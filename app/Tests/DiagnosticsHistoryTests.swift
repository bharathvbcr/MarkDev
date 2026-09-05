//
//  DiagnosticsHistoryTests.swift
//  MarkDevKitTests
//
//  Adversarial coverage for bounded, descriptor-relative previous-run export.
//

import Darwin
import Foundation
import XCTest

@testable import MarkDevKit

final class DiagnosticsHistoryTests: XCTestCase {
    func testActiveRunsAreSkippedAndInactiveRunsExportDeterministically() throws {
        let support = try privateTemporaryApplicationSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let inactive = productionOrigin(
            runID: "11000000-0000-0000-0000-000000000001",
            processID: 111)
        let active = productionOrigin(
            runID: "12000000-0000-0000-0000-000000000002",
            processID: 122,
            role: .quickLookExtension)
        let inactiveDirectory = try createInactiveRun(
            in: support,
            origin: inactive,
            sequences: [2])
        try privateWrite(
            try DiagnosticsJSON.line(for: event(origin: inactive, sequence: 1)),
            to: inactiveDirectory.appendingPathComponent("events.1.jsonl"))
        let activeLease = try DiagnosticsScopedRunStore.acquire(
            applicationSupportDirectory: support,
            origin: active)
        defer { activeLease.release() }
        try writeEvents([event(origin: active, sequence: 1)], to: activeLease.directory)

        let first = try DiagnosticsScopedRunStore.historyReport(
            applicationSupportDirectory: support,
            generatedAtMilliseconds: 1_700_000_000_999)
        let second = try DiagnosticsScopedRunStore.historyReport(
            applicationSupportDirectory: support,
            generatedAtMilliseconds: 1_700_000_000_999)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.runs.map(\.origin), [inactive])
        XCTAssertEqual(first.runs.flatMap(\.events).map(\.localSequence), [1, 2])
        XCTAssertEqual(first.inspection.runs.inspected, 2)
        XCTAssertEqual(first.inspection.runs.included, 1)
        XCTAssertEqual(first.inspection.runs.omitted, 1)
        XCTAssertNil(first.inspection.files.uninspected)
        XCTAssertNil(first.inspection.bytes.uninspected)
        XCTAssertNil(first.inspection.events.uninspected)
    }

    func testOnlyPrivateSingleLinkRegularEventFilesAreAccepted() throws {
        let support = try privateTemporaryApplicationSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let origin = productionOrigin(
            runID: "21000000-0000-0000-0000-000000000001",
            processID: 211)
        let directory = try createInactiveRun(in: support, origin: origin, sequences: [1])
        let victim = support.appendingPathComponent("PRIVATE-VICTIM-HISTORY")
        try privateWrite(Data("PRIVATE-HISTORY-SEED".utf8), to: victim)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("events.1.jsonl"),
            withDestinationURL: victim)

        let hardLinked = directory.appendingPathComponent("events.2.jsonl")
        let linkResult = victim.path.withCString { source in
            hardLinked.path.withCString { destination in
                Darwin.link(source, destination)
            }
        }
        XCTAssertEqual(linkResult, 0)
        let permissive = directory.appendingPathComponent("events.3.jsonl")
        try privateWrite(try DiagnosticsJSON.line(for: event(origin: origin, sequence: 2)), to: permissive)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: permissive.path)

        let report = try DiagnosticsScopedRunStore.historyReport(
            applicationSupportDirectory: support,
            generatedAtMilliseconds: 10)
        let encoded = try DiagnosticsJSON.data(for: report)

        XCTAssertEqual(report.inspection.files.inspected, 4)
        XCTAssertEqual(report.inspection.files.included, 1)
        XCTAssertEqual(report.inspection.files.omitted, 3)
        XCTAssertEqual(report.inspection.events.included, 1)
        XCTAssertNil(report.inspection.bytes.uninspected)
        XCTAssertNil(report.inspection.events.uninspected)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("PRIVATE-HISTORY-SEED"))
    }

    func testCorruptTruncatedAndMismatchedOriginFilesAreOmittedAsWholeFiles() throws {
        let support = try privateTemporaryApplicationSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let origin = productionOrigin(
            runID: "31000000-0000-0000-0000-000000000001",
            processID: 311)
        let other = productionOrigin(
            runID: "32000000-0000-0000-0000-000000000002",
            processID: 322)
        let directory = try createInactiveRun(in: support, origin: origin, sequences: [1])
        try privateWrite(
            try DiagnosticsJSON.line(for: event(origin: other, sequence: 1)),
            to: directory.appendingPathComponent("events.1.jsonl"))
        try privateWrite(
            Data("{not-json}\n".utf8),
            to: directory.appendingPathComponent("events.2.jsonl"))
        let truncated = try DiagnosticsJSON.line(for: event(origin: origin, sequence: 4))
        try privateWrite(
            Data(truncated.dropLast()),
            to: directory.appendingPathComponent("events.3.jsonl"))

        let report = try DiagnosticsScopedRunStore.historyReport(
            applicationSupportDirectory: support,
            generatedAtMilliseconds: 20)

        XCTAssertEqual(report.runs.count, 1)
        XCTAssertEqual(report.runs[0].events.map(\.localSequence), [1])
        XCTAssertEqual(report.inspection.files.inspected, 4)
        XCTAssertEqual(report.inspection.files.included, 1)
        XCTAssertEqual(report.inspection.files.omitted, 3)
        XCTAssertEqual(report.inspection.events.inspected, 4)
        XCTAssertEqual(report.inspection.events.included, 1)
        XCTAssertEqual(report.inspection.events.omitted, 3)
        XCTAssertNil(report.inspection.events.uninspected)
    }

    func testRunAndFileCapsNeverMasqueradeAsCompleteCoverage() throws {
        let support = try privateTemporaryApplicationSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let first = productionOrigin(
            runID: "41000000-0000-0000-0000-000000000001",
            processID: 411)
        let second = productionOrigin(
            runID: "42000000-0000-0000-0000-000000000002",
            processID: 422)
        _ = try createInactiveRun(in: support, origin: first, sequences: [1])
        _ = try createInactiveRun(in: support, origin: second, sequences: [1])

        let runCapped = try DiagnosticsScopedRunStore.historyReport(
            applicationSupportDirectory: support,
            limits: DiagnosticsHistoryInspectionLimits(
                maximumRuns: 1,
                maximumFiles: 8))
        XCTAssertEqual(runCapped.inspection.runs.inspected, 1)
        XCTAssertEqual(runCapped.inspection.runs.uninspected, 1)
        XCTAssertNil(runCapped.inspection.files.uninspected)
        XCTAssertNil(runCapped.inspection.bytes.uninspected)
        XCTAssertNil(runCapped.inspection.events.uninspected)

        let directory = try XCTUnwrap(DiagnosticsBootstrap.scopedDirectory(
            applicationSupportDirectory: support,
            origin: first))
        try privateWrite(
            try DiagnosticsJSON.line(for: event(origin: first, sequence: 2)),
            to: directory.appendingPathComponent("events.1.jsonl"))
        let fileCapped = try DiagnosticsScopedRunStore.historyReport(
            applicationSupportDirectory: support,
            limits: DiagnosticsHistoryInspectionLimits(
                maximumRuns: 2,
                maximumFiles: 1))
        XCTAssertEqual(fileCapped.inspection.files.inspected, 1)
        XCTAssertEqual(fileCapped.inspection.files.uninspected, 2)
        XCTAssertNil(fileCapped.inspection.bytes.uninspected)
        XCTAssertNil(fileCapped.inspection.events.uninspected)
    }

    func testRootAndOutputCapsRemainExplicitAndBounded() throws {
        let support = try privateTemporaryApplicationSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let origin = productionOrigin(
            runID: "51000000-0000-0000-0000-000000000001",
            processID: 511)
        _ = try createInactiveRun(
            in: support,
            origin: origin,
            sequences: Array(1...20).map { UInt64($0) })

        let rootCapped = try DiagnosticsScopedRunStore.historyReport(
            applicationSupportDirectory: support,
            limits: DiagnosticsHistoryInspectionLimits(maximumRootEntries: 1))
        XCTAssertEqual(rootCapped.inspection.inspectedRootEntryCount, 1)
        XCTAssertNil(rootCapped.inspection.uninspectedRootEntryCount)
        XCTAssertNil(rootCapped.inspection.runs.uninspected)

        let destination = support.appendingPathComponent("bounded-history.json")
        let summary = try DiagnosticsScopedRunStore.exportHistoryReport(
            applicationSupportDirectory: support,
            to: destination,
            generatedAtMilliseconds: 30,
            limits: DiagnosticsHistoryInspectionLimits(maximumOutputBytes: 4_096))
        let bytes = try Data(contentsOf: destination)
        let report = try JSONDecoder().decode(DiagnosticHistoryReport.self, from: bytes)
        XCTAssertLessThanOrEqual(bytes.count, 4_096)
        XCTAssertLessThan(report.inspection.events.included, 20)
        XCTAssertEqual(
            report.inspection.events.included + report.inspection.events.omitted,
            report.inspection.events.inspected)
        XCTAssertEqual(summary.byteCount, bytes.count)
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1, 0o600)
    }

    func testPerFileByteAndEventInspectionCapsOmitWholeFilesTruthfully() throws {
        let support = try privateTemporaryApplicationSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let origin = productionOrigin(
            runID: "52000000-0000-0000-0000-000000000001",
            processID: 521)
        let directory = try createInactiveRun(in: support, origin: origin, sequences: [1, 2])
        let sourceByteCount = try Data(
            contentsOf: directory.appendingPathComponent("events.jsonl")).count

        let byteCapped = try DiagnosticsScopedRunStore.historyReport(
            applicationSupportDirectory: support,
            limits: DiagnosticsHistoryInspectionLimits(maximumBytesPerFile: 1))
        XCTAssertEqual(byteCapped.inspection.files.inspected, 1)
        XCTAssertEqual(byteCapped.inspection.files.included, 0)
        XCTAssertEqual(byteCapped.inspection.files.omitted, 1)
        XCTAssertEqual(byteCapped.inspection.bytes.inspected, 0)
        XCTAssertEqual(byteCapped.inspection.bytes.uninspected, sourceByteCount)
        XCTAssertNil(byteCapped.inspection.events.uninspected)

        let eventCapped = try DiagnosticsScopedRunStore.historyReport(
            applicationSupportDirectory: support,
            limits: DiagnosticsHistoryInspectionLimits(
                maximumInspectedEvents: 1,
                maximumIncludedEvents: 1))
        XCTAssertEqual(eventCapped.inspection.files.included, 0)
        XCTAssertEqual(eventCapped.inspection.files.omitted, 1)
        XCTAssertEqual(eventCapped.inspection.bytes.inspected, sourceByteCount)
        XCTAssertEqual(eventCapped.inspection.events.inspected, 1)
        XCTAssertEqual(eventCapped.inspection.events.included, 0)
        XCTAssertNil(eventCapped.inspection.events.uninspected)
    }

    func testRetentionLockContentionIsUnavailableInsteadOfAFalseEmptyHistory() throws {
        let support = try privateTemporaryApplicationSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let origin = productionOrigin(
            runID: "53000000-0000-0000-0000-000000000001",
            processID: 531)
        _ = try createInactiveRun(in: support, origin: origin, sequences: [1])
        let lockURL = DiagnosticsBootstrap.runRoot(applicationSupportDirectory: support)
            .appendingPathComponent(".retention.lock")
        let descriptor = lockURL.path.withCString {
            Darwin.open($0, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        }
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer {
            _ = flock(descriptor, LOCK_UN)
            _ = Darwin.close(descriptor)
        }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)

        XCTAssertThrowsError(try DiagnosticsScopedRunStore.historyReport(
            applicationSupportDirectory: support)) { error in
            XCTAssertEqual(
                error as? DiagnosticsScopedRunStoreError,
                .retentionLockUnavailable)
        }
    }

    func testDirectoryNamespaceSwapFailsClosedWithoutReadingReplacement() throws {
        let support = try privateTemporaryApplicationSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let origin = productionOrigin(
            runID: "61000000-0000-0000-0000-000000000001",
            processID: 611)
        let directory = try createInactiveRun(in: support, origin: origin, sequences: [1])
        let displaced = support.appendingPathComponent("displaced-run", isDirectory: true)
        let victim = try privateVictimDirectory(in: support, seed: "RUN-SWAP-PRIVATE")
        var swapped = false
        let hooks = DiagnosticsHistoryTestingHooks(beforeOpeningRun: { candidate in
            guard candidate == directory, !swapped else { return }
            swapped = true
            try! FileManager.default.moveItem(at: candidate, to: displaced)
            try! FileManager.default.createSymbolicLink(at: candidate, withDestinationURL: victim)
        })

        XCTAssertThrowsError(try DiagnosticsScopedRunStore.historyReport(
            applicationSupportDirectory: support,
            testingHooks: hooks)) { error in
            XCTAssertEqual(error as? DiagnosticsScopedRunStoreError, .filesystemChanged)
        }
        XCTAssertTrue(swapped)
        XCTAssertEqual(
            try Data(contentsOf: victim.appendingPathComponent("sentinel")),
            Data("RUN-SWAP-PRIVATE".utf8))
    }

    func testFileNamespaceSwapFailsClosedWithoutReadingReplacement() throws {
        let support = try privateTemporaryApplicationSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let origin = productionOrigin(
            runID: "71000000-0000-0000-0000-000000000001",
            processID: 711)
        let directory = try createInactiveRun(in: support, origin: origin, sequences: [1])
        let eventFile = directory.appendingPathComponent("events.jsonl")
        let displaced = directory.appendingPathComponent("displaced-events")
        let victim = support.appendingPathComponent("FILE-SWAP-PRIVATE")
        try privateWrite(Data("FILE-SWAP-PRIVATE".utf8), to: victim)
        var swapped = false
        let hooks = DiagnosticsHistoryTestingHooks(beforeReadingFile: { candidate in
            guard candidate == eventFile, !swapped else { return }
            swapped = true
            try! FileManager.default.moveItem(at: candidate, to: displaced)
            try! FileManager.default.createSymbolicLink(at: candidate, withDestinationURL: victim)
        })

        XCTAssertThrowsError(try DiagnosticsScopedRunStore.historyReport(
            applicationSupportDirectory: support,
            testingHooks: hooks)) { error in
            XCTAssertEqual(error as? DiagnosticsScopedRunStoreError, .filesystemChanged)
        }
        XCTAssertTrue(swapped)
        XCTAssertEqual(try Data(contentsOf: victim), Data("FILE-SWAP-PRIVATE".utf8))
    }

    func testAlreadyCancelledInspectionCannotReturnACompleteSnapshot() async throws {
        let support = try privateTemporaryApplicationSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let task = Task { () -> Bool in
            while !Task.isCancelled { await Task.yield() }
            do {
                _ = try DiagnosticsScopedRunStore.historyReport(
                    applicationSupportDirectory: support)
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        task.cancel()
        let cancelledSafely = await task.value
        XCTAssertTrue(cancelledSafely)
    }

    func testSettingsSourceKeepsHistorySeparateAndTruthfullyLabelsUnknownTotals() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("app/MarkDev/SettingsView.swift"),
            encoding: .utf8)
        let modelSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "app/MarkDevKit/Diagnostics/DiagnosticsSettingsModel.swift"),
            encoding: .utf8)
        for identifier in [
            "diagnostics.history.status",
            "diagnostics.history.runs",
            "diagnostics.history.files",
            "diagnostics.history.events",
            "diagnostics.history.bytes",
            "diagnostics.history.export",
            "diagnostics.history.export.status",
        ] {
            XCTAssertTrue(source.contains(identifier), "missing stable history identity: \(identifier)")
        }
        XCTAssertTrue(source.contains("Export Support Report…"))
        XCTAssertTrue(source.contains("Export Previous Runs…"))
        XCTAssertTrue(source.contains("uninspected unknown"))
        XCTAssertTrue(source.contains("diagnosticsModel.cancelHistoryWork()"))
        XCTAssertFalse(source.contains("historyApplicationSupportDirectory.path"))
        XCTAssertTrue(modelSource.contains("historyRefreshGeneration"))
        XCTAssertTrue(modelSource.contains("historyRefreshTask?.cancel()"))
        XCTAssertTrue(modelSource.contains("withTaskCancellationHandler"))
    }

    private func createInactiveRun(
        in support: URL,
        origin: DiagnosticOrigin,
        sequences: [UInt64]
    ) throws -> URL {
        let lease = try DiagnosticsScopedRunStore.acquire(
            applicationSupportDirectory: support,
            origin: origin)
        let directory = lease.directory
        try writeEvents(sequences.map { event(origin: origin, sequence: $0) }, to: directory)
        lease.release()
        return directory
    }

    private func writeEvents(_ events: [DiagnosticEvent], to directory: URL) throws {
        var data = Data()
        for event in events { data.append(try DiagnosticsJSON.line(for: event)) }
        try privateWrite(data, to: directory.appendingPathComponent("events.jsonl"))
    }

    private func event(origin: DiagnosticOrigin, sequence: UInt64) -> DiagnosticEvent {
        DiagnosticEvent(
            origin: origin,
            localSequence: sequence,
            timestampMilliseconds: 1_700_000_000_000 + Int64(sequence),
            uptimeNanoseconds: sequence,
            severity: .info,
            subsystem: .diagnostics,
            code: .appLaunchABIVerified,
            operationID: nil,
            metadata: DiagnosticMetadata())
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

    private func privateTemporaryApplicationSupport() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("MarkDevDiagnosticsHistory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path)
        return directory
    }

    private func privateVictimDirectory(in support: URL, seed: String) throws -> URL {
        let victim = support.appendingPathComponent("victim", isDirectory: true)
        try FileManager.default.createDirectory(
            at: victim,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        try privateWrite(Data(seed.utf8), to: victim.appendingPathComponent("sentinel"))
        return victim
    }

    private func privateWrite(_ data: Data, to destination: URL) throws {
        try data.write(to: destination)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination.path)
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

@MainActor
final class DiagnosticsHistorySettingsModelTests: XCTestCase {
    private struct FixedClock: DiagnosticClock {
        func millisecondsSince1970() -> Int64 { 1_700_000_000_123 }
        func uptimeNanoseconds() -> UInt64 { 99 }
    }

    func testRefreshAndExportExposeOnlyClosedHistoryState() async throws {
        let support = try privateTemporaryApplicationSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let origin = DiagnosticOrigin(
            validatedRunID: UUID(uuidString: "81000000-0000-0000-0000-000000000001")!,
            processID: 811,
            role: .app,
            locality: .productionUser)
        let lease = try DiagnosticsScopedRunStore.acquire(
            applicationSupportDirectory: support,
            origin: origin)
        var data = try DiagnosticsJSON.line(for: DiagnosticEvent(
            origin: origin,
            localSequence: 1,
            timestampMilliseconds: 1,
            uptimeNanoseconds: 1,
            severity: .info,
            subsystem: .diagnostics,
            code: .appLaunchABIVerified,
            operationID: nil,
            metadata: DiagnosticMetadata()))
        try SecureAtomicDiagnosticsFile.write(
            data,
            to: lease.directory.appendingPathComponent("events.jsonl"))
        data.removeAll(keepingCapacity: false)
        lease.release()

        let center = DiagnosticsCenter(sinks: [], clock: FixedClock())
        let model = DiagnosticsSettingsModel(
            emitter: DiagnosticsEmitter(center: center),
            generatedAtMilliseconds: 100,
            historyApplicationSupportDirectory: support)
        await model.refresh()
        guard case let .available(snapshot) = model.historyAvailability else {
            return XCTFail("expected safely inspected history")
        }
        XCTAssertEqual(snapshot.inspection.runs.included, 1)
        XCTAssertEqual(snapshot.inspection.events.included, 1)

        let destination = support.appendingPathComponent("settings-history.json")
        let exported = await model.exportHistory(to: destination)
        XCTAssertTrue(exported)
        guard case let .succeeded(summary) = model.historyExportState else {
            return XCTFail("expected successful previous-run export")
        }
        XCTAssertEqual(summary.inspection.events.included, 1)
        XCTAssertFalse(model.historyExportState.message.contains(destination.path))
    }

    private func privateTemporaryApplicationSupport() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("MarkDevDiagnosticsHistoryModel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        return directory
    }
}
