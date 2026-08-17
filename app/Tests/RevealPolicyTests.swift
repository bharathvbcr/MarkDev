//
//  RevealPolicyTests.swift
//  MarkDevKitTests
//

import XCTest

@testable import MarkDevKit

final class RevealPolicyTests: XCTestCase {
    /// `# Title\n\n**bold** text` — two blocks well apart.
    private let source = "# Title\n\n**bold** text"

    func testCaretInAHeadingRevealsOnlyThatBlock() {
        let doc = ParsedDocument.parse(source)
        let hidden = HiddenRanges(document: doc, selection: NSRange(location: 2, length: 0))

        // The `# ` is revealed, so it must not be collapsed.
        XCTAssertFalse(
            hidden.ranges.contains { $0.location == 0 },
            "the caret's own block should keep its syntax visible")
        // The `**` further down is in another block and stays hidden.
        XCTAssertTrue(
            hidden.ranges.contains { $0.location >= 9 },
            "other blocks stay collapsed")
    }

    func testSourceModeHidesNothing() {
        let doc = ParsedDocument.parse(source)
        let hidden = HiddenRanges(document: doc, selection: NSRange(location: 0, length: 0), mode: .source)
        XCTAssertTrue(hidden.ranges.isEmpty)
    }

    func testReadingModeHidesEverythingHideable() {
        let doc = ParsedDocument.parse(source)
        let hidden = HiddenRanges(
            document: doc, selection: NSRange(location: 2, length: 0), mode: .reading)
        XCTAssertFalse(
            hidden.ranges.isEmpty, "reading mode ignores the caret and hides syntax")
    }

    func testCaretAtBlockEndStillRevealsIt() {
        // Typing at the end of a heading must not make its `# ` vanish
        // mid-keystroke.
        let doc = ParsedDocument.parse("# Title")
        let end = ("# Title" as NSString).length
        let hidden = HiddenRanges(document: doc, selection: NSRange(location: end, length: 0))
        XCTAssertTrue(hidden.ranges.isEmpty, "caret at end of block keeps it revealed")
    }

    func testTaskMarkersAreNeverHidden() {
        // Hiding `- [x]` with nothing drawn in its place would read as the
        // checkbox having been deleted.
        let doc = ParsedDocument.parse("- [x] done\n- [ ] todo")
        let hidden = HiddenRanges(
            document: doc, selection: NSRange(location: 0, length: 0), mode: .reading)
        guard let task = doc.spans.first(where: { $0.kind == .taskMarker }) else {
            return XCTFail("expected a task marker span")
        }
        XCTAssertFalse(
            hidden.ranges.contains { NSIntersectionRange($0, task.range).length > 0 },
            "task markers must stay visible until a checkbox is drawn for them")
    }

    func testHorizontalRulesAreNeverHidden() {
        let doc = ParsedDocument.parse("a\n\n---\n\nb")
        let hidden = HiddenRanges(
            document: doc, selection: NSRange(location: 0, length: 0), mode: .reading)
        guard let rule = doc.blocks.first(where: { $0.kind == .rule }) else {
            return XCTFail("expected a rule block")
        }
        XCTAssertFalse(
            hidden.ranges.contains { NSIntersectionRange($0, rule.range).length > 0 },
            "a hidden rule would leave a blank line that reads as data loss")
    }

    func testSelectionSpanningBlocksRevealsAllOfThem() {
        let doc = ParsedDocument.parse(source)
        let all = NSRange(location: 0, length: (source as NSString).length)
        let revealed = RevealPolicy.revealedBlocks(in: doc, selection: all)
        XCTAssertEqual(revealed.count, doc.blocks.count)
    }

    func testAnUnfocusedEditorRevealsNothing() {
        // Syntax is revealed because the caret is somewhere. With no keyboard
        // focus there is no caret in play, and showing markers would make a
        // note look like raw source the instant it opens.
        let doc = ParsedDocument.parse(source)
        let hidden = HiddenRanges(
            document: doc, selection: NSRange(location: 2, length: 0), isEditing: false)
        let focused = HiddenRanges(
            document: doc, selection: NSRange(location: 2, length: 0), isEditing: true)

        XCTAssertGreaterThan(
            hidden.ranges.count, focused.ranges.count,
            "an unfocused editor should hide at least as much as a focused one")
        XCTAssertTrue(
            hidden.ranges.contains { $0.location == 0 },
            "the heading's `# ` should be collapsed when unfocused")
    }

    func testSourceModeStillShowsEverythingWhenUnfocused() {
        // Source mode is an explicit user choice and outranks focus.
        let doc = ParsedDocument.parse(source)
        let hidden = HiddenRanges(
            document: doc, selection: NSRange(location: 0, length: 0),
            mode: .source, isEditing: false)
        XCTAssertTrue(hidden.ranges.isEmpty)
    }

    func testEmptyDocumentIsHandled() {
        let hidden = HiddenRanges(
            document: .empty, selection: NSRange(location: 0, length: 0))
        XCTAssertTrue(hidden.ranges.isEmpty)
    }
}
