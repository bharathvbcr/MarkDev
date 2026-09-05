//
//  WorkspaceIOLifecycle.swift
//  MarkDevKit
//
//  Exact lifetime and presentation boundaries for asynchronous workspace I/O.
//

import Foundation

/// Non-wrapping authority for one asynchronous workspace operation.
///
/// A task being cancelled is not proof that its completion cannot arrive: a
/// synchronous filesystem or Rust call may already be in flight. Callers keep
/// a token and check it immediately before every UI mutation after an `await`.
@MainActor
public final class WorkspaceIOLifecycle {
    public enum Scope: Hashable, Sendable {
        case documentOpen(PaneID)
        case documentBatch(PaneID)
        case editorDrop(PaneID)
        case vault
        case sessionRestore
        case createNote(PaneID)
        case watcher
        case watchCatchUp
        case rename
        case externalDocument(UUID)
    }

    public struct Token: Hashable, Sendable {
        fileprivate let epoch: UUID
        fileprivate let operation: UUID
        fileprivate let scope: Scope
    }

    private var epoch = UUID()
    private var current: [Scope: UUID] = [:]

    public init() {}

    /// Starts the latest operation in `scope`, invalidating only an older
    /// completion that would compete for the same state.
    public func begin(_ scope: Scope) -> Token {
        let operation = UUID()
        current[scope] = operation
        return Token(epoch: epoch, operation: operation, scope: scope)
    }

    public func isCurrent(_ token: Token) -> Bool {
        token.epoch == epoch && current[token.scope] == token.operation
    }

    public func finish(_ token: Token) {
        guard isCurrent(token) else { return }
        current[token.scope] = nil
    }

    public func invalidate(_ scope: Scope) {
        current[scope] = nil
    }

    /// Retires every token without relying on an integer that can wrap back
    /// into equality with an ancient completion.
    public func invalidateAll() {
        epoch = UUID()
        current.removeAll(keepingCapacity: false)
    }
}

/// One bounded owner for the unstructured tasks launched by synchronous
/// SwiftUI callbacks.
///
/// Replacing a scope cancels its prior task and the lifecycle token rejects a
/// completion already inside non-cancellable system work. The fixed scope set
/// also prevents repeated opens or watcher bursts from retaining an unbounded
/// task history for the lifetime of a window.
@MainActor
public final class WorkspaceIOTaskBag {
    private struct Entry {
        let id: UUID
        let task: Task<Void, Never>
    }

    private var tasks: [WorkspaceIOLifecycle.Scope: Entry] = [:]

    public init() {}

    public func launch(
        in scope: WorkspaceIOLifecycle.Scope,
        priority: TaskPriority? = nil,
        operation: @escaping @MainActor @Sendable () async -> Void
    ) {
        tasks.removeValue(forKey: scope)?.task.cancel()
        let id = UUID()
        let task = Task(priority: priority) { @MainActor [weak self] in
            await operation()
            guard self?.tasks[scope]?.id == id else { return }
            self?.tasks[scope] = nil
        }
        tasks[scope] = Entry(id: id, task: task)
    }

    public func cancel(_ scope: WorkspaceIOLifecycle.Scope) {
        tasks.removeValue(forKey: scope)?.task.cancel()
    }

    public func cancelAll() {
        let retained = Array(tasks.values)
        tasks.removeAll(keepingCapacity: false)
        for entry in retained { entry.task.cancel() }
    }

    public func isActive(_ scope: WorkspaceIOLifecycle.Scope) -> Bool {
        tasks[scope] != nil
    }

    var countForTesting: Int { tasks.count }
}

/// Shared finite budgets for work sourced from the filesystem or external UI.
public enum WorkspaceIOBounds {
    /// Canonical process-wide admission cap. This lives outside the
    /// MainActor-isolated inbox so request defaults and detached producers can
    /// read the policy without an implicit actor hop.
    public static let maximumOpenItems = 32
    public static let maximumWatchedPaths = 256
    public static let maximumCreateAttempts = 128
    public static let maximumRenameItems = 32
    public static let maximumFailureItems = 16
    public static let maximumDisplayNameBytes = 160
}

/// A finite, stable batch of note moves accepted from one drag gesture.
///
/// Duplicate providers are collapsed before mutation so the second copy cannot
/// race the first move and manufacture a misleading failure. Only the bounded
/// prefix is inspected; a hostile pasteboard cannot make admission itself an
/// unbounded MainActor operation.
public struct WorkspaceRenameBatchRequest: Equatable, Sendable {
    public let urls: [URL]
    public let dropped: Int

    public static func bounded(
        _ urls: [URL],
        limit: Int = WorkspaceIOBounds.maximumRenameItems
    ) -> WorkspaceRenameBatchRequest {
        let limit = min(max(0, limit), WorkspaceIOBounds.maximumRenameItems)
        let prefix = urls.prefix(limit)
        var seen: Set<String> = []
        var admitted: [URL] = []
        admitted.reserveCapacity(prefix.count)
        var duplicateCount = 0
        var refusedCount = 0
        for url in prefix {
            guard BoundedRegularFileReader.hasLocalFileAuthority(url) else {
                refusedCount += 1
                continue
            }
            let standardized = url.standardizedFileURL
            guard seen.insert(standardized.path).inserted else {
                duplicateCount += 1
                continue
            }
            admitted.append(standardized)
        }
        let omitted = max(0, urls.count - prefix.count)
        let (classifiedDropped, classifiedOverflow) = duplicateCount.addingReportingOverflow(
            refusedCount)
        let (dropped, overflow) = omitted.addingReportingOverflow(classifiedDropped)
        return WorkspaceRenameBatchRequest(
            urls: admitted,
            dropped: classifiedOverflow || overflow ? Int.max : dropped)
    }

    public var truncationMessage: String? {
        guard dropped > 0 else { return nil }
        return "\(dropped) additional dropped notes were not moved."
    }
}

public enum WorkspaceRenameAttempt: Equatable, Sendable {
    case moved
    case movedWithIssue(String)
    case failed(String)
}

public struct WorkspaceRenameIssue: Equatable, Sendable {
    public let displayName: String
    public let reason: String

    public init(item: URL, reason: String) {
        displayName = WorkspaceIOFailure.safeDisplayName(item)
        self.reason = String(reason.prefix(512))
    }
}

/// Truthful, bounded per-item results for a multi-note move.
public struct WorkspaceRenameBatchOutcome: Equatable, Sendable {
    public private(set) var movedCount = 0
    public private(set) var issues: [WorkspaceRenameIssue] = []
    public private(set) var omittedIssueCount = 0

    public init() {}

    public mutating func record(_ attempt: WorkspaceRenameAttempt, item: URL) {
        switch attempt {
        case .moved:
            movedCount += 1
        case .movedWithIssue(let reason):
            movedCount += 1
            recordIssue(reason, item: item)
        case .failed(let reason):
            recordIssue(reason, item: item)
        }
    }

    public var issueMessage: String? {
        guard !issues.isEmpty else {
            return omittedIssueCount > 0
                ? "\(omittedIssueCount) note moves need attention; details were omitted."
                : nil
        }
        if issues.count == 1, omittedIssueCount == 0, let issue = issues.first {
            return "\(issue.displayName): \(issue.reason)"
        }
        let shown = issues.map(\.displayName).joined(separator: ", ")
        let total = issues.count + omittedIssueCount
        let suffix = omittedIssueCount == 0
            ? ""
            : "; \(omittedIssueCount) more not listed"
        return "\(total) note moves need attention: \(shown)\(suffix)."
    }

    private mutating func recordIssue(_ reason: String, item: URL) {
        guard issues.count < WorkspaceIOBounds.maximumFailureItems else {
            omittedIssueCount += 1
            return
        }
        issues.append(WorkspaceRenameIssue(item: item, reason: reason))
    }
}

/// A bounded, path-redacted user-facing projection of arbitrary I/O errors.
public enum WorkspaceIOFailure {
    public enum Operation: Sendable {
        case openDocument
        case openVault
        case createDocument
        case renameDocument
        case reloadDocument
        case watchVault
        case restoreSession
    }

    public static func presentation(
        _ error: Error,
        operation: Operation,
        item: URL? = nil
    ) -> String? {
        if error is CancellationError || error as? SecureLocalFileError == .cancelled {
            return nil
        }

        let name = item.map(safeDisplayName)
        if let workspaceError = error as? WorkspaceError,
            let description = workspaceError.errorDescription
        {
            return bounded(description)
        }

        switch operation {
        case .openDocument:
            return bounded("Could not open \(name ?? "that document") safely.")
        case .openVault:
            return bounded("Could not open \(name ?? "that vault") safely.")
        case .createDocument:
            return bounded("Could not create a note in \(name ?? "that folder") safely.")
        case .renameDocument:
            return bounded("Could not move \(name ?? "that note") safely.")
        case .reloadDocument:
            return bounded("Could not reload \(name ?? "that note") safely.")
        case .watchVault:
            return "Some changed notes could not be checked safely. The vault will be rescanned."
        case .restoreSession:
            return "Some documents from the previous session could not be restored safely."
        }
    }

    public static func safeDisplayName(_ url: URL) -> String {
        let candidate = url.lastPathComponent.isEmpty ? "Item" : url.lastPathComponent
        return bounded(candidate)
    }

    private static func bounded(_ value: String) -> String {
        guard value.utf8.count > WorkspaceIOBounds.maximumDisplayNameBytes else {
            return value
        }
        var result = ""
        result.reserveCapacity(WorkspaceIOBounds.maximumDisplayNameBytes)
        for scalar in value.unicodeScalars {
            let next = result + String(scalar)
            guard next.utf8.count <= WorkspaceIOBounds.maximumDisplayNameBytes - 3 else {
                break
            }
            result = next
        }
        return result + "…"
    }
}
