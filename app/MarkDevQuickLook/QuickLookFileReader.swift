//
//  QuickLookFileReader.swift
//  MarkDevQuickLook
//
//  The extension-local, read-only file boundary.
//

import Darwin
import Foundation

enum QuickLookReadError: Error, Equatable, LocalizedError, Sendable {
    case invalidLimit
    case notRegularFile
    case tooLarge(maximumBytes: Int)
    case changedDuringRead
    case systemCall(code: Int32)

    var errorDescription: String? {
        switch self {
        case .invalidLimit:
            "The preview size limit is invalid."
        case .notRegularFile:
            "Only regular files can be previewed."
        case .tooLarge(let maximumBytes):
            "The file is larger than the \(maximumBytes)-byte preview limit."
        case .changedDuringRead:
            "The file changed while its preview was being prepared."
        case .systemCall(let code):
            String(cString: strerror(code))
        }
    }
}

/// Closed, path-free failure categories safe to publish through unified logs.
///
/// The extension intentionally does not log `Error.localizedDescription`,
/// errno, or the requested URL. Those values can contain filenames, volume
/// names, dependency text, and other user-controlled data. Keep this enum
/// exhaustive so adding a new typed read failure requires choosing a bounded
/// public category here.
enum QuickLookDiagnosticFailureCode: String, Equatable, Sendable {
    case invalidLimit = "invalid-limit"
    case notRegularFile = "not-regular-file"
    case tooLarge = "too-large"
    case changedDuringRead = "changed-during-read"
    case systemCall = "system-call"
    case cancelled
    case unexpected
}

enum QuickLookDiagnostics {
    static func failureCode(for error: Error) -> QuickLookDiagnosticFailureCode {
        if error is CancellationError { return .cancelled }
        guard let readError = error as? QuickLookReadError else { return .unexpected }
        switch readError {
        case .invalidLimit:
            return .invalidLimit
        case .notRegularFile:
            return .notRegularFile
        case .tooLarge:
            return .tooLarge
        case .changedDuringRead:
            return .changedDuringRead
        case .systemCall:
            return .systemCall
        }
    }
}

/// One generation-bound Quick Look preparation request.
///
/// The detached worker starts when the request is created, while ``value()``
/// binds a caller's cancellation to that worker and asks the owning
/// coordinator to authorize publication. The coordinator reference is weak so
/// releasing the preview controller can tear the owner down and cancel work
/// instead of the in-flight request retaining it indefinitely.
final class QuickLookPreviewRequest<Content: Sendable>: @unchecked Sendable {
    let generation: UInt64
    let url: URL

    private weak var coordinator: QuickLookPreviewCoordinator<Content>?
    private let worker: Task<Content, Error>
    fileprivate let commit: @MainActor @Sendable (Content, URL) throws -> Void

    fileprivate init(
        coordinator: QuickLookPreviewCoordinator<Content>,
        generation: UInt64,
        url: URL,
        priority: TaskPriority,
        operation: @escaping @Sendable () throws -> Content,
        commit: @escaping @MainActor @Sendable (Content, URL) throws -> Void
    ) {
        self.coordinator = coordinator
        self.generation = generation
        self.url = url
        self.commit = commit
        worker = Task.detached(priority: priority) {
            try operation()
        }
    }

    deinit {
        worker.cancel()
    }

    /// Waits for the detached read without allowing unstructured-task
    /// cancellation to disappear at the `Task.value` boundary.
    func value() async throws {
        let retainedWorker = worker
        let content: Content
        do {
            content = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let content = try await retainedWorker.value
                // A cancelled worker is cooperative and may still return a
                // value. Never treat that late success as publishable.
                try Task.checkCancellation()
                return content
            } onCancel: {
                retainedWorker.cancel()
            }
        } catch {
            if let coordinator {
                await coordinator.finishIfCurrent(self)
            }
            throw error
        }

        guard let coordinator else { throw CancellationError() }
        do {
            try await coordinator.commitIfCurrent(content, from: self)
        } catch {
            await coordinator.finishIfCurrent(self)
            throw error
        }
    }

    func cancel() {
        worker.cancel()
    }
}

/// Owns the sole currently authorized Quick Look read.
///
/// A new request cancels its predecessor immediately. Publication then checks
/// the request object, its monotonically issued generation, and its exact URL
/// together on MainActor. The commit closure is synchronous on that actor, so
/// no newer request can interleave between the authorization check and
/// `preview.show`.
@MainActor
final class QuickLookPreviewCoordinator<Content: Sendable> {
    private var latestGeneration: UInt64 = 0
    private var activeURL: URL?
    private var activeRequest: QuickLookPreviewRequest<Content>?

    deinit {
        activeRequest?.cancel()
    }

    func start(
        url: URL,
        priority: TaskPriority = .userInitiated,
        operation: @escaping @Sendable () throws -> Content,
        commit: @escaping @MainActor @Sendable (Content, URL) throws -> Void
    ) -> QuickLookPreviewRequest<Content> {
        let displaced = activeRequest
        activeRequest = nil
        activeURL = nil
        displaced?.cancel()

        // Saturation cannot alias authority because object identity and URL
        // are checked as well. It also avoids turning an unreachable counter
        // boundary into a process trap.
        if latestGeneration < UInt64.max {
            latestGeneration += 1
        }

        let request = QuickLookPreviewRequest(
            coordinator: self,
            generation: latestGeneration,
            url: url,
            priority: priority,
            operation: operation,
            commit: commit)
        activeURL = url
        activeRequest = request
        return request
    }

    func cancel() {
        let request = activeRequest
        activeRequest = nil
        activeURL = nil
        request?.cancel()
    }

    fileprivate func finishIfCurrent(_ request: QuickLookPreviewRequest<Content>) {
        guard activeRequest === request else { return }
        activeRequest = nil
        activeURL = nil
    }

    fileprivate func commitIfCurrent(
        _ content: Content,
        from request: QuickLookPreviewRequest<Content>
    ) throws {
        guard activeRequest === request,
            request.generation == latestGeneration,
            request.url == activeURL
        else {
            throw CancellationError()
        }
        defer { finishIfCurrent(request) }

        try Task.checkCancellation()
        try request.commit(content, request.url)
    }
}

enum QuickLookFileReader {
    /// Reads one stable, bounded regular-file snapshot.
    ///
    /// The app and extension deliberately share the descriptor implementation;
    /// this wrapper keeps Quick Look's domain-specific error language without
    /// leaving a second filesystem authority boundary to drift.
    static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        do {
            return try BoundedRegularFileReader.read(
                url,
                maximumBytes: maximumBytes
            ).data
        } catch let error as BoundedRegularFileReadError {
            switch error {
            case .invalidLimit:
                throw QuickLookReadError.invalidLimit
            case .notFileURL, .notRegularFile:
                throw QuickLookReadError.notRegularFile
            case .tooLarge(let maximumBytes):
                throw QuickLookReadError.tooLarge(maximumBytes: maximumBytes)
            case .changedDuringRead:
                throw QuickLookReadError.changedDuringRead
            case .systemCall(let code):
                throw QuickLookReadError.systemCall(code: code)
            }
        }
    }
}
