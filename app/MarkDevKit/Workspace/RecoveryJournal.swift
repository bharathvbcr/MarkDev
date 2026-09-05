//
//  RecoveryJournal.swift
//  MarkDevKit
//
//  Bounded two-copy persistence for filesystem recovery observations.
//

import CryptoKit
import Darwin
import Foundation

enum RecoveryJournalTransactionPhase: String, Codable, Equatable, Sendable {
    case preparing
    case staged
    case publishing
    case committed
    case indeterminate
}

enum RecoveryJournalRecoveryContents: String, Codable, Equatable, Sendable {
    case previousDestination
    case unpublishedScratch

    init(_ contents: FileRecoveryContents) {
        switch contents {
        case .previousDestination: self = .previousDestination
        case .unpublishedScratch: self = .unpublishedScratch
        }
    }

    var liveValue: FileRecoveryContents {
        switch self {
        case .previousDestination: .previousDestination
        case .unpublishedScratch: .unpublishedScratch
        }
    }
}

/// Untrusted-on-load identity fields. A decoded value is an observation, not
/// a live capability; it becomes useful only as a predicate for a freshly
/// opened descriptor.
struct RecoveryJournalFileIdentityObservation: Codable, Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let generation: UInt32
    let birthSeconds: Int64
    let birthNanoseconds: Int64

    init(_ identity: LocalFileIdentity) {
        device = identity.device
        inode = identity.inode
        generation = identity.generation
        birthSeconds = identity.birthSeconds
        birthNanoseconds = identity.birthNanoseconds
    }

    init(
        device: UInt64,
        inode: UInt64,
        generation: UInt32,
        birthSeconds: Int64,
        birthNanoseconds: Int64
    ) {
        self.device = device
        self.inode = inode
        self.generation = generation
        self.birthSeconds = birthSeconds
        self.birthNanoseconds = birthNanoseconds
    }

    func matches(_ identity: LocalFileIdentity) -> Bool {
        device == identity.device
            && inode == identity.inode
            && birthSeconds == identity.birthSeconds
            && birthNanoseconds == identity.birthNanoseconds
        // `st_gen` is deliberately excluded for the same reason as
        // FileVersionToken: Darwin exposes a useful value only to root.
    }
}

/// Persisted exact-version fields used only to revalidate a newly opened file.
/// Decoding this value never constructs `FileVersionToken` or
/// `FileRecoveryAuthority`.
struct RecoveryJournalFileVersionObservation: Codable, Equatable, Sendable {
    let identity: RecoveryJournalFileIdentityObservation
    let size: Int64
    let mode: UInt32
    let ownerID: UInt32
    let groupID: UInt32
    let flags: UInt32
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
    let linkCount: UInt64
    let sha256: Data

    init(_ version: FileVersionToken) {
        identity = RecoveryJournalFileIdentityObservation(version.identity)
        size = Int64(version.size)
        mode = UInt32(version.mode)
        ownerID = UInt32(version.ownerID)
        groupID = UInt32(version.groupID)
        flags = version.flags
        modifiedSeconds = version.modifiedSeconds
        modifiedNanoseconds = version.modifiedNanoseconds
        changedSeconds = version.changedSeconds
        changedNanoseconds = version.changedNanoseconds
        linkCount = version.linkCount
        sha256 = version.sha256
    }

    func matches(_ version: FileVersionToken) -> Bool {
        identity.matches(version.identity)
            && size == Int64(version.size)
            && mode == UInt32(version.mode)
            && ownerID == UInt32(version.ownerID)
            && groupID == UInt32(version.groupID)
            && flags == version.flags
            && modifiedSeconds == version.modifiedSeconds
            && modifiedNanoseconds == version.modifiedNanoseconds
            && changedSeconds == version.changedSeconds
            && changedNanoseconds == version.changedNanoseconds
            && linkCount == version.linkCount
            && sha256 == version.sha256
    }

    func matchesAcrossRename(_ version: FileVersionToken) -> Bool {
        identity.matches(version.identity)
            && size == Int64(version.size)
            && mode == UInt32(version.mode)
            && ownerID == UInt32(version.ownerID)
            && groupID == UInt32(version.groupID)
            && flags == version.flags
            && modifiedSeconds == version.modifiedSeconds
            && modifiedNanoseconds == version.modifiedNanoseconds
            && linkCount == version.linkCount
            && sha256 == version.sha256
    }

    fileprivate var isStructurallyValid: Bool {
        size >= 0
            && size <= Int64(MarkdownReadLimits.maximumDocumentBytes)
            && mode & UInt32(S_IFMT) == UInt32(S_IFREG)
            && linkCount == 1
            && sha256.count == SHA256.byteCount
    }
}

struct RecoveryJournalDestinationObservation: Codable, Equatable, Sendable {
    let presentationURLString: String
    let bookmark: Data?
    let parentIdentity: RecoveryJournalFileIdentityObservation
    let component: String
    let componentBytes: Data

    init(
        presentationURL: URL,
        destinationKey: FileDestinationKey,
        bookmark: Data? = nil
    ) throws {
        guard BoundedRegularFileReader.hasLocalFileAuthority(presentationURL),
            let componentString = String(
            data: destinationKey.componentBytes,
            encoding: .utf8),
            (try? FileComponent(componentString)) != nil
        else { throw RecoveryJournalError.invalidEntry }
        self.presentationURLString = presentationURL.standardizedFileURL.absoluteString
        self.bookmark = bookmark
        parentIdentity = RecoveryJournalFileIdentityObservation(
            destinationKey.directoryIdentity)
        component = componentString
        componentBytes = destinationKey.componentBytes
    }

    var presentationURL: URL? {
        guard let url = URL(string: presentationURLString),
            BoundedRegularFileReader.hasLocalFileAuthority(url)
        else { return nil }
        return url.standardizedFileURL
    }

    func fileComponent() throws -> FileComponent {
        let value = try FileComponent(component)
        guard Data(component.utf8) == componentBytes else {
            throw RecoveryJournalError.invalidEntry
        }
        return value
    }

    func matches(_ key: FileDestinationKey) -> Bool {
        parentIdentity.matches(key.directoryIdentity)
            && componentBytes == key.componentBytes
    }
}

enum RecoveryJournalDestinationExpectation: Equatable, Sendable, Codable {
    case missing
    case exact(RecoveryJournalFileVersionObservation)

    init(_ expectation: FileTransactionExpectation) {
        switch expectation {
        case .missing: self = .missing
        case .exact(let version):
            self = .exact(RecoveryJournalFileVersionObservation(version))
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case version
    }

    private enum Kind: String, Codable {
        case missing
        case exact
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .missing:
            guard !container.contains(.version) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .version,
                    in: container,
                    debugDescription: "missing expectation cannot carry a version")
            }
            self = .missing
        case .exact:
            self = .exact(try container.decode(
                RecoveryJournalFileVersionObservation.self,
                forKey: .version))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .missing:
            try container.encode(Kind.missing, forKey: .kind)
        case .exact(let version):
            try container.encode(Kind.exact, forKey: .kind)
            try container.encode(version, forKey: .version)
        }
    }
}

struct RecoveryJournalStageObservation: Codable, Equatable, Sendable {
    let component: String
    let version: RecoveryJournalFileVersionObservation
    let destinationParentIdentity: RecoveryJournalFileIdentityObservation
    let destinationComponentBytes: Data
    let contents: RecoveryJournalRecoveryContents

    init(_ slot: FileRecoverySlot) {
        component = slot.authority.component.rawValue
        version = RecoveryJournalFileVersionObservation(slot.authority.version)
        destinationParentIdentity = RecoveryJournalFileIdentityObservation(
            slot.authority.destinationKey.directoryIdentity)
        destinationComponentBytes = slot.authority.destinationKey.componentBytes
        contents = RecoveryJournalRecoveryContents(slot.contents)
    }

    init(
        component: FileComponent,
        version: FileVersionToken,
        destinationKey: FileDestinationKey,
        contents: FileRecoveryContents
    ) {
        self.component = component.rawValue
        self.version = RecoveryJournalFileVersionObservation(version)
        destinationParentIdentity = RecoveryJournalFileIdentityObservation(
            destinationKey.directoryIdentity)
        destinationComponentBytes = destinationKey.componentBytes
        self.contents = RecoveryJournalRecoveryContents(contents)
    }

    func fileComponent() throws -> FileComponent {
        try FileComponent(component)
    }

    func isScoped(to destination: RecoveryJournalDestinationObservation) -> Bool {
        destinationParentIdentity == destination.parentIdentity
            && destinationComponentBytes == destination.componentBytes
    }
}

struct RecoveryJournalEntry: Codable, Equatable, Sendable {
    let id: UUID
    let revision: UInt64
    let phase: RecoveryJournalTransactionPhase
    let destination: RecoveryJournalDestinationObservation
    let expectation: RecoveryJournalDestinationExpectation
    /// The exact descriptor-relative component selected before a fresh stage
    /// is created. It carries no inode authority. Its only purpose is to make
    /// the otherwise tiny create-to-observe crash window discoverable: a
    /// present name without a matching `stage` token requires review and is
    /// never opened for mutation.
    let plannedStageComponent: String?
    let stage: RecoveryJournalStageObservation?
    let committedDestinationVersion: RecoveryJournalFileVersionObservation?

    init(
        id: UUID,
        revision: UInt64,
        phase: RecoveryJournalTransactionPhase,
        destination: RecoveryJournalDestinationObservation,
        expectation: RecoveryJournalDestinationExpectation,
        stage: RecoveryJournalStageObservation?,
        committedDestinationVersion: RecoveryJournalFileVersionObservation?,
        plannedStageComponent: String? = nil
    ) {
        self.id = id
        self.revision = revision
        self.phase = phase
        self.destination = destination
        self.expectation = expectation
        self.plannedStageComponent = plannedStageComponent
        self.stage = stage
        self.committedDestinationVersion = committedDestinationVersion
    }
}

enum RecoveryJournalCopy: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case a
    case b
}

struct RecoveryJournalSnapshot: Equatable, Sendable {
    let fileSetID: UUID
    let generation: UInt64
    let entries: [RecoveryJournalEntry]
    let degradedCopies: Set<RecoveryJournalCopy>
}

enum RecoveryJournalLiveReconciliation: Equatable, Sendable {
    /// The observed phase carries no retained artifact and the destination is
    /// still consistent with it.
    case noRecovery
    /// Publication is proven not to have happened and this exact scratch or
    /// predecessor can be offered to the matching live transaction.
    case reusable(FileRecoverySlot)
    /// Publication is proven and, for an overwrite, the displaced predecessor
    /// was revalidated under its exact retained name.
    case published(version: FileVersionToken, recovery: FileRecoverySlot?)
    /// The journal remains the authority for review; no live capability is
    /// emitted from ambiguous or contradictory topology.
    case requiresReview

    var recoverySlot: FileRecoverySlot? {
        switch self {
        case .reusable(let slot): slot
        case .published(_, let slot): slot
        case .noRecovery, .requiresReview: nil
        }
    }
}

enum RecoveryJournalOperation: String, Equatable, Sendable {
    case createFile
    case openFile
    case inspectFile
    case acquireLock
    case releaseLock
    case truncateFile
    case readFile
    case writeFile
    case syncFile
    case syncDirectory
    case metadata
}

enum RecoveryJournalError: Error, Equatable, LocalizedError {
    case applicationSupportUnavailable
    case invalidStorage(SecureLocalFileError)
    case invalidEntry
    case tooManyEntries(maximum: Int)
    case encodedSizeExceeded(maximumBytes: Int)
    case fieldSizeExceeded(maximumBytes: Int)
    case nestingLimitExceeded(maximumDepth: Int)
    case incompleteFileSet
    case unsupportedSchema
    case fileSetMismatch
    case bothCopiesInvalid
    case equalGenerationDivergence
    case reconciliationRequired
    case generationExhausted
    case revisionExhausted
    case lockUnavailable(maximumAttempts: Int)
    case cancelled
    case operation(RecoveryJournalOperation, errno: Int32)
    case durabilityUncertain(RecoveryJournalOperation, errno: Int32)
    indirect case cleanupFailure(
        primary: RecoveryJournalError,
        cleanup: RecoveryJournalOperation,
        errno: Int32)

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            "Application Support is unavailable."
        case .invalidStorage:
            "The recovery journal storage boundary is unsafe."
        case .invalidEntry:
            "A recovery journal entry is malformed."
        case .tooManyEntries(let maximum):
            "The recovery journal exceeds its \(maximum)-entry limit."
        case .encodedSizeExceeded(let maximumBytes):
            "The recovery journal exceeds its \(maximumBytes)-byte limit."
        case .fieldSizeExceeded(let maximumBytes):
            "A recovery journal field exceeds its \(maximumBytes)-byte limit."
        case .nestingLimitExceeded(let maximumDepth):
            "The recovery journal exceeds its \(maximumDepth)-level nesting limit."
        case .incompleteFileSet:
            "The fixed recovery journal file set is incomplete."
        case .unsupportedSchema:
            "The recovery journal schema is unsupported."
        case .fileSetMismatch:
            "The recovery journal files do not belong to one file set."
        case .bothCopiesInvalid:
            "Neither recovery journal copy is valid."
        case .equalGenerationDivergence:
            "Recovery journal copies diverge at the same generation."
        case .reconciliationRequired:
            "A recovery journal entry requires explicit reconciliation."
        case .generationExhausted:
            "The recovery journal generation is exhausted."
        case .revisionExhausted:
            "A recovery journal entry revision is exhausted."
        case .lockUnavailable:
            "The recovery journal is busy."
        case .cancelled:
            "The recovery journal operation was cancelled."
        case .operation(_, let code), .durabilityUncertain(_, let code):
            String(cString: strerror(code))
        case .cleanupFailure(let primary, let cleanup, let code):
            "\(primary.localizedDescription) Cleanup \(cleanup.rawValue) also failed: "
                + String(cString: strerror(code))
        }
    }
}

private func recoveryJournalFileLock(
    _ descriptor: Int32,
    _ operation: Int32
) -> Int32 {
    flock(descriptor, operation)
}

struct RecoveryJournalSyscalls: @unchecked Sendable {
    var files: SecureFileSyscalls
    var fileLock: (Int32, Int32) -> Int32
    var waitBeforeLockRetry: () -> Void

    static let live = RecoveryJournalSyscalls(
        files: .live,
        fileLock: recoveryJournalFileLock,
        waitBeforeLockRetry: { _ = Darwin.usleep(1_000) })
}

enum RecoveryJournalLimits {
    static let maximumEntries = 256
    static let maximumEncodedBytes = 1 * 1_024 * 1_024
    static let maximumURLOrBookmarkBytes = 64 * 1_024
    static let maximumJSONDepth = 16
    static let maximumLockAttempts = 64
    static let maximumInterruptedSyscallAttempts = 8
}

private let zeroRecoveryJournalUUID = "00000000-0000-0000-0000-000000000000"

private struct RecoveryJournalPayload: Codable, Equatable {
    let entries: [RecoveryJournalEntry]
}

private enum RecoveryJournalPayloadCodec {
    static func encode(_ entries: [RecoveryJournalEntry]) throws -> Data {
        try validate(entries)
        let ordered = entries.sorted {
            $0.id.uuidString.compare($1.id.uuidString) == .orderedAscending
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded: Data
        do {
            encoded = try encoder.encode(RecoveryJournalPayload(entries: ordered))
        } catch {
            throw RecoveryJournalError.invalidEntry
        }
        guard encoded.count + RecoveryJournalDiskFormat.recordHeaderByteCount
            <= RecoveryJournalLimits.maximumEncodedBytes
        else {
            throw RecoveryJournalError.encodedSizeExceeded(
                maximumBytes: RecoveryJournalLimits.maximumEncodedBytes)
        }
        return encoded
    }

    static func decode(_ data: Data) throws -> [RecoveryJournalEntry] {
        try enforceNestingLimit(data)
        let payload: RecoveryJournalPayload
        do {
            payload = try JSONDecoder().decode(RecoveryJournalPayload.self, from: data)
        } catch {
            throw RecoveryJournalError.invalidEntry
        }
        try validate(payload.entries)

        // This is an independent canonicality check, not reliance on
        // JSONDecoder's duplicate-key or number-spelling choices. Duplicate
        // keys, exponent-form integers, insignificant whitespace, alternate
        // escaping, or unsorted entries decode to a value whose canonical
        // re-encoding differs byte-for-byte and are rejected.
        guard try encode(payload.entries) == data else {
            throw RecoveryJournalError.invalidEntry
        }
        return payload.entries
    }

    private static func validate(_ entries: [RecoveryJournalEntry]) throws {
        guard entries.count <= RecoveryJournalLimits.maximumEntries else {
            throw RecoveryJournalError.tooManyEntries(
                maximum: RecoveryJournalLimits.maximumEntries)
        }
        guard Set(entries.map(\.id)).count == entries.count else {
            throw RecoveryJournalError.invalidEntry
        }
        for entry in entries {
            try validate(entry)
        }
    }

    private static func validate(_ entry: RecoveryJournalEntry) throws {
        guard entry.id.uuidString != zeroRecoveryJournalUUID,
            entry.revision > 0
        else { throw RecoveryJournalError.invalidEntry }
        let destination = entry.destination
        guard destination.presentationURLString.utf8.count
            <= RecoveryJournalLimits.maximumURLOrBookmarkBytes,
            destination.bookmark?.count ?? 0
            <= RecoveryJournalLimits.maximumURLOrBookmarkBytes
        else {
            throw RecoveryJournalError.fieldSizeExceeded(
                maximumBytes: RecoveryJournalLimits.maximumURLOrBookmarkBytes)
        }
        guard let url = URL(string: destination.presentationURLString),
            BoundedRegularFileReader.hasLocalFileAuthority(url),
            !url.hasDirectoryPath,
            url.standardizedFileURL.absoluteString == destination.presentationURLString,
            let destinationComponent = try? destination.fileComponent(),
            Data(url.lastPathComponent.utf8) == destination.componentBytes,
            url.deletingLastPathComponent().appendingPathComponent(
                destinationComponent.rawValue,
                isDirectory: false
            ).standardizedFileURL.absoluteString == destination.presentationURLString
        else { throw RecoveryJournalError.invalidEntry }

        switch entry.expectation {
        case .missing:
            break
        case .exact(let version):
            guard version.isStructurallyValid else {
                throw RecoveryJournalError.invalidEntry
            }
        }
        if let stage = entry.stage {
            guard (try? stage.fileComponent()) != nil,
                stage.version.isStructurallyValid,
                stage.isScoped(to: destination),
                stage.component != destination.component
            else { throw RecoveryJournalError.invalidEntry }
        }
        if let planned = entry.plannedStageComponent {
            guard (try? FileComponent(planned)) != nil,
                planned != destination.component,
                entry.stage == nil || entry.stage?.component == planned
            else { throw RecoveryJournalError.invalidEntry }
        }
        if let committed = entry.committedDestinationVersion,
            !committed.isStructurallyValid
        {
            throw RecoveryJournalError.invalidEntry
        }

        switch entry.phase {
        case .preparing:
            guard entry.committedDestinationVersion == nil
            else { throw RecoveryJournalError.invalidEntry }
        case .staged, .publishing:
            guard entry.stage?.contents == .unpublishedScratch,
                entry.committedDestinationVersion == nil
            else { throw RecoveryJournalError.invalidEntry }
        case .committed:
            guard entry.committedDestinationVersion != nil else {
                throw RecoveryJournalError.invalidEntry
            }
            switch entry.expectation {
            case .missing:
                guard entry.stage == nil else {
                    throw RecoveryJournalError.invalidEntry
                }
            case .exact:
                guard entry.stage == nil
                    || entry.stage?.contents == .previousDestination
                else { throw RecoveryJournalError.invalidEntry }
            }
        case .indeterminate:
            guard entry.plannedStageComponent != nil
                || entry.stage != nil
                || entry.committedDestinationVersion != nil
            else {
                throw RecoveryJournalError.invalidEntry
            }
        }
    }

    private static func enforceNestingLimit(_ data: Data) throws {
        var depth = 0
        var inString = false
        var escaped = false
        for byte in data {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    inString = false
                }
                continue
            }
            if byte == 0x22 {
                inString = true
            } else if byte == 0x7B || byte == 0x5B {
                depth += 1
                guard depth <= RecoveryJournalLimits.maximumJSONDepth else {
                    throw RecoveryJournalError.nestingLimitExceeded(
                        maximumDepth: RecoveryJournalLimits.maximumJSONDepth)
                }
            } else if byte == 0x7D || byte == 0x5D {
                depth -= 1
                guard depth >= 0 else {
                    throw RecoveryJournalError.invalidEntry
                }
            }
        }
        guard depth == 0, !inString, !escaped else {
            throw RecoveryJournalError.invalidEntry
        }
    }
}

enum RecoveryJournalEntryTransition {
    static func validate(
        previous: RecoveryJournalEntry?,
        next: RecoveryJournalEntry
    ) throws {
        if let previous {
            guard previous.id == next.id else {
                throw RecoveryJournalError.invalidEntry
            }
            let (expectedRevision, overflow) = previous.revision.addingReportingOverflow(1)
            guard !overflow, next.revision == expectedRevision else {
                throw overflow
                    ? RecoveryJournalError.revisionExhausted
                    : RecoveryJournalError.invalidEntry
            }
            guard allowed(previous.phase, next.phase) else {
                throw RecoveryJournalError.invalidEntry
            }
            guard previous.destination == next.destination else {
                throw RecoveryJournalError.invalidEntry
            }
            if next.phase != .preparing,
                previous.expectation != next.expectation
            {
                throw RecoveryJournalError.invalidEntry
            }
            if let previousStage = previous.stage,
                let nextStage = next.stage,
                previousStage.component != nextStage.component
            {
                throw RecoveryJournalError.invalidEntry
            }
            if next.phase != .preparing,
                previous.plannedStageComponent != next.plannedStageComponent
            {
                throw RecoveryJournalError.invalidEntry
            }
        } else {
            guard next.revision == 1,
                next.phase == .preparing
            else { throw RecoveryJournalError.invalidEntry }
        }
    }

    private static func allowed(
        _ previous: RecoveryJournalTransactionPhase,
        _ next: RecoveryJournalTransactionPhase
    ) -> Bool {
        switch (previous, next) {
        case (.preparing, .preparing),
            (.preparing, .staged),
            (.preparing, .indeterminate),
            (.staged, .staged),
            (.staged, .preparing),
            (.staged, .publishing),
            (.staged, .indeterminate),
            (.publishing, .preparing),
            (.publishing, .committed),
            (.publishing, .indeterminate),
            (.committed, .committed),
            (.committed, .preparing):
            true
        default:
            false
        }
    }
}

enum RecoveryJournalDiskFormat {
    static let schemaVersion: UInt32 = 1
    static let recordMagic = Data("MDRJNL01".utf8)
    static let lockMagic = Data("MDRJLOCK".utf8)
    static let uuidByteCount = 36
    static let recordHeaderByteCount = 8 + 4 + uuidByteCount + 8 + 4 + SHA256.byteCount
    static let identityByteCount = 8 + 8 + 4 + 8 + 8
    static let lockManifestByteCount = 8 + 4 + uuidByteCount
        + (3 * identityByteCount) + SHA256.byteCount

    struct FileSetManifest: Equatable {
        let fileSetID: UUID
        let lockIdentity: RecoveryJournalFileIdentityObservation
        let copyAIdentity: RecoveryJournalFileIdentityObservation
        let copyBIdentity: RecoveryJournalFileIdentityObservation
    }

    struct DecodedRecord: Equatable {
        let fileSetID: UUID
        let generation: UInt64
        let payload: Data
    }

    static func canonicalPayload(entries: [RecoveryJournalEntry]) throws -> Data {
        try RecoveryJournalPayloadCodec.encode(entries)
    }

    static func decodeEntries(from recordData: Data) throws -> [RecoveryJournalEntry] {
        let record = try decodeRecord(recordData)
        return try RecoveryJournalPayloadCodec.decode(record.payload)
    }

    static func encodeRecord(
        fileSetID: UUID,
        generation: UInt64,
        entries: [RecoveryJournalEntry]
    ) throws -> Data {
        guard fileSetID.uuidString != zeroRecoveryJournalUUID,
            generation > 0
        else { throw RecoveryJournalError.invalidEntry }
        let payload = try RecoveryJournalPayloadCodec.encode(entries)
        return try encodeRecord(
            fileSetID: fileSetID,
            generation: generation,
            canonicalPayload: payload)
    }

    /// Internal so corruption tests can produce checksum-valid but
    /// noncanonical payloads. Production callers use the typed overload.
    static func encodeRecord(
        fileSetID: UUID,
        generation: UInt64,
        canonicalPayload: Data
    ) throws -> Data {
        guard canonicalPayload.count + recordHeaderByteCount
            <= RecoveryJournalLimits.maximumEncodedBytes,
            let payloadLength = UInt32(exactly: canonicalPayload.count)
        else {
            throw RecoveryJournalError.encodedSizeExceeded(
                maximumBytes: RecoveryJournalLimits.maximumEncodedBytes)
        }
        var data = Data()
        data.reserveCapacity(recordHeaderByteCount + canonicalPayload.count)
        data.append(recordMagic)
        data.appendBigEndian(schemaVersion)
        data.append(Data(fileSetID.uuidString.utf8))
        data.appendBigEndian(generation)
        data.appendBigEndian(payloadLength)
        let checksummedPrefix = data
        var checksummedRecord = checksummedPrefix
        checksummedRecord.append(canonicalPayload)
        data.append(Data(SHA256.hash(data: checksummedRecord)))
        data.append(canonicalPayload)
        return data
    }

    static func decodeRecord(_ data: Data) throws -> DecodedRecord {
        guard data.count >= recordHeaderByteCount,
            data.prefix(recordMagic.count) == recordMagic
        else { throw RecoveryJournalError.invalidEntry }
        let schemaOffset = recordMagic.count
        guard data.readUInt32(at: schemaOffset) == schemaVersion else {
            throw RecoveryJournalError.unsupportedSchema
        }
        let uuidOffset = schemaOffset + 4
        let uuidBytes = data[uuidOffset..<(uuidOffset + uuidByteCount)]
        guard let uuidString = String(data: uuidBytes, encoding: .utf8),
            let fileSetID = UUID(uuidString: uuidString),
            fileSetID.uuidString == uuidString,
            uuidString != zeroRecoveryJournalUUID
        else { throw RecoveryJournalError.invalidEntry }
        let generationOffset = uuidOffset + uuidByteCount
        guard let generation = data.readUInt64(at: generationOffset) else {
            throw RecoveryJournalError.invalidEntry
        }
        guard generation > 0 else { throw RecoveryJournalError.invalidEntry }
        let lengthOffset = generationOffset + 8
        guard let payloadLength = data.readUInt32(at: lengthOffset) else {
            throw RecoveryJournalError.invalidEntry
        }
        let checksumOffset = lengthOffset + 4
        let payloadOffset = checksumOffset + SHA256.byteCount
        guard Int(payloadLength) == data.count - payloadOffset else {
            throw RecoveryJournalError.invalidEntry
        }
        let expectedChecksum = data[checksumOffset..<payloadOffset]
        let payload = Data(data[payloadOffset...])
        var checksummedRecord = Data(data[..<checksumOffset])
        checksummedRecord.append(payload)
        guard Data(SHA256.hash(data: checksummedRecord)) == expectedChecksum else {
            throw RecoveryJournalError.invalidEntry
        }
        return DecodedRecord(
            fileSetID: fileSetID,
            generation: generation,
            payload: payload)
    }

    static func encodeLockManifest(_ manifest: FileSetManifest) -> Data {
        precondition(manifest.fileSetID.uuidString != zeroRecoveryJournalUUID)
        var body = Data()
        body.reserveCapacity(lockManifestByteCount)
        body.append(lockMagic)
        body.appendBigEndian(schemaVersion)
        body.append(Data(manifest.fileSetID.uuidString.utf8))
        body.appendIdentity(manifest.lockIdentity)
        body.appendIdentity(manifest.copyAIdentity)
        body.appendIdentity(manifest.copyBIdentity)
        body.append(Data(SHA256.hash(data: body)))
        return body
    }

    static func decodeLockManifest(_ data: Data) throws -> FileSetManifest {
        guard data.count == lockManifestByteCount,
            data.prefix(lockMagic.count) == lockMagic
        else { throw RecoveryJournalError.incompleteFileSet }
        let schemaOffset = lockMagic.count
        guard data.readUInt32(at: schemaOffset) == schemaVersion else {
            throw RecoveryJournalError.unsupportedSchema
        }
        let uuidOffset = schemaOffset + 4
        let identitiesOffset = uuidOffset + uuidByteCount
        let checksumOffset = identitiesOffset + (3 * identityByteCount)
        guard Data(SHA256.hash(data: data[..<checksumOffset]))
                == data[checksumOffset...],
            let uuidString = String(
                data: data[uuidOffset..<(uuidOffset + uuidByteCount)],
                encoding: .utf8),
            let fileSetID = UUID(uuidString: uuidString),
            fileSetID.uuidString == uuidString,
            uuidString != zeroRecoveryJournalUUID
        else { throw RecoveryJournalError.incompleteFileSet }
        guard let lockIdentity = data.readIdentity(at: identitiesOffset),
            let copyAIdentity = data.readIdentity(
                at: identitiesOffset + identityByteCount),
            let copyBIdentity = data.readIdentity(
                at: identitiesOffset + (2 * identityByteCount))
        else { throw RecoveryJournalError.incompleteFileSet }
        return FileSetManifest(
            fileSetID: fileSetID,
            lockIdentity: lockIdentity,
            copyAIdentity: copyAIdentity,
            copyBIdentity: copyBIdentity)
    }
}

enum RecoveryJournalOpeningMode: Equatable, Sendable {
    /// May create the file set only when the lock name is absent. If any
    /// member already exists, creation is never used to repair or replace it.
    case initializeIfAbsent
    /// Requires the complete previously initialized set. This is the startup
    /// mode once the application knows it has owned a journal before.
    case existing
}

/// A bounded, fixed-inode journal. Every operation reopens the three trusted
/// children by descriptor, validates their original identities, and holds the
/// exact lock inode for the complete read/modify/write critical section.
/// Journal bytes are observations only; they never manufacture live file
/// authority without a later descriptor-relative revalidation.
///
/// The SHA-256 field is a corruption checksum, not a MAC. Owner-only modes,
/// ACL removal, exact inode checks, and the private parent protect against
/// other users and accidental replacement. A hostile process already running
/// as this same uid can rewrite a fixed inode and recompute the checksum; that
/// threat requires privilege separation or a protected key outside this file
/// format and is intentionally not claimed here.
final class RecoveryJournal: @unchecked Sendable {
    static let lockFileName = ".markdev-recovery.lock"
    static let copyAFileName = ".markdev-recovery-a.journal"
    static let copyBFileName = ".markdev-recovery-b.journal"

    fileprivate struct TrustedName: Sendable {
        let component: FileComponent
        let identity: LocalFileIdentity
    }

    fileprivate struct Bootstrap {
        let fileSetID: UUID
        let lock: TrustedName
        let copies: [RecoveryJournalCopy: TrustedName]
    }

    fileprivate struct ValidCopy {
        let copy: RecoveryJournalCopy
        let record: RecoveryJournalDiskFormat.DecodedRecord
        let entries: [RecoveryJournalEntry]
        let raw: Data
    }

    fileprivate struct LoadedState {
        let winner: ValidCopy
        let valid: [RecoveryJournalCopy: ValidCopy]
        let degraded: Set<RecoveryJournalCopy>
    }

    fileprivate struct RecoverableInitialChild {
        let child: SecureLocalDirectoryHandle.TrustedRegularChild
        let validRecord: RecoveryJournalDiskFormat.DecodedRecord?
    }

    private let storage: PrivateStorageDirectory
    private let syscalls: RecoveryJournalSyscalls
    private let lockName: TrustedName
    private let copyNames: [RecoveryJournalCopy: TrustedName]
    let fileSetID: UUID

    /// Opens the production journal beneath an owner-private, descriptor-
    /// created Application Support hierarchy. Tests pass an explicit root and
    /// never touch this process-global location.
    static func production(
        applicationSupportDirectory: URL? = nil,
        syscalls: RecoveryJournalSyscalls = .live,
        cancellationCheck: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> RecoveryJournal {
        let applicationSupport: URL
        if let applicationSupportDirectory {
            guard BoundedRegularFileReader.hasLocalFileAuthority(
                applicationSupportDirectory)
            else {
                throw RecoveryJournalError.invalidStorage(
                    .operation(.openDirectory, errno: EINVAL))
            }
            applicationSupport = applicationSupportDirectory.standardizedFileURL
        } else {
            guard let resolved = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask).first
            else { throw RecoveryJournalError.applicationSupportUnavailable }
            applicationSupport = resolved.standardizedFileURL
        }
        let base: SecureLocalDirectoryHandle
        do {
            base = try SecureLocalDirectoryHandle(
                opening: applicationSupport,
                syscalls: syscalls.files,
                cancellationCheck: cancellationCheck)
            var status = stat()
            guard syscalls.files.fstat(base.descriptor, &status) == 0,
                status.st_mode & S_IFMT == S_IFDIR,
                status.st_uid == geteuid()
            else { throw SecureLocalFileError.unsupportedEntry }
            let app = try base.openOrCreatePrivateDirectory(
                try FileComponent("MarkDev"),
                cancellationCheck: cancellationCheck)
            let recovery = try app.openOrCreatePrivateDirectory(
                try FileComponent("Recovery"),
                cancellationCheck: cancellationCheck)
            let version = try recovery.openOrCreatePrivateDirectory(
                try FileComponent("v1"),
                cancellationCheck: cancellationCheck)
            return try RecoveryJournal(
                storageDirectory: version.url,
                openingMode: .initializeIfAbsent,
                syscalls: syscalls,
                cancellationCheck: cancellationCheck)
        } catch let error as RecoveryJournalError {
            throw error
        } catch let error as SecureLocalFileError {
            throw RecoveryJournalError.invalidStorage(error)
        } catch {
            throw RecoveryJournalError.applicationSupportUnavailable
        }
    }

    init(
        storageDirectory: URL,
        openingMode: RecoveryJournalOpeningMode = .initializeIfAbsent,
        syscalls: RecoveryJournalSyscalls = .live,
        cancellationCheck: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) throws {
        do {
            storage = try PrivateStorageDirectory(
                existing: storageDirectory,
                syscalls: syscalls.files)
        } catch let error as SecureLocalFileError {
            throw Self.mapStorageError(error)
        }
        self.syscalls = syscalls
        let bootstrap = try Self.bootstrap(
            directory: storage.handle,
            openingMode: openingMode,
            syscalls: syscalls,
            cancellationCheck: cancellationCheck)
        fileSetID = bootstrap.fileSetID
        lockName = bootstrap.lock
        copyNames = bootstrap.copies
    }

    func load(
        cancellationCheck: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> RecoveryJournalSnapshot {
        try withExclusiveLock(cancellationCheck: cancellationCheck) {
            let state = try loadLocked(cancellationCheck: cancellationCheck)
            return Self.snapshot(from: state)
        }
    }

    @discardableResult
    func upsert(
        _ entry: RecoveryJournalEntry,
        cancellationCheck: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> RecoveryJournalSnapshot {
        try withExclusiveLock(cancellationCheck: cancellationCheck) {
            let state = try loadLocked(cancellationCheck: cancellationCheck)
            var entries = Dictionary(uniqueKeysWithValues: state.winner.entries.map {
                ($0.id, $0)
            })
            if let existing = entries[entry.id], existing.revision == entry.revision {
                guard existing == entry else {
                    throw RecoveryJournalError.invalidEntry
                }
                return try settleIdempotentRetry(
                    entries: state.winner.entries,
                    state: state,
                    cancellationCheck: cancellationCheck)
            }
            try RecoveryJournalEntryTransition.validate(
                previous: entries[entry.id],
                next: entry)
            entries[entry.id] = entry
            return try persistLocked(
                Array(entries.values),
                from: state,
                cancellationCheck: cancellationCheck)
        }
    }

    /// Removes only the exact revision the caller reconciled. A stale cleanup
    /// cannot erase a newer phase written by another process.
    @discardableResult
    func remove(
        id: UUID,
        expectedRevision: UInt64,
        cancellationCheck: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> RecoveryJournalSnapshot {
        try withExclusiveLock(cancellationCheck: cancellationCheck) {
            let state = try loadLocked(cancellationCheck: cancellationCheck)
            var entries = Dictionary(uniqueKeysWithValues: state.winner.entries.map {
                ($0.id, $0)
            })
            guard let current = entries[id] else {
                let hasNewerObservedRevision = state.valid.values.contains { copy in
                    guard let observed = copy.entries.first(where: { $0.id == id }) else {
                        return false
                    }
                    return observed.revision > expectedRevision
                }
                guard !hasNewerObservedRevision else {
                    throw RecoveryJournalError.invalidEntry
                }
                return try settleIdempotentRetry(
                    entries: state.winner.entries,
                    state: state,
                    cancellationCheck: cancellationCheck)
            }
            guard current.revision == expectedRevision else {
                throw RecoveryJournalError.invalidEntry
            }
            entries.removeValue(forKey: id)
            return try persistLocked(
                Array(entries.values),
                from: state,
                cancellationCheck: cancellationCheck)
        }
    }

    private static func snapshot(from state: LoadedState) -> RecoveryJournalSnapshot {
        RecoveryJournalSnapshot(
            fileSetID: state.winner.record.fileSetID,
            generation: state.winner.record.generation,
            entries: state.winner.entries,
            degradedCopies: state.degraded)
    }

    private func settleIdempotentRetry(
        entries: [RecoveryJournalEntry],
        state: LoadedState,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) throws -> RecoveryJournalSnapshot {
        let hasTwoEquivalentCopies = RecoveryJournalCopy.allCases.allSatisfy { copy in
            state.valid[copy]?.entries == entries
        }
        if hasTwoEquivalentCopies {
            return Self.snapshot(from: state)
        }
        return try persistLocked(
            entries,
            from: state,
            cancellationCheck: cancellationCheck)
    }
}

private extension RecoveryJournal {
    static func bootstrap(
        directory: SecureLocalDirectoryHandle,
        openingMode: RecoveryJournalOpeningMode,
        syscalls: RecoveryJournalSyscalls,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) throws -> Bootstrap {
        let lockComponent = try component(Self.lockFileName)
        let copyAComponent = try component(Self.copyAFileName)
        let copyBComponent = try component(Self.copyBFileName)

        let lockChild: SecureLocalDirectoryHandle.TrustedRegularChild
        switch openingMode {
        case .existing:
            lockChild = try openExisting(
                lockComponent,
                expectedIdentity: nil,
                directory: directory,
                accessMode: O_RDWR,
                cancellationCheck: cancellationCheck)
        case .initializeIfAbsent:
            do {
                lockChild = try openCreated(
                    lockComponent,
                    directory: directory,
                    cancellationCheck: cancellationCheck)
            } catch RecoveryJournalError.invalidStorage(
                .operation(.createStage, let code)) where code == EEXIST
            {
                lockChild = try openExisting(
                    lockComponent,
                    expectedIdentity: nil,
                    directory: directory,
                    accessMode: O_RDWR,
                    cancellationCheck: cancellationCheck)
            }
        }
        defer { _ = syscalls.files.close(lockChild.descriptor) }

        try acquireLock(
            lockChild.descriptor,
            syscalls: syscalls,
            cancellationCheck: cancellationCheck)
        let result: Result<Bootstrap, Error>
        do {
            _ = try revalidate(
                lockChild,
                component: lockComponent,
                directory: directory,
                cancellationCheck: cancellationCheck)
            try verifyACL(lockChild.descriptor)

            let bootstrap: Bootstrap
            if lockChild.wasCreated {
                guard openingMode == .initializeIfAbsent else {
                    throw RecoveryJournalError.incompleteFileSet
                }
                bootstrap = try initializeFileSet(
                    lock: lockChild,
                    lockComponent: lockComponent,
                    copyAComponent: copyAComponent,
                    copyBComponent: copyBComponent,
                    directory: directory,
                    syscalls: syscalls,
                    cancellationCheck: cancellationCheck)
            } else {
                let lockData = try readFixedFile(
                    descriptor: lockChild.descriptor,
                    component: lockComponent,
                    identity: lockChild.identity,
                    maximumBytes: RecoveryJournalDiskFormat.lockManifestByteCount,
                    directory: directory,
                    syscalls: syscalls,
                    cancellationCheck: cancellationCheck)
                if lockData.isEmpty, openingMode == .initializeIfAbsent {
                    bootstrap = try recoverIncompleteInitialization(
                        lock: lockChild,
                        lockComponent: lockComponent,
                        copyAComponent: copyAComponent,
                        copyBComponent: copyBComponent,
                        directory: directory,
                        syscalls: syscalls,
                        cancellationCheck: cancellationCheck)
                } else {
                    bootstrap = try openFileSet(
                        lock: lockChild,
                        lockComponent: lockComponent,
                        lockData: lockData,
                        copyAComponent: copyAComponent,
                        copyBComponent: copyBComponent,
                        directory: directory,
                        syscalls: syscalls,
                        cancellationCheck: cancellationCheck)
                }
            }
            _ = try revalidate(
                lockChild,
                component: lockComponent,
                directory: directory,
                cancellationCheck: { false })
            result = .success(bootstrap)
        } catch {
            result = .failure(error)
        }
        let releaseResult = Result {
            try releaseLock(lockChild.descriptor, syscalls: syscalls)
        }
        return try resolveLockResults(result, releaseResult: releaseResult)
    }

    static func initializeFileSet(
        lock: SecureLocalDirectoryHandle.TrustedRegularChild,
        lockComponent: FileComponent,
        copyAComponent: FileComponent,
        copyBComponent: FileComponent,
        directory: SecureLocalDirectoryHandle,
        syscalls: RecoveryJournalSyscalls,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) throws -> Bootstrap {
        if cancellationCheck() { throw RecoveryJournalError.cancelled }
        try hardenCreatedFile(
            lock,
            component: lockComponent,
            directory: directory,
            cancellationCheck: cancellationCheck)

        let copyA = try openCreated(
            copyAComponent,
            directory: directory,
            cancellationCheck: cancellationCheck)
        defer { _ = syscalls.files.close(copyA.descriptor) }
        try hardenCreatedFile(
            copyA,
            component: copyAComponent,
            directory: directory,
            cancellationCheck: cancellationCheck)

        let copyB = try openCreated(
            copyBComponent,
            directory: directory,
            cancellationCheck: cancellationCheck)
        defer { _ = syscalls.files.close(copyB.descriptor) }
        try hardenCreatedFile(
            copyB,
            component: copyBComponent,
            directory: directory,
            cancellationCheck: cancellationCheck)

        var fileSetID = UUID()
        if fileSetID.uuidString == zeroRecoveryJournalUUID { fileSetID = UUID() }
        guard fileSetID.uuidString != zeroRecoveryJournalUUID else {
            throw RecoveryJournalError.invalidEntry
        }
        let initialRecord = try RecoveryJournalDiskFormat.encodeRecord(
            fileSetID: fileSetID,
            generation: 1,
            entries: [])
        try rewriteFixedFile(
            descriptor: copyA.descriptor,
            data: initialRecord,
            syscalls: syscalls,
            operationCancellationCheck: cancellationCheck)
        try rewriteFixedFile(
            descriptor: copyB.descriptor,
            data: initialRecord,
            syscalls: syscalls,
            operationCancellationCheck: cancellationCheck)
        try rewriteFixedFile(
            descriptor: lock.descriptor,
            data: RecoveryJournalDiskFormat.encodeLockManifest(.init(
                fileSetID: fileSetID,
                lockIdentity: RecoveryJournalFileIdentityObservation(lock.identity),
                copyAIdentity: RecoveryJournalFileIdentityObservation(copyA.identity),
                copyBIdentity: RecoveryJournalFileIdentityObservation(copyB.identity))),
            syscalls: syscalls,
            operationCancellationCheck: cancellationCheck)

        _ = try revalidate(
            copyA,
            component: copyAComponent,
            directory: directory,
            cancellationCheck: { false })
        _ = try revalidate(
            copyB,
            component: copyBComponent,
            directory: directory,
            cancellationCheck: { false })
        _ = try revalidate(
            lock,
            component: lockComponent,
            directory: directory,
            cancellationCheck: { false })
        try syncDirectory(directory, syscalls: syscalls)

        return Bootstrap(
            fileSetID: fileSetID,
            lock: TrustedName(
                component: lockComponent,
                identity: lock.identity),
            copies: [
                .a: TrustedName(component: copyAComponent, identity: copyA.identity),
                .b: TrustedName(component: copyBComponent, identity: copyB.identity),
            ])
    }

    /// Resumes only the narrow state our own first initialization can leave:
    /// an empty lock plus fixed children that are absent, empty, or contain an
    /// exact canonical generation-1 empty record. Partial/noncanonical bytes,
    /// entries, generations, or conflicting file-set IDs are never repaired.
    static func recoverIncompleteInitialization(
        lock: SecureLocalDirectoryHandle.TrustedRegularChild,
        lockComponent: FileComponent,
        copyAComponent: FileComponent,
        copyBComponent: FileComponent,
        directory: SecureLocalDirectoryHandle,
        syscalls: RecoveryJournalSyscalls,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) throws -> Bootstrap {
        let copyA = try openRecoverableInitialChild(
            copyAComponent,
            directory: directory,
            syscalls: syscalls,
            cancellationCheck: cancellationCheck)
        defer { _ = syscalls.files.close(copyA.child.descriptor) }
        let copyB = try openRecoverableInitialChild(
            copyBComponent,
            directory: directory,
            syscalls: syscalls,
            cancellationCheck: cancellationCheck)
        defer { _ = syscalls.files.close(copyB.child.descriptor) }

        let observedIDs = Set(
            [copyA.validRecord?.fileSetID, copyB.validRecord?.fileSetID].compactMap { $0 })
        guard observedIDs.count <= 1 else {
            throw RecoveryJournalError.fileSetMismatch
        }
        var fileSetID = observedIDs.first ?? UUID()
        if fileSetID.uuidString == zeroRecoveryJournalUUID { fileSetID = UUID() }
        guard fileSetID.uuidString != zeroRecoveryJournalUUID else {
            throw RecoveryJournalError.invalidEntry
        }
        let initialRecord = try RecoveryJournalDiskFormat.encodeRecord(
            fileSetID: fileSetID,
            generation: 1,
            entries: [])

        for recoverable in [copyA, copyB] {
            if recoverable.validRecord == nil {
                try rewriteFixedFile(
                    descriptor: recoverable.child.descriptor,
                    data: initialRecord,
                    syscalls: syscalls,
                    operationCancellationCheck: cancellationCheck)
            } else {
                try syncFile(recoverable.child.descriptor, syscalls: syscalls)
            }
        }
        try rewriteFixedFile(
            descriptor: lock.descriptor,
            data: RecoveryJournalDiskFormat.encodeLockManifest(.init(
                fileSetID: fileSetID,
                lockIdentity: RecoveryJournalFileIdentityObservation(lock.identity),
                copyAIdentity: RecoveryJournalFileIdentityObservation(
                    copyA.child.identity),
                copyBIdentity: RecoveryJournalFileIdentityObservation(
                    copyB.child.identity))),
            syscalls: syscalls,
            operationCancellationCheck: cancellationCheck)

        _ = try revalidate(
            copyA.child,
            component: copyAComponent,
            directory: directory,
            cancellationCheck: { false })
        _ = try revalidate(
            copyB.child,
            component: copyBComponent,
            directory: directory,
            cancellationCheck: { false })
        _ = try revalidate(
            lock,
            component: lockComponent,
            directory: directory,
            cancellationCheck: { false })
        try syncDirectory(directory, syscalls: syscalls)

        return Bootstrap(
            fileSetID: fileSetID,
            lock: TrustedName(component: lockComponent, identity: lock.identity),
            copies: [
                .a: TrustedName(
                    component: copyAComponent,
                    identity: copyA.child.identity),
                .b: TrustedName(
                    component: copyBComponent,
                    identity: copyB.child.identity),
            ])
    }

    static func openRecoverableInitialChild(
        _ component: FileComponent,
        directory: SecureLocalDirectoryHandle,
        syscalls: RecoveryJournalSyscalls,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) throws -> RecoverableInitialChild {
        let child: SecureLocalDirectoryHandle.TrustedRegularChild
        let wasCreated: Bool
        do {
            child = try openExisting(
                component,
                expectedIdentity: nil,
                directory: directory,
                accessMode: O_RDWR,
                cancellationCheck: cancellationCheck)
            wasCreated = false
        } catch RecoveryJournalError.incompleteFileSet {
            child = try openCreated(
                component,
                directory: directory,
                cancellationCheck: cancellationCheck)
            wasCreated = true
        }
        var transfersDescriptor = false
        defer {
            if !transfersDescriptor { _ = syscalls.files.close(child.descriptor) }
        }
        if wasCreated {
            try hardenCreatedFile(
                child,
                component: component,
                directory: directory,
                cancellationCheck: cancellationCheck)
        }
        try verifyACL(child.descriptor)
        let raw = try readFixedFile(
            descriptor: child.descriptor,
            component: component,
            identity: child.identity,
            maximumBytes: RecoveryJournalLimits.maximumEncodedBytes,
            directory: directory,
            syscalls: syscalls,
            cancellationCheck: cancellationCheck)
        guard !raw.isEmpty else {
            transfersDescriptor = true
            return RecoverableInitialChild(child: child, validRecord: nil)
        }
        let record: RecoveryJournalDiskFormat.DecodedRecord
        do {
            record = try RecoveryJournalDiskFormat.decodeRecord(raw)
            let entries = try RecoveryJournalPayloadCodec.decode(record.payload)
            guard record.generation == 1, entries.isEmpty else {
                throw RecoveryJournalError.incompleteFileSet
            }
        } catch let error as RecoveryJournalError {
            switch error {
            case .fileSetMismatch:
                throw error
            default:
                throw RecoveryJournalError.incompleteFileSet
            }
        }
        transfersDescriptor = true
        return RecoverableInitialChild(child: child, validRecord: record)
    }

    static func openFileSet(
        lock: SecureLocalDirectoryHandle.TrustedRegularChild,
        lockComponent: FileComponent,
        lockData: Data,
        copyAComponent: FileComponent,
        copyBComponent: FileComponent,
        directory: SecureLocalDirectoryHandle,
        syscalls: RecoveryJournalSyscalls,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) throws -> Bootstrap {
        let manifest = try RecoveryJournalDiskFormat.decodeLockManifest(lockData)
        guard manifest.lockIdentity.matches(lock.identity) else {
            throw RecoveryJournalError.incompleteFileSet
        }
        let fileSetID = manifest.fileSetID

        let copyA = try openExisting(
            copyAComponent,
            expectedIdentity: nil,
            directory: directory,
            accessMode: O_RDONLY,
            cancellationCheck: cancellationCheck)
        defer { _ = syscalls.files.close(copyA.descriptor) }
        guard manifest.copyAIdentity.matches(copyA.identity) else {
            throw RecoveryJournalError.incompleteFileSet
        }
        let copyB = try openExisting(
            copyBComponent,
            expectedIdentity: nil,
            directory: directory,
            accessMode: O_RDONLY,
            cancellationCheck: cancellationCheck)
        defer { _ = syscalls.files.close(copyB.descriptor) }
        guard manifest.copyBIdentity.matches(copyB.identity) else {
            throw RecoveryJournalError.incompleteFileSet
        }
        try verifyACL(copyA.descriptor)
        try verifyACL(copyB.descriptor)

        let names: [RecoveryJournalCopy: TrustedName] = [
            .a: TrustedName(component: copyAComponent, identity: copyA.identity),
            .b: TrustedName(component: copyBComponent, identity: copyB.identity),
        ]
        _ = try loadState(
            fileSetID: fileSetID,
            directory: directory,
            copyNames: names,
            syscalls: syscalls,
            cancellationCheck: cancellationCheck)
        return Bootstrap(
            fileSetID: fileSetID,
            lock: TrustedName(component: lockComponent, identity: lock.identity),
            copies: names)
    }
}

private extension RecoveryJournal {
    static func component(_ value: String) throws -> FileComponent {
        do { return try FileComponent(value) }
        catch { throw RecoveryJournalError.invalidEntry }
    }

    static func mapStorageError(_ error: SecureLocalFileError) -> RecoveryJournalError {
        if error == .cancelled { return .cancelled }
        return .invalidStorage(error)
    }

    static func openCreated(
        _ component: FileComponent,
        directory: SecureLocalDirectoryHandle,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) throws -> SecureLocalDirectoryHandle.TrustedRegularChild {
        do {
            return try directory.openTrustedRegularChild(
                component,
                disposition: .createExclusive,
                accessMode: O_RDWR,
                cancellationCheck: cancellationCheck)
        } catch let error as SecureLocalFileError {
            throw mapStorageError(error)
        }
    }

    static func openExisting(
        _ component: FileComponent,
        expectedIdentity: LocalFileIdentity?,
        directory: SecureLocalDirectoryHandle,
        accessMode: Int32,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) throws -> SecureLocalDirectoryHandle.TrustedRegularChild {
        do {
            return try directory.openTrustedRegularChild(
                component,
                disposition: .existing(expectedIdentity: expectedIdentity),
                accessMode: accessMode,
                cancellationCheck: cancellationCheck)
        } catch SecureLocalFileError.operation(.openTarget, let code) where code == ENOENT {
            throw RecoveryJournalError.incompleteFileSet
        } catch let error as SecureLocalFileError {
            throw mapStorageError(error)
        }
    }

    @discardableResult
    static func revalidate(
        _ child: SecureLocalDirectoryHandle.TrustedRegularChild,
        component: FileComponent,
        directory: SecureLocalDirectoryHandle,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) throws -> stat {
        do {
            return try directory.revalidateTrustedRegularChild(
                descriptor: child.descriptor,
                component: component,
                expectedIdentity: child.identity,
                cancellationCheck: cancellationCheck)
        } catch let error as SecureLocalFileError {
            throw mapStorageError(error)
        }
    }

    @discardableResult
    static func revalidate(
        descriptor: Int32,
        name: TrustedName,
        directory: SecureLocalDirectoryHandle,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) throws -> stat {
        do {
            return try directory.revalidateTrustedRegularChild(
                descriptor: descriptor,
                component: name.component,
                expectedIdentity: name.identity,
                cancellationCheck: cancellationCheck)
        } catch let error as SecureLocalFileError {
            throw mapStorageError(error)
        }
    }

    static func hardenCreatedFile(
        _ child: SecureLocalDirectoryHandle.TrustedRegularChild,
        component: FileComponent,
        directory: SecureLocalDirectoryHandle,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) throws {
        do {
            try clearAndVerifyExtendedACL(on: child.descriptor)
        } catch let error as SecureLocalFileError {
            throw mapStorageError(error)
        }
        _ = try revalidate(
            child,
            component: component,
            directory: directory,
            cancellationCheck: cancellationCheck)
    }

    static func verifyACL(_ descriptor: Int32) throws {
        do { try verifyEmptyExtendedACL(on: descriptor) }
        catch let error as SecureLocalFileError { throw mapStorageError(error) }
    }

    static func acquireLock(
        _ descriptor: Int32,
        syscalls: RecoveryJournalSyscalls,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) throws {
        for attempt in 1...RecoveryJournalLimits.maximumLockAttempts {
            if cancellationCheck() { throw RecoveryJournalError.cancelled }
            errno = 0
            if syscalls.fileLock(descriptor, LOCK_EX | LOCK_NB) == 0 { return }
            let code = errno == 0 ? EIO : errno
            guard code == EWOULDBLOCK || code == EAGAIN || code == EINTR else {
                throw RecoveryJournalError.operation(.acquireLock, errno: code)
            }
            guard attempt < RecoveryJournalLimits.maximumLockAttempts else {
                throw RecoveryJournalError.lockUnavailable(
                    maximumAttempts: RecoveryJournalLimits.maximumLockAttempts)
            }
            syscalls.waitBeforeLockRetry()
        }
        preconditionFailure("finite recovery-journal lock loop exhausted")
    }

    static func releaseLock(
        _ descriptor: Int32,
        syscalls: RecoveryJournalSyscalls
    ) throws {
        errno = 0
        guard syscalls.fileLock(descriptor, LOCK_UN) == 0 else {
            throw RecoveryJournalError.operation(
                .releaseLock, errno: errno == 0 ? EIO : errno)
        }
    }

    static func resolveLockResults<Value>(
        _ bodyResult: Result<Value, Error>,
        releaseResult: Result<Void, Error>
    ) throws -> Value {
        switch (bodyResult, releaseResult) {
        case (.success(let value), .success):
            return value
        case (.success, .failure(let releaseError)):
            throw releaseError
        case (.failure(let primary), .success):
            throw primary
        case (.failure(let primary), .failure(let releaseError)):
            guard let primary = primary as? RecoveryJournalError else {
                // Every protected journal body maps its boundary failures into
                // RecoveryJournalError before reaching this seam. Preserve a
                // conservative typed failure if that invariant is violated.
                throw RecoveryJournalError.cleanupFailure(
                    primary: .invalidEntry,
                    cleanup: .releaseLock,
                    errno: releaseErrno(from: releaseError))
            }
            throw RecoveryJournalError.cleanupFailure(
                primary: primary,
                cleanup: .releaseLock,
                errno: releaseErrno(from: releaseError))
        }
    }

    static func releaseErrno(from error: Error) -> Int32 {
        if case RecoveryJournalError.operation(.releaseLock, let code) = error {
            return code
        }
        return EIO
    }

    static func readFixedFile(
        descriptor: Int32,
        component: FileComponent,
        identity: LocalFileIdentity,
        maximumBytes: Int,
        directory: SecureLocalDirectoryHandle,
        syscalls: RecoveryJournalSyscalls,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) throws -> Data {
        let name = TrustedName(component: component, identity: identity)
        let before = try revalidate(
            descriptor: descriptor,
            name: name,
            directory: directory,
            cancellationCheck: cancellationCheck)
        guard before.st_size >= 0,
            let byteCount = Int(exactly: before.st_size),
            byteCount <= maximumBytes
        else {
            throw RecoveryJournalError.encodedSizeExceeded(maximumBytes: maximumBytes)
        }

        var data = Data(count: byteCount)
        var offset = 0
        while offset < byteCount {
            let readCount: Int = try data.withUnsafeMutableBytes { bytes in
                guard let base = bytes.baseAddress else { return 0 }
                return try retryInt(
                    operation: .readFile,
                    cancellationCheck: cancellationCheck,
                    succeeds: { $0 >= 0 }
                ) {
                    syscalls.files.pread(
                        descriptor,
                        base.advanced(by: offset),
                        byteCount - offset,
                        off_t(offset))
                }
            }
            guard readCount > 0, readCount <= byteCount - offset else {
                throw RecoveryJournalError.invalidEntry
            }
            offset += readCount
        }
        let after = try revalidate(
            descriptor: descriptor,
            name: name,
            directory: directory,
            cancellationCheck: cancellationCheck)
        guard LocalFileStamp(before) == LocalFileStamp(after) else {
            throw RecoveryJournalError.invalidEntry
        }
        return data
    }

    static func rewriteFixedFile(
        descriptor: Int32,
        data: Data,
        syscalls: RecoveryJournalSyscalls,
        operationCancellationCheck: @escaping @Sendable () -> Bool
    ) throws {
        guard data.count <= RecoveryJournalLimits.maximumEncodedBytes else {
            throw RecoveryJournalError.encodedSizeExceeded(
                maximumBytes: RecoveryJournalLimits.maximumEncodedBytes)
        }
        if operationCancellationCheck() { throw RecoveryJournalError.cancelled }

        _ = try retryInt32(
            operation: .truncateFile,
            cancellationCheck: { false },
            succeeds: { $0 == 0 }
        ) {
            syscalls.files.ftruncate(descriptor, 0)
        }
        var offset = 0
        while offset < data.count {
            let written: Int = try data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return 0 }
                return try retryInt(
                    operation: .writeFile,
                    cancellationCheck: { false },
                    succeeds: { $0 >= 0 }
                ) {
                    syscalls.files.pwrite(
                        descriptor,
                        base.advanced(by: offset),
                        data.count - offset,
                        off_t(offset))
                }
            }
            guard written > 0, written <= data.count - offset else {
                throw RecoveryJournalError.operation(.writeFile, errno: EIO)
            }
            offset += written
        }
        do {
            _ = try retryInt32(
                operation: .syncFile,
                cancellationCheck: { false },
                succeeds: { $0 == 0 }
            ) {
                syscalls.files.fsync(descriptor)
            }
        } catch RecoveryJournalError.operation(.syncFile, let code) {
            throw RecoveryJournalError.durabilityUncertain(.syncFile, errno: code)
        }
    }

    static func syncDirectory(
        _ directory: SecureLocalDirectoryHandle,
        syscalls: RecoveryJournalSyscalls
    ) throws {
        do {
            _ = try retryInt32(
                operation: .syncDirectory,
                cancellationCheck: { false },
                succeeds: { $0 == 0 }
            ) {
                syscalls.files.fsync(directory.descriptor)
            }
        } catch RecoveryJournalError.operation(.syncDirectory, let code) {
            throw RecoveryJournalError.durabilityUncertain(.syncDirectory, errno: code)
        }
    }

    static func syncFile(
        _ descriptor: Int32,
        syscalls: RecoveryJournalSyscalls
    ) throws {
        do {
            _ = try retryInt32(
                operation: .syncFile,
                cancellationCheck: { false },
                succeeds: { $0 == 0 }
            ) {
                syscalls.files.fsync(descriptor)
            }
        } catch RecoveryJournalError.operation(.syncFile, let code) {
            throw RecoveryJournalError.durabilityUncertain(.syncFile, errno: code)
        }
    }

    static func retryInt(
        operation: RecoveryJournalOperation,
        cancellationCheck: @escaping @Sendable () -> Bool,
        succeeds: (Int) -> Bool,
        body: () -> Int
    ) throws -> Int {
        for attempt in 1...RecoveryJournalLimits.maximumInterruptedSyscallAttempts {
            if cancellationCheck() { throw RecoveryJournalError.cancelled }
            errno = 0
            let result = body()
            if succeeds(result) { return result }
            let code = errno == 0 ? EIO : errno
            if code != EINTR
                || attempt == RecoveryJournalLimits.maximumInterruptedSyscallAttempts
            {
                throw RecoveryJournalError.operation(operation, errno: code)
            }
        }
        preconditionFailure("finite recovery-journal syscall loop exhausted")
    }

    static func retryInt32(
        operation: RecoveryJournalOperation,
        cancellationCheck: @escaping @Sendable () -> Bool,
        succeeds: (Int32) -> Bool,
        body: () -> Int32
    ) throws -> Int32 {
        for attempt in 1...RecoveryJournalLimits.maximumInterruptedSyscallAttempts {
            if cancellationCheck() { throw RecoveryJournalError.cancelled }
            errno = 0
            let result = body()
            if succeeds(result) { return result }
            let code = errno == 0 ? EIO : errno
            if code != EINTR
                || attempt == RecoveryJournalLimits.maximumInterruptedSyscallAttempts
            {
                throw RecoveryJournalError.operation(operation, errno: code)
            }
        }
        preconditionFailure("finite recovery-journal syscall loop exhausted")
    }
}

private extension RecoveryJournal {
    func withExclusiveLock<Value>(
        cancellationCheck: @escaping @Sendable () -> Bool,
        _ body: () throws -> Value
    ) throws -> Value {
        let lock = try Self.openExisting(
            lockName.component,
            expectedIdentity: lockName.identity,
            directory: storage.handle,
            accessMode: O_RDWR,
            cancellationCheck: cancellationCheck)
        defer { _ = syscalls.files.close(lock.descriptor) }
        try Self.verifyACL(lock.descriptor)
        try Self.acquireLock(
            lock.descriptor,
            syscalls: syscalls,
            cancellationCheck: cancellationCheck)

        let result: Result<Value, Error>
        do {
            _ = try Self.revalidate(
                descriptor: lock.descriptor,
                name: lockName,
                directory: storage.handle,
                cancellationCheck: cancellationCheck)
            let value = try body()
            _ = try Self.revalidate(
                descriptor: lock.descriptor,
                name: lockName,
                directory: storage.handle,
                cancellationCheck: { false })
            result = .success(value)
        } catch {
            result = .failure(error)
        }
        let releaseResult = Result {
            try Self.releaseLock(lock.descriptor, syscalls: syscalls)
        }
        return try Self.resolveLockResults(result, releaseResult: releaseResult)
    }

    func loadLocked(
        cancellationCheck: @escaping @Sendable () -> Bool
    ) throws -> LoadedState {
        try Self.loadState(
            fileSetID: fileSetID,
            directory: storage.handle,
            copyNames: copyNames,
            syscalls: syscalls,
            cancellationCheck: cancellationCheck)
    }

    static func loadState(
        fileSetID: UUID,
        directory: SecureLocalDirectoryHandle,
        copyNames: [RecoveryJournalCopy: TrustedName],
        syscalls: RecoveryJournalSyscalls,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) throws -> LoadedState {
        var valid: [RecoveryJournalCopy: ValidCopy] = [:]
        var degraded = Set<RecoveryJournalCopy>()

        for copy in RecoveryJournalCopy.allCases {
            guard let name = copyNames[copy] else {
                throw RecoveryJournalError.incompleteFileSet
            }
            let child = try openExisting(
                name.component,
                expectedIdentity: name.identity,
                directory: directory,
                accessMode: O_RDONLY,
                cancellationCheck: cancellationCheck)
            defer { _ = syscalls.files.close(child.descriptor) }
            try verifyACL(child.descriptor)

            do {
                let raw = try readFixedFile(
                    descriptor: child.descriptor,
                    component: name.component,
                    identity: name.identity,
                    maximumBytes: RecoveryJournalLimits.maximumEncodedBytes,
                    directory: directory,
                    syscalls: syscalls,
                    cancellationCheck: cancellationCheck)
                let record = try RecoveryJournalDiskFormat.decodeRecord(raw)
                guard record.fileSetID == fileSetID else {
                    throw RecoveryJournalError.fileSetMismatch
                }
                let entries = try RecoveryJournalPayloadCodec.decode(record.payload)
                valid[copy] = ValidCopy(
                    copy: copy,
                    record: record,
                    entries: entries,
                    raw: raw)
            } catch let error as RecoveryJournalError {
                switch error {
                case .invalidEntry,
                    .tooManyEntries,
                    .encodedSizeExceeded,
                    .fieldSizeExceeded,
                    .nestingLimitExceeded:
                    degraded.insert(copy)
                case .unsupportedSchema,
                    .fileSetMismatch,
                    .incompleteFileSet,
                    .bothCopiesInvalid,
                    .equalGenerationDivergence,
                    .reconciliationRequired,
                    .generationExhausted,
                    .revisionExhausted,
                    .lockUnavailable,
                    .cancelled,
                    .applicationSupportUnavailable,
                    .invalidStorage,
                    .operation,
                    .durabilityUncertain,
                    .cleanupFailure:
                    throw error
                }
            }
        }

        let winner: ValidCopy
        switch (valid[.a], valid[.b]) {
        case (nil, nil):
            throw RecoveryJournalError.bothCopiesInvalid
        case (let value?, nil), (nil, let value?):
            winner = value
        case (let a?, let b?):
            if a.record.generation == b.record.generation {
                guard a.raw == b.raw else {
                    throw RecoveryJournalError.equalGenerationDivergence
                }
                winner = a
            } else {
                winner = a.record.generation > b.record.generation ? a : b
            }
        }
        return LoadedState(winner: winner, valid: valid, degraded: degraded)
    }

    func persistLocked(
        _ entries: [RecoveryJournalEntry],
        from state: LoadedState,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) throws -> RecoveryJournalSnapshot {
        let (nextGeneration, overflow) = state.winner.record.generation
            .addingReportingOverflow(1)
        guard !overflow, nextGeneration > 0 else {
            throw RecoveryJournalError.generationExhausted
        }
        let recordData = try RecoveryJournalDiskFormat.encodeRecord(
            fileSetID: fileSetID,
            generation: nextGeneration,
            entries: entries)
        if cancellationCheck() { throw RecoveryJournalError.cancelled }

        let target = targetCopy(for: state)
        guard let targetName = copyNames[target] else {
            throw RecoveryJournalError.incompleteFileSet
        }
        let child = try Self.openExisting(
            targetName.component,
            expectedIdentity: targetName.identity,
            directory: storage.handle,
            accessMode: O_RDWR,
            cancellationCheck: cancellationCheck)
        defer { _ = syscalls.files.close(child.descriptor) }
        try Self.verifyACL(child.descriptor)
        _ = try Self.revalidate(
            descriptor: child.descriptor,
            name: targetName,
            directory: storage.handle,
            cancellationCheck: cancellationCheck)

        // Cancellation is observed before the first mutation. Once truncation
        // begins, complete or surface a concrete failure so a fully written
        // generation is never reported as a mere pre-effect cancellation.
        try Self.rewriteFixedFile(
            descriptor: child.descriptor,
            data: recordData,
            syscalls: syscalls,
            operationCancellationCheck: cancellationCheck)
        _ = try Self.revalidate(
            descriptor: child.descriptor,
            name: targetName,
            directory: storage.handle,
            cancellationCheck: { false })
        let verified = try Self.readFixedFile(
            descriptor: child.descriptor,
            component: targetName.component,
            identity: targetName.identity,
            maximumBytes: RecoveryJournalLimits.maximumEncodedBytes,
            directory: storage.handle,
            syscalls: syscalls,
            cancellationCheck: { false })
        guard verified == recordData else {
            throw RecoveryJournalError.durabilityUncertain(.writeFile, errno: EIO)
        }
        let decoded = try RecoveryJournalDiskFormat.decodeRecord(verified)
        guard decoded.fileSetID == fileSetID,
            decoded.generation == nextGeneration
        else {
            throw RecoveryJournalError.durabilityUncertain(.writeFile, errno: EIO)
        }
        let decodedEntries = try RecoveryJournalPayloadCodec.decode(decoded.payload)
        let valid = ValidCopy(
            copy: target,
            record: decoded,
            entries: decodedEntries,
            raw: verified)
        return RecoveryJournalSnapshot(
            fileSetID: fileSetID,
            generation: nextGeneration,
            entries: valid.entries,
            degradedCopies: [])
    }

    func targetCopy(for state: LoadedState) -> RecoveryJournalCopy {
        if state.degraded.contains(.a) { return .a }
        if state.degraded.contains(.b) { return .b }
        if let a = state.valid[.a], let b = state.valid[.b],
            a.record.generation != b.record.generation
        {
            return a.record.generation < b.record.generation ? .a : .b
        }
        return state.winner.record.generation.isMultiple(of: 2) ? .a : .b
    }
}

private extension Data {
    mutating func appendIdentity(_ value: RecoveryJournalFileIdentityObservation) {
        appendBigEndian(value.device)
        appendBigEndian(value.inode)
        appendBigEndian(value.generation)
        appendBigEndian(UInt64(bitPattern: value.birthSeconds))
        appendBigEndian(UInt64(bitPattern: value.birthNanoseconds))
    }

    mutating func appendBigEndian(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendBigEndian(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    func readUInt32(at offset: Int) -> UInt32? {
        guard offset >= 0, count - offset >= 4 else { return nil }
        return self[offset..<(offset + 4)].reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
    }

    func readUInt64(at offset: Int) -> UInt64? {
        guard offset >= 0, count - offset >= 8 else { return nil }
        return self[offset..<(offset + 8)].reduce(UInt64(0)) {
            ($0 << 8) | UInt64($1)
        }
    }

    func readIdentity(at offset: Int) -> RecoveryJournalFileIdentityObservation? {
        guard let device = readUInt64(at: offset),
            let inode = readUInt64(at: offset + 8),
            let generation = readUInt32(at: offset + 16),
            let birthSeconds = readUInt64(at: offset + 20),
            let birthNanoseconds = readUInt64(at: offset + 28)
        else { return nil }
        return RecoveryJournalFileIdentityObservation(
            device: device,
            inode: inode,
            generation: generation,
            birthSeconds: Int64(bitPattern: birthSeconds),
            birthNanoseconds: Int64(bitPattern: birthNanoseconds))
    }
}

// MARK: - Live transaction integration

struct RecoveryJournalStartupSlot: Equatable, Sendable {
    let entry: RecoveryJournalEntry
    let slot: FileRecoverySlot
}

struct RecoveryJournalStartupSnapshot: Equatable, Sendable {
    let fileSetID: UUID
    let retained: [RecoveryJournalStartupSlot]
    let reconciledEntryCount: Int
}

/// Loads and reconciles journal observations before MainActor registry state is
/// made available. Every capability in the result was freshly reopened and
/// token-checked by SecureLocalFileSystem; decoded bytes alone never populate
/// the process registry.
enum RecoveryJournalStartup {
    static func reconcile(
        journal: RecoveryJournal,
        cancellationCheck: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> RecoveryJournalStartupSnapshot {
        let snapshot = try journal.load(cancellationCheck: cancellationCheck)
        var retained: [RecoveryJournalStartupSlot] = []
        var removals: [RecoveryJournalEntry] = []
        retained.reserveCapacity(snapshot.entries.count)
        var seenKeys = Set<FileDestinationKey>()

        for entry in snapshot.entries {
            if cancellationCheck() { throw RecoveryJournalError.cancelled }
            guard entry.phase != .indeterminate else {
                throw RecoveryJournalError.reconciliationRequired
            }
            let outcome: RecoveryJournalLiveReconciliation
            do {
                outcome = try SecureLocalFileSystem.reconcileRecoveryJournalEntry(
                    entry,
                    cancellationCheck: cancellationCheck)
            } catch SecureLocalFileError.cancelled {
                throw RecoveryJournalError.cancelled
            } catch {
                throw RecoveryJournalError.invalidEntry
            }

            switch outcome {
            case .noRecovery, .published(_, recovery: nil):
                removals.append(entry)
            case .reusable(let slot), .published(_, recovery: .some(let slot)):
                guard slot.authority.destinationKey.matchesObservation(entry.destination),
                    seenKeys.insert(slot.authority.destinationKey).inserted
                else { throw RecoveryJournalError.invalidEntry }
                retained.append(RecoveryJournalStartupSlot(entry: entry, slot: slot))
            case .requiresReview:
                // No entry is discarded or rewritten. A caller must surface
                // the blocked repository and preserve all observed artifacts.
                throw RecoveryJournalError.reconciliationRequired
            }
        }

        // Never partially consume an otherwise review-blocked snapshot. Only
        // after every entry has reconciled unambiguously may settled records be
        // removed by exact revision.
        for entry in removals {
            _ = try journal.remove(
                id: entry.id,
                expectedRevision: entry.revision,
                cancellationCheck: cancellationCheck)
        }

        return RecoveryJournalStartupSnapshot(
            fileSetID: snapshot.fileSetID,
            retained: retained,
            reconciledEntryCount: snapshot.entries.count)
    }
}

enum RecoveryJournalTransactionResolution: Equatable, Sendable {
    case active(RecoveryJournalEntry)
    case cleared
    case reusable(entry: RecoveryJournalEntry, slot: FileRecoverySlot)
    case committed(entry: RecoveryJournalEntry)
    case incident(RecoveryJournalEntry?)
}

enum RecoveryJournalCheckpoint: CaseIterable, Equatable, Sendable {
    case preparing
    case stageCreatedUnobserved
    case stageObserved
    case staged
    case publishing
    case committed
}

/// One journal entry leased to one FileTransaction. All phase changes are
/// synchronous with the corresponding filesystem boundary. The context is
/// lock-backed because the detached commit and its MainActor settlement read
/// it from different executors, although phase mutation itself is serial.
final class RecoveryJournalTransactionContext: @unchecked Sendable {
    let journal: RecoveryJournal
    let entryID: UUID
    let preferredStageComponent: FileComponent

    private let lock = NSLock()
    private let destination: RecoveryJournalDestinationObservation
    private let expectation: RecoveryJournalDestinationExpectation
    private let initialReusableStage: FileRecoverySlot?
    private let checkpointDidPersist: (@Sendable (RecoveryJournalCheckpoint) -> RecoveryJournalError?)?
    private var currentEntryStorage: RecoveryJournalEntry?
    private var didPrepare = false
    private var interruptedAfterDurableCheckpoint = false
    private var resolutionStorage: RecoveryJournalTransactionResolution

    init(
        journal: RecoveryJournal,
        previousEntry: RecoveryJournalEntry?,
        destinationURL: URL,
        destinationKey: FileDestinationKey,
        expectation: FileTransactionExpectation,
        reusableStage: FileRecoverySlot?,
        checkpointDidPersist: (@Sendable (RecoveryJournalCheckpoint) -> RecoveryJournalError?)? = nil
    ) throws {
        if let previousEntry {
            guard previousEntry.destination.matches(destinationKey) else {
                throw RecoveryJournalError.invalidEntry
            }
        }
        if let reusableStage {
            guard reusableStage.authority.destinationKey == destinationKey else {
                throw RecoveryJournalError.invalidEntry
            }
            preferredStageComponent = reusableStage.authority.component
        } else {
            preferredStageComponent = try FileComponent(
                ".markdev-stage-\(UUID().uuidString.lowercased())")
        }
        self.journal = journal
        entryID = previousEntry?.id ?? UUID()
        destination = try RecoveryJournalDestinationObservation(
            presentationURL: destinationURL,
            destinationKey: destinationKey)
        self.expectation = RecoveryJournalDestinationExpectation(expectation)
        initialReusableStage = reusableStage
        self.checkpointDidPersist = checkpointDidPersist
        currentEntryStorage = previousEntry
        if let previousEntry, let reusableStage {
            resolutionStorage = .reusable(entry: previousEntry, slot: reusableStage)
        } else if let previousEntry {
            resolutionStorage = .active(previousEntry)
        } else {
            resolutionStorage = .cleared
        }
    }

    var currentEntry: RecoveryJournalEntry? {
        lock.lock()
        defer { lock.unlock() }
        return currentEntryStorage
    }

    var resolution: RecoveryJournalTransactionResolution {
        lock.lock()
        defer { lock.unlock() }
        return resolutionStorage
    }

    func record(_ event: FileTransactionLifecycleEvent) throws {
        lock.lock()
        defer { lock.unlock() }

        switch event {
        case .preparing:
            guard !didPrepare else { throw RecoveryJournalError.invalidEntry }
            let entry = try makeNextEntry(
                phase: .preparing,
                stage: initialReusableStage.map(RecoveryJournalStageObservation.init),
                committedVersion: nil)
            try persist(entry)
            didPrepare = true
            resolutionStorage = .active(entry)
            try finishCheckpoint(.preparing)

        case .stageCreatedUnobserved(let component):
            guard didPrepare,
                initialReusableStage == nil,
                component == preferredStageComponent
            else {
                throw RecoveryJournalError.invalidEntry
            }
            // The preparing record already carries this planned component.
            // Do not persist or infer an inode token at this boundary.
            try finishCheckpoint(.stageCreatedUnobserved)

        case .stageObserved(let slot):
            try requirePrepared(slot: slot)
            let entry = try makeNextEntry(
                phase: .preparing,
                stage: RecoveryJournalStageObservation(slot),
                committedVersion: nil)
            try persist(entry)
            resolutionStorage = .active(entry)
            try finishCheckpoint(.stageObserved)

        case .staged(let slot):
            try requirePrepared(slot: slot)
            guard slot.contents == .unpublishedScratch else {
                throw RecoveryJournalError.invalidEntry
            }
            let entry = try makeNextEntry(
                phase: .staged,
                stage: RecoveryJournalStageObservation(slot),
                committedVersion: nil)
            try persist(entry)
            resolutionStorage = .active(entry)
            try finishCheckpoint(.staged)

        case .publishing(let slot):
            try requirePrepared(slot: slot)
            guard slot.contents == .unpublishedScratch else {
                throw RecoveryJournalError.invalidEntry
            }
            let entry = try makeNextEntry(
                phase: .publishing,
                stage: RecoveryJournalStageObservation(slot),
                committedVersion: nil)
            try persist(entry)
            resolutionStorage = .active(entry)
            try finishCheckpoint(.publishing)

        case .committed(let receipt):
            guard didPrepare,
                let version = receipt.version,
                receipt.destinationKey.map(destination.matches) == true,
                Self.isValidCommittedReceipt(receipt, expectation: expectation)
            else { throw RecoveryJournalError.invalidEntry }
            if let slot = receipt.recoverySlot {
                try requireScoped(slot)
                guard slot.contents == .previousDestination else {
                    throw RecoveryJournalError.invalidEntry
                }
            }
            let entry = try makeNextEntry(
                phase: .committed,
                stage: receipt.recoverySlot.map(RecoveryJournalStageObservation.init),
                committedVersion: RecoveryJournalFileVersionObservation(version))
            try persist(entry)
            resolutionStorage = .committed(entry: entry)
            try finishCheckpoint(.committed)
        }
    }

    /// Normalizes an interrupted transaction using the exact receipt produced
    /// by FileTransaction. Known no-effect outcomes either retain a fully
    /// revalidated scratch token or remove an absent planned name. Ambiguous
    /// topology remains durably incident-bound.
    func recordFailure(_ error: Error) throws {
        lock.lock()
        defer { lock.unlock() }
        guard didPrepare, let current = currentEntryStorage else { return }
        if interruptedAfterDurableCheckpoint {
            // This test-only boundary models process death immediately after
            // one durable checkpoint. Do not let ordinary unwind handling
            // write a later phase that the crashed process could not have
            // produced.
            resolutionStorage = .incident(current)
            return
        }

        if let secure = error as? SecureLocalFileError {
            if Self.containsRecoveryJournalFailure(secure) {
                // Retrying a checkpoint after any write/fsync uncertainty can
                // overwrite the only trustworthy copy. Preserve the last
                // confirmed phase and force registry review.
                resolutionStorage = .incident(current)
                return
            }
            switch secure {
            case .prepublicationFailure(let cause, let receipt)
                where receipt.isValidPrepublicationFailure
                    && Self.isKnownNotPublished(cause):
                guard receipt.destinationKey.map(destination.matches) == true else {
                    try retainIncident(from: receipt, current: current)
                    return
                }
                if let slot = receipt.recoverySlot {
                    try requireScoped(slot)
                    let entry = try makeNextEntry(
                        phase: .preparing,
                        stage: RecoveryJournalStageObservation(slot),
                        committedVersion: nil)
                    try persist(entry)
                    resolutionStorage = .reusable(entry: entry, slot: slot)
                } else {
                    try reconcileKnownNoEffect(current)
                }
                return
            case .indeterminate(let receipt):
                try retainIncident(from: receipt, current: current)
                return
            case .recoveryJournal:
                // The last successfully persisted phase remains authoritative;
                // do not risk a second write after a durability uncertainty.
                resolutionStorage = .incident(current)
                return
            default:
                if Self.isKnownNotPublished(secure) {
                    try reconcileKnownNoEffect(current)
                } else {
                    try retainIncident(from: nil, current: current)
                }
                return
            }
        }
        try retainIncident(from: nil, current: current)
    }

    func finalizeCommitted(_ receipt: FileTransactionReceipt) throws {
        lock.lock()
        defer { lock.unlock() }
        guard case .committed(let entry) = resolutionStorage else {
            throw RecoveryJournalError.invalidEntry
        }
        guard receipt.recoverySlot == nil else { return }
        _ = try journal.remove(
            id: entry.id,
            expectedRevision: entry.revision,
            cancellationCheck: { false })
        currentEntryStorage = nil
        resolutionStorage = .cleared
    }

    private func requirePrepared(slot: FileRecoverySlot) throws {
        guard didPrepare else { throw RecoveryJournalError.invalidEntry }
        try requireScoped(slot)
    }

    private func requireScoped(_ slot: FileRecoverySlot) throws {
        guard slot.authority.component == preferredStageComponent,
            destination.matches(slot.authority.destinationKey)
        else { throw RecoveryJournalError.invalidEntry }
    }

    private func makeNextEntry(
        phase: RecoveryJournalTransactionPhase,
        stage: RecoveryJournalStageObservation?,
        committedVersion: RecoveryJournalFileVersionObservation?
    ) throws -> RecoveryJournalEntry {
        let revision: UInt64
        if let currentEntryStorage {
            let (next, overflow) = currentEntryStorage.revision.addingReportingOverflow(1)
            guard !overflow else { throw RecoveryJournalError.revisionExhausted }
            revision = next
        } else {
            revision = 1
        }
        return RecoveryJournalEntry(
            id: entryID,
            revision: revision,
            phase: phase,
            destination: destination,
            expectation: expectation,
            stage: stage,
            committedDestinationVersion: committedVersion,
            plannedStageComponent: preferredStageComponent.rawValue)
    }

    private func persist(_ entry: RecoveryJournalEntry) throws {
        _ = try journal.upsert(entry, cancellationCheck: { false })
        currentEntryStorage = entry
    }

    private func finishCheckpoint(_ checkpoint: RecoveryJournalCheckpoint) throws {
        if let error = checkpointDidPersist?(checkpoint) {
            interruptedAfterDurableCheckpoint = true
            throw error
        }
    }

    private func reconcileKnownNoEffect(_ current: RecoveryJournalEntry) throws {
        let outcome: RecoveryJournalLiveReconciliation
        do {
            outcome = try SecureLocalFileSystem.reconcileRecoveryJournalEntry(
                current,
                cancellationCheck: { false })
        } catch {
            try retainIncident(from: nil, current: current)
            return
        }
        switch outcome {
        case .noRecovery:
            _ = try journal.remove(
                id: current.id,
                expectedRevision: current.revision,
                cancellationCheck: { false })
            currentEntryStorage = nil
            resolutionStorage = .cleared
        case .reusable(let slot):
            try requireScoped(slot)
            let entry = try makeNextEntry(
                phase: .preparing,
                stage: RecoveryJournalStageObservation(slot),
                committedVersion: nil)
            try persist(entry)
            resolutionStorage = .reusable(entry: entry, slot: slot)
        case .published, .requiresReview:
            try retainIncident(from: nil, current: current)
        }
    }

    private func retainIncident(
        from receipt: FileTransactionReceipt?,
        current: RecoveryJournalEntry
    ) throws {
        let slot = receipt?.recoverySlot
        if let slot { try requireScoped(slot) }
        let entry: RecoveryJournalEntry
        if current.phase == .indeterminate,
            slot == nil,
            receipt?.version == nil
        {
            entry = current
        } else {
            entry = try makeNextEntry(
                phase: .indeterminate,
                stage: slot.map(RecoveryJournalStageObservation.init) ?? current.stage,
                committedVersion: receipt?.version.map(
                    RecoveryJournalFileVersionObservation.init))
            try persist(entry)
        }
        resolutionStorage = .incident(entry)
    }

    private static func isKnownNotPublished(_ error: SecureLocalFileError) -> Bool {
        switch error {
        case .invalidComponent, .unsupportedEntry, .fileTooLarge,
            .hardLinkedEntry, .unsupportedFileMode, .unsupportedFileFlags,
            .expectationMismatch, .operation, .cancelled:
            true
        case .prepublicationFailure(let cause, let receipt):
            receipt.isValidPrepublicationFailure && isKnownNotPublished(cause)
        case .recoverySlotUnavailable, .recoveryJournal, .indeterminate:
            false
        }
    }

    private static func containsRecoveryJournalFailure(
        _ error: SecureLocalFileError
    ) -> Bool {
        switch error {
        case .recoveryJournal:
            return true
        case .prepublicationFailure(let cause, _),
            .recoverySlotUnavailable(let cause):
            return containsRecoveryJournalFailure(cause)
        case .invalidComponent, .unsupportedEntry, .fileTooLarge,
            .hardLinkedEntry, .unsupportedFileMode, .unsupportedFileFlags,
            .expectationMismatch, .operation, .cancelled, .indeterminate:
            return false
        }
    }

    private static func isValidCommittedReceipt(
        _ receipt: FileTransactionReceipt,
        expectation: RecoveryJournalDestinationExpectation
    ) -> Bool {
        guard receipt.version != nil else { return false }
        switch (expectation, receipt.durability) {
        case (.missing, .fullySynced),
            (.missing, .committedDirectorySyncUnconfirmed):
            return receipt.recoverySlot == nil
        case (.exact, .fullySynced),
            (.exact, .committedDirectorySyncUnconfirmed):
            return receipt.recoverySlot == nil
        case (.exact(let expected), .recoveryRetained):
            return receipt.recoverySlot?.contents == .previousDestination
                && receipt.recoverySlot.map {
                    expected.matchesAcrossRename($0.authority.version)
                } == true
        case (.missing, .recoveryRetained),
            (_, .notPublishedRecoveryRetained),
            (_, .notPublishedRecoveryUnconfirmed),
            (_, .indeterminate):
            return false
        }
    }
}

private extension FileDestinationKey {
    func matchesObservation(_ observation: RecoveryJournalDestinationObservation) -> Bool {
        observation.matches(self)
    }
}
