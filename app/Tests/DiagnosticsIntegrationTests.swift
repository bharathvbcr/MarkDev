//
//  DiagnosticsIntegrationTests.swift
//  MarkDevKitTests
//
//  Production call sites, delivery isolation, and payload privacy.
//

import Foundation
import XCTest

@testable import MarkDevKit

private struct IntegrationDiagnosticClock: DiagnosticClock {
    func millisecondsSince1970() -> Int64 { 1_700_000_123_456 }
    func uptimeNanoseconds() -> UInt64 { 987_654_321 }
}

private actor FailingIntegrationDiagnosticSink: DiagnosticSink {
    private(set) var attempts = 0

    func write(_ record: DiagnosticRecord) async throws {
        attempts += 1
        throw CocoaError(.fileWriteNoPermission)
    }
}

/// Holds only the first write so the emitter's pending bound is exercised
/// deterministically rather than racing a fast in-memory sink.
private actor GatedIntegrationDiagnosticSink: DiagnosticSink {
    private var writes = 0
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func write(_ record: DiagnosticRecord) async throws {
        writes += 1
        guard writes == 1 else { return }
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilFirstWriteStarts() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseFirstWrite() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

@MainActor
final class DiagnosticsProductionIntegrationTests: XCTestCase {
    private var scratch: URL!

    override func setUp() async throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevDiagnosticsIntegration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func makeCenter(
        sinks: [any DiagnosticSink] = [],
        memoryEventLimit: Int = 1_024
    ) -> DiagnosticsCenter {
        DiagnosticsCenter(
            configuration: DiagnosticsConfiguration(
                memoryEventLimit: memoryEventLimit,
                memoryByteLimit: 4 * 1_024 * 1_024,
                supportReportByteLimit: 4 * 1_024 * 1_024),
            sinks: sinks,
            clock: IntegrationDiagnosticClock())
    }

    private func stub(named name: String = "stub-manvi", _ script: String) throws -> URL {
        let file = scratch.appendingPathComponent(name)
        try ("#!/bin/sh\n" + script + "\n").write(
            to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }

    private func harnessRequest(
        binary: URL,
        prompt: String,
        timeout: Duration = .seconds(20)
    ) -> HarnessRunRequest {
        HarnessRunRequest(
            binary: binary,
            prompt: prompt,
            workingDirectory: scratch,
            maxSteps: 4,
            timeout: timeout,
            environment: ["PATH": "/usr/bin:/bin", "SEEDED_SECRET": prompt])
    }

    private func reportString(_ center: DiagnosticsCenter) async throws -> String {
        let data = try await center.supportReportData(
            metadata: DiagnosticReportMetadata(
                app: DiagnosticAppMetadata(name: "MarkDev", bundleIdentifier: "dev.markdev.test"),
                build: DiagnosticBuildMetadata(
                    version: "1.0", buildNumber: "1", sourceCommit: "abcdef1"),
                operatingSystem: DiagnosticOSMetadata(
                    name: "macOS", version: "26.5", architecture: "arm64")),
            generatedAtMilliseconds: 1_700_000_123_456)
        return String(decoding: data, as: UTF8.self)
    }

    func testWorkspaceSaveEmitsSuccessAndSinkFailureCannotFailTheSave() async throws {
        let failingSink = FailingIntegrationDiagnosticSink()
        let center = makeCenter(sinks: [failingSink])
        let emitter = DiagnosticsEmitter(center: center)
        let workspace = Workspace(
            diagnostics: emitter,
            documentIO: LocalDocumentIO(),
            transactionRegistry: ProcessFileTransactionRegistry())
        let pane = workspace.focusedPane
        let secretText = "note-body-SECRET-2f79f6f0"
        let secretName = "private-token-7b12c.md"
        let destination = scratch.appendingPathComponent(secretName)
        workspace.updateText(secretText, in: pane)

        let saved = try workspace.save(in: pane, to: destination)
        await emitter.flush()

        XCTAssertEqual(saved, destination)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), secretText)
        let snapshot = await center.snapshot()
        let event = try XCTUnwrap(snapshot.events.only)
        XCTAssertEqual(event.subsystem, .workspace)
        XCTAssertEqual(event.code, .workspaceSaveSucceeded)
        XCTAssertNotNil(event.operationID)
        XCTAssertEqual(event.metadata, DiagnosticMetadata())
        XCTAssertEqual(snapshot.health.sinkFailureCount, 1)
        let sinkAttempts = await failingSink.attempts
        XCTAssertEqual(sinkAttempts, 1)

        let report = try await reportString(center)
        XCTAssertFalse(report.contains(secretText))
        XCTAssertFalse(report.contains(secretName))
        XCTAssertFalse(report.contains(destination.path))
    }

    /// The refused edit is on the keystroke path, and must record exactly once.
    ///
    /// The binding pushes text in on every keystroke, so an unconditional emit
    /// here would flood the ring and evict the events that explain anything.
    /// Only the refusal — the case where the reader's text is about to be
    /// reverted out from under them — is worth a line.
    func testAnOversizedEditEmitsOnceAndAcceptedEditsEmitNothing() async throws {
        let center = makeCenter()
        let emitter = DiagnosticsEmitter(center: center)
        let workspace = Workspace(
            diagnostics: emitter,
            documentIO: LocalDocumentIO(),
            transactionRegistry: ProcessFileTransactionRegistry())
        let pane = workspace.focusedPane
        let secretText = "draft-body-SECRET-4c81ba90"
        let oversized = String(
            repeating: "x", count: MarkdownReadLimits.maximumDocumentBytes + 1)

        // Ordinary typing: many edits, no events.
        for suffix in 0..<8 {
            workspace.updateText("\(secretText)-\(suffix)", in: pane)
        }
        await emitter.flush()
        var snapshot = await center.snapshot()
        XCTAssertTrue(
            snapshot.events.isEmpty,
            "ordinary edits must not log; this runs on every keystroke")

        XCTAssertFalse(workspace.updateText(oversized, in: pane))
        await emitter.flush()
        snapshot = await center.snapshot()
        let event = try XCTUnwrap(snapshot.events.only)
        XCTAssertEqual(event.subsystem, .workspace)
        XCTAssertEqual(event.code, .workspaceEditRefused)
        XCTAssertNotNil(event.operationID)
        XCTAssertEqual(
            event.metadata,
            DiagnosticMetadata([
                .byteCount: .integer(Int64(MarkdownReadLimits.maximumDocumentBytes + 1))
            ]))

        // And the reader's text never reaches the log.
        let report = try await reportString(center)
        XCTAssertFalse(report.contains(secretText))
    }

    func testWorkspaceSaveFailureEmitsWithoutChangingTheThrownError() async throws {
        let center = makeCenter()
        let emitter = DiagnosticsEmitter(center: center)
        let workspace = Workspace(
            diagnostics: emitter,
            documentIO: LocalDocumentIO(),
            transactionRegistry: ProcessFileTransactionRegistry())
        let pane = workspace.focusedPane
        let secretText = "draft-SECRET-e3e9e773"
        let destination = scratch
            .appendingPathComponent("missing-parent")
            .appendingPathComponent("credential-file-a24c.md")
        workspace.updateText(secretText, in: pane)

        XCTAssertThrowsError(try workspace.save(in: pane, to: destination))
        await emitter.flush()

        let snapshot = await center.snapshot()
        let event = try XCTUnwrap(snapshot.events.only)
        XCTAssertEqual(event.subsystem, .workspace)
        XCTAssertEqual(event.code, .workspaceSaveFailed)
        XCTAssertNotNil(event.operationID)
        XCTAssertEqual(event.metadata, DiagnosticMetadata())
        let report = try await reportString(center)
        XCTAssertFalse(report.contains(secretText))
        XCTAssertFalse(report.contains("credential-file-a24c.md"))
        XCTAssertFalse(report.contains(destination.path))
    }

    func testAutosaveReportsConflictsWithExactAggregateCounts() async throws {
        let center = makeCenter()
        let emitter = DiagnosticsEmitter(center: center)
        let workspace = Workspace(
            diagnostics: emitter,
            documentIO: LocalDocumentIO(),
            transactionRegistry: ProcessFileTransactionRegistry())
        let pane = workspace.focusedPane

        let conflict = scratch.appendingPathComponent("conflict-secret-931b.md")
        try "original".write(to: conflict, atomically: true, encoding: .utf8)
        try workspace.open(conflict, in: pane)
        workspace.updateText("local-secret-98af", in: pane)
        try "external-secret-6a17".write(to: conflict, atomically: true, encoding: .utf8)
        XCTAssertEqual(workspace.autosave(), 0)

        let missing = scratch.appendingPathComponent("missing-secret-b51c.md")
        try "baseline".write(to: missing, atomically: true, encoding: .utf8)
        try workspace.open(missing, in: pane)
        workspace.updateText("unsaved-secret-6634", in: pane)
        try FileManager.default.removeItem(at: missing)
        XCTAssertEqual(workspace.autosave(), 0)
        await emitter.flush()

        let snapshot = await center.snapshot()
        XCTAssertEqual(
            snapshot.events.map(\.code),
            [.workspaceAutosaveConflict, .workspaceAutosaveConflict])
        guard snapshot.events.count == 2 else { return }
        let first = snapshot.events[0]
        XCTAssertEqual(first.metadata[.attemptedCount], .integer(1))
        XCTAssertEqual(first.metadata[.succeededCount], .integer(0))
        XCTAssertEqual(first.metadata[.conflictCount], .integer(1))
        XCTAssertEqual(first.metadata[.failedCount], .integer(0))
        let last = snapshot.events[1]
        XCTAssertEqual(last.metadata[.attemptedCount], .integer(2))
        XCTAssertEqual(last.metadata[.succeededCount], .integer(0))
        XCTAssertEqual(last.metadata[.conflictCount], .integer(2))
        XCTAssertEqual(last.metadata[.failedCount], .integer(0))
        XCTAssertNotEqual(first.operationID, last.operationID)

        let report = try await reportString(center)
        for forbidden in [
            "conflict-secret-931b.md", "local-secret-98af", "external-secret-6a17",
            "missing-secret-b51c.md", "unsaved-secret-6634", scratch.path,
        ] {
            XCTAssertFalse(report.contains(forbidden), "leaked \(forbidden)")
        }
    }

    func testIncompleteVaultReconciliationEmitsEveryBoundedCoverageCounter() async throws {
        let center = makeCenter()
        let emitter = DiagnosticsEmitter(center: center)
        let vault = scratch.appendingPathComponent("vault-secret-114d")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        try "# private-vault-content-7dc0".write(
            to: vault.appendingPathComponent("classified-note-c84a.md"),
            atomically: true,
            encoding: .utf8)
        let index = VaultIndex(diagnostics: emitter)
        index.open(vault)

        let result = await index.reconcileWithDisk(
            excluding: [],
            scanLimits: FileTree.ScanLimits(maxDepth: 0, maxEntries: 0, maxNoteBytes: 1))
        await emitter.flush()

        XCTAssertFalse(result.isComplete)
        let snapshot = await center.snapshot()
        let event = try XCTUnwrap(snapshot.events.only)
        XCTAssertEqual(event.subsystem, .vault)
        XCTAssertEqual(event.code, .vaultReconciliationIncomplete)
        XCTAssertNotNil(event.operationID)
        XCTAssertEqual(event.metadata[.changedCount], .integer(Int64(result.changedNotes)))
        XCTAssertEqual(event.metadata[.discoveredFileCount], .integer(Int64(result.scan.files.count)))
        XCTAssertEqual(event.metadata[.visitedEntryCount], .integer(Int64(result.scan.visitedEntries)))
        XCTAssertEqual(event.metadata[.skippedSymlinkCount], .integer(Int64(result.scan.skippedSymlinks)))
        XCTAssertEqual(
            event.metadata[.unreadableDirectoryCount],
            .integer(Int64(result.scan.unreadableDirectories)))
        XCTAssertEqual(
            event.metadata[.unreadableEntryCount],
            .integer(Int64(result.scan.unreadableEntries)))
        XCTAssertEqual(event.metadata[.unreadableFileCount], .integer(Int64(result.unreadableFiles)))
        XCTAssertEqual(event.metadata[.oversizedFileCount], .integer(Int64(result.oversizedFiles)))
        XCTAssertEqual(event.metadata[.hitDepthLimit], .boolean(result.scan.hitDepthLimit))
        XCTAssertEqual(event.metadata[.hitEntryLimit], .boolean(result.scan.hitEntryLimit))

        let report = try await reportString(center)
        XCTAssertFalse(report.contains("vault-secret-114d"))
        XCTAssertFalse(report.contains("classified-note-c84a.md"))
        XCTAssertFalse(report.contains("private-vault-content-7dc0"))
        XCTAssertFalse(report.contains(vault.path))
    }

    func testHarnessTerminalOutcomesEmitTypedPrivateEvents() async throws {
        let center = makeCenter()
        let emitter = DiagnosticsEmitter(center: center)
        let promptSecret = "PROMPT_TOKEN_0197fcb4"

        let success = try stub(
            named: "secret-success-binary",
            "echo '{\"kind\":\"assistant.text\",\"text\":\"private-answer-8b9e\"}'\nexit 0")
        let successResult = await HarnessRun.run(
            harnessRequest(binary: success, prompt: promptSecret),
            diagnostics: emitter
        ) { _ in }
        XCTAssertEqual(successResult.outcome, .finished)

        let failure = try stub(
            named: "secret-failure-binary",
            "echo 'manvi: RAW_ERROR_SECRET_d836' >&2\nexit 1")
        let failureResult = await HarnessRun.run(
            harnessRequest(binary: failure, prompt: promptSecret),
            diagnostics: emitter
        ) { _ in }
        XCTAssertEqual(failureResult.outcome, .failed("RAW_ERROR_SECRET_d836"))

        let missing = scratch.appendingPathComponent("credential-bearing-missing-binary")
        let startFailure = await HarnessRun.run(
            harnessRequest(binary: missing, prompt: promptSecret),
            diagnostics: emitter
        ) { _ in }
        guard case .failed = startFailure.outcome else {
            return XCTFail("missing executable must fail")
        }
        await emitter.flush()

        let snapshot = await center.snapshot()
        XCTAssertEqual(
            snapshot.events.map(\.code),
            [.harnessTerminalSucceeded, .harnessTerminalFailed, .harnessTerminalFailed])
        XCTAssertEqual(snapshot.events[0].metadata[.exitStatus], .integer(0))
        XCTAssertEqual(snapshot.events[1].metadata[.exitStatus], .integer(1))
        XCTAssertNil(snapshot.events[2].metadata[.exitStatus])
        XCTAssertEqual(snapshot.events[2].metadata[.available], .boolean(false))
        XCTAssertTrue(snapshot.events.allSatisfy { $0.operationID != nil })

        let report = try await reportString(center)
        for forbidden in [
            promptSecret, "private-answer-8b9e", "RAW_ERROR_SECRET_d836",
            "secret-success-binary", "secret-failure-binary",
            "credential-bearing-missing-binary", scratch.path,
        ] {
            XCTAssertFalse(report.contains(forbidden), "leaked \(forbidden)")
        }
    }

    func testHarnessCancellationAndBackstopTimeoutEmitDistinctCodes() async throws {
        let center = makeCenter()
        let emitter = DiagnosticsEmitter(center: center)
        let binary = try stub(
            named: "private-loop-binary",
            "echo '{\"kind\":\"assistant.text\",\"text\":\"started-secret-9d9e\"}'\nwhile :; do :; done")

        let started = expectation(description: "harness produced an event before cancellation")
        let cancellation = Task { @MainActor in
            await HarnessRun.run(
                harnessRequest(binary: binary, prompt: "cancel-prompt-secret-ffa2"),
                diagnostics: emitter
            ) { event in
                if event.kind == .text { started.fulfill() }
            }
        }
        await fulfillment(of: [started], timeout: 5)
        cancellation.cancel()
        let cancellationResult = await cancellation.value
        XCTAssertEqual(cancellationResult.outcome, .cancelled)

        let timeout = await HarnessRun.run(
            harnessRequest(
                binary: binary,
                prompt: "timeout-prompt-secret-b4bb",
                timeout: .milliseconds(1)),
            diagnostics: emitter,
            backstopGrace: .milliseconds(20)
        ) { _ in }
        XCTAssertEqual(timeout.outcome, .timedOut)
        await emitter.flush()

        let snapshot = await center.snapshot()
        XCTAssertEqual(
            snapshot.events.map(\.code),
            [.harnessTerminalCancelled, .harnessTerminalTimedOut])
        XCTAssertTrue(snapshot.events.allSatisfy { $0.operationID != nil })
        let report = try await reportString(center)
        for forbidden in [
            "private-loop-binary", "started-secret-9d9e", "cancel-prompt-secret-ffa2",
            "timeout-prompt-secret-b4bb", scratch.path,
        ] {
            XCTAssertFalse(report.contains(forbidden), "leaked \(forbidden)")
        }
    }

    func testHarnessInputCapAllowsExactLimitAndRejectsOneOverBeforeLaunch() async throws {
        let center = makeCenter()
        let emitter = DiagnosticsEmitter(center: center)
        let launchMarker = scratch.appendingPathComponent("launch-marker")
        let binary = try stub(
            named: "input-boundary-binary",
            "echo launched >> '\(launchMarker.path)'\ncat >/dev/null\nexit 0")

        let exact = String(repeating: "a", count: HarnessRun.maximumInputBytes)
        var exactRequest = harnessRequest(binary: binary, prompt: exact)
        exactRequest.environment = ["PATH": "/usr/bin:/bin"]
        let accepted = await HarnessRun.run(
            exactRequest,
            diagnostics: emitter
        ) { _ in }
        XCTAssertEqual(accepted.outcome, .finished)

        let oneOver = String(repeating: "b", count: HarnessRun.maximumInputBytes + 1)
        var oneOverRequest = harnessRequest(binary: binary, prompt: oneOver)
        oneOverRequest.environment = ["PATH": "/usr/bin:/bin"]
        let rejected = await HarnessRun.run(
            oneOverRequest,
            diagnostics: emitter
        ) { _ in }
        XCTAssertEqual(rejected.outcome, .failed(HarnessRun.inputTooLargeMessage))
        await emitter.flush()

        let launches = try String(contentsOf: launchMarker, encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(launches.count, 1, "one-over input launched the child")
        let snapshot = await center.snapshot()
        XCTAssertEqual(
            snapshot.events.map(\.code),
            [.harnessTerminalSucceeded, .harnessTerminalInputTooLarge])
        XCTAssertEqual(
            snapshot.events.last?.metadata[.byteCount],
            .integer(Int64(HarnessRun.maximumInputBytes + 1)))
    }

    func testChildClosingStdinCannotMasqueradeAsASuccessfulRun() async throws {
        let center = makeCenter()
        let emitter = DiagnosticsEmitter(center: center)
        let binary = try stub(
            named: "closed-input-binary",
            "exec 0<&-\nsleep 0.1\nexit 0")
        let prompt = String(repeating: "s", count: HarnessRun.maximumInputBytes)
        var request = harnessRequest(binary: binary, prompt: prompt)
        request.environment = ["PATH": "/usr/bin:/bin"]

        let result = await HarnessRun.run(
            request,
            diagnostics: emitter
        ) { _ in }
        await emitter.flush()

        XCTAssertEqual(result.outcome, .failed(HarnessRun.inputRejectedMessage))
        let snapshot = await center.snapshot()
        let event = try XCTUnwrap(snapshot.events.only)
        XCTAssertEqual(event.code, .harnessTerminalInputRejected)
        XCTAssertEqual(event.metadata[.exitStatus], .integer(0))
        let report = try await reportString(center)
        XCTAssertFalse(report.contains(prompt))
    }

    func testHarnessKeepsAValidFinalEventWithoutATrailingNewline() async throws {
        let center = makeCenter()
        let emitter = DiagnosticsEmitter(center: center)
        let binary = try stub(
            named: "unterminated-final-event-binary",
            "printf '{\"kind\":\"assistant.text\",\"text\":\"final\"}'\nexit 0")

        let result = await HarnessRun.run(
            harnessRequest(binary: binary, prompt: "safe prompt"),
            diagnostics: emitter
        ) { _ in }

        XCTAssertEqual(result.outcome, .finished)
        XCTAssertEqual(result.answer, "final")
        XCTAssertEqual(result.events.count, 1)
    }
}

final class DiagnosticsEmitterStressTests: XCTestCase {
    @MainActor
    func testPipeStreamBufferIsByteBoundedWhenTheConsumerIsStalled() async throws {
        let pipe = Pipe()
        let stream = HarnessRun.stream(
            from: pipe.fileHandleForReading,
            maximumBufferedBytes: 128)
        try pipe.fileHandleForWriting.write(contentsOf: Data(repeating: 0x61, count: 4_096))
        try pipe.fileHandleForWriting.close()

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !stream.loss.hasDropped, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        var retainedBytes = 0
        for await chunk in stream.chunks {
            retainedBytes += chunk.count
        }

        XCTAssertTrue(stream.loss.hasDropped)
        XCTAssertLessThanOrEqual(retainedBytes, 128)
    }

    @MainActor
    func testOneChunkCannotAppendPastTheHarnessEventLimit() {
        let line = "{\"kind\":\"turn.end\"}\n"
        let chunk = Data(
            String(repeating: line, count: HarnessRun.maximumEvents + 500).utf8)
        XCTAssertLessThan(chunk.count, HarnessRun.maximumTranscriptBytes)
        var pending = Data()
        var transcriptBytes = 0
        var events: [HarnessEvent] = []
        var answer = ""
        var truncated = false
        var streamed = 0

        HarnessRun.absorbTranscriptChunk(
            chunk,
            pending: &pending,
            transcriptBytes: &transcriptBytes,
            events: &events,
            answer: &answer,
            truncated: &truncated
        ) { _ in
            streamed += 1
        }

        XCTAssertEqual(events.count, HarnessRun.maximumEvents)
        XCTAssertEqual(streamed, HarnessRun.maximumEvents)
        XCTAssertTrue(truncated)
        XCTAssertTrue(pending.isEmpty, "discarded tail remained retained in memory")
    }

    func testHostileByteCountersSaturateInsteadOfWrapping() {
        XCTAssertEqual(
            HarnessRun.saturatingByteCount(Int.max - 1, adding: 1),
            Int.max)
        XCTAssertEqual(
            HarnessRun.saturatingByteCount(Int.max, adding: 1),
            Int.max)
    }

    func testZeroPendingCapacityDropsAndAccountsForEveryEmission() async {
        let center = DiagnosticsCenter(
            configuration: DiagnosticsConfiguration(
                memoryEventLimit: 8,
                memoryByteLimit: 64 * 1_024,
                supportReportByteLimit: 64 * 1_024),
            clock: IntegrationDiagnosticClock())
        let emitter = DiagnosticsEmitter(
            center: center,
            configuration: DiagnosticsEmitterConfiguration(maximumPendingEvents: 0))

        DispatchQueue.concurrentPerform(iterations: 1_000) { _ in
            emitter.emit(
                severity: .debug,
                subsystem: .diagnostics,
                code: .appLaunchABIVerified)
        }
        await emitter.flush()

        let snapshot = await center.snapshot()
        XCTAssertEqual(snapshot.health.recordedEventCount, 0)
        XCTAssertEqual(snapshot.health.ingressDroppedEventCount, 1_000)
        XCTAssertEqual(snapshot.health.droppedEventCount, 1_000)
        XCTAssertTrue(snapshot.events.isEmpty)
    }

    func testBlockedSinkKeepsIngressBoundedAndAccountsForEveryDrop() async {
        let concurrentEmissionCount = 10_000
        let totalEmissionCount = concurrentEmissionCount + 1
        let maximumPendingEvents = 64
        let gate = GatedIntegrationDiagnosticSink()
        let center = DiagnosticsCenter(
            configuration: DiagnosticsConfiguration(
                memoryEventLimit: totalEmissionCount,
                memoryByteLimit: 16 * 1_024 * 1_024,
                supportReportByteLimit: 16 * 1_024 * 1_024),
            sinks: [gate],
            clock: IntegrationDiagnosticClock())
        let emitter = DiagnosticsEmitter(
            center: center,
            configuration: DiagnosticsEmitterConfiguration(
                maximumPendingEvents: maximumPendingEvents))

        emitter.emit(
            severity: .notice,
            subsystem: .diagnostics,
            code: .appLaunchABIVerified)
        await gate.waitUntilFirstWriteStarts()
        DispatchQueue.concurrentPerform(iterations: concurrentEmissionCount) { _ in
            emitter.emit(
                severity: .notice,
                subsystem: .diagnostics,
                code: .appLaunchABIVerified)
        }
        await gate.releaseFirstWrite()
        await emitter.flush()

        let snapshot = await center.snapshot()
        let recorded = snapshot.health.recordedEventCount
        let dropped = snapshot.health.droppedEventCount
        XCTAssertLessThanOrEqual(
            emitter.maximumObservedPendingCountForTesting,
            maximumPendingEvents)
        XCTAssertEqual(recorded + dropped, UInt64(totalEmissionCount))
        XCTAssertEqual(snapshot.health.ingressDroppedEventCount, dropped)
        XCTAssertEqual(snapshot.events.map(\.sequence), Array(1...recorded))
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
