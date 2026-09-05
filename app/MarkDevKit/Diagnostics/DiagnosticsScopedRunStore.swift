//
//  DiagnosticsScopedRunStore.swift
//  MarkDevKit
//
//  Globally bounded v2 run retention through retained directory descriptors.
//

import Darwin
import Foundation

private let diagnosticsPrivateDirectoryMode: mode_t = S_IRWXU
private let diagnosticsPrivateFileMode: mode_t = S_IRUSR | S_IWUSR

private func diagnosticsFileLock(_ descriptor: Int32, _ operation: Int32) -> Int32 {
    flock(descriptor, operation)
}

enum DiagnosticsScopedRunStoreError: Error, Equatable {
    case untrustedOrigin
    case pathIsNotDirectory
    case untrustedFilesystemObject
    case filesystemChanged
    case retentionLockUnavailable
    case retentionCapacityUnavailable(limit: Int)
    case runDirectoryCollision
}

enum DiagnosticsScopedRunStoreMutationStage: Equatable {
    case candidateRenamed
    case retirementRenameSynced
    case childUnlinked(String)
    case activeLockUnlinked
    case runDirectorySynced
    case retiredDirectoryRemoved
    case retirementRemovalSynced
}

struct DiagnosticsScopedRunStoreTestingHooks: @unchecked Sendable {
    var beforeCandidateRetirement: ((URL) -> Void)?
    var afterMutation: ((DiagnosticsScopedRunStoreMutationStage) throws -> Void)?

    init(
        beforeCandidateRetirement: ((URL) -> Void)? = nil,
        afterMutation: ((DiagnosticsScopedRunStoreMutationStage) throws -> Void)? = nil
    ) {
        self.beforeCandidateRetirement = beforeCandidateRetirement
        self.afterMutation = afterMutation
    }

    static let none = Self()
}

struct DiagnosticsHistoryInspectionLimits: Equatable, Sendable {
    static let production = Self()

    let maximumRootEntries: Int
    let maximumRuns: Int
    let maximumEntriesPerRun: Int
    let maximumFiles: Int
    let maximumBytesPerFile: Int
    let maximumInspectedBytes: Int
    let maximumInspectedEvents: Int
    let maximumIncludedEvents: Int
    let maximumOutputBytes: Int

    init(
        maximumRootEntries: Int = 4_096,
        maximumRuns: Int = 32,
        maximumEntriesPerRun: Int = 96,
        maximumFiles: Int = 256,
        maximumBytesPerFile: Int = 8 * 1_024 * 1_024,
        maximumInspectedBytes: Int = 32 * 1_024 * 1_024,
        maximumInspectedEvents: Int = 100_000,
        maximumIncludedEvents: Int = 50_000,
        maximumOutputBytes: Int = 16 * 1_024 * 1_024
    ) {
        self.maximumRootEntries = min(max(1, maximumRootEntries), 4_096)
        self.maximumRuns = min(max(1, maximumRuns), 32)
        self.maximumEntriesPerRun = min(max(1, maximumEntriesPerRun), 1_024)
        self.maximumFiles = min(max(1, maximumFiles), 1_024)
        self.maximumBytesPerFile = min(
            max(1, maximumBytesPerFile),
            RotatingDiagnosticsFileConfiguration.largestSupportedFile)
        self.maximumInspectedBytes = min(
            max(1, maximumInspectedBytes),
            128 * 1_024 * 1_024)
        self.maximumInspectedEvents = min(max(1, maximumInspectedEvents), 250_000)
        self.maximumIncludedEvents = min(
            max(1, maximumIncludedEvents),
            self.maximumInspectedEvents)
        self.maximumOutputBytes = min(max(1, maximumOutputBytes), 64 * 1_024 * 1_024)
    }
}

struct DiagnosticsHistoryTestingHooks: @unchecked Sendable {
    var beforeOpeningRun: ((URL) -> Void)?
    var beforeReadingFile: ((URL) -> Void)?

    init(
        beforeOpeningRun: ((URL) -> Void)? = nil,
        beforeReadingFile: ((URL) -> Void)? = nil
    ) {
        self.beforeOpeningRun = beforeOpeningRun
        self.beforeReadingFile = beforeReadingFile
    }

    static let none = Self()
}

final class DiagnosticsRunLease: @unchecked Sendable {
    let directory: URL

    private let lock = NSLock()
    private var activeLockDescriptor: Int32?
    private var runDescriptor: Int32?
    private var directoryChain: DiagnosticsTrustedDirectoryChain?
    private let runName: String
    private let runIdentity: LocalFileIdentity

    fileprivate init(
        directory: URL,
        activeLockDescriptor: Int32,
        runDescriptor: Int32,
        directoryChain: DiagnosticsTrustedDirectoryChain,
        runName: String,
        runIdentity: LocalFileIdentity
    ) {
        self.directory = directory
        self.activeLockDescriptor = activeLockDescriptor
        self.runDescriptor = runDescriptor
        self.directoryChain = directoryChain
        self.runName = runName
        self.runIdentity = runIdentity
    }

    deinit {
        release()
    }

    fileprivate func revalidate() throws {
        lock.lock()
        defer { lock.unlock() }
        guard let activeLockDescriptor, let runDescriptor, let directoryChain else {
            throw DiagnosticsScopedRunStoreError.filesystemChanged
        }
        try directoryChain.revalidate()
        guard DiagnosticsScopedRunStore.isTrustedDirectoryDescriptor(
            runDescriptor,
            expectedIdentity: runIdentity),
            DiagnosticsScopedRunStore.isDirectoryNameBound(
                parentDescriptor: directoryChain.leafDescriptor,
                name: runName,
                expectedIdentity: runIdentity),
            DiagnosticsScopedRunStore.isTrustedRegularDescriptor(
                activeLockDescriptor,
                expectedIdentity: nil),
            DiagnosticsScopedRunStore.isRegularNameBound(
                parentDescriptor: runDescriptor,
                name: ".active.lock",
                descriptor: activeLockDescriptor)
        else {
            throw DiagnosticsScopedRunStoreError.filesystemChanged
        }
    }

    func release() {
        let releasedActiveLock: Int32?
        let releasedRun: Int32?
        let releasedChain: DiagnosticsTrustedDirectoryChain?
        lock.lock()
        releasedActiveLock = activeLockDescriptor
        activeLockDescriptor = nil
        releasedRun = runDescriptor
        runDescriptor = nil
        releasedChain = directoryChain
        directoryChain = nil
        lock.unlock()

        if let releasedActiveLock {
            _ = diagnosticsFileLock(releasedActiveLock, LOCK_UN)
            _ = Darwin.close(releasedActiveLock)
        }
        if let releasedRun {
            _ = Darwin.close(releasedRun)
        }
        withExtendedLifetime(releasedChain) {}
    }
}

private struct LeasedRotatingDiagnosticsSink: DiagnosticSink {
    let sink: RotatingJSONLDiagnosticsSink
    let lease: DiagnosticsRunLease

    func write(_ record: DiagnosticRecord) async throws {
        try lease.revalidate()
        try await sink.write(record)
        try lease.revalidate()
    }
}

private struct DiagnosticsDirectoryFingerprint: Equatable {
    let identity: LocalFileIdentity
    let ownerID: uid_t
    let mode: mode_t

    init(_ status: stat) {
        identity = LocalFileIdentity(status)
        ownerID = status.st_uid
        mode = status.st_mode & mode_t(0o7777)
    }
}

private struct DiagnosticsRegularFileFingerprint: Equatable {
    let identity: LocalFileIdentity
    let ownerID: uid_t
    let mode: mode_t
    let linkCount: UInt64
    let size: Int64
    let flags: UInt32
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    init(_ status: stat) {
        identity = LocalFileIdentity(status)
        ownerID = status.st_uid
        mode = status.st_mode & mode_t(0o7777)
        linkCount = UInt64(status.st_nlink)
        size = Int64(status.st_size)
        flags = status.st_flags
        modifiedSeconds = Int64(status.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(status.st_mtimespec.tv_nsec)
        changedSeconds = Int64(status.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(status.st_ctimespec.tv_nsec)
    }
}

private struct DiagnosticsHistoryDirectoryFingerprint: Equatable {
    let identity: LocalFileIdentity
    let ownerID: uid_t
    let mode: mode_t
    let linkCount: UInt64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    init(_ status: stat) {
        identity = LocalFileIdentity(status)
        ownerID = status.st_uid
        mode = status.st_mode & mode_t(0o7777)
        linkCount = UInt64(status.st_nlink)
        modifiedSeconds = Int64(status.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(status.st_mtimespec.tv_nsec)
        changedSeconds = Int64(status.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(status.st_ctimespec.tv_nsec)
    }
}

fileprivate final class DiagnosticsTrustedDirectoryChain {
    struct Node {
        let descriptor: Int32
        let url: URL
        let componentFromParent: String?
        let fingerprint: DiagnosticsDirectoryFingerprint
        let requiresPrivateMode: Bool
    }

    private let nodes: [Node]

    init(nodes: [Node]) {
        precondition(!nodes.isEmpty)
        self.nodes = nodes
    }

    deinit {
        for node in nodes.reversed() {
            _ = Darwin.close(node.descriptor)
        }
    }

    var leafDescriptor: Int32 { nodes[nodes.count - 1].descriptor }
    var leafURL: URL { nodes[nodes.count - 1].url }

    func revalidate() throws {
        for (index, node) in nodes.enumerated() {
            var held = stat()
            guard DiagnosticsScopedRunStore.retrying({ Darwin.fstat(node.descriptor, &held) }) == 0,
                  DiagnosticsScopedRunStore.isTrustedDirectoryStatus(
                    held,
                    requiresPrivateMode: node.requiresPrivateMode),
                  DiagnosticsDirectoryFingerprint(held) == node.fingerprint
            else {
                throw DiagnosticsScopedRunStoreError.filesystemChanged
            }

            if index == 0 {
                guard DiagnosticsScopedRunStore.actualURL(for: node.descriptor)?.standardizedFileURL
                    == node.url.standardizedFileURL
                else {
                    throw DiagnosticsScopedRunStoreError.filesystemChanged
                }
                continue
            }

            let parent = nodes[index - 1]
            guard let component = node.componentFromParent,
                  DiagnosticsScopedRunStore.isDirectoryNameBound(
                    parentDescriptor: parent.descriptor,
                    name: component,
                    expectedIdentity: node.fingerprint.identity)
            else {
                throw DiagnosticsScopedRunStoreError.filesystemChanged
            }
        }
    }
}

enum DiagnosticsScopedRunStore {
    static let maximumRetainedRuns = 8
    static let largestSupportedRetainedRunLimit = 32

    private static let maximumDirectoryEntriesToInspect = 4_096
    private static let maximumOwnedEntriesPerRun =
        RotatingDiagnosticsFileConfiguration.largestSupportedFileCount + 32
    private static let ownedDirectoryComponents = ["MarkDev", "Diagnostics", "v2", "runs"]

    private struct HistoryEnumeration {
        let names: [String]
        let hasUnknownRemainder: Bool
    }

    private struct HistoryCollectedEvent {
        let ordinal: Int
        let sourceByteCount: Int
        let event: DiagnosticEvent
    }

    private struct HistoryCollectedRun {
        let origin: DiagnosticOrigin
        var events: [HistoryCollectedEvent]
    }

    private struct HistoryInspectionAccumulator {
        var inspectedRootEntryCount = 0
        var uninspectedRootEntryCount: Int? = 0

        var includedRunCount = 0
        var omittedRunCount = 0
        var knownUninspectedRunCount = 0
        var hasUnknownUninspectedRuns = false

        var includedFileCount = 0
        var omittedFileCount = 0
        var knownUninspectedFileCount = 0
        var hasUnknownUninspectedFiles = false

        var inspectedByteCount = 0
        var knownUninspectedByteCount = 0
        var hasUnknownUninspectedBytes = false

        var inspectedEventCount = 0
        var knownUninspectedEventCount = 0
        var hasUnknownUninspectedEvents = false

        var collectedRuns: [HistoryCollectedRun] = []
        var collectedEventCount = 0

        mutating func markRunContentsUnknown() {
            hasUnknownUninspectedFiles = true
            hasUnknownUninspectedBytes = true
            hasUnknownUninspectedEvents = true
        }

        mutating func markFileContentsUnknown(knownByteCount: Int? = nil) {
            if let knownByteCount {
                knownUninspectedByteCount = Self.saturatingAdd(
                    knownUninspectedByteCount,
                    knownByteCount)
            } else {
                hasUnknownUninspectedBytes = true
            }
            hasUnknownUninspectedEvents = true
        }

        func inspection(
            includedEventCount: Int,
            includedByteCount: Int
        ) -> DiagnosticHistoryInspection {
            DiagnosticHistoryInspection(
                inspectedRootEntryCount: inspectedRootEntryCount,
                uninspectedRootEntryCount: uninspectedRootEntryCount,
                runs: DiagnosticHistoryDimensionCounts(
                    inspected: Self.saturatingAdd(includedRunCount, omittedRunCount),
                    included: includedRunCount,
                    omitted: omittedRunCount,
                    uninspected: hasUnknownUninspectedRuns
                        ? nil
                        : knownUninspectedRunCount),
                files: DiagnosticHistoryDimensionCounts(
                    inspected: Self.saturatingAdd(includedFileCount, omittedFileCount),
                    included: includedFileCount,
                    omitted: omittedFileCount,
                    uninspected: hasUnknownUninspectedFiles
                        ? nil
                        : knownUninspectedFileCount),
                bytes: DiagnosticHistoryDimensionCounts(
                    inspected: inspectedByteCount,
                    included: includedByteCount,
                    omitted: max(0, inspectedByteCount - includedByteCount),
                    uninspected: hasUnknownUninspectedBytes
                        ? nil
                        : knownUninspectedByteCount),
                events: DiagnosticHistoryDimensionCounts(
                    inspected: inspectedEventCount,
                    included: includedEventCount,
                    omitted: max(0, inspectedEventCount - includedEventCount),
                    uninspected: hasUnknownUninspectedEvents
                        ? nil
                        : knownUninspectedEventCount))
        }

        private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
            let (result, overflow) = lhs.addingReportingOverflow(rhs)
            return overflow ? Int.max : result
        }
    }

    private struct HistoryReportMaterial {
        let report: DiagnosticHistoryReport
        let data: Data
    }

    static func makeSink(
        applicationSupportDirectory: URL,
        origin: DiagnosticOrigin,
        maximumFileBytes: Int,
        maximumFiles: Int
    ) throws -> any DiagnosticSink {
        let lease = try acquire(
            applicationSupportDirectory: applicationSupportDirectory,
            origin: origin,
            maximumRetainedRuns: maximumRetainedRuns)
        do {
            try lease.revalidate()
            let sink = try RotatingJSONLDiagnosticsSink(
                configuration: RotatingDiagnosticsFileConfiguration(
                    directory: lease.directory,
                    baseName: "events",
                    maximumFileBytes: maximumFileBytes,
                    maximumFiles: maximumFiles),
                requiredOrigin: origin)
            try lease.revalidate()
            return LeasedRotatingDiagnosticsSink(sink: sink, lease: lease)
        } catch {
            lease.release()
            throw error
        }
    }

    static func historyReport(
        applicationSupportDirectory: URL,
        generatedAtMilliseconds: Int64? = nil,
        limits: DiagnosticsHistoryInspectionLimits = .production,
        testingHooks: DiagnosticsHistoryTestingHooks = .none
    ) throws -> DiagnosticHistoryReport {
        try historyReportMaterial(
            applicationSupportDirectory: applicationSupportDirectory,
            generatedAtMilliseconds: generatedAtMilliseconds,
            limits: limits,
            testingHooks: testingHooks).report
    }

    static func exportHistoryReport(
        applicationSupportDirectory: URL,
        to destination: URL,
        generatedAtMilliseconds: Int64? = nil,
        limits: DiagnosticsHistoryInspectionLimits = .production,
        testingHooks: DiagnosticsHistoryTestingHooks = .none
    ) throws -> DiagnosticHistoryExportSummary {
        let material = try historyReportMaterial(
            applicationSupportDirectory: applicationSupportDirectory,
            generatedAtMilliseconds: generatedAtMilliseconds,
            limits: limits,
            testingHooks: testingHooks)
        try SecureAtomicDiagnosticsFile.write(material.data, to: destination)
        return DiagnosticHistoryExportSummary(
            byteCount: material.data.count,
            inspection: material.report.inspection)
    }

    private static func historyReportMaterial(
        applicationSupportDirectory: URL,
        generatedAtMilliseconds: Int64?,
        limits: DiagnosticsHistoryInspectionLimits,
        testingHooks: DiagnosticsHistoryTestingHooks
    ) throws -> HistoryReportMaterial {
        try checkHistoryCancellation()
        var accumulator = HistoryInspectionAccumulator()
        guard let chain = try openExistingOwnedDirectoryChain(
            applicationSupportDirectory: applicationSupportDirectory)
        else {
            return try encodeHistoryReport(
                accumulator: accumulator,
                generatedAtMilliseconds: historyTimestamp(generatedAtMilliseconds),
                maximumOutputBytes: limits.maximumOutputBytes)
        }
        try chain.revalidate()

        let retentionLock = try openTrustedRegularChild(
            parentDescriptor: chain.leafDescriptor,
            name: ".retention.lock",
            createIfMissing: false)
        guard diagnosticsFileLock(retentionLock.descriptor, LOCK_SH | LOCK_NB) == 0 else {
            let code = errno
            _ = Darwin.close(retentionLock.descriptor)
            if code == EWOULDBLOCK || code == EAGAIN {
                throw DiagnosticsScopedRunStoreError.retentionLockUnavailable
            }
            throw posixError(code)
        }
        defer {
            _ = diagnosticsFileLock(retentionLock.descriptor, LOCK_UN)
            _ = Darwin.close(retentionLock.descriptor)
        }
        guard isRegularNameBound(
            parentDescriptor: chain.leafDescriptor,
            name: retentionLock.name,
            descriptor: retentionLock.descriptor)
        else {
            throw DiagnosticsScopedRunStoreError.filesystemChanged
        }

        let rootFingerprint = try historyDirectoryFingerprint(
            descriptor: chain.leafDescriptor)
        let rootEntries = try historyDirectoryEntryNames(
            descriptor: chain.leafDescriptor,
            maximumNames: limits.maximumRootEntries,
            expectedFingerprint: rootFingerprint)
        accumulator.inspectedRootEntryCount = rootEntries.names.count
        accumulator.uninspectedRootEntryCount = rootEntries.hasUnknownRemainder ? nil : 0

        let runNames = rootEntries.names.filter { parseRunOrigin(from: $0) != nil }.sorted()
        let inspectedRunNames = Array(runNames.prefix(limits.maximumRuns))
        if rootEntries.hasUnknownRemainder {
            accumulator.hasUnknownUninspectedRuns = true
        } else {
            accumulator.knownUninspectedRunCount = runNames.count - inspectedRunNames.count
        }
        if runNames.count > inspectedRunNames.count || rootEntries.hasUnknownRemainder {
            accumulator.markRunContentsUnknown()
        }

        var remainingFileInspections = limits.maximumFiles
        for runName in inspectedRunNames {
            try checkHistoryCancellation()
            try inspectHistoryRun(
                named: runName,
                chain: chain,
                rootFingerprint: rootFingerprint,
                retentionLock: retentionLock,
                remainingFileInspections: &remainingFileInspections,
                limits: limits,
                testingHooks: testingHooks,
                accumulator: &accumulator)
        }

        try chain.revalidate()
        guard try historyDirectoryFingerprint(descriptor: chain.leafDescriptor) == rootFingerprint,
              isRegularNameBound(
                parentDescriptor: chain.leafDescriptor,
                name: retentionLock.name,
                descriptor: retentionLock.descriptor)
        else {
            throw DiagnosticsScopedRunStoreError.filesystemChanged
        }
        return try encodeHistoryReport(
            accumulator: accumulator,
            generatedAtMilliseconds: historyTimestamp(generatedAtMilliseconds),
            maximumOutputBytes: limits.maximumOutputBytes)
    }

    private static func inspectHistoryRun(
        named runName: String,
        chain: DiagnosticsTrustedDirectoryChain,
        rootFingerprint: DiagnosticsHistoryDirectoryFingerprint,
        retentionLock: TrustedRegularChild,
        remainingFileInspections: inout Int,
        limits: DiagnosticsHistoryInspectionLimits,
        testingHooks: DiagnosticsHistoryTestingHooks,
        accumulator: inout HistoryInspectionAccumulator
    ) throws {
        guard let origin = parseRunOrigin(from: runName),
              let initialStatus = try entryStatus(
                parentDescriptor: chain.leafDescriptor,
                name: runName),
              isTrustedDirectoryStatus(initialStatus, requiresPrivateMode: true)
        else {
            accumulator.omittedRunCount += 1
            accumulator.markRunContentsUnknown()
            return
        }
        let expectedIdentity = LocalFileIdentity(initialStatus)
        testingHooks.beforeOpeningRun?(
            chain.leafURL.appendingPathComponent(runName, isDirectory: true))
        let runDescriptor: Int32
        do {
            runDescriptor = try openDirectory(
                parentDescriptor: chain.leafDescriptor,
                name: runName)
        } catch {
            throw DiagnosticsScopedRunStoreError.filesystemChanged
        }
        defer { _ = Darwin.close(runDescriptor) }
        guard isTrustedDirectoryDescriptor(
                runDescriptor,
                expectedIdentity: expectedIdentity),
              isDirectoryNameBound(
                parentDescriptor: chain.leafDescriptor,
                name: runName,
                expectedIdentity: expectedIdentity),
              try historyDirectoryFingerprint(descriptor: chain.leafDescriptor) == rootFingerprint,
              isRegularNameBound(
                parentDescriptor: chain.leafDescriptor,
                name: retentionLock.name,
                descriptor: retentionLock.descriptor)
        else {
            throw DiagnosticsScopedRunStoreError.filesystemChanged
        }

        let activeLock: TrustedRegularChild
        do {
            activeLock = try openTrustedRegularChild(
                parentDescriptor: runDescriptor,
                name: ".active.lock",
                createIfMissing: false)
        } catch {
            accumulator.omittedRunCount += 1
            accumulator.markRunContentsUnknown()
            return
        }
        guard diagnosticsFileLock(activeLock.descriptor, LOCK_SH | LOCK_NB) == 0 else {
            let code = errno
            _ = Darwin.close(activeLock.descriptor)
            if code == EWOULDBLOCK || code == EAGAIN {
                accumulator.omittedRunCount += 1
                accumulator.markRunContentsUnknown()
                return
            }
            throw posixError(code)
        }
        defer {
            _ = diagnosticsFileLock(activeLock.descriptor, LOCK_UN)
            _ = Darwin.close(activeLock.descriptor)
        }
        guard isRegularNameBound(
            parentDescriptor: runDescriptor,
            name: activeLock.name,
            descriptor: activeLock.descriptor)
        else {
            throw DiagnosticsScopedRunStoreError.filesystemChanged
        }
        let expectedFingerprint = try historyDirectoryFingerprint(descriptor: runDescriptor)

        let runEntries = try historyDirectoryEntryNames(
            descriptor: runDescriptor,
            maximumNames: limits.maximumEntriesPerRun,
            expectedFingerprint: expectedFingerprint)
        guard runEntries.names.contains(".active.lock") else {
            throw DiagnosticsScopedRunStoreError.filesystemChanged
        }

        accumulator.includedRunCount += 1
        accumulator.collectedRuns.append(HistoryCollectedRun(origin: origin, events: []))
        let collectedRunIndex = accumulator.collectedRuns.count - 1

        let allEventNames = runEntries.names.filter(isHistoryEventFileName).sorted {
            let left = historyEventGeneration($0)
            let right = historyEventGeneration($1)
            switch (left, right) {
            case let (.some(lhs), .some(rhs)) where lhs != rhs:
                return lhs > rhs
            default:
                return $0 < $1
            }
        }
        let inspectedFileNames = Array(allEventNames.prefix(remainingFileInspections))
        remainingFileInspections -= inspectedFileNames.count
        if runEntries.hasUnknownRemainder {
            accumulator.hasUnknownUninspectedFiles = true
            accumulator.hasUnknownUninspectedBytes = true
            accumulator.hasUnknownUninspectedEvents = true
        } else if allEventNames.count > inspectedFileNames.count {
            accumulator.knownUninspectedFileCount += allEventNames.count - inspectedFileNames.count
            accumulator.hasUnknownUninspectedBytes = true
            accumulator.hasUnknownUninspectedEvents = true
        }

        for fileName in inspectedFileNames {
            try checkHistoryCancellation()
            try inspectHistoryEventFile(
                named: fileName,
                origin: origin,
                runDescriptor: runDescriptor,
                runName: runName,
                runFingerprint: expectedFingerprint,
                chain: chain,
                rootFingerprint: rootFingerprint,
                retentionLock: retentionLock,
                activeLock: activeLock,
                collectedRunIndex: collectedRunIndex,
                limits: limits,
                testingHooks: testingHooks,
                accumulator: &accumulator)
        }
    }

    private static func inspectHistoryEventFile(
        named fileName: String,
        origin: DiagnosticOrigin,
        runDescriptor: Int32,
        runName: String,
        runFingerprint: DiagnosticsHistoryDirectoryFingerprint,
        chain: DiagnosticsTrustedDirectoryChain,
        rootFingerprint: DiagnosticsHistoryDirectoryFingerprint,
        retentionLock: TrustedRegularChild,
        activeLock: TrustedRegularChild,
        collectedRunIndex: Int,
        limits: DiagnosticsHistoryInspectionLimits,
        testingHooks: DiagnosticsHistoryTestingHooks,
        accumulator: inout HistoryInspectionAccumulator
    ) throws {
        accumulator.omittedFileCount += 1
        guard historyEventGeneration(fileName) != nil,
              let status = try entryStatus(parentDescriptor: runDescriptor, name: fileName),
              isTrustedRegularStatus(status)
        else {
            accumulator.markFileContentsUnknown()
            return
        }
        let expectedFingerprint = DiagnosticsRegularFileFingerprint(status)
        guard expectedFingerprint.size >= 0,
              expectedFingerprint.size <= Int64(Int.max)
        else {
            accumulator.markFileContentsUnknown()
            return
        }
        let fileByteCount = Int(expectedFingerprint.size)
        let remainingByteCapacity = max(
            0,
            limits.maximumInspectedBytes - accumulator.inspectedByteCount)
        guard fileByteCount <= limits.maximumBytesPerFile,
              fileByteCount <= remainingByteCapacity
        else {
            accumulator.markFileContentsUnknown(knownByteCount: fileByteCount)
            return
        }
        let remainingEventInspections = max(
            0,
            limits.maximumInspectedEvents - accumulator.inspectedEventCount)
        guard remainingEventInspections > 0 else {
            accumulator.markFileContentsUnknown(knownByteCount: fileByteCount)
            return
        }

        testingHooks.beforeReadingFile?(
            chain.leafURL
                .appendingPathComponent(runName, isDirectory: true)
                .appendingPathComponent(fileName, isDirectory: false))
        let child: TrustedRegularChild
        do {
            child = try openReadOnlyTrustedRegularChild(
                parentDescriptor: runDescriptor,
                name: fileName,
                expectedFingerprint: expectedFingerprint)
        } catch {
            throw DiagnosticsScopedRunStoreError.filesystemChanged
        }
        defer { _ = Darwin.close(child.descriptor) }

        let data = try readHistoryData(
            descriptor: child.descriptor,
            expectedByteCount: fileByteCount)
        accumulator.inspectedByteCount += data.count
        let parsed = parseHistoryEventFile(
            data,
            requiredOrigin: origin,
            maximumRecords: remainingEventInspections)
        accumulator.inspectedEventCount += parsed.recordCount

        try chain.revalidate()
        guard isRegularNameBound(
            parentDescriptor: runDescriptor,
            name: fileName,
            descriptor: child.descriptor),
              try regularFileFingerprint(descriptor: child.descriptor) == expectedFingerprint,
              try historyDirectoryFingerprint(descriptor: runDescriptor) == runFingerprint,
              isDirectoryNameBound(
                parentDescriptor: chain.leafDescriptor,
                name: runName,
                expectedIdentity: runFingerprint.identity),
              try historyDirectoryFingerprint(descriptor: chain.leafDescriptor) == rootFingerprint,
              isRegularNameBound(
                parentDescriptor: chain.leafDescriptor,
                name: retentionLock.name,
                descriptor: retentionLock.descriptor),
              isRegularNameBound(
                parentDescriptor: runDescriptor,
                name: activeLock.name,
                descriptor: activeLock.descriptor)
        else {
            throw DiagnosticsScopedRunStoreError.filesystemChanged
        }

        guard parsed.isValid else {
            if parsed.hasUnknownEventCount {
                accumulator.hasUnknownUninspectedEvents = true
            }
            return
        }

        accumulator.omittedFileCount -= 1
        accumulator.includedFileCount += 1
        for parsedEvent in parsed.events {
            guard accumulator.collectedEventCount < limits.maximumIncludedEvents else {
                continue
            }
            let ordinal = accumulator.collectedEventCount
            accumulator.collectedEventCount += 1
            accumulator.collectedRuns[collectedRunIndex].events.append(
                HistoryCollectedEvent(
                    ordinal: ordinal,
                    sourceByteCount: parsedEvent.sourceByteCount,
                    event: parsedEvent.event))
        }
    }

    private static func encodeHistoryReport(
        accumulator: HistoryInspectionAccumulator,
        generatedAtMilliseconds: Int64,
        maximumOutputBytes: Int
    ) throws -> HistoryReportMaterial {
        func encode(omittingEventPrefix omittedPrefix: Int) throws -> HistoryReportMaterial {
            var includedByteCount = 0
            let runs = accumulator.collectedRuns.map { collectedRun in
                let events = collectedRun.events.compactMap { item -> DiagnosticEvent? in
                    guard item.ordinal >= omittedPrefix else { return nil }
                    includedByteCount += item.sourceByteCount
                    return item.event
                }
                return DiagnosticHistoryRun(origin: collectedRun.origin, events: events)
            }
            let includedEventCount = accumulator.collectedEventCount - omittedPrefix
            let inspection = accumulator.inspection(
                includedEventCount: includedEventCount,
                includedByteCount: includedByteCount)
            let report = DiagnosticHistoryReport(
                generatedAtMilliseconds: generatedAtMilliseconds,
                inspection: inspection,
                runs: runs)
            return HistoryReportMaterial(
                report: report,
                data: try DiagnosticsJSON.data(for: report))
        }

        let complete = try encode(omittingEventPrefix: 0)
        if complete.data.count <= maximumOutputBytes { return complete }

        var lowerBound = 1
        var upperBound = accumulator.collectedEventCount
        var smallestFitting: HistoryReportMaterial?
        while lowerBound <= upperBound {
            let midpoint = lowerBound + (upperBound - lowerBound) / 2
            let candidate = try encode(omittingEventPrefix: midpoint)
            if candidate.data.count <= maximumOutputBytes {
                smallestFitting = candidate
                upperBound = midpoint - 1
            } else {
                lowerBound = midpoint + 1
            }
        }
        guard let smallestFitting else {
            throw DiagnosticsError.reportExceedsByteLimit(limit: maximumOutputBytes)
        }
        return smallestFitting
    }

    private struct ParsedHistoryEventFile {
        struct Event {
            let sourceByteCount: Int
            let event: DiagnosticEvent
        }

        let isValid: Bool
        let recordCount: Int
        let hasUnknownEventCount: Bool
        let events: [Event]
    }

    private static func parseHistoryEventFile(
        _ data: Data,
        requiredOrigin: DiagnosticOrigin,
        maximumRecords: Int
    ) -> ParsedHistoryEventFile {
        guard !data.isEmpty else {
            return ParsedHistoryEventFile(
                isValid: true,
                recordCount: 0,
                hasUnknownEventCount: false,
                events: [])
        }
        var events: [ParsedHistoryEventFile.Event] = []
        var recordCount = 0
        var isValid = true
        var hasUnknownEventCount = false
        var start = data.startIndex
        while start < data.endIndex {
            guard recordCount < maximumRecords else {
                isValid = false
                hasUnknownEventCount = true
                break
            }
            guard let newline = data[start...].firstIndex(of: 0x0A) else {
                recordCount += 1
                isValid = false
                hasUnknownEventCount = true
                break
            }
            recordCount += 1
            let afterNewline = data.index(after: newline)
            let line = data[start..<newline]
            if line.isEmpty {
                isValid = false
            } else if let event = try? JSONDecoder().decode(
                DiagnosticEvent.self,
                from: Data(line)),
                event.origin == requiredOrigin
            {
                events.append(ParsedHistoryEventFile.Event(
                    sourceByteCount: data.distance(from: start, to: afterNewline),
                    event: event))
            } else {
                isValid = false
            }
            start = afterNewline
        }
        return ParsedHistoryEventFile(
            isValid: isValid,
            recordCount: recordCount,
            hasUnknownEventCount: hasUnknownEventCount,
            events: isValid ? events : [])
    }

    private static func historyTimestamp(_ injected: Int64?) -> Int64 {
        injected ?? Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
    }

    private static func checkHistoryCancellation() throws {
        if Task.isCancelled { throw CancellationError() }
    }

    static func acquire(
        applicationSupportDirectory: URL,
        origin: DiagnosticOrigin,
        maximumRetainedRuns requestedLimit: Int = maximumRetainedRuns,
        testingHooks: DiagnosticsScopedRunStoreTestingHooks = .none
    ) throws -> DiagnosticsRunLease {
        guard origin.isTrustedProduction else {
            throw DiagnosticsScopedRunStoreError.untrustedOrigin
        }
        let maximumRetainedRuns = min(
            max(1, requestedLimit),
            largestSupportedRetainedRunLimit)
        let chain = try prepareOwnedDirectoryChain(
            applicationSupportDirectory: applicationSupportDirectory)
        try chain.revalidate()

        let retentionLock = try openTrustedRegularChild(
            parentDescriptor: chain.leafDescriptor,
            name: ".retention.lock",
            createIfMissing: true)
        guard diagnosticsFileLock(retentionLock.descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            _ = Darwin.close(retentionLock.descriptor)
            if code == EWOULDBLOCK || code == EAGAIN {
                throw DiagnosticsScopedRunStoreError.retentionLockUnavailable
            }
            throw posixError(code)
        }
        defer {
            _ = diagnosticsFileLock(retentionLock.descriptor, LOCK_UN)
            _ = Darwin.close(retentionLock.descriptor)
        }

        try chain.revalidate()
        guard isRegularNameBound(
            parentDescriptor: chain.leafDescriptor,
            name: retentionLock.name,
            descriptor: retentionLock.descriptor)
        else {
            throw DiagnosticsScopedRunStoreError.filesystemChanged
        }

        var candidates = try ownedRunCandidates(
            in: chain.leafDescriptor,
            rootURL: chain.leafURL)
        candidates.sort {
            if $0.modifiedSeconds == $1.modifiedSeconds {
                return $0.name < $1.name
            }
            return $0.modifiedSeconds < $1.modifiedSeconds
        }
        var retainedCandidateCount = candidates.count
        for candidate in candidates {
            guard retainedCandidateCount >= maximumRetainedRuns else { break }
            if try retireIfInactiveAndExclusivelyOwned(
                candidate,
                chain: chain,
                retentionLock: retentionLock,
                testingHooks: testingHooks)
            {
                retainedCandidateCount -= 1
            }
        }
        guard retainedCandidateCount < maximumRetainedRuns else {
            throw DiagnosticsScopedRunStoreError.retentionCapacityUnavailable(
                limit: maximumRetainedRuns)
        }

        let runName = DiagnosticsBootstrap.runDirectoryName(origin: origin)
        let runDirectory = chain.leafURL.appendingPathComponent(runName, isDirectory: true)
        let runDescriptor = try createPrivateDirectory(
            parentDescriptor: chain.leafDescriptor,
            name: runName)
        var ownsRunDescriptor = true
        var activeLockDescriptor: Int32?
        do {
            var runStatus = stat()
            guard retrying({ Darwin.fstat(runDescriptor, &runStatus) }) == 0,
                  isTrustedDirectoryStatus(runStatus, requiresPrivateMode: true)
            else {
                throw DiagnosticsScopedRunStoreError.untrustedFilesystemObject
            }
            let runIdentity = LocalFileIdentity(runStatus)
            guard isDirectoryNameBound(
                parentDescriptor: chain.leafDescriptor,
                name: runName,
                expectedIdentity: runIdentity)
            else {
                throw DiagnosticsScopedRunStoreError.filesystemChanged
            }

            let activeLock = try openTrustedRegularChild(
                parentDescriptor: runDescriptor,
                name: ".active.lock",
                createIfMissing: true)
            activeLockDescriptor = activeLock.descriptor
            guard diagnosticsFileLock(activeLock.descriptor, LOCK_EX | LOCK_NB) == 0 else {
                throw posixError(errno)
            }
            guard isRegularNameBound(
                parentDescriptor: runDescriptor,
                name: activeLock.name,
                descriptor: activeLock.descriptor)
            else {
                throw DiagnosticsScopedRunStoreError.filesystemChanged
            }
            try syncDescriptor(runDescriptor)
            try syncDescriptor(chain.leafDescriptor)
            try chain.revalidate()
            guard isDirectoryNameBound(
                parentDescriptor: chain.leafDescriptor,
                name: runName,
                expectedIdentity: runIdentity)
            else {
                throw DiagnosticsScopedRunStoreError.filesystemChanged
            }

            ownsRunDescriptor = false
            activeLockDescriptor = nil
            return DiagnosticsRunLease(
                directory: runDirectory,
                activeLockDescriptor: activeLock.descriptor,
                runDescriptor: runDescriptor,
                directoryChain: chain,
                runName: runName,
                runIdentity: runIdentity)
        } catch {
            if let activeLockDescriptor {
                _ = diagnosticsFileLock(activeLockDescriptor, LOCK_UN)
                _ = Darwin.close(activeLockDescriptor)
            }
            if ownsRunDescriptor {
                _ = Darwin.close(runDescriptor)
            }
            try? removeEmptyCreatedDirectory(
                parentDescriptor: chain.leafDescriptor,
                name: runName)
            throw error
        }
    }

    private static func openExistingOwnedDirectoryChain(
        applicationSupportDirectory: URL
    ) throws -> DiagnosticsTrustedDirectoryChain? {
        guard BoundedRegularFileReader.hasLocalFileAuthority(applicationSupportDirectory) else {
            throw DiagnosticsScopedRunStoreError.pathIsNotDirectory
        }
        let baseURL = LocalFileSystem.canonicalIOURL(applicationSupportDirectory)
        let baseDescriptor = baseURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                errno = EINVAL
                return -1
            }
            return Darwin.open(
                path,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK)
        }
        if baseDescriptor < 0, errno == ENOENT { return nil }
        guard baseDescriptor >= 0 else { throw posixError(errno) }

        var nodes: [DiagnosticsTrustedDirectoryChain.Node] = []
        func closeNodes() {
            for node in nodes.reversed() { _ = Darwin.close(node.descriptor) }
            if nodes.isEmpty { _ = Darwin.close(baseDescriptor) }
        }
        do {
            var baseStatus = stat()
            guard retrying({ Darwin.fstat(baseDescriptor, &baseStatus) }) == 0,
                  isTrustedDirectoryStatus(baseStatus, requiresPrivateMode: false)
            else {
                throw DiagnosticsScopedRunStoreError.untrustedFilesystemObject
            }
            nodes.append(DiagnosticsTrustedDirectoryChain.Node(
                descriptor: baseDescriptor,
                url: baseURL,
                componentFromParent: nil,
                fingerprint: DiagnosticsDirectoryFingerprint(baseStatus),
                requiresPrivateMode: false))

            var currentURL = baseURL
            for component in ownedDirectoryComponents {
                let parent = nodes[nodes.count - 1]
                guard let status = try entryStatus(
                    parentDescriptor: parent.descriptor,
                    name: component)
                else {
                    closeNodes()
                    return nil
                }
                guard isTrustedDirectoryStatus(status, requiresPrivateMode: true) else {
                    throw DiagnosticsScopedRunStoreError.untrustedFilesystemObject
                }
                let descriptor = try openDirectory(
                    parentDescriptor: parent.descriptor,
                    name: component)
                let identity = LocalFileIdentity(status)
                guard isTrustedDirectoryDescriptor(descriptor, expectedIdentity: identity),
                      isDirectoryNameBound(
                        parentDescriptor: parent.descriptor,
                        name: component,
                        expectedIdentity: identity)
                else {
                    _ = Darwin.close(descriptor)
                    throw DiagnosticsScopedRunStoreError.filesystemChanged
                }
                currentURL.appendPathComponent(component, isDirectory: true)
                nodes.append(DiagnosticsTrustedDirectoryChain.Node(
                    descriptor: descriptor,
                    url: currentURL,
                    componentFromParent: component,
                    fingerprint: DiagnosticsDirectoryFingerprint(status),
                    requiresPrivateMode: true))
            }
        } catch {
            closeNodes()
            throw error
        }

        let chain = DiagnosticsTrustedDirectoryChain(nodes: nodes)
        try chain.revalidate()
        return chain
    }

    private static func historyDirectoryFingerprint(
        descriptor: Int32
    ) throws -> DiagnosticsHistoryDirectoryFingerprint {
        var status = stat()
        guard retrying({ Darwin.fstat(descriptor, &status) }) == 0,
              isTrustedDirectoryStatus(status, requiresPrivateMode: true)
        else {
            throw DiagnosticsScopedRunStoreError.filesystemChanged
        }
        return DiagnosticsHistoryDirectoryFingerprint(status)
    }

    private static func regularFileFingerprint(
        descriptor: Int32
    ) throws -> DiagnosticsRegularFileFingerprint {
        var status = stat()
        guard retrying({ Darwin.fstat(descriptor, &status) }) == 0,
              isTrustedRegularStatus(status)
        else {
            throw DiagnosticsScopedRunStoreError.filesystemChanged
        }
        return DiagnosticsRegularFileFingerprint(status)
    }

    private static func historyDirectoryEntryNames(
        descriptor: Int32,
        maximumNames: Int,
        expectedFingerprint: DiagnosticsHistoryDirectoryFingerprint
    ) throws -> HistoryEnumeration {
        guard try historyDirectoryFingerprint(descriptor: descriptor) == expectedFingerprint else {
            throw DiagnosticsScopedRunStoreError.filesystemChanged
        }
        let enumerationDescriptor = ".".withCString { currentDirectory in
            retrying {
                Darwin.openat(
                    descriptor,
                    currentDirectory,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
                        | O_RESOLVE_BENEATH)
            }
        }
        guard enumerationDescriptor >= 0 else { throw posixError(errno) }
        guard try historyDirectoryFingerprint(descriptor: enumerationDescriptor)
            == expectedFingerprint
        else {
            _ = Darwin.close(enumerationDescriptor)
            throw DiagnosticsScopedRunStoreError.filesystemChanged
        }
        guard let directory = Darwin.fdopendir(enumerationDescriptor) else {
            let code = errno
            _ = Darwin.close(enumerationDescriptor)
            throw posixError(code)
        }
        defer { Darwin.closedir(directory) }

        var names: [String] = []
        names.reserveCapacity(min(maximumNames, 64))
        while true {
            try checkHistoryCancellation()
            errno = 0
            guard let entry = Darwin.readdir(directory) else {
                if errno != 0 { throw posixError(errno) }
                guard try historyDirectoryFingerprint(descriptor: descriptor)
                        == expectedFingerprint,
                      try historyDirectoryFingerprint(descriptor: enumerationDescriptor)
                        == expectedFingerprint
                else {
                    throw DiagnosticsScopedRunStoreError.filesystemChanged
                }
                return HistoryEnumeration(names: names, hasUnknownRemainder: false)
            }
            var entryValue = entry.pointee
            let name = withUnsafePointer(to: &entryValue.d_name) { pointer -> String? in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(validatingCString: $0)
                }
            }
            guard let name else {
                throw DiagnosticsScopedRunStoreError.untrustedFilesystemObject
            }
            if name == "." || name == ".." { continue }
            if names.count == maximumNames {
                guard try historyDirectoryFingerprint(descriptor: descriptor)
                        == expectedFingerprint,
                      try historyDirectoryFingerprint(descriptor: enumerationDescriptor)
                        == expectedFingerprint
                else {
                    throw DiagnosticsScopedRunStoreError.filesystemChanged
                }
                return HistoryEnumeration(names: names, hasUnknownRemainder: true)
            }
            names.append(name)
        }
    }

    private static func openReadOnlyTrustedRegularChild(
        parentDescriptor: Int32,
        name: String,
        expectedFingerprint: DiagnosticsRegularFileFingerprint
    ) throws -> TrustedRegularChild {
        let descriptor = name.withCString { namePointer in
            retrying {
                Darwin.openat(
                    parentDescriptor,
                    namePointer,
                    O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | O_RESOLVE_BENEATH
                        | O_UNIQUE)
            }
        }
        guard descriptor >= 0 else { throw posixError(errno) }
        do {
            let fingerprint = try regularFileFingerprint(descriptor: descriptor)
            guard fingerprint == expectedFingerprint,
                  isRegularNameBound(
                    parentDescriptor: parentDescriptor,
                    name: name,
                    descriptor: descriptor)
            else {
                throw DiagnosticsScopedRunStoreError.filesystemChanged
            }
            return TrustedRegularChild(
                descriptor: descriptor,
                name: name,
                fingerprint: fingerprint)
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private static func readHistoryData(
        descriptor: Int32,
        expectedByteCount: Int
    ) throws -> Data {
        var data = Data(count: expectedByteCount)
        var offset = 0
        try data.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            while offset < buffer.count {
                try checkHistoryCancellation()
                let count = Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixError(errno)
                }
                guard count > 0 else {
                    throw DiagnosticsScopedRunStoreError.filesystemChanged
                }
                offset += count
            }
        }
        return data
    }

    private static func parseRunOrigin(from name: String) -> DiagnosticOrigin? {
        let role: DiagnosticProcessRole
        let prefix: String
        if name.hasPrefix("app-") {
            role = .app
            prefix = "app-"
        } else if name.hasPrefix("quick-look-extension-") {
            role = .quickLookExtension
            prefix = "quick-look-extension-"
        } else {
            return nil
        }
        let remainder = name.dropFirst(prefix.count)
        guard remainder.count >= 38 else { return nil }
        let uuidEnd = remainder.index(remainder.startIndex, offsetBy: 36)
        guard let runID = UUID(uuidString: String(remainder[..<uuidEnd])),
              remainder[uuidEnd] == "-"
        else {
            return nil
        }
        let processIDText = remainder[remainder.index(after: uuidEnd)...]
        guard !processIDText.isEmpty,
              processIDText.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
              let numericProcessID = Int64(processIDText),
              let processID = Int32(exactly: numericProcessID),
              processID > 0
        else {
            return nil
        }
        return DiagnosticOrigin(
            runID: runID,
            processID: processID,
            role: role,
            locality: .productionUser)
    }

    private static func isHistoryEventFileName(_ name: String) -> Bool {
        name.hasPrefix("events") && name.hasSuffix(".jsonl")
    }

    private static func historyEventGeneration(_ name: String) -> UInt64? {
        if name == "events.jsonl" { return 0 }
        let prefix = "events."
        let suffix = ".jsonl"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let digits = name.dropFirst(prefix.count).dropLast(suffix.count)
        guard !digits.isEmpty,
              digits.utf8.allSatisfy({ (0x30...0x39).contains($0) })
        else {
            return nil
        }
        return UInt64(digits)
    }

    private struct RunCandidate {
        let name: String
        let url: URL
        let modifiedSeconds: Int64
        let expectedIdentity: LocalFileIdentity?
        let isRetired: Bool
    }

    private struct TrustedRegularChild {
        let descriptor: Int32
        let name: String
        let fingerprint: DiagnosticsRegularFileFingerprint
    }

    private struct OpenedOwnedChild {
        let descriptor: Int32
        let name: String
        let fingerprint: DiagnosticsRegularFileFingerprint
    }

    private static func prepareOwnedDirectoryChain(
        applicationSupportDirectory: URL
    ) throws -> DiagnosticsTrustedDirectoryChain {
        guard BoundedRegularFileReader.hasLocalFileAuthority(applicationSupportDirectory) else {
            throw DiagnosticsScopedRunStoreError.pathIsNotDirectory
        }
        let baseURL = LocalFileSystem.canonicalIOURL(applicationSupportDirectory)
        let baseDescriptor = baseURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                errno = EINVAL
                return -1
            }
            return Darwin.open(
                path,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK)
        }
        guard baseDescriptor >= 0 else { throw posixError(errno) }

        var nodes: [DiagnosticsTrustedDirectoryChain.Node] = []
        do {
            var baseStatus = stat()
            guard retrying({ Darwin.fstat(baseDescriptor, &baseStatus) }) == 0,
                  isTrustedDirectoryStatus(baseStatus, requiresPrivateMode: false)
            else {
                throw DiagnosticsScopedRunStoreError.untrustedFilesystemObject
            }
            nodes.append(DiagnosticsTrustedDirectoryChain.Node(
                descriptor: baseDescriptor,
                url: baseURL,
                componentFromParent: nil,
                fingerprint: DiagnosticsDirectoryFingerprint(baseStatus),
                requiresPrivateMode: false))

            var currentURL = baseURL
            for component in ownedDirectoryComponents {
                let parent = nodes[nodes.count - 1]
                let created = try createDirectoryIfMissing(
                    parentDescriptor: parent.descriptor,
                    name: component)
                let descriptor = try openDirectory(
                    parentDescriptor: parent.descriptor,
                    name: component)
                if created {
                    guard retrying({ Darwin.fchmod(descriptor, diagnosticsPrivateDirectoryMode) }) == 0 else {
                        let code = errno
                        _ = Darwin.close(descriptor)
                        throw posixError(code)
                    }
                }

                var status = stat()
                guard retrying({ Darwin.fstat(descriptor, &status) }) == 0,
                      isTrustedDirectoryStatus(status, requiresPrivateMode: true)
                else {
                    _ = Darwin.close(descriptor)
                    throw DiagnosticsScopedRunStoreError.untrustedFilesystemObject
                }
                let identity = LocalFileIdentity(status)
                guard isDirectoryNameBound(
                    parentDescriptor: parent.descriptor,
                    name: component,
                    expectedIdentity: identity)
                else {
                    _ = Darwin.close(descriptor)
                    throw DiagnosticsScopedRunStoreError.filesystemChanged
                }
                currentURL.appendPathComponent(component, isDirectory: true)
                nodes.append(DiagnosticsTrustedDirectoryChain.Node(
                    descriptor: descriptor,
                    url: currentURL,
                    componentFromParent: component,
                    fingerprint: DiagnosticsDirectoryFingerprint(status),
                    requiresPrivateMode: true))
                if created { try syncDescriptor(parent.descriptor) }
            }
        } catch {
            for node in nodes.reversed() {
                _ = Darwin.close(node.descriptor)
            }
            if nodes.isEmpty { _ = Darwin.close(baseDescriptor) }
            throw error
        }

        let chain = DiagnosticsTrustedDirectoryChain(nodes: nodes)
        try chain.revalidate()
        return chain
    }

    private static func createDirectoryIfMissing(
        parentDescriptor: Int32,
        name: String
    ) throws -> Bool {
        let result = name.withCString { namePointer in
            retrying {
                Darwin.mkdirat(parentDescriptor, namePointer, diagnosticsPrivateDirectoryMode)
            }
        }
        if result == 0 { return true }
        if errno == EEXIST { return false }
        throw posixError(errno)
    }

    private static func createPrivateDirectory(
        parentDescriptor: Int32,
        name: String
    ) throws -> Int32 {
        let result = name.withCString { namePointer in
            retrying {
                Darwin.mkdirat(parentDescriptor, namePointer, diagnosticsPrivateDirectoryMode)
            }
        }
        guard result == 0 else {
            if errno == EEXIST {
                throw DiagnosticsScopedRunStoreError.runDirectoryCollision
            }
            throw posixError(errno)
        }
        do {
            let descriptor = try openDirectory(parentDescriptor: parentDescriptor, name: name)
            guard retrying({ Darwin.fchmod(descriptor, diagnosticsPrivateDirectoryMode) }) == 0 else {
                let code = errno
                _ = Darwin.close(descriptor)
                throw posixError(code)
            }
            return descriptor
        } catch {
            try? removeEmptyCreatedDirectory(parentDescriptor: parentDescriptor, name: name)
            throw error
        }
    }

    private static func openDirectory(
        parentDescriptor: Int32,
        name: String
    ) throws -> Int32 {
        let descriptor = name.withCString { namePointer in
            retrying {
                Darwin.openat(
                    parentDescriptor,
                    namePointer,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
                        | O_RESOLVE_BENEATH)
            }
        }
        guard descriptor >= 0 else { throw posixError(errno) }
        return descriptor
    }

    private static func openTrustedRegularChild(
        parentDescriptor: Int32,
        name: String,
        createIfMissing: Bool,
        expectedFingerprint: DiagnosticsRegularFileFingerprint? = nil
    ) throws -> TrustedRegularChild {
        var descriptor = openExistingRegularChild(
            parentDescriptor: parentDescriptor,
            name: name)
        var created = false
        if descriptor < 0, errno == ENOENT, createIfMissing {
            descriptor = name.withCString { namePointer in
                retrying {
                    Darwin.openat(
                        parentDescriptor,
                        namePointer,
                        O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
                            | O_RESOLVE_BENEATH | O_UNIQUE,
                        diagnosticsPrivateFileMode)
                }
            }
            if descriptor >= 0 {
                created = true
            } else if errno == EEXIST {
                descriptor = openExistingRegularChild(
                    parentDescriptor: parentDescriptor,
                    name: name)
            }
        }
        guard descriptor >= 0 else { throw posixError(errno) }

        do {
            if created {
                guard retrying({ Darwin.fchmod(descriptor, diagnosticsPrivateFileMode) }) == 0 else {
                    throw posixError(errno)
                }
            }
            var held = stat()
            guard retrying({ Darwin.fstat(descriptor, &held) }) == 0,
                  isTrustedRegularStatus(held)
            else {
                throw DiagnosticsScopedRunStoreError.untrustedFilesystemObject
            }
            let fingerprint = DiagnosticsRegularFileFingerprint(held)
            if let expectedFingerprint, fingerprint != expectedFingerprint {
                throw DiagnosticsScopedRunStoreError.filesystemChanged
            }
            guard isRegularNameBound(
                parentDescriptor: parentDescriptor,
                name: name,
                descriptor: descriptor)
            else {
                throw DiagnosticsScopedRunStoreError.filesystemChanged
            }
            if created {
                try syncDescriptor(descriptor)
                try syncDescriptor(parentDescriptor)
            }
            return TrustedRegularChild(
                descriptor: descriptor,
                name: name,
                fingerprint: fingerprint)
        } catch {
            if created {
                try? unlinkIfStillBound(
                    parentDescriptor: parentDescriptor,
                    name: name,
                    descriptor: descriptor)
            }
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private static func openExistingRegularChild(
        parentDescriptor: Int32,
        name: String
    ) -> Int32 {
        return name.withCString { namePointer in
            retrying {
                Darwin.openat(
                    parentDescriptor,
                    namePointer,
                    O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | O_RESOLVE_BENEATH
                        | O_UNIQUE)
            }
        }
    }

    private static func ownedRunCandidates(
        in rootDescriptor: Int32,
        rootURL: URL
    ) throws -> [RunCandidate] {
        let names = try directoryEntryNames(descriptor: rootDescriptor)
        var candidates: [RunCandidate] = []
        candidates.reserveCapacity(min(names.count, largestSupportedRetainedRunLimit))
        for name in names where isOwnedRunName(name) || isRetiredRunName(name) {
            guard let status = try entryStatus(parentDescriptor: rootDescriptor, name: name) else {
                throw DiagnosticsScopedRunStoreError.filesystemChanged
            }
            let trustedDirectory = isTrustedDirectoryStatus(status, requiresPrivateMode: true)
            candidates.append(RunCandidate(
                name: name,
                url: rootURL.appendingPathComponent(name, isDirectory: true),
                modifiedSeconds: Int64(status.st_mtimespec.tv_sec),
                expectedIdentity: trustedDirectory ? LocalFileIdentity(status) : nil,
                isRetired: isRetiredRunName(name)))
        }
        return candidates
    }

    private static func retireIfInactiveAndExclusivelyOwned(
        _ candidate: RunCandidate,
        chain: DiagnosticsTrustedDirectoryChain,
        retentionLock: TrustedRegularChild,
        testingHooks: DiagnosticsScopedRunStoreTestingHooks
    ) throws -> Bool {
        guard let expectedIdentity = candidate.expectedIdentity else { return false }
        let runDescriptor: Int32
        do {
            runDescriptor = try openDirectory(
                parentDescriptor: chain.leafDescriptor,
                name: candidate.name)
        } catch {
            return false
        }
        defer { _ = Darwin.close(runDescriptor) }

        guard isTrustedDirectoryDescriptor(runDescriptor, expectedIdentity: expectedIdentity),
              isDirectoryNameBound(
                parentDescriptor: chain.leafDescriptor,
                name: candidate.name,
                expectedIdentity: expectedIdentity),
              let initialEntries = try validatedOwnedEntries(in: runDescriptor),
              candidate.isRetired || initialEntries[".active.lock"] != nil
        else {
            return false
        }

        var activeLock: TrustedRegularChild?
        if let lockFingerprint = initialEntries[".active.lock"] {
            let openedLock: TrustedRegularChild
            do {
                openedLock = try openTrustedRegularChild(
                    parentDescriptor: runDescriptor,
                    name: ".active.lock",
                    createIfMissing: false,
                    expectedFingerprint: lockFingerprint)
            } catch {
                return false
            }
            guard diagnosticsFileLock(openedLock.descriptor, LOCK_EX | LOCK_NB) == 0 else {
                let code = errno
                _ = Darwin.close(openedLock.descriptor)
                if code == EWOULDBLOCK || code == EAGAIN { return false }
                throw posixError(code)
            }
            activeLock = openedLock
        }
        defer {
            if let activeLock {
                _ = diagnosticsFileLock(activeLock.descriptor, LOCK_UN)
                _ = Darwin.close(activeLock.descriptor)
            }
        }

        guard hasMutationAuthority(
            chain: chain,
            retentionLock: retentionLock,
            runDescriptor: runDescriptor,
            runName: candidate.name,
            runIdentity: expectedIdentity),
            try validatedOwnedEntries(in: runDescriptor) == initialEntries
        else {
            return false
        }

        testingHooks.beforeCandidateRetirement?(candidate.url)

        let activeLockIsStillBound = activeLock.map {
            isRegularNameBound(
                parentDescriptor: runDescriptor,
                name: $0.name,
                descriptor: $0.descriptor)
        } ?? candidate.isRetired
        guard hasMutationAuthority(
            chain: chain,
            retentionLock: retentionLock,
            runDescriptor: runDescriptor,
            runName: candidate.name,
            runIdentity: expectedIdentity),
            try validatedOwnedEntries(in: runDescriptor) == initialEntries,
            activeLockIsStillBound
        else {
            return false
        }

        let retiredName: String
        if candidate.isRetired {
            retiredName = candidate.name
        } else {
            retiredName = ".retired-" + UUID().uuidString.lowercased()
            let renameResult = candidate.name.withCString { source in
                retiredName.withCString { destination in
                    retrying {
                        Darwin.renameatx_np(
                            chain.leafDescriptor,
                            source,
                            chain.leafDescriptor,
                            destination,
                            UInt32(RENAME_EXCL))
                    }
                }
            }
            guard renameResult == 0 else {
                if errno == ENOENT || errno == EEXIST { return false }
                throw posixError(errno)
            }
            try testingHooks.afterMutation?(.candidateRenamed)
            try syncDescriptor(chain.leafDescriptor)
            try testingHooks.afterMutation?(.retirementRenameSynced)
        }

        guard isDirectoryNameBound(
            parentDescriptor: chain.leafDescriptor,
            name: retiredName,
            expectedIdentity: expectedIdentity),
            isRegularNameBound(
                parentDescriptor: chain.leafDescriptor,
                name: retentionLock.name,
                descriptor: retentionLock.descriptor),
            try validatedOwnedEntries(in: runDescriptor) == initialEntries
        else {
            if !candidate.isRetired {
                try? restoreRetiredName(
                    rootDescriptor: chain.leafDescriptor,
                    retiredName: retiredName,
                    originalName: candidate.name,
                    expectedIdentity: expectedIdentity)
            }
            return false
        }

        let openedChildren: [OpenedOwnedChild]
        do {
            openedChildren = try openOwnedChildren(
                in: runDescriptor,
                expectedEntries: initialEntries,
                activeLock: activeLock)
        } catch {
            return false
        }
        defer {
            for child in openedChildren
                where child.descriptor != activeLock?.descriptor
            {
                _ = Darwin.close(child.descriptor)
            }
        }

        guard try validatedOwnedEntries(in: runDescriptor) == initialEntries,
              isDirectoryNameBound(
                parentDescriptor: chain.leafDescriptor,
                name: retiredName,
                expectedIdentity: expectedIdentity)
        else {
            return false
        }

        for child in openedChildren where child.name != ".active.lock" {
            guard hasMutationAuthority(
                chain: chain,
                retentionLock: retentionLock,
                runDescriptor: runDescriptor,
                runName: retiredName,
                runIdentity: expectedIdentity),
                isRegularNameBound(
                parentDescriptor: runDescriptor,
                name: child.name,
                descriptor: child.descriptor),
                isTrustedRegularDescriptor(
                    child.descriptor,
                    expectedIdentity: child.fingerprint.identity)
            else {
                return false
            }
            let unlinkResult = child.name.withCString { namePointer in
                retrying { Darwin.unlinkat(runDescriptor, namePointer, 0) }
            }
            guard unlinkResult == 0 else { return false }
            try testingHooks.afterMutation?(.childUnlinked(child.name))
        }

        if let activeLock {
            guard hasMutationAuthority(
                chain: chain,
                retentionLock: retentionLock,
                runDescriptor: runDescriptor,
                runName: retiredName,
                runIdentity: expectedIdentity),
                isRegularNameBound(
                parentDescriptor: runDescriptor,
                name: activeLock.name,
                descriptor: activeLock.descriptor)
            else {
                return false
            }
            let lockUnlinkResult = activeLock.name.withCString { namePointer in
                retrying { Darwin.unlinkat(runDescriptor, namePointer, 0) }
            }
            guard lockUnlinkResult == 0 else { return false }
            try testingHooks.afterMutation?(.activeLockUnlinked)
        }

        try syncDescriptor(runDescriptor)
        try testingHooks.afterMutation?(.runDirectorySynced)
        guard try directoryEntryNames(descriptor: runDescriptor).isEmpty,
              hasMutationAuthority(
                chain: chain,
                retentionLock: retentionLock,
                runDescriptor: runDescriptor,
                runName: retiredName,
                runIdentity: expectedIdentity)
        else {
            return false
        }

        let directoryUnlinkResult = retiredName.withCString { namePointer in
            retrying {
                Darwin.unlinkat(chain.leafDescriptor, namePointer, AT_REMOVEDIR)
            }
        }
        guard directoryUnlinkResult == 0 else { return false }
        try testingHooks.afterMutation?(.retiredDirectoryRemoved)
        try syncDescriptor(chain.leafDescriptor)
        try testingHooks.afterMutation?(.retirementRemovalSynced)
        try chain.revalidate()
        return true
    }

    private static func hasMutationAuthority(
        chain: DiagnosticsTrustedDirectoryChain,
        retentionLock: TrustedRegularChild,
        runDescriptor: Int32,
        runName: String,
        runIdentity: LocalFileIdentity
    ) -> Bool {
        do {
            try chain.revalidate()
        } catch {
            return false
        }
        return isRegularNameBound(
            parentDescriptor: chain.leafDescriptor,
            name: retentionLock.name,
            descriptor: retentionLock.descriptor)
            && isTrustedDirectoryDescriptor(
                runDescriptor,
                expectedIdentity: runIdentity)
            && isDirectoryNameBound(
                parentDescriptor: chain.leafDescriptor,
                name: runName,
                expectedIdentity: runIdentity)
    }

    private static func openOwnedChildren(
        in runDescriptor: Int32,
        expectedEntries: [String: DiagnosticsRegularFileFingerprint],
        activeLock: TrustedRegularChild?
    ) throws -> [OpenedOwnedChild] {
        var children: [OpenedOwnedChild] = []
        children.reserveCapacity(expectedEntries.count)
        do {
            for name in expectedEntries.keys.sorted() {
                guard let expected = expectedEntries[name] else {
                    throw DiagnosticsScopedRunStoreError.filesystemChanged
                }
                if name == activeLock?.name {
                    guard let activeLock, activeLock.fingerprint == expected else {
                        throw DiagnosticsScopedRunStoreError.filesystemChanged
                    }
                    children.append(OpenedOwnedChild(
                        descriptor: activeLock.descriptor,
                        name: name,
                        fingerprint: expected))
                    continue
                }
                let child = try openTrustedRegularChild(
                    parentDescriptor: runDescriptor,
                    name: name,
                    createIfMissing: false,
                    expectedFingerprint: expected)
                children.append(OpenedOwnedChild(
                    descriptor: child.descriptor,
                    name: name,
                    fingerprint: child.fingerprint))
            }
            return children
        } catch {
            for child in children where child.descriptor != activeLock?.descriptor {
                _ = Darwin.close(child.descriptor)
            }
            throw error
        }
    }

    private static func validatedOwnedEntries(
        in directoryDescriptor: Int32
    ) throws -> [String: DiagnosticsRegularFileFingerprint]? {
        let names = try directoryEntryNames(descriptor: directoryDescriptor)
        guard names.count <= maximumOwnedEntriesPerRun else { return nil }
        var entries: [String: DiagnosticsRegularFileFingerprint] = [:]
        entries.reserveCapacity(names.count)
        for name in names {
            guard isOwnedRunEntry(name),
                  let status = try entryStatus(
                    parentDescriptor: directoryDescriptor,
                    name: name),
                  isTrustedRegularStatus(status)
            else {
                return nil
            }
            entries[name] = DiagnosticsRegularFileFingerprint(status)
        }
        return entries
    }

    private static func directoryEntryNames(descriptor: Int32) throws -> [String] {
        var sourceStatus = stat()
        guard retrying({ Darwin.fstat(descriptor, &sourceStatus) }) == 0,
              isTrustedDirectoryStatus(sourceStatus, requiresPrivateMode: true)
        else {
            throw DiagnosticsScopedRunStoreError.filesystemChanged
        }
        let sourceFingerprint = DiagnosticsDirectoryFingerprint(sourceStatus)

        // A dup(2) descriptor shares the directory stream offset with its source.
        // Reopening `.` creates an independent open file description, so repeated
        // validation passes cannot accidentally observe EOF from an earlier pass.
        let enumerationDescriptor = ".".withCString { currentDirectory in
            retrying {
                Darwin.openat(
                    descriptor,
                    currentDirectory,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
                        | O_RESOLVE_BENEATH)
            }
        }
        guard enumerationDescriptor >= 0 else { throw posixError(errno) }
        var enumerationStatus = stat()
        guard retrying({ Darwin.fstat(enumerationDescriptor, &enumerationStatus) }) == 0,
              isTrustedDirectoryStatus(enumerationStatus, requiresPrivateMode: true),
              DiagnosticsDirectoryFingerprint(enumerationStatus) == sourceFingerprint
        else {
            _ = Darwin.close(enumerationDescriptor)
            throw DiagnosticsScopedRunStoreError.filesystemChanged
        }

        guard let directory = Darwin.fdopendir(enumerationDescriptor) else {
            let code = errno
            _ = Darwin.close(enumerationDescriptor)
            throw posixError(code)
        }
        defer { Darwin.closedir(directory) }

        var names: [String] = []
        names.reserveCapacity(16)
        while true {
            errno = 0
            guard let entry = Darwin.readdir(directory) else {
                if errno != 0 { throw posixError(errno) }
                var finalSourceStatus = stat()
                var finalEnumerationStatus = stat()
                guard retrying({ Darwin.fstat(descriptor, &finalSourceStatus) }) == 0,
                      retrying({
                        Darwin.fstat(enumerationDescriptor, &finalEnumerationStatus)
                      }) == 0,
                      DiagnosticsDirectoryFingerprint(finalSourceStatus) == sourceFingerprint,
                      DiagnosticsDirectoryFingerprint(finalEnumerationStatus) == sourceFingerprint
                else {
                    throw DiagnosticsScopedRunStoreError.filesystemChanged
                }
                return names
            }
            var entryValue = entry.pointee
            let name = withUnsafePointer(to: &entryValue.d_name) { pointer -> String? in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(validatingCString: $0)
                }
            }
            guard let name else {
                throw DiagnosticsScopedRunStoreError.untrustedFilesystemObject
            }
            if name == "." || name == ".." { continue }
            guard names.count < maximumDirectoryEntriesToInspect else {
                throw DiagnosticsScopedRunStoreError.retentionCapacityUnavailable(
                    limit: maximumRetainedRuns)
            }
            names.append(name)
        }
    }

    private static func entryStatus(
        parentDescriptor: Int32,
        name: String
    ) throws -> stat? {
        var status = stat()
        let result = name.withCString { namePointer in
            retrying {
                Darwin.fstatat(
                    parentDescriptor,
                    namePointer,
                    &status,
                    AT_SYMLINK_NOFOLLOW | AT_RESOLVE_BENEATH)
            }
        }
        if result == 0 { return status }
        if errno == ENOENT { return nil }
        throw posixError(errno)
    }

    fileprivate static func isTrustedDirectoryDescriptor(
        _ descriptor: Int32,
        expectedIdentity: LocalFileIdentity
    ) -> Bool {
        var status = stat()
        return retrying({ Darwin.fstat(descriptor, &status) }) == 0
            && isTrustedDirectoryStatus(status, requiresPrivateMode: true)
            && LocalFileIdentity(status) == expectedIdentity
    }

    fileprivate static func isDirectoryNameBound(
        parentDescriptor: Int32,
        name: String,
        expectedIdentity: LocalFileIdentity
    ) -> Bool {
        do {
            guard let status = try entryStatus(parentDescriptor: parentDescriptor, name: name),
                  isTrustedDirectoryStatus(status, requiresPrivateMode: true)
            else {
                return false
            }
            return LocalFileIdentity(status) == expectedIdentity
        } catch {
            return false
        }
    }

    fileprivate static func isTrustedRegularDescriptor(
        _ descriptor: Int32,
        expectedIdentity: LocalFileIdentity?
    ) -> Bool {
        var status = stat()
        guard retrying({ Darwin.fstat(descriptor, &status) }) == 0,
              isTrustedRegularStatus(status)
        else {
            return false
        }
        return expectedIdentity.map { LocalFileIdentity(status) == $0 } ?? true
    }

    fileprivate static func isRegularNameBound(
        parentDescriptor: Int32,
        name: String,
        descriptor: Int32
    ) -> Bool {
        var held = stat()
        guard retrying({ Darwin.fstat(descriptor, &held) }) == 0,
              isTrustedRegularStatus(held)
        else {
            return false
        }
        do {
            guard let named = try entryStatus(parentDescriptor: parentDescriptor, name: name),
                  isTrustedRegularStatus(named)
            else {
                return false
            }
            return DiagnosticsRegularFileFingerprint(held)
                == DiagnosticsRegularFileFingerprint(named)
        } catch {
            return false
        }
    }

    fileprivate static func isTrustedDirectoryStatus(
        _ status: stat,
        requiresPrivateMode: Bool
    ) -> Bool {
        guard status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == geteuid(),
              status.st_nlink >= 2
        else {
            return false
        }
        let permissions = status.st_mode & mode_t(0o7777)
        return requiresPrivateMode
            ? permissions == diagnosticsPrivateDirectoryMode
            : permissions & mode_t(0o022) == 0
    }

    private static func isTrustedRegularStatus(_ status: stat) -> Bool {
        status.st_mode & S_IFMT == S_IFREG
            && status.st_uid == geteuid()
            && status.st_nlink == 1
            && status.st_mode & mode_t(0o7777) == diagnosticsPrivateFileMode
    }

    private static func isOwnedRunName(_ value: String) -> Bool {
        parseRunOrigin(from: value) != nil
    }

    private static func isRetiredRunName(_ value: String) -> Bool {
        let prefix = ".retired-"
        guard value.hasPrefix(prefix) else { return false }
        return UUID(uuidString: String(value.dropFirst(prefix.count))) != nil
    }

    private static func isOwnedRunEntry(_ name: String) -> Bool {
        if name == ".active.lock" || name == "events.jsonl" { return true }
        if name.hasPrefix("events."), name.hasSuffix(".jsonl") {
            let digits = name.dropFirst("events.".count).dropLast(".jsonl".count)
            return !digits.isEmpty && digits.utf8.allSatisfy { (0x30...0x39).contains($0) }
        }
        if name.hasPrefix(".events"), name.hasSuffix(".tmp") {
            let components = name.split(separator: ".", omittingEmptySubsequences: false)
            return components.count >= 4
                && UUID(uuidString: String(components[components.count - 2])) != nil
        }
        return false
    }

    private static func restoreRetiredName(
        rootDescriptor: Int32,
        retiredName: String,
        originalName: String,
        expectedIdentity: LocalFileIdentity
    ) throws {
        guard isDirectoryNameBound(
            parentDescriptor: rootDescriptor,
            name: retiredName,
            expectedIdentity: expectedIdentity)
        else {
            throw DiagnosticsScopedRunStoreError.filesystemChanged
        }
        let result = retiredName.withCString { source in
            originalName.withCString { destination in
                retrying {
                    Darwin.renameatx_np(
                        rootDescriptor,
                        source,
                        rootDescriptor,
                        destination,
                        UInt32(RENAME_EXCL))
                }
            }
        }
        guard result == 0 else { throw posixError(errno) }
    }

    private static func removeEmptyCreatedDirectory(
        parentDescriptor: Int32,
        name: String
    ) throws {
        guard let status = try entryStatus(parentDescriptor: parentDescriptor, name: name),
              isTrustedDirectoryStatus(status, requiresPrivateMode: true)
        else {
            return
        }
        let descriptor = try openDirectory(parentDescriptor: parentDescriptor, name: name)
        defer { _ = Darwin.close(descriptor) }
        guard isDirectoryNameBound(
            parentDescriptor: parentDescriptor,
            name: name,
            expectedIdentity: LocalFileIdentity(status)),
            try directoryEntryNames(descriptor: descriptor).isEmpty
        else {
            return
        }
        let result = name.withCString { namePointer in
            retrying { Darwin.unlinkat(parentDescriptor, namePointer, AT_REMOVEDIR) }
        }
        guard result == 0 else { throw posixError(errno) }
        try syncDescriptor(parentDescriptor)
    }

    private static func unlinkIfStillBound(
        parentDescriptor: Int32,
        name: String,
        descriptor: Int32
    ) throws {
        guard isRegularNameBound(
            parentDescriptor: parentDescriptor,
            name: name,
            descriptor: descriptor)
        else {
            throw DiagnosticsScopedRunStoreError.filesystemChanged
        }
        let result = name.withCString { namePointer in
            retrying { Darwin.unlinkat(parentDescriptor, namePointer, 0) }
        }
        guard result == 0 else { throw posixError(errno) }
    }

    fileprivate static func actualURL(for descriptor: Int32) -> URL? {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let result: Int32 = path.withUnsafeMutableBytes { bytes -> Int32 in
            guard let baseAddress = bytes.baseAddress else {
                errno = EINVAL
                return Int32(-1)
            }
            return Darwin.fcntl(descriptor, F_GETPATH, baseAddress)
        }
        guard result == 0 else { return nil }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }

    private static func syncDescriptor(_ descriptor: Int32) throws {
        guard retrying({ Darwin.fsync(descriptor) }) == 0 else {
            throw posixError(errno)
        }
    }

    fileprivate static func retrying(_ body: () -> Int32) -> Int32 {
        while true {
            let result = body()
            if result >= 0 || errno != EINTR { return result }
        }
    }

    private static func posixError(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
