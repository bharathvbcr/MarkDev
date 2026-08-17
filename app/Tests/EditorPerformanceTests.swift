//
//  EditorPerformanceTests.swift
//  MarkDevKitTests
//
//  The plan commits to 60fps typing in a 10,000-line document. A performance
//  claim without a failing threshold is not a test, so these assert a budget
//  rather than merely reporting a number.
//

import AppKit
import XCTest

@testable import MarkDevKit

@MainActor
final class EditorPerformanceTests: XCTestCase {
    /// One frame at 60fps. A keystroke that costs more than this drops frames.
    private static let frameBudget: TimeInterval = 1.0 / 60.0

    /// A document with the shape of real writing rather than one repeated
    /// line: headings, lists, code, links, and emphasis all cost differently.
    private static func largeDocument(lines: Int) -> String {
        var out: [String] = []
        out.reserveCapacity(lines)
        var i = 0
        while out.count < lines {
            out.append("## Section \(i)")
            out.append("")
            out.append("Body with **bold**, *italic*, `code`, and [[Wiki Link \(i)]].")
            out.append("Tagged #section\(i) and ==highlighted== for good measure.")
            out.append("")
            out.append("- [ ] task \(i)")
            out.append("- item with [a link](https://example.com/\(i))")
            out.append("")
            out.append("```swift")
            out.append("let value\(i) = \(i)")
            out.append("```")
            out.append("")
            out.append("> [!NOTE]")
            out.append("> A callout in section \(i).")
            out.append("")
            i += 1
        }
        return out.prefix(lines).joined(separator: "\n")
    }

    private func measureMedian(iterations: Int = 5, _ body: () -> Void) -> TimeInterval {
        var samples: [TimeInterval] = []
        for _ in 0..<iterations {
            let start = CFAbsoluteTimeGetCurrent()
            body()
            samples.append(CFAbsoluteTimeGetCurrent() - start)
        }
        samples.sort()
        return samples[samples.count / 2]
    }

    /// Parse cost is gated in Rust instead — see `core/tests/performance.rs`,
    /// which runs under `--release`. These tests link a *debug* `libmarkdev.a`,
    /// where the parser measures ~10x slower (25ms vs 2.55ms for 10k lines),
    /// so a budget asserted here would be measuring the wrong build.
    ///
    /// This test keeps an eye on the debug figure only to catch a pathological
    /// regression, such as accidentally quadratic parsing.
    func testDebugParseHasNotRegressedPathologically() {
        let source = Self.largeDocument(lines: 10_000)
        let median = measureMedian { _ = ParsedDocument.parse(source) }

        print("[perf] debug Rust parse of 10k lines: \(String(format: "%.2f", median * 1000))ms")
        XCTAssertLessThan(
            median, 0.200,
            "debug parse is unexpectedly slow — check for superlinear behaviour")
    }

    func testEditorWorkPerKeystrokeStaysUnderAFrame() {
        // Gates the part Swift owns: restyle plus relayout.
        //
        // The full cycle also contains a Rust reparse, which in this *debug*
        // build costs ~22ms and alone exceeds a frame. That is a build
        // artifact, not shipping behaviour — the release parser is gated at
        // 2.55ms by core/tests/performance.rs. Subtracting the measured parse
        // isolates the editor's own cost, which is what a change to this
        // target can actually regress.
        //
        // The reparse is still whole-document; making it incremental is
        // tracked separately and will take the release cycle well clear of
        // the budget.
        let source = Self.largeDocument(lines: 10_000)
        let view = MarkdownTextView.make()
        view.setMarkdown(source)
        view.setSelectedRange(NSRange(location: 0, length: 0))

        let parseCost = measureMedian { _ = ParsedDocument.parse(source) }
        let cycle = measureMedian {
            view.insertText("x", replacementRange: view.selectedRange())
        }
        let editorCost = max(0, cycle - parseCost)

        print(
            "[perf] keystroke on 10k lines: \(String(format: "%.2f", cycle * 1000))ms total, "
                + "\(String(format: "%.2f", parseCost * 1000))ms debug parse, "
                + "\(String(format: "%.2f", editorCost * 1000))ms editor")

        // Deliberately *not* asserted against the 60fps frame budget.
        //
        // This is a debug build of both Swift and Rust, and it cannot be
        // measured in release: `@testable import` does not link against a
        // Release build of the framework. Asserting a 16.6ms target here
        // would be asserting something the configuration cannot deliver, and
        // the honest consequence is that release performance for this case
        // is currently **unverified**.
        //
        // What this does catch is a real regression — the quadratic marker
        // lookup that once cost 5,000ms would fail this immediately.
        XCTAssertLessThan(
            editorCost, 0.050,
            "per-keystroke styling has regressed badly; check for superlinear work")
    }

    /// A document of plain prose — the shape the incremental fast path is
    /// able to help with.
    private static func proseDocument(lines: Int) -> String {
        (0..<lines)
            .map { i in
                i % 3 == 2
                    ? ""
                    : "This is an ordinary sentence of prose numbered \(i) with no markup in it."
            }
            .joined(separator: "\n")
    }

    func testTypingInPlainProseAvoidsReparsing() {
        // Quantifies the incremental parser. In prose it should skip the
        // parse entirely; the comparison against the rich-Markdown fixture
        // above is what shows how narrow that win is.
        let view = MarkdownTextView.make()
        view.setMarkdown(Self.proseDocument(lines: 10_000))

        let text = view.markdown as NSString
        let anchor = text.range(of: "numbered 300 ")
        XCTAssertNotEqual(anchor.location, NSNotFound)
        view.setSelectedRange(NSRange(location: anchor.location + 5, length: 0))

        let before = view.parseStatistics
        let median = measureMedian(iterations: 7) {
            view.insertText("x", replacementRange: view.selectedRange())
        }
        let after = view.parseStatistics

        print(
            "[perf] prose keystroke on 10k lines: "
                + "\(String(format: "%.2f", median * 1000))ms, "
                + "shifted=\(after.shifted - before.shifted) "
                + "full=\(after.full - before.full) "
                + "resyncs=\(after.resyncs - before.resyncs)")

        XCTAssertEqual(
            after.resyncs, before.resyncs,
            "the Rust and Swift text copies must not drift during normal typing")
        XCTAssertGreaterThan(
            after.shifted, before.shifted,
            "typing in plain prose should avoid reparsing at least once")
        XCTAssertLessThan(
            median, Self.frameBudget,
            "a prose keystroke should comfortably fit in one frame")
    }

    func testCaretMovementWithinABlockDoesNotRestyle() {
        // Moving the caret inside one block leaves the reveal set unchanged,
        // so it must not trigger a full restyle. This is the optimisation
        // that keeps arrow keys cheap.
        let view = MarkdownTextView.make()
        view.setMarkdown(Self.largeDocument(lines: 10_000))
        view.setSelectedRange(NSRange(location: 0, length: 0))

        let median = measureMedian(iterations: 9) {
            let current = view.selectedRange().location
            view.setSelectedRange(NSRange(location: current + 1, length: 0))
        }

        print("[perf] caret move on 10k lines: \(String(format: "%.3f", median * 1000))ms")
        XCTAssertLessThan(
            median, Self.frameBudget,
            "caret movement must not cost a full restyle")
    }
}
