//
//  LocalDocumentIO.swift
//  MarkDevKit
//
//  Off-main, bounded scheduling for descriptor-relative document saves.
//

import Darwin
import Foundation

/// An opaque live-process generation captured when Workspace selects a
/// recovery slot. It prevents a delayed completion from replacing authority
/// installed by a newer transaction.
struct FileRecoverySlotRevision: Equatable, Sendable {
    let rawValue: UUID

    init() {
        rawValue = UUID()
    }
}

struct FileRecoverySlotSelection: Equatable, Sendable {
    let observedRevision: FileRecoverySlotRevision
    let reusableStage: FileRecoverySlot?
    let journalTransaction: RecoveryJournalTransactionContext?

    init(
        observedRevision: FileRecoverySlotRevision,
        reusableStage: FileRecoverySlot?,
        journalTransaction: RecoveryJournalTransactionContext? = nil
    ) {
        self.observedRevision = observedRevision
        self.reusableStage = reusableStage
        self.journalTransaction = journalTransaction
    }

    static func == (lhs: FileRecoverySlotSelection, rhs: FileRecoverySlotSelection) -> Bool {
        lhs.observedRevision == rhs.observedRevision
            && lhs.reusableStage == rhs.reusableStage
            && lhs.journalTransaction?.entryID == rhs.journalTransaction?.entryID
    }
}

/// A destination inspected after the save panel returns and retained by
/// descriptor until publication. Its authority is intentionally opaque to UI
/// callers; only Workspace and LocalDocumentIO can consume it.
public struct UserContentWriteAuthorization: Sendable {
    public let destination: URL

    let directory: UserContentDirectory
    let component: FileComponent
    /// Opaque physical namespace identity shared by process-wide reservation
    /// and recovery-slot owners. URL spellings are presentation only.
    let destinationKey: FileDestinationKey
    let expectation: FileTransactionExpectation
    /// One exact scratch slot previously retained for this destination during
    /// the current process. It is never sourced from another destination.
    let recoverySlotSelection: FileRecoverySlotSelection?

    var reusableStage: FileRecoverySlot? {
        recoverySlotSelection?.reusableStage
    }

    var existingVersion: FileVersionToken? {
        guard case .exact(let version) = expectation else { return nil }
        return version
    }

    func selectingRecoverySlot(
        _ selection: FileRecoverySlotSelection
    ) -> UserContentWriteAuthorization {
        UserContentWriteAuthorization(
            destination: destination,
            directory: directory,
            component: component,
            destinationKey: destinationKey,
            expectation: expectation,
            recoverySlotSelection: selection)
    }
}

/// Workspace keeps its domain language while diagnostics and exporters can
/// consume the same retained, exact destination authority without depending
/// on a workspace-specific implementation.
public typealias WorkspaceSaveAuthorization = UserContentWriteAuthorization

enum LocalDocumentSavePriority: Int, Sendable {
    case autosave = 0
    case manual = 1
}

struct LocalDocumentSaveRequest: Sendable {
    private enum Payload: Sendable {
        case data(Data)
        case admittedUTF8(text: String, byteCount: Int)
    }

    let documentID: UUID
    let authorization: WorkspaceSaveAuthorization
    let maximumBytes: Int
    private let payload: Payload

    var byteCount: Int {
        switch payload {
        case .data(let data): data.count
        case .admittedUTF8(_, let byteCount): byteCount
        }
    }

    /// Commit implementations receive a materialized request. Keeping this
    /// projection also preserves the narrow test/export adapter used before
    /// payload admission moved behind the scheduler.
    var data: Data {
        switch payload {
        case .data(let data): data
        case .admittedUTF8(let text, _): Data(text.utf8)
        }
    }

    init(
        documentID: UUID,
        authorization: WorkspaceSaveAuthorization,
        data: Data,
        maximumBytes: Int = MarkdownReadLimits.maximumDocumentBytes
    ) {
        precondition(maximumBytes >= 0, "document I/O limit must not be negative")
        self.documentID = documentID
        self.authorization = authorization
        self.maximumBytes = maximumBytes
        payload = .data(data)
    }

    init(
        documentID: UUID,
        authorization: WorkspaceSaveAuthorization,
        admittedUTF8 text: String,
        byteCount: Int,
        maximumBytes: Int = MarkdownReadLimits.maximumDocumentBytes
    ) {
        precondition(maximumBytes >= 0, "document I/O limit must not be negative")
        precondition(byteCount >= 0 && byteCount <= maximumBytes)
        self.documentID = documentID
        self.authorization = authorization
        self.maximumBytes = maximumBytes
        payload = .admittedUTF8(text: text, byteCount: byteCount)
    }

    func materialized(
        cancellationCheck: @escaping @Sendable () -> Bool
    ) throws -> LocalDocumentSaveRequest {
        switch payload {
        case .data:
            guard !cancellationCheck() else { throw CancellationError() }
            return self
        case .admittedUTF8(let text, let admittedByteCount):
            guard !cancellationCheck() else { throw CancellationError() }
            let data = Data(text.utf8)
            guard data.count == admittedByteCount, data.count <= maximumBytes else {
                throw SecureLocalFileError.fileTooLarge(maximumBytes: maximumBytes)
            }
            guard !cancellationCheck() else { throw CancellationError() }
            return LocalDocumentSaveRequest(
                documentID: documentID,
                authorization: authorization,
                data: data,
                maximumBytes: maximumBytes)
        }
    }
}

enum LocalDocumentIOError: Error, Equatable {
    case busy
    case destinationExists
    /// The requested spelling is unsafe for publication, but resolves to a
    /// known regular-file identity so Workspace can distinguish an alias of
    /// an already-open document from a generic unsafe destination. This is
    /// diagnostic identity only; it never grants write authority.
    case destinationAlias(URL, LocalFileIdentity)
    case superseded
}

enum LocalDocumentEntryKind: Equatable, Sendable {
    case regularFile
    case directory
    case unsupported
}

private final class DocumentIOCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// Bounded latest-wins scheduler for blocking local file transactions.
///
/// The actor owns ordering only. Each syscall transaction runs in a detached
/// task, never on MainActor, and receives an explicit cancellation flag because
/// detached tasks do not inherit cancellation from their caller.
actor LocalDocumentIO {
    private static let maximumConsecutiveManualCommits = 8

    typealias CommitImplementation = @Sendable (
        LocalDocumentSaveRequest,
        @escaping @Sendable () -> Bool
    ) throws -> FileTransactionReceipt
    typealias ReadImplementation = @Sendable (
        URL,
        Int,
        @escaping @Sendable () -> Bool
    ) throws -> SecureLocalFileReadSnapshot
    typealias CreateImplementation = @Sendable (
        URL,
        String,
        String,
        Int,
        @escaping @Sendable () -> Bool
    ) throws -> SecureLocalFileCreationSnapshot
    typealias ClassificationImplementation = @Sendable (
        URL,
        @escaping @Sendable () -> Bool
    ) throws -> LocalDocumentEntryKind
    typealias DurabilityConfirmationImplementation = @Sendable (
        WorkspaceSaveAuthorization,
        FileVersionToken,
        Int,
        @escaping @Sendable () -> Bool
    ) throws -> Void

    private final class Job: @unchecked Sendable {
        let id: UUID
        let request: LocalDocumentSaveRequest
        let priority: LocalDocumentSavePriority
        let cancellation: DocumentIOCancellation
        let continuation: CheckedContinuation<FileTransactionReceipt, Error>

        init(
            id: UUID,
            request: LocalDocumentSaveRequest,
            priority: LocalDocumentSavePriority,
            cancellation: DocumentIOCancellation,
            continuation: CheckedContinuation<FileTransactionReceipt, Error>
        ) {
            self.id = id
            self.request = request
            self.priority = priority
            self.cancellation = cancellation
            self.continuation = continuation
        }
    }

    private enum JobOutcome: @unchecked Sendable {
        case success(FileTransactionReceipt)
        case failure(Error)
    }

    private let maximumConcurrent: Int
    private let maximumPendingWork: Int
    private let commitImplementation: CommitImplementation
    private let readImplementation: ReadImplementation
    private let createImplementation: CreateImplementation
    private let classificationImplementation: ClassificationImplementation
    private let durabilityConfirmationImplementation: DurabilityConfirmationImplementation
    private let payloadMaterializedForTesting: (@Sendable () -> Void)?
    private let preparationGrantedForTesting: (@Sendable () -> Void)?
    private let preparationCompletedForTesting: (@Sendable () -> Void)?
    private var pending: [Job] = []
    private var active: [UUID: Job] = [:]
    private var activeDocuments: Set<UUID> = []
    private var activeWorkCount = 0
    private var pendingPreparations: [PreparationWaiter] = []
    private var preferPreparation = true
    private var consecutiveManualCommits = 0

    private final class PreparationWaiter: @unchecked Sendable {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>

        init(id: UUID, continuation: CheckedContinuation<Void, Error>) {
            self.id = id
            self.continuation = continuation
        }
    }

    init(
        maximumConcurrent: Int = 2,
        maximumPendingWork: Int = 32,
        preparationGrantedForTesting: (@Sendable () -> Void)? = nil,
        preparationCompletedForTesting: (@Sendable () -> Void)? = nil,
        read: @escaping ReadImplementation = { url, maximumBytes, cancellationCheck in
            try LocalDocumentIO.readSynchronously(
                url,
                maximumBytes: maximumBytes,
                cancellationCheck: cancellationCheck)
        },
        create: @escaping CreateImplementation = {
            folder, baseName, pathExtension, maximumAttempts, cancellationCheck in
            try LocalDocumentIO.createUniqueEmptyDocumentSynchronously(
                in: folder,
                baseName: baseName,
                pathExtension: pathExtension,
                maximumAttempts: maximumAttempts,
                cancellationCheck: cancellationCheck)
        },
        classify: @escaping ClassificationImplementation = { url, cancellationCheck in
            try LocalDocumentIO.classifySynchronously(
                url,
                cancellationCheck: cancellationCheck)
        },
        confirmDurability: @escaping DurabilityConfirmationImplementation = {
            authorization, expectedVersion, maximumBytes, cancellationCheck in
            try LocalDocumentIO.confirmDurabilitySynchronously(
                authorization,
                expectedVersion: expectedVersion,
                maximumBytes: maximumBytes,
                cancellationCheck: cancellationCheck)
        },
        payloadMaterializedForTesting: (@Sendable () -> Void)? = nil
    ) {
        precondition((1...2).contains(maximumConcurrent))
        precondition((0...32).contains(maximumPendingWork))
        self.maximumConcurrent = maximumConcurrent
        self.maximumPendingWork = maximumPendingWork
        self.preparationGrantedForTesting = preparationGrantedForTesting
        self.preparationCompletedForTesting = preparationCompletedForTesting
        self.readImplementation = read
        createImplementation = create
        classificationImplementation = classify
        durabilityConfirmationImplementation = confirmDurability
        self.payloadMaterializedForTesting = payloadMaterializedForTesting
        commitImplementation = { request, cancellationCheck in
            try LocalDocumentIO.commitSynchronously(
                request, cancellationCheck: cancellationCheck)
        }
    }

    init(
        maximumConcurrent: Int = 2,
        maximumPendingWork: Int = 32,
        preparationGrantedForTesting: (@Sendable () -> Void)? = nil,
        preparationCompletedForTesting: (@Sendable () -> Void)? = nil,
        read: @escaping ReadImplementation = { url, maximumBytes, cancellationCheck in
            try LocalDocumentIO.readSynchronously(
                url,
                maximumBytes: maximumBytes,
                cancellationCheck: cancellationCheck)
        },
        create: @escaping CreateImplementation = {
            folder, baseName, pathExtension, maximumAttempts, cancellationCheck in
            try LocalDocumentIO.createUniqueEmptyDocumentSynchronously(
                in: folder,
                baseName: baseName,
                pathExtension: pathExtension,
                maximumAttempts: maximumAttempts,
                cancellationCheck: cancellationCheck)
        },
        classify: @escaping ClassificationImplementation = { url, cancellationCheck in
            try LocalDocumentIO.classifySynchronously(
                url,
                cancellationCheck: cancellationCheck)
        },
        confirmDurability: @escaping DurabilityConfirmationImplementation = {
            authorization, expectedVersion, maximumBytes, cancellationCheck in
            try LocalDocumentIO.confirmDurabilitySynchronously(
                authorization,
                expectedVersion: expectedVersion,
                maximumBytes: maximumBytes,
                cancellationCheck: cancellationCheck)
        },
        payloadMaterializedForTesting: (@Sendable () -> Void)? = nil,
        commit: @escaping CommitImplementation
    ) {
        precondition((1...2).contains(maximumConcurrent))
        precondition((0...32).contains(maximumPendingWork))
        self.maximumConcurrent = maximumConcurrent
        self.maximumPendingWork = maximumPendingWork
        self.preparationGrantedForTesting = preparationGrantedForTesting
        self.preparationCompletedForTesting = preparationCompletedForTesting
        self.readImplementation = read
        createImplementation = create
        classificationImplementation = classify
        durabilityConfirmationImplementation = confirmDurability
        self.payloadMaterializedForTesting = payloadMaterializedForTesting
        commitImplementation = commit
    }

    func read(
        _ requestedURL: URL,
        maximumBytes: Int = MarkdownReadLimits.maximumDocumentBytes
    ) async throws -> SecureLocalFileReadSnapshot {
        precondition(maximumBytes >= 0, "read limit must not be negative")
        let waiterID = UUID()
        let cancellation = DocumentIOCancellation()
        return try await withTaskCancellationHandler {
            try await acquirePreparationSlot(id: waiterID)
            defer { releasePreparationSlot() }
            try Task.checkCancellation()
            let implementation = readImplementation
            let snapshot = try await Task.detached(priority: .userInitiated) {
                try implementation(
                    requestedURL,
                    maximumBytes,
                    { cancellation.isCancelled })
            }.value
            preparationCompletedForTesting?()
            try Task.checkCancellation()
            return snapshot
        } onCancel: {
            cancellation.cancel()
            Task { await self.cancelPreparation(id: waiterID) }
        }
    }

    func createUniqueEmptyDocument(
        in folder: URL,
        baseName: String = "Untitled",
        pathExtension: String = "md",
        maximumAttempts: Int = WorkspaceIOBounds.maximumCreateAttempts
    ) async throws -> SecureLocalFileCreationSnapshot {
        guard (1...WorkspaceIOBounds.maximumCreateAttempts).contains(maximumAttempts) else {
            throw SecureLocalFileError.invalidComponent
        }
        let waiterID = UUID()
        let cancellation = DocumentIOCancellation()
        return try await withTaskCancellationHandler {
            try await acquirePreparationSlot(id: waiterID)
            defer { releasePreparationSlot() }
            try Task.checkCancellation()
            let implementation = createImplementation
            let result = try await Task.detached(priority: .userInitiated) {
                try implementation(
                    folder,
                    baseName,
                    pathExtension,
                    maximumAttempts,
                    { cancellation.isCancelled })
            }.value
            preparationCompletedForTesting?()
            try Task.checkCancellation()
            return result
        } onCancel: {
            cancellation.cancel()
            Task { await self.cancelPreparation(id: waiterID) }
        }
    }

    func classify(_ url: URL) async throws -> LocalDocumentEntryKind {
        let waiterID = UUID()
        let cancellation = DocumentIOCancellation()
        return try await withTaskCancellationHandler {
            try await acquirePreparationSlot(id: waiterID)
            defer { releasePreparationSlot() }
            try Task.checkCancellation()
            let implementation = classificationImplementation
            let kind = try await Task.detached(priority: .userInitiated) {
                try implementation(url, { cancellation.isCancelled })
            }.value
            preparationCompletedForTesting?()
            try Task.checkCancellation()
            return kind
        } onCancel: {
            cancellation.cancel()
            Task { await self.cancelPreparation(id: waiterID) }
        }
    }

    func authorizeSaveAs(
        _ requestedURL: URL,
        overwrite: Bool,
        maximumBytes: Int = MarkdownReadLimits.maximumDocumentBytes
    ) async throws -> WorkspaceSaveAuthorization {
        precondition(maximumBytes >= 0, "authorization limit must not be negative")
        let waiterID = UUID()
        let cancellation = DocumentIOCancellation()
        return try await withTaskCancellationHandler {
            try await acquirePreparationSlot(id: waiterID)
            defer { releasePreparationSlot() }
            try Task.checkCancellation()
            let authorization = try await Task.detached(priority: .userInitiated) {
                try Self.authorizeSaveAsSynchronously(
                    requestedURL,
                    overwrite: overwrite,
                    maximumBytes: maximumBytes,
                    cancellationCheck: { cancellation.isCancelled })
            }.value
            preparationCompletedForTesting?()
            try Task.checkCancellation()
            return authorization
        } onCancel: {
            cancellation.cancel()
            Task { await self.cancelPreparation(id: waiterID) }
        }
    }

    func confirmDurability(
        _ authorization: WorkspaceSaveAuthorization,
        expectedVersion: FileVersionToken,
        maximumBytes: Int
    ) async throws {
        precondition(maximumBytes >= 0, "confirmation limit must not be negative")
        let waiterID = UUID()
        let cancellation = DocumentIOCancellation()
        try await withTaskCancellationHandler {
            try await acquirePreparationSlot(id: waiterID)
            defer { releasePreparationSlot() }
            try Task.checkCancellation()
            let implementation = durabilityConfirmationImplementation
            try await Task.detached(priority: .userInitiated) {
                try implementation(
                    authorization,
                    expectedVersion,
                    maximumBytes,
                    { cancellation.isCancelled })
            }.value
            preparationCompletedForTesting?()
            try Task.checkCancellation()
        } onCancel: {
            cancellation.cancel()
            Task { await self.cancelPreparation(id: waiterID) }
        }
    }

    func authorizeOriginal(
        _ destination: URL,
        expectedVersion: FileVersionToken,
        maximumBytes: Int = MarkdownReadLimits.maximumDocumentBytes
    ) async throws -> WorkspaceSaveAuthorization {
        precondition(maximumBytes >= 0, "authorization limit must not be negative")
        let waiterID = UUID()
        let cancellation = DocumentIOCancellation()
        return try await withTaskCancellationHandler {
            try await acquirePreparationSlot(id: waiterID)
            defer { releasePreparationSlot() }
            try Task.checkCancellation()
            let authorization = try await Task.detached(priority: .userInitiated) {
                try Self.authorizeOriginalSynchronously(
                    destination,
                    expectedVersion: expectedVersion,
                    maximumBytes: maximumBytes,
                    cancellationCheck: { cancellation.isCancelled })
            }.value
            preparationCompletedForTesting?()
            try Task.checkCancellation()
            return authorization
        } onCancel: {
            cancellation.cancel()
            Task { await self.cancelPreparation(id: waiterID) }
        }
    }

    func commit(
        _ request: LocalDocumentSaveRequest,
        priority: LocalDocumentSavePriority
    ) async throws -> FileTransactionReceipt {
        let id = UUID()
        let cancellation = DocumentIOCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueue(
                    Job(
                        id: id,
                        request: request,
                        priority: priority,
                        cancellation: cancellation,
                        continuation: continuation))
            }
        } onCancel: {
            cancellation.cancel()
            Task { await self.cancelPending(id: id) }
        }
    }

    nonisolated static func commitSynchronously(
        _ request: LocalDocumentSaveRequest,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) throws -> FileTransactionReceipt {
        let materialized = try request.materialized(cancellationCheck: cancellationCheck)
        var transaction = materialized.authorization.directory.handle.transaction(
            component: materialized.authorization.component,
            data: materialized.data,
            expectation: materialized.authorization.expectation,
            policy: .userContent,
            maximumBytes: materialized.maximumBytes,
            reusableStage: materialized.authorization.reusableStage)
        transaction.cancellationCheck = cancellationCheck
        if let journal = materialized.authorization.recoverySlotSelection?.journalTransaction {
            transaction.preferredStageComponent = journal.preferredStageComponent
            transaction.lifecycleObserver = { event in
                try journal.record(event)
            }
        }
        do {
            let receipt = try transaction.commit()
            if let journal = materialized.authorization.recoverySlotSelection?.journalTransaction {
                do {
                    try journal.finalizeCommitted(receipt)
                } catch {
                    throw SecureLocalFileError.indeterminate(
                        receipt.replacingDurability(
                            .indeterminate(operation: .syncFile, errno: nil)))
                }
            }
            return receipt
        } catch {
            if let journal = materialized.authorization.recoverySlotSelection?.journalTransaction {
                do {
                    try journal.recordFailure(error)
                } catch let journalError as RecoveryJournalError {
                    if case SecureLocalFileError.indeterminate = error {
                        // Preserve the publication-bearing receipt. Registry
                        // settlement observes the context incident separately.
                        throw error
                    }
                    throw SecureLocalFileError.recoveryJournal(journalError)
                }
            }
            throw error
        }
    }

    nonisolated static func readSynchronously(
        _ requestedURL: URL,
        maximumBytes: Int,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) throws -> SecureLocalFileReadSnapshot {
        try SecureLocalFileSystem.read(
            requestedURL,
            maximumBytes: maximumBytes,
            cancellationCheck: cancellationCheck)
    }

    nonisolated static func createUniqueEmptyDocumentSynchronously(
        in folder: URL,
        baseName: String,
        pathExtension: String,
        maximumAttempts: Int,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) throws -> SecureLocalFileCreationSnapshot {
        guard BoundedRegularFileReader.hasLocalFileAuthority(folder),
            (1...WorkspaceIOBounds.maximumCreateAttempts).contains(maximumAttempts),
            !baseName.isEmpty,
            !pathExtension.isEmpty,
            !baseName.contains("/"),
            !pathExtension.contains("/")
        else { throw SecureLocalFileError.invalidComponent }

        let directory = try SecureLocalDirectoryHandle(
            opening: folder,
            cancellationCheck: cancellationCheck)
        for attempt in 0..<maximumAttempts {
            if cancellationCheck() { throw SecureLocalFileError.cancelled }
            let stem = attempt == 0 ? baseName : "\(baseName) \(attempt + 1)"
            let component = try FileComponent("\(stem).\(pathExtension)")
            do {
                return try directory.createExclusiveUserContentFile(
                    component,
                    cancellationCheck: cancellationCheck)
            } catch SecureLocalFileError.operation(.createDocument, let code)
                where code == EEXIST
            {
                continue
            }
        }
        throw LocalDocumentIOError.destinationExists
    }

    nonisolated static func classifySynchronously(
        _ url: URL,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) throws -> LocalDocumentEntryKind {
        guard BoundedRegularFileReader.hasLocalFileAuthority(url) else {
            throw LocalFileResolutionError.notAFileURL(url)
        }
        if cancellationCheck() { throw SecureLocalFileError.cancelled }
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isRegularFileKey,
        ])
        if cancellationCheck() { throw SecureLocalFileError.cancelled }
        if values.isDirectory == true { return .directory }
        if values.isRegularFile == true { return .regularFile }
        return .unsupported
    }

    nonisolated static func confirmDurabilitySynchronously(
        _ authorization: WorkspaceSaveAuthorization,
        expectedVersion: FileVersionToken,
        maximumBytes: Int,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) throws {
        try authorization.directory.confirmDurability(
            component: authorization.component,
            expectedVersion: expectedVersion,
            maximumBytes: maximumBytes,
            cancellationCheck: cancellationCheck)
    }

    nonisolated static func authorizeSaveAsSynchronously(
        _ requestedURL: URL,
        overwrite: Bool,
        maximumBytes: Int = MarkdownReadLimits.maximumDocumentBytes,
        cancellationCheck: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> WorkspaceSaveAuthorization {
        precondition(maximumBytes >= 0, "authorization limit must not be negative")
        if cancellationCheck() { throw SecureLocalFileError.cancelled }
        guard BoundedRegularFileReader.hasLocalFileAuthority(requestedURL) else {
            throw LocalFileResolutionError.notAFileURL(requestedURL)
        }
        let standardized = requestedURL.standardizedFileURL
        let directory = try UserContentDirectory(
            containing: standardized,
            cancellationCheck: cancellationCheck)
        var component = try directory.component(for: standardized)
        let status = try directory.handle.entryStatus(
            component,
            cancellationCheck: cancellationCheck)
        if cancellationCheck() { throw SecureLocalFileError.cancelled }

        let expectation: FileTransactionExpectation
        if let status {
            guard status.st_mode & S_IFMT == S_IFREG else {
                if let alias = aliasDestinationError(for: standardized) { throw alias }
                throw SecureLocalFileError.unsupportedEntry
            }
            guard status.st_nlink == 1 else {
                if let alias = aliasDestinationError(for: standardized) { throw alias }
                throw SecureLocalFileError.hardLinkedEntry
            }
            guard overwrite else { throw LocalDocumentIOError.destinationExists }
            let authorized: SecureLocalDirectoryHandle.ExistingFileAuthorization
            do {
                authorized = try directory.handle.authorizeExistingFile(
                    component,
                    maximumBytes: maximumBytes,
                    cancellationCheck: cancellationCheck)
            } catch SecureLocalFileError.hardLinkedEntry {
                if let alias = aliasDestinationError(for: standardized) { throw alias }
                throw SecureLocalFileError.hardLinkedEntry
            }
            component = authorized.component
            expectation = .exact(authorized.version)
        } else {
            expectation = .missing
        }
        return WorkspaceSaveAuthorization(
            destination: directory.handle.destinationURL(component),
            directory: directory,
            component: component,
            destinationKey: try directory.handle.destinationKey(
                component,
                cancellationCheck: cancellationCheck),
            expectation: expectation,
            recoverySlotSelection: nil)
    }

    nonisolated static func authorizeOriginalSynchronously(
        _ requestedURL: URL,
        expectedVersion: FileVersionToken,
        maximumBytes: Int = MarkdownReadLimits.maximumDocumentBytes,
        cancellationCheck: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> WorkspaceSaveAuthorization {
        precondition(maximumBytes >= 0, "authorization limit must not be negative")
        if cancellationCheck() { throw SecureLocalFileError.cancelled }
        guard BoundedRegularFileReader.hasLocalFileAuthority(requestedURL) else {
            throw LocalFileResolutionError.notAFileURL(requestedURL)
        }
        let standardized = requestedURL.standardizedFileURL
        let directory = try UserContentDirectory(
            containing: standardized,
            cancellationCheck: cancellationCheck)
        var component = try directory.component(for: standardized)
        guard let status = try directory.handle.entryStatus(
            component,
            cancellationCheck: cancellationCheck),
            status.st_mode & S_IFMT == S_IFREG
        else { throw SecureLocalFileError.expectationMismatch }
        guard expectedVersion.size <= maximumBytes else {
            throw SecureLocalFileError.fileTooLarge(maximumBytes: maximumBytes)
        }
        let authorized = try directory.handle.authorizeExistingFile(
            component,
            maximumBytes: maximumBytes,
            cancellationCheck: cancellationCheck)
        guard authorized.version == expectedVersion else {
            throw SecureLocalFileError.expectationMismatch
        }
        component = authorized.component
        if cancellationCheck() { throw SecureLocalFileError.cancelled }
        return WorkspaceSaveAuthorization(
            destination: directory.handle.destinationURL(component),
            directory: directory,
            component: component,
            destinationKey: try directory.handle.destinationKey(
                component,
                cancellationCheck: cancellationCheck),
            expectation: .exact(expectedVersion),
            recoverySlotSelection: nil)
    }

    nonisolated private static func aliasDestinationError(
        for requestedURL: URL
    ) -> LocalDocumentIOError? {
        guard let resolved = try? LocalFileSystem.resolveExisting(requestedURL) else {
            return nil
        }
        return .destinationAlias(resolved.url, resolved.identity)
    }

    private func enqueue(_ job: Job) {
        if job.cancellation.isCancelled {
            job.continuation.resume(throwing: CancellationError())
            return
        }

        if job.priority == .autosave {
            if let index = pending.lastIndex(where: {
                $0.request.documentID == job.request.documentID && $0.priority == .autosave
            }) {
                let superseded = pending.remove(at: index)
                superseded.cancellation.cancel()
                superseded.continuation.resume(throwing: LocalDocumentIOError.superseded)
            }
        } else {
            // A reader explicitly asking to save subsumes any older queued
            // autosave snapshot for this document. Letting that stale job run
            // after the manual receipt would manufacture a conflict against
            // our own newly committed token.
            let superseded = pending.filter {
                $0.request.documentID == job.request.documentID && $0.priority == .autosave
            }
            pending.removeAll {
                $0.request.documentID == job.request.documentID && $0.priority == .autosave
            }
            for old in superseded {
                old.cancellation.cancel()
                old.continuation.resume(throwing: LocalDocumentIOError.superseded)
            }
        }

        let canStartImmediately = activeWorkCount < maximumConcurrent
            && pending.isEmpty
            && pendingPreparations.isEmpty
            && !activeDocuments.contains(job.request.documentID)
        guard canStartImmediately
            || pending.count + pendingPreparations.count < maximumPendingWork
        else {
            job.continuation.resume(throwing: LocalDocumentIOError.busy)
            return
        }

        if job.priority == .manual,
            let firstAutosave = pending.firstIndex(where: { $0.priority == .autosave })
        {
            pending.insert(job, at: firstAutosave)
        } else {
            pending.append(job)
        }
        schedule()
    }

    private func schedule() {
        while activeWorkCount < maximumConcurrent {
            let commitIndex = pending.firstIndex(where: {
                !activeDocuments.contains($0.request.documentID)
            })
            let manualIndex = pending.firstIndex(where: {
                $0.priority == .manual
                    && !activeDocuments.contains($0.request.documentID)
            })
            let autosaveIndex = pending.firstIndex(where: {
                $0.priority == .autosave
                    && !activeDocuments.contains($0.request.documentID)
            })
            if autosaveIndex == nil {
                // This counter measures only a contiguous manual burst while
                // an autosave is actually eligible. Idle/manual-only history
                // must not change scheduling after autosave pressure arrives.
                consecutiveManualCommits = 0
            }
            let manualBurstHasCapacity = autosaveIndex == nil
                || consecutiveManualCommits < Self.maximumConsecutiveManualCommits
            if let manualIndex,
                manualBurstHasCapacity,
                pendingPreparations.isEmpty || !preferPreparation
            {
                // Alternate classes when both remain queued. Manual work gets
                // priority over autosave, but never starves path inspection.
                preferPreparation = true
                launchCommit(at: manualIndex, autosaveWasWaiting: autosaveIndex != nil)
                continue
            }
            if !pendingPreparations.isEmpty,
                commitIndex == nil || preferPreparation
            {
                let preparation = pendingPreparations.removeFirst()
                activeWorkCount += 1
                preferPreparation = false
                preparationGrantedForTesting?()
                preparation.continuation.resume(returning: ())
                continue
            }
            let selectedCommitIndex: Int?
            if let autosaveIndex,
                manualIndex != nil,
                consecutiveManualCommits >= Self.maximumConsecutiveManualCommits
            {
                selectedCommitIndex = autosaveIndex
            } else {
                selectedCommitIndex = commitIndex
            }
            guard let selectedCommitIndex else {
                if let preparation = pendingPreparations.first {
                    pendingPreparations.removeFirst()
                    activeWorkCount += 1
                    preferPreparation = false
                    preparationGrantedForTesting?()
                    preparation.continuation.resume(returning: ())
                    continue
                }
                return
            }
            preferPreparation = true
            launchCommit(
                at: selectedCommitIndex,
                autosaveWasWaiting: autosaveIndex != nil)
        }
    }

    private func launchCommit(at index: Int, autosaveWasWaiting: Bool) {
            let job = pending.remove(at: index)
            if job.cancellation.isCancelled {
                job.continuation.resume(throwing: CancellationError())
                return
            }
            if job.priority == .manual {
                if autosaveWasWaiting,
                    consecutiveManualCommits < Self.maximumConsecutiveManualCommits
                {
                    consecutiveManualCommits += 1
                } else if !autosaveWasWaiting {
                    consecutiveManualCommits = 0
                }
            } else {
                consecutiveManualCommits = 0
            }
            active[job.id] = job
            activeDocuments.insert(job.request.documentID)
            activeWorkCount += 1
            let implementation = commitImplementation
            let payloadMaterializedForTesting = payloadMaterializedForTesting
            Task.detached(priority: job.priority == .manual ? .userInitiated : .utility) {
                let outcome: JobOutcome
                do {
                    let materialized = try job.request.materialized(
                        cancellationCheck: { job.cancellation.isCancelled })
                    payloadMaterializedForTesting?()
                    outcome = .success(
                        try implementation(
                            materialized,
                            { job.cancellation.isCancelled }))
                } catch {
                    outcome = .failure(error)
                }
                await self.finish(id: job.id, outcome: outcome)
            }
    }

    private func finish(id: UUID, outcome: JobOutcome) {
        guard let job = active.removeValue(forKey: id) else { return }
        precondition(
            activeDocuments.remove(job.request.documentID) != nil,
            "an active document must own exactly one scheduler slot")
        precondition(activeWorkCount > 0, "active work count underflow")
        activeWorkCount -= 1
        switch outcome {
        case .success(let receipt):
            job.continuation.resume(returning: receipt)
        case .failure(let error):
            job.continuation.resume(throwing: error)
        }
        schedule()
    }

    private func cancelPending(id: UUID) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let job = pending.remove(at: index)
        job.continuation.resume(throwing: CancellationError())
        schedule()
    }

    private func acquirePreparationSlot(id: UUID) async throws {
        if Task.isCancelled { throw CancellationError() }
        if activeWorkCount < maximumConcurrent,
            pending.isEmpty, pendingPreparations.isEmpty
        {
            activeWorkCount += 1
            return
        }
        guard pending.count + pendingPreparations.count < maximumPendingWork else {
            throw LocalDocumentIOError.busy
        }
        try await withCheckedThrowingContinuation { continuation in
            pendingPreparations.append(
                PreparationWaiter(id: id, continuation: continuation))
            schedule()
        }
        // Once the continuation is resumed, this caller owns one active slot.
        // Do not throw here: authorizeSaveAs/authorizeOriginal first install
        // their `defer { releasePreparationSlot() }`, then check cancellation.
        // Throwing between grant and that ownership transfer leaks the slot.
    }

    private func releasePreparationSlot() {
        precondition(activeWorkCount > 0, "preparation slot released without ownership")
        activeWorkCount -= 1
        schedule()
    }

    private func cancelPreparation(id: UUID) {
        guard let index = pendingPreparations.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = pendingPreparations.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
        schedule()
    }

    func pendingJobCountForTesting() -> Int {
        pending.count
    }

    func workCountsForTesting() -> (active: Int, pending: Int) {
        (activeWorkCount, pending.count + pendingPreparations.count)
    }
}
