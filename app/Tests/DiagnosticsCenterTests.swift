//
//  DiagnosticsCenterTests.swift
//  MarkDevKitTests
//
//  The diagnostics event boundary and its in-memory retention contract.
//

import Foundation
import XCTest

@testable import MarkDevKit

final class DiagnosticsCenterTests: XCTestCase {
    private struct FixedClock: DiagnosticClock {
        let milliseconds: Int64
        let uptime: UInt64

        func millisecondsSince1970() -> Int64 { milliseconds }
        func uptimeNanoseconds() -> UInt64 { uptime }
    }

    private actor FailingSink: DiagnosticSink {
        private(set) var attempts = 0

        func write(_ record: DiagnosticRecord) async throws {
            attempts += 1
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    private actor CountingSink: DiagnosticSink {
        private(set) var sequences: [UInt64] = []

        func write(_ record: DiagnosticRecord) async throws {
            sequences.append(record.event.sequence)
        }
    }

    private let clock = FixedClock(milliseconds: 1_700_000_000_123, uptime: 42)
    private let origin = DiagnosticOrigin(
        validatedRunID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        processID: 42,
        role: .testHost,
        locality: .ephemeralTest)

    func testCountBoundaryEvictsOldestAndAccountsForEveryDrop() async {
        let center = DiagnosticsCenter(
            configuration: DiagnosticsConfiguration(
                memoryEventLimit: 3,
                memoryByteLimit: 64 * 1_024,
                supportReportByteLimit: 128 * 1_024),
            clock: clock)

        for value in 1...4 {
            await center.record(
                severity: .info,
                subsystem: .diagnostics,
                code: .appLaunchABIVerified,
                metadata: DiagnosticMetadata([.attemptedCount: .integer(Int64(value))]))
        }

        let snapshot = await center.snapshot()
        XCTAssertEqual(snapshot.events.map(\.sequence), [2, 3, 4])
        XCTAssertEqual(snapshot.health.recordedEventCount, 4)
        XCTAssertEqual(snapshot.health.retainedEventCount, 3)
        XCTAssertEqual(snapshot.health.evictedEventCount, 1)
        XCTAssertEqual(snapshot.health.oversizedEventCount, 0)
        XCTAssertEqual(snapshot.health.droppedEventCount, 1)
        XCTAssertLessThanOrEqual(snapshot.health.retainedByteCount, 64 * 1_024)
    }

    func testByteBoundaryAcceptsExactFitAndRejectsOneByteLess() async throws {
        let event = DiagnosticEvent(
            origin: origin,
            localSequence: 1,
            timestampMilliseconds: clock.milliseconds,
            uptimeNanoseconds: clock.uptime,
            severity: .warning,
            subsystem: .filesystem,
            code: .appLaunchABIVerified,
            operationID: nil,
            metadata: DiagnosticMetadata())
        let exactBytes = try DiagnosticsJSON.line(for: event).count

        let exact = DiagnosticsCenter(
            configuration: DiagnosticsConfiguration(
                memoryEventLimit: 1,
                memoryByteLimit: exactBytes,
                supportReportByteLimit: 128 * 1_024),
            clock: clock,
            origin: origin)
        await exact.record(
            severity: .warning,
            subsystem: .filesystem,
            code: .appLaunchABIVerified)
        let exactSnapshot = await exact.snapshot()
        XCTAssertEqual(exactSnapshot.events, [event])
        XCTAssertEqual(exactSnapshot.health.retainedByteCount, exactBytes)
        XCTAssertEqual(exactSnapshot.health.droppedEventCount, 0)

        let oneShort = DiagnosticsCenter(
            configuration: DiagnosticsConfiguration(
                memoryEventLimit: 1,
                memoryByteLimit: exactBytes - 1,
                supportReportByteLimit: 128 * 1_024),
            clock: clock,
            origin: origin)
        await oneShort.record(
            severity: .warning,
            subsystem: .filesystem,
            code: .appLaunchABIVerified)
        let shortSnapshot = await oneShort.snapshot()
        XCTAssertTrue(shortSnapshot.events.isEmpty)
        XCTAssertEqual(shortSnapshot.health.oversizedEventCount, 1)
        XCTAssertEqual(shortSnapshot.health.droppedEventCount, 1)
        XCTAssertEqual(shortSnapshot.health.retainedByteCount, 0)
    }

    func testConcurrentFloodStaysOrderedAndBounded() async {
        let workers = 16
        let eventsPerWorker = 500
        let retainedLimit = 128
        let center = DiagnosticsCenter(
            configuration: DiagnosticsConfiguration(
                memoryEventLimit: retainedLimit,
                memoryByteLimit: 512 * 1_024,
                supportReportByteLimit: 512 * 1_024),
            clock: clock)

        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<workers {
                group.addTask {
                    for offset in 0..<eventsPerWorker {
                        await center.record(
                            severity: .debug,
                            subsystem: .diagnostics,
                            code: .appLaunchABIVerified,
                            metadata: DiagnosticMetadata([
                                .attemptedCount: .integer(Int64(worker * eventsPerWorker + offset))
                            ]))
                    }
                }
            }
        }

        let snapshot = await center.snapshot()
        let total = UInt64(workers * eventsPerWorker)
        XCTAssertEqual(snapshot.health.recordedEventCount, total)
        XCTAssertEqual(snapshot.health.retainedEventCount, retainedLimit)
        XCTAssertEqual(snapshot.health.droppedEventCount, total - UInt64(retainedLimit))
        XCTAssertEqual(snapshot.events.map(\.sequence), Array((total - UInt64(retainedLimit) + 1)...total))
        XCTAssertLessThanOrEqual(snapshot.health.retainedByteCount, 512 * 1_024)
    }

    func testSinkFailureIsCountedWithoutDiscardingTheMemoryRecord() async {
        let sink = FailingSink()
        let center = DiagnosticsCenter(
            configuration: DiagnosticsConfiguration(
                memoryEventLimit: 4,
                memoryByteLimit: 64 * 1_024,
                supportReportByteLimit: 128 * 1_024),
            sinks: [sink],
            clock: clock)

        await center.record(
            severity: .error,
            subsystem: .diagnostics,
            code: .appLaunchABIVerified)

        let snapshot = await center.snapshot()
        let attempts = await sink.attempts
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(snapshot.health.sinkFailureCount, 1)
        XCTAssertEqual(snapshot.health.recordedEventCount, 1)
        XCTAssertEqual(snapshot.health.retainedEventCount, 1)
        XCTAssertEqual(snapshot.events.first?.code, .appLaunchABIVerified)
    }

    func testZeroMemoryCapacityAccountsForEveryRecordWithoutAllocating() async {
        let center = DiagnosticsCenter(
            configuration: DiagnosticsConfiguration(
                memoryEventLimit: 0,
                memoryByteLimit: 64 * 1_024,
                supportReportByteLimit: 128 * 1_024),
            clock: clock)

        for _ in 0..<100 {
            await center.record(
                severity: .debug,
                subsystem: .diagnostics,
                code: .appLaunchABIVerified)
        }

        let snapshot = await center.snapshot()
        XCTAssertTrue(snapshot.events.isEmpty)
        XCTAssertEqual(snapshot.health.recordedEventCount, 100)
        XCTAssertEqual(snapshot.health.retainedEventCount, 0)
        XCTAssertEqual(snapshot.health.retainedByteCount, 0)
        XCTAssertEqual(snapshot.health.evictedEventCount, 100)
        XCTAssertEqual(snapshot.health.droppedEventCount, 100)
    }

    func testOneFailingSinkDoesNotStarveLaterSinks() async {
        let failing = FailingSink()
        let succeeding = CountingSink()
        let center = DiagnosticsCenter(
            sinks: [failing, succeeding],
            clock: clock)

        await center.record(
            severity: .error,
            subsystem: .diagnostics,
            code: .appLaunchABIVerified)

        let attempts = await failing.attempts
        let sequences = await succeeding.sequences
        let health = await center.snapshot().health
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(sequences, [1])
        XCTAssertEqual(health.sinkFailureCount, 1)
    }
}
