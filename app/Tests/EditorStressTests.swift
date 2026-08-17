//
//  EditorStressTests.swift
//  MarkDevKitTests
//
//  Randomised editing against an oracle.
//
//  Scoped restyling is an optimisation whose failure mode is silence: the
//  wrong scope does not crash or throw, it leaves a paragraph somewhere
//  wearing last keystroke's colours. Hand-written cases cover the situations
//  someone thought of. These cover the ones nobody did — thousands of edits,
//  each checked against the only oracle that settles the question: what the
//  same text looks like when styled from scratch.
//

import AppKit
import XCTest

@testable import MarkDevKit

/// SplitMix64 — a seeded generator, so a failure names the seed that
/// reproduces it rather than "sometimes".
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@MainActor
final class EditorStressTests: XCTestCase {

    // MARK: - Fixtures

    /// Blocks that style differently from one another, including the ones
    /// whose meaning depends on text elsewhere in the document.
    private static let blockPalette: [String] = [
        "# Heading one",
        "## Heading two",
        "Plain paragraph with no markup at all.",
        "Paragraph with **bold**, *italic*, `code`, ~~struck~~ and ==highlight==.",
        "Paragraph with [[Wiki Link]], [[Other|aliased]] and #a-tag.",
        "Paragraph referencing [foo] and [bar][baz].",
        "[foo]: https://example.test/foo",
        "[baz]: https://example.test/baz",
        "A paragraph with an inline link [text](https://example.test) in it.",
        "- item one\n- item two\n- item three",
        "1. first\n2. second",
        "- [ ] unchecked task\n- [x] checked task",
        "    - nested\n        - deeper",
        "> a quote\n> continued across lines",
        "> [!NOTE]\n> A callout with **bold** inside.",
        "```swift\nlet x = 1\nfunc f() {}\n```",
        "```\nunlabelled fence\n```",
        "| a | b |\n|---|---|\n| 1 | 2 |",
        "---",
        "Setext heading\n==============",
        "Text with a footnote[^1].",
        "[^1]: The footnote body.",
        "Emoji 🎉 and accents éàü so offsets are not ASCII.",
        "$$\nx^2 + y^2\n$$",
        "Math $inline$ and \\(escaped\\) text.",
        "<div>raw html</div>",
        "Trailing spaces here.   ",
        "A line ending in a backslash \\",
    ]

    /// What a keystroke, a paste, or a delete looks like. Weighted towards the
    /// characters that change how the rest of the file parses.
    private static let snippetPalette: [String] = [
        "", "x", "word ", "\n", "\n\n", "\t", " ", "  ",
        "#", "# ", "##", ">", "> ", "-", "- ", "1. ", "- [ ] ",
        "*", "**", "***", "_", "`", "``", "```", "```swift\n", "~~", "==",
        "[", "]", "[[", "]]", "(", ")", "|", "$", "^",
        "[foo]", "[foo]: https://example.test/foo\n", "[[Wiki Link]]",
        "---\n", "===\n", "🎉", "é", "\u{200B}",
        "Some longer pasted text\n\nwith a blank line in it.\n",
        // Line endings a file can arrive with, and a paste long enough to
        // cross several blocks at once.
        "\r\n", "\r",
        "# Pasted heading\n\n- pasted item\n\n```swift\nlet pasted = 1\n```\n",
    ]

    private func document(blocks: Int, using rng: inout SeededGenerator) -> String {
        (0..<blocks)
            .map { _ in Self.blockPalette.randomElement(using: &rng)! }
            .joined(separator: "\n\n")
    }

    // MARK: - Oracle

    /// Gives the editor the turn of the runloop it needs.
    ///
    /// Undo and redo reach `NSTextStorage` without telling the text view, so
    /// the editor catches them from the storage's own notification and
    /// reparses just after the edit cycle closes — see
    /// `MarkdownTextView.storageDidProcessEditing`. A running app turns the
    /// runloop constantly; a test has to do it deliberately, or it measures a
    /// document that has not finished reacting.
    private func drainDeferredWork(_ view: MarkdownTextView) {
        var spins = 0
        while !view.hasSettledAfterTextChanges, spins < 200 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.001))
            spins += 1
        }
        XCTAssertTrue(
            view.hasSettledAfterTextChanges,
            "the editor never caught up with a text change")
    }

    /// Fails unless `view` is styled exactly as a document of the same text,
    /// looked at from the same caret, would be when opened fresh.
    ///
    /// Attribute-by-attribute rather than spot checks: the whole point is to
    /// catch the run somebody forgot about.
    @discardableResult
    private func assertMatchesFreshParse(
        _ view: MarkdownTextView,
        context: @autoclosure () -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        // Both documents are read from the same caret, and that caret is the
        // start of the document.
        //
        // Live preview reveals the block the caret is in, so two views with
        // the caret in different blocks *should* be styled differently and
        // comparing them would be meaningless. Asking both for offset zero
        // makes the comparison well defined: it is the one position no hidden
        // run can swallow, so the caret rule — which nudges out of collapsed
        // syntax in whichever direction the caret was travelling — cannot land
        // the two views in different places. Where the caret rests after an
        // edit is a separate question, and
        // `testCaretNeverRestsInsideCollapsedSyntax` asks it directly.
        drainDeferredWork(view)
        let origin = NSRange(location: 0, length: 0)
        view.setSelectedRange(origin)

        let fresh = MarkdownTextView.make()
        fresh.mode = view.mode
        fresh.setMarkdown(view.markdown)
        fresh.setSelectedRange(origin)

        guard let actual = view.textStorage, let expected = fresh.textStorage else {
            XCTFail("no storage", file: file, line: line)
            return false
        }
        guard actual.string == expected.string else {
            XCTFail("text diverged: \(context())", file: file, line: line)
            return false
        }
        guard view.selectedRange() == fresh.selectedRange() else {
            XCTFail(
                "caret landed at \(NSStringFromRange(view.selectedRange())) but a "
                    + "fresh document puts it at \(NSStringFromRange(fresh.selectedRange())): "
                    + context(),
                file: file, line: line)
            return false
        }

        var offset = 0
        while offset < expected.length {
            var actualRange = NSRange(location: 0, length: 0)
            var expectedRange = NSRange(location: 0, length: 0)
            let actualAttributes = actual.attributes(at: offset, effectiveRange: &actualRange)
            let expectedAttributes = expected.attributes(at: offset, effectiveRange: &expectedRange)
            // Advance by whichever run ends first. Stepping to the end of the
            // *expected* run jumps over any difference sitting inside it, and
            // an oracle that skips is worse than no oracle: it reports
            // agreement it never checked.
            let step = min(NSMaxRange(actualRange), NSMaxRange(expectedRange))
            if actualAttributes as NSDictionary != expectedAttributes as NSDictionary {
                let sample = (expected.string as NSString).substring(
                    with: NSRange(
                        location: expectedRange.location,
                        length: min(expectedRange.length, 48)))
                XCTFail(
                    """
                    styling differs at \(offset) (\(sample.debugDescription))
                    \(context())
                    stale:   \(actualAttributes)
                    correct: \(expectedAttributes)
                    """,
                    file: file, line: line)
                return false
            }
            offset = max(offset + 1, step)
        }
        return true
    }

    // MARK: - Randomised editing

    /// One seed's worth of editing: random replacements at random places, each
    /// one checked against a fresh parse before the next is applied.
    private func runEditingStress(
        seed: UInt64, steps: Int, blocks: Int, mode: EditorMode = .livePreview
    ) {
        var rng = SeededGenerator(seed: seed)
        let source = document(blocks: blocks, using: &rng)

        let view = MarkdownTextView.make()
        view.mode = mode
        view.setMarkdown(source)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        // Mirrors the document independently, so a wrong edit shows up as
        // wrong *text* rather than as mysteriously wrong styling.
        var mirror = source as NSString

        for step in 0..<steps {
            let length = mirror.length
            let start = length == 0 ? 0 : Int.random(in: 0...length, using: &rng)
            let maxRun = min(24, length - start)
            let runLength = maxRun <= 0 ? 0 : Int.random(in: 0...maxRun, using: &rng)
            var target = NSRange(location: start, length: runLength)
            // Never split a surrogate pair: the text view would refuse the
            // edit and the step would test nothing.
            target = mirror.rangeOfComposedCharacterSequences(for: target)
            let replacement = Self.snippetPalette.randomElement(using: &rng)!

            view.setSelectedRange(target)
            view.insertText(replacement, replacementRange: view.selectedRange())
            mirror = mirror.replacingCharacters(in: target, with: replacement) as NSString

            // Move the caret somewhere else half the time: the reveal set
            // follows the caret, so where it rests changes what is collapsed.
            if Bool.random(using: &rng), mirror.length > 0 {
                let where_ = Int.random(in: 0...mirror.length, using: &rng)
                view.setSelectedRange(NSRange(location: where_, length: 0))
            }

            let describe = """
                seed \(seed) step \(step): replaced \(NSStringFromRange(target)) \
                with \(replacement.debugDescription)
                """
            XCTAssertEqual(view.markdown, mirror as String, describe)
            guard assertMatchesFreshParse(view, context: describe) else { return }
        }
    }

    func testRandomEditsNeverLeaveStaleStyling() {
        // Independent seeds rather than one long run: different seeds reach
        // different construct combinations, and a failure names the one to
        // re-run.
        for seed in [1, 2, 3, 4, 5, 6] as [UInt64] {
            runEditingStress(seed: seed, steps: 110, blocks: 14)
        }
    }

    func testRandomEditsInSourceModeAsWellAsLivePreview() {
        // Mode decides what is collapsed at all, and source mode hides
        // nothing — a scope that is subtly wrong about hidden runs behaves
        // differently there. Reading mode is not editable by design, so it is
        // exercised by `testSwitchingModeAfterEditingRestylesEverything`
        // instead.
        for mode in [EditorMode.source, .livePreview] {
            runEditingStress(seed: 21, steps: 60, blocks: 12, mode: mode)
        }
    }

    func testSwitchingModeAfterEditingRestylesEverything() {
        // Reading mode collapses every marker in the document at once, which
        // is the widest possible change to the hidden set with no change to
        // the text. It has to land on a document that has been edited, not
        // just on a freshly opened one.
        var rng = SeededGenerator(seed: 41)
        let view = MarkdownTextView.make()
        view.setMarkdown(document(blocks: 12, using: &rng))

        for _ in 0..<20 {
            let length = (view.markdown as NSString).length
            view.setSelectedRange(
                NSRange(location: Int.random(in: 0...length, using: &rng), length: 0))
            view.insertText(
                Self.snippetPalette.randomElement(using: &rng)!,
                replacementRange: view.selectedRange())
        }

        for mode in [EditorMode.reading, .source, .livePreview, .reading] {
            view.mode = mode
            guard assertMatchesFreshParse(view, context: "in \(mode) after editing") else { return }
        }
    }

    func testRandomEditsOnADocumentOfManyBlocks() {
        // Wider documents: more blocks means more chances for the leading and
        // trailing runs to line up on the wrong element.
        for seed in [101, 102] as [UInt64] {
            runEditingStress(seed: seed, steps: 40, blocks: 60)
        }
    }

    /// Supplies the undo manager a text view normally gets from its window.
    /// A view built for a test has no window, so without this `allowsUndo`
    /// registers nothing and an undo test silently tests nothing.
    private final class UndoHost: NSObject, NSTextViewDelegate {
        let manager = UndoManager()
        func undoManager(for view: NSTextView) -> UndoManager? { manager }
    }

    func testUndoAndRedoRestoreStylingExactly() {
        // Undo replays edits through the same path, backwards, with ranges
        // that describe the document as it was. If the scope arithmetic has a
        // sign error anywhere, undo is where it shows.
        var rng = SeededGenerator(seed: 7)
        let source = document(blocks: 12, using: &rng)

        let host = UndoHost()
        let view = MarkdownTextView.make()
        view.delegate = host
        view.setMarkdown(source)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        // Whatever `setMarkdown` registered is setup, not an edit under test.
        host.manager.removeAllActions()

        for _ in 0..<25 {
            let length = (view.markdown as NSString).length
            let location = Int.random(in: 0...length, using: &rng)
            view.setSelectedRange(NSRange(location: location, length: 0))
            view.insertText(
                Self.snippetPalette.randomElement(using: &rng)!,
                replacementRange: view.selectedRange())
        }
        let edited = view.markdown
        XCTAssertNotEqual(edited, source)
        assertMatchesFreshParse(view, context: "after 25 edits")

        // Drained rather than counted: AppKit coalesces consecutive typing
        // into one undo group, so the number of groups is its business, not
        // the test's.
        var steps = 0
        while view.undoManager?.canUndo == true, steps < 100 {
            view.undoManager?.undo()
            drainDeferredWork(view)
            steps += 1
            guard assertMatchesFreshParse(view, context: "after undo \(steps)") else { return }
        }
        XCTAssertGreaterThan(steps, 0, "the edits should be undoable")
        XCTAssertEqual(view.markdown, source, "undo should restore the original text")

        steps = 0
        while view.undoManager?.canRedo == true, steps < 100 {
            view.undoManager?.redo()
            drainDeferredWork(view)
            steps += 1
            guard assertMatchesFreshParse(view, context: "after redo \(steps)") else { return }
        }
        XCTAssertEqual(view.markdown, edited, "redo should restore the edited text")
    }

    func testUndoInARealWindowRestylesTheDocument() {
        // The path that has to be exercised in a window, because that is where
        // it goes wrong: AppKit's own undo manager replays the change straight
        // into `NSTextStorage`, calling neither `shouldChangeText` nor
        // `didChangeText`. Before the storage notification was observed, this
        // left `**bold**` styled as bold text that was no longer there.
        let view = MarkdownTextView.make()
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        let window = NSWindow(
            contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView?.addSubview(view)
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(view), "the view has to hold the caret")
        defer { window.orderOut(nil) }

        let source = "# Title\n\nBody with ==highlight== here.\n"
        view.setMarkdown(source)
        view.setSelectedRange(NSRange(location: 9, length: 0))
        view.insertText("**bold** ", replacementRange: view.selectedRange())
        assertMatchesFreshParse(view, context: "after typing in a window")

        XCTAssertEqual(view.undoManager?.canUndo, true, "AppKit should have registered the edit")
        view.undoManager?.undo()
        drainDeferredWork(view)
        XCTAssertEqual(view.markdown, source)
        assertMatchesFreshParse(view, context: "after undo in a window")

        view.undoManager?.redo()
        assertMatchesFreshParse(view, context: "after redo in a window")
    }

    func testCaretNeverRestsInsideCollapsedSyntax() {
        // The invariant the oracle deliberately steps around: wherever an edit
        // leaves the caret, it must not be *inside* a collapsed run. A caret
        // parked inside hidden syntax renders at 0.01pt — it reads as the
        // cursor having disappeared.
        var rng = SeededGenerator(seed: 31)
        let source = document(blocks: 16, using: &rng)

        let view = MarkdownTextView.make()
        view.setMarkdown(source)

        for step in 0..<150 {
            let length = (view.markdown as NSString).length
            let start = Int.random(in: 0...length, using: &rng)
            let target = (view.markdown as NSString).rangeOfComposedCharacterSequences(
                for: NSRange(location: start, length: Int.random(in: 0...min(12, length - start), using: &rng)))
            view.setSelectedRange(target)
            view.insertText(
                Self.snippetPalette.randomElement(using: &rng)!,
                replacementRange: view.selectedRange())

            let caret = view.selectedRange().location
            let hidden = HiddenRanges(
                document: view.parsed, selection: view.selectedRange(), mode: view.mode,
                isEditing: true)
            XCTAssertFalse(
                hidden.contains(caret),
                "step \(step): caret at \(caret) is inside the collapsed run "
                    + "\(hidden.range(containing: caret).map(NSStringFromRange) ?? "?")")
        }
    }

    func testEditsAtEveryOffsetOfASmallDocument() {
        // Exhaustive rather than random, over a document small enough to try
        // every position: boundaries between blocks, inside markers, at the
        // very start and the very end.
        let source = """
            # Title

            Paragraph with **bold** and [foo].

            ```swift
            let x = 1
            ```

            > [!NOTE]
            > Callout.

            [foo]: https://example.test
            """

        for insertion in ["x", "\n", "```", "> ", "#", "*"] {
            for offset in 0...(source as NSString).length {
                let view = MarkdownTextView.make()
                view.setMarkdown(source)
                view.setSelectedRange(NSRange(location: offset, length: 0))
                view.insertText(insertion, replacementRange: view.selectedRange())
                guard
                    assertMatchesFreshParse(
                        view,
                        context: "inserted \(insertion.debugDescription) at \(offset)")
                else { return }
            }
        }
    }

    func testDeletingEveryRangeOfASmallDocument() {
        let source = """
            ## Section

            Body with `code`, a [[Wiki Link]] and a #tag.

            - [ ] task
            - item

            > quote
            """
        let length = (source as NSString).length

        for start in stride(from: 0, to: length, by: 3) {
            for runLength in [1, 2, 5, 13] where start + runLength <= length {
                let view = MarkdownTextView.make()
                view.setMarkdown(source)
                let target = (source as NSString).rangeOfComposedCharacterSequences(
                    for: NSRange(location: start, length: runLength))
                view.setSelectedRange(target)
                view.insertText("", replacementRange: view.selectedRange())
                guard
                    assertMatchesFreshParse(
                        view, context: "deleted \(NSStringFromRange(target))")
                else { return }
            }
        }
    }

    // MARK: - Scale

    func testNoSingleEditStallsOnALargeDocument() {
        // The stall this suite exists for was one edit in a large file, so the
        // guard belongs on the worst edit rather than on the average. Twenty
        // times the debug parse cost, which a whole-document restyle clears
        // easily and a scoped one never approaches.
        var rng = SeededGenerator(seed: 99)
        let source = (0..<160)
            .map { _ in Self.blockPalette.randomElement(using: &rng)! }
            .joined(separator: "\n\n")

        let view = MarkdownTextView.make()
        view.setMarkdown(source)

        var worst: TimeInterval = 0
        var worstStep = -1
        for step in 0..<120 {
            let length = (view.markdown as NSString).length
            let start = Int.random(in: 0...length, using: &rng)
            let runLength = Int.random(in: 0...min(20, length - start), using: &rng)
            let target = (view.markdown as NSString).rangeOfComposedCharacterSequences(
                for: NSRange(location: start, length: runLength))
            let replacement = Self.snippetPalette.randomElement(using: &rng)!

            view.setSelectedRange(target)
            let started = CFAbsoluteTimeGetCurrent()
            view.insertText(replacement, replacementRange: view.selectedRange())
            let cost = CFAbsoluteTimeGetCurrent() - started
            if cost > worst {
                worst = cost
                worstStep = step
            }
        }

        print(
            "[perf] worst of 120 random edits on \(view.markdown.count) characters: "
                + "\(String(format: "%.2f", worst * 1000))ms (step \(worstStep))")
        // Correct at the end as well as fast throughout: a scope that drifted
        // over 120 edits would show here even if no single edit was slow.
        assertMatchesFreshParse(view, context: "after 120 edits on a large document")
        XCTAssertLessThan(
            worst, 0.500,
            "one edit in a large document is stalling; check what forced a full restyle")
    }

    // MARK: - Marker lookup

    func testMarkerWindowMatchesAFullScanOnRandomDocuments() {
        // The binary search that replaced a per-block scan of every marker.
        // Its one assumption — that overlapping markers sit next to each other
        // in sort order — is worth a few thousand random probes.
        for seed in [11, 12, 13] as [UInt64] {
            var rng = SeededGenerator(seed: seed)
            let source = document(blocks: 20, using: &rng)
            let doc = ParsedDocument.parse(source)
            let length = (source as NSString).length
            XCTAssertFalse(doc.markers.isEmpty)

            for _ in 0..<400 {
                let start = Int.random(in: 0...length, using: &rng)
                let probe = NSRange(
                    location: start,
                    length: Int.random(in: 0...max(0, length - start), using: &rng))
                let expected = doc.markers.filter {
                    NSIntersectionRange($0.range, probe).length > 0
                }
                let actual = doc.markers[doc.markerIndices(overlapping: probe)].filter {
                    NSIntersectionRange($0.range, probe).length > 0
                }
                XCTAssertEqual(
                    Array(actual), expected,
                    "seed \(seed): window missed markers overlapping \(NSStringFromRange(probe))")
            }
        }
    }
}
