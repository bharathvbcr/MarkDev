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

    private static let allowedRawValues: Set<String> = [
        "diagnostics.invalid-code",
        "app.launch.abi-verified",
        "workspace.save.succeeded",
        "workspace.save.failed",
        "workspace.autosave.conflict",
        "workspace.autosave.failed",
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

public struct DiagnosticEvent: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let sequence: UInt64
    public let timestampMilliseconds: Int64
    public let uptimeNanoseconds: UInt64
    public let severity: DiagnosticSeverity
    public let subsystem: DiagnosticSubsystem
    public let code: DiagnosticCode
    public let operationID: DiagnosticOperationID?
    public let metadata: DiagnosticMetadata

    public init(
        schemaVersion: Int = 1,
        sequence: UInt64,
        timestampMilliseconds: Int64,
        uptimeNanoseconds: UInt64,
        severity: DiagnosticSeverity,
        subsystem: DiagnosticSubsystem,
        code: DiagnosticCode,
        operationID: DiagnosticOperationID?,
        metadata: DiagnosticMetadata
    ) {
        self.schemaVersion = schemaVersion
        self.sequence = sequence
        self.timestampMilliseconds = timestampMilliseconds
        self.uptimeNanoseconds = uptimeNanoseconds
        self.severity = severity
        self.subsystem = subsystem
        self.code = code
        self.operationID = operationID
        self.metadata = metadata
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

public struct DiagnosticsConfiguration: Codable, Equatable, Sendable {
    public static let largestSupportedMemoryEventLimit = 100_000
    public static let largestSupportedMemoryByteLimit = 64 * 1_024 * 1_024
    public static let largestSupportedReportByteLimit = 64 * 1_024 * 1_024

    public let memoryEventLimit: Int
    public let memoryByteLimit: Int
    public let supportReportByteLimit: Int

    public init(
        memoryEventLimit: Int = 2_000,
        memoryByteLimit: Int = 2 * 1_024 * 1_024,
        supportReportByteLimit: Int = 4 * 1_024 * 1_024
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
    }

    private enum CodingKeys: String, CodingKey {
        case memoryEventLimit
        case memoryByteLimit
        case supportReportByteLimit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            memoryEventLimit: try container.decode(Int.self, forKey: .memoryEventLimit),
            memoryByteLimit: try container.decode(Int.self, forKey: .memoryByteLimit),
            supportReportByteLimit: try container.decode(Int.self, forKey: .supportReportByteLimit))
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
    public let droppedEventCount: UInt64

    public init(
        recordedEventCount: UInt64,
        retainedEventCount: Int,
        retainedByteCount: Int,
        evictedEventCount: UInt64,
        oversizedEventCount: UInt64,
        encodingFailureCount: UInt64,
        sinkFailureCount: UInt64,
        ingressDroppedEventCount: UInt64 = 0
    ) {
        self.recordedEventCount = recordedEventCount
        self.retainedEventCount = retainedEventCount
        self.retainedByteCount = retainedByteCount
        self.evictedEventCount = evictedEventCount
        self.oversizedEventCount = oversizedEventCount
        self.encodingFailureCount = encodingFailureCount
        self.ingressDroppedEventCount = ingressDroppedEventCount
        self.sinkFailureCount = sinkFailureCount
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
                UInt64.self, forKey: .ingressDroppedEventCount) ?? 0)
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

public struct DiagnosticSupportReport: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let generatedAtMilliseconds: Int64
    public let metadata: DiagnosticReportMetadata
    public let health: DiagnosticsHealth
    public let includedEventCount: Int
    public let omittedEventCount: Int
    public let events: [DiagnosticEvent]
}

public struct DiagnosticExportSummary: Codable, Equatable, Sendable {
    public let byteCount: Int
    public let includedEventCount: Int
    public let omittedEventCount: Int
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
