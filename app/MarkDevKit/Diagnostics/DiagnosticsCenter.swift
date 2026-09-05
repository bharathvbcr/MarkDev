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
        let origin = DiagnosticsBootstrap.currentOrigin()
        var registrations = [
            DiagnosticSinkRegistration(id: .osLog, sink: OSLogDiagnosticsSink())
        ]
        var initialSinkFailureCount: UInt64 = 0

        // Not a failure, and must not be counted as one: the sink was never
        // attempted. Reporting a sink failure here would make "we chose not to
        // write" indistinguishable from "the disk refused us" in the health
        // the settings panel shows.
        if isRunningTests || !origin.isTrustedProduction {
            return DiagnosticsCenter(
                configuration: DiagnosticsConfiguration(),
                registrations: registrations,
                clock: SystemDiagnosticClock(),
                initialSinkFailureCount: 0,
                origin: origin)
        }

        do {
            guard let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                throw DiagnosticsError.destinationDirectoryUnavailable
            }
            let directory = applicationSupport
            let fileSink = try DiagnosticsScopedRunStore.makeSink(
                applicationSupportDirectory: applicationSupport,
                origin: origin,
                maximumFileBytes: 1 * 1_024 * 1_024,
                maximumFiles: 4)
            registrations.append(
                DiagnosticSinkRegistration(id: .rotatingJSONL, sink: fileSink))
        } catch {
            initialSinkFailureCount = 1
        }

        return DiagnosticsCenter(
            configuration: DiagnosticsConfiguration(),
            registrations: registrations,
            clock: SystemDiagnosticClock(),
            initialSinkFailureCount: initialSinkFailureCount,
            origin: origin)
    }()

    private let configuration: DiagnosticsConfiguration
    private let lanes: [DiagnosticSinkLane]
    private let clock: any DiagnosticClock
    public nonisolated let origin: DiagnosticOrigin
    private let rejectedSinkRegistrationCount: Int
    private var ring: BoundedDiagnosticRing
    private var nextSequence: UInt64? = 1
    private var recordedEventCount: UInt64 = 0
    private var evictedEventCount: UInt64 = 0
    private var oversizedEventCount: UInt64 = 0
    private var encodingFailureCount: UInt64 = 0
    private var ingressDroppedEventCount: UInt64 = 0
    private let initialSinkFailureCount: UInt64

    public init(
        configuration: DiagnosticsConfiguration = DiagnosticsConfiguration(),
        sinks: [any DiagnosticSink] = [],
        clock: any DiagnosticClock = SystemDiagnosticClock(),
        initialSinkFailureCount: UInt64 = 0,
        origin: DiagnosticOrigin? = nil
    ) {
        self.configuration = configuration
        self.clock = clock
        self.origin = origin ?? DiagnosticsBootstrap.currentOrigin()
        let registrations = sinks.enumerated().map { index, sink in
            DiagnosticSinkRegistration(
                id: DiagnosticSinkID(knownRawValue: "sink-\(index)"),
                sink: sink,
                maximumOutstandingRecords: configuration.maximumPendingRecordsPerSink)
        }
        let normalized = Self.makeLanes(
            registrations: registrations,
            configuration: configuration)
        lanes = normalized.lanes
        rejectedSinkRegistrationCount = normalized.rejectedCount
        ring = BoundedDiagnosticRing(
            countLimit: configuration.memoryEventLimit,
            byteLimit: configuration.memoryByteLimit)
        self.initialSinkFailureCount = initialSinkFailureCount
    }

    public init(
        configuration: DiagnosticsConfiguration = DiagnosticsConfiguration(),
        registrations: [DiagnosticSinkRegistration],
        clock: any DiagnosticClock = SystemDiagnosticClock(),
        initialSinkFailureCount: UInt64 = 0,
        origin: DiagnosticOrigin? = nil
    ) {
        self.configuration = configuration
        self.clock = clock
        self.origin = origin ?? DiagnosticsBootstrap.currentOrigin()
        let normalized = Self.makeLanes(
            registrations: registrations,
            configuration: configuration)
        lanes = normalized.lanes
        rejectedSinkRegistrationCount = normalized.rejectedCount
        ring = BoundedDiagnosticRing(
            countLimit: configuration.memoryEventLimit,
            byteLimit: configuration.memoryByteLimit)
        self.initialSinkFailureCount = initialSinkFailureCount
    }

    func record(
        severity: DiagnosticSeverity,
        subsystem: DiagnosticSubsystem,
        code: DiagnosticCode,
        operationID: DiagnosticOperationID? = nil,
        metadata: DiagnosticMetadata = DiagnosticMetadata()
    ) async {
        let completions = offer(
            severity: severity,
            subsystem: subsystem,
            code: code,
            operationID: operationID,
            metadata: metadata,
            requestingSinkCompletion: true)
        await withTaskGroup(of: Void.self) { group in
            for completion in completions {
                group.addTask {
                    await completion.wait()
                }
            }
        }
    }

    /// The emitter is the production ingress and already owns its own bounded
    /// ordering queue. It offers records to every independent sink lane without
    /// awaiting their completion, then captures an exact cut at its marker.
    func offer(
        severity: DiagnosticSeverity,
        subsystem: DiagnosticSubsystem,
        code: DiagnosticCode,
        operationID: DiagnosticOperationID? = nil,
        metadata: DiagnosticMetadata = DiagnosticMetadata()
    ) {
        _ = offer(
            severity: severity,
            subsystem: subsystem,
            code: code,
            operationID: operationID,
            metadata: metadata,
            requestingSinkCompletion: false)
    }

    private func offer(
        severity: DiagnosticSeverity,
        subsystem: DiagnosticSubsystem,
        code: DiagnosticCode,
        operationID: DiagnosticOperationID?,
        metadata: DiagnosticMetadata,
        requestingSinkCompletion: Bool
    ) -> [DiagnosticSinkDeliveryHandle] {
        guard let sequence = nextSequence else {
            ingressDroppedEventCount = ingressDroppedEventCount.saturatingIncremented
            return []
        }
        nextSequence = sequence == .max ? nil : sequence + 1
        recordedEventCount = recordedEventCount.saturatingIncremented

        let event = DiagnosticEvent(
            origin: origin,
            localSequence: sequence,
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
            return []
        }

        switch ring.append(record) {
        case let .retained(evicted):
            evictedEventCount = evictedEventCount.saturatingAdding(UInt64(evicted))
        case .oversized:
            oversizedEventCount = oversizedEventCount.saturatingIncremented
        }

        return lanes.compactMap {
            $0.offer(record, requestingCompletion: requestingSinkCompletion)
        }
    }

    func setNextSequenceForTesting(_ sequence: UInt64?) {
        precondition(recordedEventCount == 0)
        precondition(sequence.map { $0 > 0 } ?? true)
        nextSequence = sequence
    }

    public func snapshot() -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(events: ring.events, health: health)
    }

    func captureCut(markerID: UUID) throws -> CapturedDiagnosticsCut {
        var barriers: [DiagnosticSinkBarrierHandle] = []
        barriers.reserveCapacity(lanes.count)
        do {
            for lane in lanes {
                barriers.append(try lane.captureBarrier())
            }
        } catch {
            for barrier in barriers {
                barrier.cancel()
            }
            throw error
        }

        let cut = DiagnosticsCut(
            markerID: markerID,
            snapshot: DiagnosticsSnapshot(events: ring.events, health: health),
            sinks: barriers.map(\.cut))
        return CapturedDiagnosticsCut(cut: cut, sinkBarriers: barriers)
    }

    func pendingSinkBarrierCountForTesting() -> Int {
        lanes.reduce(0) { $0 + $1.pendingBarrierCountForTesting }
    }

    /// Accounts for events refused by the synchronous producer boundary
    /// before they can enter this actor. The producer reports exact batches;
    /// saturation keeps a pathological flood from wrapping health back to a
    /// reassuringly small number.
    func accountForIngressDrops(_ count: UInt64) {
        ingressDroppedEventCount = ingressDroppedEventCount.saturatingAdding(count)
    }

    func supportReportData(
        metadata: DiagnosticReportMetadata = .current(),
        generatedAtMilliseconds: Int64? = nil
    ) throws -> Data {
        try supportReportData(
            events: ring.events,
            health: health,
            delivery: .snapshotOnly,
            metadata: metadata,
            generatedAtMilliseconds: generatedAtMilliseconds)
    }

    func supportReportData(
        from cut: DiagnosticsCut,
        metadata: DiagnosticReportMetadata = .current(),
        generatedAtMilliseconds: Int64? = nil
    ) throws -> Data {
        try supportReportData(
            events: cut.snapshot.events,
            health: cut.snapshot.health,
            delivery: .snapshotOnly,
            metadata: metadata,
            generatedAtMilliseconds: generatedAtMilliseconds)
    }

    func supportReportData(
        from receipt: DiagnosticsBarrierReceipt,
        deliveryState: DiagnosticReportDeliveryState,
        metadata: DiagnosticReportMetadata = .current(),
        generatedAtMilliseconds: Int64? = nil
    ) throws -> Data {
        precondition(deliveryState == .settled || deliveryState == .timedOut)
        return try supportReportData(
            events: receipt.cut.snapshot.events,
            health: receipt.cut.snapshot.health,
            delivery: DiagnosticReportDelivery(
                state: deliveryState,
                markerID: receipt.cut.markerID,
                sinks: receipt.sinks),
            metadata: metadata,
            generatedAtMilliseconds: generatedAtMilliseconds)
    }

    private func supportReportData(
        events: [DiagnosticEvent],
        health: DiagnosticsHealth,
        delivery: DiagnosticReportDelivery,
        metadata: DiagnosticReportMetadata,
        generatedAtMilliseconds: Int64?
    ) throws -> Data {
        let timestamp = generatedAtMilliseconds ?? clock.millisecondsSince1970()

        func encode(omitting omittedEventCount: Int) throws -> Data {
            let report = DiagnosticSupportReport(
                formatVersion: 2,
                generatedAtMilliseconds: timestamp,
                metadata: metadata,
                health: health,
                delivery: delivery,
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

    func exportSupportReport(
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
            omittedEventCount: report.omittedEventCount,
            deliveryState: report.delivery.state)
    }

    func exportSupportReport(
        from cut: DiagnosticsCut,
        to destination: URL,
        metadata: DiagnosticReportMetadata = .current(),
        generatedAtMilliseconds: Int64? = nil
    ) throws -> DiagnosticExportSummary {
        let data = try supportReportData(
            from: cut,
            metadata: metadata,
            generatedAtMilliseconds: generatedAtMilliseconds)
        let report = try JSONDecoder().decode(DiagnosticSupportReport.self, from: data)
        try SecureAtomicDiagnosticsFile.write(data, to: destination)
        return DiagnosticExportSummary(
            byteCount: data.count,
            includedEventCount: report.includedEventCount,
            omittedEventCount: report.omittedEventCount,
            deliveryState: report.delivery.state)
    }

    func exportSupportReport(
        from receipt: DiagnosticsBarrierReceipt,
        deliveryState: DiagnosticReportDeliveryState,
        to destination: URL,
        metadata: DiagnosticReportMetadata = .current(),
        generatedAtMilliseconds: Int64? = nil
    ) throws -> DiagnosticExportSummary {
        let data = try supportReportData(
            from: receipt,
            deliveryState: deliveryState,
            metadata: metadata,
            generatedAtMilliseconds: generatedAtMilliseconds)
        let report = try JSONDecoder().decode(DiagnosticSupportReport.self, from: data)
        try SecureAtomicDiagnosticsFile.write(data, to: destination)
        return DiagnosticExportSummary(
            byteCount: data.count,
            includedEventCount: report.includedEventCount,
            omittedEventCount: report.omittedEventCount,
            deliveryState: report.delivery.state)
    }

    private var health: DiagnosticsHealth {
        let sinkHealth = lanes.map { $0.healthSnapshot() }
        let sinkFailures = sinkHealth.reduce(initialSinkFailureCount) { partial, sink in
            partial.saturatingAdding(sink.failureCount)
        }
        let sinkDeliveryDrops = sinkHealth.reduce(UInt64(0)) { partial, sink in
            partial.saturatingAdding(sink.droppedEventCount)
        }
        return DiagnosticsHealth(
            recordedEventCount: recordedEventCount,
            retainedEventCount: ring.count,
            retainedByteCount: ring.byteCount,
            evictedEventCount: evictedEventCount,
            oversizedEventCount: oversizedEventCount,
            encodingFailureCount: encodingFailureCount,
            sinkFailureCount: sinkFailures,
            ingressDroppedEventCount: ingressDroppedEventCount,
            sinkDeliveryDroppedEventCount: sinkDeliveryDrops,
            rejectedSinkRegistrationCount: rejectedSinkRegistrationCount,
            sinks: sinkHealth)
    }

    private static func makeLanes(
        registrations: [DiagnosticSinkRegistration],
        configuration: DiagnosticsConfiguration
    ) -> (lanes: [DiagnosticSinkLane], rejectedCount: Int) {
        var identifiers: Set<DiagnosticSinkID> = []
        var lanes: [DiagnosticSinkLane] = []
        lanes.reserveCapacity(min(registrations.count, configuration.maximumSinkCount))
        var rejectedCount = 0

        for registration in registrations {
            guard lanes.count < configuration.maximumSinkCount,
                  identifiers.insert(registration.id).inserted
            else {
                rejectedCount += 1
                continue
            }
            let effectiveRegistration = DiagnosticSinkRegistration(
                id: registration.id,
                sink: registration.sink,
                maximumOutstandingRecords: min(
                    registration.maximumOutstandingRecords,
                    configuration.maximumPendingRecordsPerSink))
            lanes.append(
                DiagnosticSinkLane(
                    registration: effectiveRegistration,
                    maximumBarrierWaiters: configuration.maximumBarrierWaitersPerSink))
        }
        return (lanes, rejectedCount)
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
    static func write(
        _ data: Data,
        to destination: URL,
        testingBeforeCommit: (() throws -> Void)? = nil
    ) throws {
        // `file://remote-host/path` still reports `isFileURL == true`, while
        // Foundation and Darwin path access silently target the local `path`.
        // Refuse that authority collapse before inspecting or creating any
        // filesystem object.
        guard BoundedRegularFileReader.hasLocalFileAuthority(destination) else {
            throw DiagnosticsError.destinationDirectoryUnavailable
        }
        let destination = destination.standardizedFileURL
        let directory = destination.deletingLastPathComponent()
        let destinationName = destination.lastPathComponent
        guard isValidLeafName(destinationName) else {
            throw DiagnosticsError.destinationDirectoryUnavailable
        }
        let directoryDescriptor = try openStableDirectory(directory)
        defer { Darwin.close(directoryDescriptor) }

        let temporaryName = ".markdev-diagnostics-\(UUID().uuidString).tmp"
        let descriptor = temporaryName.withCString { name in
            Darwin.openat(
                directoryDescriptor,
                name,
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
                temporaryName.withCString { name in
                    _ = Darwin.unlinkat(directoryDescriptor, name, 0)
                }
            }
        }

        try writeAll(data, descriptor: descriptor)
        guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try testingBeforeCommit?()
        guard directoryIsStillBound(directory, descriptor: directoryDescriptor),
              regularNameIsBound(
                temporaryName,
                directoryDescriptor: directoryDescriptor,
                descriptor: descriptor)
        else {
            throw POSIXError(.EIO)
        }

        let renameResult = temporaryName.withCString { source in
            destinationName.withCString { target in
                Darwin.renameat(
                    directoryDescriptor,
                    source,
                    directoryDescriptor,
                    target)
            }
        }
        guard renameResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        renamed = true
        guard directoryIsStillBound(directory, descriptor: directoryDescriptor),
              regularNameIsBound(
                destinationName,
                directoryDescriptor: directoryDescriptor,
                descriptor: descriptor)
        else {
            throw POSIXError(.EIO)
        }
        guard Darwin.fsync(directoryDescriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func syncDirectory(_ directory: URL) throws {
        guard BoundedRegularFileReader.hasLocalFileAuthority(directory) else {
            throw DiagnosticsError.destinationDirectoryUnavailable
        }
        let directory = directory.standardizedFileURL
        let directoryDescriptor = try openStableDirectory(directory)
        defer { Darwin.close(directoryDescriptor) }

        guard Darwin.fsync(directoryDescriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func openStableDirectory(_ directory: URL) throws -> Int32 {
        let descriptor = directory.path.withCString { path in
            Darwin.open(
                path,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            throw DiagnosticsError.destinationDirectoryUnavailable
        }
        guard directoryIsStillBound(directory, descriptor: descriptor) else {
            _ = Darwin.close(descriptor)
            throw DiagnosticsError.destinationDirectoryUnavailable
        }
        return descriptor
    }

    private static func directoryIsStillBound(
        _ directory: URL,
        descriptor: Int32
    ) -> Bool {
        var held = stat()
        var named = stat()
        guard Darwin.fstat(descriptor, &held) == 0,
              directory.path.withCString({ Darwin.lstat($0, &named) }) == 0
        else { return false }
        return held.st_mode & S_IFMT == S_IFDIR
            && named.st_mode & S_IFMT == S_IFDIR
            && held.st_dev == named.st_dev
            && held.st_ino == named.st_ino
    }

    private static func regularNameIsBound(
        _ name: String,
        directoryDescriptor: Int32,
        descriptor: Int32
    ) -> Bool {
        var held = stat()
        var named = stat()
        guard Darwin.fstat(descriptor, &held) == 0,
              name.withCString({
                  Darwin.fstatat(
                      directoryDescriptor,
                      $0,
                      &named,
                      AT_SYMLINK_NOFOLLOW)
              }) == 0
        else { return false }
        return held.st_mode & S_IFMT == S_IFREG
            && named.st_mode & S_IFMT == S_IFREG
            && held.st_nlink == 1
            && named.st_nlink == 1
            && held.st_dev == named.st_dev
            && held.st_ino == named.st_ino
    }

    private static func isValidLeafName(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && value.utf8.count <= Int(MAXNAMLEN)
            && !value.utf8.contains(0)
            && !value.contains("/")
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
