//
//  DiagnosticsModels.swift
//  MarkDevKit
//
//  Privacy-preserving value types shared by every diagnostics producer and sink.
//

import Foundation

public enum DiagnosticSeverity: String, Codable, CaseIterable, Sendable {
    case debug
    case info
    case notice
    case warning
    case error
    case critical
}

public enum DiagnosticSubsystem: String, Codable, CaseIterable, Sendable {
    case app
    case workspace
    case filesystem
    case vault
    case editor
    case renderer
    case intelligence
    case harness
    case terminal
    case permissions
    case diagnostics
}

public struct DiagnosticCode: Codable, Hashable, Sendable {
    public let rawValue: String

    public static let invalid = Self(knownRawValue: "diagnostics.invalid-code")
    public static let appLaunchABIVerified = Self(knownRawValue: "app.launch.abi-verified")
    public static let workspaceSaveSucceeded = Self(knownRawValue: "workspace.save.succeeded")
    public static let workspaceSaveFailed = Self(knownRawValue: "workspace.save.failed")
    public static let workspaceAutosaveConflict = Self(knownRawValue: "workspace.autosave.conflict")
    public static let workspaceAutosaveFailed = Self(knownRawValue: "workspace.autosave.failed")
    public static let workspaceSessionSaveRejected = Self(
        knownRawValue: "workspace.session-save.rejected")
    public static let workspaceSessionRestoreRejected = Self(
        knownRawValue: "workspace.session-restore.rejected")
    public static let vaultReconciliationIncomplete = Self(
        knownRawValue: "vault.reconciliation.incomplete")
    public static let harnessTerminalSucceeded = Self(knownRawValue: "harness.terminal.succeeded")
    public static let harnessTerminalFailed = Self(knownRawValue: "harness.terminal.failed")
    public static let harnessTerminalCancelled = Self(knownRawValue: "harness.terminal.cancelled")
    public static let harnessTerminalTimedOut = Self(knownRawValue: "harness.terminal.timed-out")
    public static let harnessTerminalInputTooLarge = Self(
        knownRawValue: "harness.terminal.input-too-large")
    public static let harnessTerminalInputRejected = Self(
        knownRawValue: "harness.terminal.input-rejected")
    /// The editor refused a document outright and is showing nothing.
    ///
    /// The `editor` subsystem had no codes at all, which left the one failure
    /// a reader cannot miss — a note that opens blank — as the one failure
    /// nothing recorded.
    public static let editorDocumentRejected = Self(knownRawValue: "editor.document.rejected")
    /// The reader's authorization of the MANVI executable was withdrawn,
    /// because the bytes behind the path they approved are no longer the bytes
    /// they approved.
    ///
    /// The check that catches this is the app's one real privilege boundary —
    /// it stands between a note and an arbitrary local binary — and until now
    /// it fired silently. A revocation is exactly what a support export needs
    /// to explain why a harness that worked yesterday refuses to run today.
    public static let permissionsHarnessExecutableRevoked = Self(
        knownRawValue: "permissions.harness-executable.revoked")
    /// An edit was refused because it would push the document past the
    /// parser's byte limit. The reader's typing or paste does not survive it.
    public static let workspaceEditRefused = Self(knownRawValue: "workspace.edit.refused")
    public static let workspaceOpenFailed = Self(knownRawValue: "workspace.open.failed")
    public static let workspaceVaultOpenFailed = Self(
        knownRawValue: "workspace.vault-open.failed")
    public static let workspaceCreateFailed = Self(knownRawValue: "workspace.create.failed")
    public static let workspaceRenameFailed = Self(knownRawValue: "workspace.rename.failed")
    public static let workspaceExternalReadFailed = Self(
        knownRawValue: "workspace.external-read.failed")
    public static let workspaceIOBatchIncomplete = Self(
        knownRawValue: "workspace.io-batch.incomplete")

    private static let allowedRawValues: Set<String> = [
        "diagnostics.invalid-code",
        "app.launch.abi-verified",
        "workspace.save.succeeded",
        "workspace.save.failed",
        "workspace.autosave.conflict",
        "workspace.autosave.failed",
        "workspace.session-save.rejected",
        "workspace.session-restore.rejected",
        "vault.reconciliation.incomplete",
        "harness.terminal.succeeded",
        "harness.terminal.failed",
        "harness.terminal.cancelled",
        "harness.terminal.timed-out",
        "harness.terminal.input-too-large",
        "harness.terminal.input-rejected",
        "editor.document.rejected",
        "permissions.harness-executable.revoked",
        "workspace.edit.refused",
        "workspace.open.failed",
        "workspace.vault-open.failed",
        "workspace.create.failed",
        "workspace.rename.failed",
        "workspace.external-read.failed",
        "workspace.io-batch.incomplete",
    ]

    private init(knownRawValue: String) {
        rawValue = knownRawValue
    }

    private init(sanitizing value: String) {
        guard value.utf8.count <= 96 else {
            rawValue = "diagnostics.invalid-code"
            return
        }
        let normalized = value.lowercased()
        rawValue = Self.allowedRawValues.contains(normalized)
            ? normalized
            : "diagnostics.invalid-code"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(sanitizing: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct DiagnosticOperationID: Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let identifier = UUID(uuidString: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid diagnostic operation identifier")
        }
        rawValue = identifier
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue.uuidString.lowercased())
    }
}

public enum DiagnosticMetadataKey: String, Codable, CaseIterable, Sendable {
    case attemptedCount = "attempted_count"
    case succeededCount = "succeeded_count"
    case failedCount = "failed_count"
    case conflictCount = "conflict_count"
    case changedCount = "changed_count"
    case discoveredFileCount = "discovered_file_count"
    case visitedEntryCount = "visited_entry_count"
    case skippedSymlinkCount = "skipped_symlink_count"
    case unreadableDirectoryCount = "unreadable_directory_count"
    case unreadableEntryCount = "unreadable_entry_count"
    case unreadableFileCount = "unreadable_file_count"
    case oversizedFileCount = "oversized_file_count"
    case droppedCount = "dropped_count"
    case retainedCount = "retained_count"
    case byteCount = "byte_count"
    case durationMilliseconds = "duration_milliseconds"
    case retryCount = "retry_count"
    case exitStatus = "exit_status"
    case signal
    case truncated
    case available
    case hitDepthLimit = "hit_depth_limit"
    case hitEntryLimit = "hit_entry_limit"
    case fileType = "file_type"
    case endpoint
}

public struct DiagnosticMetadataValue: Equatable, Sendable {
    fileprivate enum ValueKind {
        case integer
        case boolean
        case durationMilliseconds
        case fileExtension
        case urlOrigin
    }

    private enum Storage: Equatable, Sendable {
        case integer(Int64)
        case boolean(Bool)
        case durationMilliseconds(UInt64)
        case fileExtension(String)
        case urlOrigin(String)
    }

    private let storage: Storage

    public static func integer(_ value: Int64) -> Self {
        Self(storage: .integer(value))
    }

    public static func boolean(_ value: Bool) -> Self {
        Self(storage: .boolean(value))
    }

    public static func durationMilliseconds(_ value: UInt64) -> Self {
        Self(storage: .durationMilliseconds(value))
    }

    public static func file(_ url: URL) -> Self {
        Self(storage: .fileExtension(DiagnosticsSanitizer.fileExtension(url.pathExtension)))
    }

    public static func url(_ url: URL) -> Self {
        Self(storage: .urlOrigin(DiagnosticsSanitizer.urlOrigin(url)))
    }

    fileprivate var kind: ValueKind {
        switch storage {
        case .integer:
            .integer
        case .boolean:
            .boolean
        case .durationMilliseconds:
            .durationMilliseconds
        case .fileExtension:
            .fileExtension
        case .urlOrigin:
            .urlOrigin
        }
    }
}

extension DiagnosticMetadataValue: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    private enum Kind: String, Codable {
        case integer
        case boolean
        case durationMilliseconds = "duration_milliseconds"
        case fileExtension = "file_extension"
        case urlOrigin = "url_origin"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .integer:
            self = Self(storage: .integer(try container.decode(Int64.self, forKey: .value)))
        case .boolean:
            self = Self(storage: .boolean(try container.decode(Bool.self, forKey: .value)))
        case .durationMilliseconds:
            self = Self(storage: .durationMilliseconds(
                try container.decode(UInt64.self, forKey: .value)))
        case .fileExtension:
            self = Self(storage: .fileExtension(DiagnosticsSanitizer.fileExtension(
                try container.decode(String.self, forKey: .value))))
        case .urlOrigin:
            let value = try container.decode(String.self, forKey: .value)
            guard value.utf8.count <= 2_048, let url = URL(string: value) else {
                self = Self(storage: .urlOrigin("invalid"))
                return
            }
            self = Self(storage: .urlOrigin(DiagnosticsSanitizer.urlOrigin(url)))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch storage {
        case let .integer(value):
            try container.encode(Kind.integer, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .boolean(value):
            try container.encode(Kind.boolean, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .durationMilliseconds(value):
            try container.encode(Kind.durationMilliseconds, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .fileExtension(value):
            try container.encode(Kind.fileExtension, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .urlOrigin(value):
            try container.encode(Kind.urlOrigin, forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }
}

public struct DiagnosticMetadata: Codable, Equatable, Sendable {
    private var storage: [DiagnosticMetadataKey: DiagnosticMetadataValue]

    public init(_ values: [DiagnosticMetadataKey: DiagnosticMetadataValue] = [:]) {
        storage = values.filter { key, value in key.accepts(value) }
    }

    public subscript(key: DiagnosticMetadataKey) -> DiagnosticMetadataValue? {
        storage[key]
    }

    private struct MetadataCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: MetadataCodingKey.self)
        var values: [DiagnosticMetadataKey: DiagnosticMetadataValue] = [:]
        for key in container.allKeys {
            guard let metadataKey = DiagnosticMetadataKey(rawValue: key.stringValue) else {
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: container,
                    debugDescription: "Unknown diagnostic metadata key")
            }
            let value = try container.decode(DiagnosticMetadataValue.self, forKey: key)
            guard metadataKey.accepts(value) else {
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: container,
                    debugDescription: "Diagnostic metadata value has the wrong type for its key")
            }
            values[metadataKey] = value
        }
        storage = values
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: MetadataCodingKey.self)
        for (key, value) in storage {
            guard let codingKey = MetadataCodingKey(stringValue: key.rawValue) else {
                continue
            }
            try container.encode(value, forKey: codingKey)
        }
    }
}

private extension DiagnosticMetadataKey {
    func accepts(_ value: DiagnosticMetadataValue) -> Bool {
        switch self {
        case .attemptedCount, .succeededCount, .failedCount, .conflictCount,
             .changedCount, .discoveredFileCount, .visitedEntryCount,
             .skippedSymlinkCount, .unreadableDirectoryCount, .unreadableEntryCount,
             .unreadableFileCount, .oversizedFileCount, .droppedCount, .retainedCount,
             .byteCount, .retryCount, .exitStatus, .signal:
            value.kind == .integer
        case .durationMilliseconds:
            value.kind == .durationMilliseconds
        case .truncated, .available, .hitDepthLimit, .hitEntryLimit:
            value.kind == .boolean
        case .fileType:
            value.kind == .fileExtension
        case .endpoint:
            value.kind == .urlOrigin
        }
    }
}

public enum DiagnosticProcessRole: String, Codable, CaseIterable, Sendable {
    case app
    case quickLookExtension
    case testHost
    case unknown
}

public enum DiagnosticLocality: String, Codable, CaseIterable, Sendable {
    case productionUser
    case ephemeralTest
    case unknown
}

public struct DiagnosticOrigin: Codable, Equatable, Hashable, Sendable {
    public let runID: UUID
    public let processID: Int32
    public let role: DiagnosticProcessRole
    public let locality: DiagnosticLocality

    public init?(
        runID: UUID,
        processID: Int32,
        role: DiagnosticProcessRole,
        locality: DiagnosticLocality
    ) {
        guard Self.isValid(processID: processID, role: role, locality: locality) else {
            return nil
        }
        self.runID = runID
        self.processID = processID
        self.role = role
        self.locality = locality
    }

    init(
        validatedRunID runID: UUID,
        processID: Int32,
        role: DiagnosticProcessRole,
        locality: DiagnosticLocality
    ) {
        precondition(Self.isValid(processID: processID, role: role, locality: locality))
        self.runID = runID
        self.processID = processID
        self.role = role
        self.locality = locality
    }

    var canPersistToScopedStore: Bool {
        switch (role, locality) {
        case (.app, .productionUser),
             (.quickLookExtension, .productionUser),
             (.testHost, .ephemeralTest):
            return true
        case (.unknown, .unknown):
            return false
        default:
            return false
        }
    }

    var isTrustedProduction: Bool {
        locality == .productionUser
            && (role == .app || role == .quickLookExtension)
    }

    private enum CodingKeys: String, CodingKey {
        case runID
        case processID
        case role
        case locality
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let runIDString = try container.decode(String.self, forKey: .runID)
        guard let runID = UUID(uuidString: runIDString) else {
            throw DecodingError.dataCorruptedError(
                forKey: .runID,
                in: container,
                debugDescription: "Invalid diagnostics run identifier")
        }
        let processID = try container.decode(Int32.self, forKey: .processID)
        let role = try container.decode(DiagnosticProcessRole.self, forKey: .role)
        let locality = try container.decode(DiagnosticLocality.self, forKey: .locality)
        guard let origin = Self(
            runID: runID,
            processID: processID,
            role: role,
            locality: locality)
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .locality,
                in: container,
                debugDescription: "Diagnostics origin role and locality are inconsistent")
        }
        self = origin
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(runID.uuidString.lowercased(), forKey: .runID)
        try container.encode(processID, forKey: .processID)
        try container.encode(role, forKey: .role)
        try container.encode(locality, forKey: .locality)
    }

    private static func isValid(
        processID: Int32,
        role: DiagnosticProcessRole,
        locality: DiagnosticLocality
    ) -> Bool {
        switch (role, locality) {
        case (.app, .productionUser),
             (.quickLookExtension, .productionUser),
             (.testHost, .ephemeralTest):
            return processID > 0
        case (.unknown, .unknown):
            return processID >= 0
        default:
            return false
        }
    }
}

public struct DiagnosticEventID: Codable, Equatable, Hashable, Sendable {
    public let runID: UUID
    public let processID: Int32
    public let localSequence: UInt64

    public init?(
        runID: UUID,
        processID: Int32,
        localSequence: UInt64
    ) {
        guard processID >= 0, localSequence > 0 else { return nil }
        self.runID = runID
        self.processID = processID
        self.localSequence = localSequence
    }

    init(origin: DiagnosticOrigin, localSequence: UInt64) {
        precondition(localSequence > 0)
        runID = origin.runID
        processID = origin.processID
        self.localSequence = localSequence
    }

    private enum CodingKeys: String, CodingKey {
        case runID
        case processID
        case localSequence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let runIDString = try container.decode(String.self, forKey: .runID)
        guard let runID = UUID(uuidString: runIDString) else {
            throw DecodingError.dataCorruptedError(
                forKey: .runID,
                in: container,
                debugDescription: "Invalid diagnostics run identifier")
        }
        let processID = try container.decode(Int32.self, forKey: .processID)
        let localSequence = try container.decode(UInt64.self, forKey: .localSequence)
        guard let identifier = Self(
            runID: runID,
            processID: processID,
            localSequence: localSequence)
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .localSequence,
                in: container,
                debugDescription: "Diagnostic event identity is invalid")
        }
        self = identifier
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(runID.uuidString.lowercased(), forKey: .runID)
        try container.encode(processID, forKey: .processID)
        try container.encode(localSequence, forKey: .localSequence)
    }
}

public struct DiagnosticEvent: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let origin: DiagnosticOrigin
    public let localSequence: UInt64
    public let timestampMilliseconds: Int64
    public let uptimeNanoseconds: UInt64
    public let severity: DiagnosticSeverity
    public let subsystem: DiagnosticSubsystem
    public let code: DiagnosticCode
    public let operationID: DiagnosticOperationID?
    public let metadata: DiagnosticMetadata

    public var id: DiagnosticEventID {
        DiagnosticEventID(origin: origin, localSequence: localSequence)
    }

    /// Source compatibility for readers that predate scoped event identity.
    /// Persisted schema-v2 bytes use `localSequence`; the value is not globally
    /// unique without `origin`.
    public var sequence: UInt64 { localSequence }

    init(
        origin: DiagnosticOrigin,
        localSequence: UInt64,
        timestampMilliseconds: Int64,
        uptimeNanoseconds: UInt64,
        severity: DiagnosticSeverity,
        subsystem: DiagnosticSubsystem,
        code: DiagnosticCode,
        operationID: DiagnosticOperationID?,
        metadata: DiagnosticMetadata
    ) {
        precondition(localSequence > 0)
        schemaVersion = Self.currentSchemaVersion
        self.origin = origin
        self.localSequence = localSequence
        self.timestampMilliseconds = timestampMilliseconds
        self.uptimeNanoseconds = uptimeNanoseconds
        self.severity = severity
        self.subsystem = subsystem
        self.code = code
        self.operationID = operationID
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case origin
        case localSequence
        case timestampMilliseconds
        case uptimeNanoseconds
        case severity
        case subsystem
        case code
        case operationID
        case metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported diagnostic event schema")
        }
        let localSequence = try container.decode(UInt64.self, forKey: .localSequence)
        guard localSequence > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .localSequence,
                in: container,
                debugDescription: "Diagnostic local sequence must be positive")
        }
        self.init(
            origin: try container.decode(DiagnosticOrigin.self, forKey: .origin),
            localSequence: localSequence,
            timestampMilliseconds: try container.decode(
                Int64.self, forKey: .timestampMilliseconds),
            uptimeNanoseconds: try container.decode(UInt64.self, forKey: .uptimeNanoseconds),
            severity: try container.decode(DiagnosticSeverity.self, forKey: .severity),
            subsystem: try container.decode(DiagnosticSubsystem.self, forKey: .subsystem),
            code: try container.decode(DiagnosticCode.self, forKey: .code),
            operationID: try container.decodeIfPresent(
                DiagnosticOperationID.self, forKey: .operationID),
            metadata: try container.decode(DiagnosticMetadata.self, forKey: .metadata))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(origin, forKey: .origin)
        try container.encode(localSequence, forKey: .localSequence)
        try container.encode(timestampMilliseconds, forKey: .timestampMilliseconds)
        try container.encode(uptimeNanoseconds, forKey: .uptimeNanoseconds)
        try container.encode(severity, forKey: .severity)
        try container.encode(subsystem, forKey: .subsystem)
        try container.encode(code, forKey: .code)
        try container.encodeIfPresent(operationID, forKey: .operationID)
        try container.encode(metadata, forKey: .metadata)
    }
}

public struct DiagnosticRecord: Equatable, Sendable {
    public let event: DiagnosticEvent
    public let jsonLine: Data

    init(event: DiagnosticEvent, jsonLine: Data) {
        self.event = event
        self.jsonLine = jsonLine
    }
}

public protocol DiagnosticClock: Sendable {
    func millisecondsSince1970() -> Int64
    func uptimeNanoseconds() -> UInt64
}

public struct SystemDiagnosticClock: DiagnosticClock {
    public init() {}

    public func millisecondsSince1970() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
    }

    public func uptimeNanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }
}

public protocol DiagnosticSink: Sendable {
    func write(_ record: DiagnosticRecord) async throws
}

public struct DiagnosticSinkID: Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public static let osLog = Self(knownRawValue: "os-log")
    public static let rotatingJSONL = Self(knownRawValue: "rotating-jsonl")

    public init?(_ rawValue: String) {
        let normalized = rawValue.lowercased()
        guard Self.isValid(normalized) else { return nil }
        self.rawValue = normalized
    }

    init(knownRawValue: String) {
        precondition(Self.isValid(knownRawValue))
        rawValue = knownRawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let identifier = Self(rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid diagnostic sink identifier")
        }
        self = identifier
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func isValid(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 48
            && value.utf8.allSatisfy { byte in
                (0x30...0x39).contains(byte)
                    || (0x61...0x7A).contains(byte)
                    || byte == 0x2D
                    || byte == 0x5F
            }
    }
}

public struct DiagnosticSinkRegistration: Sendable {
    public let id: DiagnosticSinkID
    public let sink: any DiagnosticSink
    public let maximumOutstandingRecords: Int

    public init(
        id: DiagnosticSinkID,
        sink: any DiagnosticSink,
        maximumOutstandingRecords: Int = 256
    ) {
        self.id = id
        self.sink = sink
        self.maximumOutstandingRecords = min(
            max(0, maximumOutstandingRecords),
            DiagnosticsConfiguration.largestSupportedPendingRecordLimitPerSink)
    }
}

public struct DiagnosticSinkHealth: Codable, Equatable, Sendable {
    public let id: DiagnosticSinkID
    public let offeredEventCount: UInt64
    public let acceptedEventCount: UInt64
    public let writtenEventCount: UInt64
    public let failureCount: UInt64
    public let droppedEventCount: UInt64
    public let outstandingEventCount: Int
    public let maximumOutstandingEventCount: Int
    public let countersSaturated: Bool

    init(
        id: DiagnosticSinkID,
        offeredEventCount: UInt64,
        acceptedEventCount: UInt64,
        writtenEventCount: UInt64,
        failureCount: UInt64,
        droppedEventCount: UInt64,
        outstandingEventCount: Int,
        maximumOutstandingEventCount: Int,
        countersSaturated: Bool
    ) {
        precondition(outstandingEventCount >= 0)
        precondition(maximumOutstandingEventCount >= outstandingEventCount)
        precondition(acceptedEventCount >= writtenEventCount)
        precondition(acceptedEventCount - writtenEventCount >= failureCount)
        if !countersSaturated {
            let (accountedOffers, offerOverflow) = acceptedEventCount
                .addingReportingOverflow(droppedEventCount)
            let (completed, completionOverflow) = writtenEventCount
                .addingReportingOverflow(failureCount)
            precondition(!offerOverflow && !completionOverflow)
            precondition(offeredEventCount == accountedOffers)
            precondition(UInt64(outstandingEventCount) == acceptedEventCount - completed)
        }
        self.id = id
        self.offeredEventCount = offeredEventCount
        self.acceptedEventCount = acceptedEventCount
        self.writtenEventCount = writtenEventCount
        self.failureCount = failureCount
        self.droppedEventCount = droppedEventCount
        self.outstandingEventCount = outstandingEventCount
        self.maximumOutstandingEventCount = maximumOutstandingEventCount
        self.countersSaturated = countersSaturated
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case offeredEventCount
        case acceptedEventCount
        case writtenEventCount
        case failureCount
        case droppedEventCount
        case outstandingEventCount
        case maximumOutstandingEventCount
        case countersSaturated
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(DiagnosticSinkID.self, forKey: .id)
        let offered = try container.decode(UInt64.self, forKey: .offeredEventCount)
        let accepted = try container.decode(UInt64.self, forKey: .acceptedEventCount)
        let written = try container.decode(UInt64.self, forKey: .writtenEventCount)
        let failures = try container.decode(UInt64.self, forKey: .failureCount)
        let dropped = try container.decode(UInt64.self, forKey: .droppedEventCount)
        let outstanding = try container.decode(Int.self, forKey: .outstandingEventCount)
        let maximumOutstanding = try container.decode(
            Int.self, forKey: .maximumOutstandingEventCount)
        let saturated = try container.decode(Bool.self, forKey: .countersSaturated)

        guard outstanding >= 0,
              maximumOutstanding >= outstanding,
              accepted >= written,
              accepted - written >= failures
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .outstandingEventCount,
                in: container,
                debugDescription: "Diagnostic sink health counters are inconsistent")
        }
        if !saturated {
            let (accountedOffers, offerOverflow) = accepted.addingReportingOverflow(dropped)
            let (completed, completionOverflow) = written.addingReportingOverflow(failures)
            guard !offerOverflow,
                  !completionOverflow,
                  offered == accountedOffers,
                  completed <= accepted,
                  UInt64(outstanding) == accepted - completed
            else {
                throw DecodingError.dataCorruptedError(
                    forKey: .countersSaturated,
                    in: container,
                    debugDescription: "Diagnostic sink health counters are inconsistent")
            }
        }
        self.init(
            id: id,
            offeredEventCount: offered,
            acceptedEventCount: accepted,
            writtenEventCount: written,
            failureCount: failures,
            droppedEventCount: dropped,
            outstandingEventCount: outstanding,
            maximumOutstandingEventCount: maximumOutstanding,
            countersSaturated: saturated)
    }
}

public struct DiagnosticsConfiguration: Codable, Equatable, Sendable {
    public static let largestSupportedMemoryEventLimit = 100_000
    public static let largestSupportedMemoryByteLimit = 64 * 1_024 * 1_024
    public static let largestSupportedReportByteLimit = 64 * 1_024 * 1_024
    public static let largestSupportedSinkCount = 16
    public static let largestSupportedPendingRecordLimitPerSink = 100_000
    public static let largestSupportedSinkBarrierWaiterLimit = 1_024

    public let memoryEventLimit: Int
    public let memoryByteLimit: Int
    public let supportReportByteLimit: Int
    public let maximumSinkCount: Int
    public let maximumPendingRecordsPerSink: Int
    public let maximumBarrierWaitersPerSink: Int

    public init(
        memoryEventLimit: Int = 2_000,
        memoryByteLimit: Int = 2 * 1_024 * 1_024,
        supportReportByteLimit: Int = 4 * 1_024 * 1_024,
        maximumSinkCount: Int = 16,
        maximumPendingRecordsPerSink: Int = 256,
        maximumBarrierWaitersPerSink: Int = 64
    ) {
        self.memoryEventLimit = min(
            max(0, memoryEventLimit),
            Self.largestSupportedMemoryEventLimit)
        self.memoryByteLimit = min(
            max(0, memoryByteLimit),
            Self.largestSupportedMemoryByteLimit)
        self.supportReportByteLimit = min(
            max(1, supportReportByteLimit),
            Self.largestSupportedReportByteLimit)
        self.maximumSinkCount = min(max(0, maximumSinkCount), Self.largestSupportedSinkCount)
        self.maximumPendingRecordsPerSink = min(
            max(0, maximumPendingRecordsPerSink),
            Self.largestSupportedPendingRecordLimitPerSink)
        self.maximumBarrierWaitersPerSink = min(
            max(0, maximumBarrierWaitersPerSink),
            Self.largestSupportedSinkBarrierWaiterLimit)
    }

    private enum CodingKeys: String, CodingKey {
        case memoryEventLimit
        case memoryByteLimit
        case supportReportByteLimit
        case maximumSinkCount
        case maximumPendingRecordsPerSink
        case maximumBarrierWaitersPerSink
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            memoryEventLimit: try container.decode(Int.self, forKey: .memoryEventLimit),
            memoryByteLimit: try container.decode(Int.self, forKey: .memoryByteLimit),
            supportReportByteLimit: try container.decode(Int.self, forKey: .supportReportByteLimit),
            maximumSinkCount: try container.decodeIfPresent(
                Int.self, forKey: .maximumSinkCount) ?? 16,
            maximumPendingRecordsPerSink: try container.decodeIfPresent(
                Int.self, forKey: .maximumPendingRecordsPerSink) ?? 256,
            maximumBarrierWaitersPerSink: try container.decodeIfPresent(
                Int.self, forKey: .maximumBarrierWaitersPerSink) ?? 64)
    }
}

public struct DiagnosticsHealth: Codable, Equatable, Sendable {
    public let recordedEventCount: UInt64
    public let retainedEventCount: Int
    public let retainedByteCount: Int
    public let evictedEventCount: UInt64
    public let oversizedEventCount: UInt64
    public let encodingFailureCount: UInt64
    public let ingressDroppedEventCount: UInt64
    public let sinkFailureCount: UInt64
    /// Per-delivery failures are intentionally separate from `droppedEventCount`:
    /// one event can be dropped by one sink and successfully written by another.
    public let sinkDeliveryDroppedEventCount: UInt64
    public let rejectedSinkRegistrationCount: Int
    public let sinks: [DiagnosticSinkHealth]
    public let droppedEventCount: UInt64

    public init(
        recordedEventCount: UInt64,
        retainedEventCount: Int,
        retainedByteCount: Int,
        evictedEventCount: UInt64,
        oversizedEventCount: UInt64,
        encodingFailureCount: UInt64,
        sinkFailureCount: UInt64,
        ingressDroppedEventCount: UInt64 = 0,
        sinkDeliveryDroppedEventCount: UInt64 = 0,
        rejectedSinkRegistrationCount: Int = 0,
        sinks: [DiagnosticSinkHealth] = []
    ) {
        self.recordedEventCount = recordedEventCount
        self.retainedEventCount = retainedEventCount
        self.retainedByteCount = retainedByteCount
        self.evictedEventCount = evictedEventCount
        self.oversizedEventCount = oversizedEventCount
        self.encodingFailureCount = encodingFailureCount
        self.ingressDroppedEventCount = ingressDroppedEventCount
        self.sinkFailureCount = sinkFailureCount
        self.sinkDeliveryDroppedEventCount = sinkDeliveryDroppedEventCount
        self.rejectedSinkRegistrationCount = max(0, rejectedSinkRegistrationCount)
        self.sinks = sinks
        droppedEventCount = Self.saturatingSum(
            evictedEventCount,
            oversizedEventCount,
            encodingFailureCount,
            ingressDroppedEventCount)
    }

    private static func saturatingSum(_ values: UInt64...) -> UInt64 {
        values.reduce(0) { partial, value in
            let (result, overflow) = partial.addingReportingOverflow(value)
            return overflow ? .max : result
        }
    }

    private enum CodingKeys: String, CodingKey {
        case recordedEventCount
        case retainedEventCount
        case retainedByteCount
        case evictedEventCount
        case oversizedEventCount
        case encodingFailureCount
        case ingressDroppedEventCount
        case sinkFailureCount
        case sinkDeliveryDroppedEventCount
        case rejectedSinkRegistrationCount
        case sinks
        case droppedEventCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            recordedEventCount: try container.decode(UInt64.self, forKey: .recordedEventCount),
            retainedEventCount: try container.decode(Int.self, forKey: .retainedEventCount),
            retainedByteCount: try container.decode(Int.self, forKey: .retainedByteCount),
            evictedEventCount: try container.decode(UInt64.self, forKey: .evictedEventCount),
            oversizedEventCount: try container.decode(UInt64.self, forKey: .oversizedEventCount),
            encodingFailureCount: try container.decode(UInt64.self, forKey: .encodingFailureCount),
            sinkFailureCount: try container.decode(UInt64.self, forKey: .sinkFailureCount),
            ingressDroppedEventCount: try container.decodeIfPresent(
                UInt64.self, forKey: .ingressDroppedEventCount) ?? 0,
            sinkDeliveryDroppedEventCount: try container.decodeIfPresent(
                UInt64.self, forKey: .sinkDeliveryDroppedEventCount) ?? 0,
            rejectedSinkRegistrationCount: try container.decodeIfPresent(
                Int.self, forKey: .rejectedSinkRegistrationCount) ?? 0,
            sinks: try container.decodeIfPresent(
                [DiagnosticSinkHealth].self, forKey: .sinks) ?? [])
        let encodedDropCount = try container.decode(UInt64.self, forKey: .droppedEventCount)
        guard encodedDropCount == droppedEventCount else {
            throw DecodingError.dataCorruptedError(
                forKey: .droppedEventCount,
                in: container,
                debugDescription: "Diagnostic drop counters are inconsistent")
        }
    }
}

public struct DiagnosticsSnapshot: Codable, Equatable, Sendable {
    public let events: [DiagnosticEvent]
    public let health: DiagnosticsHealth

    public init(events: [DiagnosticEvent], health: DiagnosticsHealth) {
        self.events = events
        self.health = health
    }
}

public struct DiagnosticDeadline: Equatable, Sendable {
    public let uptimeNanoseconds: UInt64

    public init(uptimeNanoseconds: UInt64) {
        self.uptimeNanoseconds = uptimeNanoseconds
    }

    public static func after(nanoseconds: UInt64) -> Self {
        let now = DispatchTime.now().uptimeNanoseconds
        let (deadline, overflow) = now.addingReportingOverflow(nanoseconds)
        return Self(uptimeNanoseconds: overflow ? .max : deadline)
    }
}

public protocol DiagnosticBarrierClock: Sendable {
    func uptimeNanoseconds() -> UInt64
    func sleep(until deadline: DiagnosticDeadline) async throws
}

public struct SystemDiagnosticBarrierClock: DiagnosticBarrierClock {
    public init() {}

    public func uptimeNanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    public func sleep(until deadline: DiagnosticDeadline) async throws {
        let now = uptimeNanoseconds()
        guard deadline.uptimeNanoseconds > now else { return }
        try await Task.sleep(nanoseconds: deadline.uptimeNanoseconds - now)
    }
}

public struct DiagnosticSinkCut: Codable, Equatable, Sendable {
    public let id: DiagnosticSinkID
    public let offeredEventCount: UInt64
    public let acceptedEventCount: UInt64
    public let droppedEventCount: UInt64
    public let countersSaturated: Bool

    init(
        id: DiagnosticSinkID,
        offeredEventCount: UInt64,
        acceptedEventCount: UInt64,
        droppedEventCount: UInt64,
        countersSaturated: Bool
    ) {
        if !countersSaturated {
            let (accounted, overflow) = acceptedEventCount
                .addingReportingOverflow(droppedEventCount)
            precondition(!overflow && accounted == offeredEventCount)
        }
        self.id = id
        self.offeredEventCount = offeredEventCount
        self.acceptedEventCount = acceptedEventCount
        self.droppedEventCount = droppedEventCount
        self.countersSaturated = countersSaturated
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case offeredEventCount
        case acceptedEventCount
        case droppedEventCount
        case countersSaturated
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(DiagnosticSinkID.self, forKey: .id)
        let offered = try container.decode(UInt64.self, forKey: .offeredEventCount)
        let accepted = try container.decode(UInt64.self, forKey: .acceptedEventCount)
        let dropped = try container.decode(UInt64.self, forKey: .droppedEventCount)
        let saturated = try container.decode(Bool.self, forKey: .countersSaturated)
        if !saturated {
            let (accounted, overflow) = accepted.addingReportingOverflow(dropped)
            guard !overflow, accounted == offered else {
                throw DecodingError.dataCorruptedError(
                    forKey: .offeredEventCount,
                    in: container,
                    debugDescription: "Diagnostic sink cut counters are inconsistent")
            }
        }
        self.init(
            id: id,
            offeredEventCount: offered,
            acceptedEventCount: accepted,
            droppedEventCount: dropped,
            countersSaturated: saturated)
    }
}

public enum DiagnosticSinkBarrierState: String, Codable, Equatable, Sendable {
    case settled
    case pending
}

public struct DiagnosticSinkBarrierResult: Codable, Equatable, Sendable {
    public let cut: DiagnosticSinkCut
    public let state: DiagnosticSinkBarrierState
    public let writtenEventCount: UInt64
    public let failureCount: UInt64
    public let pendingEventCount: UInt64

    init(
        cut: DiagnosticSinkCut,
        state: DiagnosticSinkBarrierState,
        writtenEventCount: UInt64,
        failureCount: UInt64,
        pendingEventCount: UInt64
    ) {
        let (completedEventCount, completedOverflow) = writtenEventCount
            .addingReportingOverflow(failureCount)
        let (accountedEventCount, accountedOverflow) = completedEventCount
            .addingReportingOverflow(pendingEventCount)
        precondition(!completedOverflow && !accountedOverflow)
        precondition(accountedEventCount == cut.acceptedEventCount)
        precondition(state == .pending || pendingEventCount == 0)
        self.cut = cut
        self.state = state
        self.writtenEventCount = writtenEventCount
        self.failureCount = failureCount
        self.pendingEventCount = pendingEventCount
    }

    private enum CodingKeys: String, CodingKey {
        case cut
        case state
        case writtenEventCount
        case failureCount
        case pendingEventCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let cut = try container.decode(DiagnosticSinkCut.self, forKey: .cut)
        let state = try container.decode(DiagnosticSinkBarrierState.self, forKey: .state)
        let written = try container.decode(UInt64.self, forKey: .writtenEventCount)
        let failures = try container.decode(UInt64.self, forKey: .failureCount)
        let pending = try container.decode(UInt64.self, forKey: .pendingEventCount)
        let (completed, completedOverflow) = written.addingReportingOverflow(failures)
        let (accounted, accountedOverflow) = completed.addingReportingOverflow(pending)
        guard !completedOverflow,
              !accountedOverflow,
              accounted == cut.acceptedEventCount,
              state == .pending || pending == 0
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .pendingEventCount,
                in: container,
                debugDescription: "Diagnostic sink barrier counters are inconsistent")
        }
        self.init(
            cut: cut,
            state: state,
            writtenEventCount: written,
            failureCount: failures,
            pendingEventCount: pending)
    }
}

public struct DiagnosticsCut: Equatable, Sendable {
    public let markerID: UUID
    public let snapshot: DiagnosticsSnapshot
    public let sinks: [DiagnosticSinkCut]

    init(markerID: UUID, snapshot: DiagnosticsSnapshot, sinks: [DiagnosticSinkCut]) {
        self.markerID = markerID
        self.snapshot = snapshot
        self.sinks = sinks
    }
}

public struct DiagnosticsBarrierReceipt: Equatable, Sendable {
    public let cut: DiagnosticsCut
    public let sinks: [DiagnosticSinkBarrierResult]

    init(cut: DiagnosticsCut, sinks: [DiagnosticSinkBarrierResult]) {
        self.cut = cut
        self.sinks = sinks
    }

    public var isFullySettled: Bool {
        sinks.allSatisfy { $0.state == .settled }
    }
}

public enum DiagnosticsBarrierError: Error, Equatable, LocalizedError {
    case waiterLimitExceeded(limit: Int)
    case sinkWaiterLimitExceeded(sinkID: DiagnosticSinkID, limit: Int)
    case deadlineExceeded(partial: DiagnosticsBarrierReceipt?)

    public var errorDescription: String? {
        switch self {
        case let .waiterLimitExceeded(limit):
            return "The diagnostics barrier waiter limit of \(limit) was reached."
        case let .sinkWaiterLimitExceeded(sinkID, limit):
            return "The \(sinkID.rawValue) diagnostics sink waiter limit of \(limit) was reached."
        case .deadlineExceeded:
            return "The diagnostics barrier deadline elapsed before every sink settled."
        }
    }
}

public struct DiagnosticAppMetadata: Codable, Equatable, Sendable {
    public let name: String
    public let bundleIdentifier: String

    public init(name: String, bundleIdentifier: String) {
        self.name = DiagnosticsSanitizer.label(name, fallback: "MarkDev")
        self.bundleIdentifier = DiagnosticsSanitizer.identifier(bundleIdentifier)
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case bundleIdentifier
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decode(String.self, forKey: .name),
            bundleIdentifier: try container.decode(String.self, forKey: .bundleIdentifier))
    }
}

public struct DiagnosticBuildMetadata: Codable, Equatable, Sendable {
    public let version: String
    public let buildNumber: String
    public let sourceCommit: String

    public init(version: String, buildNumber: String, sourceCommit: String) {
        self.version = DiagnosticsSanitizer.version(version)
        self.buildNumber = DiagnosticsSanitizer.version(buildNumber)
        self.sourceCommit = DiagnosticsSanitizer.commit(sourceCommit)
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case buildNumber
        case sourceCommit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            version: try container.decode(String.self, forKey: .version),
            buildNumber: try container.decode(String.self, forKey: .buildNumber),
            sourceCommit: try container.decode(String.self, forKey: .sourceCommit))
    }
}

public struct DiagnosticOSMetadata: Codable, Equatable, Sendable {
    public let name: String
    public let version: String
    public let architecture: String

    public init(name: String, version: String, architecture: String) {
        self.name = DiagnosticsSanitizer.label(name, fallback: "macOS")
        self.version = DiagnosticsSanitizer.version(version)
        self.architecture = DiagnosticsSanitizer.identifier(architecture)
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case version
        case architecture
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decode(String.self, forKey: .name),
            version: try container.decode(String.self, forKey: .version),
            architecture: try container.decode(String.self, forKey: .architecture))
    }
}

public struct DiagnosticReportMetadata: Codable, Equatable, Sendable {
    public let app: DiagnosticAppMetadata
    public let build: DiagnosticBuildMetadata
    public let operatingSystem: DiagnosticOSMetadata

    public init(
        app: DiagnosticAppMetadata,
        build: DiagnosticBuildMetadata,
        operatingSystem: DiagnosticOSMetadata
    ) {
        self.app = app
        self.build = build
        self.operatingSystem = operatingSystem
    }

    public static func current(bundle: Bundle = .main) -> Self {
        let info = bundle.infoDictionary ?? [:]
        let appName = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? ProcessInfo.processInfo.processName
        let version = (info["CFBundleShortVersionString"] as? String) ?? "unknown"
        let build = (info["CFBundleVersion"] as? String) ?? "unknown"
        let sourceCommit = (info["MarkDevSourceCommit"] as? String) ?? "unknown"
        let os = ProcessInfo.processInfo.operatingSystemVersion

        return DiagnosticReportMetadata(
            app: DiagnosticAppMetadata(
                name: appName,
                bundleIdentifier: bundle.bundleIdentifier ?? "unknown"),
            build: DiagnosticBuildMetadata(
                version: version,
                buildNumber: build,
                sourceCommit: sourceCommit),
            operatingSystem: DiagnosticOSMetadata(
                name: "macOS",
                version: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                architecture: DiagnosticsSanitizer.architecture))
    }
}

public enum DiagnosticReportDeliveryState: String, Codable, Equatable, Sendable {
    /// A direct center snapshot was encoded without requesting sink settlement.
    case snapshotOnly = "snapshot_only"
    /// Every sink accepted before the frozen cut has finished its write attempt.
    case settled
    /// The shared monotonic deadline elapsed; per-sink pending counts are exact
    /// for the frozen cut and later events are excluded.
    case timedOut = "timed_out"
}

public struct DiagnosticReportDelivery: Codable, Equatable, Sendable {
    public let state: DiagnosticReportDeliveryState
    public let markerID: UUID?
    public let sinks: [DiagnosticSinkBarrierResult]

    init(
        state: DiagnosticReportDeliveryState,
        markerID: UUID?,
        sinks: [DiagnosticSinkBarrierResult]
    ) {
        precondition(Set(sinks.map(\.cut.id)).count == sinks.count)
        switch state {
        case .snapshotOnly:
            precondition(markerID == nil && sinks.isEmpty)
        case .settled:
            precondition(markerID != nil && sinks.allSatisfy { $0.state == .settled })
        case .timedOut:
            precondition(markerID != nil)
        }
        self.state = state
        self.markerID = markerID
        self.sinks = sinks
    }

    static let snapshotOnly = Self(state: .snapshotOnly, markerID: nil, sinks: [])

    private enum CodingKeys: String, CodingKey {
        case state
        case markerID
        case sinks
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let state = try container.decode(DiagnosticReportDeliveryState.self, forKey: .state)
        let markerID = try container.decodeIfPresent(UUID.self, forKey: .markerID)
        let sinks = try container.decode([DiagnosticSinkBarrierResult].self, forKey: .sinks)
        guard Set(sinks.map(\.cut.id)).count == sinks.count else {
            throw DecodingError.dataCorruptedError(
                forKey: .sinks,
                in: container,
                debugDescription: "Diagnostic report contains duplicate sink results")
        }
        switch state {
        case .snapshotOnly:
            guard markerID == nil, sinks.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .state,
                    in: container,
                    debugDescription: "Snapshot-only delivery cannot claim sink settlement")
            }
        case .settled:
            guard markerID != nil, sinks.allSatisfy({ $0.state == .settled }) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .state,
                    in: container,
                    debugDescription: "Settled delivery contains pending sink work")
            }
        case .timedOut:
            guard markerID != nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .markerID,
                    in: container,
                    debugDescription: "Timed-out delivery requires a frozen marker")
            }
        }
        self.init(state: state, markerID: markerID, sinks: sinks)
    }
}

public struct DiagnosticSupportReport: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let generatedAtMilliseconds: Int64
    public let metadata: DiagnosticReportMetadata
    public let health: DiagnosticsHealth
    public let delivery: DiagnosticReportDelivery
    public let includedEventCount: Int
    public let omittedEventCount: Int
    public let events: [DiagnosticEvent]

    init(
        formatVersion: Int,
        generatedAtMilliseconds: Int64,
        metadata: DiagnosticReportMetadata,
        health: DiagnosticsHealth,
        delivery: DiagnosticReportDelivery,
        includedEventCount: Int,
        omittedEventCount: Int,
        events: [DiagnosticEvent]
    ) {
        precondition(formatVersion == 2)
        precondition(includedEventCount == events.count)
        precondition(omittedEventCount >= 0)
        self.formatVersion = formatVersion
        self.generatedAtMilliseconds = generatedAtMilliseconds
        self.metadata = metadata
        self.health = health
        self.delivery = delivery
        self.includedEventCount = includedEventCount
        self.omittedEventCount = omittedEventCount
        self.events = events
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case generatedAtMilliseconds
        case metadata
        case health
        case delivery
        case includedEventCount
        case omittedEventCount
        case events
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        let includedEventCount = try container.decode(Int.self, forKey: .includedEventCount)
        let omittedEventCount = try container.decode(Int.self, forKey: .omittedEventCount)
        let events = try container.decode([DiagnosticEvent].self, forKey: .events)
        guard formatVersion == 2,
              includedEventCount == events.count,
              omittedEventCount >= 0
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .formatVersion,
                in: container,
                debugDescription: "Diagnostic support report counters or format are inconsistent")
        }
        self.init(
            formatVersion: formatVersion,
            generatedAtMilliseconds: try container.decode(
                Int64.self,
                forKey: .generatedAtMilliseconds),
            metadata: try container.decode(DiagnosticReportMetadata.self, forKey: .metadata),
            health: try container.decode(DiagnosticsHealth.self, forKey: .health),
            delivery: try container.decode(DiagnosticReportDelivery.self, forKey: .delivery),
            includedEventCount: includedEventCount,
            omittedEventCount: omittedEventCount,
            events: events)
    }
}

public struct DiagnosticExportSummary: Codable, Equatable, Sendable {
    public let byteCount: Int
    public let includedEventCount: Int
    public let omittedEventCount: Int
    public let deliveryState: DiagnosticReportDeliveryState
}

/// Exact accounting for one bounded history-inspection dimension.
///
/// `included` and `omitted` partition the objects that were actually inspected.
/// `uninspected` is nil when a safety boundary made the remaining total
/// unknowable; a nil value must never be rendered as zero or "complete".
public struct DiagnosticHistoryDimensionCounts: Codable, Equatable, Sendable {
    public let inspected: Int
    public let included: Int
    public let omitted: Int
    public let uninspected: Int?

    init(inspected: Int, included: Int, omitted: Int, uninspected: Int?) {
        precondition(inspected >= 0)
        precondition(included >= 0)
        precondition(omitted >= 0)
        precondition(included + omitted == inspected)
        precondition(uninspected.map { $0 >= 0 } ?? true)
        self.inspected = inspected
        self.included = included
        self.omitted = omitted
        self.uninspected = uninspected
    }

    private enum CodingKeys: String, CodingKey {
        case inspected
        case included
        case omitted
        case uninspected
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let inspected = try container.decode(Int.self, forKey: .inspected)
        let included = try container.decode(Int.self, forKey: .included)
        let omitted = try container.decode(Int.self, forKey: .omitted)
        let uninspected = try container.decodeIfPresent(Int.self, forKey: .uninspected)
        guard inspected >= 0,
              included >= 0,
              omitted >= 0,
              included.addingReportingOverflow(omitted).overflow == false,
              included + omitted == inspected,
              uninspected.map({ $0 >= 0 }) ?? true
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .inspected,
                in: container,
                debugDescription: "Diagnostic history counters are inconsistent")
        }
        self.init(
            inspected: inspected,
            included: included,
            omitted: omitted,
            uninspected: uninspected)
    }
}

public struct DiagnosticHistoryInspection: Codable, Equatable, Sendable {
    public let inspectedRootEntryCount: Int
    public let uninspectedRootEntryCount: Int?
    public let runs: DiagnosticHistoryDimensionCounts
    public let files: DiagnosticHistoryDimensionCounts
    public let bytes: DiagnosticHistoryDimensionCounts
    public let events: DiagnosticHistoryDimensionCounts

    init(
        inspectedRootEntryCount: Int,
        uninspectedRootEntryCount: Int?,
        runs: DiagnosticHistoryDimensionCounts,
        files: DiagnosticHistoryDimensionCounts,
        bytes: DiagnosticHistoryDimensionCounts,
        events: DiagnosticHistoryDimensionCounts
    ) {
        precondition(inspectedRootEntryCount >= 0)
        precondition(uninspectedRootEntryCount.map { $0 >= 0 } ?? true)
        self.inspectedRootEntryCount = inspectedRootEntryCount
        self.uninspectedRootEntryCount = uninspectedRootEntryCount
        self.runs = runs
        self.files = files
        self.bytes = bytes
        self.events = events
    }
}

public struct DiagnosticHistoryRun: Codable, Equatable, Sendable {
    public let origin: DiagnosticOrigin
    public let events: [DiagnosticEvent]

    init(origin: DiagnosticOrigin, events: [DiagnosticEvent]) {
        precondition(origin.isTrustedProduction)
        precondition(events.allSatisfy { $0.origin == origin })
        self.origin = origin
        self.events = events
    }

    private enum CodingKeys: String, CodingKey {
        case origin
        case events
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let origin = try container.decode(DiagnosticOrigin.self, forKey: .origin)
        let events = try container.decode([DiagnosticEvent].self, forKey: .events)
        guard origin.isTrustedProduction,
              events.allSatisfy({ $0.origin == origin })
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .origin,
                in: container,
                debugDescription: "Diagnostic history run contains an inconsistent origin")
        }
        self.init(origin: origin, events: events)
    }
}

/// Canonical privacy-safe export of inactive, previously persisted runs.
/// Filesystem paths and raw file errors are intentionally absent.
public struct DiagnosticHistoryReport: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let generatedAtMilliseconds: Int64
    public let inspection: DiagnosticHistoryInspection
    public let runs: [DiagnosticHistoryRun]

    init(
        formatVersion: Int = 1,
        generatedAtMilliseconds: Int64,
        inspection: DiagnosticHistoryInspection,
        runs: [DiagnosticHistoryRun]
    ) {
        precondition(formatVersion == 1)
        precondition(inspection.runs.included == runs.count)
        precondition(inspection.events.included == runs.reduce(0) { $0 + $1.events.count })
        self.formatVersion = formatVersion
        self.generatedAtMilliseconds = generatedAtMilliseconds
        self.inspection = inspection
        self.runs = runs
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case generatedAtMilliseconds
        case inspection
        case runs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        let inspection = try container.decode(
            DiagnosticHistoryInspection.self,
            forKey: .inspection)
        let runs = try container.decode([DiagnosticHistoryRun].self, forKey: .runs)
        let (includedEvents, overflow) = runs.reduce(into: (count: 0, overflow: false)) {
            partial, run in
            let result = partial.count.addingReportingOverflow(run.events.count)
            partial.count = result.partialValue
            partial.overflow = partial.overflow || result.overflow
        }
        guard formatVersion == 1,
              inspection.runs.included == runs.count,
              !overflow,
              inspection.events.included == includedEvents
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .formatVersion,
                in: container,
                debugDescription: "Diagnostic history report counters or format are inconsistent")
        }
        self.init(
            generatedAtMilliseconds: try container.decode(
                Int64.self,
                forKey: .generatedAtMilliseconds),
            inspection: inspection,
            runs: runs)
    }
}

public struct DiagnosticHistorySnapshot: Equatable, Sendable {
    public let inspection: DiagnosticHistoryInspection

    init(report: DiagnosticHistoryReport) {
        inspection = report.inspection
    }

    init(inspection: DiagnosticHistoryInspection) {
        self.inspection = inspection
    }
}

public struct DiagnosticHistoryExportSummary: Equatable, Sendable {
    public let byteCount: Int
    public let inspection: DiagnosticHistoryInspection
}

enum DiagnosticsJSON {
    static func data<T: Encodable>(for value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func line(for event: DiagnosticEvent) throws -> Data {
        var data = try self.data(for: event)
        data.append(0x0A)
        return data
    }
}

private enum DiagnosticsSanitizer {
    static func fileExtension(_ value: String) -> String {
        guard value.utf8.count <= 16 else { return "other" }
        let normalized = value.lowercased()
        if normalized.isEmpty { return "none" }
        let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mdx", "mkd"]
        return markdownExtensions.contains(normalized) ? normalized : "other"
    }

    static func urlOrigin(_ url: URL) -> String {
        guard url.absoluteString.utf8.count <= 2_048 else { return "invalid" }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let rawScheme = components.scheme?.lowercased(),
              let rawHost = components.host?.lowercased(),
              !rawScheme.isEmpty,
              !rawHost.isEmpty,
              rawScheme == "http" || rawScheme == "https",
              rawHost.utf8.count <= 253,
              rawHost.utf8.allSatisfy({ isAlphaNumeric($0) || $0 == 0x2D || $0 == 0x2E || $0 == 0x3A })
        else {
            return "invalid"
        }

        let host = rawHost.contains(":") ? "[\(rawHost)]" : rawHost
        let port = components.port.map { ":\($0)" } ?? ""
        return "\(rawScheme)://\(host)\(port)"
    }

    static func label(_ value: String, fallback: String) -> String {
        boundedASCII(value, allowed: { byte in
            isAlphaNumeric(byte) || byte == 0x20 || byte == 0x2D || byte == 0x2E || byte == 0x5F
        }, fallback: fallback)
    }

    static func identifier(_ value: String) -> String {
        boundedASCII(value, allowed: { byte in
            isAlphaNumeric(byte) || byte == 0x2D || byte == 0x2E || byte == 0x5F
        }, fallback: "unknown")
    }

    static func version(_ value: String) -> String {
        boundedASCII(value, allowed: { byte in
            isAlphaNumeric(byte) || byte == 0x2B || byte == 0x2D || byte == 0x2E || byte == 0x5F
        }, fallback: "unknown")
    }

    static func commit(_ value: String) -> String {
        guard value.utf8.count <= 64 else { return "unknown" }
        let normalized = value.lowercased()
        guard (7...64).contains(normalized.utf8.count),
              normalized.utf8.allSatisfy({ byte in
                  (0x30...0x39).contains(byte) || (0x61...0x66).contains(byte)
              })
        else {
            return "unknown"
        }
        return normalized
    }

    static var architecture: String {
#if arch(arm64)
        return "arm64"
#elseif arch(x86_64)
        return "x86_64"
#else
        return "unknown"
#endif
    }

    private static func boundedASCII(
        _ value: String,
        allowed: (UInt8) -> Bool,
        fallback: String
    ) -> String {
        guard !value.isEmpty,
              value.utf8.count <= 80,
              value.utf8.allSatisfy(allowed)
        else {
            return fallback
        }
        return value
    }

    private static func isAlphaNumeric(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x61...0x7A).contains(byte)
    }
}
