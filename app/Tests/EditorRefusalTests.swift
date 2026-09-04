//
//  EditorRefusalTests.swift
//  MarkDevKitTests
//
//  A document the editor refuses must not look like a document that is empty.
//
//  `setMarkdown` returns `Bool` and every caller discarded it, so a refusal
//  left a blank page and nothing else: no alert, no log line, no counter. The
//  `editor` subsystem had no diagnostic codes at all, which meant the single
//  failure a reader cannot miss was the one failure the support export could
//  not explain. Worse, `updateNSView` pushes text in whenever it differs from
//  the view's — and a refused document never becomes the view's — so the
//  condition stayed true and SwiftUI re-attempted the same rejected parse on
//  every update pass for the life of the window.
//

import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import MarkDevKit

private struct RefusalClock: DiagnosticClock {
    func millisecondsSince1970() -> Int64 { 1_700_000_000_000 }
    func uptimeNanoseconds() -> UInt64 { 1 }
}

private actor RecordingSink: DiagnosticSink {
    private(set) var codes: [String] = []
    private(set) var byteCounts: [DiagnosticMetadataValue] = []

    func write(_ record: DiagnosticRecord) async throws {
        codes.append(record.event.code.rawValue)
        if let bytes = record.event.metadata[.byteCount] {
            byteCounts.append(bytes)
        }
    }
}

@MainActor
final class EditorRefusalTests: XCTestCase {

    private func editor(_ emitter: DiagnosticsEmitter) -> MarkdownTextView {
        let view = MarkdownTextView.make()
        view.diagnostics = emitter
        view.frame = NSRect(x: 0, y: 0, width: 480, height: 400)
        return view
    }

    private func harness() -> (DiagnosticsEmitter, RecordingSink) {
        let sink = RecordingSink()
        let center = DiagnosticsCenter(sinks: [sink], clock: RefusalClock())
        return (DiagnosticsEmitter(center: center), sink)
    }

    func testARefusedDocumentIsRecordedRatherThanSilentlyBlank() async {
        let (emitter, sink) = harness()
        let view = editor(emitter)

        // A NUL byte is the reachable case: it survives a UTF-8 file read and
        // is refused at the FFI, so the note opens blank on an ordinary path.
        XCTAssertFalse(view.setMarkdown("before\0after"))
        XCTAssertEqual(view.markdown, "", "a refusal must not commit half a document")

        await emitter.flush()
        let codes = await sink.codes
        XCTAssertEqual(
            codes, ["editor.document.rejected"],
            "a blank page with no diagnostic is indistinguishable from an empty note")
    }

    func testAnAcceptedDocumentRecordsNothing() async {
        let (emitter, sink) = harness()
        let view = editor(emitter)

        XCTAssertTrue(view.setMarkdown("# Title\n\n- one\n- two\n"))
        XCTAssertEqual(view.markdown, "# Title\n\n- one\n- two\n")

        await emitter.flush()
        let codes = await sink.codes
        XCTAssertTrue(codes.isEmpty, "an ordinary note must not log an error: \(codes)")
    }

    func testTheRefusalCarriesTheSizeThatSeparatesItsTwoCauses() async {
        let (emitter, sink) = harness()
        let view = editor(emitter)

        let oversized = String(repeating: "x", count: MarkdownReadLimits.maximumDocumentBytes + 1)
        XCTAssertFalse(view.setMarkdown(oversized))

        await emitter.flush()
        let counts = await sink.byteCounts
        XCTAssertEqual(
            counts, [.integer(Int64(MarkdownReadLimits.maximumDocumentBytes + 1))],
            "without the size, 'too large' and 'not text' are the same log line")
    }

    /// Every refusal is reported, because each one is a document lost.
    ///
    /// The emitter is the only thing that de-duplicates, and it does not — so
    /// a caller that retries in a loop would flood the ring and evict the
    /// events explaining *why*. That is what the SwiftUI bridge's
    /// `refusedText` exists to prevent, one layer up.
    func testEachDistinctRefusalIsRecordedOnce() async {
        let (emitter, sink) = harness()
        let view = editor(emitter)

        XCTAssertFalse(view.setMarkdown("first\0doc"))
        XCTAssertFalse(view.setMarkdown("second\0doc"))

        await emitter.flush()
        let codes = await sink.codes
        XCTAssertEqual(codes.count, 2)
    }

    /// The view stays usable: a refusal is not a wedged editor.
    func testAnOrdinaryDocumentStillOpensAfterARefusal() async {
        let (emitter, _) = harness()
        let view = editor(emitter)

        XCTAssertFalse(view.setMarkdown("bad\0doc"))
        XCTAssertTrue(view.setMarkdown("# Recovered\n\nbody\n"))
        XCTAssertEqual(view.markdown, "# Recovered\n\nbody\n")
    }

    // MARK: - The retry the bridge must not make

    private func coordinator() -> MarkdownEditorView.Coordinator {
        var text = ""
        return MarkdownEditorView.Coordinator(
            text: Binding(get: { text }, set: { text = $0 }), onParse: nil)
    }

    func testARefusedDocumentIsNotPushedAgainOnEveryUpdatePass() {
        let coordinator = coordinator()
        let refused = "before\0after"

        // First pass: the view holds nothing, so the document is offered.
        XCTAssertTrue(coordinator.shouldPush(refused, currentlyShowing: ""))
        coordinator.recordPush(of: refused, accepted: false)

        // The view still holds nothing, so the naive condition — "the text
        // differs from what is shown" — is still true, and stays true forever.
        // SwiftUI calls `updateNSView` on every state change, so this is an
        // unbounded loop of full parse attempts, not a one-off.
        XCTAssertFalse(
            coordinator.shouldPush(refused, currentlyShowing: ""),
            "a document already refused must not be re-attempted every update pass")
    }

    func testADifferentDocumentIsStillTriedAfterARefusal() {
        let coordinator = coordinator()
        coordinator.recordPush(of: "bad\0doc", accepted: false)

        XCTAssertTrue(
            coordinator.shouldPush("# A real note\n", currentlyShowing: ""),
            "refusing one document must not wedge the editor against all others")
    }

    func testEditingTheRefusedDocumentClearsTheRefusal() {
        let coordinator = coordinator()
        let refused = "bad\0doc"
        coordinator.recordPush(of: refused, accepted: false)

        // The reader repairs the file and reopens it: same pane, new bytes.
        let repaired = "bad doc"
        XCTAssertTrue(coordinator.shouldPush(repaired, currentlyShowing: ""))
        coordinator.recordPush(of: repaired, accepted: true)

        // Accepted, so nothing is being suppressed any more — and the view now
        // holds it, which is what stops the push this time.
        XCTAssertFalse(coordinator.shouldPush(repaired, currentlyShowing: repaired))
        XCTAssertTrue(coordinator.shouldPush(refused, currentlyShowing: repaired))
    }

    func testAnAcceptedDocumentIsPushedOnlyUntilTheViewHoldsIt() {
        let coordinator = coordinator()
        let note = "# Title\n"

        XCTAssertTrue(coordinator.shouldPush(note, currentlyShowing: ""))
        coordinator.recordPush(of: note, accepted: true)
        XCTAssertFalse(coordinator.shouldPush(note, currentlyShowing: note))
    }
}
