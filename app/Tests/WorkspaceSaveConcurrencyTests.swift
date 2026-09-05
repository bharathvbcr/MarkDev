//
//  WorkspaceSaveConcurrencyTests.swift
//  MarkDevKitTests
//
//  Adversarial save-state regressions captured before the async transaction
//  boundary existed.
//

import Darwin
import XCTest

@testable import MarkDevKit

private final class BlockingDocumentCommitter: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var enteredCount = 0
    private var activeCount = 0
    private var maximumActiveCount = 0
    private var hold = true
    private var payloads: [String] = []
    private var expectations: [FileTransactionExpectation] = []
    private var receiptVersions: [FileVersionToken?] = []

    func commit(
        _ request: LocalDocumentSaveRequest,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) throws -> FileTransactionReceipt {
        lock.lock()
        enteredCount += 1
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        payloads.append(String(decoding: request.data, as: UTF8.self))
        expectations.append(request.authorization.expectation)
        let shouldHold = hold
        lock.unlock()
        entered.signal()

        defer {
            lock.lock()
            activeCount -= 1
            lock.unlock()
        }

        if shouldHold {
            while release.wait(timeout: .now() + 0.01) != .success {
                if cancellationCheck() { break }
            }
        }
        let receipt = try LocalDocumentIO.commitSynchronously(
            request, cancellationCheck: cancellationCheck)
        lock.lock()
        receiptVersions.append(receipt.version)
        lock.unlock()
        return receipt
    }

    func waitForEntry() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(
                    returning: self.entered.wait(timeout: .now() + 5) == .success)
            }
        }
    }

    func allowOne() {
        release.signal()
    }

    func allowAllFutureCommits() {
        lock.lock()
        hold = false
        lock.unlock()
        for _ in 0..<16 { release.signal() }
    }

    var observedMaximumActiveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximumActiveCount
    }

    var observedPayloads: [String] {
        lock.lock()
        defer { lock.unlock() }
        return payloads
    }

    var observedExpectations: [FileTransactionExpectation] {
        lock.lock()
        defer { lock.unlock() }
        return expectations
    }

    var observedReceiptVersions: [FileVersionToken?] {
        lock.lock()
        defer { lock.unlock() }
        return receiptVersions
    }
}

private final class PostCommitBlockingDocumentCommitter: @unchecked Sendable {
    private let committed = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    func commit(
        _ request: LocalDocumentSaveRequest,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) throws -> FileTransactionReceipt {
        let receipt = try LocalDocumentIO.commitSynchronously(
            request, cancellationCheck: cancellationCheck)
        committed.signal()
        while release.wait(timeout: .now() + 0.01) != .success {}
        return receipt
    }

    func waitForCommit() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(
                    returning: self.committed.wait(timeout: .now() + 5) == .success)
            }
        }
    }

    func allowSettlement() {
        release.signal()
    }
}

private final class RecordingDocumentCommitter: @unchecked Sendable {
    private let firstEntered = DispatchSemaphore(value: 0)
    private let releaseFirst = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var invocationCount = 0
    private var activeCount = 0
    private var maximumActiveCount = 0
    private var payloads: [String] = []

    func commit(
        _ request: LocalDocumentSaveRequest,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) throws -> FileTransactionReceipt {
        lock.lock()
        let invocation = invocationCount
        invocationCount += 1
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        payloads.append(String(decoding: request.data, as: UTF8.self))
        lock.unlock()
        defer {
            lock.lock()
            activeCount -= 1
            lock.unlock()
        }

        if invocation == 0 {
            firstEntered.signal()
            while releaseFirst.wait(timeout: .now() + 0.01) != .success {
                if cancellationCheck() { throw CancellationError() }
            }
        }
        if cancellationCheck() { throw CancellationError() }
        guard let version = request.authorization.existingVersion else {
            throw SecureLocalFileError.expectationMismatch
        }
        return FileTransactionReceipt(
            destination: request.authorization.destination,
            version: version,
            durability: .fullySynced,
            recovery: nil)
    }

    func waitForFirstEntry() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(
                    returning: self.firstEntered.wait(timeout: .now() + 5) == .success)
            }
        }
    }

    func allowFirst() {
        releaseFirst.signal()
    }

    var observedPayloads: [String] {
        lock.lock()
        defer { lock.unlock() }
        return payloads
    }

    var observedMaximumActiveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximumActiveCount
    }
}

private final class AllBlockingDocumentCommitter: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var enteredCount = 0
    private var activeCount = 0
    private var maximumActiveCount = 0
    private var payloads: [String] = []

    func commit(
        _ request: LocalDocumentSaveRequest,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) throws -> FileTransactionReceipt {
        lock.lock()
        enteredCount += 1
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        payloads.append(String(decoding: request.data, as: UTF8.self))
        lock.unlock()
        entered.signal()
        defer {
            lock.lock()
            activeCount -= 1
            lock.unlock()
        }

        while release.wait(timeout: .now() + 0.01) != .success {
            if cancellationCheck() { throw CancellationError() }
        }
        guard let version = request.authorization.existingVersion else {
            throw SecureLocalFileError.expectationMismatch
        }
        return FileTransactionReceipt(
            destination: request.authorization.destination,
            version: version,
            durability: .fullySynced,
            recovery: nil)
    }

    func waitForEntryCount(_ expected: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                for _ in 0..<expected {
                    guard self.entered.wait(timeout: .now() + 5) == .success else {
                        continuation.resume(returning: false)
                        return
                    }
                }
                continuation.resume(returning: true)
            }
        }
    }

    func allow(_ count: Int) {
        for _ in 0..<count { release.signal() }
    }

    var observedMaximumActiveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximumActiveCount
    }

    var observedPayloads: [String] {
        lock.lock()
        defer { lock.unlock() }
        return payloads
    }
}

private final class DurabilityDocumentCommitter: @unchecked Sendable {
    func commit(
        _ request: LocalDocumentSaveRequest,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) throws -> FileTransactionReceipt {
        let receipt = try LocalDocumentIO.commitSynchronously(
            request, cancellationCheck: cancellationCheck)
        return receipt.replacingDurability(
            receipt.recovery == nil
                ? .committedDirectorySyncUnconfirmed(errno: EIO)
                : .recoveryRetained(directorySyncErrno: EIO))
    }
}

private final class SwitchableDurabilityDocumentCommitter: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldConfirmDirectory = false

    func useFullySyncedReceipts() {
        lock.lock()
        shouldConfirmDirectory = true
        lock.unlock()
    }

    func commit(
        _ request: LocalDocumentSaveRequest,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) throws -> FileTransactionReceipt {
        let receipt = try LocalDocumentIO.commitSynchronously(
            request, cancellationCheck: cancellationCheck)
        lock.lock()
        let confirmed = shouldConfirmDirectory
        lock.unlock()
        guard !confirmed else { return receipt }
        return receipt.replacingDurability(
            receipt.recovery == nil
                ? .committedDirectorySyncUnconfirmed(errno: EIO)
                : .recoveryRetained(directorySyncErrno: EIO))
    }
}

private final class BlockingDurabilityConfirmer: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    func confirm(
        _ authorization: WorkspaceSaveAuthorization,
        expectedVersion: FileVersionToken,
        maximumBytes: Int,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) throws {
        entered.signal()
        while release.wait(timeout: .now() + 0.01) != .success {
            if cancellationCheck() { throw CancellationError() }
        }
        if cancellationCheck() { throw CancellationError() }
        try LocalDocumentIO.confirmDurabilitySynchronously(
            authorization,
            expectedVersion: expectedVersion,
            maximumBytes: maximumBytes,
            cancellationCheck: cancellationCheck)
    }

    func waitForEntry() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(
                    returning: self.entered.wait(timeout: .now() + 5) == .success)
            }
        }
    }

    func allow() {
        release.signal()
    }
}

private final class ClassifyingDocumentCommitter: @unchecked Sendable {
    func commit(
        _ request: LocalDocumentSaveRequest,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) throws -> FileTransactionReceipt {
        switch String(decoding: request.data, as: UTF8.self) {
        case "fail":
            throw SecureLocalFileError.operation(.write, errno: EIO)
        case "cancel":
            throw CancellationError()
        default:
            return try LocalDocumentIO.commitSynchronously(
                request, cancellationCheck: cancellationCheck)
        }
    }
}

private final class FailFirstThenCommitDocumentCommitter: @unchecked Sendable {
    private let firstEntered = DispatchSemaphore(value: 0)
    private let releaseFirst = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var callCount = 0
    private var payloads: [String] = []

    func commit(
        _ request: LocalDocumentSaveRequest,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) throws -> FileTransactionReceipt {
        lock.lock()
        let call = callCount
        callCount += 1
        payloads.append(String(decoding: request.data, as: UTF8.self))
        lock.unlock()
        if call == 0 {
            firstEntered.signal()
            _ = releaseFirst.wait(timeout: .now() + 5)
            throw SecureLocalFileError.operation(.write, errno: ENOSPC)
        }
        return try LocalDocumentIO.commitSynchronously(
            request, cancellationCheck: cancellationCheck)
    }

    func waitForFirstEntry() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(
                    returning: self.firstEntered.wait(timeout: .now() + 5) == .success)
            }
        }
    }

    func allowFirstFailure() { releaseFirst.signal() }

    var observedPayloads: [String] {
        lock.lock()
        defer { lock.unlock() }
        return payloads
    }
}

private final class FailThenPostCommitBlockingDocumentCommitter: @unchecked Sendable {
    private let firstEntered = DispatchSemaphore(value: 0)
    private let releaseFirst = DispatchSemaphore(value: 0)
    private let secondCommitted = DispatchSemaphore(value: 0)
    private let releaseSecond = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var callCount = 0

    func commit(
        _ request: LocalDocumentSaveRequest,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) throws -> FileTransactionReceipt {
        lock.lock()
        let call = callCount
        callCount += 1
        lock.unlock()
        if call == 0 {
            firstEntered.signal()
            _ = releaseFirst.wait(timeout: .now() + 5)
            throw SecureLocalFileError.operation(.write, errno: ENOSPC)
        }
        let receipt = try LocalDocumentIO.commitSynchronously(
            request,
            cancellationCheck: cancellationCheck)
        secondCommitted.signal()
        _ = releaseSecond.wait(timeout: .now() + 5)
        return receipt
    }

    func waitForFirstEntry() async -> Bool {
        await wait(for: firstEntered)
    }

    func allowFirstFailure() {
        releaseFirst.signal()
    }

    func waitForSecondCommit() async -> Bool {
        await wait(for: secondCommitted)
    }

    func allowSecondSettlement() {
        releaseSecond.signal()
    }

    private func wait(for semaphore: DispatchSemaphore) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(
                    returning: semaphore.wait(timeout: .now() + 5) == .success)
            }
        }
    }
}

private enum UnknownCommitFailure: Error {
    case injected
}

private final class UnknownFailingDocumentCommitter: @unchecked Sendable {
    private let firstEntered = DispatchSemaphore(value: 0)
    private let releaseFirst = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var payloads: [String] = []

    func commit(
        _ request: LocalDocumentSaveRequest,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) throws -> FileTransactionReceipt {
        lock.lock()
        let call = payloads.count
        payloads.append(String(decoding: request.data, as: UTF8.self))
        lock.unlock()
        if call == 0 {
            firstEntered.signal()
            _ = releaseFirst.wait(timeout: .now() + 5)
            throw UnknownCommitFailure.injected
        }
        return try LocalDocumentIO.commitSynchronously(
            request,
            cancellationCheck: cancellationCheck)
    }

    func waitForFirstEntry() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(
                    returning: self.firstEntered.wait(timeout: .now() + 5) == .success)
            }
        }
    }

    func allowFailure() {
        releaseFirst.signal()
    }

    var observedPayloads: [String] {
        lock.lock()
        defer { lock.unlock() }
        return payloads
    }
}

private final class MalformedPrepublicationCommitter: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var payloads: [String] = []

    func commit(
        _ request: LocalDocumentSaveRequest,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) throws -> FileTransactionReceipt {
        lock.lock()
        payloads.append(String(decoding: request.data, as: UTF8.self))
        lock.unlock()
        entered.signal()
        _ = release.wait(timeout: .now() + 5)
        let inner = FileTransactionReceipt(
            destination: request.authorization.destination,
            version: request.authorization.existingVersion,
            durability: .indeterminate(operation: .publish, errno: EINTR),
            recovery: nil)
        let outer = FileTransactionReceipt(
            destination: request.authorization.destination,
            version: nil,
            durability: .notPublishedRecoveryUnconfirmed(
                operation: .verify,
                errno: nil),
            recovery: nil)
        throw SecureLocalFileError.prepublicationFailure(
            cause: .indeterminate(inner),
            receipt: outer)
    }

    func waitForEntry() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(
                    returning: self.entered.wait(timeout: .now() + 5) == .success)
            }
        }
    }

    func allowFailure() { release.signal() }

    var observedPayloads: [String] {
        lock.lock()
        defer { lock.unlock() }
        return payloads
    }
}

private final class RetriableMissingStageFailureCommitter: @unchecked Sendable {
    private let lock = NSLock()
    private var remainingFailures: Int
    private var calls = 0

    init(failureCount: Int) {
        remainingFailures = failureCount
    }

    func commit(
        _ request: LocalDocumentSaveRequest,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) throws -> FileTransactionReceipt {
        lock.lock()
        calls += 1
        let shouldFail = remainingFailures > 0
        if shouldFail { remainingFailures -= 1 }
        lock.unlock()
        guard shouldFail else {
            return try LocalDocumentIO.commitSynchronously(
                request,
                cancellationCheck: cancellationCheck)
        }

        var syscalls = SecureFileSyscalls.live
        syscalls.write = { _, _, _ in
            errno = ENOSPC
            return -1
        }
        let directory = try UserContentDirectory(
            containing: request.authorization.destination,
            syscalls: syscalls,
            cancellationCheck: cancellationCheck)
        var transaction = directory.handle.transaction(
            component: request.authorization.component,
            data: request.data,
            expectation: request.authorization.expectation,
            policy: .userContent,
            maximumBytes: request.maximumBytes,
            reusableStage: request.authorization.reusableStage)
        transaction.cancellationCheck = cancellationCheck
        return try transaction.commit()
    }

    var invocationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

private final class PreparationGrantProbe: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    func blockGrantedSlot() {
        entered.signal()
        _ = release.wait(timeout: .now() + 5)
    }

    func waitForGrant() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(
                    returning: self.entered.wait(timeout: .now() + 5) == .success)
            }
        }
    }

    func allow() {
        release.signal()
    }
}

private final class PreparationCompletionProbe: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var shouldBlock = true

    func blockCompletedPreparation() {
        lock.lock()
        guard shouldBlock else {
            lock.unlock()
            return
        }
        shouldBlock = false
        lock.unlock()
        entered.signal()
        _ = release.wait(timeout: .now() + 5)
    }

    func waitForCompletion() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(
                    returning: self.entered.wait(timeout: .now() + 5) == .success)
            }
        }
    }

    func allowReturn() {
        release.signal()
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class BlockingDocumentReader: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var calls = 0

    func read(
        _ url: URL,
        maximumBytes: Int,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) throws -> SecureLocalFileReadSnapshot {
        lock.lock()
        calls += 1
        lock.unlock()
        entered.signal()
        while release.wait(timeout: .now() + 0.01) != .success {
            if cancellationCheck() { throw CancellationError() }
        }
        if cancellationCheck() { throw CancellationError() }
        return try SecureLocalFileSystem.read(
            url,
            maximumBytes: maximumBytes,
            cancellationCheck: cancellationCheck)
    }

    func waitForEntry() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(
                    returning: self.entered.wait(timeout: .now() + 5) == .success)
            }
        }
    }

    func allow() {
        release.signal()
    }

    var invocationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

@MainActor
final class WorkspaceSaveConcurrencyTests: XCTestCase {
    private func makeWorkspace(
        vaultRoot: URL? = nil,
        diagnostics: DiagnosticsEmitter = .shared,
        documentIO: LocalDocumentIO = LocalDocumentIO(),
        transactionRegistry: ProcessFileTransactionRegistry = ProcessFileTransactionRegistry(),
        documentRead: (@Sendable (URL, Int) throws -> WorkspaceDocumentReadSnapshot)? = nil
    ) -> Workspace {
        if let documentRead {
            return Workspace(
                vaultRoot: vaultRoot,
                diagnostics: diagnostics,
                documentIO: documentIO,
                transactionRegistry: transactionRegistry,
                documentRead: documentRead)
        }
        return Workspace(
            vaultRoot: vaultRoot,
            diagnostics: diagnostics,
            documentIO: documentIO,
            transactionRegistry: transactionRegistry)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkDevAsyncSave-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func testEditDuringSavePersistsSnapshotWithoutClearingNewerEdit() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Note.md")
        try Data("disk".utf8).write(to: file)
        let blocker = BlockingDocumentCommitter()
        let io = LocalDocumentIO(maximumConcurrent: 2) { request, cancellationCheck in
            try blocker.commit(request, cancellationCheck: cancellationCheck)
        }
        let workspace = makeWorkspace(documentIO: io)
        let pane = workspace.focusedPane
        try workspace.open(file, in: pane)
        let documentID = try XCTUnwrap(workspace.document(in: pane)?.id)
        XCTAssertTrue(workspace.updateText("saved snapshot", in: pane))

        let save = Task { try await workspace.saveAsync(document: documentID) }
        let entered = await blocker.waitForEntry()
        XCTAssertTrue(entered)
        XCTAssertTrue(workspace.updateText("newer edit", in: pane))
        blocker.allowOne()
        _ = try await save.value

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "saved snapshot")
        let current = try XCTUnwrap(workspace.document(in: pane))
        XCTAssertEqual(current.text, "newer edit")
        XCTAssertTrue(current.hasUnsavedChanges)
        XCTAssertTrue(current.matchesPersisted("saved snapshot"))
    }

    func testEditGenerationPreventsFalseCleanWhenTextReturnsToSavedSnapshot() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Note.md")
        try Data("disk".utf8).write(to: file)
        let blocker = BlockingDocumentCommitter()
        let workspace = makeWorkspace(
            documentIO: LocalDocumentIO(maximumConcurrent: 1) { request, cancellationCheck in
                try blocker.commit(request, cancellationCheck: cancellationCheck)
            })
        let pane = workspace.focusedPane
        try workspace.open(file, in: pane)
        let documentID = try XCTUnwrap(workspace.document(in: pane)?.id)
        XCTAssertTrue(workspace.updateText("snapshot", in: pane))

        let save = Task { try await workspace.saveAsync(document: documentID) }
        let entered = await blocker.waitForEntry()
        XCTAssertTrue(entered)
        XCTAssertTrue(workspace.updateText("intermediate", in: pane))
        XCTAssertTrue(workspace.updateText("snapshot", in: pane))
        blocker.allowOne()
        _ = try await save.value

        let current = try XCTUnwrap(workspace.document(in: pane))
        XCTAssertEqual(current.text, "snapshot")
        XCTAssertTrue(
            current.hasUnsavedChanges,
            "a post-snapshot edit generation must not be erased merely because text returned")
        XCTAssertTrue(current.matchesPersisted("snapshot"))
    }

    func testCloseDuringBlockedSaveCancelsBeforePublicationAndNeverResurrectsDocument() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Note.md")
        try Data("disk".utf8).write(to: file)
        let blocker = BlockingDocumentCommitter()
        let io = LocalDocumentIO(maximumConcurrent: 2) { request, cancellationCheck in
            try blocker.commit(request, cancellationCheck: cancellationCheck)
        }
        let workspace = makeWorkspace(documentIO: io)
        let pane = workspace.focusedPane
        try workspace.open(file, in: pane)
        let documentID = try XCTUnwrap(workspace.document(in: pane)?.id)
        XCTAssertTrue(workspace.updateText("local", in: pane))

        let save = Task { try await workspace.saveAsync(document: documentID) }
        let entered = await blocker.waitForEntry()
        XCTAssertTrue(entered)
        workspace.close(documentID, in: pane)
        blocker.allowOne()

        do {
            _ = try await save.value
            XCTFail("a pre-publication close must cancel the document's save")
        } catch is CancellationError {
            // Expected.
        } catch SecureLocalFileError.cancelled {
            // Expected transaction-level cancellation.
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "disk")
        XCTAssertFalse(workspace.state(for: pane).documents.contains { $0.id == documentID })
    }

    func testSaveAsAuthorizationRejectsIdenticalByteReplacementBeforeCommit() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("Existing.md")
        let replacement = directory.appendingPathComponent("Replacement.md")
        try Data("existing".utf8).write(to: destination)
        let blocker = BlockingDocumentCommitter()
        let io = LocalDocumentIO(maximumConcurrent: 2) { request, cancellationCheck in
            try blocker.commit(request, cancellationCheck: cancellationCheck)
        }
        let workspace = makeWorkspace(documentIO: io)
        let pane = workspace.focusedPane
        XCTAssertTrue(workspace.updateText("draft", in: pane))
        let documentID = try XCTUnwrap(workspace.document(in: pane)?.id)

        let authorization = try await workspace.authorizeSaveDestination(
            destination, overwrite: true)
        let save = Task {
            try await workspace.saveAsync(document: documentID, authorization: authorization)
        }
        let entered = await blocker.waitForEntry()
        XCTAssertTrue(entered)
        try Data("existing".utf8).write(to: replacement)
        XCTAssertEqual(Darwin.rename(replacement.path, destination.path), 0)
        blocker.allowOne()

        await XCTAssertThrowsErrorAsync(try await save.value)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "existing")
        XCTAssertNil(workspace.document(in: pane)?.url)
        XCTAssertTrue(workspace.document(in: pane)?.hasUnsavedChanges == true)
    }

    func testReceiptVersionAuthorizesNextSaveAndRejectsLaterReplacement() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Note.md")
        let replacement = directory.appendingPathComponent("Replacement.md")
        try Data("disk".utf8).write(to: file)
        let workspace = makeWorkspace(documentIO: LocalDocumentIO())
        let pane = workspace.focusedPane
        try workspace.open(file, in: pane)
        let documentID = try XCTUnwrap(workspace.document(in: pane)?.id)
        XCTAssertTrue(workspace.updateText("first", in: pane))
        _ = try await workspace.saveAsync(document: documentID)

        try Data("first".utf8).write(to: replacement)
        XCTAssertEqual(Darwin.rename(replacement.path, file.path), 0)
        XCTAssertTrue(workspace.updateText("second", in: pane))

        await XCTAssertThrowsErrorAsync(try await workspace.saveAsync(document: documentID))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "first")
        XCTAssertTrue(workspace.document(in: pane)?.hasUnsavedChanges == true)
    }

    func testSynchronousCompatibilitySaveRefusesOverlapWithAsyncSave() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Note.md")
        try Data("disk".utf8).write(to: file)
        let blocker = BlockingDocumentCommitter()
        let workspace = makeWorkspace(
            documentIO: LocalDocumentIO(maximumConcurrent: 1) { request, cancellationCheck in
                try blocker.commit(request, cancellationCheck: cancellationCheck)
            })
        let pane = workspace.focusedPane
        try workspace.open(file, in: pane)
        let documentID = try XCTUnwrap(workspace.document(in: pane)?.id)
        XCTAssertTrue(workspace.updateText("snapshot", in: pane))

        let asynchronous = Task { try await workspace.saveAsync(document: documentID) }
        let entered = await blocker.waitForEntry()
        XCTAssertTrue(entered)
        XCTAssertThrowsError(try workspace.save(document: documentID))
        workspace.close(documentID, in: pane)
        blocker.allowOne()
        await XCTAssertThrowsErrorAsync(try await asynchronous.value)
    }

    func testOpenRefusesDestinationReservedByCommittedSaveAs() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("Created.md")
        let committer = PostCommitBlockingDocumentCommitter()
        let workspace = makeWorkspace(
            documentIO: LocalDocumentIO(maximumConcurrent: 1) { request, cancellationCheck in
                try committer.commit(request, cancellationCheck: cancellationCheck)
            })
        let pane = workspace.focusedPane
        XCTAssertTrue(workspace.updateText("draft", in: pane))
        let documentID = try XCTUnwrap(workspace.document(in: pane)?.id)

        let save = Task {
            try await workspace.saveAsync(
                document: documentID, to: destination, overwrite: false)
        }
        let committed = await committer.waitForCommit()
        XCTAssertTrue(committed)
        XCTAssertThrowsError(try workspace.open(destination, in: pane)) { error in
            guard case WorkspaceError.destinationAlreadyOpen = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        committer.allowSettlement()
        _ = try await save.value

        let current = try XCTUnwrap(
            workspace.state(for: pane).documents.first(where: { $0.id == documentID }))
        XCTAssertEqual(current.url, destination)
        XCTAssertFalse(current.hasUnsavedChanges)
        XCTAssertEqual(workspace.state(for: pane).documents.count, 1)
    }

    func testSaveOutcomeReportsCommittedButDirectorySyncUnconfirmed() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Note.md")
        try Data("disk".utf8).write(to: file)
        let committer = DurabilityDocumentCommitter()
        let workspace = makeWorkspace(
            documentIO: LocalDocumentIO(maximumConcurrent: 1) { request, cancellationCheck in
                try committer.commit(request, cancellationCheck: cancellationCheck)
            })
        let pane = workspace.focusedPane
        try workspace.open(file, in: pane)
        let documentID = try XCTUnwrap(workspace.document(in: pane)?.id)
        XCTAssertTrue(workspace.updateText("saved", in: pane))

        let outcome = try await workspace.saveWithOutcome(document: documentID)

        XCTAssertEqual(outcome.destination, file)
        XCTAssertEqual(outcome.durability, .directorySyncUnconfirmed)
        XCTAssertEqual(outcome.settlement, .applied)
        XCTAssertFalse(outcome.isFullyDurable)
        XCTAssertTrue(outcome.hasUnconfirmedDurability)
        XCTAssertFalse(workspace.document(in: pane)?.hasUnsavedChanges == true)
        XCTAssertTrue(workspace.document(in: pane)?.hasUnconfirmedDurability == true)
        XCTAssertTrue(workspace.document(in: pane)?.requiresCloseReview == true)
        XCTAssertTrue(workspace.documentsWithUnsavedChanges.isEmpty)
        XCTAssertEqual(workspace.documentsRequiringCloseReview.map(\.id), [documentID])
        XCTAssertTrue(workspace.requiresConfirmationBeforeClosing(documentID, in: pane))
    }

    func testRetainedRecoveryAndDirectorySyncFactsRemainOrthogonalInSaveOutcome() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Note.md")
        try Data("disk".utf8).write(to: file)
        let handle = try SecureLocalDirectoryHandle(opening: directory)
        let initial = try handle.version(of: FileComponent("Note.md"))
        let committed = try handle.transaction(
            component: FileComponent("Note.md"),
            data: Data("saved".utf8),
            expectation: .exact(initial),
            policy: .userContent
        ).commit()
        let version = try XCTUnwrap(committed.version)
        let recoverySlot = try XCTUnwrap(committed.recoverySlot)

        let retainedOnly = try WorkspaceSaveOutcome(
            receipt: FileTransactionReceipt(
                destination: file,
                version: version,
                durability: .recoveryRetained(directorySyncErrno: nil),
                recoverySlot: recoverySlot),
            byteCount: 4,
            settlement: .applied)
        XCTAssertTrue(retainedOnly.requiresRecovery)
        XCTAssertTrue(retainedOnly.isFullyDurable)
        XCTAssertFalse(retainedOnly.hasUnconfirmedDurability)
        XCTAssertEqual(retainedOnly.recoveryVersion, recoverySlot.authority.version)
        XCTAssertNil(retainedOnly.directorySyncErrno)

        let combined = try WorkspaceSaveOutcome(
            receipt: FileTransactionReceipt(
                destination: file,
                version: version,
                durability: .recoveryRetained(directorySyncErrno: EIO),
                recoverySlot: recoverySlot),
            byteCount: 4,
            settlement: .applied)
        XCTAssertTrue(combined.requiresRecovery)
        XCTAssertFalse(combined.isFullyDurable)
        XCTAssertTrue(combined.hasUnconfirmedDurability)
        XCTAssertEqual(combined.recoveryVersion, recoverySlot.authority.version)
        XCTAssertEqual(combined.directorySyncErrno, EIO)
    }

    func testDurabilityConfirmationClearsCloseReviewWithoutRewritingText() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Note.md")
        try Data("disk".utf8).write(to: file)
        let committer = DurabilityDocumentCommitter()
        let workspace = makeWorkspace(
            documentIO: LocalDocumentIO(maximumConcurrent: 1) { request, cancellationCheck in
                try committer.commit(request, cancellationCheck: cancellationCheck)
            })
        let pane = workspace.focusedPane
        try workspace.open(file, in: pane)
        let documentID = try XCTUnwrap(workspace.document(in: pane)?.id)
        XCTAssertTrue(workspace.updateText("saved", in: pane))
        _ = try await workspace.saveWithOutcome(document: documentID)

        let confirmation = try await workspace.confirmDurability(document: documentID)
        XCTAssertEqual(confirmation, .confirmed)
        let current = try XCTUnwrap(workspace.document(in: pane))
        XCTAssertFalse(current.hasUnsavedChanges)
        XCTAssertFalse(current.hasUnconfirmedDurability)
        XCTAssertFalse(current.requiresCloseReview)
        XCTAssertTrue(workspace.documentsRequiringCloseReview.isEmpty)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "saved")
    }

    func testCancelledDurabilityConfirmationRetainsCloseReviewAndAuthority() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Note.md")
        try Data("disk".utf8).write(to: file)
        let committer = DurabilityDocumentCommitter()
        let confirmer = BlockingDurabilityConfirmer()
        let workspace = makeWorkspace(
            documentIO: LocalDocumentIO(
                maximumConcurrent: 1,
                confirmDurability: { authorization, version, maximumBytes, cancellation in
                    try confirmer.confirm(
                        authorization,
                        expectedVersion: version,
                        maximumBytes: maximumBytes,
                        cancellationCheck: cancellation)
                }
            ) { request, cancellationCheck in
                try committer.commit(request, cancellationCheck: cancellationCheck)
            })
        let pane = workspace.focusedPane
        try workspace.open(file, in: pane)
        let documentID = try XCTUnwrap(workspace.document(in: pane)?.id)
        XCTAssertTrue(workspace.updateText("saved", in: pane))
        _ = try await workspace.saveWithOutcome(document: documentID)

        let confirmation = Task {
            try await workspace.confirmDurability(document: documentID)
        }
        XCTAssertTrue(awaitValue: await confirmer.waitForEntry())
        confirmation.cancel()
        confirmer.allow()
        await XCTAssertThrowsErrorAsync(try await confirmation.value)
        XCTAssertTrue(workspace.document(in: pane)?.hasUnconfirmedDurability == true)
        XCTAssertEqual(workspace.retainedDurabilityConfirmationCountForTesting(), 1)
    }

    func testEditDuringDurabilityConfirmationCannotClearNewerReviewState() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Note.md")
        try Data("disk".utf8).write(to: file)
        let committer = DurabilityDocumentCommitter()
        let confirmer = BlockingDurabilityConfirmer()
        let workspace = makeWorkspace(
            documentIO: LocalDocumentIO(
                maximumConcurrent: 1,
                confirmDurability: { authorization, version, maximumBytes, cancellation in
                    try confirmer.confirm(
                        authorization,
                        expectedVersion: version,
                        maximumBytes: maximumBytes,
                        cancellationCheck: cancellation)
                }
            ) { request, cancellationCheck in
                try committer.commit(request, cancellationCheck: cancellationCheck)
            })
        let pane = workspace.focusedPane
        try workspace.open(file, in: pane)
        let documentID = try XCTUnwrap(workspace.document(in: pane)?.id)
        XCTAssertTrue(workspace.updateText("saved", in: pane))
        _ = try await workspace.saveWithOutcome(document: documentID)

        let confirmation = Task {
            try await workspace.confirmDurability(document: documentID)
        }
        XCTAssertTrue(awaitValue: await confirmer.waitForEntry())
        XCTAssertTrue(workspace.updateText("newer", in: pane))
        confirmer.allow()
        let result = try await confirmation.value
        XCTAssertEqual(result, .stale)
        let current = try XCTUnwrap(workspace.document(in: pane))
        XCTAssertTrue(current.hasUnsavedChanges)
        XCTAssertTrue(current.hasUnconfirmedDurability)
        XCTAssertEqual(workspace.retainedDurabilityConfirmationCountForTesting(), 0)
    }

    func testExternalReplacementRefusesDurabilityConfirmation() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Note.md")
        let replacement = directory.appendingPathComponent("Replacement.md")
        try Data("disk".utf8).write(to: file)
        let committer = DurabilityDocumentCommitter()
        let workspace = makeWorkspace(
            documentIO: LocalDocumentIO(maximumConcurrent: 1) { request, cancellationCheck in
                try committer.commit(request, cancellationCheck: cancellationCheck)
            })
        let pane = workspace.focusedPane
        try workspace.open(file, in: pane)
        let documentID = try XCTUnwrap(workspace.document(in: pane)?.id)
        XCTAssertTrue(workspace.updateText("saved", in: pane))
        _ = try await workspace.saveWithOutcome(document: documentID)
        try Data("external".utf8).write(to: replacement)
        XCTAssertEqual(Darwin.rename(replacement.path, file.path), 0)

        await XCTAssertThrowsErrorAsync(
            try await workspace.confirmDurability(document: documentID))
        XCTAssertTrue(workspace.document(in: pane)?.hasUnconfirmedDurability == true)
        XCTAssertEqual(workspace.retainedDurabilityConfirmationCountForTesting(), 0)
    }

    func testDurabilityAuthorityCapKeepsEveryDocumentInReviewAndLaterSaveRepairsOverflow() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let committer = SwitchableDurabilityDocumentCommitter()
        let workspace = makeWorkspace(
            documentIO: LocalDocumentIO(maximumConcurrent: 1) { request, cancellationCheck in
                try committer.commit(request, cancellationCheck: cancellationCheck)
            })
        let pane = workspace.focusedPane
        var documentIDs: [OpenDocument.ID] = []
        for index in 0...Workspace.maximumRetainedDurabilityConfirmations {
            let file = directory.appendingPathComponent("\(index).md")
            try Data("disk".utf8).write(to: file)
            try workspace.open(file, in: pane)
            let documentID = try XCTUnwrap(workspace.document(in: pane)?.id)
            documentIDs.append(documentID)
            XCTAssertTrue(workspace.updateText("saved-\(index)", in: pane))
            _ = try await workspace.saveWithOutcome(document: documentID)
        }

        XCTAssertEqual(
            workspace.retainedDurabilityConfirmationCountForTesting(),
            Workspace.maximumRetainedDurabilityConfirmations)
        XCTAssertEqual(workspace.documentsRequiringCloseReview.count, documentIDs.count)
        let overflowID = try XCTUnwrap(documentIDs.last)
        let unavailable = try await workspace.confirmDurability(document: overflowID)
        XCTAssertEqual(unavailable, .authorityUnavailable)

        committer.useFullySyncedReceipts()
        let repaired = try await workspace.saveWithOutcome(document: overflowID)
        XCTAssertTrue(repaired.isFullyDurable)
        let repairedDocument = try XCTUnwrap(
            workspace.state(for: pane).documents.first { $0.id == overflowID })
        XCTAssertFalse(repairedDocument.hasUnconfirmedDurability)
        XCTAssertEqual(
            workspace.documentsRequiringCloseReview.count,
            documentIDs.count - 1)
    }

    func testCommittedSaveReportsDocumentClosedWithoutResurrectingIt() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Note.md")
        try Data("disk".utf8).write(to: file)
        let key = try LocalDocumentIO.authorizeSaveAsSynchronously(
            file,
            overwrite: true).destinationKey
        let registry = ProcessFileTransactionRegistry()
        let committer = PostCommitBlockingDocumentCommitter()
        let workspace = makeWorkspace(
            documentIO: LocalDocumentIO(maximumConcurrent: 1) { request, cancellationCheck in
                try committer.commit(request, cancellationCheck: cancellationCheck)
            },
            transactionRegistry: registry)
        let pane = workspace.focusedPane
        try workspace.open(file, in: pane)
        let documentID = try XCTUnwrap(workspace.document(in: pane)?.id)
        XCTAssertTrue(workspace.updateText("published", in: pane))

        let save = Task { try await workspace.saveWithOutcome(document: documentID) }
        XCTAssertTrue(awaitValue: await committer.waitForCommit())
        workspace.close(documentID, in: pane)
        committer.allowSettlement()
        let outcome = try await save.value

        XCTAssertEqual(outcome.settlement, .documentClosed)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "published")
        XCTAssertFalse(workspace.state(for: pane).documents.contains { $0.id == documentID })
        XCTAssertEqual(workspace.activeSaveCountForTesting(documentID: documentID), 0)
        guard case .reusable(_, _, nil) = registry.entryForTesting(destinationKey: key) else {
            return XCTFail("closed UI owner erased exact filesystem recovery authority")
        }
    }

    func testPublishedButUnsettledSaveNeverEmitsOrdinarySuccessDiagnostic() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Note.md")
        try Data("disk".utf8).write(to: file)
        let center = DiagnosticsCenter(
            configuration: DiagnosticsConfiguration(
                memoryEventLimit: 16,
                memoryByteLimit: 64 * 1_024,
                supportReportByteLimit: 64 * 1_024))
        let emitter = DiagnosticsEmitter(center: center)
        let committer = PostCommitBlockingDocumentCommitter()
        let workspace = makeWorkspace(
            diagnostics: emitter,
            documentIO: LocalDocumentIO(maximumConcurrent: 1) { request, cancellationCheck in
                try committer.commit(request, cancellationCheck: cancellationCheck)
            })
        let pane = workspace.focusedPane
        try workspace.open(file, in: pane)
        let documentID = try XCTUnwrap(workspace.document(in: pane)?.id)
        XCTAssertTrue(workspace.updateText("published", in: pane))

        let save = Task { try await workspace.saveWithOutcome(document: documentID) }
        XCTAssertTrue(awaitValue: await committer.waitForCommit())
        workspace.close(documentID, in: pane)
        committer.allowSettlement()
        let outcome = try await save.value
        XCTAssertEqual(outcome.settlement, .documentClosed)
        await emitter.flush()

        let snapshot = await center.snapshot()
        XCTAssertFalse(snapshot.events.contains { $0.code == .workspaceSaveSucceeded })
        let event = try XCTUnwrap(snapshot.events.last)
        XCTAssertEqual(event.code, .workspaceSaveFailed)
        XCTAssertEqual(event.severity, .warning)
        XCTAssertEqual(event.metadata[.droppedCount], .integer(1))
    }

    func testCommittedSaveReportsSourceChangedAfterReloadWithoutOverwritingLiveAuthority() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Note.md")
        try Data("disk".utf8).write(to: file)
        let key = try LocalDocumentIO.authorizeSaveAsSynchronously(
            file,
            overwrite: true).destinationKey
        let registry = ProcessFileTransactionRegistry()
        let committer = PostCommitBlockingDocumentCommitter()
        let workspace = makeWorkspace(
            documentIO: LocalDocumentIO(maximumConcurrent: 1) { request, cancellationCheck in
                try committer.commit(request, cancellationCheck: cancellationCheck)
            },
            transactionRegistry: registry)
        let pane = workspace.focusedPane
        try workspace.open(file, in: pane)
        let documentID = try XCTUnwrap(workspace.document(in: pane)?.id)
        XCTAssertTrue(workspace.updateText("published", in: pane))

        let save = Task { try await workspace.saveWithOutcome(document: documentID) }
        XCTAssertTrue(awaitValue: await committer.waitForCommit())
        let current = try XCTUnwrap(workspace.document(in: pane))
        XCTAssertTrue(workspace.replace(document: current.reloaded(from: "reloaded")))
        committer.allowSettlement()
        let outcome = try await save.value

        XCTAssertEqual(outcome.settlement, .sourceChanged)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "published")
        XCTAssertEqual(workspace.document(in: pane)?.text, "reloaded")
        XCTAssertEqual(workspace.activeSaveCountForTesting(documentID: documentID), 0)
        guard case .reusable(_, _, nil) = registry.entryForTesting(destinationKey: key) else {
            return XCTFail("source rebase erased exact filesystem recovery authority")
        }
    }

    func testCommittedSaveReportsDestinationCollisionWithoutRetargetingSource() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Source.md")
        let other = directory.appendingPathComponent("Other.md")
        let destination = directory.appendingPathComponent("Destination.md")
        try Data("source".utf8).write(to: source)
        try Data("other".utf8).write(to: other)
        try Data("destination".utf8).write(to: destination)
        let key = try LocalDocumentIO.authorizeSaveAsSynchronously(
            destination,
            overwrite: true).destinationKey
        let registry = ProcessFileTransactionRegistry()
        let committer = PostCommitBlockingDocumentCommitter()
        let workspace = makeWorkspace(
            documentIO: LocalDocumentIO(maximumConcurrent: 1) { request, cancellationCheck in
                try committer.commit(request, cancellationCheck: cancellationCheck)
            },
            transactionRegistry: registry)
        let pane = workspace.focusedPane
        try workspace.open(source, in: pane)
        let sourceID = try XCTUnwrap(workspace.document(in: pane)?.id)
        try workspace.open(other, in: pane)
        let otherID = try XCTUnwrap(workspace.document(in: pane)?.id)
        workspace.select(sourceID, in: pane)
        XCTAssertTrue(workspace.updateText("published", in: pane))

        let save = Task {
            try await workspace.saveWithOutcome(
                document: sourceID, to: destination, overwrite: true)
        }
        XCTAssertTrue(awaitValue: await committer.waitForCommit())
        let otherDocument = try XCTUnwrap(
            workspace.state(for: pane).documents.first { $0.id == otherID })
        XCTAssertTrue(workspace.replace(document: otherDocument.retargeted(to: destination)))
        committer.allowSettlement()
        let outcome = try await save.value

        XCTAssertEqual(outcome.settlement, .destinationCollision)
        let sourceDocument = try XCTUnwrap(
            workspace.state(for: pane).documents.first { $0.id == sourceID })
        XCTAssertEqual(sourceDocument.url, source)
        XCTAssertTrue(sourceDocument.hasUnsavedChanges)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "published")
        XCTAssertEqual(workspace.activeSaveCountForTesting(documentID: sourceID), 0)
        guard case .reusable(_, _, nil) = registry.entryForTesting(destinationKey: key) else {
            return XCTFail("destination collision erased exact filesystem recovery authority")
        }
    }

    func testAutosaveReportPartitionsEveryCountAndByteExactly() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = makeWorkspace(
            documentIO: LocalDocumentIO(maximumConcurrent: 1) { request, cancellationCheck in
                try ClassifyingDocumentCommitter().commit(
                    request, cancellationCheck: cancellationCheck)
            })
        let pane = workspace.focusedPane
        let inputs = ["ok", "conflict", "fail", "cancel"]
        var urls: [URL] = []
        for (index, text) in inputs.enumerated() {
            let url = directory.appendingPathComponent("\(index).md")
            try Data("base".utf8).write(to: url)
            try workspace.open(url, in: pane)
            XCTAssertTrue(workspace.updateText(text, in: pane))
            urls.append(url)
        }
        let replacement = directory.appendingPathComponent("Replacement.md")
        try Data("base".utf8).write(to: replacement)
        XCTAssertEqual(Darwin.rename(replacement.path, urls[1].path), 0)

        let report = await workspace.autosaveAsync()

        XCTAssertEqual(report.consideredCount, 4)
        XCTAssertEqual(report.attemptedCount, 4)
        XCTAssertEqual(report.succeededCount, 1)
        XCTAssertEqual(report.conflictCount, 1)
        XCTAssertEqual(report.failureCount, 1)
        XCTAssertEqual(report.cancelledCount, 1)
        XCTAssertEqual(report.deferredCount, 0)
        XCTAssertEqual(report.consideredBytes, 20)
        XCTAssertEqual(report.attemptedBytes, 20)
        XCTAssertEqual(report.succeededBytes, 2)
        XCTAssertEqual(report.conflictBytes, 8)
        XCTAssertEqual(report.failureBytes, 4)
        XCTAssertEqual(report.cancelledBytes, 6)
        XCTAssertEqual(report.deferredBytes, 0)
        XCTAssertEqual(
            report.consideredCount,
            report.succeededCount + report.conflictCount + report.failureCount
                + report.cancelledCount + report.deferredCount)
        XCTAssertEqual(
            report.consideredBytes,
            report.succeededBytes + report.conflictBytes + report.failureBytes
                + report.cancelledBytes + report.deferredBytes)
    }

    func testAutosaveExactDocumentLimitReportsOneDeferredDocumentAndBytes() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = makeWorkspace(documentIO: LocalDocumentIO(maximumConcurrent: 1))
        let pane = workspace.focusedPane
        for index in 0..<17 {
            let url = directory.appendingPathComponent("\(index).md")
            try Data("x".utf8).write(to: url)
            try workspace.open(url, in: pane)
            XCTAssertTrue(workspace.updateText("yy", in: pane))
        }

        let report = await workspace.autosaveAsync()

        XCTAssertEqual(report.consideredCount, 17)
        XCTAssertEqual(report.attemptedCount, 16)
        XCTAssertEqual(report.succeededCount, 16)
        XCTAssertEqual(report.deferredCount, 1)
        XCTAssertEqual(report.consideredBytes, 34)
        XCTAssertEqual(report.attemptedBytes, 32)
        XCTAssertEqual(report.succeededBytes, 32)
        XCTAssertEqual(report.deferredBytes, 2)
    }

    func testManualSaveSupersedesPendingAutosaveAndRunsBeforeOtherAutosaves() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blockerFile = directory.appendingPathComponent("Blocker.md")
        let targetFile = directory.appendingPathComponent("Target.md")
        try Data("blocker".utf8).write(to: blockerFile)
        try Data("target".utf8).write(to: targetFile)
        let recorder = RecordingDocumentCommitter()
        let io = LocalDocumentIO(maximumConcurrent: 1) { request, cancellationCheck in
            try recorder.commit(request, cancellationCheck: cancellationCheck)
        }
        let blockerAuthorization = try await io.authorizeSaveAs(
            blockerFile, overwrite: true)
        let targetAuthorization = try await io.authorizeSaveAs(targetFile, overwrite: true)
        let blockerID = UUID()
        let targetID = UUID()
        let blocker = Task {
            try await io.commit(
                LocalDocumentSaveRequest(
                    documentID: blockerID,
                    authorization: blockerAuthorization,
                    data: Data("blocker".utf8)),
                priority: .manual)
        }
        let entered = await recorder.waitForFirstEntry()
        XCTAssertTrue(entered)
        let autosave = Task {
            try await io.commit(
                LocalDocumentSaveRequest(
                    documentID: targetID,
                    authorization: targetAuthorization,
                    data: Data("autosave".utf8)),
                priority: .autosave)
        }
        let autosaveQueued = await waitUntilPendingJobCount(io, equals: 1)
        XCTAssertTrue(autosaveQueued)
        let manual = Task {
            try await io.commit(
                LocalDocumentSaveRequest(
                    documentID: targetID,
                    authorization: targetAuthorization,
                    data: Data("manual".utf8)),
                priority: .manual)
        }
        let manualQueued = await waitUntilPendingJobCount(io, equals: 1)
        XCTAssertTrue(manualQueued)
        recorder.allowFirst()

        _ = try await blocker.value
        _ = try await manual.value
        await XCTAssertThrowsErrorAsync(try await autosave.value)
        XCTAssertEqual(recorder.observedPayloads, ["blocker", "manual"])
    }

    func testSecondManualSaveWaitsThenReauthorizesFromFirstReceipt() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Note.md")
        try Data("disk".utf8).write(to: file)
        let blocker = BlockingDocumentCommitter()
        let workspace = makeWorkspace(
            documentIO: LocalDocumentIO(maximumConcurrent: 2) { request, cancellationCheck in
                try blocker.commit(request, cancellationCheck: cancellationCheck)
            })
        let pane = workspace.focusedPane
        try workspace.open(file, in: pane)
        let documentID = try XCTUnwrap(workspace.document(in: pane)?.id)
        XCTAssertTrue(workspace.updateText("first", in: pane))
        let first = Task {
            try await workspace.saveWithOutcome(document: documentID)
        }
        let entered = await blocker.waitForEntry()
        XCTAssertTrue(entered)
        XCTAssertTrue(workspace.updateText("second", in: pane))
        let second = Task {
            try await workspace.saveWithOutcome(document: documentID)
        }
        await Task.yield()
        blocker.allowAllFutureCommits()

        let firstOutcome = try await first.value
        let secondOutcome = try await second.value
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "second")
        XCTAssertEqual(blocker.observedPayloads, ["first", "second"])
        XCTAssertEqual(blocker.observedMaximumActiveCount, 1)
        XCTAssertEqual(firstOutcome.byteCount, 5)
        XCTAssertEqual(secondOutcome.byteCount, 6)
        let receiptVersions = blocker.observedReceiptVersions
        XCTAssertEqual(receiptVersions.count, 2)
        let firstReceiptVersion = try XCTUnwrap(receiptVersions.first ?? nil)
        let expectations = blocker.observedExpectations
        XCTAssertEqual(expectations.count, 2)
        XCTAssertEqual(
            expectations[1],
            .exact(firstReceiptVersion),
            "save two must authorize from save one's committed receipt")
    }

    func testIdenticalManualSaveCallersCoalesceAndOneCancellationDoesNotCancelSharedWork()
        async throws
    {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Note.md")
        try Data("disk".utf8).write(to: file)
        let blocker = BlockingDocumentCommitter()
        let workspace = makeWorkspace(
            documentIO: LocalDocumentIO(maximumConcurrent: 1) { request, cancellationCheck in
                try blocker.commit(request, cancellationCheck: cancellationCheck)
            })
        let pane = workspace.focusedPane
        try workspace.open(file, in: pane)
        let documentID = try XCTUnwrap(workspace.document(in: pane)?.id)
        XCTAssertTrue(workspace.updateText("shared", in: pane))

        let first = Task { try await workspace.saveWithOutcome(document: documentID) }
        XCTAssertTrue(awaitValue: await blocker.waitForEntry())
        let second = Task { try await workspace.saveWithOutcome(document: documentID) }
        for _ in 0..<16 { await Task.yield() }
        first.cancel()
        for _ in 0..<16 { await Task.yield() }
        blocker.allowAllFutureCommits()

        await XCTAssertThrowsErrorAsync(try await first.value)
        let outcome = try await second.value
        XCTAssertEqual(outcome.settlement, .applied)
        XCTAssertEqual(blocker.observedPayloads, ["shared"])
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "shared")
        XCTAssertFalse(workspace.document(in: pane)?.hasUnsavedChanges == true)
    }

    func testSoleCallerCancellationAfterPublicationReturnsCommittedOutcome() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Note.md")
        try Data("disk".utf8).write(to: file)
        let destinationKey = try LocalDocumentIO.authorizeSaveAsSynchronously(
            file,
            overwrite: true).destinationKey
        let registry = ProcessFileTransactionRegistry()
        let committer = PostCommitBlockingDocumentCommitter()
        let workspace = makeWorkspace(
            documentIO: LocalDocumentIO(maximumConcurrent: 1) { request, cancellationCheck in
                try committer.commit(request, cancellationCheck: cancellationCheck)
            },
            transactionRegistry: registry)
        let pane = workspace.focusedPane
        try workspace.open(file, in: pane)
        let documentID = try XCTUnwrap(workspace.document(in: pane)?.id)
        XCTAssertTrue(workspace.updateText("published", in: pane))

        let save = Task { try await workspace.saveWithOutcome(document: documentID) }
        XCTAssertTrue(awaitValue: await committer.waitForCommit())
        save.cancel()
        XCTAssertTrue(
            awaitValue: await waitUntilActiveSaveWaiterCount(
                workspace,
                documentID: documentID,
                equals: 0))
        committer.allowSettlement()

        let outcome = try await save.value
        XCTAssertEqual(outcome.settlement, .applied)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "published")
        let document = try XCTUnwrap(workspace.document(in: pane))
        XCTAssertEqual(document.text, "published")
        XCTAssertFalse(document.hasUnsavedChanges)
        guard case .reusable(_, _, let owner) = registry.entryForTesting(
            destinationKey: destinationKey)
        else {
            return XCTFail("a committed save must retain exact recovery authority")
        }
        XCTAssertNotNil(owner)
    }

    func testOrderedDoubleCancellationDetachesFirstAndReturnsCommitToLastOwner() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Note.md")
        try Data("disk".utf8).write(to: file)
        let committer = PostCommitBlockingDocumentCommitter()
        let workspace = makeWorkspace(
            documentIO: LocalDocumentIO(maximumConcurrent: 1) { request, cancellationCheck in
                try committer.commit(request, cancellationCheck: cancellationCheck)
            },
            transactionRegistry: ProcessFileTransactionRegistry())
        let pane = workspace.focusedPane
        try workspace.open(file, in: pane)
        let documentID = try XCTUnwrap(workspace.document(in: pane)?.id)
        XCTAssertTrue(workspace.updateText("published", in: pane))

        let first = Task { try await workspace.saveWithOutcome(document: documentID) }
        XCTAssertTrue(awaitValue: await committer.waitForCommit())
        let last = Task { try await workspace.saveWithOutcome(document: documentID) }
        XCTAssertTrue(
            awaitValue: await waitUntilActiveSaveWaiterCount(
                workspace,
                documentID: documentID,
                equals: 2))

        first.cancel()
        XCTAssertTrue(
            awaitValue: await waitUntilActiveSaveWaiterCount(
                workspace,
                documentID: documentID,
                equals: 1))
        last.cancel()
        XCTAssertTrue(
            awaitValue: await waitUntilActiveSaveWaiterCount(
                workspace,
                documentID: documentID,
                equals: 0))
        committer.allowSettlement()

        do {
            _ = try await first.value
            XCTFail("the first canceled caller must remain detached")
        } catch is CancellationError {
            // Expected: another request still owned the operation when this
            // request's cancellation linearized.
        }
        let outcome = try await last.value
        XCTAssertEqual(outcome.settlement, .applied)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "published")
        XCTAssertFalse(workspace.document(in: pane)?.hasUnsavedChanges == true)
    }

    func testDetachedCancellationMasksSharedFailureOnlyForCancelledCaller() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Note.md")
        try Data("disk".utf8).write(to: file)
        let committer = UnknownFailingDocumentCommitter()
        let workspace = makeWorkspace(
            documentIO: LocalDocumentIO(maximumConcurrent: 1) { request, cancellationCheck in
                try committer.commit(request, cancellationCheck: cancellationCheck)
            },
            transactionRegistry: ProcessFileTransactionRegistry())
        let pane = workspace.focusedPane
        try workspace.open(file, in: pane)
        let documentID = try XCTUnwrap(workspace.document(in: pane)?.id)
        XCTAssertTrue(workspace.updateText("shared", in: pane))

        let cancelled = Task { try await workspace.saveWithOutcome(document: documentID) }
        XCTAssertTrue(awaitValue: await committer.waitForFirstEntry())
        let survivor = Task { try await workspace.saveWithOutcome(document: documentID) }
        XCTAssertTrue(
            awaitValue: await waitUntilActiveSaveWaiterCount(
                workspace,
                documentID: documentID,
                equals: 2))
        cancelled.cancel()
        XCTAssertTrue(
            awaitValue: await waitUntilActiveSaveWaiterCount(
                workspace,
                documentID: documentID,
                equals: 1))
        committer.allowFailure()

        do {
            _ = try await cancelled.value
            XCTFail("a detached canceled caller must receive cancellation")
        } catch is CancellationError {
            // Expected.
        }
        do {
            _ = try await survivor.value
            XCTFail("the live owner must receive the shared operation failure")
        } catch is UnknownCommitFailure {
            // Expected.
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "disk")
        XCTAssertTrue(workspace.document(in: pane)?.hasUnsavedChanges == true)
    }

    func testJoinedCancellationRemainsDetachedWhenDocumentClosesBeforeActorYield()
        async throws
    {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Note.md")
        try Data("disk".utf8).write(to: file)
        let committer = PostCommitBlockingDocumentCommitter()
        let workspace = makeWorkspace(
            documentIO: LocalDocumentIO(maximumConcurrent: 1) { request, cancellationCheck in
                try committer.commit(request, cancellationCheck: cancellationCheck)
            },
            transactionRegistry: ProcessFileTransactionRegistry())
        let pane = workspace.focusedPane
        try workspace.open(file, in: pane)
        let documentID = try XCTUnwrap(workspace.document(in: pane)?.id)
        XCTAssertTrue(workspace.updateText("published", in: pane))

        let owner = Task { try await workspace.saveWithOutcome(document: documentID) }
        XCTAssertTrue(awaitValue: await committer.waitForCommit())
        let joined = Task { try await workspace.saveWithOutcome(document: documentID) }
        XCTAssertTrue(
            awaitValue: await waitUntilActiveSaveWaiterCount(
                workspace,
                documentID: documentID,
                equals: 2))

        joined.cancel()
        workspace.close(documentID, in: pane)
        committer.allowSettlement()

        do {
            _ = try await joined.value
            XCTFail("closing the document must not erase a joined caller's cancellation role")
        } catch is CancellationError {
            // Expected.
        }
        let outcome = try await owner.value
        XCTAssertEqual(outcome.settlement, .documentClosed)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "published")
        XCTAssertFalse(workspace.state(for: pane).documents.contains { $0.id == documentID })
    }

    func testPromotedCallerCancellationRemainsDetachedWhenDocumentClosesBeforeActorYield()
        async throws
    {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Note.md")
        try Data("disk".utf8).write(to: file)
        let committer = FailThenPostCommitBlockingDocumentCommitter()
        let workspace = makeWorkspace(
            documentIO: LocalDocumentIO(maximumConcurrent: 1) { request, cancellationCheck in
                try committer.commit(request, cancellationCheck: cancellationCheck)
            },
            transactionRegistry: ProcessFileTransactionRegistry())
        let pane = workspace.focusedPane
        try workspace.open(file, in: pane)
        let documentID = try XCTUnwrap(workspace.document(in: pane)?.id)
        XCTAssertTrue(workspace.updateText("first", in: pane))

        let first = Task { try await workspace.saveWithOutcome(document: documentID) }
        XCTAssertTrue(awaitValue: await committer.waitForFirstEntry())
        XCTAssertTrue(workspace.updateText("published", in: pane))
        let promoted = Task { try await workspace.saveWithOutcome(document: documentID) }
        XCTAssertTrue(
            awaitValue: await waitUntilPendingManualSaveCount(
                workspace,
                documentID: documentID,
                equals: 1))
        committer.allowFirstFailure()
        await XCTAssertThrowsErrorAsync(try await first.value)
        XCTAssertTrue(awaitValue: await committer.waitForSecondCommit())

        let joined = Task { try await workspace.saveWithOutcome(document: documentID) }
        XCTAssertTrue(
            awaitValue: await waitUntilActiveSaveWaiterCount(
                workspace,
                documentID: documentID,
                equals: 2))
        promoted.cancel()
        workspace.close(documentID, in: pane)
        committer.allowSecondSettlement()

        do {
            _ = try await promoted.value
            XCTFail("a promoted caller's cancellation role must survive lifecycle teardown")
        } catch is CancellationError {
            // Expected.
        }
        let outcome = try await joined.value
        XCTAssertEqual(outcome.settlement, .documentClosed)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "published")
        XCTAssertFalse(workspace.state(for: pane).documents.contains { $0.id == documentID })
    }

    func testIdenticalSaveCoalescingHasFiniteWaiterAdmission() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Note.md")
        try Data("disk".utf8).write(to: file)
        let blocker = BlockingDocumentCommitter()
        let workspace = makeWorkspace(
            documentIO: LocalDocumentIO(maximumConcurrent: 1) { request, cancellationCheck in
                try blocker.commit(request, cancellationCheck: cancellationCheck)
            })
        let pane = workspace.focusedPane
        try workspace.open(file, in: pane)
        let documentID = try XCTUnwrap(workspace.document(in: pane)?.id)
        XCTAssertTrue(workspace.updateText("shared", in: pane))

        let first = Task { try await workspace.saveWithOutcome(document: documentID) }
        XCTAssertTrue(awaitValue: await blocker.waitForEntry())
        var admitted: [Task<WorkspaceSaveOutcome, Error>] = []
        for _ in 1..<Workspace.maximumCoalescedSaveWaiters {
            admitted.append(Task { try await workspace.saveWithOutcome(document: documentID) })
        }
        XCTAssertTrue(
            awaitValue: await waitUntilActiveSaveWaiterCount(
                workspace,
                documentID: documentID,
                equals: Workspace.maximumCoalescedSaveWaiters))

        let overflow = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<1_000 {
                group.addTask {
                    do {
                        _ = try await workspace.saveWithOutcome(document: documentID)
                        return false
                    } catch WorkspaceError.ioBusy {
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var refused = 0
            for await wasRefused in group where wasRefused { refused += 1 }
            return refused
        }
        XCTAssertEqual(overflow, 1_000)
        XCTAssertEqual(
            workspace.activeSaveWaiterCountForTesting(documentID: documentID),
            Workspace.maximumCoalescedSaveWaiters)

        blocker.allowAllFutureCommits()
        _ = try await first.value
        for task in admitted { _ = try await task.value }
        XCTAssertEqual(blocker.observedPayloads, ["shared"])
        XCTAssertEqual(workspace.activeSaveWaiterCountForTesting(documentID: documentID), 0)
    }

    func testSameGenerationDifferentSaveAsTargetDoesNotCoalesce() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Source.md")
        let other = directory.appendingPathComponent("Other.md")
        try Data("disk".utf8).write(to: source)
        let blocker = BlockingDocumentCommitter()
        let workspace = makeWorkspace(
            documentIO: LocalDocumentIO(maximumConcurrent: 1) { request, cancellationCheck in
                try blocker.commit(request, cancellationCheck: cancellationCheck)
            })
        let pane = workspace.focusedPane
        try workspace.open(source, in: pane)
        let documentID = try XCTUnwrap(workspace.document(in: pane)?.id)
        XCTAssertTrue(workspace.updateText("shared", in: pane))
        let first = Task { try await workspace.saveWithOutcome(document: documentID) }
        XCTAssertTrue(awaitValue: await blocker.waitForEntry())

        do {
            _ = try await workspace.saveWithOutcome(
                document: documentID, to: other, overwrite: false)
            XCTFail("a distinct destination must not join the active source save")
        } catch WorkspaceError.saveInProgress {
            // Expected bounded refusal.
        }
        blocker.allowAllFutureCommits()
        _ = try await first.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.path))
        XCTAssertEqual(blocker.observedPayloads, ["shared"])
    }

    func testNewerPendingManualSaveSurvivesActiveCallerCancellationBeforePublication()
        async throws
    {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Note.md")
        try Data("disk".utf8).write(to: file)
        let blocker = BlockingDocumentCommitter()
        let workspace = makeWorkspace(
            documentIO: LocalDocumentIO(maximumConcurrent: 1) { request, cancellationCheck in
                try blocker.commit(request, cancellationCheck: cancellationCheck)
            })
        let pane = workspace.focusedPane
        try workspace.open(file, in: pane)
        let documentID = try XCTUnwrap(workspace.document(in: pane)?.id)
        XCTAssertTrue(workspace.updateText("first", in: pane))
        let first = Task { try await workspace.saveWithOutcome(document: documentID) }
        XCTAssertTrue(awaitValue: await blocker.waitForEntry())
        XCTAssertTrue(workspace.updateText("latest", in: pane))
        let latest = Task { try await workspace.saveWithOutcome(document: documentID) }
        XCTAssertTrue(
            awaitValue: await waitUntilPendingManualSaveCount(
                workspace, documentID: documentID, equals: 1))

        first.cancel()
        for _ in 0..<16 { await Task.yield() }
        blocker.allowAllFutureCommits()

        await XCTAssertThrowsErrorAsync(try await first.value)
        let outcome = try await latest.value
        XCTAssertEqual(outcome.settlement, .applied)
        XCTAssertEqual(blocker.observedPayloads, ["first", "latest"])
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "latest")
        XCTAssertFalse(workspace.document(in: pane)?.hasUnsavedChanges == true)
    }

    func testNewerSaveAsRunsAfterKnownPrepublicationSourceSaveFailure() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Source.md")
        let destination = directory.appendingPathComponent("Healthy.md")
        try Data("disk".utf8).write(to: source)
        let committer = FailFirstThenCommitDocumentCommitter()
        let workspace = makeWorkspace(
            documentIO: LocalDocumentIO(maximumConcurrent: 1) { request, cancellationCheck in
                try committer.commit(request, cancellationCheck: cancellationCheck)
            })
        let pane = workspace.focusedPane
        try workspace.open(source, in: pane)
        let documentID = try XCTUnwrap(workspace.document(in: pane)?.id)
        XCTAssertTrue(workspace.updateText("first", in: pane))
        let first = Task { try await workspace.saveWithOutcome(document: documentID) }
        XCTAssertTrue(awaitValue: await committer.waitForFirstEntry())

        XCTAssertTrue(workspace.updateText("latest", in: pane))
        let latest = Task {
            try await workspace.saveWithOutcome(
                document: documentID, to: destination, overwrite: false)
        }
        XCTAssertTrue(
            awaitValue: await waitUntilPendingManualSaveCount(
                workspace, documentID: documentID, equals: 1))
        committer.allowFirstFailure()

        await XCTAssertThrowsErrorAsync(try await first.value)
        let outcome = try await latest.value
        XCTAssertEqual(outcome.settlement, .applied)
        XCTAssertEqual(committer.observedPayloads, ["first", "latest"])
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "latest")
        XCTAssertEqual(workspace.document(in: pane)?.url?.standardizedFileURL, destination)
    }

    func testCommitFailurePublicationClassifierIsExhaustiveAndFailsClosed() throws {
        let destination = URL(fileURLWithPath: "/tmp/MarkDev-classifier.md")
        let indeterminateReceipt = FileTransactionReceipt(
            destination: destination,
            version: nil,
            durability: .indeterminate(operation: .publish, errno: EINTR),
            recovery: nil)
        let prepublicationReceipt = FileTransactionReceipt(
            destination: destination,
            version: nil,
            durability: .notPublishedRecoveryUnconfirmed(
                operation: .verify,
                errno: nil),
            recovery: nil)
        let malformedPrepublicationReceipt = FileTransactionReceipt(
            destination: destination,
            version: nil,
            durability: .indeterminate(operation: .verify, errno: nil),
            recovery: nil)
        let operations: [SecureLocalFileOperation] = [
            .openDirectory, .inspect, .openTarget, .createStage, .truncate,
            .seek, .write, .metadata, .syncFile, .publish, .verify,
            .syncDirectory,
        ]
        let knownNoPublication: [Error] = [
            CancellationError(),
            LocalDocumentIOError.busy,
            LocalDocumentIOError.destinationExists,
            LocalDocumentIOError.superseded,
            SecureLocalFileError.invalidComponent,
            SecureLocalFileError.unsupportedEntry,
            SecureLocalFileError.fileTooLarge(maximumBytes: 1),
            SecureLocalFileError.hardLinkedEntry,
            SecureLocalFileError.unsupportedFileMode(mode_t(S_ISUID)),
            SecureLocalFileError.unsupportedFileFlags(UInt32(UF_IMMUTABLE)),
            SecureLocalFileError.expectationMismatch,
            SecureLocalFileError.cancelled,
            SecureLocalFileError.prepublicationFailure(
                cause: .operation(.write, errno: EIO),
                receipt: prepublicationReceipt),
        ] + operations.map { SecureLocalFileError.operation($0, errno: EIO) }

        for error in knownNoPublication {
            XCTAssertTrue(
                Workspace.failureIsKnownNotPublished(error),
                "known pre-publication failure was refused: \(error)")
        }
        XCTAssertFalse(Workspace.failureIsKnownNotPublished(UnknownCommitFailure.injected))
        XCTAssertFalse(
            Workspace.failureIsKnownNotPublished(
                SecureLocalFileError.indeterminate(indeterminateReceipt)))
        XCTAssertFalse(
            Workspace.failureIsKnownNotPublished(
                SecureLocalFileError.prepublicationFailure(
                    cause: .operation(.write, errno: EIO),
                    receipt: malformedPrepublicationReceipt)))
        XCTAssertFalse(
            Workspace.failureIsKnownNotPublished(
                WorkspaceError.savePublishedButNotSettled(
                    destination, .sourceChanged)))
    }

    func testUnknownActiveFailureDoesNotPromotePendingSave() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Source.md")
        let destination = directory.appendingPathComponent("Destination.md")
        try Data("disk".utf8).write(to: source)
        let committer = UnknownFailingDocumentCommitter()
        let workspace = makeWorkspace(
            documentIO: LocalDocumentIO(maximumConcurrent: 1) { request, cancellationCheck in
                try committer.commit(request, cancellationCheck: cancellationCheck)
            })
        let pane = workspace.focusedPane
        try workspace.open(source, in: pane)
        let documentID = try XCTUnwrap(workspace.document(in: pane)?.id)
        XCTAssertTrue(workspace.updateText("first", in: pane))
        let first = Task { try await workspace.saveWithOutcome(document: documentID) }
        XCTAssertTrue(awaitValue: await committer.waitForFirstEntry())
        XCTAssertTrue(workspace.updateText("latest", in: pane))
        let pending = Task {
            try await workspace.saveWithOutcome(
                document: documentID,
                to: destination,
                overwrite: false)
        }
        XCTAssertTrue(
            awaitValue: await waitUntilPendingManualSaveCount(
                workspace,
                documentID: documentID,
                equals: 1))

        committer.allowFailure()
        await XCTAssertThrowsErrorAsync(try await first.value)
        await XCTAssertThrowsErrorAsync(try await pending.value)
        XCTAssertEqual(committer.observedPayloads, ["first"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testOpeningOriginalDuringItsSaveSharesReservationOwner() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Note.md")
        try Data("disk".utf8).write(to: file)
        let blocker = BlockingDocumentCommitter()
        let workspace = makeWorkspace(
            documentIO: LocalDocumentIO(maximumConcurrent: 1) { request, cancellationCheck in
                try blocker.commit(request, cancellationCheck: cancellationCheck)
            })
        let pane = workspace.focusedPane
        try workspace.open(file, in: pane)
        let documentID = try XCTUnwrap(workspace.document(in: pane)?.id)
        XCTAssertTrue(workspace.updateText("saved", in: pane))
        let save = Task { try await workspace.saveWithOutcome(document: documentID) }
        XCTAssertTrue(awaitValue: await blocker.waitForEntry())

        var adjacent: PaneID?
        do {
            adjacent = try workspace.open(file, beside: pane)
        } catch {
            XCTFail("the reservation owner must remain openable: \(error)")
        }
        if let adjacent {
            XCTAssertEqual(workspace.document(in: adjacent)?.id, documentID)
        }
        blocker.allowAllFutureCommits()
        _ = try await save.value
    }

    func testAuthoritativeLoadedIdentitySelectsExistingDocumentWithoutDuplicate() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let requested = directory.appendingPathComponent("Requested.md")
        let alreadyOpen = directory.appendingPathComponent("AlreadyOpen.md")
        try Data("requested".utf8).write(to: requested)
        try Data("authoritative".utf8).write(to: alreadyOpen)
        let authoritative = try workspaceReadSnapshot(at: alreadyOpen)
        let workspace = makeWorkspace(
            documentIO: LocalDocumentIO(),
            documentRead: { url, maximumBytes in
                if url.standardizedFileURL == requested.standardizedFileURL {
                    return authoritative
                }
                return try workspaceReadSnapshot(at: url, maximumBytes: maximumBytes)
            })
        let pane = workspace.focusedPane
        try workspace.open(alreadyOpen, in: pane)
        let existingID = try XCTUnwrap(workspace.document(in: pane)?.id)

        let adjacent = try workspace.open(requested, beside: pane)

        XCTAssertEqual(workspace.document(in: adjacent)?.id, existingID)
        XCTAssertEqual(workspace.document(in: adjacent)?.text, "authoritative")
    }

    func testSameOpenPathWithReplacedIdentityRefusesStaleDocumentAuthority() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Note.md")
        let replacement = directory.appendingPathComponent("Replacement.md")
        try Data("before".utf8).write(to: file)
        let workspace = makeWorkspace(documentIO: LocalDocumentIO())
        let pane = workspace.focusedPane
        try workspace.open(file, in: pane)
        let originalID = try XCTUnwrap(workspace.document(in: pane)?.id)
        try Data("external".utf8).write(to: replacement)
        XCTAssertEqual(Darwin.rename(replacement.path, file.path), 0)

        XCTAssertThrowsError(try workspace.open(file, in: pane)) { error in
            guard case WorkspaceError.documentChangedOnDisk(let changed) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(changed.standardizedFileURL, file.standardizedFileURL)
        }
        XCTAssertEqual(workspace.document(in: pane)?.id, originalID)
        XCTAssertEqual(workspace.document(in: pane)?.text, "before")
    }

    func testAuthoritativeLoadedIdentityCannotBypassSaveDestinationReservation() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Source.md")
        let requested = directory.appendingPathComponent("Requested.md")
        let reserved = directory.appendingPathComponent("Reserved.md")
        try Data("source".utf8).write(to: source)
        try Data("requested".utf8).write(to: requested)
        try Data("reserved".utf8).write(to: reserved)
        let authoritative = try workspaceReadSnapshot(at: reserved)
        let blocker = BlockingDocumentCommitter()
        let workspace = makeWorkspace(
            documentIO: LocalDocumentIO(maximumConcurrent: 1) { request, cancellationCheck in
                try blocker.commit(request, cancellationCheck: cancellationCheck)
            },
            documentRead: { url, maximumBytes in
                if url.standardizedFileURL == requested.standardizedFileURL {
                    return authoritative
                }
                return try workspaceReadSnapshot(at: url, maximumBytes: maximumBytes)
            })
        let pane = workspace.focusedPane
        try workspace.open(source, in: pane)
        let documentID = try XCTUnwrap(workspace.document(in: pane)?.id)
        XCTAssertTrue(workspace.updateText("saved", in: pane))
        let save = Task {
            try await workspace.saveWithOutcome(
                document: documentID, to: reserved, overwrite: true)
        }
        XCTAssertTrue(awaitValue: await blocker.waitForEntry())

        XCTAssertThrowsError(try workspace.open(requested, beside: pane)) { error in
            guard case WorkspaceError.destinationAlreadyOpen(let destination) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(destination.standardizedFileURL, reserved.standardizedFileURL)
        }

        blocker.allowAllFutureCommits()
        _ = try await save.value
    }

    func testClosingLastSharedPanePrunesDurabilityAuthority() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Note.md")
        try Data("disk".utf8).write(to: file)
        let committer = DurabilityDocumentCommitter()
        let workspace = makeWorkspace(
            documentIO: LocalDocumentIO(maximumConcurrent: 1) { request, cancellationCheck in
                try committer.commit(request, cancellationCheck: cancellationCheck)
            })
        let pane = workspace.focusedPane
        try workspace.open(file, in: pane)
        let documentID = try XCTUnwrap(workspace.document(in: pane)?.id)
        XCTAssertTrue(workspace.updateText("saved", in: pane))
        _ = try await workspace.saveWithOutcome(document: documentID)
        let adjacent = workspace.split(pane, edge: .trailing)

        workspace.close(documentID, in: pane)
        XCTAssertEqual(workspace.retainedDurabilityConfirmationCountForTesting(), 1)
        workspace.closePane(adjacent)
        XCTAssertEqual(workspace.retainedDurabilityConfirmationCountForTesting(), 0)
        XCTAssertFalse(workspace.documentsRequiringCloseReview.contains { $0.id == documentID })
    }

    func testClosingPaneCancelsUniqueActiveAndPendingSavesWithoutPromotion() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sharedFile = directory.appendingPathComponent("Shared.md")
        let uniqueFile = directory.appendingPathComponent("Unique.md")
        try Data("shared".utf8).write(to: sharedFile)
        try Data("disk".utf8).write(to: uniqueFile)
        let blocker = BlockingDocumentCommitter()
        let workspace = makeWorkspace(
            documentIO: LocalDocumentIO(maximumConcurrent: 1) { request, cancellationCheck in
                try blocker.commit(request, cancellationCheck: cancellationCheck)
            })
        let pane = workspace.focusedPane
        try workspace.open(sharedFile, in: pane)
        let adjacent = workspace.split(pane, edge: .trailing)
        try workspace.open(uniqueFile, in: adjacent)
        let documentID = try XCTUnwrap(workspace.document(in: adjacent)?.id)

        XCTAssertTrue(workspace.updateText("first", in: adjacent))
        let first = Task { try await workspace.saveWithOutcome(document: documentID) }
        XCTAssertTrue(awaitValue: await blocker.waitForEntry())
        XCTAssertTrue(workspace.updateText("second", in: adjacent))
        let pending = Task { try await workspace.saveWithOutcome(document: documentID) }
        XCTAssertTrue(
            awaitValue: await waitUntilPendingManualSaveCount(
                workspace, documentID: documentID, equals: 1))

        workspace.closePane(adjacent)
        XCTAssertEqual(workspace.activeSaveCountForTesting(documentID: documentID), 0)
        XCTAssertEqual(workspace.pendingManualSaveCountForTesting(documentID: documentID), 0)

        blocker.allowAllFutureCommits()
        do {
            _ = try await pending.value
            XCTFail("a pending save for a closed document must be cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        await XCTAssertThrowsErrorAsync(try await first.value)
        XCTAssertEqual(blocker.observedPayloads, ["first"])
        XCTAssertEqual(try String(contentsOf: uniqueFile, encoding: .utf8), "disk")
    }

    func testCancelledManualWaiterDoesNotAuthorizeOrCommitAfterActiveSaveFinishes() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Note.md")
        try Data("disk".utf8).write(to: file)
        let blocker = BlockingDocumentCommitter()
        let workspace = makeWorkspace(
            documentIO: LocalDocumentIO(maximumConcurrent: 1) { request, cancellationCheck in
                try blocker.commit(request, cancellationCheck: cancellationCheck)
            })
        let pane = workspace.focusedPane
        try workspace.open(file, in: pane)
        let documentID = try XCTUnwrap(workspace.document(in: pane)?.id)
        XCTAssertTrue(workspace.updateText("first", in: pane))
        let first = Task { try await workspace.saveWithOutcome(document: documentID) }
        let entered = await blocker.waitForEntry()
        XCTAssertTrue(entered)
        XCTAssertTrue(workspace.updateText("second", in: pane))
        let cancelled = Task { try await workspace.saveWithOutcome(document: documentID) }
        let waiting = await waitUntilPendingManualSaveCount(
            workspace, documentID: documentID, equals: 1)
        XCTAssertTrue(waiting)
        cancelled.cancel()
        blocker.allowAllFutureCommits()

        _ = try await first.value
        await XCTAssertThrowsErrorAsync(try await cancelled.value)
        XCTAssertEqual(blocker.observedPayloads, ["first"])
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "first")
        XCTAssertEqual(workspace.document(in: pane)?.text, "second")
        XCTAssertTrue(workspace.document(in: pane)?.hasUnsavedChanges == true)
    }

    func testManualSaveFloodRetainsOnlyOneLatestPendingSnapshot() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Note.md")
        try Data("disk".utf8).write(to: file)
        let blocker = BlockingDocumentCommitter()
        let workspace = makeWorkspace(
            documentIO: LocalDocumentIO(maximumConcurrent: 1) { request, cancellationCheck in
                try blocker.commit(request, cancellationCheck: cancellationCheck)
            })
        let pane = workspace.focusedPane
        try workspace.open(file, in: pane)
        let documentID = try XCTUnwrap(workspace.document(in: pane)?.id)
        XCTAssertTrue(workspace.updateText("first", in: pane))
        let first = Task { try await workspace.saveWithOutcome(document: documentID) }
        XCTAssertTrue(awaitValue: await blocker.waitForEntry())

        XCTAssertTrue(workspace.updateText("second", in: pane))
        let second = Task { try await workspace.saveWithOutcome(document: documentID) }
        XCTAssertTrue(
            awaitValue: await waitUntilPendingManualSaveCount(
                workspace, documentID: documentID, equals: 1))

        let flood = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<1_000 {
                group.addTask {
                    do {
                        _ = try await workspace.saveWithOutcome(document: documentID)
                        return false
                    } catch WorkspaceError.saveInProgress {
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var refused = 0
            for await value in group where value { refused += 1 }
            return refused
        }
        XCTAssertEqual(flood, 1_000)
        XCTAssertEqual(workspace.pendingManualSaveCountForTesting(documentID: documentID), 1)

        XCTAssertTrue(workspace.updateText("latest", in: pane))
        let latest = Task { try await workspace.saveWithOutcome(document: documentID) }
        await XCTAssertThrowsErrorAsync(try await second.value)
        XCTAssertEqual(workspace.pendingManualSaveCountForTesting(documentID: documentID), 1)
        latest.cancel()
        await XCTAssertThrowsErrorAsync(try await latest.value)
        XCTAssertTrue(
            awaitValue: await waitUntilPendingManualSaveCount(
                workspace, documentID: documentID, equals: 0))

        blocker.allowAllFutureCommits()
        _ = try await first.value
        XCTAssertEqual(blocker.observedPayloads, ["first"])
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "first")
        XCTAssertEqual(workspace.document(in: pane)?.text, "latest")
        XCTAssertTrue(workspace.document(in: pane)?.hasUnsavedChanges == true)
        XCTAssertEqual(workspace.pendingManualSaveCountForTesting(documentID: documentID), 0)
        XCTAssertEqual(workspace.activeSaveCountForTesting(documentID: documentID), 0)
    }

    func testSharedAdmissionBoundsCommitAndAuthorizationBacklog() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Note.md")
        try Data("disk".utf8).write(to: file)
        let blocker = AllBlockingDocumentCommitter()
        let io = LocalDocumentIO(
            maximumConcurrent: 2,
            maximumPendingWork: 2
        ) { request, cancellationCheck in
            try blocker.commit(request, cancellationCheck: cancellationCheck)
        }
        let authorization = try await io.authorizeSaveAs(file, overwrite: true)
        func request(_ index: Int) -> LocalDocumentSaveRequest {
            LocalDocumentSaveRequest(
                documentID: UUID(),
                authorization: authorization,
                data: Data("\(index)".utf8))
        }

        let first = Task { try await io.commit(request(1), priority: .manual) }
        XCTAssertTrue(awaitValue: await blocker.waitForEntryCount(1))
        let second = Task { try await io.commit(request(2), priority: .manual) }
        XCTAssertTrue(awaitValue: await blocker.waitForEntryCount(1))
        let third = Task { try await io.commit(request(3), priority: .manual) }
        XCTAssertTrue(awaitValue: await waitUntilPendingJobCount(io, equals: 1))
        let queuedAuthorization = Task {
            try await io.authorizeSaveAs(file, overwrite: true)
        }
        XCTAssertTrue(awaitValue: await waitUntilTotalPendingWork(io, equals: 2))

        let overflowResults = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<1_000 {
                group.addTask {
                    do {
                        _ = try await io.commit(request(10_000 + index), priority: .autosave)
                        return false
                    } catch LocalDocumentIOError.busy {
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var values: [Bool] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(overflowResults.count, 1_000)
        XCTAssertTrue(overflowResults.allSatisfy { $0 })
        let saturated = await io.workCountsForTesting()
        XCTAssertEqual(saturated.active, 2)
        XCTAssertEqual(saturated.pending, 2)

        queuedAuthorization.cancel()
        await XCTAssertThrowsErrorAsync(try await queuedAuthorization.value)
        XCTAssertTrue(awaitValue: await waitUntilTotalPendingWork(io, equals: 1))
        let fourth = Task { try await io.commit(request(4), priority: .manual) }
        XCTAssertTrue(awaitValue: await waitUntilTotalPendingWork(io, equals: 2))
        blocker.allow(4)

        _ = try await first.value
        _ = try await second.value
        _ = try await third.value
        _ = try await fourth.value
        XCTAssertEqual(blocker.observedMaximumActiveCount, 2)
        let drained = await io.workCountsForTesting()
        XCTAssertEqual(drained.active, 0)
        XCTAssertEqual(drained.pending, 0)
    }

    func testQueuedAuthorizationProgressesUnderSustainedManualCommitPressure() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Note.md")
        try Data("disk".utf8).write(to: file)
        let blocker = AllBlockingDocumentCommitter()
        let probe = PreparationGrantProbe()
        let io = LocalDocumentIO(
            maximumConcurrent: 1,
            maximumPendingWork: 16,
            preparationGrantedForTesting: { probe.blockGrantedSlot() }
        ) { request, cancellationCheck in
            try blocker.commit(request, cancellationCheck: cancellationCheck)
        }
        let authorization = try await io.authorizeSaveAs(file, overwrite: true)
        let active = Task {
            try await io.commit(
                LocalDocumentSaveRequest(
                    documentID: UUID(), authorization: authorization, data: Data("0".utf8)),
                priority: .manual)
        }
        XCTAssertTrue(awaitValue: await blocker.waitForEntryCount(1))
        let preparation = Task { try await io.authorizeSaveAs(file, overwrite: true) }
        XCTAssertTrue(awaitValue: await waitUntilTotalPendingWork(io, equals: 1))
        var pressure: [Task<FileTransactionReceipt, Error>] = []
        for index in 1...12 {
            pressure.append(Task {
                try await io.commit(
                    LocalDocumentSaveRequest(
                        documentID: UUID(),
                        authorization: authorization,
                        data: Data("\(index)".utf8)),
                    priority: .manual)
            })
        }
        let pressureWasQueued = await waitUntilTotalPendingWork(io, equals: 13)
        XCTAssertTrue(
            pressureWasQueued,
            "the pressure queue must be present before the active slot is released")

        blocker.allow(1)
        let preparationProgressed = await probe.waitForGrant()
        probe.allow()
        blocker.allow(12)
        _ = try await active.value
        for task in pressure { _ = try await task.value }
        _ = try await preparation.value
        XCTAssertTrue(
            preparationProgressed,
            "manual pressure must not starve a queued destination authorization")
        XCTAssertTrue(awaitValue: await waitUntilWorkCountsDrain(io))
    }

    func testQueuedAutosaveProgressesWithinFiniteManualPriorityBurst() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Note.md")
        try Data("disk".utf8).write(to: file)
        let recorder = RecordingDocumentCommitter()
        let io = LocalDocumentIO(maximumConcurrent: 1, maximumPendingWork: 16) {
            request, cancellationCheck in
            try recorder.commit(request, cancellationCheck: cancellationCheck)
        }
        let authorization = try await io.authorizeSaveAs(file, overwrite: true)
        let active = Task {
            try await io.commit(
                LocalDocumentSaveRequest(
                    documentID: UUID(), authorization: authorization,
                    data: Data("active".utf8)),
                priority: .manual)
        }
        XCTAssertTrue(awaitValue: await recorder.waitForFirstEntry())
        let autosave = Task {
            try await io.commit(
                LocalDocumentSaveRequest(
                    documentID: UUID(), authorization: authorization,
                    data: Data("autosave".utf8)),
                priority: .autosave)
        }
        var manuals: [Task<FileTransactionReceipt, Error>] = []
        for index in 0..<12 {
            manuals.append(Task {
                try await io.commit(
                    LocalDocumentSaveRequest(
                        documentID: UUID(), authorization: authorization,
                        data: Data("manual-\(index)".utf8)),
                    priority: .manual)
            })
        }
        XCTAssertTrue(awaitValue: await waitUntilTotalPendingWork(io, equals: 13))

        recorder.allowFirst()
        _ = try await active.value
        _ = try await autosave.value
        for manual in manuals { _ = try await manual.value }

        let payloads = recorder.observedPayloads
        let autosaveIndex = try XCTUnwrap(payloads.firstIndex(of: "autosave"))
        XCTAssertLessThanOrEqual(
            autosaveIndex, 9,
            "manual priority may run at most eight queued commits before autosave progresses")
        XCTAssertTrue(awaitValue: await waitUntilWorkCountsDrain(io))
    }

    func testIdleManualHistoryDoesNotConsumeLaterAutosavePriorityBurst() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Note.md")
        try Data("disk".utf8).write(to: file)
        let blocker = AllBlockingDocumentCommitter()
        let io = LocalDocumentIO(maximumConcurrent: 1, maximumPendingWork: 16) {
            request, cancellationCheck in
            try blocker.commit(request, cancellationCheck: cancellationCheck)
        }
        let authorization = try await io.authorizeSaveAs(file, overwrite: true)

        for index in 0..<8 {
            let history = Task {
                try await io.commit(
                    LocalDocumentSaveRequest(
                        documentID: UUID(), authorization: authorization,
                        data: Data("history-\(index)".utf8)),
                    priority: .manual)
            }
            XCTAssertTrue(awaitValue: await blocker.waitForEntryCount(1))
            blocker.allow(1)
            _ = try await history.value
            XCTAssertTrue(awaitValue: await waitUntilWorkCountsDrain(io))
        }

        let active = Task {
            try await io.commit(
                LocalDocumentSaveRequest(
                    documentID: UUID(), authorization: authorization,
                    data: Data("active".utf8)),
                priority: .manual)
        }
        XCTAssertTrue(awaitValue: await blocker.waitForEntryCount(1))
        let autosave = Task {
            try await io.commit(
                LocalDocumentSaveRequest(
                    documentID: UUID(), authorization: authorization,
                    data: Data("autosave".utf8)),
                priority: .autosave)
        }
        let manual = Task {
            try await io.commit(
                LocalDocumentSaveRequest(
                    documentID: UUID(), authorization: authorization,
                    data: Data("queued-manual".utf8)),
                priority: .manual)
        }
        XCTAssertTrue(awaitValue: await waitUntilTotalPendingWork(io, equals: 2))

        blocker.allow(1)
        _ = try await active.value
        XCTAssertTrue(awaitValue: await blocker.waitForEntryCount(1))
        XCTAssertEqual(
            blocker.observedPayloads.last,
            "queued-manual",
            "manual-only history must not consume a future autosave pressure burst")
        blocker.allow(2)
        _ = try await autosave.value
        _ = try await manual.value
        XCTAssertTrue(awaitValue: await waitUntilWorkCountsDrain(io))
    }

    func testCancelledPreparationAfterGrantReleasesSharedAdmissionSlot() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Note.md")
        try Data("disk".utf8).write(to: file)
        let blocker = AllBlockingDocumentCommitter()
        let probe = PreparationGrantProbe()
        let io = LocalDocumentIO(
            maximumConcurrent: 1,
            maximumPendingWork: 2,
            preparationGrantedForTesting: { probe.blockGrantedSlot() }
        ) { request, cancellationCheck in
            try blocker.commit(request, cancellationCheck: cancellationCheck)
        }
        let authorization = try await io.authorizeSaveAs(file, overwrite: true)
        let active = Task {
            try await io.commit(
                LocalDocumentSaveRequest(
                    documentID: UUID(),
                    authorization: authorization,
                    data: Data("active".utf8)),
                priority: .manual)
        }
        XCTAssertTrue(awaitValue: await blocker.waitForEntryCount(1))

        let cancelledAuthorization = Task {
            try await io.authorizeSaveAs(file, overwrite: true)
        }
        XCTAssertTrue(awaitValue: await waitUntilTotalPendingWork(io, equals: 1))
        blocker.allow(1)
        XCTAssertTrue(awaitValue: await probe.waitForGrant())
        cancelledAuthorization.cancel()
        probe.allow()
        _ = try await active.value
        await XCTAssertThrowsErrorAsync(try await cancelledAuthorization.value)

        XCTAssertTrue(awaitValue: await waitUntilWorkCountsDrain(io))
        _ = try await io.authorizeSaveAs(file, overwrite: true)
        let drained = await io.workCountsForTesting()
        XCTAssertEqual(drained.active, 0)
        XCTAssertEqual(drained.pending, 0)
    }

    func testCancellationAfterAuthorizationIOBeforeReturnRefusesAuthorityAndReleasesSlot() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Note.md")
        try Data("disk".utf8).write(to: file)
        let probe = PreparationCompletionProbe()
        let io = LocalDocumentIO(
            maximumConcurrent: 1,
            maximumPendingWork: 2,
            preparationCompletedForTesting: { probe.blockCompletedPreparation() })

        let authorization = Task {
            try await io.authorizeSaveAs(file, overwrite: true)
        }
        XCTAssertTrue(awaitValue: await probe.waitForCompletion())
        authorization.cancel()
        probe.allowReturn()
        do {
            _ = try await authorization.value
            XCTFail("a cancelled completed authorization must not escape")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(awaitValue: await waitUntilWorkCountsDrain(io))

        _ = try await io.authorizeSaveAs(file, overwrite: true)
        let drained = await io.workCountsForTesting()
        XCTAssertEqual(drained.active, 0)
        XCTAssertEqual(drained.pending, 0)
    }

    func testGenericUserContentAuthorityHonorsCallerSpecificExactByteLimit() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exact = directory.appendingPathComponent("Exact.bin")
        let tooLarge = directory.appendingPathComponent("TooLarge.bin")
        try Data(repeating: 0x61, count: 8).write(to: exact)
        try Data(repeating: 0x62, count: 9).write(to: tooLarge)
        let io = LocalDocumentIO(maximumConcurrent: 1)

        _ = try await io.authorizeSaveAs(exact, overwrite: true, maximumBytes: 8)
        do {
            _ = try await io.authorizeSaveAs(tooLarge, overwrite: true, maximumBytes: 8)
            XCTFail("cap + 1 must be refused before an overwrite authority is issued")
        } catch SecureLocalFileError.fileTooLarge(let maximumBytes) {
            XCTAssertEqual(maximumBytes, 8)
        }

        let created = directory.appendingPathComponent("Created.bin")
        let creation = try await io.authorizeSaveAs(
            created, overwrite: false, maximumBytes: 8)
        _ = try await io.commit(
            LocalDocumentSaveRequest(
                documentID: UUID(),
                authorization: creation,
                data: Data(repeating: 0x63, count: 8),
                maximumBytes: 8),
            priority: .manual)
        XCTAssertEqual(try Data(contentsOf: created).count, 8)

        let refused = directory.appendingPathComponent("Refused.bin")
        let refusedAuthorization = try await io.authorizeSaveAs(
            refused, overwrite: false, maximumBytes: 8)
        await XCTAssertThrowsErrorAsync(
            try await io.commit(
                LocalDocumentSaveRequest(
                    documentID: UUID(),
                    authorization: refusedAuthorization,
                    data: Data(repeating: 0x64, count: 9),
                    maximumBytes: 8),
                priority: .manual))
        XCTAssertFalse(FileManager.default.fileExists(atPath: refused.path))
    }

    func testAsyncReadUsesTheSharedBoundedQueueAndCancelledWaiterReleasesAdmission()
        async throws
    {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Note.md")
        try Data("disk".utf8).write(to: file)
        let reader = BlockingDocumentReader()
        let io = LocalDocumentIO(
            maximumConcurrent: 1,
            maximumPendingWork: 2,
            read: { url, maximumBytes, cancellationCheck in
                try reader.read(
                    url,
                    maximumBytes: maximumBytes,
                    cancellationCheck: cancellationCheck)
            })

        let first = Task { try await io.read(file, maximumBytes: 64) }
        XCTAssertTrue(awaitValue: await reader.waitForEntry())
        let cancelled = Task { try await io.read(file, maximumBytes: 64) }
        XCTAssertTrue(awaitValue: await waitUntilTotalPendingWork(io, equals: 1))
        cancelled.cancel()
        await XCTAssertThrowsErrorAsync(try await cancelled.value)
        XCTAssertTrue(awaitValue: await waitUntilTotalPendingWork(io, equals: 0))

        reader.allow()
        let firstSnapshot = try await first.value
        XCTAssertEqual(firstSnapshot.data, Data("disk".utf8))

        let later = Task { try await io.read(file, maximumBytes: 64) }
        XCTAssertTrue(awaitValue: await reader.waitForEntry())
        reader.allow()
        let laterSnapshot = try await later.value
        XCTAssertEqual(laterSnapshot.data, Data("disk".utf8))
        XCTAssertEqual(reader.invocationCount, 2)
        XCTAssertTrue(awaitValue: await waitUntilWorkCountsDrain(io))
    }

    func testCancellationAfterReadIOBeforeReturnRefusesSnapshotAndReleasesSlot() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Note.md")
        try Data("disk".utf8).write(to: file)
        let probe = PreparationCompletionProbe()
        let io = LocalDocumentIO(
            maximumConcurrent: 1,
            maximumPendingWork: 2,
            preparationCompletedForTesting: { probe.blockCompletedPreparation() })

        let read = Task { try await io.read(file, maximumBytes: 64) }
        XCTAssertTrue(awaitValue: await probe.waitForCompletion())
        read.cancel()
        probe.allowReturn()
        await XCTAssertThrowsErrorAsync(try await read.value)
        XCTAssertTrue(awaitValue: await waitUntilWorkCountsDrain(io))

        let laterSnapshot = try await io.read(file, maximumBytes: 64)
        XCTAssertEqual(laterSnapshot.data, Data("disk".utf8))
        let drained = await io.workCountsForTesting()
        XCTAssertEqual(drained.active, 0)
        XCTAssertEqual(drained.pending, 0)
    }

    func testIdenticalSaveCallersMaterializeOneUTF8Payload() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Note.md")
        try Data("disk".utf8).write(to: file)
        let committer = BlockingDocumentCommitter()
        let materializations = LockedCounter()
        let io = LocalDocumentIO(
            payloadMaterializedForTesting: { materializations.increment() }
        ) { request, cancellationCheck in
            try committer.commit(request, cancellationCheck: cancellationCheck)
        }
        let workspace = makeWorkspace(documentIO: io)
        try workspace.open(file, in: workspace.focusedPane)
        XCTAssertTrue(workspace.updateText("shared snapshot", in: workspace.focusedPane))
        let documentID = try XCTUnwrap(workspace.document(in: workspace.focusedPane)?.id)

        let first = Task { try await workspace.saveWithOutcome(document: documentID) }
        XCTAssertTrue(awaitValue: await committer.waitForEntry())
        var joined: [Task<WorkspaceSaveOutcome, Error>] = []
        for _ in 0..<16 {
            joined.append(Task { try await workspace.saveWithOutcome(document: documentID) })
        }
        XCTAssertTrue(
            awaitValue: await waitUntilActiveSaveWaiterCount(
                workspace, documentID: documentID, equals: 17))
        XCTAssertEqual(materializations.value, 1)

        committer.allowOne()
        _ = try await first.value
        for task in joined { _ = try await task.value }
        XCTAssertEqual(materializations.value, 1)
    }

    func testAutosaveDefersSeventeenthDocumentBeforePayloadMaterialization() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let materializations = LockedCounter()
        let io = LocalDocumentIO(
            payloadMaterializedForTesting: { materializations.increment() }
        ) { request, _ in
            guard let version = request.authorization.existingVersion else {
                throw SecureLocalFileError.expectationMismatch
            }
            return FileTransactionReceipt(
                destination: request.authorization.destination,
                version: version,
                durability: .fullySynced,
                recovery: nil)
        }
        let workspace = makeWorkspace(documentIO: io)
        let pane = workspace.focusedPane
        for index in 0..<17 {
            let file = directory.appendingPathComponent("Note-\(index).md")
            try Data("disk".utf8).write(to: file)
            try workspace.open(file, in: pane)
            XCTAssertTrue(workspace.updateText("edit-\(index)", in: pane))
        }

        let report = await workspace.autosaveAsync()

        XCTAssertEqual(report.consideredCount, 17)
        XCTAssertEqual(report.attemptedCount, 16)
        XCTAssertEqual(report.succeededCount, 16)
        XCTAssertEqual(report.deferredCount, 1)
        XCTAssertEqual(materializations.value, 16)
    }

    func testOneHundredSameDestinationSavesRetainOneSlotAndTwoLogicalInodes() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Note.md")
        try Data("version-0".utf8).write(to: file)
        let registry = ProcessFileTransactionRegistry()
        let workspace = makeWorkspace(
            documentIO: LocalDocumentIO(),
            transactionRegistry: registry)
        try workspace.open(file, in: workspace.focusedPane)
        let documentID = try XCTUnwrap(workspace.document(in: workspace.focusedPane)?.id)
        var observedIdentities = Set<LocalFileIdentity>()

        func observeLogicalInodes() throws {
            let entries = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil)
            for entry in entries where entry.lastPathComponent == "Note.md"
                || entry.lastPathComponent.hasPrefix(".markdev-stage-")
            {
                observedIdentities.insert(
                    try XCTUnwrap(LocalFileSystem.stamp(of: entry)?.identity))
            }
        }

        try observeLogicalInodes()

        for version in 1...100 {
            XCTAssertTrue(workspace.updateText("version-\(version)", in: workspace.focusedPane))
            try workspace.save(document: documentID)
            try observeLogicalInodes()
        }

        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil)
        let stages = entries.filter { $0.lastPathComponent.hasPrefix(".markdev-stage-") }
        let identities = Set(try entries.map { entry -> LocalFileIdentity in
            try XCTUnwrap(LocalFileSystem.stamp(of: entry)?.identity)
        })
        XCTAssertEqual(stages.count, 1, "one destination must reuse one retained slot")
        XCTAssertEqual(identities.count, 2, "destination and retained slot must cycle two inodes")
        XCTAssertEqual(
            observedIdentities.count,
            2,
            "all 100 saves must cycle the original two inodes, not merely converge at the end")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "version-100")
    }

    func testSubstitutedRecoverySlotIsNeverTruncatedOrReplacedByAFreshSlot() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Note.md")
        try Data("version-0".utf8).write(to: file)
        let destinationKey = try LocalDocumentIO.authorizeSaveAsSynchronously(
            file,
            overwrite: true).destinationKey
        let registry = ProcessFileTransactionRegistry()
        let workspace = makeWorkspace(
            documentIO: LocalDocumentIO(),
            transactionRegistry: registry)
        try workspace.open(file, in: workspace.focusedPane)
        let documentID = try XCTUnwrap(workspace.document(in: workspace.focusedPane)?.id)

        XCTAssertTrue(workspace.updateText("version-1", in: workspace.focusedPane))
        try workspace.save(document: documentID)
        let firstEntries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil)
        let stage = try XCTUnwrap(
            firstEntries.first { $0.lastPathComponent.hasPrefix(".markdev-stage-") })
        let retained = directory.appendingPathComponent("retained-original")
        try FileManager.default.moveItem(at: stage, to: retained)
        try Data("bystander".utf8).write(to: stage)

        XCTAssertTrue(workspace.updateText("version-2", in: workspace.focusedPane))
        XCTAssertThrowsError(try workspace.save(document: documentID)) { error in
            XCTAssertEqual(
                error as? WorkspaceError,
                .recoveryRequiresReview(file.standardizedFileURL))
        }
        guard case .incident = registry.entryForTesting(destinationKey: destinationKey) else {
            return XCTFail("an unprovable retained slot must become a review incident")
        }

        XCTAssertThrowsError(try workspace.save(document: documentID)) { error in
            XCTAssertEqual(
                error as? WorkspaceError,
                .recoveryRequiresReview(file.standardizedFileURL))
        }

        XCTAssertEqual(try String(contentsOf: stage, encoding: .utf8), "bystander")
        XCTAssertEqual(try String(contentsOf: retained, encoding: .utf8), "version-0")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "version-1")
        let finalStages = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".markdev-stage-") }
        XCTAssertEqual(finalStages, [stage], "a stale slot must fail closed without allocating another")
    }

    func testProcessRegistryReusesOneExactSlotAcrossWorkspaces() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Note.md")
        try Data("version-0".utf8).write(to: file)
        let registry = ProcessFileTransactionRegistry()
        let first = makeWorkspace(
            documentIO: LocalDocumentIO(),
            transactionRegistry: registry)
        try first.open(file, in: first.focusedPane)
        let firstID = try XCTUnwrap(first.document(in: first.focusedPane)?.id)
        XCTAssertTrue(first.updateText("version-1", in: first.focusedPane))
        try first.save(document: firstID)
        let originalStage = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).first { $0.lastPathComponent.hasPrefix(".markdev-stage-") })
        first.close(firstID, in: first.focusedPane)

        let second = makeWorkspace(
            documentIO: LocalDocumentIO(),
            transactionRegistry: registry)
        try second.open(file, in: second.focusedPane)
        let secondID = try XCTUnwrap(second.document(in: second.focusedPane)?.id)
        XCTAssertTrue(second.updateText("version-2", in: second.focusedPane))
        try second.save(document: secondID)

        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil)
        let stages = entries.filter { $0.lastPathComponent.hasPrefix(".markdev-stage-") }
        XCTAssertEqual(stages.map(\.lastPathComponent), [originalStage.lastPathComponent])
        XCTAssertEqual(Set(try entries.map {
            try XCTUnwrap(LocalFileSystem.stamp(of: $0)?.identity)
        }).count, 2)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "version-2")
    }

    func testPhysicalCaseAliasSavesReuseOneRegistrySlotAndTwoInodes() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stored = directory.appendingPathComponent("CaseSlot.md")
        let alias = directory.appendingPathComponent("caseslot.md")
        try Data("version-0".utf8).write(to: stored)
        guard let storedIdentity = LocalFileSystem.stamp(of: stored)?.identity,
            LocalFileSystem.stamp(of: alias)?.identity == storedIdentity
        else {
            throw XCTSkip("test volume uses case-sensitive file names")
        }

        let registry = ProcessFileTransactionRegistry()
        let workspace = makeWorkspace(
            documentIO: LocalDocumentIO(),
            transactionRegistry: registry)
        try workspace.open(stored, in: workspace.focusedPane)
        let documentID = try XCTUnwrap(workspace.document(in: workspace.focusedPane)?.id)
        var observedIdentities: Set<LocalFileIdentity> = [storedIdentity]

        for version in 1...12 {
            XCTAssertTrue(
                workspace.updateText("version-\(version)", in: workspace.focusedPane))
            try workspace.save(
                document: documentID,
                to: version.isMultiple(of: 2) ? stored : alias,
                overwrite: true)
            for entry in try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil)
            where entry.lastPathComponent == stored.lastPathComponent
                || entry.lastPathComponent.hasPrefix(".markdev-stage-")
            {
                observedIdentities.insert(
                    try XCTUnwrap(LocalFileSystem.stamp(of: entry)?.identity))
            }
        }

        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil)
        XCTAssertEqual(
            entries.filter { $0.lastPathComponent.hasPrefix(".markdev-stage-") }.count,
            1)
        XCTAssertEqual(observedIdentities.count, 2)
        XCTAssertEqual(registry.entryCountForTesting, 1)
        XCTAssertEqual(try String(contentsOf: stored, encoding: .utf8), "version-12")
    }

    func testCrossWorkspaceOpenRefusesPostCommitPreSettlementReservation() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Note.md")
        try Data("disk".utf8).write(to: file)
        let registry = ProcessFileTransactionRegistry()
        let committer = PostCommitBlockingDocumentCommitter()
        let writer = makeWorkspace(
            documentIO: LocalDocumentIO(maximumConcurrent: 1) { request, cancellationCheck in
                try committer.commit(request, cancellationCheck: cancellationCheck)
            },
            transactionRegistry: registry)
        try writer.open(file, in: writer.focusedPane)
        let documentID = try XCTUnwrap(writer.document(in: writer.focusedPane)?.id)
        XCTAssertTrue(writer.updateText("published", in: writer.focusedPane))
        let save = Task { try await writer.saveWithOutcome(document: documentID) }
        XCTAssertTrue(awaitValue: await committer.waitForCommit())

        let reader = makeWorkspace(
            documentIO: LocalDocumentIO(),
            transactionRegistry: registry)
        XCTAssertThrowsError(try reader.open(file, in: reader.focusedPane)) { error in
            guard case WorkspaceError.destinationAlreadyOpen = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        committer.allowSettlement()
        let outcome = try await save.value
        XCTAssertEqual(outcome.settlement, .applied)
    }

    func testCapacityReservationIsAtomicAcrossTwoWorkspaces() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstURL = directory.appendingPathComponent("First.md")
        let secondURL = directory.appendingPathComponent("Second.md")
        let registry = ProcessFileTransactionRegistry(maximumSlots: 1)
        let committer = PostCommitBlockingDocumentCommitter()
        let first = makeWorkspace(
            documentIO: LocalDocumentIO(maximumConcurrent: 1) { request, cancellationCheck in
                try committer.commit(request, cancellationCheck: cancellationCheck)
            },
            transactionRegistry: registry)
        XCTAssertTrue(first.updateText("first", in: first.focusedPane))
        let firstID = try XCTUnwrap(first.document(in: first.focusedPane)?.id)
        let firstSave = Task {
            try await first.saveWithOutcome(
                document: firstID,
                to: firstURL,
                overwrite: false)
        }
        XCTAssertTrue(awaitValue: await committer.waitForCommit())

        let second = makeWorkspace(
            documentIO: LocalDocumentIO(),
            transactionRegistry: registry)
        XCTAssertTrue(second.updateText("second", in: second.focusedPane))
        let secondID = try XCTUnwrap(second.document(in: second.focusedPane)?.id)
        do {
            _ = try await second.saveWithOutcome(
                document: secondID,
                to: secondURL,
                overwrite: false)
            XCTFail("a second destination crossed the one-slot cap")
        } catch WorkspaceError.recoveryCapacityReached(let maximumSlots) {
            XCTAssertEqual(maximumSlots, 1)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondURL.path))
        XCTAssertEqual(registry.entryCountForTesting, 1)

        committer.allowSettlement()
        let outcome = try await firstSave.value
        XCTAssertEqual(outcome.settlement, .applied)
        XCTAssertEqual(registry.entryCountForTesting, 0)
    }

    func testStaleExactReceiptIsIndeterminateAndDoesNotClearDirtyState() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Note.md")
        try Data("disk".utf8).write(to: file)
        let key = try LocalDocumentIO.authorizeSaveAsSynchronously(
            file,
            overwrite: true).destinationKey
        let registry = ProcessFileTransactionRegistry()
        let committer = PostCommitBlockingDocumentCommitter()
        let workspace = makeWorkspace(
            documentIO: LocalDocumentIO(maximumConcurrent: 1) { request, cancellationCheck in
                try committer.commit(request, cancellationCheck: cancellationCheck)
            },
            transactionRegistry: registry)
        try workspace.open(file, in: workspace.focusedPane)
        let documentID = try XCTUnwrap(workspace.document(in: workspace.focusedPane)?.id)
        XCTAssertTrue(workspace.updateText("published", in: workspace.focusedPane))
        let save = Task { try await workspace.saveWithOutcome(document: documentID) }
        XCTAssertTrue(awaitValue: await committer.waitForCommit())
        registry.advanceRevisionForTesting(destinationKey: key)
        committer.allowSettlement()

        do {
            _ = try await save.value
            XCTFail("stale filesystem authority was reported as applied")
        } catch SecureLocalFileError.indeterminate(let receipt) {
            XCTAssertNotNil(receipt.recoverySlot)
            XCTAssertEqual(receipt.destinationKey, key)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertTrue(workspace.document(in: workspace.focusedPane)?.hasUnsavedChanges == true)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "published")
        XCTAssertNotNil(registry.entryForTesting(destinationKey: key))
    }

    func testMissingFailuresReuseOneScratchThenConsumeItOnSuccess() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("Created.md")
        let registry = ProcessFileTransactionRegistry()
        let committer = RetriableMissingStageFailureCommitter(failureCount: 3)
        let workspace = makeWorkspace(
            documentIO: LocalDocumentIO(maximumConcurrent: 1) { request, cancellationCheck in
                try committer.commit(request, cancellationCheck: cancellationCheck)
            },
            transactionRegistry: registry)
        let documentID = try XCTUnwrap(workspace.document(in: workspace.focusedPane)?.id)

        for attempt in 1...3 {
            XCTAssertTrue(workspace.updateText("attempt-\(attempt)", in: workspace.focusedPane))
            await XCTAssertThrowsErrorAsync(
                try await workspace.saveWithOutcome(
                    document: documentID,
                    to: destination,
                    overwrite: false))
            let stages = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter { $0.hasPrefix(".markdev-stage-") }
            XCTAssertEqual(stages.count, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertEqual(registry.entryCountForTesting, 1)
        }

        XCTAssertTrue(workspace.updateText("success", in: workspace.focusedPane))
        let outcome = try await workspace.saveWithOutcome(
            document: documentID,
            to: destination,
            overwrite: false)
        XCTAssertEqual(outcome.settlement, .applied)
        XCTAssertEqual(committer.invocationCount, 4)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter { $0.hasPrefix(".markdev-stage-") }.count,
            0)
        XCTAssertEqual(registry.entryCountForTesting, 0)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "success")
    }

    func testSaveAsDoesNotConsumeSourceRecoverySlot() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Source.md")
        let destination = directory.appendingPathComponent("Destination.md")
        try Data("source-0".utf8).write(to: source)
        let registry = ProcessFileTransactionRegistry()
        let first = makeWorkspace(
            documentIO: LocalDocumentIO(),
            transactionRegistry: registry)
        try first.open(source, in: first.focusedPane)
        let firstID = try XCTUnwrap(first.document(in: first.focusedPane)?.id)
        XCTAssertTrue(first.updateText("source-1", in: first.focusedPane))
        try first.save(document: firstID)
        let sourceStage = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(atPath: directory.path)
                .first { $0.hasPrefix(".markdev-stage-") })

        XCTAssertTrue(first.updateText("save-as", in: first.focusedPane))
        try first.save(document: firstID, to: destination, overwrite: false)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(sourceStage).path))

        let second = makeWorkspace(
            documentIO: LocalDocumentIO(),
            transactionRegistry: registry)
        try second.open(source, in: second.focusedPane)
        let secondID = try XCTUnwrap(second.document(in: second.focusedPane)?.id)
        XCTAssertTrue(second.updateText("source-2", in: second.focusedPane))
        try second.save(document: secondID)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter { $0.hasPrefix(".markdev-stage-") },
            [sourceStage])
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "source-2")
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "save-as")
    }

    func testMalformedNestedPrepublicationFailureCreatesIncidentAndDoesNotPromote() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Note.md")
        try Data("disk".utf8).write(to: file)
        let registry = ProcessFileTransactionRegistry()
        let committer = MalformedPrepublicationCommitter()
        let workspace = makeWorkspace(
            documentIO: LocalDocumentIO(maximumConcurrent: 1) { request, cancellationCheck in
                try committer.commit(request, cancellationCheck: cancellationCheck)
            },
            transactionRegistry: registry)
        try workspace.open(file, in: workspace.focusedPane)
        let documentID = try XCTUnwrap(workspace.document(in: workspace.focusedPane)?.id)
        XCTAssertTrue(workspace.updateText("first", in: workspace.focusedPane))
        let first = Task { try await workspace.saveWithOutcome(document: documentID) }
        XCTAssertTrue(awaitValue: await committer.waitForEntry())
        XCTAssertTrue(workspace.updateText("queued", in: workspace.focusedPane))
        let queued = Task { try await workspace.saveWithOutcome(document: documentID) }
        XCTAssertTrue(
            awaitValue: await waitUntilPendingManualSaveCount(
                workspace,
                documentID: documentID,
                equals: 1))
        committer.allowFailure()
        await XCTAssertThrowsErrorAsync(try await first.value)
        await XCTAssertThrowsErrorAsync(try await queued.value)
        XCTAssertEqual(committer.observedPayloads, ["first"])

        do {
            _ = try await workspace.saveWithOutcome(document: documentID)
            XCTFail("incident authority was silently reused")
        } catch WorkspaceError.recoveryRequiresReview(let url) {
            XCTAssertEqual(url.standardizedFileURL, file.standardizedFileURL)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testCrossDestinationRecoveryReceiptAndClaimedURLFailClosed() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("Target.md")
        let donor = directory.appendingPathComponent("Donor.md")
        let claimed = directory.appendingPathComponent("Claimed.md")
        try Data("target".utf8).write(to: target)
        try Data("donor-0".utf8).write(to: donor)
        try Data("claimed".utf8).write(to: claimed)
        let handle = try SecureLocalDirectoryHandle(opening: directory)
        let donorInitial = try handle.version(of: FileComponent("Donor.md"))
        let donorReceipt = try handle.transaction(
            component: FileComponent("Donor.md"),
            data: Data("donor-1".utf8),
            expectation: .exact(donorInitial),
            policy: .userContent
        ).commit()
        let donorSlot = try XCTUnwrap(donorReceipt.recoverySlot)
        let donorRecoveryURL = directory.appendingPathComponent(
            donorSlot.authority.component.rawValue)
        let donorRecoveryIdentity = try XCTUnwrap(
            LocalFileSystem.stamp(of: donorRecoveryURL)?.identity)

        let registry = ProcessFileTransactionRegistry()
        let transplanted = makeWorkspace(
            documentIO: LocalDocumentIO(maximumConcurrent: 1) { request, _ in
                return FileTransactionReceipt(
                    destination: request.authorization.destination,
                    version: request.authorization.existingVersion,
                    durability: .recoveryRetained(directorySyncErrno: nil),
                    recoverySlot: donorSlot)
            },
            transactionRegistry: registry)
        try transplanted.open(target, in: transplanted.focusedPane)
        let targetID = try XCTUnwrap(transplanted.document(in: transplanted.focusedPane)?.id)
        XCTAssertTrue(transplanted.updateText("changed", in: transplanted.focusedPane))
        await XCTAssertThrowsErrorAsync(
            try await transplanted.saveWithOutcome(document: targetID))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "target")
        XCTAssertEqual(try String(contentsOf: donorRecoveryURL, encoding: .utf8), "donor-0")
        XCTAssertEqual(
            LocalFileSystem.stamp(of: donorRecoveryURL)?.identity,
            donorRecoveryIdentity)

        let urlRegistry = ProcessFileTransactionRegistry()
        let substituted = makeWorkspace(
            documentIO: LocalDocumentIO(maximumConcurrent: 1) { request, cancellationCheck in
                let committed = try LocalDocumentIO.commitSynchronously(
                    request,
                    cancellationCheck: cancellationCheck)
                return FileTransactionReceipt(
                    destination: claimed,
                    version: committed.version,
                    durability: committed.durability,
                    recoverySlot: committed.recoverySlot)
            },
            transactionRegistry: urlRegistry)
        try substituted.open(target, in: substituted.focusedPane)
        let substitutedID = try XCTUnwrap(substituted.document(in: substituted.focusedPane)?.id)
        XCTAssertTrue(substituted.updateText("changed-again", in: substituted.focusedPane))
        await XCTAssertThrowsErrorAsync(
            try await substituted.saveWithOutcome(document: substitutedID))
        XCTAssertEqual(substituted.document(in: substituted.focusedPane)?.url, target)
        XCTAssertTrue(substituted.document(in: substituted.focusedPane)?.hasUnsavedChanges == true)
        XCTAssertEqual(try String(contentsOf: claimed, encoding: .utf8), "claimed")
    }

    func testStaleNoRecoveryCompletionCannotClearNewerGenerationAndRealIncidentCapRefuses() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("Created.md")
        let fixture = directory.appendingPathComponent("Fixture.md")
        try Data("fixture".utf8).write(to: fixture)
        let fixtureVersion = try SecureLocalDirectoryHandle(opening: directory)
            .version(of: FileComponent("Fixture.md"))
        let authorization = try LocalDocumentIO.authorizeSaveAsSynchronously(
            destination,
            overwrite: false)
        let owner = ProcessFileTransactionOwner(
            workspaceID: UUID(),
            documentID: UUID())
        let registry = ProcessFileTransactionRegistry(maximumSlots: 1)
        let selection = try registry.begin(
            destinationKey: authorization.destinationKey,
            identity: nil,
            expectation: .missing,
            owner: owner)
        registry.advanceRevisionForTesting(destinationKey: authorization.destinationKey)
        let newer = registry.entryForTesting(destinationKey: authorization.destinationKey)
        let stale = registry.settleCommitted(
            destinationKey: authorization.destinationKey,
            expectation: .missing,
            selection: selection,
            receipt: FileTransactionReceipt(
                destination: authorization.destination,
                version: fixtureVersion,
                durability: .fullySynced,
                recovery: nil))
        XCTAssertEqual(stale, .stale)
        XCTAssertEqual(registry.entryForTesting(destinationKey: authorization.destinationKey), newer)
        registry.release(
            destinationKey: authorization.destinationKey,
            identity: nil,
            owner: owner,
            leaseRevision: selection.observedRevision)
        try registry.fillWithIncidentsForTesting(using: authorization.destinationKey)
        XCTAssertEqual(registry.entryCountForTesting, 1)
        guard case .incident = registry.entryForTesting(
            destinationKey: authorization.destinationKey)
        else { return XCTFail("capacity fixture must contain a real review incident") }

        let other = directory.appendingPathComponent("Other.md")
        let otherAuthorization = try LocalDocumentIO.authorizeSaveAsSynchronously(
            other,
            overwrite: false)
        XCTAssertThrowsError(
            try registry.begin(
                destinationKey: otherAuthorization.destinationKey,
                identity: nil,
                expectation: .missing,
                owner: ProcessFileTransactionOwner(
                    workspaceID: UUID(),
                    documentID: UUID()))) { error in
            XCTAssertEqual(
                error as? ProcessFileTransactionRegistryError,
                .capacityReached(maximumSlots: 1))
        }
    }

    func testReservationLeaseRejectsSameOwnerOverlapAndOldReleaseCannotClearNewLease() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("Created.md")
        let fixture = directory.appendingPathComponent("Fixture.md")
        try Data("fixture".utf8).write(to: fixture)
        let fixtureVersion = try SecureLocalDirectoryHandle(opening: directory)
            .version(of: FileComponent("Fixture.md"))
        let authorization = try LocalDocumentIO.authorizeSaveAsSynchronously(
            destination,
            overwrite: false)
        let registry = ProcessFileTransactionRegistry(maximumSlots: 2)
        let owner = ProcessFileTransactionOwner(
            workspaceID: UUID(),
            documentID: UUID())
        let old = try registry.begin(
            destinationKey: authorization.destinationKey,
            identity: nil,
            expectation: .missing,
            owner: owner)
        XCTAssertEqual(
            registry.settleCommitted(
                destinationKey: authorization.destinationKey,
                expectation: .missing,
                selection: old,
                receipt: FileTransactionReceipt(
                    destination: authorization.destination,
                    version: fixtureVersion,
                    durability: .fullySynced,
                    recovery: nil)),
            .settled(revision: nil))
        XCTAssertThrowsError(
            try registry.begin(
                destinationKey: authorization.destinationKey,
                identity: nil,
                expectation: .missing,
                owner: owner))

        registry.release(
            destinationKey: authorization.destinationKey,
            identity: nil,
            owner: owner,
            leaseRevision: old.observedRevision)
        let newer = try registry.begin(
            destinationKey: authorization.destinationKey,
            identity: nil,
            expectation: .missing,
            owner: owner)
        registry.release(
            destinationKey: authorization.destinationKey,
            identity: nil,
            owner: owner,
            leaseRevision: old.observedRevision)
        XCTAssertThrowsError(
            try registry.ensureAvailable(
                destinationKey: authorization.destinationKey,
                identity: nil,
                owner: ProcessFileTransactionOwner(
                    workspaceID: UUID(),
                    documentID: UUID()))) { error in
            XCTAssertEqual(error as? ProcessFileTransactionRegistryError, .destinationReserved)
        }
        registry.release(
            destinationKey: authorization.destinationKey,
            identity: nil,
            owner: owner,
            leaseRevision: newer.observedRevision)
    }

    func testRecoveryKeysKeepExactBytesWhileReservationAliasesConservativelyCollide() throws {
        let status = try XCTUnwrap(LocalFileSystem.stamp(
            of: URL(fileURLWithPath: #filePath)))
        let upper = FileDestinationKey(
            directoryIdentity: status.identity,
            component: try FileComponent("A.md"),
            caseSensitiveNames: nil)
        let lower = FileDestinationKey(
            directoryIdentity: status.identity,
            component: try FileComponent("a.md"),
            caseSensitiveNames: nil)
        XCTAssertNotEqual(upper, lower)
        XCTAssertEqual(upper.reservationAlias, lower.reservationAlias)

        let composed = FileDestinationKey(
            directoryIdentity: status.identity,
            component: try FileComponent("\u{00E9}.md"),
            caseSensitiveNames: true)
        let decomposed = FileDestinationKey(
            directoryIdentity: status.identity,
            component: try FileComponent("e\u{0301}.md"),
            caseSensitiveNames: true)
        XCTAssertNotEqual(composed, decomposed)
        XCTAssertEqual(composed.reservationAlias, decomposed.reservationAlias)
    }
}

@MainActor
private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected expression to throw", file: file, line: line)
    } catch {
        // Expected.
    }
}

private func workspaceReadSnapshot(
    at url: URL,
    maximumBytes: Int = MarkdownReadLimits.maximumDocumentBytes
) throws -> WorkspaceDocumentReadSnapshot {
    let snapshot = try SecureLocalFileSystem.read(url, maximumBytes: maximumBytes)
    guard let text = String(data: snapshot.data, encoding: .utf8) else {
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }
    return WorkspaceDocumentReadSnapshot(
        text: text,
        version: snapshot.version,
        canonicalURL: snapshot.canonicalURL,
        destinationKey: snapshot.destinationKey)
}

private func waitUntilPendingJobCount(
    _ io: LocalDocumentIO,
    equals expectedCount: Int
) async -> Bool {
    for _ in 0..<5_000 {
        if await io.pendingJobCountForTesting() == expectedCount { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return false
}

private func waitUntilTotalPendingWork(
    _ io: LocalDocumentIO,
    equals expectedCount: Int
) async -> Bool {
    for _ in 0..<5_000 {
        if await io.workCountsForTesting().pending == expectedCount { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return false
}

private func waitUntilWorkCountsDrain(_ io: LocalDocumentIO) async -> Bool {
    for _ in 0..<5_000 {
        let counts = await io.workCountsForTesting()
        if counts.active == 0, counts.pending == 0 { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return false
}

@MainActor
private func waitUntilPendingManualSaveCount(
    _ workspace: Workspace,
    documentID: UUID,
    equals expectedCount: Int
) async -> Bool {
    for _ in 0..<5_000 {
        if workspace.pendingManualSaveCountForTesting(documentID: documentID) == expectedCount {
            return true
        }
        await Task.yield()
    }
    return false
}

@MainActor
private func waitUntilActiveSaveWaiterCount(
    _ workspace: Workspace,
    documentID: UUID,
    equals expectedCount: Int
) async -> Bool {
    for _ in 0..<5_000 {
        if workspace.activeSaveWaiterCountForTesting(documentID: documentID) == expectedCount {
            return true
        }
        await Task.yield()
    }
    return false
}

private func XCTAssertTrue(
    awaitValue value: Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertTrue(value, file: file, line: line)
}
