//
//  Workspace.swift
//  MarkDevKit
//
//  Panes, their tabs, and the vault they belong to.
//

import Darwin
import Foundation
import SwiftUI

/// A document-state generation that cannot alias after its UInt64 counter
/// wraps. Ordering is needed only within one epoch; equality remains safe
/// across the wrap because a fresh epoch is installed before returning zero.
struct DocumentEditGeneration: Equatable, Sendable {
    private(set) var epoch: UUID
    private(set) var value: UInt64

    init(epoch: UUID = UUID(), value: UInt64 = 0) {
        self.epoch = epoch
        self.value = value
    }

    mutating func advance() {
        if value == .max {
            epoch = UUID()
            value = 0
        } else {
            value += 1
        }
    }
}

/// One open document in a pane.
public struct OpenDocument: Identifiable, Sendable, Equatable {
    public let id: UUID
    public internal(set) var url: URL?
    public internal(set) var text: String
    public internal(set) var hasUnsavedChanges: Bool
    /// A save has published this exact baseline, but the containing directory
    /// could not yet confirm the rename. This is independent of text dirtiness:
    /// an unchanged document can still require close/quit review.
    public internal(set) var hasUnconfirmedDurability: Bool
    /// The exact contents last read from or written to disk. Keeping the
    /// baseline lets dirty state clear when an undo returns to it, and lets a
    /// save detect an edit made by another process before overwriting it.
    var persistedText: String?
    /// Exact descriptor-read authority for ``persistedText``. Save admission
    /// never recomputes this token at save time, because doing so would bless
    /// an identical-byte replacement that arrived after open.
    var persistedVersion: FileVersionToken?
    /// Changes for every edit or authority transition. A save completion may
    /// update a baseline after an edit, but may clear dirty state only when
    /// this still equals the request it wrote.
    var editGeneration: DocumentEditGeneration
    /// Stable identity of the regular file behind `url`. Paths alone cannot
    /// make a symlink and its target (or two hard links) one document.
    var fileIdentity: LocalFileIdentity?

    public init(
        id: UUID = UUID(),
        url: URL? = nil,
        text: String = "",
        hasUnsavedChanges: Bool = false
    ) {
        self.id = id
        let resolved = url.flatMap { try? LocalFileSystem.resolveExisting($0) }
        self.url = resolved?.url ?? url.flatMap {
            BoundedRegularFileReader.hasLocalFileAuthority($0)
                ? $0.standardizedFileURL
                : nil
        }
        self.text = text
        // A path lookup is not exact content authority. Compatibility callers
        // that cannot supply the descriptor-coherent version must remain
        // visibly dirty instead of constructing a clean document that every
        // later save is forced to refuse.
        self.hasUnsavedChanges = url == nil ? hasUnsavedChanges : true
        self.persistedText = nil
        self.persistedVersion = nil
        self.editGeneration = DocumentEditGeneration()
        self.fileIdentity = resolved?.identity
        self.hasUnconfirmedDurability = false
    }

    /// Builds a clean file-backed document from one descriptor-coherent read.
    /// Unlike the compatibility initializer, this never resolves or reopens a
    /// pathname and is therefore safe to call when committing an async read.
    init(
        authoritativeText text: String,
        at url: URL,
        version: FileVersionToken
    ) {
        id = UUID()
        self.url = url.standardizedFileURL
        self.text = text
        hasUnsavedChanges = false
        hasUnconfirmedDurability = false
        persistedText = text
        persistedVersion = version
        editGeneration = DocumentEditGeneration()
        fileIdentity = version.identity
    }

    /// Whether `text` is exactly what was last read from or written to disk.
    ///
    /// Public because the watcher asks it of documents it does not own, and
    /// ``persistedText`` itself must stay private: handing out the baseline
    /// hands out a second source of truth.
    public func matchesPersisted(_ text: String) -> Bool {
        persistedText == text
    }

    /// The document after its file was re-read from disk.
    ///
    /// Both constructors below are the only ways outside code may touch the
    /// persisted baseline, which is what keeps "what was last written" a
    /// fact about files rather than an editable field.
    public func reloaded(from text: String) -> OpenDocument {
        var copy = self
        copy.text = text
        copy.persistedText = nil
        copy.persistedVersion = nil
        copy.hasUnsavedChanges = true
        copy.editGeneration.advance()
        if let url = copy.url,
            let resolved = try? LocalFileSystem.resolveExisting(url)
        {
            copy.url = resolved.url
            copy.fileIdentity = resolved.identity
        }
        return copy
    }

    /// The same document at a new location, after a rename on disk.
    ///
    /// Text and baseline are deliberately carried across unchanged: a rename
    /// moves bytes, it does not edit them.
    public func retargeted(to newURL: URL) -> OpenDocument {
        var copy = self
        copy.persistedText = nil
        copy.persistedVersion = nil
        copy.hasUnsavedChanges = true
        copy.editGeneration.advance()
        if let resolved = try? LocalFileSystem.resolveExisting(newURL) {
            copy.url = resolved.url
            copy.fileIdentity = resolved.identity
        } else {
            copy.url = BoundedRegularFileReader.hasLocalFileAuthority(newURL)
                ? newURL.standardizedFileURL
                : nil
            copy.fileIdentity = nil
        }
        return copy
    }

    /// The document with its baseline moved to what the disk holds now.
    ///
    /// Used when *this app* changed a file out from under an open view —
    /// rename's link rewrites are the case — so autosave keeps covering the
    /// note and no phantom "changed on disk" banner appears for our own
    /// edit. Dirty state survives: text is untouched, and "unsaved" still
    /// means "differs from disk".
    public func rebased(on diskText: String) -> OpenDocument {
        var copy = self
        copy.persistedText = nil
        copy.persistedVersion = nil
        copy.hasUnsavedChanges = true
        copy.editGeneration.advance()
        if let url = copy.url,
            let resolved = try? LocalFileSystem.resolveExisting(url)
        {
            copy.url = resolved.url
            copy.fileIdentity = resolved.identity
        }
        return copy
    }

    /// Token-aware reload used by Workspace after one verified descriptor
    /// read. This avoids reopening by path between bytes and authority.
    func reloaded(from text: String, at url: URL, version: FileVersionToken) -> OpenDocument {
        var copy = self
        copy.url = url
        copy.text = text
        copy.persistedText = text
        copy.persistedVersion = version
        copy.fileIdentity = version.identity
        copy.hasUnsavedChanges = false
        copy.editGeneration.advance()
        return copy
    }

    /// Token-aware rename/rebase variants. Callers that cannot provide a
    /// verified token fail closed by using the public compatibility methods.
    func retargeted(to newURL: URL, version: FileVersionToken) -> OpenDocument {
        var copy = self
        copy.url = newURL.standardizedFileURL
        copy.persistedVersion = version
        copy.fileIdentity = version.identity
        copy.editGeneration.advance()
        return copy
    }

    func rebased(
        on diskText: String,
        at url: URL,
        version: FileVersionToken
    ) -> OpenDocument {
        var copy = self
        copy.url = url.standardizedFileURL
        copy.persistedText = diskText
        copy.persistedVersion = version
        copy.fileIdentity = version.identity
        copy.hasUnsavedChanges = copy.text != diskText
        copy.editGeneration.advance()
        return copy
    }

    /// Title for the tab. Untitled documents still need a stable label.
    public var title: String {
        url?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }

    public var requiresCloseReview: Bool {
        hasUnsavedChanges || hasUnconfirmedDurability
    }
}

/// The UTF-8 text and exact authority produced by one coherent descriptor
/// read. The injection seam is internal so lifecycle tests can force an
/// initial path observation to disagree with the authoritative read without
/// introducing a second production reader.
struct WorkspaceDocumentReadSnapshot: Sendable {
    let text: String
    let version: FileVersionToken
    let canonicalURL: URL
    let destinationKey: FileDestinationKey
}

public enum WorkspaceLocalEntryKind: Equatable, Sendable {
    case regularFile
    case directory
    case unsupported
}

public struct WorkspaceCreatedDocument: Equatable, Sendable {
    public let url: URL
    public let isFullyDurable: Bool
}

public struct WorkspaceDiskText: Equatable, Sendable {
    public let relativePath: String
    public let text: String
}

public struct WorkspaceExternalChangeBatch: Equatable, Sendable {
    public let changedNotes: [WorkspaceDiskText]
    public let missingNotePaths: [String]
    public let conflictingDocumentIDs: Set<OpenDocument.ID>
    public let failedItemNames: [String]
    public let omittedFailureCount: Int
    public let omittedPathCount: Int
    public let staleDocumentCount: Int
}

public struct WorkspaceDiskRebaseReport: Equatable, Sendable {
    public let appliedCount: Int
    public let staleDocumentCount: Int
    public let failedItemNames: [String]
    public let omittedFailureCount: Int
    public let omittedDocumentCount: Int

    public var isComplete: Bool {
        staleDocumentCount == 0
            && failedItemNames.isEmpty
            && omittedFailureCount == 0
            && omittedDocumentCount == 0
    }
}

public struct WorkspaceRestoreReport: Equatable, Sendable {
    public let restoredDocumentCount: Int
    public let failedItemNames: [String]
    public let omittedFailureCount: Int

    public var isComplete: Bool {
        failedItemNames.isEmpty && omittedFailureCount == 0
    }
}

/// What ``Workspace/apply(text:in:)`` did with an edit.
///
/// Exists because the `Bool` it replaces could not tell a caller whether a
/// refusal cost the reader anything. Both "no document is open" and "this edit
/// would exceed the parser's limit" answered `false`, and only the second
/// means text the reader typed is about to vanish: the model keeps the old
/// string, SwiftUI pushes it back into the editor, and the paste is reverted
/// with nothing said.
public enum TextUpdateOutcome: Equatable, Sendable {
    /// The document now holds the new text.
    case applied
    /// The document already held exactly this text.
    case unchanged
    /// No document is open in that pane. Benign, and not worth reporting.
    case noDocument
    /// The edit would take the document past ``MarkdownReadLimits``.
    case refusedTooLarge(byteCount: Int, limit: Int)

    /// Whether the model reflects the caller's text — the old `Bool`.
    public var didApply: Bool {
        switch self {
        case .applied, .unchanged: true
        case .noDocument, .refusedTooLarge: false
        }
    }

    /// What to tell the reader, or nil when there is nothing they can act on.
    public var readerMessage: String? {
        guard case let .refusedTooLarge(_, limit) = self else { return nil }
        let readable = ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)
        return "That edit would make this document larger than \(readable), "
            + "which is more than MarkDev can edit safely. The document has been left as it was."
    }
}

/// Recoverable document-lifecycle failures surfaced by ``Workspace``.
public enum WorkspaceError: Error, Equatable, LocalizedError {
    case noDocument
    case paneUnavailable
    case needsSaveDestination
    case destinationAlreadyOpen(URL)
    case destinationExists(URL)
    case ioBusy
    case saveInProgress(URL?)
    case saveSuperseded
    case savePublishedButNotSettled(URL, WorkspaceSaveSettlement)
    case documentChangedOnDisk(URL)
    case documentUnavailable(URL)
    case documentOperationSuperseded(URL?)
    case documentTooLarge(maximumBytes: Int)
    case noteNameCapacityReached(maximumAttempts: Int)
    case recoveryCapacityReached(maximumSlots: Int)
    case recoveryRequiresReview(URL)
    case recoveryJournalRequiresReview(WorkspaceRecoveryJournalIssue)
    case unsafeDestination(URL)
    case unsupportedLocation(URL)

    public var errorDescription: String? {
        switch self {
        case .noDocument:
            return "There is no document to save."
        case .paneUnavailable:
            return "The target editor is no longer open."
        case .needsSaveDestination:
            return "Choose a name and location before saving this document."
        case .destinationAlreadyOpen(let url):
            return "\(url.lastPathComponent) is already open in this workspace."
        case .destinationExists(let url):
            return "\(url.lastPathComponent) already exists."
        case .ioBusy:
            return "MarkDev is already handling the maximum number of file operations. Try again."
        case .saveInProgress(let url):
            return "\(url?.lastPathComponent ?? "This document") is already being saved."
        case .saveSuperseded:
            return "A newer save request replaced this one."
        case .savePublishedButNotSettled(let url, let settlement):
            switch settlement {
            case .applied:
                return nil
            case .documentClosed:
                return "\(url.lastPathComponent) was written, but its document closed before the save could update the window."
            case .sourceChanged:
                return "\(url.lastPathComponent) was written, but the open document changed location or reloaded before the save completed."
            case .destinationCollision:
                return "\(url.lastPathComponent) was written, but another open document now owns that destination."
            }
        case .documentChangedOnDisk(let url):
            return "\(url.lastPathComponent) changed on disk. Reload it or use Save As to preserve both versions."
        case .documentUnavailable(let url):
            return "\(url.lastPathComponent) could not be read as a safe local document."
        case .documentOperationSuperseded(let url):
            return "\(url?.lastPathComponent ?? "The document") changed before the file operation finished. Nothing stale was applied."
        case .documentTooLarge(let maximumBytes):
            let readable = ByteCountFormatter.string(
                fromByteCount: Int64(maximumBytes), countStyle: .file)
            return "This document is too large to edit or save safely. The limit is \(readable)."
        case .noteNameCapacityReached(let maximumAttempts):
            return "No available Untitled note name was found after \(maximumAttempts) attempts. Choose a name first."
        case .recoveryCapacityReached(let maximumSlots):
            return "MarkDev is retaining \(maximumSlots) recovery files and will not create another until they can be reviewed safely."
        case .recoveryRequiresReview(let url):
            return "\(url.lastPathComponent) has an unresolved recovery file. Use Save As to preserve this edit without overwriting that evidence."
        case .recoveryJournalRequiresReview:
            return "MarkDev's recovery journal requires review. Saving is blocked so recovery evidence is not overwritten."
        case .unsafeDestination(let url):
            return "\(url.lastPathComponent) is not a safe regular-file destination."
        case .unsupportedLocation(let url):
            return "MarkDev can only open files on this Mac, and \(url.scheme ?? "that location") is not one."
        }
    }
}

public enum WorkspaceRecoveryJournalIssue: String, Equatable, Sendable {
    case applicationSupportUnavailable
    case unsafeStorage
    case corrupt
    case unsupportedSchema
    case recoveryIncident
    case busy
    case durabilityUncertain
    case capacityExhausted
    case cancelled
    case unknown
}

public enum WorkspaceRecoveryJournalState: Equatable, Sendable {
    case processOnlyForTesting
    case ready(retainedCount: Int)
    case requiresReview(WorkspaceRecoveryJournalIssue)
}

/// The file boundary for editor-targeted drops.
public enum MarkdownDropPolicy {
    /// Whether `url` is a Markdown file type declared by MarkDev.
    ///
    /// A directory named `Archive.md` is still a directory and must remain a
    /// vault drop rather than being sent through the document reader.
    public static func accepts(_ url: URL) -> Bool {
        guard BoundedRegularFileReader.hasLocalFileAuthority(url),
            FileTree.isMarkdown(url), !url.hasDirectoryPath
        else {
            return false
        }
        return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
    }
}

/// The documents open in one pane, and which is frontmost.
public struct PaneState: Sendable, Equatable {
    public var documents: [OpenDocument]
    public var selection: OpenDocument.ID?

    public init(documents: [OpenDocument] = [], selection: OpenDocument.ID? = nil) {
        self.documents = documents
        self.selection = selection
    }

    public var current: OpenDocument? {
        documents.first { $0.id == selection } ?? documents.first
    }
}

/// Exact document identities that stopped being represented anywhere after a
/// tab or pane close. UI-owned state keyed by document identity (for example,
/// an external-change warning) may be pruned only from this outcome: removing
/// one side of a split is not the same as closing the document.
public struct WorkspaceCloseOutcome: Equatable, Sendable {
    public let documentIDsNoLongerOpen: Set<OpenDocument.ID>

    init(documentIDsNoLongerOpen: Set<OpenDocument.ID> = []) {
        self.documentIDsNoLongerOpen = documentIDsNoLongerOpen
    }
}

/// Exact accounting for one bounded autosave pass. Counts never present a
/// capped subset as complete: documents and bytes omitted by either budget are
/// reported explicitly.
public enum WorkspaceSaveDurability: Equatable, Sendable {
    /// File bytes and the containing directory entry were both synced.
    case fullySynced
    /// New bytes are visible and file-synced, but the directory sync failed.
    case directorySyncUnconfirmed
}

/// Whether a published save receipt could also be applied to the live model.
/// Publication is irreversible at this point, so stale lifecycle state must
/// remain distinct from both an I/O failure and an ordinary applied save.
public enum WorkspaceSaveSettlement: Equatable, Sendable {
    case applied
    case documentClosed
    case sourceChanged
    case destinationCollision
}

/// Truthful result for a save whose publication completed. A committed save
/// is not necessarily fully durable across sudden power loss, and callers that
/// review close/quit must be able to distinguish those states.
public struct WorkspaceSaveOutcome: Equatable, Sendable {
    public let destination: URL
    public let durability: WorkspaceSaveDurability
    public let settlement: WorkspaceSaveSettlement
    public let byteCount: Int
    /// Directory durability and retained recovery are orthogonal: a save can
    /// be fully synced while its exact displaced predecessor remains available.
    public let directorySyncErrno: Int32?
    let recovery: FileRecoveryAuthority?

    var recoveryComponent: FileComponent? { recovery?.component }
    var recoveryVersion: FileVersionToken? { recovery?.version }

    public var isFullyDurable: Bool { durability == .fullySynced }
    public var requiresRecovery: Bool { recoveryComponent != nil }
    public var hasUnconfirmedDurability: Bool { directorySyncErrno != nil }
    public var didSettleLiveDocument: Bool { settlement == .applied }

    init(
        receipt: FileTransactionReceipt,
        byteCount: Int,
        settlement: WorkspaceSaveSettlement
    ) throws {
        destination = receipt.destination
        self.byteCount = byteCount
        self.settlement = settlement
        recovery = receipt.recovery
        switch receipt.durability {
        case .fullySynced:
            guard receipt.recovery == nil else {
                throw SecureLocalFileError.indeterminate(receipt)
            }
            durability = .fullySynced
            directorySyncErrno = nil
        case .committedDirectorySyncUnconfirmed(let code):
            guard receipt.recovery == nil else {
                throw SecureLocalFileError.indeterminate(receipt)
            }
            durability = .directorySyncUnconfirmed
            directorySyncErrno = code
        case .recoveryRetained(let directoryCode):
            guard receipt.recovery != nil else {
                throw SecureLocalFileError.indeterminate(receipt)
            }
            durability = directoryCode == nil ? .fullySynced : .directorySyncUnconfirmed
            directorySyncErrno = directoryCode
        case .notPublishedRecoveryRetained, .notPublishedRecoveryUnconfirmed,
            .indeterminate:
            throw SecureLocalFileError.indeterminate(receipt)
        }
    }
}

public struct WorkspaceAutosaveReport: Equatable, Sendable {
    public var consideredCount = 0
    public var attemptedCount = 0
    public var succeededCount = 0
    public var conflictCount = 0
    public var failureCount = 0
    public var cancelledCount = 0
    public var deferredCount = 0
    /// The bytes reached disk, but a close/reload/retarget/collision prevented
    /// the receipt from becoming the authority of the live document.
    public var publishedUnsettledCount = 0
    public var consideredBytes = 0
    public var attemptedBytes = 0
    public var succeededBytes = 0
    public var conflictBytes = 0
    public var failureBytes = 0
    public var cancelledBytes = 0
    public var deferredBytes = 0
    public var publishedUnsettledBytes = 0
    /// Subsets of `succeededCount`/`succeededBytes`, not additional outcomes.
    public var directorySyncUnconfirmedCount = 0
    public var directorySyncUnconfirmedBytes = 0
    public var recoveryRetainedCount = 0
    public var recoveryRetainedBytes = 0

    public init() {}

    /// Thin compatibility projection for existing callers that only displayed
    /// whether anything was written.
    public var writtenCount: Int { succeededCount }
}

public enum WorkspaceDurabilityConfirmationResult: Equatable, Sendable {
    case notRequired
    case confirmed
    /// The bounded retained-authority cache was full. The document remains in
    /// close review and a later ordinary save can establish durability.
    case authorityUnavailable
    /// The live document changed after confirmation started. No current state
    /// was cleared by the stale completion.
    case stale
}

struct ProcessFileTransactionOwner: Hashable, Sendable {
    let workspaceID: UUID
    let documentID: OpenDocument.ID
}

enum ProcessFileTransactionRegistryError: Error, Equatable {
    case destinationReserved
    case recoveryRequiresReview
    case capacityReached(maximumSlots: Int)
    case journalRequiresReview(RecoveryJournalError)
}

enum ProcessRecoveryJournalState: Equatable, Sendable {
    /// Internal tests that do not exercise persistence opt into the historical
    /// process-only registry explicitly by constructing a fresh registry.
    case processOnlyForTesting
    case ready(fileSetID: UUID, retainedCount: Int)
    case requiresReview(RecoveryJournalError)
}

/// The single MainActor-owned seam for process-wide destination leases and
/// retained file-recovery capabilities. Production workspaces share one
/// instance; tests may inject a fresh instance without silently evicting or
/// deleting any artifact.
@MainActor
final class ProcessFileTransactionRegistry {
    private struct Reservation: Equatable, Sendable {
        let owner: ProcessFileTransactionOwner
        let leaseRevision: FileRecoverySlotRevision
    }

    enum Entry: Equatable, Sendable {
        case reserved(
            revision: FileRecoverySlotRevision,
            owner: ProcessFileTransactionOwner)
        case reusable(
            revision: FileRecoverySlotRevision,
            slot: FileRecoverySlot,
            owner: ProcessFileTransactionOwner?)
        case incident(
            revision: FileRecoverySlotRevision,
            authority: FileRecoveryAuthority?)

        var revision: FileRecoverySlotRevision {
            switch self {
            case .reserved(let revision, _),
                .reusable(let revision, _, _),
                .incident(let revision, _):
                revision
            }
        }
    }

    enum CommitSettlement: Equatable, Sendable {
        case settled(revision: FileRecoverySlotRevision?)
        case incident
        case stale
    }

    static let shared: ProcessFileTransactionRegistry = {
        do {
            return ProcessFileTransactionRegistry(
                maximumSlots: Workspace.maximumProcessRecoverySlots,
                recoveryJournal: try RecoveryJournal.production())
        } catch let error as RecoveryJournalError {
            return ProcessFileTransactionRegistry(
                maximumSlots: Workspace.maximumProcessRecoverySlots,
                journalStartupFailure: error)
        } catch {
            return ProcessFileTransactionRegistry(
                maximumSlots: Workspace.maximumProcessRecoverySlots,
                journalStartupFailure: .applicationSupportUnavailable)
        }
    }()

    private let maximumSlots: Int
    private let recoveryJournal: RecoveryJournal?
    private let journalCheckpointDidPersist: (
        @Sendable (RecoveryJournalCheckpoint) -> RecoveryJournalError?
    )?
    private var journalEntries: [FileDestinationKey: RecoveryJournalEntry] = [:]
    private(set) var journalState: ProcessRecoveryJournalState
    private var entries: [FileDestinationKey: Entry] = [:]
    private var destinationReservations: [
        FileDestinationReservationAlias: Reservation
    ] = [:]
    private var identityReservations: [
        LocalFileIdentity: Reservation
    ] = [:]

    init(
        maximumSlots: Int = Workspace.maximumProcessRecoverySlots,
        recoveryJournal: RecoveryJournal? = nil,
        journalCheckpointDidPersist: (
            @Sendable (RecoveryJournalCheckpoint) -> RecoveryJournalError?
        )? = nil
    ) {
        precondition(maximumSlots > 0)
        self.maximumSlots = maximumSlots
        self.recoveryJournal = recoveryJournal
        self.journalCheckpointDidPersist = journalCheckpointDidPersist
        journalState = recoveryJournal == nil
            ? .processOnlyForTesting
            : .requiresReview(.invalidEntry)
        if let recoveryJournal {
            do {
                let startup = try RecoveryJournalStartup.reconcile(
                    journal: recoveryJournal,
                    cancellationCheck: { false })
                guard startup.retained.count <= maximumSlots else {
                    throw RecoveryJournalError.tooManyEntries(maximum: maximumSlots)
                }
                for retained in startup.retained {
                    let key = retained.slot.authority.destinationKey
                    let revision = FileRecoverySlotRevision()
                    entries[key] = .reusable(
                        revision: revision,
                        slot: retained.slot,
                        owner: nil)
                    journalEntries[key] = retained.entry
                }
                journalState = .ready(
                    fileSetID: startup.fileSetID,
                    retainedCount: startup.retained.count)
            } catch let error as RecoveryJournalError {
                entries.removeAll()
                journalEntries.removeAll()
                journalState = .requiresReview(error)
            } catch {
                entries.removeAll()
                journalEntries.removeAll()
                journalState = .requiresReview(.invalidEntry)
            }
        }
    }

    /// Constructs the same fail-closed state used when the production journal
    /// cannot be opened. Keeping this as a distinct initializer makes it
    /// impossible to confuse an unavailable journal with the explicit
    /// process-only test mode.
    init(
        maximumSlots: Int = Workspace.maximumProcessRecoverySlots,
        journalStartupFailure: RecoveryJournalError
    ) {
        precondition(maximumSlots > 0)
        self.maximumSlots = maximumSlots
        recoveryJournal = nil
        journalCheckpointDidPersist = nil
        journalState = .requiresReview(journalStartupFailure)
    }

    func ensureAvailable(
        destinationKey: FileDestinationKey,
        identity: LocalFileIdentity?,
        owner: ProcessFileTransactionOwner?
    ) throws {
        if let reserved = destinationReservations[destinationKey.reservationAlias],
            reserved.owner != owner
        {
            throw ProcessFileTransactionRegistryError.destinationReserved
        }
        if let identity,
            let reserved = identityReservations[identity],
            reserved.owner != owner
        {
            throw ProcessFileTransactionRegistryError.destinationReserved
        }
    }

    /// Atomically reserves both one destination and, when needed, one bounded
    /// registry generation before an off-main commit can start.
    func begin(
        destinationKey: FileDestinationKey,
        destinationURL: URL? = nil,
        identity: LocalFileIdentity?,
        expectation: FileTransactionExpectation,
        owner: ProcessFileTransactionOwner
    ) throws -> FileRecoverySlotSelection {
        if case .requiresReview(let error) = journalState {
            throw ProcessFileTransactionRegistryError.journalRequiresReview(error)
        }
        try ensureAvailable(
            destinationKey: destinationKey,
            identity: identity,
            owner: owner)
        // `ensureAvailable` permits the owning document to observe its own
        // in-flight reservation. Mutation leasing is stricter: even the same
        // owner cannot concurrently acquire one reusable inode twice.
        guard destinationReservations[destinationKey.reservationAlias] == nil,
            identity.map({ identityReservations[$0] == nil }) ?? true
        else { throw ProcessFileTransactionRegistryError.destinationReserved }

        var selection: FileRecoverySlotSelection
        if let entry = entries[destinationKey] {
            switch entry {
            case .reserved:
                throw ProcessFileTransactionRegistryError.destinationReserved
            case .incident:
                throw ProcessFileTransactionRegistryError.recoveryRequiresReview
            case .reusable(let revision, let slot, _):
                guard slot.authority.destinationKey == destinationKey else {
                    entries[destinationKey] = .incident(
                        revision: FileRecoverySlotRevision(),
                        authority: slot.authority)
                    throw ProcessFileTransactionRegistryError.recoveryRequiresReview
                }
                switch expectation {
                case .exact:
                    selection = FileRecoverySlotSelection(
                        observedRevision: revision,
                        reusableStage: slot)
                case .missing where slot.contents == .unpublishedScratch:
                    selection = FileRecoverySlotSelection(
                        observedRevision: revision,
                        reusableStage: slot)
                case .missing:
                    throw ProcessFileTransactionRegistryError.recoveryRequiresReview
                }
            }
        } else {
            guard entries.count < maximumSlots else {
                throw ProcessFileTransactionRegistryError.capacityReached(
                    maximumSlots: maximumSlots)
            }
            let revision = FileRecoverySlotRevision()
            entries[destinationKey] = .reserved(revision: revision, owner: owner)
            selection = FileRecoverySlotSelection(
                observedRevision: revision,
                reusableStage: nil)
        }

        if let recoveryJournal {
            guard let destinationURL else {
                journalState = .requiresReview(.invalidEntry)
                throw ProcessFileTransactionRegistryError.journalRequiresReview(.invalidEntry)
            }
            let previousEntry = journalEntries[destinationKey]
            if selection.reusableStage != nil, previousEntry == nil {
                installIncident(
                    destinationKey: destinationKey,
                    selection: selection,
                    authority: selection.reusableStage?.authority)
                journalState = .requiresReview(.invalidEntry)
                throw ProcessFileTransactionRegistryError.journalRequiresReview(.invalidEntry)
            }
            do {
                let context = try RecoveryJournalTransactionContext(
                    journal: recoveryJournal,
                    previousEntry: previousEntry,
                    destinationURL: destinationURL,
                    destinationKey: destinationKey,
                    expectation: expectation,
                    reusableStage: selection.reusableStage,
                    checkpointDidPersist: journalCheckpointDidPersist)
                selection = FileRecoverySlotSelection(
                    observedRevision: selection.observedRevision,
                    reusableStage: selection.reusableStage,
                    journalTransaction: context)
            } catch let error as RecoveryJournalError {
                installIncident(
                    destinationKey: destinationKey,
                    selection: selection,
                    authority: selection.reusableStage?.authority)
                journalState = .requiresReview(error)
                throw ProcessFileTransactionRegistryError.journalRequiresReview(error)
            }
        }

        let reservation = Reservation(
            owner: owner,
            leaseRevision: selection.observedRevision)
        destinationReservations[destinationKey.reservationAlias] = reservation
        if let identity { identityReservations[identity] = reservation }
        return selection
    }

    func release(
        destinationKey: FileDestinationKey,
        identity: LocalFileIdentity?,
        owner: ProcessFileTransactionOwner,
        leaseRevision: FileRecoverySlotRevision
    ) {
        let reservation = Reservation(owner: owner, leaseRevision: leaseRevision)
        if destinationReservations[destinationKey.reservationAlias] == reservation {
            destinationReservations[destinationKey.reservationAlias] = nil
        }
        if let identity, identityReservations[identity] == reservation {
            identityReservations[identity] = nil
        }
    }

    /// Advances only the exact generation leased by this transaction. This
    /// cleanly separates filesystem settlement from any later UI settlement.
    @discardableResult
    func settleCommitted(
        destinationKey: FileDestinationKey,
        expectation: FileTransactionExpectation,
        selection: FileRecoverySlotSelection,
        receipt: FileTransactionReceipt
    ) -> CommitSettlement {
        guard entries[destinationKey]?.revision == selection.observedRevision else {
            if selection.journalTransaction?.currentEntry != nil {
                journalState = .requiresReview(.invalidEntry)
            }
            return .stale
        }
        if let context = selection.journalTransaction {
            switch context.resolution {
            case .committed(let entry):
                guard receipt.recoverySlot != nil else {
                    installIncident(
                        destinationKey: destinationKey,
                        selection: selection,
                        authority: nil)
                    journalState = .requiresReview(.invalidEntry)
                    return .incident
                }
                journalEntries[destinationKey] = entry
            case .cleared:
                guard receipt.recoverySlot == nil else {
                    installIncident(
                        destinationKey: destinationKey,
                        selection: selection,
                        authority: receipt.recovery)
                    journalState = .requiresReview(.invalidEntry)
                    return .incident
                }
                journalEntries[destinationKey] = nil
            case .active, .reusable, .incident:
                installIncident(
                    destinationKey: destinationKey,
                    selection: selection,
                    authority: receipt.recovery ?? selection.reusableStage?.authority)
                journalState = .requiresReview(.invalidEntry)
                return .incident
            }
        } else if recoveryJournal != nil {
            installIncident(
                destinationKey: destinationKey,
                selection: selection,
                authority: receipt.recovery ?? selection.reusableStage?.authority)
            journalState = .requiresReview(.invalidEntry)
            return .incident
        }
        if let slot = receipt.recoverySlot {
            guard slot.authority.destinationKey == destinationKey else {
                entries[destinationKey] = .incident(
                    revision: FileRecoverySlotRevision(),
                    authority: slot.authority)
                return .incident
            }
            let revision = FileRecoverySlotRevision()
            entries[destinationKey] = .reusable(
                revision: revision,
                slot: slot,
                owner: nil)
            refreshJournalReadyCount()
            return .settled(revision: revision)
        }

        switch expectation {
        case .missing:
            // Either a fresh or retained scratch inode became the destination.
            entries[destinationKey] = nil
            journalEntries[destinationKey] = nil
            refreshJournalReadyCount()
            return .settled(revision: nil)
        case .exact where selection.reusableStage == nil:
            // Alternate injected committers may deliberately retain no recovery.
            // Production FileTransaction exact commits always return one.
            entries[destinationKey] = nil
            journalEntries[destinationKey] = nil
            refreshJournalReadyCount()
            return .settled(revision: nil)
        case .exact:
            let revision = FileRecoverySlotRevision()
            entries[destinationKey] = .incident(
                revision: revision,
                authority: selection.reusableStage?.authority)
            return .incident
        }
    }

    func settleFailure(
        _ error: Error,
        destinationKey: FileDestinationKey,
        selection: FileRecoverySlotSelection
    ) {
        guard entries[destinationKey]?.revision == selection.observedRevision else {
            if selection.journalTransaction?.currentEntry != nil {
                journalState = .requiresReview(.invalidEntry)
            }
            return
        }

        if let context = selection.journalTransaction {
            switch context.resolution {
            case .cleared:
                journalEntries[destinationKey] = nil
                abortReserved(destinationKey: destinationKey, selection: selection)
                refreshJournalReadyCount()
            case .reusable(let entry, let slot):
                guard slot.authority.destinationKey == destinationKey else {
                    installIncident(
                        destinationKey: destinationKey,
                        selection: selection,
                        authority: slot.authority)
                    journalState = .requiresReview(.invalidEntry)
                    return
                }
                journalEntries[destinationKey] = entry
                entries[destinationKey] = .reusable(
                    revision: FileRecoverySlotRevision(),
                    slot: slot,
                    owner: nil)
                refreshJournalReadyCount()
            case .active(let entry), .committed(let entry):
                journalEntries[destinationKey] = entry
                installIncident(
                    destinationKey: destinationKey,
                    selection: selection,
                    authority: selection.reusableStage?.authority)
                journalState = .requiresReview(.invalidEntry)
            case .incident(let entry):
                if let entry { journalEntries[destinationKey] = entry }
                installIncident(
                    destinationKey: destinationKey,
                    selection: selection,
                    authority: selection.reusableStage?.authority)
                journalState = .requiresReview(.invalidEntry)
            }
            return
        } else if recoveryJournal != nil {
            installIncident(
                destinationKey: destinationKey,
                selection: selection,
                authority: selection.reusableStage?.authority)
            journalState = .requiresReview(.invalidEntry)
            return
        }

        if error is CancellationError || error is LocalDocumentIOError {
            abortReserved(destinationKey: destinationKey, selection: selection)
            return
        }
        guard let secureError = error as? SecureLocalFileError else {
            installIncident(
                destinationKey: destinationKey,
                selection: selection,
                authority: selection.reusableStage?.authority)
            return
        }
        switch secureError {
        case .prepublicationFailure(let cause, let receipt):
            guard receipt.isValidPrepublicationFailure,
                Workspace.failureIsKnownNotPublished(cause)
            else {
                installIncident(
                    destinationKey: destinationKey,
                    selection: selection,
                    authority: receipt.recovery ?? selection.reusableStage?.authority)
                return
            }
            if let slot = receipt.recoverySlot,
                receipt.destinationKey == destinationKey,
                slot.authority.destinationKey == destinationKey
            {
                entries[destinationKey] = .reusable(
                    revision: FileRecoverySlotRevision(),
                    slot: slot,
                    owner: nil)
            } else {
                installIncident(
                    destinationKey: destinationKey,
                    selection: selection,
                    authority: selection.reusableStage?.authority)
            }
        case .indeterminate(let receipt):
            installIncident(
                destinationKey: destinationKey,
                selection: selection,
                authority: receipt.recovery ?? selection.reusableStage?.authority)
        case .recoverySlotUnavailable:
            installIncident(
                destinationKey: destinationKey,
                selection: selection,
                authority: selection.reusableStage?.authority)
        default:
            // These exhaustive errors are proven no-effect unless wrapped in
            // prepublicationFailure by FileTransaction after stage acquisition.
            abortReserved(destinationKey: destinationKey, selection: selection)
        }
    }

    func settleInvalidReceipt(
        destinationKey: FileDestinationKey,
        selection: FileRecoverySlotSelection,
        receipt: FileTransactionReceipt
    ) {
        installIncident(
            destinationKey: destinationKey,
            selection: selection,
            authority: receipt.recovery ?? selection.reusableStage?.authority)
        if selection.journalTransaction != nil {
            journalState = .requiresReview(.invalidEntry)
        }
    }

    func associateReusableSlot(
        with owner: ProcessFileTransactionOwner,
        destinationKey: FileDestinationKey,
        revision: FileRecoverySlotRevision?
    ) {
        detachReusableSlots(from: owner)
        guard let revision,
            case .reusable(let currentRevision, let slot, _) = entries[destinationKey],
            currentRevision == revision
        else { return }
        entries[destinationKey] = .reusable(
            revision: currentRevision,
            slot: slot,
            owner: owner)
    }

    func detachReusableSlots(from owner: ProcessFileTransactionOwner) {
        for (key, entry) in entries {
            guard case .reusable(let revision, let slot, .some(let currentOwner)) = entry,
                currentOwner == owner
            else {
                continue
            }
            entries[key] = .reusable(revision: revision, slot: slot, owner: nil)
        }
    }

    func reservationOwners(
        destinationKey: FileDestinationKey,
        identity: LocalFileIdentity
    ) -> Set<ProcessFileTransactionOwner> {
        Set([
            destinationReservations[destinationKey.reservationAlias]?.owner,
            identityReservations[identity]?.owner,
        ].compactMap { $0 })
    }

    private func abortReserved(
        destinationKey: FileDestinationKey,
        selection: FileRecoverySlotSelection
    ) {
        guard case .reserved(let revision, _) = entries[destinationKey],
            revision == selection.observedRevision
        else { return }
        entries[destinationKey] = nil
    }

    private func installIncident(
        destinationKey: FileDestinationKey,
        selection: FileRecoverySlotSelection,
        authority: FileRecoveryAuthority?
    ) {
        guard entries[destinationKey]?.revision == selection.observedRevision else {
            return
        }
        entries[destinationKey] = .incident(
            revision: FileRecoverySlotRevision(),
            authority: authority)
    }

    private func refreshJournalReadyCount() {
        guard case .ready(let fileSetID, _) = journalState else { return }
        journalState = .ready(
            fileSetID: fileSetID,
            retainedCount: journalEntries.count)
    }

    var entryCountForTesting: Int { entries.count }

    func entryForTesting(destinationKey: FileDestinationKey) -> Entry? {
        entries[destinationKey]
    }

    func advanceRevisionForTesting(destinationKey: FileDestinationKey) {
        guard let entry = entries[destinationKey] else { return }
        let revision = FileRecoverySlotRevision()
        switch entry {
        case .reserved(_, let owner):
            entries[destinationKey] = .reserved(revision: revision, owner: owner)
        case .reusable(_, let slot, let owner):
            entries[destinationKey] = .reusable(
                revision: revision,
                slot: slot,
                owner: owner)
        case .incident(_, let authority):
            entries[destinationKey] = .incident(
                revision: revision,
                authority: authority)
        }
    }

    func fillWithIncidentsForTesting(using baseKey: FileDestinationKey) throws {
        precondition(destinationReservations.isEmpty && identityReservations.isEmpty)
        entries.removeAll(keepingCapacity: true)
        entries[baseKey] = .incident(
            revision: FileRecoverySlotRevision(),
            authority: nil)
        for index in 1..<maximumSlots {
            let component = try FileComponent("capacity-\(index)")
            let key = FileDestinationKey(
                directoryIdentity: baseKey.directoryIdentity,
                component: component,
                caseSensitiveNames: true)
            entries[key] = .incident(
                revision: FileRecoverySlotRevision(),
                authority: nil)
        }
    }

    func resetForTesting() {
        precondition(destinationReservations.isEmpty && identityReservations.isEmpty)
        precondition(!entries.values.contains { entry in
            if case .reserved = entry { return true }
            return false
        })
        entries.removeAll()
    }
}

/// The whole window: a split layout, the panes it contains, and the vault
/// root the navigator shows.
///
/// Observable so SwiftUI tracks it, but the interesting logic — opening a
/// document that is already open, closing the last tab in a pane — lives in
/// plain methods that can be tested without a view.
@MainActor
@Observable
public final class Workspace {
    static let maximumCoalescedSaveWaiters = 32
    static let maximumRetainedDurabilityConfirmations = 8
    static let maximumProcessRecoverySlots = 256

    public private(set) var layout: SplitLayout
    public private(set) var panes: [PaneID: PaneState]
    public var focusedPane: PaneID
    public var vaultRoot: URL?
    private let diagnostics: DiagnosticsEmitter
    @ObservationIgnored private let documentIO: LocalDocumentIO
    @ObservationIgnored private let documentRead: @Sendable (
        URL,
        Int
    ) throws -> WorkspaceDocumentReadSnapshot
    @ObservationIgnored private let documentReadAsync: @Sendable (
        URL,
        Int
    ) async throws -> WorkspaceDocumentReadSnapshot
    @ObservationIgnored private let transactionRegistry: ProcessFileTransactionRegistry
    @ObservationIgnored private let workspaceID = UUID()

    public var recoveryJournalState: WorkspaceRecoveryJournalState {
        switch transactionRegistry.journalState {
        case .processOnlyForTesting:
            return .processOnlyForTesting
        case .ready(_, let retainedCount):
            return .ready(retainedCount: retainedCount)
        case .requiresReview(let error):
            return .requiresReview(Self.recoveryJournalIssue(error))
        }
    }

    private final class ActiveSaveRequest: @unchecked Sendable {
        private enum CancellationDisposition {
            case active
            case detached
            case operationOwner
        }

        private let lock = NSLock()
        private var disposition = CancellationDisposition.active

        func resolveCancellation(detached: Bool) {
            lock.lock()
            if disposition == .active {
                disposition = detached ? .detached : .operationOwner
            }
            lock.unlock()
        }

        var shouldReturnCancellation: Bool {
            lock.lock()
            defer { lock.unlock() }
            return disposition == .detached
        }
    }

    /// Linearizes admission, cancellation ownership, and completion for every
    /// caller joined to one physical save. Cancellation handlers run outside
    /// MainActor, so actor-queued bookkeeping cannot be the ordering authority.
    private final class ActiveSaveRequestLedger: @unchecked Sendable {
        enum Admission {
            case admitted(ActiveSaveRequest)
            case closed
            case full
        }

        private let lock = NSLock()
        private var requests: [UUID: ActiveSaveRequest]
        private var accepting = true

        init(initialRequestID: UUID, request: ActiveSaveRequest) {
            requests = [initialRequestID: request]
        }

        func admit(_ requestID: UUID, maximum: Int) -> Admission {
            lock.lock()
            defer { lock.unlock() }
            guard accepting else { return .closed }
            guard requests.count < maximum else { return .full }
            let request = ActiveSaveRequest()
            requests[requestID] = request
            return .admitted(request)
        }

        /// Returns true only for the request that canceled the last live
        /// ownership claim and therefore owns cancellation of the operation.
        func cancel(_ requestID: UUID) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard let request = requests.removeValue(forKey: requestID) else {
                // Completion (or an earlier cancellation) won the race.
                return false
            }
            let ownsOperation = requests.isEmpty
            if ownsOperation { accepting = false }
            request.resolveCancellation(detached: !ownsOperation)
            return ownsOperation
        }

        /// Completion wins over any cancellation that has not already
        /// linearized. Existing request objects remain readable by their
        /// waiters, but no later cancellation may rewrite their disposition.
        func complete() {
            lock.lock()
            accepting = false
            requests.removeAll(keepingCapacity: false)
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return requests.count
        }
    }

    /// A pending caller has no active-save ledger yet. This relay records its
    /// cancellation synchronously and transfers that ordering decision when
    /// the pending request is promoted, so actor scheduling cannot erase the
    /// caller's role during close/prune teardown.
    private final class PendingSaveCancellationRelay: @unchecked Sendable {
        private struct Binding {
            let ledger: ActiveSaveRequestLedger
            let requestID: UUID
            let task: Task<WorkspaceSaveOutcome, Error>

            func deliver() {
                if ledger.cancel(requestID) {
                    task.cancel()
                }
            }
        }

        private enum State {
            case pending
            case requested
            case bound(Binding)
            case delivered
        }

        private let lock = NSLock()
        private var state = State.pending

        func requestCancellation() {
            let binding: Binding?
            lock.lock()
            switch state {
            case .pending:
                state = .requested
                binding = nil
            case .bound(let active):
                state = .delivered
                binding = active
            case .requested, .delivered:
                binding = nil
            }
            lock.unlock()
            binding?.deliver()
        }

        func bind(
            ledger: ActiveSaveRequestLedger,
            requestID: UUID,
            task: Task<WorkspaceSaveOutcome, Error>
        ) {
            let binding = Binding(
                ledger: ledger,
                requestID: requestID,
                task: task)
            let deliverImmediately: Bool
            lock.lock()
            switch state {
            case .pending:
                state = .bound(binding)
                deliverImmediately = false
            case .requested:
                state = .delivered
                deliverImmediately = true
            case .bound, .delivered:
                preconditionFailure("a pending save cancellation relay may bind only once")
            }
            lock.unlock()
            if deliverImmediately { binding.deliver() }
        }
    }

    private struct ActiveSave {
        let operationID: UUID
        let editGeneration: DocumentEditGeneration
        let coalescingKey: SaveCoalescingKey
        let task: Task<WorkspaceSaveOutcome, Error>
        let requests: ActiveSaveRequestLedger
    }

    private struct PendingDurabilityConfirmation: Sendable {
        let authorization: WorkspaceSaveAuthorization
        let destination: URL
        let version: FileVersionToken
        let authorityGeneration: DocumentEditGeneration
    }

    private final class PendingManualSave: @unchecked Sendable {
        let requestID: UUID
        let snapshot: SaveSnapshot
        let authorizationRequest: SaveAuthorizationRequest
        let cancellationRelay: PendingSaveCancellationRelay
        let continuation: CheckedContinuation<WorkspaceSaveOutcome, Error>

        init(
            requestID: UUID,
            snapshot: SaveSnapshot,
            authorizationRequest: SaveAuthorizationRequest,
            cancellationRelay: PendingSaveCancellationRelay,
            continuation: CheckedContinuation<WorkspaceSaveOutcome, Error>
        ) {
            self.requestID = requestID
            self.snapshot = snapshot
            self.authorizationRequest = authorizationRequest
            self.cancellationRelay = cancellationRelay
            self.continuation = continuation
        }
    }

    private struct SavePlan: Sendable {
        let documentID: OpenDocument.ID
        let snapshotText: String
        let editGeneration: DocumentEditGeneration
        let sourceURL: URL?
        let sourceVersion: FileVersionToken?
        let authorization: WorkspaceSaveAuthorization
        let byteCount: Int

        var request: LocalDocumentSaveRequest {
            LocalDocumentSaveRequest(
                documentID: documentID,
                authorization: authorization,
                admittedUTF8: snapshotText,
                byteCount: byteCount)
        }
    }

    private struct SaveSnapshot: Sendable {
        let documentID: OpenDocument.ID
        let text: String
        let editGeneration: DocumentEditGeneration
        let sourceURL: URL?
        let sourceVersion: FileVersionToken?
        let byteCount: Int
    }

    /// Exact live-document state captured before an external read. Disk work
    /// can finish only against this identity; a later edit, retarget, close,
    /// or replacement turns the completion into a stale observation.
    private struct ExternalDocumentExpectation: Sendable {
        let id: OpenDocument.ID
        let url: URL
        let editGeneration: DocumentEditGeneration
        let persistedText: String?
        let persistedVersion: FileVersionToken?
        let hasUnsavedChanges: Bool
    }

    private struct ExternalReadResult: Sendable {
        let expectation: ExternalDocumentExpectation?
        let requestedURL: URL
        let relativePath: String
        let snapshot: WorkspaceDocumentReadSnapshot?
        let isMissing: Bool
        let failedDisplayName: String?
    }

    private enum SaveSnapshotAdmission {
        case accepted(SaveSnapshot)
        case refused(observedAtLeast: Int)
    }

    private enum SaveAuthorizationRequest: Sendable {
        case resolve(requestedURL: URL?, overwrite: Bool)
        case retained(WorkspaceSaveAuthorization)

        var coalescingKey: SaveCoalescingKey {
            switch self {
            case .resolve(let requestedURL, let overwrite):
                return .resolve(
                    requestedURL: requestedURL.map {
                        BoundedRegularFileReader.hasLocalFileAuthority($0)
                            ? $0.standardizedFileURL
                            : $0
                    },
                    overwrite: overwrite)
            case .retained(let authorization):
                return .retained(
                    destination: BoundedRegularFileReader.hasLocalFileAuthority(
                        authorization.destination)
                        ? authorization.destination.standardizedFileURL
                        : authorization.destination,
                    expectation: authorization.expectation)
            }
        }

        func validateAuthority() throws {
            let destination: URL?
            switch self {
            case .resolve(let requestedURL, _):
                destination = requestedURL
            case .retained(let authorization):
                destination = authorization.destination
            }
            if let destination,
                !BoundedRegularFileReader.hasLocalFileAuthority(destination)
            {
                throw WorkspaceError.unsupportedLocation(destination)
            }
        }
    }

    private enum SaveCoalescingKey: Equatable, Sendable {
        case resolve(requestedURL: URL?, overwrite: Bool)
        case retained(destination: URL, expectation: FileTransactionExpectation)
    }

    @ObservationIgnored private var activeSaves: [OpenDocument.ID: ActiveSave] = [:]
    @ObservationIgnored private var pendingManualSaves: [OpenDocument.ID: PendingManualSave] = [:]
    @ObservationIgnored private var durabilityConfirmations: [
        OpenDocument.ID: PendingDurabilityConfirmation
    ] = [:]

    public init(
        vaultRoot: URL? = nil,
        diagnostics: DiagnosticsEmitter = .shared
    ) {
        let documentIO = LocalDocumentIO()
        let first = PaneID()
        self.layout = SplitLayout(pane: first)
        self.panes = [first: PaneState(documents: [OpenDocument()], selection: nil)]
        self.focusedPane = first
        self.vaultRoot = vaultRoot.flatMap {
            BoundedRegularFileReader.hasLocalFileAuthority($0)
                ? $0.standardizedFileURL
                : nil
        }
        self.diagnostics = diagnostics
        self.documentIO = documentIO
        self.transactionRegistry = .shared
        self.documentRead = { url, maximumBytes in
            try Workspace.secureDocumentRead(url, maximumBytes: maximumBytes)
        }
        self.documentReadAsync = { url, maximumBytes in
            let loaded = try await documentIO.read(url, maximumBytes: maximumBytes)
            return try Workspace.documentReadSnapshot(from: loaded, requestedURL: url)
        }

        if let document = panes[first]?.documents.first {
            panes[first]?.selection = document.id
        }
    }

    /// Internal injection seam for deterministic blocked-I/O and cancellation
    /// tests. The public initializer remains unchanged for binary stability.
    init(
        vaultRoot: URL? = nil,
        diagnostics: DiagnosticsEmitter = .shared,
        documentIO: LocalDocumentIO,
        transactionRegistry: ProcessFileTransactionRegistry = ProcessFileTransactionRegistry(),
        documentRead: (@Sendable (
            URL,
            Int
        ) throws -> WorkspaceDocumentReadSnapshot)? = nil
    ) {
        let first = PaneID()
        self.layout = SplitLayout(pane: first)
        self.panes = [first: PaneState(documents: [OpenDocument()], selection: nil)]
        self.focusedPane = first
        self.vaultRoot = vaultRoot.flatMap {
            BoundedRegularFileReader.hasLocalFileAuthority($0)
                ? $0.standardizedFileURL
                : nil
        }
        self.diagnostics = diagnostics
        self.documentIO = documentIO
        self.transactionRegistry = transactionRegistry
        let synchronousRead = documentRead ?? { url, maximumBytes in
            try Workspace.secureDocumentRead(url, maximumBytes: maximumBytes)
        }
        self.documentRead = synchronousRead
        if documentRead != nil {
            self.documentReadAsync = { url, maximumBytes in
                try await Task.detached(priority: .userInitiated) {
                    try synchronousRead(url, maximumBytes)
                }.value
            }
        } else {
            self.documentReadAsync = { url, maximumBytes in
                let loaded = try await documentIO.read(url, maximumBytes: maximumBytes)
                return try Workspace.documentReadSnapshot(
                    from: loaded,
                    requestedURL: url)
            }
        }

        if let document = panes[first]?.documents.first {
            panes[first]?.selection = document.id
        }
    }

    /// Binding for the split view, so divider drags write straight back.
    public var layoutBinding: Binding<SplitLayout> {
        Binding(get: { self.layout }, set: { self.layout = $0 })
    }

    public func state(for pane: PaneID) -> PaneState {
        panes[pane] ?? PaneState()
    }

    /// The document currently shown in `pane`.
    public func document(in pane: PaneID) -> OpenDocument? {
        panes[pane]?.current
    }

    /// Each modified document exactly once, even if a split shows it in
    /// several panes. This is the authoritative close/quit review list.
    public var documentsWithUnsavedChanges: [OpenDocument] {
        allDocuments.filter(\.hasUnsavedChanges)
    }

    /// Each document that needs a close/quit decision, deduplicated across
    /// split panes. Text dirtiness and directory-sync uncertainty are distinct
    /// reasons and remain separately inspectable on the document.
    public var documentsRequiringCloseReview: [OpenDocument] {
        allDocuments.filter(\.requiresCloseReview)
    }

    /// A live pane containing `document`, in stable layout order.
    public func pane(containing document: OpenDocument.ID) -> PaneID? {
        layout.panes.first { pane in
            panes[pane]?.documents.contains(where: { $0.id == document }) == true
        }
    }

    // MARK: - Documents

    /// Creates and selects a fresh untitled document in `pane`.
    ///
    /// The initial pristine tab already represents exactly that state, so it
    /// is reused instead of accumulating indistinguishable empty tabs.
    @discardableResult
    public func newDocument(in pane: PaneID) -> OpenDocument.ID? {
        guard var state = panes[pane] else { return nil }
        if state.documents.count == 1, state.documents[0].isPristineUntitled {
            state.selection = state.documents[0].id
            panes[pane] = state
            return state.selection
        }

        let document = OpenDocument()
        state.documents.append(document)
        state.selection = document.id
        panes[pane] = state
        return document.id
    }

    /// Opens `url` in `pane`, focusing it if already open there.
    ///
    /// Reusing an open tab rather than stacking duplicates is the behaviour
    /// every editor has; opening the same note five times is never intended.
    public func open(_ url: URL, in pane: PaneID) throws {
        guard var state = panes[pane], layout.panes.contains(pane) else {
            throw WorkspaceError.paneUnavailable
        }

        let document = try resolvedDocument(for: url)
        if let existing = state.documents.first(where: { $0.id == document.id }) {
            state.selection = existing.id
            panes[pane] = state
            return
        }
        if state.documents.count == 1, state.documents[0].isPristineUntitled {
            state.documents[0] = document
        } else {
            state.documents.append(document)
        }
        state.selection = document.id
        panes[pane] = state
    }

    /// Opens `url` in a new pane beside `pane`.
    ///
    /// File resolution happens before layout mutation. A missing, unreadable,
    /// or non-UTF-8 drop therefore cannot leave an empty split behind. If the
    /// document is already open, the new pane shares its canonical identity so
    /// edits continue to propagate between views.
    @discardableResult
    public func open(
        _ url: URL,
        beside pane: PaneID,
        edge: SplitEdge = .trailing
    ) throws -> PaneID {
        guard panes[pane] != nil, layout.panes.contains(pane) else {
            throw WorkspaceError.paneUnavailable
        }
        let document = try resolvedDocument(for: url)

        let new = PaneID()
        layout.split(pane, edge: edge, with: new)
        guard layout.panes.contains(new) else {
            throw WorkspaceError.paneUnavailable
        }
        panes[new] = PaneState(documents: [document], selection: document.id)
        focusedPane = new
        return new
    }

    /// Opens through the bounded LocalDocumentIO reader, then commits only if
    /// the exact caller generation and pane still exist.
    public func openAsync(
        _ url: URL,
        in pane: PaneID,
        ifCurrent: @escaping @MainActor @Sendable () -> Bool = { true }
    ) async throws {
        guard panes[pane] != nil, layout.panes.contains(pane) else {
            throw WorkspaceError.paneUnavailable
        }
        guard ifCurrent() else { throw CancellationError() }
        let loaded = try await readDocumentAsync(url)
        try Task.checkCancellation()
        guard ifCurrent(), panes[pane] != nil, layout.panes.contains(pane) else {
            throw CancellationError()
        }
        let document = try resolvedDocument(from: loaded)
        try install(document, in: pane)
    }

    /// Async equivalent of opening the first editor-targeted drop in a new
    /// pane. Resolution finishes before the split is created, preserving the
    /// existing failure-atomic layout rule.
    @discardableResult
    public func openAsync(
        _ url: URL,
        beside pane: PaneID,
        edge: SplitEdge = .trailing,
        ifCurrent: @escaping @MainActor @Sendable () -> Bool = { true }
    ) async throws -> PaneID {
        guard panes[pane] != nil, layout.panes.contains(pane) else {
            throw WorkspaceError.paneUnavailable
        }
        guard ifCurrent() else { throw CancellationError() }
        let loaded = try await readDocumentAsync(url)
        try Task.checkCancellation()
        guard ifCurrent(), panes[pane] != nil, layout.panes.contains(pane) else {
            throw CancellationError()
        }
        let document = try resolvedDocument(from: loaded)
        let new = PaneID()
        guard layout.split(pane, edge: edge, with: new), layout.panes.contains(new) else {
            throw WorkspaceError.paneUnavailable
        }
        panes[new] = PaneState(documents: [document], selection: document.id)
        focusedPane = new
        return new
    }

    public func classifyLocalEntry(at url: URL) async throws -> WorkspaceLocalEntryKind {
        switch try await documentIO.classify(url) {
        case .regularFile: return .regularFile
        case .directory: return .directory
        case .unsupported: return .unsupported
        }
    }

    /// Atomically chooses, creates, and opens one empty note without a
    /// pathname existence check. The parent directory is retained by
    /// descriptor for the whole bounded O_EXCL attempt sequence.
    public func createUniqueEmptyDocument(
        in folder: URL,
        pane: PaneID,
        maximumAttempts: Int = WorkspaceIOBounds.maximumCreateAttempts,
        ifCurrent: @escaping @MainActor @Sendable () -> Bool = { true }
    ) async throws -> WorkspaceCreatedDocument {
        guard panes[pane] != nil, layout.panes.contains(pane) else {
            throw WorkspaceError.paneUnavailable
        }
        guard ifCurrent() else { throw CancellationError() }
        let created: SecureLocalFileCreationSnapshot
        do {
            created = try await documentIO.createUniqueEmptyDocument(
                in: folder,
                maximumAttempts: maximumAttempts)
        } catch LocalDocumentIOError.destinationExists {
            throw WorkspaceError.noteNameCapacityReached(maximumAttempts: maximumAttempts)
        }
        try Task.checkCancellation()
        guard ifCurrent(), panes[pane] != nil, layout.panes.contains(pane) else {
            throw CancellationError()
        }
        let loaded = try Self.documentReadSnapshot(
            from: created.read,
            requestedURL: created.read.canonicalURL)
        var document = try resolvedDocument(from: loaded)
        document.hasUnconfirmedDurability = !created.isFullyDurable
        try install(document, in: pane)
        return WorkspaceCreatedDocument(
            url: created.read.canonicalURL,
            isFullyDurable: created.isFullyDurable)
    }

    /// Updates the text of the document shown in `pane`.
    ///
    /// The `Bool` folds four outcomes into two, which is enough for a caller
    /// that only needs to know whether the model moved. A caller that has to
    /// *tell the reader something* wants ``apply(text:in:)`` instead: refusing
    /// an oversized edit and having no document open are both `false` here,
    /// and only one of them costs somebody their paste.
    @discardableResult
    public func updateText(_ text: String, in pane: PaneID) -> Bool {
        apply(text: text, in: pane).didApply
    }

    /// Updates the text of the document shown in `pane`, saying what happened.
    @discardableResult
    public func apply(text: String, in pane: PaneID) -> TextUpdateOutcome {
        switch MarkdownReadLimits.cappedDocumentByteCount(text) {
        case .accepted:
            break
        case .exceeded(let observedAtLeast):
            // The editor's binding pushes text in on every keystroke, so this
            // is the paste that would take the document past the limit. The
            // model keeps the old text, SwiftUI pushes it back, and the
            // editor *reverts* — silently, before this was reported. Losing
            // work with no explanation is the one outcome worth a diagnostic
            // on a per-keystroke path; it fires only on the refusal.
            diagnostics.emit(
                severity: .warning,
                subsystem: .workspace,
                code: .workspaceEditRefused,
                operationID: DiagnosticOperationID(),
                metadata: DiagnosticMetadata([
                    .byteCount: .integer(Int64(clamping: observedAtLeast))
                ]))
            return .refusedTooLarge(
                byteCount: observedAtLeast,
                limit: MarkdownReadLimits.maximumDocumentBytes)
        case .invalidLimit:
            preconditionFailure("the canonical document limit must be finite")
        }
        guard let state = panes[pane], let current = state.current else { return .noDocument }
        guard let index = state.documents.firstIndex(where: { $0.id == current.id }) else {
            return .noDocument
        }
        guard state.documents[index].text != text else { return .unchanged }

        var document = state.documents[index]
        document.text = text
        document.hasUnsavedChanges = document.url != nil && document.persistedVersion == nil
            || document.persistedText.map { $0 != text } ?? !text.isEmpty
        document.editGeneration.advance()
        propagate(document)
        return .applied
    }

    /// Atomically saves the selected document, optionally assigning a new URL.
    ///
    /// The original URL is guarded by an exact content comparison with the
    /// version read from disk. This intentionally fails closed if another app
    /// edited or removed the file while it was open.
    @discardableResult
    public func save(
        in pane: PaneID,
        to requestedURL: URL? = nil,
        overwrite: Bool = false
    ) throws -> URL {
        guard let current = document(in: pane) else {
            diagnostics.emit(
                severity: .error,
                subsystem: .workspace,
                code: .workspaceSaveFailed,
                operationID: DiagnosticOperationID())
            throw WorkspaceError.noDocument
        }
        return try save(document: current.id, to: requestedURL, overwrite: overwrite)
    }

    /// Atomically saves one exact document identity, whether or not its tab is
    /// frontmost. Close and quit review operate on documents, not selections;
    /// routing those actions through `save(in:)` can otherwise save a clean
    /// foreground tab and then discard the dirty background tab the alert
    /// named.
    @discardableResult
    public func save(
        document documentID: OpenDocument.ID,
        to requestedURL: URL? = nil,
        overwrite: Bool = false
    ) throws -> URL {
        try saveSynchronously(
            document: documentID,
            to: requestedURL,
            overwrite: overwrite,
            emitDiagnostic: true
        ).destination
    }

    /// Compatibility path for synchronous callers. It deliberately refuses
    /// overlap with the canonical async scheduler rather than starting a
    /// second transaction for the same authority on MainActor.
    private func saveSynchronously(
        document documentID: OpenDocument.ID,
        to requestedURL: URL?,
        overwrite: Bool,
        emitDiagnostic: Bool
    ) throws -> WorkspaceSaveOutcome {
        let operationID = DiagnosticOperationID()
        let errorURL = requestedURL
            ?? allDocuments.first(where: { $0.id == documentID })?.url
        var attemptedAuthorization: WorkspaceSaveAuthorization?
        var commitInvoked = false
        do {
            guard let current = allDocuments.first(where: { $0.id == documentID }) else {
                throw WorkspaceError.noDocument
            }
            guard activeSaves[documentID] == nil else {
                throw WorkspaceError.saveInProgress(current.url)
            }
            let snapshot = try captureSaveSnapshot(from: current)
            guard let requestedDestination = requestedURL ?? current.url else {
                throw WorkspaceError.needsSaveDestination
            }
            guard BoundedRegularFileReader.hasLocalFileAuthority(requestedDestination) else {
                throw WorkspaceError.unsupportedLocation(requestedDestination)
            }
            let authorization: WorkspaceSaveAuthorization
            if requestedURL == nil
                || current.url?.standardizedFileURL == requestedDestination.standardizedFileURL
            {
                guard let url = current.url, let version = current.persistedVersion else {
                    throw WorkspaceError.documentChangedOnDisk(requestedDestination)
                }
                authorization = try LocalDocumentIO.authorizeOriginalSynchronously(
                    url, expectedVersion: version)
            } else {
                authorization = try LocalDocumentIO.authorizeSaveAsSynchronously(
                    requestedDestination, overwrite: overwrite)
            }
            let plan = try makeSavePlan(snapshot: snapshot, authorization: authorization)
            attemptedAuthorization = plan.authorization
            defer { releaseReservation(plan.authorization, for: documentID) }
            commitInvoked = true
            let receipt = try LocalDocumentIO.commitSynchronously(
                plan.request, cancellationCheck: { false })
            let outcome = try settle(plan, receipt: receipt)
            if emitDiagnostic { emitSaveDiagnostic(outcome, operationID: operationID) }
            return outcome
        } catch {
            if commitInvoked, let attemptedAuthorization {
                absorbCommitFailure(
                    error,
                    authorization: attemptedAuthorization)
            }
            if emitDiagnostic {
                diagnostics.emit(
                    severity: .error,
                    subsystem: .workspace,
                    code: .workspaceSaveFailed,
                    operationID: operationID)
            }
            throw mapSaveError(error, requestedURL: errorURL)
        }
    }

    /// Captures one Save As decision without opening or hashing the destination
    /// on MainActor. Existing destinations are authorized by exact token only
    /// when overwrite was explicitly approved; symlinks and hard links fail
    /// closed at this boundary.
    public func authorizeSaveDestination(
        _ requestedURL: URL,
        overwrite: Bool
    ) async throws -> WorkspaceSaveAuthorization {
        do {
            let authorization = try await documentIO.authorizeSaveAs(
                requestedURL, overwrite: overwrite)
            try ensureDestinationIsAvailable(authorization, for: nil)
            return authorization
        } catch {
            throw mapSaveError(error, requestedURL: requestedURL)
        }
    }

    /// Off-main manual save using a destination captured by this method.
    @discardableResult
    public func saveAsync(
        document documentID: OpenDocument.ID,
        to requestedURL: URL? = nil,
        overwrite: Bool = false
    ) async throws -> URL {
        let outcome = try await saveWithOutcome(
            document: documentID,
            to: requestedURL,
            overwrite: overwrite)
        guard outcome.didSettleLiveDocument else {
            throw WorkspaceError.savePublishedButNotSettled(
                outcome.destination, outcome.settlement)
        }
        return outcome.destination
    }

    /// Canonical manual-save result. Publication and durability are distinct:
    /// callers reviewing close/quit must not treat a directory-sync warning as
    /// indistinguishable from a fully durable save.
    public func saveWithOutcome(
        document documentID: OpenDocument.ID,
        to requestedURL: URL? = nil,
        overwrite: Bool = false
    ) async throws -> WorkspaceSaveOutcome {
        try await performSave(
            document: documentID,
            authorizationRequest: .resolve(
                requestedURL: requestedURL,
                overwrite: overwrite),
            priority: .manual)
    }

    /// Consumes the retained exact destination authority captured after a save
    /// panel returned. A replacement between consent and publication is refused
    /// by FileTransaction rather than silently re-authorized.
    @discardableResult
    public func saveAsync(
        document documentID: OpenDocument.ID,
        authorization: WorkspaceSaveAuthorization
    ) async throws -> URL {
        let outcome = try await saveWithOutcome(
            document: documentID,
            authorization: authorization)
        guard outcome.didSettleLiveDocument else {
            throw WorkspaceError.savePublishedButNotSettled(
                outcome.destination, outcome.settlement)
        }
        return outcome.destination
    }

    public func saveWithOutcome(
        document documentID: OpenDocument.ID,
        authorization: WorkspaceSaveAuthorization
    ) async throws -> WorkspaceSaveOutcome {
        try await performSave(
            document: documentID,
            authorizationRequest: .retained(authorization),
            priority: .manual)
    }

    /// Retries only the directory durability barrier for a previously
    /// published save. The retained descriptor authority is bounded; when it
    /// is unavailable, an ordinary Save remains the repair path.
    public func confirmDurability(
        document documentID: OpenDocument.ID
    ) async throws -> WorkspaceDurabilityConfirmationResult {
        guard let current = allDocuments.first(where: { $0.id == documentID }) else {
            throw WorkspaceError.noDocument
        }
        guard current.hasUnconfirmedDurability else { return .notRequired }
        guard let pending = durabilityConfirmations[documentID] else {
            return .authorityUnavailable
        }
        guard durabilityConfirmation(pending, stillMatches: current) else {
            clearDurabilityConfirmation(pending, for: documentID)
            return .stale
        }

        do {
            try await documentIO.confirmDurability(
                pending.authorization,
                expectedVersion: pending.version,
                maximumBytes: MarkdownReadLimits.maximumDocumentBytes)
            try Task.checkCancellation()
        } catch {
            if error is SecureLocalFileError {
                clearDurabilityConfirmation(pending, for: documentID)
            }
            throw mapSaveError(error, requestedURL: pending.destination)
        }

        guard let latest = allDocuments.first(where: { $0.id == documentID }),
            latest.hasUnconfirmedDurability,
            durabilityConfirmation(pending, stillMatches: latest)
        else {
            clearDurabilityConfirmation(pending, for: documentID)
            return .stale
        }
        var confirmed = latest
        confirmed.hasUnconfirmedDurability = false
        confirmed.editGeneration.advance()
        propagate(confirmed)
        clearDurabilityConfirmation(pending, for: documentID)
        return .confirmed
    }

    private func durabilityConfirmation(
        _ pending: PendingDurabilityConfirmation,
        stillMatches document: OpenDocument
    ) -> Bool {
        document.url?.standardizedFileURL == pending.destination
            && document.persistedVersion == pending.version
            && document.editGeneration == pending.authorityGeneration
    }

    private func clearDurabilityConfirmation(
        _ pending: PendingDurabilityConfirmation,
        for documentID: OpenDocument.ID
    ) {
        guard let current = durabilityConfirmations[documentID],
            current.destination == pending.destination,
            current.version == pending.version,
            current.authorityGeneration == pending.authorityGeneration
        else { return }
        durabilityConfirmations[documentID] = nil
    }

    private func performSave(
        document documentID: OpenDocument.ID,
        authorizationRequest: SaveAuthorizationRequest,
        priority: LocalDocumentSavePriority
    ) async throws -> WorkspaceSaveOutcome {
        try Task.checkCancellation()
        let snapshot = try captureSaveSnapshot(documentID: documentID)
        return try await performSave(
            snapshot: snapshot,
            authorizationRequest: authorizationRequest,
            priority: priority)
    }

    private func performSave(
        snapshot: SaveSnapshot,
        authorizationRequest: SaveAuthorizationRequest,
        priority: LocalDocumentSavePriority
    ) async throws -> WorkspaceSaveOutcome {
        // Validation must precede coalescing and Save-As/original routing.
        // Foundation standardization removes a remote file URL's authority,
        // which would otherwise make it compare equal to the current local
        // document and authorize a write the caller did not name locally.
        try authorizationRequest.validateAuthority()
        if let active = activeSaves[snapshot.documentID] {
            if priority == .autosave { throw LocalDocumentIOError.superseded }
            if active.editGeneration == snapshot.editGeneration {
                guard active.coalescingKey == authorizationRequest.coalescingKey
                else { throw WorkspaceError.saveInProgress(snapshot.sourceURL) }
                let requestID = UUID()
                let request: ActiveSaveRequest
                switch active.requests.admit(
                    requestID,
                    maximum: Self.maximumCoalescedSaveWaiters)
                {
                case .admitted(let admitted):
                    request = admitted
                case .closed:
                    throw WorkspaceError.saveInProgress(snapshot.sourceURL)
                case .full:
                    throw WorkspaceError.ioBusy
                }
                return try await awaitActiveSave(
                    active,
                    request: request,
                    cancelForRequestID: requestID)
            }
            return try await enqueuePendingManualSave(
                snapshot: snapshot,
                authorizationRequest: authorizationRequest,
                active: active)
        }

        let requestID = UUID()
        let launched = launchSave(
            snapshot: snapshot,
            authorizationRequest: authorizationRequest,
            priority: priority,
            requestID: requestID)
        return try await awaitActiveSave(
            launched.active,
            request: launched.request,
            cancelForRequestID: requestID)
    }

    private func launchSave(
        snapshot: SaveSnapshot,
        authorizationRequest: SaveAuthorizationRequest,
        priority: LocalDocumentSavePriority,
        requestID: UUID
    ) -> (active: ActiveSave, request: ActiveSaveRequest) {
        enum SaveExecutionPhase {
            case preparing
            case committing
            case settling
        }

        let documentID = snapshot.documentID
        let activeID = UUID()
        let diagnosticID = DiagnosticOperationID()
        let operation = Task { @MainActor [weak self] () throws -> WorkspaceSaveOutcome in
            guard let self else { throw CancellationError() }
            let result: Result<WorkspaceSaveOutcome, Error>
            var phase = SaveExecutionPhase.preparing
            var mayPromotePendingAfterFailure = false
            var attemptedAuthorization: WorkspaceSaveAuthorization?
            do {
                let authorization = try await self.resolveAuthorization(
                    authorizationRequest,
                    for: snapshot)
                let plan = try self.makeSavePlan(
                    snapshot: snapshot,
                    authorization: authorization)
                attemptedAuthorization = plan.authorization
                defer { self.releaseReservation(plan.authorization, for: documentID) }
                phase = .committing
                let receipt = try await self.documentIO.commit(
                    plan.request, priority: priority)
                phase = .settling
                let outcome = try self.settle(plan, receipt: receipt)
                if priority == .manual {
                    self.emitSaveDiagnostic(outcome, operationID: diagnosticID)
                }
                result = .success(outcome)
            } catch {
                switch phase {
                case .preparing:
                    break
                case .committing, .settling:
                    if let attemptedAuthorization {
                    self.absorbCommitFailure(
                        error,
                        authorization: attemptedAuthorization)
                    }
                }
                switch phase {
                case .preparing:
                    // Publication is structurally impossible before commit is
                    // invoked, independent of the concrete preparation error.
                    mayPromotePendingAfterFailure = true
                case .committing:
                    mayPromotePendingAfterFailure = Self.failureIsKnownNotPublished(error)
                case .settling:
                    mayPromotePendingAfterFailure = false
                }
                if priority == .manual {
                    self.diagnostics.emit(
                        severity: .error,
                        subsystem: .workspace,
                        code: .workspaceSaveFailed,
                        operationID: diagnosticID)
                }
                let requestedURL: URL?
                switch authorizationRequest {
                case .resolve(let url, _): requestedURL = url
                case .retained(let authorization): requestedURL = authorization.destination
                }
                result = .failure(self.mapSaveError(error, requestedURL: requestedURL))
            }
            self.completeActiveSave(
                operationID: activeID,
                documentID: documentID,
                result: result,
                mayPromotePendingAfterFailure: mayPromotePendingAfterFailure)
            return try result.get()
        }
        let request = ActiveSaveRequest()
        let requestLedger = ActiveSaveRequestLedger(
            initialRequestID: requestID,
            request: request)
        let active = ActiveSave(
            operationID: activeID,
            editGeneration: snapshot.editGeneration,
            coalescingKey: authorizationRequest.coalescingKey,
            task: operation,
            requests: requestLedger)
        activeSaves[documentID] = active
        return (active, request)
    }

    private func awaitActiveSave(
        _ active: ActiveSave,
        request: ActiveSaveRequest,
        cancelForRequestID: UUID?
    ) async throws -> WorkspaceSaveOutcome {
        do {
            let result = try await withTaskCancellationHandler {
                try await active.task.value
            } onCancel: {
                guard let cancelForRequestID else { return }
                if active.requests.cancel(cancelForRequestID) {
                    active.task.cancel()
                }
            }
            if request.shouldReturnCancellation {
                throw CancellationError()
            }
            return result
        } catch {
            if request.shouldReturnCancellation {
                throw CancellationError()
            }
            throw error
        }
    }

    private func enqueuePendingManualSave(
        snapshot: SaveSnapshot,
        authorizationRequest: SaveAuthorizationRequest,
        active: ActiveSave
    ) async throws -> WorkspaceSaveOutcome {
        try Task.checkCancellation()
        let requestID = UUID()
        let cancellationRelay = PendingSaveCancellationRelay()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let prior = pendingManualSaves[snapshot.documentID] {
                    guard prior.snapshot.editGeneration != snapshot.editGeneration else {
                        continuation.resume(
                            throwing: WorkspaceError.saveInProgress(snapshot.sourceURL))
                        return
                    }
                    pendingManualSaves[snapshot.documentID] = nil
                    prior.continuation.resume(throwing: WorkspaceError.saveSuperseded)
                }
                guard activeSaves[snapshot.documentID]?.operationID == active.operationID else {
                    continuation.resume(throwing: WorkspaceError.saveInProgress(snapshot.sourceURL))
                    return
                }
                pendingManualSaves[snapshot.documentID] = PendingManualSave(
                    requestID: requestID,
                    snapshot: snapshot,
                    authorizationRequest: authorizationRequest,
                    cancellationRelay: cancellationRelay,
                    continuation: continuation)
            }
        } onCancel: {
            cancellationRelay.requestCancellation()
            Task { @MainActor [weak self] in
                self?.cancelManualSave(
                    documentID: snapshot.documentID,
                    requestID: requestID)
            }
        }
    }

    private func cancelManualSave(
        documentID: OpenDocument.ID,
        requestID: UUID
    ) {
        if let pending = pendingManualSaves[documentID], pending.requestID == requestID {
            pendingManualSaves[documentID] = nil
            pending.continuation.resume(throwing: CancellationError())
            return
        }
        if let active = activeSaves[documentID] {
            if active.requests.cancel(requestID) {
                active.task.cancel()
            }
        }
    }

    private func completeActiveSave(
        operationID: UUID,
        documentID: OpenDocument.ID,
        result: Result<WorkspaceSaveOutcome, Error>,
        mayPromotePendingAfterFailure: Bool
    ) {
        guard let active = activeSaves[documentID], active.operationID == operationID else {
            return
        }
        active.requests.complete()
        activeSaves[documentID] = nil
        guard let pending = pendingManualSaves.removeValue(forKey: documentID) else { return }

        switch result {
        case .failure(let error):
            guard mayPromotePendingAfterFailure,
                let current = allDocuments.first(where: { $0.id == documentID }),
                current.url?.standardizedFileURL == pending.snapshot.sourceURL,
                current.persistedVersion == pending.snapshot.sourceVersion
            else {
                pending.continuation.resume(throwing: error)
                return
            }
            promotePendingManualSave(pending, snapshot: pending.snapshot)
        case .success(let outcome):
            guard outcome.didSettleLiveDocument else {
                pending.continuation.resume(
                    throwing: WorkspaceError.savePublishedButNotSettled(
                        outcome.destination, outcome.settlement))
                return
            }
            guard let current = allDocuments.first(where: { $0.id == documentID }) else {
                pending.continuation.resume(throwing: WorkspaceError.noDocument)
                return
            }
            let rebased = SaveSnapshot(
                documentID: pending.snapshot.documentID,
                text: pending.snapshot.text,
                // Settling the first receipt advances authority generation.
                // That transition happened before this queued save starts and
                // is not a user edit that should keep the queued snapshot dirty.
                editGeneration: current.text == pending.snapshot.text
                    ? current.editGeneration
                    : pending.snapshot.editGeneration,
                sourceURL: current.url?.standardizedFileURL,
                sourceVersion: current.persistedVersion,
                byteCount: pending.snapshot.byteCount)
            promotePendingManualSave(pending, snapshot: rebased)
        }
    }

    static func failureIsKnownNotPublished(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let error = error as? LocalDocumentIOError {
            switch error {
            case .busy, .destinationExists, .destinationAlias, .superseded:
                return true
            }
        }
        guard let error = error as? SecureLocalFileError else { return false }
        switch error {
        case .indeterminate:
            return false
        case .recoverySlotUnavailable:
            return false
        case .recoveryJournal:
            // A durable checkpoint failed after commit invocation. Even when
            // FileTransaction stopped before rename, the adapter boundary must
            // not promote another save without registry review.
            return false
        case .prepublicationFailure(let cause, let receipt):
            return receipt.isValidPrepublicationFailure
                && failureIsKnownNotPublished(cause)
        case .invalidComponent,
            .unsupportedEntry,
            .fileTooLarge,
            .hardLinkedEntry,
            .unsupportedFileMode,
            .unsupportedFileFlags,
            .expectationMismatch,
            .operation,
            .cancelled:
            return true
        }
    }

    private func promotePendingManualSave(
        _ pending: PendingManualSave,
        snapshot: SaveSnapshot
    ) {
        let promoted = launchSave(
            snapshot: snapshot,
            authorizationRequest: pending.authorizationRequest,
            priority: .manual,
            requestID: pending.requestID)
        pending.cancellationRelay.bind(
            ledger: promoted.active.requests,
            requestID: pending.requestID,
            task: promoted.active.task)
        Task { @MainActor [weak self] in
            guard let self else {
                pending.continuation.resume(throwing: CancellationError())
                return
            }
            do {
                let outcome = try await self.awaitActiveSave(
                    promoted.active,
                    request: promoted.request,
                    cancelForRequestID: nil)
                pending.continuation.resume(returning: outcome)
            } catch {
                pending.continuation.resume(throwing: error)
            }
        }
    }

    private func resolveAuthorization(
        _ request: SaveAuthorizationRequest,
        for snapshot: SaveSnapshot
    ) async throws -> WorkspaceSaveAuthorization {
        switch request {
        case .retained(let authorization):
            return authorization
        case .resolve(let requestedURL, let overwrite):
            if let requestedURL {
                guard BoundedRegularFileReader.hasLocalFileAuthority(requestedURL) else {
                    throw WorkspaceError.unsupportedLocation(requestedURL)
                }
                guard snapshot.sourceURL == requestedURL.standardizedFileURL else {
                    return try await authorizeSaveDestination(
                        requestedURL, overwrite: overwrite)
                }
            }
            guard let url = snapshot.sourceURL else { throw WorkspaceError.needsSaveDestination }
            guard let version = snapshot.sourceVersion else {
                throw WorkspaceError.documentChangedOnDisk(url)
            }
            do {
                return try await documentIO.authorizeOriginal(
                    url, expectedVersion: version)
            } catch {
                throw mapSaveError(error, requestedURL: url)
            }
        }
    }

    private func makeSavePlan(
        snapshot: SaveSnapshot,
        authorization: WorkspaceSaveAuthorization
    ) throws -> SavePlan {
        try ensureDestinationIsAvailable(authorization, for: snapshot.documentID)
        let owner = ProcessFileTransactionOwner(
            workspaceID: workspaceID,
            documentID: snapshot.documentID)
        let selection: FileRecoverySlotSelection
        do {
            selection = try transactionRegistry.begin(
                destinationKey: authorization.destinationKey,
                destinationURL: authorization.destination,
                identity: authorization.existingVersion?.identity,
                expectation: authorization.expectation,
                owner: owner)
        } catch ProcessFileTransactionRegistryError.destinationReserved {
            throw WorkspaceError.destinationAlreadyOpen(authorization.destination)
        } catch ProcessFileTransactionRegistryError.recoveryRequiresReview {
            throw WorkspaceError.recoveryRequiresReview(authorization.destination)
        } catch ProcessFileTransactionRegistryError.capacityReached(let maximumSlots) {
            throw WorkspaceError.recoveryCapacityReached(maximumSlots: maximumSlots)
        } catch ProcessFileTransactionRegistryError.journalRequiresReview(let error) {
            throw WorkspaceError.recoveryJournalRequiresReview(
                Self.recoveryJournalIssue(error))
        }
        let preparedAuthorization = authorization.selectingRecoverySlot(
            selection)
        return SavePlan(
            documentID: snapshot.documentID,
            snapshotText: snapshot.text,
            editGeneration: snapshot.editGeneration,
            sourceURL: snapshot.sourceURL,
            sourceVersion: snapshot.sourceVersion,
            authorization: preparedAuthorization,
            byteCount: snapshot.byteCount)
    }

    private func captureSaveSnapshot(documentID: OpenDocument.ID) throws -> SaveSnapshot {
        guard let current = allDocuments.first(where: { $0.id == documentID }) else {
            throw WorkspaceError.noDocument
        }
        return try captureSaveSnapshot(from: current)
    }

    private func captureSaveSnapshot(from current: OpenDocument) throws -> SaveSnapshot {
        switch inspectSaveSnapshot(from: current) {
        case .accepted(let snapshot):
            return snapshot
        case .refused:
            throw WorkspaceError.documentTooLarge(
                maximumBytes: MarkdownReadLimits.maximumDocumentBytes)
        }
    }

    private func inspectSaveSnapshot(from current: OpenDocument) -> SaveSnapshotAdmission {
        switch MarkdownReadLimits.cappedDocumentByteCount(current.text) {
        case .accepted(let byteCount):
            return .accepted(
                SaveSnapshot(
                    documentID: current.id,
                    text: current.text,
                    editGeneration: current.editGeneration,
                    sourceURL: current.url?.standardizedFileURL,
                    sourceVersion: current.persistedVersion,
                    byteCount: byteCount))
        case .exceeded(let observedAtLeast):
            return .refused(observedAtLeast: observedAtLeast)
        case .invalidLimit:
            preconditionFailure("the canonical document limit must be finite")
        }
    }

    private func settle(
        _ plan: SavePlan,
        receipt: FileTransactionReceipt
    ) throws -> WorkspaceSaveOutcome {
        guard let selection = plan.authorization.recoverySlotSelection,
            let committedVersion = receipt.version,
            receipt.isBound(
                to: plan.authorization.destinationKey,
                destination: plan.authorization.destination),
            receipt.isValidCommittedState(for: plan.authorization.expectation)
        else {
            if let selection = plan.authorization.recoverySlotSelection {
                transactionRegistry.settleInvalidReceipt(
                    destinationKey: plan.authorization.destinationKey,
                    selection: selection,
                    receipt: receipt)
            }
            throw SecureLocalFileError.indeterminate(receipt)
        }
        // Filesystem authority settles before any UI lifecycle check. Closing,
        // reloading, retargeting, or colliding a tab cannot erase an exact
        // retained capability produced by an already-committed transaction.
        let registrySettlement = transactionRegistry.settleCommitted(
            destinationKey: plan.authorization.destinationKey,
            expectation: plan.authorization.expectation,
            selection: selection,
            receipt: receipt)
        let settledRecoveryRevision: FileRecoverySlotRevision?
        switch registrySettlement {
        case .settled(let revision):
            settledRecoveryRevision = revision
        case .incident, .stale:
            // The bytes may be committed, but recovery authority did not
            // settle onto this lease. Never present that as ordinary applied
            // success or clear the document's dirty state.
            throw SecureLocalFileError.indeterminate(receipt)
        }
        guard let current = allDocuments.first(where: { $0.id == plan.documentID }) else {
            // The file may already be committed, but a closed document must
            // never be recreated by a late completion.
            return try WorkspaceSaveOutcome(
                receipt: receipt,
                byteCount: plan.byteCount,
                settlement: .documentClosed)
        }
        guard current.url?.standardizedFileURL == plan.sourceURL,
            current.persistedVersion == plan.sourceVersion
        else {
            // Reload, rebase, or retarget won the race. Do not publish stale
            // authority into the live document.
            return try WorkspaceSaveOutcome(
                receipt: receipt,
                byteCount: plan.byteCount,
                settlement: .sourceChanged)
        }
        guard !allDocuments.contains(where: { document in
            guard document.id != current.id else { return false }
            if document.url?.standardizedFileURL == receipt.destination.standardizedFileURL {
                return true
            }
            return document.fileIdentity == committedVersion.identity
        }) else {
            return try WorkspaceSaveOutcome(
                receipt: receipt,
                byteCount: plan.byteCount,
                settlement: .destinationCollision)
        }

        var saved = current
        saved.url = receipt.destination.standardizedFileURL
        saved.persistedText = plan.snapshotText
        saved.persistedVersion = committedVersion
        saved.fileIdentity = committedVersion.identity
        saved.hasUnsavedChanges = saved.editGeneration != plan.editGeneration
            || saved.text != plan.snapshotText
        // Even a clean save advances authority; comparing only the old edit
        // counter after the next await could otherwise accept a stale receipt.
        saved.editGeneration.advance()
        let outcome = try WorkspaceSaveOutcome(
            receipt: receipt,
            byteCount: plan.byteCount,
            settlement: .applied)
        transactionRegistry.associateReusableSlot(
            with: ProcessFileTransactionOwner(
                workspaceID: workspaceID,
                documentID: plan.documentID),
            destinationKey: plan.authorization.destinationKey,
            revision: settledRecoveryRevision)
        saved.hasUnconfirmedDurability = outcome.hasUnconfirmedDurability
        propagate(saved)
        if outcome.hasUnconfirmedDurability {
            retainDurabilityConfirmation(
                for: saved,
                authorization: plan.authorization,
                committedVersion: committedVersion)
        } else {
            durabilityConfirmations[plan.documentID] = nil
        }
        return outcome
    }

    private func absorbCommitFailure(
        _ error: Error,
        authorization: WorkspaceSaveAuthorization
    ) {
        guard let selection = authorization.recoverySlotSelection else { return }
        transactionRegistry.settleFailure(
            error,
            destinationKey: authorization.destinationKey,
            selection: selection)
    }

    private func retainDurabilityConfirmation(
        for document: OpenDocument,
        authorization: WorkspaceSaveAuthorization,
        committedVersion: FileVersionToken
    ) {
        guard durabilityConfirmations[document.id] != nil
            || durabilityConfirmations.count < Self.maximumRetainedDurabilityConfirmations
        else { return }
        durabilityConfirmations[document.id] = PendingDurabilityConfirmation(
            authorization: authorization,
            destination: document.url?.standardizedFileURL
                ?? authorization.destination.standardizedFileURL,
            version: committedVersion,
            authorityGeneration: document.editGeneration)
    }

    private func emitSaveDiagnostic(
        _ outcome: WorkspaceSaveOutcome,
        operationID: DiagnosticOperationID
    ) {
        if outcome.settlement != .applied {
            let categoricalKey: DiagnosticMetadataKey
            switch outcome.settlement {
            case .applied:
                preconditionFailure("applied settlements are handled below")
            case .documentClosed:
                categoricalKey = .droppedCount
            case .sourceChanged:
                categoricalKey = .changedCount
            case .destinationCollision:
                categoricalKey = .conflictCount
            }
            diagnostics.emit(
                severity: .warning,
                subsystem: .workspace,
                code: .workspaceSaveFailed,
                operationID: operationID,
                metadata: DiagnosticMetadata([
                    categoricalKey: .integer(1),
                    .byteCount: .integer(Int64(clamping: outcome.byteCount)),
                ]))
            return
        }
        let severity: DiagnosticSeverity = outcome.isFullyDurable
            && !outcome.requiresRecovery ? .info : .warning
        let metadata: DiagnosticMetadata
        switch (outcome.hasUnconfirmedDurability, outcome.requiresRecovery) {
        case (false, false):
            metadata = DiagnosticMetadata()
        case (true, false):
            metadata = DiagnosticMetadata([.available: .boolean(false)])
        case (false, true):
            metadata = DiagnosticMetadata([.retainedCount: .integer(1)])
        case (true, true):
            metadata = DiagnosticMetadata([
                .available: .boolean(false),
                .retainedCount: .integer(1),
            ])
        }
        diagnostics.emit(
            severity: severity,
            subsystem: .workspace,
            code: .workspaceSaveSucceeded,
            operationID: operationID,
            metadata: metadata)
    }

    private func ensureDestinationIsAvailable(
        _ authorization: WorkspaceSaveAuthorization,
        for documentID: OpenDocument.ID?
    ) throws {
        let destination = authorization.destination.standardizedFileURL
        let requestingOwner = documentID.map {
            ProcessFileTransactionOwner(workspaceID: workspaceID, documentID: $0)
        }
        do {
            try transactionRegistry.ensureAvailable(
                destinationKey: authorization.destinationKey,
                identity: authorization.existingVersion?.identity,
                owner: requestingOwner)
        } catch ProcessFileTransactionRegistryError.destinationReserved {
            throw WorkspaceError.destinationAlreadyOpen(destination)
        }
        if allDocuments.contains(where: { document in
            guard document.id != documentID else { return false }
            if document.url?.standardizedFileURL == destination { return true }
            return authorization.existingVersion != nil
                && document.fileIdentity == authorization.existingVersion?.identity
        }) {
            throw WorkspaceError.destinationAlreadyOpen(destination)
        }
    }

    private func releaseReservation(
        _ authorization: WorkspaceSaveAuthorization,
        for documentID: OpenDocument.ID
    ) {
        guard let selection = authorization.recoverySlotSelection else { return }
        let owner = ProcessFileTransactionOwner(
            workspaceID: workspaceID,
            documentID: documentID)
        transactionRegistry.release(
            destinationKey: authorization.destinationKey,
            identity: authorization.existingVersion?.identity,
            owner: owner,
            leaseRevision: selection.observedRevision)
    }

    private func mapSaveError(_ error: Error, requestedURL: URL?) -> Error {
        let fallback = requestedURL.map {
            BoundedRegularFileReader.hasLocalFileAuthority($0)
                ? $0.standardizedFileURL
                : $0
        }
            ?? URL(fileURLWithPath: "Document.md")
        switch error {
        case LocalDocumentIOError.busy:
            return WorkspaceError.ioBusy
        case LocalDocumentIOError.destinationExists:
            return WorkspaceError.destinationExists(fallback)
        case LocalDocumentIOError.destinationAlias(let resolvedURL, let identity):
            if let open = allDocuments.first(where: { $0.fileIdentity == identity }) {
                return WorkspaceError.destinationAlreadyOpen(
                    open.url?.standardizedFileURL ?? resolvedURL.standardizedFileURL)
            }
            return WorkspaceError.unsafeDestination(fallback)
        case LocalDocumentIOError.superseded:
            return error
        case SecureLocalFileError.hardLinkedEntry,
            SecureLocalFileError.unsupportedEntry,
            SecureLocalFileError.unsupportedFileMode,
            SecureLocalFileError.unsupportedFileFlags,
            SecureLocalFileError.invalidComponent:
            return WorkspaceError.unsafeDestination(fallback)
        case SecureLocalFileError.expectationMismatch:
            return WorkspaceError.documentChangedOnDisk(fallback)
        case SecureLocalFileError.recoverySlotUnavailable:
            return WorkspaceError.recoveryRequiresReview(fallback)
        case SecureLocalFileError.recoveryJournal(let journalError):
            return WorkspaceError.recoveryJournalRequiresReview(
                Self.recoveryJournalIssue(journalError))
        case SecureLocalFileError.prepublicationFailure(let cause, _):
            return mapSaveError(cause, requestedURL: requestedURL)
        case SecureLocalFileError.fileTooLarge(let maximumBytes):
            return WorkspaceError.documentTooLarge(maximumBytes: maximumBytes)
        case SecureLocalFileError.cancelled:
            return CancellationError()
        case LocalFileResolutionError.notAFileURL:
            return WorkspaceError.unsupportedLocation(fallback)
        case LocalFileResolutionError.unsupportedFile,
            LocalFileResolutionError.unsafeDestination:
            return WorkspaceError.unsafeDestination(fallback)
        case let LocalFileResolutionError.posix(url, code):
            return Self.posixError(at: url, code: code)
        default:
            return error
        }
    }

    private static func recoveryJournalIssue(
        _ error: RecoveryJournalError
    ) -> WorkspaceRecoveryJournalIssue {
        switch error {
        case .applicationSupportUnavailable:
            return .applicationSupportUnavailable
        case .invalidStorage:
            return .unsafeStorage
        case .unsupportedSchema:
            return .unsupportedSchema
        case .reconciliationRequired:
            return .recoveryIncident
        case .lockUnavailable:
            return .busy
        case .durabilityUncertain, .cleanupFailure:
            return .durabilityUncertain
        case .tooManyEntries, .encodedSizeExceeded,
            .fieldSizeExceeded, .nestingLimitExceeded,
            .generationExhausted, .revisionExhausted:
            return .capacityExhausted
        case .cancelled:
            return .cancelled
        case .invalidEntry, .incompleteFileSet, .fileSetMismatch,
            .bothCopiesInvalid, .equalGenerationDivergence:
            return .corrupt
        case .operation:
            return .unknown
        }
    }

    /// Keeps the in-memory version after an external edit without pretending
    /// it has already been written. The current disk bytes become the new
    /// baseline, so the document remains dirty and the next guarded save or
    /// autosave may replace exactly that version—never an unknown later edit.
    public func keepLocal(document documentID: OpenDocument.ID) throws {
        guard let current = allDocuments.first(where: { $0.id == documentID }) else {
            throw WorkspaceError.noDocument
        }
        guard let requestedURL = current.url else {
            throw WorkspaceError.needsSaveDestination
        }
        guard BoundedRegularFileReader.hasLocalFileAuthority(requestedURL) else {
            throw WorkspaceError.unsupportedLocation(requestedURL)
        }
        let url = requestedURL.standardizedFileURL
        let loaded: (
            text: String,
            stamp: LocalFileStamp,
            version: FileVersionToken,
            canonicalURL: URL
        )
        do {
            loaded = try NoteTextCache.shared.utf8TextResult(
                at: url, maximumBytes: MarkdownReadLimits.maximumDocumentBytes)
        } catch {
            throw WorkspaceError.documentChangedOnDisk(url)
        }
        propagate(
            current.rebased(
                on: loaded.text,
                at: loaded.canonicalURL,
                version: loaded.version))
    }

    /// Re-reads and accepts the current on-disk version only if the exact
    /// document that requested it has not been edited, closed, or retargeted
    /// while the descriptor read was in flight.
    public func reloadFromDiskAsync(document documentID: OpenDocument.ID) async throws {
        let expectation = try externalExpectation(for: documentID)
        let loaded = try await readDocumentAsync(expectation.url)
        try Task.checkCancellation()
        let current = try currentDocument(matching: expectation)
        try refuseAuthorityCollision(
            documentID: documentID,
            canonicalURL: loaded.canonicalURL,
            identity: loaded.version.identity)
        propagate(
            current.reloaded(
                from: loaded.text,
                at: loaded.canonicalURL,
                version: loaded.version))
    }

    /// Async counterpart to ``keepLocal(document:)``. The local buffer is
    /// retained, while its save guard is rebased onto the exact descriptor
    /// version read off-main. A concurrent local edit refuses the stale read
    /// rather than silently changing the authority beneath newer text.
    public func keepLocalAsync(document documentID: OpenDocument.ID) async throws {
        let expectation = try externalExpectation(for: documentID)
        let loaded = try await readDocumentAsync(expectation.url)
        try Task.checkCancellation()
        let current = try currentDocument(matching: expectation)
        try refuseAuthorityCollision(
            documentID: documentID,
            canonicalURL: loaded.canonicalURL,
            identity: loaded.version.identity)
        propagate(
            current.rebased(
                on: loaded.text,
                at: loaded.canonicalURL,
                version: loaded.version))
    }

    /// Reads one bounded FSEvents batch through LocalDocumentIO and returns a
    /// value-only snapshot for the UI/index to apply. Normalization, sorting,
    /// and every filesystem read stay off MainActor. Open-document results
    /// are admitted only when their URL and edit generation are unchanged.
    public func observeExternalChangesAsync(
        _ changedPaths: [String],
        maximumPaths: Int = WorkspaceIOBounds.maximumWatchedPaths
    ) async throws -> WorkspaceExternalChangeBatch {
        guard let root = vaultRoot else {
            throw WorkspaceError.noDocument
        }
        guard BoundedRegularFileReader.hasLocalFileAuthority(root) else {
            throw WorkspaceError.unsupportedLocation(root)
        }
        let capturedRoot = root.standardizedFileURL
        let boundedMaximum = min(
            max(0, maximumPaths),
            WorkspaceIOBounds.maximumWatchedPaths)
        var expectations: [String: ExternalDocumentExpectation] = [:]
        for document in allDocuments {
            guard let url = document.url?.standardizedFileURL,
                expectations[url.path] == nil
            else { continue }
            expectations[url.path] = ExternalDocumentExpectation(
                id: document.id,
                url: url,
                editGeneration: document.editGeneration,
                persistedText: document.persistedText,
                persistedVersion: document.persistedVersion,
                hasUnsavedChanges: document.hasUnsavedChanges)
        }

        struct BoundedPaths: Sendable {
            let entries: [(url: URL, relativePath: String)]
            let omittedCount: Int
        }
        let paths = await Task.detached(priority: .utility) {
            var seen: Set<String> = []
            var entries: [(url: URL, relativePath: String)] = []
            var omittedCount = 0
            let rootComponents = capturedRoot.pathComponents
            for rawPath in changedPaths {
                guard !Task.isCancelled else { break }
                let url = URL(fileURLWithPath: rawPath).standardizedFileURL
                let components = url.pathComponents
                guard components.count > rootComponents.count,
                    components.prefix(rootComponents.count).elementsEqual(rootComponents),
                    FileTree.isMarkdown(url),
                    !url.hasDirectoryPath
                else { continue }
                if seen.contains(url.path) { continue }
                guard entries.count < boundedMaximum else {
                    // Once the budget is full, do not retain additional path
                    // keys merely to deduplicate an already omitted tail.
                    omittedCount = Self.saturatingAdd(omittedCount, 1)
                    continue
                }
                seen.insert(url.path)
                entries.append((
                    url: url,
                    relativePath: components.dropFirst(rootComponents.count)
                        .joined(separator: "/")))
            }
            entries.sort { $0.url.path < $1.url.path }
            return BoundedPaths(entries: entries, omittedCount: omittedCount)
        }.value
        try Task.checkCancellation()
        guard vaultRoot?.standardizedFileURL == capturedRoot else {
            throw WorkspaceError.documentOperationSuperseded(capturedRoot)
        }

        var reads: [ExternalReadResult] = []
        reads.reserveCapacity(paths.entries.count)
        var retainedFailureCount = 0
        for entry in paths.entries {
            try Task.checkCancellation()
            do {
                let loaded = try await documentReadAsync(
                    entry.url,
                    MarkdownReadLimits.maximumDocumentBytes)
                let canonicalRelative = Self.relativePath(
                    of: loaded.canonicalURL,
                    inside: capturedRoot)
                guard let canonicalRelative else {
                    reads.append(
                        ExternalReadResult(
                            expectation: expectations[entry.url.path],
                            requestedURL: entry.url,
                            relativePath: entry.relativePath,
                            snapshot: nil,
                            isMissing: false,
                            failedDisplayName: WorkspaceIOFailure.safeDisplayName(entry.url)))
                    retainedFailureCount = Self.saturatingAdd(retainedFailureCount, 1)
                    continue
                }
                reads.append(
                    ExternalReadResult(
                        expectation: expectations[entry.url.path],
                        requestedURL: entry.url,
                        relativePath: canonicalRelative,
                        snapshot: loaded,
                        isMissing: false,
                        failedDisplayName: nil))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let missing = Self.isMissingDocumentError(error)
                reads.append(
                    ExternalReadResult(
                        expectation: expectations[entry.url.path],
                        requestedURL: entry.url,
                        relativePath: entry.relativePath,
                        snapshot: nil,
                        isMissing: missing,
                        failedDisplayName: missing
                            ? nil : WorkspaceIOFailure.safeDisplayName(entry.url)))
                if !missing {
                    retainedFailureCount = Self.saturatingAdd(retainedFailureCount, 1)
                }
            }
        }
        try Task.checkCancellation()
        guard vaultRoot?.standardizedFileURL == capturedRoot else {
            throw WorkspaceError.documentOperationSuperseded(capturedRoot)
        }

        var changedNotes: [WorkspaceDiskText] = []
        var missingNotePaths: [String] = []
        var conflicts: Set<OpenDocument.ID> = []
        var failedItemNames: [String] = []
        var omittedFailureCount = 0
        var staleDocumentCount = 0

        for read in reads {
            if let expectation = read.expectation {
                guard let current = allDocuments.first(where: { $0.id == expectation.id }),
                    current.url?.standardizedFileURL == expectation.url,
                    current.editGeneration == expectation.editGeneration
                else {
                    staleDocumentCount = Self.saturatingAdd(staleDocumentCount, 1)
                    continue
                }
                if read.isMissing {
                    conflicts.insert(expectation.id)
                    missingNotePaths.append(read.relativePath)
                } else if let snapshot = read.snapshot,
                    !expectation.hasUnsavedChanges,
                    (expectation.persistedText != snapshot.text
                        || expectation.persistedVersion != snapshot.version)
                {
                    conflicts.insert(expectation.id)
                }
            } else if read.isMissing {
                missingNotePaths.append(read.relativePath)
            } else if let snapshot = read.snapshot {
                changedNotes.append(
                    WorkspaceDiskText(
                        relativePath: read.relativePath,
                        text: snapshot.text))
            }

            if let failedDisplayName = read.failedDisplayName {
                if failedItemNames.count < WorkspaceIOBounds.maximumFailureItems {
                    failedItemNames.append(failedDisplayName)
                } else {
                    omittedFailureCount = Self.saturatingAdd(omittedFailureCount, 1)
                }
            }
        }
        // `retainedFailureCount` is intentionally consumed so an implementation
        // change cannot accidentally make failures disappear from coverage.
        let representedFailures = failedItemNames.count + omittedFailureCount
        if representedFailures < retainedFailureCount {
            omittedFailureCount = Self.saturatingAdd(
                omittedFailureCount,
                retainedFailureCount - representedFailures)
        }
        return WorkspaceExternalChangeBatch(
            changedNotes: changedNotes,
            missingNotePaths: missingNotePaths,
            conflictingDocumentIDs: conflicts,
            failedItemNames: failedItemNames,
            omittedFailureCount: omittedFailureCount,
            omittedPathCount: paths.omittedCount,
            staleDocumentCount: staleDocumentCount)
    }

    /// Re-establishes exact descriptor authority for every open document that
    /// a vault rename may have moved or rewritten. The Rust mutation happens
    /// first; this phase never guesses authority from paths or cache metadata.
    public func rebaseFromDiskAsync(
        from sourceURL: URL,
        to destinationURL: URL,
        within root: URL,
        maximumDocuments: Int = SessionStateLimits.maximumDocuments
    ) async throws -> WorkspaceDiskRebaseReport {
        for url in [root, sourceURL, destinationURL] {
            guard BoundedRegularFileReader.hasLocalFileAuthority(url) else {
                throw WorkspaceError.unsupportedLocation(url)
            }
        }
        let capturedRoot = root.standardizedFileURL
        guard let liveRoot = vaultRoot else {
            throw WorkspaceError.documentOperationSuperseded(root)
        }
        guard BoundedRegularFileReader.hasLocalFileAuthority(liveRoot) else {
            throw WorkspaceError.unsupportedLocation(liveRoot)
        }
        guard liveRoot.standardizedFileURL == capturedRoot else {
            throw WorkspaceError.documentOperationSuperseded(root)
        }
        let source = sourceURL.standardizedFileURL
        let destination = destinationURL.standardizedFileURL
        let limit = min(max(0, maximumDocuments), SessionStateLimits.maximumDocuments)
        let candidates = allDocuments.compactMap { document -> ExternalDocumentExpectation? in
            guard let url = document.url?.standardizedFileURL,
                Self.relativePath(of: url, inside: capturedRoot) != nil
            else { return nil }
            return ExternalDocumentExpectation(
                id: document.id,
                url: url,
                editGeneration: document.editGeneration,
                persistedText: document.persistedText,
                persistedVersion: document.persistedVersion,
                hasUnsavedChanges: document.hasUnsavedChanges)
        }
        let admitted = Array(candidates.prefix(limit))
        let omittedDocumentCount = max(0, candidates.count - admitted.count)

        struct RebaseRead: Sendable {
            let expectation: ExternalDocumentExpectation
            let requestedURL: URL
            let snapshot: WorkspaceDocumentReadSnapshot
        }
        var reads: [RebaseRead] = []
        var failedItemNames: [String] = []
        var omittedFailureCount = 0
        for expectation in admitted {
            try Task.checkCancellation()
            let requested = expectation.url == source ? destination : expectation.url
            do {
                let snapshot = try await documentReadAsync(
                    requested,
                    MarkdownReadLimits.maximumDocumentBytes)
                guard Self.relativePath(of: snapshot.canonicalURL, inside: capturedRoot) != nil else {
                    throw WorkspaceError.unsafeDestination(snapshot.canonicalURL)
                }
                reads.append(
                    RebaseRead(
                        expectation: expectation,
                        requestedURL: requested,
                        snapshot: snapshot))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if failedItemNames.count < WorkspaceIOBounds.maximumFailureItems {
                    failedItemNames.append(WorkspaceIOFailure.safeDisplayName(requested))
                } else {
                    omittedFailureCount = Self.saturatingAdd(omittedFailureCount, 1)
                }
            }
        }
        try Task.checkCancellation()
        guard vaultRoot?.standardizedFileURL == capturedRoot else {
            throw WorkspaceError.documentOperationSuperseded(root)
        }

        var appliedCount = 0
        var staleDocumentCount = 0
        for read in reads {
            guard let current = allDocuments.first(where: { $0.id == read.expectation.id }),
                current.url?.standardizedFileURL == read.expectation.url,
                current.editGeneration == read.expectation.editGeneration
            else {
                staleDocumentCount = Self.saturatingAdd(staleDocumentCount, 1)
                continue
            }
            do {
                try refuseAuthorityCollision(
                    documentID: current.id,
                    canonicalURL: read.snapshot.canonicalURL,
                    identity: read.snapshot.version.identity)
                propagate(
                    current.rebased(
                        on: read.snapshot.text,
                        at: read.snapshot.canonicalURL,
                        version: read.snapshot.version))
                appliedCount = Self.saturatingAdd(appliedCount, 1)
            } catch {
                if failedItemNames.count < WorkspaceIOBounds.maximumFailureItems {
                    failedItemNames.append(
                        WorkspaceIOFailure.safeDisplayName(read.requestedURL))
                } else {
                    omittedFailureCount = Self.saturatingAdd(omittedFailureCount, 1)
                }
            }
        }
        return WorkspaceDiskRebaseReport(
            appliedCount: appliedCount,
            staleDocumentCount: staleDocumentCount,
            failedItemNames: failedItemNames,
            omittedFailureCount: omittedFailureCount,
            omittedDocumentCount: omittedDocumentCount)
    }

    public func select(_ document: OpenDocument.ID, in pane: PaneID) {
        panes[pane]?.selection = document
    }

    /// Writes every dirty, file-backed document back where it came from.
    ///
    /// - Returns: how many documents were written.
    ///
    /// A crash otherwise forfeits everything since the last manual ⌘S, which
    /// for a writing app is work the reader did not agree to lose. The write
    /// is the same atomic replace a manual save makes; an untitled document is
    /// untouched, because autosaving one would have to invent a location the
    /// reader never chose.
    ///
    /// A file changed underneath this workspace is *not* overwritten: the
    /// exact-content guard a manual save applies is applied here too, and the
    /// document simply stays dirty so the next explicit save surfaces the
    /// conflict through its usual alert. Quietly winning that race would be
    /// data loss wearing a convenience's name.
    @discardableResult
    public func autosave() -> Int {
        autosaveSynchronously().writtenCount
    }

    /// Canonical off-main autosave path. At most sixteen documents and 64 MiB
    /// are admitted per pass; every omitted document and byte remains visible
    /// in the report.
    public func autosaveAsync() async -> WorkspaceAutosaveReport {
        var report = WorkspaceAutosaveReport()
        let candidates = allDocuments.filter {
            $0.hasUnsavedChanges && $0.url != nil
        }
        var admittedDocuments = 0
        var admittedBytes = 0

        for candidate in candidates {
            let snapshot: SaveSnapshot
            switch inspectSaveSnapshot(from: candidate) {
            case .accepted(let admitted):
                snapshot = admitted
            case .refused(let byteCount):
                recordConsidered(byteCount, in: &report)
                recordAttempted(byteCount, in: &report)
                recordFailure(byteCount, in: &report)
                continue
            }
            let byteCount = snapshot.byteCount
            recordConsidered(byteCount, in: &report)

            guard activeSaves[candidate.id] == nil else {
                recordDeferred(byteCount, in: &report)
                continue
            }

            let nextBytes = admittedBytes.addingReportingOverflow(byteCount)
            guard admittedDocuments < 16,
                !nextBytes.overflow,
                nextBytes.partialValue <= 64 * 1_024 * 1_024
            else {
                recordDeferred(byteCount, in: &report)
                continue
            }
            admittedDocuments += 1
            admittedBytes = nextBytes.partialValue
            recordAttempted(byteCount, in: &report)
            guard !Task.isCancelled else {
                recordCancelled(byteCount, in: &report)
                continue
            }
            guard snapshot.sourceURL != nil, snapshot.sourceVersion != nil else {
                recordConflict(byteCount, in: &report)
                continue
            }

            do {
                let outcome = try await performSave(
                    snapshot: snapshot,
                    authorizationRequest: .resolve(requestedURL: nil, overwrite: false),
                    priority: .autosave)
                if outcome.didSettleLiveDocument {
                    recordSuccess(outcome, in: &report)
                } else {
                    recordPublishedUnsettled(outcome.byteCount, in: &report)
                }
            } catch is CancellationError {
                recordCancelled(byteCount, in: &report)
            } catch LocalDocumentIOError.superseded {
                undoAttempt(byteCount, in: &report)
                admittedDocuments -= 1
                admittedBytes -= byteCount
                recordDeferred(byteCount, in: &report)
            } catch let error as WorkspaceError {
                switch error {
                case .documentChangedOnDisk:
                    recordConflict(byteCount, in: &report)
                case .ioBusy, .saveInProgress:
                    undoAttempt(byteCount, in: &report)
                    admittedDocuments -= 1
                    admittedBytes -= byteCount
                    recordDeferred(byteCount, in: &report)
                default:
                    recordFailure(byteCount, in: &report)
                }
            } catch {
                recordFailure(byteCount, in: &report)
            }
        }
        emitAutosaveDiagnostics(report)
        return report
    }

    private func autosaveSynchronously() -> WorkspaceAutosaveReport {
        var report = WorkspaceAutosaveReport()
        var admittedDocuments = 0
        var admittedBytes = 0
        for document in allDocuments where document.hasUnsavedChanges && document.url != nil {
            let snapshot: SaveSnapshot
            switch inspectSaveSnapshot(from: document) {
            case .accepted(let admitted):
                snapshot = admitted
            case .refused(let byteCount):
                recordConsidered(byteCount, in: &report)
                recordAttempted(byteCount, in: &report)
                recordFailure(byteCount, in: &report)
                continue
            }
            let byteCount = snapshot.byteCount
            recordConsidered(byteCount, in: &report)
            guard activeSaves[document.id] == nil else {
                recordDeferred(byteCount, in: &report)
                continue
            }
            let nextBytes = admittedBytes.addingReportingOverflow(byteCount)
            guard admittedDocuments < 16,
                !nextBytes.overflow,
                nextBytes.partialValue <= 64 * 1_024 * 1_024
            else {
                recordDeferred(byteCount, in: &report)
                continue
            }
            admittedDocuments += 1
            admittedBytes = nextBytes.partialValue
            recordAttempted(byteCount, in: &report)
            guard snapshot.sourceVersion != nil else {
                recordConflict(byteCount, in: &report)
                continue
            }
            do {
                let outcome = try saveSynchronously(
                    document: document.id,
                    to: nil,
                    overwrite: false,
                    emitDiagnostic: false)
                if outcome.didSettleLiveDocument {
                    recordSuccess(outcome, in: &report)
                } else {
                    recordPublishedUnsettled(outcome.byteCount, in: &report)
                }
            } catch let error as WorkspaceError {
                switch error {
                case .documentChangedOnDisk:
                    recordConflict(byteCount, in: &report)
                case .ioBusy, .saveInProgress:
                    undoAttempt(byteCount, in: &report)
                    admittedDocuments -= 1
                    admittedBytes -= byteCount
                    recordDeferred(byteCount, in: &report)
                default:
                    recordFailure(byteCount, in: &report)
                }
            } catch {
                recordFailure(byteCount, in: &report)
            }
        }
        emitAutosaveDiagnostics(report)
        return report
    }

    private func emitAutosaveDiagnostics(_ report: WorkspaceAutosaveReport) {
        guard report.consideredCount > 0 else { return }
        let operationID = DiagnosticOperationID()
        let metadata = DiagnosticMetadata([
            .changedCount: .integer(Int64(report.consideredCount)),
            .attemptedCount: .integer(Int64(report.attemptedCount)),
            .succeededCount: .integer(Int64(report.succeededCount)),
            .conflictCount: .integer(Int64(report.conflictCount)),
            .failedCount: .integer(Int64(report.failureCount)),
            .droppedCount: .integer(Int64(report.cancelledCount)),
            .retainedCount: .integer(Int64(report.deferredCount)),
            .byteCount: .integer(Int64(clamping: report.consideredBytes)),
        ])
        if report.conflictCount > 0 {
            diagnostics.emit(
                severity: .warning,
                subsystem: .workspace,
                code: .workspaceAutosaveConflict,
                operationID: operationID,
                metadata: metadata)
        }
        if report.failureCount > 0 {
            diagnostics.emit(
                severity: .error,
                subsystem: .workspace,
                code: .workspaceAutosaveFailed,
                operationID: operationID,
                metadata: metadata)
        }
    }

    private nonisolated static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? .max : result.partialValue
    }

    private func recordConsidered(
        _ byteCount: Int,
        in report: inout WorkspaceAutosaveReport
    ) {
        report.consideredCount += 1
        report.consideredBytes = Self.saturatingAdd(report.consideredBytes, byteCount)
    }

    private func recordAttempted(
        _ byteCount: Int,
        in report: inout WorkspaceAutosaveReport
    ) {
        report.attemptedCount += 1
        report.attemptedBytes = Self.saturatingAdd(report.attemptedBytes, byteCount)
    }

    private func undoAttempt(
        _ byteCount: Int,
        in report: inout WorkspaceAutosaveReport
    ) {
        report.attemptedCount = max(0, report.attemptedCount - 1)
        report.attemptedBytes = max(0, report.attemptedBytes - byteCount)
    }

    private func recordSuccess(
        _ outcome: WorkspaceSaveOutcome,
        in report: inout WorkspaceAutosaveReport
    ) {
        report.succeededCount += 1
        report.succeededBytes = Self.saturatingAdd(
            report.succeededBytes, outcome.byteCount)
        switch outcome.durability {
        case .fullySynced:
            break
        case .directorySyncUnconfirmed:
            report.directorySyncUnconfirmedCount += 1
            report.directorySyncUnconfirmedBytes = Self.saturatingAdd(
                report.directorySyncUnconfirmedBytes, outcome.byteCount)
        }
        if outcome.requiresRecovery {
            report.recoveryRetainedCount += 1
            report.recoveryRetainedBytes = Self.saturatingAdd(
                report.recoveryRetainedBytes, outcome.byteCount)
        }
    }

    private func recordConflict(
        _ byteCount: Int,
        in report: inout WorkspaceAutosaveReport
    ) {
        report.conflictCount += 1
        report.conflictBytes = Self.saturatingAdd(report.conflictBytes, byteCount)
    }

    private func recordFailure(
        _ byteCount: Int,
        in report: inout WorkspaceAutosaveReport
    ) {
        report.failureCount += 1
        report.failureBytes = Self.saturatingAdd(report.failureBytes, byteCount)
    }

    private func recordCancelled(
        _ byteCount: Int,
        in report: inout WorkspaceAutosaveReport
    ) {
        report.cancelledCount += 1
        report.cancelledBytes = Self.saturatingAdd(report.cancelledBytes, byteCount)
    }

    private func recordDeferred(
        _ byteCount: Int,
        in report: inout WorkspaceAutosaveReport
    ) {
        report.deferredCount += 1
        report.deferredBytes = Self.saturatingAdd(report.deferredBytes, byteCount)
    }

    private func recordPublishedUnsettled(
        _ byteCount: Int,
        in report: inout WorkspaceAutosaveReport
    ) {
        report.publishedUnsettledCount += 1
        report.publishedUnsettledBytes = Self.saturatingAdd(
            report.publishedUnsettledBytes, byteCount)
    }

    func pendingManualSaveCountForTesting(documentID: OpenDocument.ID) -> Int {
        pendingManualSaves[documentID] == nil ? 0 : 1
    }

    func activeSaveCountForTesting(documentID: OpenDocument.ID) -> Int {
        activeSaves[documentID] == nil ? 0 : 1
    }

    func activeSaveWaiterCountForTesting(documentID: OpenDocument.ID) -> Int {
        activeSaves[documentID]?.requests.count ?? 0
    }

    /// Closes a tab. A pane left with no tabs gets a fresh empty one rather
    /// than rendering blank.
    @discardableResult
    public func close(
        _ document: OpenDocument.ID,
        in pane: PaneID
    ) -> WorkspaceCloseOutcome {
        guard var state = panes[pane],
            state.documents.contains(where: { $0.id == document })
        else { return WorkspaceCloseOutcome() }
        state.documents.removeAll { $0.id == document }

        if state.documents.isEmpty {
            let replacement = OpenDocument()
            state.documents = [replacement]
            state.selection = replacement.id
        } else if state.selection == document {
            state.selection = state.documents.last?.id
        }
        panes[pane] = state
        return WorkspaceCloseOutcome(
            documentIDsNoLongerOpen:
                discardLifecycleStateForDocumentsNoLongerOpen([document]))
    }

    /// Whether `url` sits inside the open vault.
    ///
    /// Component comparison, never string prefixes — `Notes-copy` is not
    /// inside `Notes`. The single owner of that rule; the watcher and the
    /// trash path both ask here rather than restating it.
    public func isInsideVault(_ url: URL) -> Bool {
        guard let root = vaultRoot,
            BoundedRegularFileReader.hasLocalFileAuthority(root),
            BoundedRegularFileReader.hasLocalFileAuthority(url)
        else { return false }
        let home = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let theirs = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return theirs.count > home.count && Array(theirs.prefix(home.count)) == home
    }

    /// The inverse of ``isInsideVault(_:)``.
    public func isOutsideVault(_ url: URL) -> Bool {
        !isInsideVault(url)
    }

    /// Whether closing this tab would discard the last in-memory view of a
    /// dirty document. Closing one of several views is always safe.
    public func requiresConfirmationBeforeClosing(
        _ document: OpenDocument.ID,
        in pane: PaneID
    ) -> Bool {
        guard panes[pane]?.documents.contains(where: { $0.id == document }) == true,
              let value = allDocuments.first(where: { $0.id == document }),
              value.requiresCloseReview
        else {
            return false
        }
        return documentOccurrences(document) == 1
    }

    // MARK: - Panes

    /// Splits `pane`, carrying its current document into the new one so the
    /// new pane opens on something rather than blank.
    @discardableResult
    public func split(_ pane: PaneID, edge: SplitEdge) -> PaneID {
        guard panes[pane] != nil, layout.panes.contains(pane) else { return focusedPane }
        let new = PaneID()
        guard layout.split(pane, edge: edge, with: new) else { return pane }

        let document = panes[pane]?.current ?? OpenDocument()
        panes[new] = PaneState(documents: [document], selection: document.id)
        focusedPane = new
        return new
    }

    /// Closes a pane and forgets its state.
    @discardableResult
    public func closePane(_ pane: PaneID) -> WorkspaceCloseOutcome {
        guard let paneState = panes[pane] else { return WorkspaceCloseOutcome() }
        let removedDocuments = Set(paneState.documents.map(\.id))
        guard layout.close(pane) else { return WorkspaceCloseOutcome() }
        panes[pane] = nil
        if focusedPane == pane {
            focusedPane = layout.panes.first ?? focusedPane
        }
        return WorkspaceCloseOutcome(
            documentIDsNoLongerOpen:
                discardLifecycleStateForDocumentsNoLongerOpen(removedDocuments))
    }

    /// Moves focus `offset` panes along, in visual order, wrapping at both
    /// ends.
    ///
    /// Splitting is the only way focus moved between panes before this, which
    /// left clicking as the sole way back — a keyboard user could open a split
    /// and then not reach one half of it. Wrapping matters for the same reason
    /// it does in the palette: a held key should never dead-end.
    public func focusPane(offset: Int) {
        let order = layout.panes
        guard order.count > 1 else { return }
        // An unknown focused pane (mid-close, before pruning) starts from the
        // first, so the shortcut still moves rather than doing nothing.
        let current = order.firstIndex(of: focusedPane) ?? 0
        let next = ((current + offset) % order.count + order.count) % order.count
        focusedPane = order[next]
    }

    /// Discards state for panes no longer in the layout.
    ///
    /// Without this the dictionary grows for the lifetime of the window,
    /// holding the full text of every document ever opened in a closed pane.
    public func pruneOrphanedPanes() {
        let live = Set(layout.panes)
        var removedDocuments = Set(
            panes.filter { !live.contains($0.key) }
                .flatMap { $0.value.documents.map(\.id) })
        panes = panes.filter { live.contains($0.key) }
        let liveDocuments = Set(allDocuments.map(\.id))
        removedDocuments.formUnion(activeSaves.keys.filter { !liveDocuments.contains($0) })
        removedDocuments.formUnion(pendingManualSaves.keys.filter { !liveDocuments.contains($0) })
        removedDocuments.formUnion(durabilityConfirmations.keys.filter {
            !liveDocuments.contains($0)
        })
        discardLifecycleStateForDocumentsNoLongerOpen(removedDocuments)
    }

    // MARK: - Canonical document identity

    /// One representative of each document identity across all panes.
    private var allDocuments: [OpenDocument] {
        var seen: Set<OpenDocument.ID> = []
        return layout.panes.compactMap { panes[$0] }
            .flatMap(\.documents)
            .filter { seen.insert($0.id).inserted }
    }

    /// Returns the one in-memory identity for `url`, loading it when needed.
    ///
    /// This is the canonical read boundary for both ordinary opens and drops.
    /// Keeping it ahead of any pane mutation is what makes open failure atomic.
    /// Internal rather than private because session restoration is a second
    /// reader of exactly the same rules — a restored launch must open notes
    /// through the same door as a clicked one.
    func resolvedDocument(for requestedURL: URL) throws -> OpenDocument {
        // Every open — Finder, a drop, a wikilink, a URL handed to the app —
        // arrives here, so this is where a location that is not a file on this
        // machine is refused. `String(contentsOf:)` will happily take an
        // `https:` URL and fetch it, synchronously, on the main actor: opening
        // a note must never become a network request.
        guard BoundedRegularFileReader.hasLocalFileAuthority(requestedURL) else {
            throw WorkspaceError.unsupportedLocation(requestedURL)
        }
        // A preliminary realpath/stat pair is not content authority: the name
        // can change before the descriptor read. Admission therefore uses only
        // the canonical URL and exact token returned with the loaded bytes.
        let loaded = try documentRead(
            requestedURL,
            MarkdownReadLimits.maximumDocumentBytes)
        return try resolvedDocument(from: loaded)
    }

    private func resolvedDocument(
        from loaded: WorkspaceDocumentReadSnapshot
    ) throws -> OpenDocument {
        let url = loaded.canonicalURL.standardizedFileURL
        let identityMatches = allDocuments.filter {
            $0.fileIdentity == loaded.version.identity
        }
        let pathMatches = allDocuments.filter {
            $0.url?.standardizedFileURL == url
        }
        guard Set(identityMatches.map(\.id)).count <= 1,
            Set(pathMatches.map(\.id)).count <= 1
        else {
            throw WorkspaceError.destinationAlreadyOpen(url)
        }
        if let pathMatch = pathMatches.first,
            pathMatch.fileIdentity != loaded.version.identity
        {
            // The path spelling is already represented by bytes from another
            // inode. Returning that document would bless stale authority;
            // creating a second identity at the same spelling would make two
            // editors race the next save.
            throw WorkspaceError.documentChangedOnDisk(url)
        }
        if let identityMatch = identityMatches.first,
            let pathMatch = pathMatches.first,
            identityMatch.id != pathMatch.id
        {
            throw WorkspaceError.destinationAlreadyOpen(url)
        }
        let existing = identityMatches.first ?? pathMatches.first
        let reservationOwners = transactionRegistry.reservationOwners(
            destinationKey: loaded.destinationKey,
            identity: loaded.version.identity)
        guard reservationOwners.count <= 1 else {
            throw WorkspaceError.destinationAlreadyOpen(url)
        }
        if let reservationOwner = reservationOwners.first {
            guard reservationOwner.workspaceID == workspaceID,
                existing?.id == reservationOwner.documentID
            else {
                throw WorkspaceError.destinationAlreadyOpen(url)
            }
            return existing!
        }
        if let existing { return existing }
        return OpenDocument(
            authoritativeText: loaded.text,
            at: loaded.canonicalURL,
            version: loaded.version)
    }

    private func install(_ document: OpenDocument, in pane: PaneID) throws {
        guard var state = panes[pane], layout.panes.contains(pane) else {
            throw WorkspaceError.paneUnavailable
        }
        if let existing = state.documents.first(where: { $0.id == document.id }) {
            state.selection = existing.id
            panes[pane] = state
            return
        }
        if state.documents.count == 1, state.documents[0].isPristineUntitled {
            state.documents[0] = document
        } else {
            state.documents.append(document)
        }
        state.selection = document.id
        panes[pane] = state
    }

    private func readDocumentAsync(
        _ requestedURL: URL
    ) async throws -> WorkspaceDocumentReadSnapshot {
        guard BoundedRegularFileReader.hasLocalFileAuthority(requestedURL) else {
            throw WorkspaceError.unsupportedLocation(requestedURL)
        }
        do {
            return try await documentReadAsync(
                requestedURL,
                MarkdownReadLimits.maximumDocumentBytes)
        } catch LocalDocumentIOError.busy {
            throw WorkspaceError.ioBusy
        } catch SecureLocalFileError.fileTooLarge(let maximumBytes) {
            throw WorkspaceError.documentTooLarge(maximumBytes: maximumBytes)
        } catch SecureLocalFileError.cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw WorkspaceError.documentUnavailable(requestedURL)
        }
    }

    private func externalExpectation(
        for documentID: OpenDocument.ID
    ) throws -> ExternalDocumentExpectation {
        guard let document = allDocuments.first(where: { $0.id == documentID }) else {
            throw WorkspaceError.noDocument
        }
        guard let url = document.url?.standardizedFileURL else {
            throw WorkspaceError.needsSaveDestination
        }
        return ExternalDocumentExpectation(
            id: document.id,
            url: url,
            editGeneration: document.editGeneration,
            persistedText: document.persistedText,
            persistedVersion: document.persistedVersion,
            hasUnsavedChanges: document.hasUnsavedChanges)
    }

    private func currentDocument(
        matching expectation: ExternalDocumentExpectation
    ) throws -> OpenDocument {
        guard let current = allDocuments.first(where: { $0.id == expectation.id }) else {
            throw WorkspaceError.noDocument
        }
        guard current.url?.standardizedFileURL == expectation.url,
            current.editGeneration == expectation.editGeneration
        else {
            throw WorkspaceError.documentOperationSuperseded(expectation.url)
        }
        return current
    }

    private func refuseAuthorityCollision(
        documentID: OpenDocument.ID,
        canonicalURL: URL,
        identity: LocalFileIdentity
    ) throws {
        if let collision = allDocuments.first(where: { candidate in
            candidate.id != documentID
                && (candidate.fileIdentity == identity
                    || candidate.url?.standardizedFileURL
                        == canonicalURL.standardizedFileURL)
        }) {
            throw WorkspaceError.destinationAlreadyOpen(
                collision.url ?? canonicalURL)
        }
    }

    private nonisolated static func relativePath(
        of url: URL,
        inside root: URL
    ) -> String? {
        let rootComponents = root.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard components.count > rootComponents.count,
            components.prefix(rootComponents.count).elementsEqual(rootComponents)
        else { return nil }
        return components.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private nonisolated static func isMissingDocumentError(_ error: Error) -> Bool {
        if case SecureLocalFileError.operation(.openTarget, let code) = error {
            return code == ENOENT
        }
        if case LocalFileResolutionError.posix(_, let code) = error {
            return code == ENOENT
        }
        let cocoa = error as NSError
        return cocoa.domain == NSCocoaErrorDomain
            && (cocoa.code == NSFileNoSuchFileError
                || cocoa.code == NSFileReadNoSuchFileError)
    }

    private nonisolated static func secureDocumentRead(
        _ url: URL,
        maximumBytes: Int
    ) throws -> WorkspaceDocumentReadSnapshot {
        let loaded = try SecureLocalFileSystem.read(
            url,
            maximumBytes: maximumBytes)
        guard let text = String(data: loaded.data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return WorkspaceDocumentReadSnapshot(
            text: text,
            version: loaded.version,
            canonicalURL: loaded.canonicalURL,
            destinationKey: loaded.destinationKey)
    }

    private nonisolated static func documentReadSnapshot(
        from loaded: SecureLocalFileReadSnapshot,
        requestedURL: URL
    ) throws -> WorkspaceDocumentReadSnapshot {
        guard let text = String(data: loaded.data, encoding: .utf8) else {
            throw CocoaError(
                .fileReadInapplicableStringEncoding,
                userInfo: [NSURLErrorKey: requestedURL])
        }
        return WorkspaceDocumentReadSnapshot(
            text: text,
            version: loaded.version,
            canonicalURL: loaded.canonicalURL,
            destinationKey: loaded.destinationKey)
    }

    /// Replaces every view of `document`, wherever it is open.
    ///
    /// The one public door onto ``propagate``: accepting an external version
    /// of a note must reach every split showing it, which is the same rule
    /// editing through a binding already follows.
    @discardableResult
    public func replace(document: OpenDocument) -> Bool {
        guard MarkdownReadLimits.acceptedDocumentByteCount(document.text) != nil else {
            return false
        }
        guard let prior = allDocuments.first(where: { $0.id == document.id }) else {
            return false
        }
        var admitted = document
        let retargetedWithoutFreshAuthority = admitted.url?.standardizedFileURL
            != prior.url?.standardizedFileURL
            && admitted.persistedVersion == prior.persistedVersion
        if admitted.url != nil,
            admitted.persistedVersion == nil || retargetedWithoutFreshAuthority
        {
            admitted.persistedText = nil
            admitted.persistedVersion = nil
            admitted.hasUnsavedChanges = true
        } else if admitted.url != nil {
            admitted.hasUnsavedChanges = admitted.persistedText != admitted.text
        } else {
            admitted.hasUnsavedChanges = !admitted.text.isEmpty
        }
        // Close-review durability is an internal observation, never mutable
        // input from public document copies.
        admitted.hasUnconfirmedDurability = prior.hasUnconfirmedDurability
        if admitted.url?.standardizedFileURL != prior.url?.standardizedFileURL
            || admitted.persistedVersion != prior.persistedVersion
            || admitted.editGeneration != prior.editGeneration
        {
            durabilityConfirmations[admitted.id] = nil
        }
        if admitted.url?.standardizedFileURL != prior.url?.standardizedFileURL {
            transactionRegistry.detachReusableSlots(
                from: ProcessFileTransactionOwner(
                    workspaceID: workspaceID,
                    documentID: admitted.id))
        }
        propagate(admitted)
        return true
    }

    /// Replaces every view of `document` so split panes can never drift.
    private func propagate(_ document: OpenDocument) {
        for pane in Array(panes.keys) {
            guard var state = panes[pane] else { continue }
            var changed = false
            for index in state.documents.indices where state.documents[index].id == document.id {
                state.documents[index] = document
                changed = true
            }
            if changed { panes[pane] = state }
        }
    }

    private func documentOccurrences(_ document: OpenDocument.ID) -> Int {
        panes.values.reduce(into: 0) { count, state in
            count += state.documents.lazy.filter { $0.id == document }.count
        }
    }

    @discardableResult
    private func discardLifecycleStateForDocumentsNoLongerOpen(
        _ candidates: Set<OpenDocument.ID>
    ) -> Set<OpenDocument.ID> {
        guard !candidates.isEmpty else { return [] }
        let liveDocuments = Set(allDocuments.map(\.id))
        let noLongerOpen = candidates.subtracting(liveDocuments)
        for documentID in noLongerOpen {
            if let active = activeSaves.removeValue(forKey: documentID) {
                active.requests.complete()
                active.task.cancel()
            }
            if let pending = pendingManualSaves.removeValue(forKey: documentID) {
                pending.continuation.resume(throwing: CancellationError())
            }
            durabilityConfirmations[documentID] = nil
            transactionRegistry.detachReusableSlots(
                from: ProcessFileTransactionOwner(
                    workspaceID: workspaceID,
                    documentID: documentID))
        }
        return noLongerOpen
    }

    func retainedDurabilityConfirmationCountForTesting() -> Int {
        durabilityConfirmations.count
    }

    private static func posixError(at url: URL, code: Int32) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSFilePathErrorKey: url.path])
    }
}

extension Workspace {
    /// What this window would come back as.
    ///
    /// Untitled documents are left out — see ``DocumentSnapshot`` — and a pane
    /// holding only those restores with its pristine empty tab instead.
    public func snapshot() -> WorkspaceSnapshot {
        let panes = layout.panes.map { pane in
            let state = self.panes[pane] ?? PaneState()
            let documents = state.documents.compactMap { document in
                document.url.map { DocumentSnapshot(url: $0.absoluteString) }
            }
            let selectedURL = state.documents.first(where: { $0.id == state.selection })?
                .url?.absoluteString
            return PaneSnapshot(
                pane: pane,
                documents: documents,
                selection: nil,
                selectedDocumentURL: selectedURL)
        }
        return WorkspaceSnapshot(
            layout: layout,
            panes: panes,
            focusedPane: focusedPane,
            vaultRoot: vaultRoot?.absoluteString)
    }

    /// Stages every retained-tab read through LocalDocumentIO, then swaps the
    /// layout in one MainActor commit. The closure is an exact window launch
    /// generation supplied by WorkspaceView; when it expires, no partial pane
    /// or vault-root mutation escapes.
    public func restoreAsync(
        from snapshot: WorkspaceSnapshot,
        ifCurrent: @escaping @MainActor @Sendable () -> Bool = { true }
    ) async throws -> WorkspaceRestoreReport {
        guard ifCurrent() else { throw CancellationError() }

        var loadedByURL: [String: WorkspaceDocumentReadSnapshot] = [:]
        var attemptedURLs: Set<String> = []
        var failedItemNames: [String] = []
        var omittedFailureCount = 0

        for entry in snapshot.panes where snapshot.layout.panes.contains(entry.pane) {
            for document in entry.documents {
                try Task.checkCancellation()
                guard attemptedURLs.insert(document.url).inserted,
                    let url = URL(string: document.url),
                    BoundedRegularFileReader.hasLocalFileAuthority(url)
                else { continue }
                do {
                    loadedByURL[document.url] = try await readDocumentAsync(url)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if failedItemNames.count < WorkspaceIOBounds.maximumFailureItems {
                        failedItemNames.append(WorkspaceIOFailure.safeDisplayName(url))
                    } else {
                        omittedFailureCount = Self.saturatingAdd(
                            omittedFailureCount, 1)
                    }
                }
                try Task.checkCancellation()
                guard ifCurrent() else { throw CancellationError() }
            }
        }

        var documentsByIdentity: [LocalFileIdentity: OpenDocument] = [:]
        var identityByCanonicalPath: [String: LocalFileIdentity] = [:]
        var restoredByURL: [String: OpenDocument] = [:]
        for (requestedURL, loaded) in loadedByURL.sorted(by: { $0.key < $1.key }) {
            let path = loaded.canonicalURL.standardizedFileURL.path
            if let existingIdentity = identityByCanonicalPath[path],
                existingIdentity != loaded.version.identity
            {
                if failedItemNames.count < WorkspaceIOBounds.maximumFailureItems {
                    failedItemNames.append(
                        WorkspaceIOFailure.safeDisplayName(loaded.canonicalURL))
                } else {
                    omittedFailureCount = Self.saturatingAdd(omittedFailureCount, 1)
                }
                continue
            }
            identityByCanonicalPath[path] = loaded.version.identity
            let document: OpenDocument
            if let existing = documentsByIdentity[loaded.version.identity] {
                document = existing
            } else {
                document = OpenDocument(
                    authoritativeText: loaded.text,
                    at: loaded.canonicalURL,
                    version: loaded.version)
                documentsByIdentity[loaded.version.identity] = document
            }
            restoredByURL[requestedURL] = document
        }

        var restoredPanes: [PaneID: PaneState] = [:]
        for entry in snapshot.panes where snapshot.layout.panes.contains(entry.pane) {
            var documents: [OpenDocument] = []
            var restoredSelection: OpenDocument.ID?
            for saved in entry.documents {
                guard let document = restoredByURL[saved.url],
                    !documents.contains(where: { $0.id == document.id })
                else { continue }
                documents.append(document)
                if saved.url == entry.selectedDocumentURL
                    || document.id == entry.selection
                {
                    restoredSelection = document.id
                }
            }
            if documents.isEmpty {
                let pristine = OpenDocument()
                documents = [pristine]
                restoredSelection = pristine.id
            }
            restoredPanes[entry.pane] = PaneState(
                documents: documents,
                selection: restoredSelection ?? documents.last?.id)
        }
        for pane in snapshot.layout.panes where restoredPanes[pane] == nil {
            let pristine = OpenDocument()
            restoredPanes[pane] = PaneState(
                documents: [pristine],
                selection: pristine.id)
        }

        try Task.checkCancellation()
        guard ifCurrent() else { throw CancellationError() }
        let replacedDocumentIDs = Set(allDocuments.map(\.id))
        layout = snapshot.layout
        panes = restoredPanes
        focusedPane = layout.panes.contains(snapshot.focusedPane)
            ? snapshot.focusedPane
            : (layout.panes.first ?? focusedPane)
        vaultRoot = snapshot.vaultRoot
            .flatMap(URL.init(string:))
            .flatMap {
                BoundedRegularFileReader.hasLocalFileAuthority($0)
                    ? $0.standardizedFileURL
                    : nil
            }
        discardLifecycleStateForDocumentsNoLongerOpen(replacedDocumentIDs)

        return WorkspaceRestoreReport(
            restoredDocumentCount: documentsByIdentity.count,
            failedItemNames: failedItemNames,
            omittedFailureCount: omittedFailureCount)
    }

    /// Rebuilds this workspace from `snapshot`.
    ///
    /// Documents that no longer exist are skipped rather than fatal: a note
    /// deleted while the app was closed must not cost the reader every other
    /// tab they had open. A snapshot naming nothing restorable leaves the
    /// workspace exactly as a fresh launch built it.
    public func restore(from snapshot: WorkspaceSnapshot) {
        // A layout whose tree survives encoding round-trips intact; panes not
        // mentioned by it (an older format, or a hand-edited default) are
        // dropped by the same rule the live window prunes orphans with.
        layout = snapshot.layout
        panes = [:]

        for entry in snapshot.panes where layout.panes.contains(entry.pane) {
            var documents: [OpenDocument] = []
            var restoredSelection: UUID?
            for document in entry.documents {
                guard let url = URL(string: document.url),
                    let resolved = try? resolvedDocument(for: url)
                else { continue }
                if documents.contains(where: { $0.id == resolved.id }) { continue }
                documents.append(resolved)
                if resolved.url?.absoluteString == entry.selectedDocumentURL
                    || resolved.id == entry.selection
                {
                    restoredSelection = resolved.id
                }
            }
            if documents.isEmpty {
                let pristine = OpenDocument()
                documents = [pristine]
                restoredSelection = pristine.id
            }
            panes[entry.pane] = PaneState(
                documents: documents,
                selection: restoredSelection ?? documents.last?.id)
        }

        // Every pane the layout names must answer `state(for:)`, or the first
        // render draws an empty pane the model does not know about.
        for pane in layout.panes where panes[pane] == nil {
            let pristine = OpenDocument()
            panes[pane] = PaneState(documents: [pristine], selection: pristine.id)
        }

        if layout.panes.contains(snapshot.focusedPane) {
            focusedPane = snapshot.focusedPane
        } else {
            focusedPane = layout.panes.first ?? focusedPane
        }

        vaultRoot = snapshot.vaultRoot
            .flatMap(URL.init(string:))
            .flatMap {
                BoundedRegularFileReader.hasLocalFileAuthority($0)
                    ? $0.standardizedFileURL
                    : nil
            }
    }
}

private extension OpenDocument {
    var isPristineUntitled: Bool {
        url == nil && text.isEmpty && !hasUnsavedChanges
    }
}
