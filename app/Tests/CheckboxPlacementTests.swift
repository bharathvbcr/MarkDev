//
//  CheckboxPlacementTests.swift
//  MarkDevKitTests
//
//  Where a task item's checkbox lands, and why that took two attempts.
//

import AppKit
import XCTest

@testable import MarkDevKit

/// The geometry on its own, with no TextKit involved.
///
/// This is the part that was actually wrong. `draw(at:in:)` receives a `point`
/// of `(0, 0)` with the context already translated to the fragment's origin —
/// so "x points from `point`" means "x points from wherever TextKit decided to
/// put this fragment. And TextKit is not consistent about that *within a
/// single list*: measured on a two-item task list, the first item's fragment
/// sits at the paragraph's 45pt indent while the second sits at the container
/// edge. A box at a fixed offset from `point` is therefore right for one item
/// and lands on the first letter of the other.
///
/// The fix subtracts whatever indent the fragment's own origin already
/// contributes, so the box ends up in the same place on screen either way.
/// These cases are that claim, stated as arithmetic; ``CheckboxPlacementTests``
/// then asserts it against both conventions as TextKit really produces them.
final class CheckboxGeometryTests: XCTestCase {
    private let gutter = MarkdownLayoutFragment.Metrics.checkboxGutter
    private let inset = MarkdownLayoutFragment.Metrics.checkboxInset
    private let side = MarkdownLayoutFragment.Metrics.checkboxSide

    private func x(textIndent: CGFloat, carried: CGFloat) -> CGFloat {
        MarkdownLayoutFragment.checkboxX(
            textIndent: textIndent, indentCarriedByFragment: carried,
            gutter: gutter, inset: inset)
    }

    func testBothConventionsPutTheBoxInTheSamePlaceOnScreen() {
        // The whole point. Two items of the *same* list, one whose fragment
        // sits at the container edge and one whose origin already includes the
        // 45pt indent, must draw the box at the same absolute position —
        // the reader sees one list either way.
        let indent: CGFloat = 45

        // Convention A: the fragment sits at the container edge, so the box's
        // own x is measured from there.
        let atEdge = x(textIndent: indent, carried: 0)
        // Convention B: the fragment already sits at the indent, so the
        // context is translated that far and the box must come back left.
        let atIndent = indent + x(textIndent: indent, carried: indent)

        XCTAssertEqual(atEdge, atIndent, accuracy: 0.001)
    }

    func testTheBoxEndsBeforeTheTextBegins() {
        for indent in stride(from: 20.0, through: 120.0, by: 5.0) {
            for carried in [0.0, indent] {
                // Absolute position of the box and of the text, in the same
                // space, whichever convention is in play.
                let boxEnd = carried + x(textIndent: indent, carried: carried) + side
                XCTAssertLessThanOrEqual(
                    boxEnd, indent,
                    "indent \(indent), carried \(carried): the box overlaps the text")
            }
        }
    }

    func testTheBoxStaysInsideTheGutterRatherThanDriftingLeft() {
        // Too far left is its own bug: the box stops reading as belonging to
        // the item beside it.
        for indent in stride(from: 25.0, through: 120.0, by: 5.0) {
            for carried in [0.0, indent] {
                let boxStart = carried + x(textIndent: indent, carried: carried)
                XCTAssertGreaterThanOrEqual(
                    boxStart, indent - gutter,
                    "indent \(indent), carried \(carried): the box left its gutter")
            }
        }
    }

    func testADeeperItemMovesItsBoxWithItsText() {
        // Anchored to the fragment's origin, every box in a nested list piled
        // up at the left margin while the text marched right.
        let shallow = x(textIndent: 45, carried: 0)
        let deep = x(textIndent: 77, carried: 0)
        XCTAssertGreaterThan(deep, shallow)
        XCTAssertEqual(deep - shallow, 32, accuracy: 0.001, "it moves exactly as far as the text")
    }

    func testAnUnindentedParagraphCannotPushTheBoxOffTheLeftEdge() {
        // A task item is always indented, but the arithmetic must not produce
        // a wild negative if the styler ever reserved nothing.
        let boxStart = x(textIndent: 0, carried: 0)
        XCTAssertGreaterThanOrEqual(boxStart, -gutter)
    }
}

@MainActor
final class CheckboxPlacementTests: XCTestCase {
    private func laidOut(_ markdown: String) throws -> MarkdownTextView {
        let view = MarkdownTextView.make()
        view.frame = NSRect(x: 0, y: 0, width: 520, height: 300)
        view.setMarkdown(markdown)
        let manager = try XCTUnwrap(view.textLayoutManager)
        manager.ensureLayout(for: manager.documentRange)
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func taskFragment(in view: MarkdownTextView) throws -> MarkdownLayoutFragment {
        let manager = try XCTUnwrap(view.textLayoutManager)
        var found: MarkdownLayoutFragment?
        manager.enumerateTextLayoutFragments(
            from: manager.documentRange.location, options: [.ensuresLayout]
        ) { fragment in
            if let fragment = fragment as? MarkdownLayoutFragment,
                fragment.decoration.taskChecked != nil
            {
                found = fragment
                return false
            }
            return true
        }
        return try XCTUnwrap(found, "the fixture should contain a task item")
    }

    /// Every task fragment in a document, in order.
    private func taskFragments(in view: MarkdownTextView) throws -> [MarkdownLayoutFragment] {
        let manager = try XCTUnwrap(view.textLayoutManager)
        var found: [MarkdownLayoutFragment] = []
        manager.enumerateTextLayoutFragments(
            from: manager.documentRange.location, options: [.ensuresLayout]
        ) { fragment in
            if let fragment = fragment as? MarkdownLayoutFragment,
                fragment.decoration.taskChecked != nil
            {
                found.append(fragment)
            }
            return true
        }
        return found
    }

    /// A list long enough to contain both of TextKit's conventions.
    private static let list = """
        ## Tasks

        - [x] Ship the graph
        - [ ] Sign the extension

        """

    func testTheFixtureReallyContainsBothConventions() throws {
        // Guards the guard. If TextKit ever stops mixing conventions within a
        // list, the tests below would still pass while covering only one case
        // — and the bug they exist for would be free to come back.
        let view = try laidOut(Self.list)
        let carried = Set(try taskFragments(in: view).map(\.indentCarriedByFragment))

        XCTAssertEqual(
            carried.count, 2,
            "expected one fragment carrying its indent and one not, got \(carried)")
        XCTAssertTrue(carried.contains(0), "one item should sit at the container edge")
    }

    func testEveryTaskFragmentReportsTheIndentTheStylerReserved() throws {
        let view = try laidOut(Self.list)
        for fragment in try taskFragments(in: view) {
            XCTAssertGreaterThan(
                fragment.textIndent, MarkdownLayoutFragment.Metrics.checkboxGutter,
                "a task item must reserve room for its box")
        }
    }

    func testNoDrawnBoxOverlapsItsItemsText() throws {
        // The defect, stated directly: with the box anchored to `point` alone,
        // the first item of this very list painted over the "S" of "Ship".
        let view = try laidOut(Self.list)
        let fragments = try taskFragments(in: view)
        XCTAssertEqual(fragments.count, 2)

        for fragment in fragments {
            let x = MarkdownLayoutFragment.checkboxX(
                textIndent: fragment.textIndent,
                indentCarriedByFragment: fragment.indentCarriedByFragment,
                gutter: MarkdownLayoutFragment.Metrics.checkboxGutter,
                inset: MarkdownLayoutFragment.Metrics.checkboxInset)
            let boxStart = fragment.indentCarriedByFragment + x
            let boxEnd = boxStart + MarkdownLayoutFragment.Metrics.checkboxSide

            XCTAssertLessThanOrEqual(
                boxEnd, fragment.textIndent,
                "carried \(fragment.indentCarriedByFragment): the box overlaps the text")
            XCTAssertGreaterThanOrEqual(
                boxStart, fragment.textIndent - MarkdownLayoutFragment.Metrics.checkboxGutter,
                "carried \(fragment.indentCarriedByFragment): the box left its gutter")
        }
    }

    func testEveryItemsBoxLandsAtTheSamePlaceAsItsNeighbours() throws {
        // A list whose boxes do not line up reads as broken even when each one
        // is individually inside its gutter.
        let view = try laidOut(Self.list)
        let positions = try taskFragments(in: view).map { fragment in
            fragment.indentCarriedByFragment
                + MarkdownLayoutFragment.checkboxX(
                    textIndent: fragment.textIndent,
                    indentCarriedByFragment: fragment.indentCarriedByFragment,
                    gutter: MarkdownLayoutFragment.Metrics.checkboxGutter,
                    inset: MarkdownLayoutFragment.Metrics.checkboxInset)
        }

        let spread = (positions.max() ?? 0) - (positions.min() ?? 0)
        XCTAssertEqual(spread, 0, accuracy: 0.001, "the boxes should be in one column")
    }

    // MARK: - The click target

    func testTheGutterIsHitTestedFromTheLinesOwnIndent() throws {
        // The target and the drawn box are two calculations of one gutter, and
        // they drifted apart once already. Both now start from the line's
        // indent, so a click just left of the text hits and a click on the
        // text does not.
        let view = try laidOut("- [ ] task\n")
        let fragment = try taskFragment(in: view)

        let textStart =
            view.textContainerInset.width
            + (view.textContainer?.lineFragmentPadding ?? 0)
            + fragment.textIndent

        XCTAssertTrue(
            view.isInCheckboxGutter(CGPoint(x: textStart - 6, y: 20)),
            "just left of the text is the box")
        XCTAssertFalse(
            view.isInCheckboxGutter(CGPoint(x: textStart + 4, y: 20)),
            "the item's own text is not the box")
        XCTAssertFalse(
            view.isInCheckboxGutter(CGPoint(x: 0, y: 20)),
            "nor is the view's outer edge, left of the gutter")
    }

    func testTogglingThroughTheGutterEditsTheDocument() throws {
        // `[ ]` and `[x]` are the document, so ticking a box is an ordinary
        // edit that undo and save both see.
        let view = try laidOut("- [ ] task\n")
        let marker = try XCTUnwrap(view.parsed.spans.first { $0.kind == .taskMarker })

        XCTAssertTrue(view.toggleTask(at: marker.range.location))
        XCTAssertTrue(view.markdown.contains("[x]"))
    }
}
