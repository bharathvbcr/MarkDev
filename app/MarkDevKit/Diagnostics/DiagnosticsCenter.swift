//
//  DiagnosticsCenter.swift
//  MarkDevKit
//
//  The single serialization, retention, health, and support-export owner.
//

import Darwin
import Foundation

public enum DiagnosticsError: Error, Equatable, LocalizedError {
    case reportExceedsByteLimit(limit: Int)
    case destinationDirectoryUnavailable

    public var errorDescription: String? {
        switch self {
        case let .reportExceedsByteLimit(limit):
            return "The diagnostics report metadata exceeds its \(limit)-byte limit."
        case .destinationDirectoryUnavailable:
            return "The diagnostics report destination directory is unavailable."
        }
    }
}

public actor DiagnosticsCenter {
    /// Whether this process is a test run rather than the app.
    ///
    /// The shared centre writes to the *reader's* Application Support
    /// directory, and a test suite that exercises a production call site
    /// writes there too. Measured on this machine after one afternoon's work:
    /// the log held 428 `editor.document.rejected` events and 212 autosave
    /// conflicts against three real launches — every one of them fabricated by
    /// a test. A support report is then mostly evidence about documents nobody
    /// opened, which is worse than an empty one: it is an export that looks
    /// complete and describes a session that never happened.
    ///
    /// The environment variable is the test runner's own, set by XCTest before
    /// the bundle loads. Tests that care about delivery build their own centre
    /// with their own sinks and are unaffected; what this suppresses is the
    /// *default* file sink, for the tests that never asked for one.
    static var isRunningTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    public static let shared: DiagnosticsCenter = {
        var sinks: [any DiagnosticSink] = [OSLogDiagnosticsSink()]
        var initialSinkFailureCount: UInt64 = 0

        // Not a failure, and must not be counted as one: the sink was never
        // attempted. Reporting a sink failure here would make "we chose not to
        // write" indistinguishable from "the disk refused us" in the health
        // the settings panel shows.
        if isRunningTests {
            return DiagnosticsCenter(
                configuration: DiagnosticsConfiguration(),
                sinks: sinks,
                clock: SystemDiagnosticClock(),
                initialSinkFailureCount: 0)
        }

        do {
            guard let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                throw DiagnosticsError.destinationDirectoryUnavailable
            }
            let directory = applicationSupport
                .appendingPathComponent("MarkDev", isDirectory: true)
                .appendingPathComponent("Diagnostics", isDirectory: true)
            let fileSink = try RotatingJSONLDiagnosticsSink(
                configuration: RotatingDiagnosticsFileConfiguration(
                    directory: directory,
                    baseName: "events",
                    maximumFileBytes: 1 * 1_024 * 1_024,
                    maximumFiles: 4))
            sinks.append(fileSink)
        } catch {
            initialSinkFailureCount = 1
        }

        return DiagnosticsCenter(
            configuration: DiagnosticsConfiguration(),
            sinks: sinks,
            clock: SystemDiagnosticClock(),
            initialSinkFailureCount: initialSinkFailureCount)
    }()

    private let configuration: DiagnosticsConfiguration
    private let sinks: [any DiagnosticSink]
    private let clock: any DiagnosticClock
    private var ring: BoundedDiagnosticRing
    private var nextSequence: UInt64 = 1
    private var recordedEventCount: UInt64 = 0
    private var evictedEventCount: UInt64 = 0
    private var oversizedEventCount: UInt64 = 0
    private var encodingFailureCount: UInt64 = 0
    private var ingressDroppedEventCount: UInt64 = 0
    private var sinkFailureCount: UInt64

    public init(
        configuration: DiagnosticsConfiguration = DiagnosticsConfiguration(),
        sinks: [any DiagnosticSink] = [],
        clock: any DiagnosticClock = SystemDiagnosticClock(),
        initialSinkFailureCount: UInt64 = 0
    ) {
        self.configuration = configuration
        self.sinks = sinks
        self.clock = clock
        ring = BoundedDiagnosticRing(
            countLimit: configuration.memoryEventLimit,
            byteLimit: configuration.memoryByteLimit)
        sinkFailureCount = initialSinkFailureCount
    }

    public func record(
        severity: DiagnosticSeverity,
        subsystem: DiagnosticSubsystem,
        code: DiagnosticCode,
        operationID: DiagnosticOperationID? = nil,
        metadata: DiagnosticMetadata = DiagnosticMetadata()
    ) async {
        let sequence = nextSequence
        nextSequence = nextSequence.saturatingIncremented
        recordedEventCount = recordedEventCount.saturatingIncremented

        let event = DiagnosticEvent(
            sequence: sequence,
            timestampMilliseconds: clock.millisecondsSince1970(),
            uptimeNanoseconds: clock.uptimeNanoseconds(),
            severity: severity,
            subsystem: subsystem,
            code: code,
            operationID: operationID,
            metadata: metadata)

        let record: DiagnosticRecord
        do {
            record = DiagnosticRecord(event: event, jsonLine: try DiagnosticsJSON.line(for: event))
        } catch {
            encodingFailureCount = encodingFailureCount.saturatingIncremented
            return
        }

        switch ring.append(record) {
        case let .retained(evicted):
            evictedEventCount = evictedEventCount.saturatingAdding(UInt64(evicted))
        case .oversized:
            oversizedEventCount = oversizedEventCount.saturatingIncremented
        }

        for sink in sinks {
            do {
                try await sink.write(record)
            } catch {
                sinkFailureCount = sinkFailureCount.saturatingIncremented
            }
        }
    }

    public func snapshot() -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(events: ring.events, health: health)
    }

    /// Accounts for events refused by the synchronous producer boundary
    /// before they can enter this actor. The producer reports exact batches;
    /// saturation keeps a pathological flood from wrapping health back to a
    /// reassuringly small number.
    public func accountForIngressDrops(_ count: UInt64) {
        ingressDroppedEventCount = ingressDroppedEventCount.saturatingAdding(count)
    }

    public func supportReportData(
        metadata: DiagnosticReportMetadata = .current(),
        generatedAtMilliseconds: Int64? = nil
    ) throws -> Data {
        let events = ring.events
        let timestamp = generatedAtMilliseconds ?? clock.millisecondsSince1970()

        func encode(omitting omittedEventCount: Int) throws -> Data {
            let report = DiagnosticSupportReport(
                formatVersion: 1,
                generatedAtMilliseconds: timestamp,
                metadata: metadata,
                health: health,
                includedEventCount: events.count - omittedEventCount,
                omittedEventCount: omittedEventCount,
                events: Array(events.dropFirst(omittedEventCount)))
            return try DiagnosticsJSON.data(for: report)
        }

        let complete = try encode(omitting: 0)
        guard complete.count > configuration.supportReportByteLimit else {
            return complete
        }

        // The retained count is capped at 100,000. A linear remove-and-reencode
        // loop turns a deliberately tiny report cap into quadratic work over
        // that whole ring. Find the smallest omitted prefix logarithmically;
        // every removed event is substantially larger than the at-most-one-byte
        // counter growth at a decimal boundary, so encoded size is monotonic.
        var lowerBound = 1
        var upperBound = events.count
        var smallestFittingReport: Data?
        while lowerBound <= upperBound {
            let midpoint = lowerBound + (upperBound - lowerBound) / 2
            let candidate = try encode(omitting: midpoint)
            if candidate.count <= configuration.supportReportByteLimit {
                smallestFittingReport = candidate
                upperBound = midpoint - 1
            } else {
                lowerBound = midpoint + 1
            }
        }

        guard let smallestFittingReport else {
            throw DiagnosticsError.reportExceedsByteLimit(
                limit: configuration.supportReportByteLimit)
        }
        return smallestFittingReport
    }

    public func exportSupportReport(
        to destination: URL,
        metadata: DiagnosticReportMetadata = .current(),
        generatedAtMilliseconds: Int64? = nil
    ) throws -> DiagnosticExportSummary {
        let data = try supportReportData(
            metadata: metadata,
            generatedAtMilliseconds: generatedAtMilliseconds)
        let report = try JSONDecoder().decode(DiagnosticSupportReport.self, from: data)
        try SecureAtomicDiagnosticsFile.write(data, to: destination)
        return DiagnosticExportSummary(
            byteCount: data.count,
            includedEventCount: report.includedEventCount,
            omittedEventCount: report.omittedEventCount)
    }

    private var health: DiagnosticsHealth {
        DiagnosticsHealth(
            recordedEventCount: recordedEventCount,
            retainedEventCount: ring.count,
            retainedByteCount: ring.byteCount,
            evictedEventCount: evictedEventCount,
            oversizedEventCount: oversizedEventCount,
            encodingFailureCount: encodingFailureCount,
            sinkFailureCount: sinkFailureCount,
            ingressDroppedEventCount: ingressDroppedEventCount)
    }
}

private struct BoundedDiagnosticRing {
    enum AppendResult {
        case retained(evicted: Int)
        case oversized
    }

    private let countLimit: Int
    private let byteLimit: Int
    private var storage: [DiagnosticRecord?]
    private var head = 0
    private(set) var count = 0
    private(set) var byteCount = 0

    init(countLimit: Int, byteLimit: Int) {
        self.countLimit = countLimit
        self.byteLimit = byteLimit
        storage = Array(repeating: nil, count: countLimit)
    }

    var events: [DiagnosticEvent] {
        guard count > 0 else { return [] }
        var result: [DiagnosticEvent] = []
        result.reserveCapacity(count)
        for offset in 0..<count {
            let index = (head + offset) % countLimit
            if let record = storage[index] {
                result.append(record.event)
            }
        }
        return result
    }

    mutating func append(_ record: DiagnosticRecord) -> AppendResult {
        guard record.jsonLine.count <= byteLimit else {
            return .oversized
        }
        guard countLimit > 0 else {
            return .retained(evicted: 1)
        }

        var evicted = 0
        while count == countLimit || byteCount + record.jsonLine.count > byteLimit {
            removeFirst()
            evicted += 1
        }

        let tail = (head + count) % countLimit
        storage[tail] = record
        count += 1
        byteCount += record.jsonLine.count
        return .retained(evicted: evicted)
    }

    private mutating func removeFirst() {
        guard count > 0, let record = storage[head] else { return }
        byteCount -= record.jsonLine.count
        storage[head] = nil
        head = (head + 1) % countLimit
        count -= 1
    }
}

enum SecureAtomicDiagnosticsFile {
    static func write(_ data: Data, to destination: URL) throws {
        let fileManager = FileManager.default
        let directory = destination.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw DiagnosticsError.destinationDirectoryUnavailable
        }

        let temporary = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = temporary.path.withCString { path in
            Darwin.open(
                path,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var renamed = false
        defer {
            Darwin.close(descriptor)
            if !renamed {
                temporary.path.withCString { path in
                    _ = Darwin.unlink(path)
                }
            }
        }

        try writeAll(data, descriptor: descriptor)
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let renameResult = temporary.path.withCString { source in
            destination.path.withCString { target in
                Darwin.rename(source, target)
            }
        }
        guard renameResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        renamed = true
        try syncDirectory(directory)
    }

    static func syncDirectory(_ directory: URL) throws {
        let directoryDescriptor = directory.path.withCString { path in
            Darwin.open(path, O_RDONLY | O_CLOEXEC)
        }
        guard directoryDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(directoryDescriptor) }

        var status = stat()
        guard Darwin.fstat(directoryDescriptor, &status) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard status.st_mode & S_IFMT == S_IFDIR else {
            throw DiagnosticsError.destinationDirectoryUnavailable
        }
        guard Darwin.fsync(directoryDescriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                guard written > 0 else {
                    throw POSIXError(.EIO)
                }
                offset += written
            }
        }
    }
}

private extension UInt64 {
    var saturatingIncremented: UInt64 {
        self == .max ? .max : self + 1
    }

    func saturatingAdding(_ other: UInt64) -> UInt64 {
        let (result, overflow) = addingReportingOverflow(other)
        return overflow ? .max : result
    }
}
