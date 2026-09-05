//
//  DiagnosticsRegressionTests.swift
//  MarkDevKitTests
//
//  Red tests for schema migration, sink isolation, and bounded cancellation.
//

import Darwin
import Foundation
import XCTest

@testable import MarkDevKit

private struct RegressionDiagnosticClock: DiagnosticClock {
    func millisecondsSince1970() -> Int64 { 1_700_000_000_123 }
    func uptimeNanoseconds() -> UInt64 { 42 }
}

private actor RegressionDiagnosticGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let ready = waiters
        waiters.removeAll()
        for continuation in ready {
            continuation.resume()
        }
    }
}

private actor RegressionCompletionFlag {
    private(set) var isComplete = false

    func markComplete() {
        isComplete = true
    }
}

/// XCTest expectations are thread-safe, but do not advertise `Sendable` on
/// every SDK supported by the project. This wrapper confines that SDK gap to a
/// test-only signalling primitive.
private final class RegressionDiagnosticSignal: @unchecked Sendable {
    private let expectation: XCTestExpectation

    init(_ expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func signal() {
        expectation.fulfill()
    }
}

private struct GatedRegressionDiagnosticSink: DiagnosticSink {
    let started: RegressionDiagnosticSignal
    let gate: RegressionDiagnosticGate

    func write(_ record: DiagnosticRecord) async throws {
        started.signal()
        await gate.wait()
    }
}

private struct SignallingRegressionDiagnosticSink: DiagnosticSink {
    let started: RegressionDiagnosticSignal

    func write(_ record: DiagnosticRecord) async throws {
        started.signal()
    }
}

private enum ExpectedRegressionSinkError: Error {
    case writeFailed
}

private struct InjectedStoreInterruption: Error {}

private actor BoundedGatedRegressionDiagnosticSink: DiagnosticSink {
    private let started: RegressionDiagnosticSignal
    private let finished: RegressionDiagnosticSignal?
    private let gate: RegressionDiagnosticGate
    private let shouldFail: Bool
    private var didSignalStart = false

    init(
        started: RegressionDiagnosticSignal,
        finished: RegressionDiagnosticSignal? = nil,
        gate: RegressionDiagnosticGate,
        shouldFail: Bool = false
    ) {
        self.started = started
        self.finished = finished
        self.gate = gate
        self.shouldFail = shouldFail
    }

    func write(_ record: DiagnosticRecord) async throws {
        if !didSignalStart {
            didSignalStart = true
            started.signal()
        }
        await gate.wait()
        finished?.signal()
        if shouldFail {
            throw ExpectedRegressionSinkError.writeFailed
        }
    }
}

private actor CollectingRegressionDiagnosticSink: DiagnosticSink {
    private(set) var sequences: [UInt64] = []

    func write(_ record: DiagnosticRecord) async throws {
        sequences.append(record.event.sequence)
    }
}

private final class ManualRegressionBarrierClock: DiagnosticBarrierClock, @unchecked Sendable {
    private struct Sleeper {
        let deadline: UInt64
        let promise: DiagnosticsOneShot<Void>
    }

    private let lock = NSLock()
    private var now: UInt64 = 0
    private var sleepers: [UUID: Sleeper] = [:]
    private var sleepInvocationCountStorage = 0

    func uptimeNanoseconds() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return now
    }

    func sleep(until deadline: DiagnosticDeadline) async throws {
        let identifier = UUID()
        let promise = DiagnosticsOneShot<Void>()

        let alreadyReached = lock.withLock {
            sleepInvocationCountStorage += 1
            guard deadline.uptimeNanoseconds > now else { return true }
            sleepers[identifier] = Sleeper(
                deadline: deadline.uptimeNanoseconds,
                promise: promise)
            return false
        }
        if alreadyReached { return }

        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await promise.value()
        } onCancel: {
            self.cancel(identifier: identifier, promise: promise)
        }
    }

    func advance(to value: UInt64) {
        var ready: [DiagnosticsOneShot<Void>] = []
        lock.lock()
        now = max(now, value)
        sleepers = sleepers.filter { _, sleeper in
            guard sleeper.deadline <= now else { return true }
            ready.append(sleeper.promise)
            return false
        }
        lock.unlock()
        for promise in ready {
            promise.resolve(.success(()))
        }
    }

    var pendingSleeperCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sleepers.count
    }

    var sleepInvocationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sleepInvocationCountStorage
    }

    private func cancel(identifier: UUID, promise: DiagnosticsOneShot<Void>) {
        lock.lock()
        sleepers.removeValue(forKey: identifier)
        lock.unlock()
        promise.resolve(.failure(CancellationError()))
    }
}

/// Deliberately not an actor: the diagnostics fan-out owner must serialize
/// calls even when a sink's own implementation supplies no isolation.
private final class ConcurrentInvocationRegressionSink: DiagnosticSink, @unchecked Sendable {
    private let lock = NSLock()
    private let gate: RegressionDiagnosticGate
    private let firstStarted: RegressionDiagnosticSignal
    private let concurrentInvocation: RegressionDiagnosticSignal
    private let writeFinished: RegressionDiagnosticSignal
    private var activeInvocationCount = 0
    private var maximumActiveInvocationCount = 0
    private var signalledFirstStart = false
    private var signalledConcurrency = false

    init(
        gate: RegressionDiagnosticGate,
        firstStarted: RegressionDiagnosticSignal,
        concurrentInvocation: RegressionDiagnosticSignal,
        writeFinished: RegressionDiagnosticSignal
    ) {
        self.gate = gate
        self.firstStarted = firstStarted
        self.concurrentInvocation = concurrentInvocation
        self.writeFinished = writeFinished
    }

    func write(_ record: DiagnosticRecord) async throws {
        beginInvocation()
        await gate.wait()
        endInvocation()
    }

    var maximumConcurrentInvocations: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximumActiveInvocationCount
    }

    private func beginInvocation() {
        var shouldSignalFirst = false
        var shouldSignalConcurrency = false

        lock.lock()
        activeInvocationCount += 1
        maximumActiveInvocationCount = max(maximumActiveInvocationCount, activeInvocationCount)
        if !signalledFirstStart {
            signalledFirstStart = true
            shouldSignalFirst = true
        }
        if activeInvocationCount > 1, !signalledConcurrency {
            signalledConcurrency = true
            shouldSignalConcurrency = true
        }
        lock.unlock()

        if shouldSignalFirst { firstStarted.signal() }
        if shouldSignalConcurrency { concurrentInvocation.signal() }
    }

    private func endInvocation() {
        lock.lock()
        activeInvocationCount -= 1
        lock.unlock()
        writeFinished.signal()
    }
}

@MainActor
final class DiagnosticsRegressionTests: XCTestCase {
    private let clock = RegressionDiagnosticClock()

    func testDiagnosticEventDecoderRejectsLegacySchemaOne() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                DiagnosticEvent.self,
                from: unscopedEventJSON(schemaVersion: 1, sequence: 1)))
    }

    func testDiagnosticEventDecoderRejectsSchemaTwoWithoutOrigin() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                DiagnosticEvent.self,
                from: unscopedEventJSON(schemaVersion: 2, sequence: 2)))
    }

    func testInitializingSinkLeavesLegacyAndMixedRootStoreByteForByteUntouched() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevDiagnosticsLegacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configuration = RotatingDiagnosticsFileConfiguration(
            directory: root,
            baseName: "events",
            maximumFileBytes: 64 * 1_024,
            maximumFiles: 2)
        var original = Data("  ".utf8)
        original.append(unscopedEventJSON(schemaVersion: 1, sequence: 1))
        original.append(Data(" \n\t".utf8))
        original.append(unscopedEventJSON(schemaVersion: 2, sequence: 2))
        original.append(Data("  \n".utf8))
        try original.write(to: configuration.fileURL(at: 0))

        XCTAssertThrowsError(
            try RotatingJSONLDiagnosticsSink(
                configuration: configuration,
                requiredOrigin: testOrigin))

        XCTAssertEqual(try Data(contentsOf: configuration.fileURL(at: 0)), original)
    }

    func testSuspendedFirstSinkCannotDelayHealthyLaterSinkStarting() async {
        let blockedStarted = expectation(description: "blocked sink starts")
        let healthyStarted = expectation(description: "healthy later sink starts")
        let recordFinished = expectation(description: "record call finishes after cleanup")
        let gate = RegressionDiagnosticGate()
        let completion = RegressionCompletionFlag()
        let center = DiagnosticsCenter(
            sinks: [
                GatedRegressionDiagnosticSink(
                    started: RegressionDiagnosticSignal(blockedStarted),
                    gate: gate),
                SignallingRegressionDiagnosticSink(
                    started: RegressionDiagnosticSignal(healthyStarted)),
            ],
            clock: clock)

        let recordFinishedSignal = RegressionDiagnosticSignal(recordFinished)
        let recordTask = Task {
            await center.record(
                severity: .notice,
                subsystem: .diagnostics,
                code: .appLaunchABIVerified)
            await completion.markComplete()
            recordFinishedSignal.signal()
        }

        await fulfillment(of: [blockedStarted], timeout: 2)
        // The timeout is only a deadlock bound; the assertion is ordering:
        // sink two must be offered the record while sink one remains suspended.
        await fulfillment(of: [healthyStarted], timeout: 1)
        let everyLaneAcceptedBeforeWaiting = await waitUntil {
            let health = await center.snapshot().health.sinks
            return health.count == 2
                && health.allSatisfy {
                    $0.offeredEventCount == 1 && $0.acceptedEventCount == 1
                }
                && health[1].writtenEventCount == 1
        }
        XCTAssertTrue(everyLaneAcceptedBeforeWaiting)
        let completedWhileBlocked = await completion.isComplete
        XCTAssertFalse(completedWhileBlocked)

        await gate.open()
        await fulfillment(of: [recordFinished], timeout: 2)
        await recordTask.value
        let completedAfterSettlement = await completion.isComplete
        XCTAssertTrue(completedAfterSettlement)
        let finalSinkHealth = await center.snapshot().health.sinks
        XCTAssertEqual(finalSinkHealth.map(\.writtenEventCount), [1, 1])
        XCTAssertEqual(finalSinkHealth.map(\.outstandingEventCount), [0, 0])
    }

    func testNonActorAsyncSinkIsNeverInvokedConcurrently() async {
        let invocationCount = 8
        let firstStarted = expectation(description: "first sink invocation starts")
        let concurrentInvocation = expectation(description: "sink is invoked concurrently")
        concurrentInvocation.isInverted = true
        let writesFinished = expectation(description: "all sink invocations finish")
        writesFinished.expectedFulfillmentCount = invocationCount
        let recordsFinished = expectation(description: "all record calls finish")
        recordsFinished.expectedFulfillmentCount = invocationCount

        let gate = RegressionDiagnosticGate()
        let sink = ConcurrentInvocationRegressionSink(
            gate: gate,
            firstStarted: RegressionDiagnosticSignal(firstStarted),
            concurrentInvocation: RegressionDiagnosticSignal(concurrentInvocation),
            writeFinished: RegressionDiagnosticSignal(writesFinished))
        let center = DiagnosticsCenter(sinks: [sink], clock: clock)
        let recordsFinishedSignal = RegressionDiagnosticSignal(recordsFinished)

        let tasks = (0..<invocationCount).map { _ in
            Task {
                await center.record(
                    severity: .debug,
                    subsystem: .diagnostics,
                    code: .appLaunchABIVerified)
                recordsFinishedSignal.signal()
            }
        }

        await fulfillment(of: [firstStarted], timeout: 2)
        // Inverted fulfilment makes concurrency the assertion; the timeout is
        // merely a bounded scheduling window before cleanup opens the gate.
        await fulfillment(of: [concurrentInvocation], timeout: 1)

        await gate.open()
        await fulfillment(of: [writesFinished, recordsFinished], timeout: 2)
        XCTAssertEqual(sink.maximumConcurrentInvocations, 1)
        for task in tasks { task.cancel() }
    }

    func testCancellingFlushCompletesWithoutReleasingHungSink() async {
        let writeStarted = expectation(description: "hung sink write starts")
        let cancellationFinished = expectation(description: "cancelled flush returns")
        let cleanupFinished = expectation(description: "flush eventually returns for cleanup")
        let gate = RegressionDiagnosticGate()
        let center = DiagnosticsCenter(
            sinks: [
                GatedRegressionDiagnosticSink(
                    started: RegressionDiagnosticSignal(writeStarted),
                    gate: gate)
            ],
            clock: clock)
        let emitter = DiagnosticsEmitter(center: center)

        emitter.emit(
            severity: .notice,
            subsystem: .diagnostics,
            code: .appLaunchABIVerified)
        await fulfillment(of: [writeStarted], timeout: 2)

        let cancellationSignal = RegressionDiagnosticSignal(cancellationFinished)
        let cleanupSignal = RegressionDiagnosticSignal(cleanupFinished)
        let flushTask = Task {
            await emitter.flush()
            cancellationSignal.signal()
            cleanupSignal.signal()
        }
        flushTask.cancel()

        // The gate intentionally remains closed through this assertion.
        await fulfillment(of: [cancellationFinished], timeout: 1)

        await gate.open()
        await fulfillment(of: [cleanupFinished], timeout: 2)
        flushTask.cancel()
    }

    func testSchemaTwoRoundTripsImmutableOriginAndCompositeIdentity() throws {
        let event = DiagnosticEvent(
            origin: testOrigin,
            localSequence: 7,
            timestampMilliseconds: clock.millisecondsSince1970(),
            uptimeNanoseconds: clock.uptimeNanoseconds(),
            severity: .warning,
            subsystem: .diagnostics,
            code: .appLaunchABIVerified,
            operationID: nil,
            metadata: DiagnosticMetadata())

        let data = try DiagnosticsJSON.data(for: event)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let decoded = try JSONDecoder().decode(DiagnosticEvent.self, from: data)

        XCTAssertEqual(object["schemaVersion"] as? Int, 2)
        XCTAssertNil(object["sequence"])
        XCTAssertEqual(object["localSequence"] as? UInt64, 7)
        XCTAssertEqual(decoded.origin, testOrigin)
        XCTAssertEqual(decoded.id.runID, testOrigin.runID)
        XCTAssertEqual(decoded.id.processID, testOrigin.processID)
        XCTAssertEqual(decoded.id.localSequence, 7)
    }

    func testOriginRoleLocalityPairsFailClosedAndUnknownCannotOpenDiskSink() throws {
        XCTAssertNil(DiagnosticOrigin(
            runID: UUID(),
            processID: 42,
            role: .app,
            locality: .ephemeralTest))
        XCTAssertNil(DiagnosticOrigin(
            runID: UUID(),
            processID: 42,
            role: .unknown,
            locality: .productionUser))
        XCTAssertNil(DiagnosticOrigin(
            runID: UUID(),
            processID: 0,
            role: .testHost,
            locality: .ephemeralTest))

        let unknown = DiagnosticOrigin(
            validatedRunID: UUID(),
            processID: 42,
            role: .unknown,
            locality: .unknown)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevDiagnosticsUnknown-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = RotatingDiagnosticsFileConfiguration(directory: root)

        XCTAssertThrowsError(try RotatingJSONLDiagnosticsSink(
            configuration: configuration,
            requiredOrigin: unknown)) { error in
            XCTAssertEqual(error as? RotatingDiagnosticsFileError, .unpersistableOrigin)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testScopedProductionDirectoryIsDisjointFromLegacyRootStore() throws {
        let support = URL(fileURLWithPath: "/tmp/application-support", isDirectory: true)
        let production = DiagnosticOrigin(
            validatedRunID: UUID(uuidString: "01234567-89ab-cdef-0123-456789abcdef")!,
            processID: 123,
            role: .app,
            locality: .productionUser)
        let directory = try XCTUnwrap(DiagnosticsBootstrap.scopedDirectory(
            applicationSupportDirectory: support,
            origin: production))

        XCTAssertEqual(
            directory.path,
            "/tmp/application-support/MarkDev/Diagnostics/v2/runs/"
                + "app-01234567-89ab-cdef-0123-456789abcdef-123")
        XCTAssertNotEqual(
            directory.appendingPathComponent("events.jsonl").path,
            "/tmp/application-support/MarkDev/Diagnostics/events.jsonl")
    }

    func testInvalidProcessIDFailsClosedWithoutCreatingDiagnosticsStorage() throws {
        let support = try privateTemporaryApplicationSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let origin = DiagnosticsBootstrap.origin(
            bundleIdentifier: "dev.markdev.MarkDev",
            isRunningTests: false,
            runID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            processID: 0)

        XCTAssertEqual(origin.processID, 0)
        XCTAssertEqual(origin.role, .unknown)
        XCTAssertEqual(origin.locality, .unknown)
        XCTAssertNil(DiagnosticsBootstrap.scopedDirectory(
            applicationSupportDirectory: support,
            origin: origin))
        XCTAssertThrowsError(try DiagnosticsScopedRunStore.acquire(
            applicationSupportDirectory: support,
            origin: origin)) { error in
            XCTAssertEqual(error as? DiagnosticsScopedRunStoreError, .untrustedOrigin)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: support.appendingPathComponent("MarkDev").path))
    }

    func testScopedRunRetentionIsGloballyBoundedAcrossProcessRoles() throws {
        let support = try privateTemporaryApplicationSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let first = productionOrigin(
            runID: "00000000-0000-0000-0000-000000000001",
            processID: 101,
            role: .app)
        let second = productionOrigin(
            runID: "00000000-0000-0000-0000-000000000002",
            processID: 102,
            role: .quickLookExtension)
        let third = productionOrigin(
            runID: "00000000-0000-0000-0000-000000000003",
            processID: 103,
            role: .app)

        try DiagnosticsScopedRunStore.acquire(
            applicationSupportDirectory: support,
            origin: first,
            maximumRetainedRuns: 2).release()
        try DiagnosticsScopedRunStore.acquire(
            applicationSupportDirectory: support,
            origin: second,
            maximumRetainedRuns: 2).release()
        let newest = try DiagnosticsScopedRunStore.acquire(
            applicationSupportDirectory: support,
            origin: third,
            maximumRetainedRuns: 2)
        defer { newest.release() }

        let runRoot = DiagnosticsBootstrap.runRoot(applicationSupportDirectory: support)
        let names = try FileManager.default.contentsOfDirectory(atPath: runRoot.path)
        let retainedRuns = names.filter {
            $0.hasPrefix("app-") || $0.hasPrefix("quick-look-extension-")
        }
        XCTAssertEqual(retainedRuns.count, 2)
        XCTAssertFalse(retainedRuns.contains(DiagnosticsBootstrap.runDirectoryName(origin: first)))
        XCTAssertTrue(retainedRuns.contains(DiagnosticsBootstrap.runDirectoryName(origin: second)))
        XCTAssertTrue(retainedRuns.contains(DiagnosticsBootstrap.runDirectoryName(origin: third)))
    }

    func testActiveRunConsumesCapacityAndIsNeverPruned() throws {
        let support = try privateTemporaryApplicationSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let activeOrigin = productionOrigin(
            runID: "20000000-0000-0000-0000-000000000001",
            processID: 201)
        let refusedOrigin = productionOrigin(
            runID: "20000000-0000-0000-0000-000000000002",
            processID: 202)
        let activeLease = try DiagnosticsScopedRunStore.acquire(
            applicationSupportDirectory: support,
            origin: activeOrigin,
            maximumRetainedRuns: 1)
        defer { activeLease.release() }

        XCTAssertThrowsError(try DiagnosticsScopedRunStore.acquire(
            applicationSupportDirectory: support,
            origin: refusedOrigin,
            maximumRetainedRuns: 1)) { error in
            XCTAssertEqual(
                error as? DiagnosticsScopedRunStoreError,
                .retentionCapacityUnavailable(limit: 1))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: activeLease.directory.path))
        XCTAssertNil(DiagnosticsBootstrap.scopedDirectory(
            applicationSupportDirectory: support,
            origin: refusedOrigin).flatMap {
                FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
            })
    }

    func testRecognizedRunSymlinkFailsClosedWithoutTouchingItsTarget() throws {
        let support = try privateTemporaryApplicationSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let seedOrigin = productionOrigin(
            runID: "30000000-0000-0000-0000-000000000001",
            processID: 301)
        let symlinkOrigin = productionOrigin(
            runID: "30000000-0000-0000-0000-000000000002",
            processID: 302)
        let refusedOrigin = productionOrigin(
            runID: "30000000-0000-0000-0000-000000000003",
            processID: 303)
        let seed = try DiagnosticsScopedRunStore.acquire(
            applicationSupportDirectory: support,
            origin: seedOrigin,
            maximumRetainedRuns: 2)
        seed.release()
        try FileManager.default.removeItem(at: seed.directory)

        let victim = support.appendingPathComponent("victim", isDirectory: true)
        try FileManager.default.createDirectory(
            at: victim,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let sentinel = victim.appendingPathComponent("must-survive")
        try Data("sentinel".utf8).write(to: sentinel)
        let symlink = DiagnosticsBootstrap.runRoot(applicationSupportDirectory: support)
            .appendingPathComponent(DiagnosticsBootstrap.runDirectoryName(origin: symlinkOrigin))
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: victim)

        XCTAssertThrowsError(try DiagnosticsScopedRunStore.acquire(
            applicationSupportDirectory: support,
            origin: refusedOrigin,
            maximumRetainedRuns: 1)) { error in
            XCTAssertEqual(
                error as? DiagnosticsScopedRunStoreError,
                .retentionCapacityUnavailable(limit: 1))
        }
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("sentinel".utf8))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: symlink.path),
            victim.path)
    }

    func testHardLinkedActiveLockIsPreservedAndBlocksPruning() throws {
        let support = try privateTemporaryApplicationSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let staleOrigin = productionOrigin(
            runID: "40000000-0000-0000-0000-000000000001",
            processID: 401)
        let refusedOrigin = productionOrigin(
            runID: "40000000-0000-0000-0000-000000000002",
            processID: 402)
        let stale = try DiagnosticsScopedRunStore.acquire(
            applicationSupportDirectory: support,
            origin: staleOrigin,
            maximumRetainedRuns: 1)
        stale.release()
        let activeLock = stale.directory.appendingPathComponent(".active.lock")
        let secondLink = support.appendingPathComponent("active-lock-alias")
        let linkResult = activeLock.path.withCString { source in
            secondLink.path.withCString { destination in
                Darwin.link(source, destination)
            }
        }
        XCTAssertEqual(linkResult, 0)

        XCTAssertThrowsError(try DiagnosticsScopedRunStore.acquire(
            applicationSupportDirectory: support,
            origin: refusedOrigin,
            maximumRetainedRuns: 1)) { error in
            XCTAssertEqual(
                error as? DiagnosticsScopedRunStoreError,
                .retentionCapacityUnavailable(limit: 1))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: activeLock.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondLink.path))
    }

    func testForeignRunChildIsPreservedAndBlocksPruning() throws {
        let support = try privateTemporaryApplicationSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let staleOrigin = productionOrigin(
            runID: "41000000-0000-0000-0000-000000000001",
            processID: 411)
        let refusedOrigin = productionOrigin(
            runID: "41000000-0000-0000-0000-000000000002",
            processID: 412)
        let stale = try DiagnosticsScopedRunStore.acquire(
            applicationSupportDirectory: support,
            origin: staleOrigin,
            maximumRetainedRuns: 1)
        stale.release()
        let foreign = stale.directory.appendingPathComponent("foreign.bin")
        try Data("foreign".utf8).write(to: foreign)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: foreign.path)

        XCTAssertThrowsError(try DiagnosticsScopedRunStore.acquire(
            applicationSupportDirectory: support,
            origin: refusedOrigin,
            maximumRetainedRuns: 1)) { error in
            XCTAssertEqual(
                error as? DiagnosticsScopedRunStoreError,
                .retentionCapacityUnavailable(limit: 1))
        }
        XCTAssertEqual(try Data(contentsOf: foreign), Data("foreign".utf8))
    }

    func testCandidateNamespaceSubstitutionCannotRedirectRetirement() throws {
        let support = try privateTemporaryApplicationSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let staleOrigin = productionOrigin(
            runID: "50000000-0000-0000-0000-000000000001",
            processID: 501)
        let refusedOrigin = productionOrigin(
            runID: "50000000-0000-0000-0000-000000000002",
            processID: 502)
        let stale = try DiagnosticsScopedRunStore.acquire(
            applicationSupportDirectory: support,
            origin: staleOrigin,
            maximumRetainedRuns: 1)
        stale.release()

        let victim = support.appendingPathComponent("swap-victim", isDirectory: true)
        try FileManager.default.createDirectory(
            at: victim,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let sentinel = victim.appendingPathComponent("must-survive")
        try Data("sentinel".utf8).write(to: sentinel)
        let displaced = support.appendingPathComponent("displaced-run", isDirectory: true)
        var didSubstitute = false
        let hooks = DiagnosticsScopedRunStoreTestingHooks(
            beforeCandidateRetirement: { candidate in
                guard !didSubstitute else { return }
                didSubstitute = true
                try! FileManager.default.moveItem(at: candidate, to: displaced)
                try! FileManager.default.createSymbolicLink(
                    at: candidate,
                    withDestinationURL: victim)
            })

        XCTAssertThrowsError(try DiagnosticsScopedRunStore.acquire(
            applicationSupportDirectory: support,
            origin: refusedOrigin,
            maximumRetainedRuns: 1,
            testingHooks: hooks)) { error in
            XCTAssertEqual(
                error as? DiagnosticsScopedRunStoreError,
                .retentionCapacityUnavailable(limit: 1))
        }
        XCTAssertTrue(didSubstitute)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("sentinel".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: displaced.path))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: stale.directory.path),
            victim.path)
    }

    func testHardLinkedRetentionLockFailsClosedBeforeCreatingAnotherRun() throws {
        let support = try privateTemporaryApplicationSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let seedOrigin = productionOrigin(
            runID: "51000000-0000-0000-0000-000000000001",
            processID: 511)
        let refusedOrigin = productionOrigin(
            runID: "51000000-0000-0000-0000-000000000002",
            processID: 512)
        let seed = try DiagnosticsScopedRunStore.acquire(
            applicationSupportDirectory: support,
            origin: seedOrigin,
            maximumRetainedRuns: 2)
        seed.release()
        let runRoot = DiagnosticsBootstrap.runRoot(applicationSupportDirectory: support)
        let retentionLock = runRoot.appendingPathComponent(".retention.lock")
        let alias = support.appendingPathComponent("retention-lock-alias")
        let linkResult = retentionLock.path.withCString { source in
            alias.path.withCString { destination in
                Darwin.link(source, destination)
            }
        }
        XCTAssertEqual(linkResult, 0)

        XCTAssertThrowsError(try DiagnosticsScopedRunStore.acquire(
            applicationSupportDirectory: support,
            origin: refusedOrigin,
            maximumRetainedRuns: 2))
        XCTAssertTrue(FileManager.default.fileExists(atPath: retentionLock.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: alias.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: DiagnosticsBootstrap.scopedDirectory(
                applicationSupportDirectory: support,
                origin: refusedOrigin)!.path))
    }

    func testNonPrivateRunDirectoryModeIsPreservedAndBlocksPruning() throws {
        let support = try privateTemporaryApplicationSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let staleOrigin = productionOrigin(
            runID: "52000000-0000-0000-0000-000000000001",
            processID: 521)
        let refusedOrigin = productionOrigin(
            runID: "52000000-0000-0000-0000-000000000002",
            processID: 522)
        let stale = try DiagnosticsScopedRunStore.acquire(
            applicationSupportDirectory: support,
            origin: staleOrigin,
            maximumRetainedRuns: 1)
        stale.release()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: stale.directory.path)

        XCTAssertThrowsError(try DiagnosticsScopedRunStore.acquire(
            applicationSupportDirectory: support,
            origin: refusedOrigin,
            maximumRetainedRuns: 1)) { error in
            XCTAssertEqual(
                error as? DiagnosticsScopedRunStoreError,
                .retentionCapacityUnavailable(limit: 1))
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: stale.directory.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
    }

    func testStrandedEmptyRetirementTombstoneIsReclaimed() throws {
        let support = try privateTemporaryApplicationSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let staleOrigin = productionOrigin(
            runID: "53000000-0000-0000-0000-000000000001",
            processID: 531)
        let replacementOrigin = productionOrigin(
            runID: "53000000-0000-0000-0000-000000000002",
            processID: 532)
        let stale = try DiagnosticsScopedRunStore.acquire(
            applicationSupportDirectory: support,
            origin: staleOrigin,
            maximumRetainedRuns: 1)
        stale.release()
        let tombstone = DiagnosticsBootstrap.runRoot(applicationSupportDirectory: support)
            .appendingPathComponent(
                ".retired-53000000-0000-0000-0000-000000000003",
                isDirectory: true)
        try FileManager.default.moveItem(at: stale.directory, to: tombstone)
        try FileManager.default.removeItem(
            at: tombstone.appendingPathComponent(".active.lock"))

        let replacement = try DiagnosticsScopedRunStore.acquire(
            applicationSupportDirectory: support,
            origin: replacementOrigin,
            maximumRetainedRuns: 1)
        defer { replacement.release() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tombstone.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacement.directory.path))
    }

    func testRetirementTombstoneWithForeignChildFailsClosed() throws {
        let support = try privateTemporaryApplicationSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let staleOrigin = productionOrigin(
            runID: "54000000-0000-0000-0000-000000000001",
            processID: 541)
        let refusedOrigin = productionOrigin(
            runID: "54000000-0000-0000-0000-000000000002",
            processID: 542)
        let stale = try DiagnosticsScopedRunStore.acquire(
            applicationSupportDirectory: support,
            origin: staleOrigin,
            maximumRetainedRuns: 1)
        stale.release()
        let tombstone = DiagnosticsBootstrap.runRoot(applicationSupportDirectory: support)
            .appendingPathComponent(
                ".retired-54000000-0000-0000-0000-000000000003",
                isDirectory: true)
        try FileManager.default.moveItem(at: stale.directory, to: tombstone)
        let foreign = tombstone.appendingPathComponent("foreign.bin")
        try writePrivate(Data("foreign".utf8), to: foreign)

        XCTAssertThrowsError(try DiagnosticsScopedRunStore.acquire(
            applicationSupportDirectory: support,
            origin: refusedOrigin,
            maximumRetainedRuns: 1)) { error in
            XCTAssertEqual(
                error as? DiagnosticsScopedRunStoreError,
                .retentionCapacityUnavailable(limit: 1))
        }
        XCTAssertEqual(try Data(contentsOf: foreign), Data("foreign".utf8))
    }

    func testInterruptedRetirementResumesAtEveryMutationBoundary() throws {
        let stages: [DiagnosticsScopedRunStoreMutationStage] = [
            .candidateRenamed,
            .retirementRenameSynced,
            .childUnlinked("events.1.jsonl"),
            .childUnlinked("events.jsonl"),
            .activeLockUnlinked,
            .runDirectorySynced,
            .retiredDirectoryRemoved,
            .retirementRemovalSynced,
        ]

        for (index, targetStage) in stages.enumerated() {
            let support = try privateTemporaryApplicationSupport()
            defer { try? FileManager.default.removeItem(at: support) }
            let suffix = String(format: "%012d", index + 1)
            let staleOrigin = productionOrigin(
                runID: "55000000-0000-0000-0000-\(suffix)",
                processID: Int32(551 + index * 2))
            let replacementOrigin = productionOrigin(
                runID: "56000000-0000-0000-0000-\(suffix)",
                processID: Int32(552 + index * 2))
            let stale = try DiagnosticsScopedRunStore.acquire(
                applicationSupportDirectory: support,
                origin: staleOrigin,
                maximumRetainedRuns: 1)
            stale.release()
            try writePrivate(
                Data("older".utf8),
                to: stale.directory.appendingPathComponent("events.1.jsonl"))
            try writePrivate(
                Data("current".utf8),
                to: stale.directory.appendingPathComponent("events.jsonl"))

            var didInterrupt = false
            let hooks = DiagnosticsScopedRunStoreTestingHooks(
                afterMutation: { stage in
                    guard !didInterrupt, stage == targetStage else { return }
                    didInterrupt = true
                    throw InjectedStoreInterruption()
                })
            XCTAssertThrowsError(try DiagnosticsScopedRunStore.acquire(
                applicationSupportDirectory: support,
                origin: replacementOrigin,
                maximumRetainedRuns: 1,
                testingHooks: hooks)) { error in
                XCTAssertTrue(error is InjectedStoreInterruption)
            }
            XCTAssertTrue(didInterrupt, "mutation stage was not reached: \(targetStage)")

            let replacement = try DiagnosticsScopedRunStore.acquire(
                applicationSupportDirectory: support,
                origin: replacementOrigin,
                maximumRetainedRuns: 1)
            replacement.release()
            let runRoot = DiagnosticsBootstrap.runRoot(applicationSupportDirectory: support)
            let names = try FileManager.default.contentsOfDirectory(atPath: runRoot.path)
            XCTAssertFalse(names.contains(where: { $0.hasPrefix(".retired-") }))
            XCTAssertEqual(
                names.filter { $0.hasPrefix("app-") || $0.hasPrefix("quick-look-extension-") },
                [DiagnosticsBootstrap.runDirectoryName(origin: replacementOrigin)])
        }
    }

    func testCenterSequenceMaximumIsEmittedOnceThenFurtherRecordsAreDropped() async {
        let center = DiagnosticsCenter(sinks: [], clock: clock, origin: testOrigin)
        await center.setNextSequenceForTesting(.max)

        await center.record(
            severity: .info,
            subsystem: .diagnostics,
            code: .appLaunchABIVerified)
        await center.record(
            severity: .info,
            subsystem: .diagnostics,
            code: .appLaunchABIVerified)

        let snapshot = await center.snapshot()
        XCTAssertEqual(snapshot.events.map(\.localSequence), [.max])
        XCTAssertEqual(snapshot.health.recordedEventCount, 1)
        XCTAssertEqual(snapshot.health.ingressDroppedEventCount, 1)
    }

    func testEmitterAdmissionMaximumIsAcceptedOnceWithoutBarrierAlias() async throws {
        let center = DiagnosticsCenter(sinks: [], clock: clock, origin: testOrigin)
        let emitter = DiagnosticsEmitter(
            center: center,
            configuration: DiagnosticsEmitterConfiguration(maximumPendingEvents: 4))
        emitter.setNextAdmissionSequenceForTesting(.max)

        emitter.emit(
            severity: .info,
            subsystem: .diagnostics,
            code: .appLaunchABIVerified)
        emitter.emit(
            severity: .info,
            subsystem: .diagnostics,
            code: .appLaunchABIVerified)
        _ = try await emitter.flush(deadline: .after(nanoseconds: 5_000_000_000))

        let state = emitter.admissionStateForTesting()
        let snapshot = await center.snapshot()
        XCTAssertEqual(state.lastAcceptedSequence, .max)
        XCTAssertNil(state.nextAcceptedSequence)
        XCTAssertEqual(state.droppedEventCount, 1)
        XCTAssertEqual(snapshot.health.recordedEventCount, 1)
        XCTAssertEqual(snapshot.health.ingressDroppedEventCount, 1)
    }

    func testSinkCapacityIncludesInFlightAndDropsExactlyOneAtBoundaryPlusOne() async throws {
        let started = expectation(description: "bounded sink starts")
        let gate = RegressionDiagnosticGate()
        let sink = BoundedGatedRegressionDiagnosticSink(
            started: RegressionDiagnosticSignal(started),
            gate: gate)
        let center = DiagnosticsCenter(
            registrations: [
                DiagnosticSinkRegistration(
                    id: DiagnosticSinkID(knownRawValue: "bounded"),
                    sink: sink,
                    maximumOutstandingRecords: 2)
            ],
            clock: clock,
            origin: testOrigin)
        let emitter = DiagnosticsEmitter(center: center)

        for _ in 0..<3 {
            emitter.emit(
                severity: .notice,
                subsystem: .diagnostics,
                code: .appLaunchABIVerified)
        }
        await fulfillment(of: [started], timeout: 2)
        let reserved = try await emitter.captureCutForTesting(
            deadline: .after(nanoseconds: 5_000_000_000))
        let sinkHealth = try XCTUnwrap(reserved.cut.snapshot.health.sinks.first)

        XCTAssertEqual(sinkHealth.offeredEventCount, 3)
        XCTAssertEqual(sinkHealth.acceptedEventCount, 2)
        XCTAssertEqual(sinkHealth.droppedEventCount, 1)
        XCTAssertEqual(sinkHealth.outstandingEventCount, 2)
        XCTAssertEqual(sinkHealth.maximumOutstandingEventCount, 2)

        await gate.open()
        let receipt = try await emitter.settleCutForTesting(
            reserved,
            deadline: .after(nanoseconds: 5_000_000_000))
        let result = try XCTUnwrap(receipt.sinks.first)
        XCTAssertEqual(result.writtenEventCount, 2)
        XCTAssertEqual(result.failureCount, 0)
        XCTAssertEqual(result.pendingEventCount, 0)
        XCTAssertEqual(result.cut.droppedEventCount, 1)
    }

    func testSinkFailureAndDeliveryDropRemainDistinctAndConserved() async throws {
        let started = expectation(description: "failing bounded sink starts")
        let gate = RegressionDiagnosticGate()
        let sink = BoundedGatedRegressionDiagnosticSink(
            started: RegressionDiagnosticSignal(started),
            gate: gate,
            shouldFail: true)
        let center = DiagnosticsCenter(
            registrations: [
                DiagnosticSinkRegistration(
                    id: DiagnosticSinkID(knownRawValue: "failing"),
                    sink: sink,
                    maximumOutstandingRecords: 1)
            ],
            clock: clock,
            origin: testOrigin)
        let emitter = DiagnosticsEmitter(center: center)

        emitter.emit(
            severity: .error,
            subsystem: .diagnostics,
            code: .appLaunchABIVerified)
        await fulfillment(of: [started], timeout: 2)
        emitter.emit(
            severity: .error,
            subsystem: .diagnostics,
            code: .appLaunchABIVerified)
        let reserved = try await emitter.captureCutForTesting(
            deadline: .after(nanoseconds: 5_000_000_000))

        await gate.open()
        let receipt = try await emitter.settleCutForTesting(
            reserved,
            deadline: .after(nanoseconds: 5_000_000_000))
        let result = try XCTUnwrap(receipt.sinks.first)
        let health = await center.snapshot().health
        let sinkHealth = try XCTUnwrap(health.sinks.first)

        XCTAssertEqual(result.writtenEventCount, 0)
        XCTAssertEqual(result.failureCount, 1)
        XCTAssertEqual(result.pendingEventCount, 0)
        XCTAssertEqual(result.cut.droppedEventCount, 1)
        XCTAssertEqual(sinkHealth.offeredEventCount, 2)
        XCTAssertEqual(sinkHealth.acceptedEventCount, 1)
        XCTAssertEqual(sinkHealth.failureCount, 1)
        XCTAssertEqual(sinkHealth.droppedEventCount, 1)
        XCTAssertEqual(health.sinkFailureCount, 1)
        XCTAssertEqual(health.sinkDeliveryDroppedEventCount, 1)
        XCTAssertEqual(health.droppedEventCount, 0)
    }

    func testCapturedCutExcludesEventsEmittedAfterItsMarker() async throws {
        let center = DiagnosticsCenter(sinks: [], clock: clock, origin: testOrigin)
        let emitter = DiagnosticsEmitter(center: center)
        emitter.emit(
            severity: .info,
            subsystem: .diagnostics,
            code: .appLaunchABIVerified)

        let reserved = try await emitter.captureCutForTesting(
            deadline: .after(nanoseconds: 5_000_000_000))
        emitter.emit(
            severity: .warning,
            subsystem: .diagnostics,
            code: .appLaunchABIVerified)

        XCTAssertEqual(reserved.cut.snapshot.events.map(\.sequence), [1])
        _ = try await emitter.settleCutForTesting(
            reserved,
            deadline: .after(nanoseconds: 5_000_000_000))
        _ = try await emitter.flush(deadline: .after(nanoseconds: 5_000_000_000))
        let finalSequences = await center.snapshot().events.map(\.sequence)
        XCTAssertEqual(finalSequences, [1, 2])
    }

    func testConcurrentEmitterFloodIsOrderedAndConserved() async throws {
        let eventCount = 1_000
        let sink = CollectingRegressionDiagnosticSink()
        let center = DiagnosticsCenter(
            configuration: DiagnosticsConfiguration(
                memoryEventLimit: eventCount,
                memoryByteLimit: 2 * 1_024 * 1_024,
                supportReportByteLimit: 2 * 1_024 * 1_024,
                maximumPendingRecordsPerSink: eventCount),
            registrations: [
                DiagnosticSinkRegistration(
                    id: DiagnosticSinkID(knownRawValue: "collector"),
                    sink: sink,
                    maximumOutstandingRecords: eventCount)
            ],
            clock: clock,
            origin: testOrigin)
        let emitter = DiagnosticsEmitter(
            center: center,
            configuration: DiagnosticsEmitterConfiguration(maximumPendingEvents: eventCount))

        DispatchQueue.concurrentPerform(iterations: eventCount) { _ in
            emitter.emit(
                severity: .debug,
                subsystem: .diagnostics,
                code: .appLaunchABIVerified)
        }
        let receipt = try await emitter.flush(
            deadline: .after(nanoseconds: 10_000_000_000))
        let snapshot = await center.snapshot()
        let delivered = await sink.sequences
        let expected = Array(UInt64(1)...UInt64(eventCount))
        let sinkHealth = try XCTUnwrap(snapshot.health.sinks.first)

        XCTAssertTrue(receipt.isFullySettled)
        XCTAssertEqual(snapshot.events.map(\.sequence), expected)
        XCTAssertEqual(delivered, expected)
        XCTAssertEqual(snapshot.health.recordedEventCount, UInt64(eventCount))
        XCTAssertEqual(snapshot.health.ingressDroppedEventCount, 0)
        XCTAssertEqual(sinkHealth.offeredEventCount, UInt64(eventCount))
        XCTAssertEqual(
            sinkHealth.acceptedEventCount + sinkHealth.droppedEventCount,
            sinkHealth.offeredEventCount)
        XCTAssertEqual(
            sinkHealth.writtenEventCount + sinkHealth.failureCount
                + UInt64(sinkHealth.outstandingEventCount),
            sinkHealth.acceptedEventCount)
    }

    func testDeadlineReturnsImmutablePerLanePartialWithoutReleasingHungSink() async throws {
        let blockedStarted = expectation(description: "blocked sink starts")
        let blockedFinished = expectation(description: "blocked sink finishes after cleanup")
        let healthyStarted = expectation(description: "healthy sink starts")
        let gate = RegressionDiagnosticGate()
        let clock = ManualRegressionBarrierClock()
        let center = DiagnosticsCenter(
            registrations: [
                DiagnosticSinkRegistration(
                    id: DiagnosticSinkID(knownRawValue: "blocked"),
                    sink: BoundedGatedRegressionDiagnosticSink(
                        started: RegressionDiagnosticSignal(blockedStarted),
                        finished: RegressionDiagnosticSignal(blockedFinished),
                        gate: gate)),
                DiagnosticSinkRegistration(
                    id: DiagnosticSinkID(knownRawValue: "healthy"),
                    sink: SignallingRegressionDiagnosticSink(
                        started: RegressionDiagnosticSignal(healthyStarted))),
            ],
            clock: self.clock,
            origin: testOrigin)
        let emitter = DiagnosticsEmitter(center: center, barrierClock: clock)
        emitter.emit(
            severity: .notice,
            subsystem: .diagnostics,
            code: .appLaunchABIVerified)
        await fulfillment(of: [blockedStarted, healthyStarted], timeout: 2)
        let reserved = try await emitter.captureCutForTesting(
            deadline: DiagnosticDeadline(uptimeNanoseconds: 100))

        let settlement = Task {
            try await emitter.settleCutForTesting(
                reserved,
                deadline: DiagnosticDeadline(uptimeNanoseconds: 10))
        }
        let deadlineSleeperStarted = await waitUntil { clock.pendingSleeperCount == 1 }
        XCTAssertTrue(deadlineSleeperStarted)
        clock.advance(to: 10)

        do {
            _ = try await settlement.value
            XCTFail("a hung lane must produce a deadline partial")
        } catch let DiagnosticsBarrierError.deadlineExceeded(partial) {
            let receipt = try XCTUnwrap(partial)
            let byID = Dictionary(uniqueKeysWithValues: receipt.sinks.map { ($0.cut.id, $0) })
            let blocked = try XCTUnwrap(byID[DiagnosticSinkID(knownRawValue: "blocked")])
            let healthy = try XCTUnwrap(byID[DiagnosticSinkID(knownRawValue: "healthy")])
            XCTAssertEqual(blocked.state, .pending)
            XCTAssertEqual(blocked.pendingEventCount, 1)
            XCTAssertEqual(healthy.state, .settled)
            XCTAssertEqual(healthy.writtenEventCount, 1)
            for result in receipt.sinks {
                XCTAssertEqual(
                    result.writtenEventCount + result.failureCount + result.pendingEventCount,
                    result.cut.acceptedEventCount)
            }
        } catch {
            XCTFail("unexpected deadline error: \(error)")
        }

        await gate.open()
        await fulfillment(of: [blockedFinished], timeout: 2)
    }

    func testTimedOutSupportExportWritesFrozenPartialDeliveryState() async throws {
        let root = try privateTemporaryApplicationSupport()
        defer { try? FileManager.default.removeItem(at: root) }
        let blockedStarted = expectation(description: "blocked export sink starts")
        let blockedFinished = expectation(description: "blocked export sink finishes")
        let gate = RegressionDiagnosticGate()
        let barrierClock = ManualRegressionBarrierClock()
        let center = DiagnosticsCenter(
            registrations: [
                DiagnosticSinkRegistration(
                    id: DiagnosticSinkID(knownRawValue: "blocked-export"),
                    sink: BoundedGatedRegressionDiagnosticSink(
                        started: RegressionDiagnosticSignal(blockedStarted),
                        finished: RegressionDiagnosticSignal(blockedFinished),
                        gate: gate))
            ],
            clock: clock,
            origin: testOrigin)
        let emitter = DiagnosticsEmitter(center: center, barrierClock: barrierClock)
        emitter.emit(
            severity: .notice,
            subsystem: .diagnostics,
            code: .appLaunchABIVerified)
        await fulfillment(of: [blockedStarted], timeout: 2)
        let destination = root.appendingPathComponent("partial-report.json")

        let export = Task {
            try await emitter.exportSupportReport(
                deadline: DiagnosticDeadline(uptimeNanoseconds: 10),
                to: destination,
                metadata: regressionReportMetadata,
                generatedAtMilliseconds: 1_700_000_000_999)
        }
        let settlementDeadlineIsWaiting = await waitUntil {
            let pendingBarriers = await center.pendingSinkBarrierCountForTesting()
            return pendingBarriers == 1
                && barrierClock.pendingSleeperCount == 1
                && barrierClock.sleepInvocationCount >= 2
        }
        XCTAssertTrue(settlementDeadlineIsWaiting)
        barrierClock.advance(to: 10)

        let summary = try await export.value
        let data = try Data(contentsOf: destination)
        let report = try JSONDecoder().decode(DiagnosticSupportReport.self, from: data)
        XCTAssertEqual(summary.deliveryState, .timedOut)
        XCTAssertEqual(report.formatVersion, 2)
        XCTAssertEqual(report.delivery.state, .timedOut)
        XCTAssertNotNil(report.delivery.markerID)
        XCTAssertEqual(report.events.map(\.sequence), [1])
        let sink = try XCTUnwrap(report.delivery.sinks.first)
        XCTAssertEqual(sink.cut.id, DiagnosticSinkID(knownRawValue: "blocked-export"))
        XCTAssertEqual(sink.state, .pending)
        XCTAssertEqual(sink.writtenEventCount, 0)
        XCTAssertEqual(sink.failureCount, 0)
        XCTAssertEqual(sink.pendingEventCount, 1)
        XCTAssertEqual(
            sink.writtenEventCount + sink.failureCount + sink.pendingEventCount,
            sink.cut.acceptedEventCount)

        await gate.open()
        await fulfillment(of: [blockedFinished], timeout: 2)
    }

    func testActiveFlushWaiterLimitCoversCapturedWaitersAndRepeatedCancellation() async {
        let started = expectation(description: "hung sink starts")
        let finished = expectation(description: "hung sink cleanup finishes")
        let gate = RegressionDiagnosticGate()
        let sink = BoundedGatedRegressionDiagnosticSink(
            started: RegressionDiagnosticSignal(started),
            finished: RegressionDiagnosticSignal(finished),
            gate: gate)
        let center = DiagnosticsCenter(
            configuration: DiagnosticsConfiguration(maximumBarrierWaitersPerSink: 8),
            sinks: [sink],
            clock: clock,
            origin: testOrigin)
        let emitter = DiagnosticsEmitter(
            center: center,
            configuration: DiagnosticsEmitterConfiguration(
                maximumPendingEvents: 8,
                maximumFlushWaiters: 2,
                defaultFlushTimeoutNanoseconds: 60_000_000_000))
        emitter.emit(
            severity: .notice,
            subsystem: .diagnostics,
            code: .appLaunchABIVerified)
        await fulfillment(of: [started], timeout: 2)

        let finishedWaiters = expectation(description: "cancelled waiters finish")
        finishedWaiters.expectedFulfillmentCount = 2
        let signal = RegressionDiagnosticSignal(finishedWaiters)
        let waiters = (0..<2).map { _ in
            Task {
                defer { signal.signal() }
                do {
                    _ = try await emitter.flush(
                        deadline: DiagnosticDeadline(uptimeNanoseconds: .max))
                    return false
                } catch is CancellationError {
                    return true
                } catch {
                    return false
                }
            }
        }
        let capturedBothWaiters = await waitUntil {
            await center.pendingSinkBarrierCountForTesting() == 2
        }
        XCTAssertTrue(capturedBothWaiters)
        XCTAssertEqual(emitter.activeFlushReservationCountForTesting, 2)

        do {
            _ = try await emitter.flush(
                deadline: DiagnosticDeadline(uptimeNanoseconds: .max))
            XCTFail("N+1 flush must be rejected while N captured waits remain active")
        } catch let error as DiagnosticsBarrierError {
            XCTAssertEqual(error, .waiterLimitExceeded(limit: 2))
        } catch {
            XCTFail("unexpected waiter limit error: \(error)")
        }

        for waiter in waiters { waiter.cancel() }
        await fulfillment(of: [finishedWaiters], timeout: 2)
        for waiter in waiters {
            let wasCancelled = await waiter.value
            XCTAssertTrue(wasCancelled)
        }
        let firstCancellationDrained = await waitUntil {
            let pendingSinkBarriers = await center.pendingSinkBarrierCountForTesting()
            return emitter.activeFlushReservationCountForTesting == 0
                && pendingSinkBarriers == 0
        }
        XCTAssertTrue(firstCancellationDrained)

        for _ in 0..<8 {
            let cancelled = expectation(description: "repeated cancellation finishes")
            let cancelledSignal = RegressionDiagnosticSignal(cancelled)
            let waiter = Task {
                defer { cancelledSignal.signal() }
                do {
                    _ = try await emitter.flush(
                        deadline: DiagnosticDeadline(uptimeNanoseconds: .max))
                    return false
                } catch is CancellationError {
                    return true
                } catch {
                    return false
                }
            }
            let waiterWasCaptured = await waitUntil {
                await center.pendingSinkBarrierCountForTesting() == 1
            }
            XCTAssertTrue(waiterWasCaptured)
            waiter.cancel()
            await fulfillment(of: [cancelled], timeout: 2)
            let wasCancelled = await waiter.value
            XCTAssertTrue(wasCancelled)
            let cancellationDrained = await waitUntil {
                let pendingSinkBarriers = await center.pendingSinkBarrierCountForTesting()
                return emitter.activeFlushReservationCountForTesting == 0
                    && pendingSinkBarriers == 0
            }
            XCTAssertTrue(cancellationDrained)
        }

        await gate.open()
        await fulfillment(of: [finished], timeout: 2)
    }

    func testAlreadyCancelledFlushWithNoSinksCannotReturnSuccess() async {
        let start = RegressionDiagnosticGate()
        let center = DiagnosticsCenter(sinks: [], clock: clock, origin: testOrigin)
        let emitter = DiagnosticsEmitter(center: center)
        let task = Task {
            await start.wait()
            do {
                _ = try await emitter.flush(
                    deadline: DiagnosticDeadline(uptimeNanoseconds: .max))
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }

        task.cancel()
        await start.open()
        let wasCancelled = await task.value
        XCTAssertTrue(wasCancelled)
        XCTAssertEqual(emitter.activeFlushReservationCountForTesting, 0)
    }

    private func privateTemporaryApplicationSupport() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("MarkDevDiagnosticsStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path)
        return directory
    }

    private func productionOrigin(
        runID: String,
        processID: Int32,
        role: DiagnosticProcessRole = .app
    ) -> DiagnosticOrigin {
        DiagnosticOrigin(
            validatedRunID: UUID(uuidString: runID)!,
            processID: processID,
            role: role,
            locality: .productionUser)
    }

    private func writePrivate(_ data: Data, to destination: URL) throws {
        try data.write(to: destination)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination.path)
    }

    private func unscopedEventJSON(schemaVersion: Int, sequence: UInt64) -> Data {
        var fields = [
            "\"metadata\":{}",
            "\"code\":\"app.launch.abi-verified\"",
            "\"subsystem\":\"diagnostics\"",
            "\"severity\":\"info\"",
            "\"uptimeNanoseconds\":\(sequence)",
            "\"timestampMilliseconds\":1700000000123",
            "\"sequence\":\(sequence)",
            "\"schemaVersion\":\(schemaVersion)",
        ]
        if schemaVersion == 2 {
            // Current schema-one code ignores this unknown field. The strict
            // schema-two implementation can therefore fail specifically for
            // the absent origin rather than an absent local sequence.
            fields.append("\"localSequence\":\(sequence)")
        }
        return Data(("{" + fields.joined(separator: ",") + "}").utf8)
    }

    private var testOrigin: DiagnosticOrigin {
        DiagnosticOrigin(
            validatedRunID: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!,
            processID: 42,
            role: .testHost,
            locality: .ephemeralTest)
    }

    private var regressionReportMetadata: DiagnosticReportMetadata {
        DiagnosticReportMetadata(
            app: DiagnosticAppMetadata(
                name: "MarkDev",
                bundleIdentifier: "dev.markdev.MarkDev"),
            build: DiagnosticBuildMetadata(
                version: "0.0.4",
                buildNumber: "10",
                sourceCommit: "0123456789abcdef0123456789abcdef01234567"),
            operatingSystem: DiagnosticOSMetadata(
                name: "macOS",
                version: "26.0.0",
                architecture: "arm64"))
    }

    private func waitUntil(
        attempts: Int = 2_000,
        _ predicate: () async -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return false
    }
}
