//
//  BlockLayoutTests.swift
//  MarkDevKitTests
//
//  How a block is laid out, as opposed to what it is: the panel a fence sits
//  in, the leading between its lines, and the glyphs drawn in place of the
//  syntax live preview collapses.
//

import AppKit
import XCTest

@testable import MarkDevKit

@MainActor
final class BlockLayoutTests: XCTestCase {
    private func makeView(_ markdown: String, mode: EditorMode = .reading) -> MarkdownTextView {
        let view = MarkdownTextView.make()
        view.mode = mode
        view.frame = NSRect(x: 0, y: 0, width: 520, height: 600)
        view.setMarkdown(markdown)
        return view
    }

    private func style(_ view: MarkdownTextView, at offset: Int) -> NSParagraphStyle? {
        view.textStorage?.attribute(.paragraphStyle, at: offset, effectiveRange: nil)
            as? NSParagraphStyle
    }

    /// The paragraph style TextKit will actually use for the line holding
    /// `substring` — the one on the line's *first* character, which is the
    /// only one a line is laid out from.
    private func lineStyle(_ view: MarkdownTextView, containing substring: String)
        -> NSParagraphStyle?
    {
        let text = view.markdown as NSString
        let found = text.range(of: substring)
        guard found.location != NSNotFound else { return nil }
        let line = text.lineRange(for: NSRange(location: found.location, length: 0))
        return style(view, at: line.location)
    }

    private func fragments(_ view: MarkdownTextView) -> [MarkdownLayoutFragment] {
        guard let manager = view.textLayoutManager else { return [] }
        manager.ensureLayout(for: manager.documentRange)
        var found: [MarkdownLayoutFragment] = []
        manager.enumerateTextLayoutFragments(
            from: manager.documentRange.location, options: [.ensuresLayout]
        ) { fragment in
            if let fragment = fragment as? MarkdownLayoutFragment { found.append(fragment) }
            return true
        }
        return found
    }

    // MARK: - The panel

    func testCodeIsSetInAPanelRatherThanTintedCharacterByCharacter() {
        // The panel is the fragment's job, and it reaches the text container's
        // edge. A character background stops where each line's text does, so
        // painting both stacks a ragged second tint on top of the panel.
        let view = makeView("```swift\nlet x = 1\nlet somewhatLonger = 2\n```\n")
        let storage = view.textStorage!
        var tinted = 0
        storage.enumerateAttribute(
            .backgroundColor, in: NSRange(location: 0, length: storage.length)
        ) { value, _, _ in
            if value != nil { tinted += 1 }
        }
        XCTAssertEqual(tinted, 0, "a fenced block must not paint its own character background")
    }

    func testCodeLinesSitTighterThanProseAndInsideThePanel() throws {
        let view = makeView("Prose here.\n\n```swift\nlet x = 1\n```\n")
        let code = try XCTUnwrap(lineStyle(view, containing: "let x = 1"))
        let prose = try XCTUnwrap(lineStyle(view, containing: "Prose here."))

        XCTAssertLessThan(
            code.lineSpacing, prose.lineSpacing,
            "a listing is read as one block; body leading makes a short fence a page long")
        XCTAssertEqual(code.headIndent, MarkdownLayoutFragment.Metrics.panelInset)
        XCTAssertEqual(
            code.tailIndent, -MarkdownLayoutFragment.Metrics.panelInset,
            "a long line has to wrap inside the panel, not against its edge")
    }

    func testAHardWrappedParagraphIsNotDoubleSpaced() throws {
        // `NSParagraphStyle` ends a paragraph at every newline, and Markdown
        // paragraphs are routinely hard-wrapped. Spacing applied per line put
        // a 12pt gap in the middle of one sentence.
        let view = makeView("One sentence broken\nacross two lines.\n\nA second paragraph.\n")
        let first = try XCTUnwrap(lineStyle(view, containing: "One sentence"))
        XCTAssertEqual(
            first.paragraphSpacing, 0,
            "the gap belongs to the end of a block, not to every line break")
    }

    func testACollapsedFenceLineTakesNoHeight() throws {
        // Collapsing a marker shrinks its characters; the line they sat on
        // still carries a full-size newline, which left a blank line of code
        // at the top and bottom of every panel.
        let view = makeView("```swift\nlet x = 1\n```\n")
        let text = view.markdown as NSString
        let fence = text.range(of: "```swift\n")

        for offset in fence.location..<NSMaxRange(fence) {
            let font = view.textStorage?.attribute(.font, at: offset, effectiveRange: nil) as? NSFont
            XCTAssertEqual(
                font?.pointSize, EditorTheme.hiddenMarkerFontSize,
                "the whole fence line collapses, its newline included (offset \(offset))")
        }
    }

    func testARevealedFenceLineKeepsItsHeight() throws {
        // The bargain live preview makes everywhere: the syntax comes back to
        // be edited, and it has to be legible when it does.
        let source = "```swift\nlet x = 1\n```\n"
        let view = makeView(source, mode: .livePreview)
        view.setSelectedRange((source as NSString).range(of: "let x = 1"))

        let font = view.textStorage?.attribute(
            .font, at: (view.markdown as NSString).range(of: "```swift").location,
            effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.pointSize, EditorTheme.standard.monoFont.pointSize)
    }

    func testAPanelNeverPaintsIntoTheLineAboveIt() throws {
        // TextKit counts `topMargin` inside the frame it hands over, so a
        // panel drawn from `-topMargin` reaches up into the previous line.
        let view = makeView("Intro line.\n\n```swift\nlet x = 1\n```\n")
        let panels = fragments(view).filter { $0.decoration.hasBackground }
        XCTAssertFalse(panels.isEmpty)
        for fragment in panels {
            XCTAssertEqual(
                fragment.decorationRect.minY, 0,
                "a panel paints its own frame, not the one before it")
            XCTAssertEqual(
                fragment.decorationRect.height, fragment.layoutFragmentFrame.height,
                "and all of its own frame, margins included")
        }
    }

    // MARK: - Stand-ins for collapsed syntax

    func testAListItemDrawsABulletWhileItsMarkerIsCollapsed() throws {
        let view = makeView("- first\n- second\n")
        let markers = fragments(view).compactMap(\.listMarker)
        XCTAssertEqual(markers, ["•", "•"], "a hidden `- ` has to leave something behind")
    }

    func testNestedItemsGetTheirOwnBulletAndTheirOwnIndent() throws {
        // Paragraph attributes are read from a line's first character, and a
        // nested item's parsed range starts *after* the spaces that indent it
        // — so every nested list used to come out one level short.
        let view = makeView("- top\n  - nested\n    - deeper\n")
        let markers = fragments(view).compactMap(\.listMarker)
        XCTAssertEqual(markers, ["•", "◦", "▪"])

        let top = try XCTUnwrap(lineStyle(view, containing: "top"))
        let nested = try XCTUnwrap(lineStyle(view, containing: "nested"))
        let deeper = try XCTUnwrap(lineStyle(view, containing: "deeper"))
        XCTAssertGreaterThan(nested.headIndent, top.headIndent)
        XCTAssertGreaterThan(deeper.headIndent, nested.headIndent)
    }

    func testAnOrderedItemKeepsTheNumberTheAuthorWrote() throws {
        let view = makeView("1. first\n2. second\n7. seventh\n")
        XCTAssertEqual(fragments(view).compactMap(\.listMarker), ["1.", "2.", "7."])
    }

    func testARevealedItemDrawsNoBulletBesideItsOwnMarker() throws {
        let source = "- first\n- second\n"
        let view = makeView(source, mode: .livePreview)
        view.setSelectedRange((source as NSString).range(of: "first"))

        let drawn = fragments(view).compactMap(\.listMarker)
        XCTAssertEqual(
            drawn, ["•"],
            "the item under the caret shows its own `- `; a bullet too would be it twice")
    }

    func testATaskItemDrawsItsCheckboxAndNoBullet() throws {
        let view = makeView("- [x] done\n")
        let fragment = try XCTUnwrap(fragments(view).first { $0.decoration.taskChecked != nil })
        XCTAssertNil(fragment.listMarker, "the checkbox is the stand-in for a task's marker")
    }

    func testAMarkerIsDrawnInsideTheSurfaceTheFragmentClaims() throws {
        // The bullet is drawn in the gutter *left* of the text, so a fragment
        // that draws one has to claim that space — otherwise it is clipped at
        // the fragment's leading edge, which is what happened to the checkbox.
        let view = makeView("- item\n")
        let fragment = try XCTUnwrap(fragments(view).first { $0.listMarker != nil })
        let leading = MarkdownLayoutFragment.checkboxX(
            textIndent: fragment.textIndent,
            indentCarriedByFragment: fragment.indentCarriedByFragment,
            gutter: MarkdownLayoutFragment.Metrics.listMarkerGutter,
            inset: 0)
        XCTAssertLessThanOrEqual(
            fragment.renderingSurfaceBounds.minX, leading,
            "the painted surface has to reach the gutter the marker is drawn in")
    }

    func testACodeFenceIsLabelledWithItsLanguageOnlyWhileCollapsed() throws {
        let source = "```swift\nlet x = 1\n```\n"
        let collapsed = makeView(source)
        XCTAssertEqual(
            fragments(collapsed).compactMap(\.blockLabel), ["SWIFT"],
            "the label stands in for the collapsed ```` ```swift ````")

        let revealed = makeView(source, mode: .livePreview)
        revealed.setSelectedRange((source as NSString).range(of: "let x = 1"))
        XCTAssertTrue(
            fragments(revealed).compactMap(\.blockLabel).isEmpty,
            "with the fence on screen, a label beside it is the same fact twice")
    }

    func testAnAlertIsLabelledWithItsFlavour() throws {
        let view = makeView("> [!WARNING]\n> mind the gap\n")
        XCTAssertEqual(fragments(view).compactMap(\.blockLabel), ["WARNING"])
    }

    func testAnUnlabelledFenceReservesNoLabelStrip() throws {
        // The strip is bought by the label. A block without one should not pay
        // for space nothing is drawn in.
        let plain = makeView("```\nx\n```\n")
        let labelled = makeView("```swift\nlet x = 1\n```\n")

        let plainTop = try XCTUnwrap(fragments(plain).first { $0.decoration.hasBackground }).topMargin
        let labelledTop = try XCTUnwrap(
            fragments(labelled).first { $0.blockLabel != nil }
        ).topMargin
        XCTAssertGreaterThan(labelledTop, plainTop)
    }
}
