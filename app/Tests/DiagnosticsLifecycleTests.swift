//
//  DiagnosticsLifecycleTests.swift
//  MarkDevKitTests
//
//  Lifecycle integration emits a stable signal without accepting payloads.
//

import XCTest

@testable import MarkDevKit

final class DiagnosticsLifecycleTests: XCTestCase {
    private struct FixedClock: DiagnosticClock {
        func millisecondsSince1970() -> Int64 { 1_700_000_000_123 }
        func uptimeNanoseconds() -> UInt64 { 99 }
    }

    func testVerifiedABILaunchEventIsTypedAndMetadataFree() async throws {
        let center = DiagnosticsCenter(sinks: [], clock: FixedClock())

        await center.recordVerifiedABILaunch()

        let snapshot = await center.snapshot()
        let event = try XCTUnwrap(snapshot.events.first)
        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertEqual(event.severity, .notice)
        XCTAssertEqual(event.subsystem, .app)
        XCTAssertEqual(event.code, .appLaunchABIVerified)
        XCTAssertNil(event.operationID)
        XCTAssertEqual(event.metadata, DiagnosticMetadata())
    }

    // MARK: - The shared centre must not write during a test run

    /// A test run must leave the reader's diagnostics log exactly as it found
    /// it.
    ///
    /// `DiagnosticsCenter.shared` writes to Application Support, and any test
    /// exercising a production call site — a workspace save, an oversized
    /// edit, a refused document — goes through it unless the test injects its
    /// own emitter. Most do not, and should not have to.
    ///
    /// Measured before this was fixed: after one afternoon the log held 428
    /// `editor.document.rejected` events and 212 autosave conflicts against
    /// *three* real launches. A support export built from that describes a
    /// session that never happened — which is worse than an empty export,
    /// because it looks complete.
    func testTheSharedCentreWritesNothingToTheReadersLogUnderTest() async throws {
        XCTAssertTrue(
            DiagnosticsCenter.isRunningTests,
            "the suppression hinges on this predicate; if it is false here, "
                + "every test in the suite is writing to the reader's log")

        let manager = FileManager.default
        guard let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
        else { throw XCTSkip("no Application Support directory on this machine") }
        let log = support
            .appendingPathComponent("MarkDev", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("events.jsonl")

        let before = try? Data(contentsOf: log)

        // Every production severity, through the shared emitter the app uses.
        for severity in [DiagnosticSeverity.error, .warning, .notice] {
            DiagnosticsEmitter.shared.emit(
                severity: severity,
                subsystem: .diagnostics,
                code: .invalid,
                operationID: DiagnosticOperationID())
        }
        await DiagnosticsEmitter.shared.flush()

        let after = try? Data(contentsOf: log)
        XCTAssertEqual(
            before?.count, after?.count,
            "a test run appended \((after?.count ?? 0) - (before?.count ?? 0)) bytes to the "
                + "reader's diagnostics log")
    }
}
