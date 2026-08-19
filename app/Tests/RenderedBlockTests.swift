//
//  RenderedBlockTests.swift
//  MarkDevKitTests
//
//  Blocks that draw content in place of their source: diagrams, formulas, and
//  standalone images.
//
//  Three things have to hold at once, and each of them shipped broken:
//
//  1. **The content is drawn once.** TextKit lays out one fragment per line, so
//     a five-line mermaid fence is five fragments. Each one drawing the whole
//     block's diagram reserved five diagrams' worth of height and stacked five
//     copies down the page — a 300pt picture in 1500pt of column.
//  2. **The source and the rendering are never both on screen.** In source
//     mode, and with the caret inside the block, the diagram was still drawn
//     *under every line of its own source* — so the code was technically
//     visible and completely unusable. That is the bug this file was opened for.
//  3. **The source comes back.** It is the only way to edit a diagram, so
//     revealing the block has to restore the text and remove the picture, and
//     leaving it has to put the picture back.
//

import AppKit
import XCTest

@testable import MarkDevKit

@MainActor
final class RenderedBlockTests: XCTestCase {

    // MARK: - Harness

    private func view(
        _ markdown: String, mode: EditorMode = .reading, width: CGFloat = 520,
        height: CGFloat = 700
    ) -> MarkdownTextView {
        let view = MarkdownTextView.make()
        view.mode = mode
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        view.setMarkdown(markdown)
        view.textLayoutManager?.ensureLayout(for: view.textLayoutManager!.documentRange)
        return view
    }

    /// Every custom fragment of `view`, in document order.
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

    /// The character range a fragment covers.
    private func range(of fragment: MarkdownLayoutFragment, in view: MarkdownTextView) -> NSRange {
        guard let manager = view.textLayoutManager,
            let element = fragment.rangeInElement as NSTextRange?
        else { return NSRange(location: NSNotFound, length: 0) }
        let start = manager.offset(from: manager.documentRange.location, to: element.location)
        let end = manager.offset(from: manager.documentRange.location, to: element.endLocation)
        return NSRange(location: start, length: max(0, end - start))
    }

    private func mermaid(bodyLines: Int) -> String {
        let body = (0..<bodyLines).map { "  N\($0) --> N\($0 + 1);" }.joined(separator: "\n")
        return "```mermaid\ngraph TD;\n\(body)\n```\n\nafter\n"
    }

    // MARK: - Drawn once

    func testADiagramIsDrawnOnceHoweverManyLinesItsSourceHas() {
        for lines in 1...6 {
            let view = view(mermaid(bodyLines: lines))
            let drawing = fragments(view).filter { $0.decoration.rendered != nil }
            XCTAssertEqual(
                drawing.count, 1,
                "a \(lines + 2)-line fence drew \(drawing.count) diagrams; TextKit makes one "
                    + "fragment per line and only the block's first piece may draw its content")
        }
    }

    func testAFormulaIsDrawnOnce() {
        let view = view("$$\n\\frac{a}{b}\n\\cdot c\n$$\n\nafter\n")
        XCTAssertEqual(fragments(view).filter { $0.decoration.rendered != nil }.count, 1)
    }

    func testARenderedBlockTakesTheHeightOfItsContentAndNoMore() throws {
        // The failure this replaces was arithmetic, not cosmetic: every line of
        // the fence grew its own frame by the diagram's full height, so the
        // paragraph after a five-line diagram started 1500pt down the page.
        for lines in 1...6 {
            let source = mermaid(bodyLines: lines)
            let view = view(source)
            let all = fragments(view)
            let entry = try XCTUnwrap(
                view.renderedBlocks.entries.first, "the fence should render as a diagram")
            let content = try XCTUnwrap(
                all.first(where: { $0.decoration.rendered != nil })?.renderedContent,
                "the diagram should have rendered")

            let occupied = all
                .filter { NSIntersectionRange(range(of: $0, in: view), entry.range).length > 0 }
                .reduce(0) { $0 + $1.layoutFragmentFrame.height }

            XCTAssertGreaterThanOrEqual(occupied, content.size.height)
            XCTAssertLessThanOrEqual(
                occupied, content.size.height + MarkdownLayoutFragment.Metrics.blockPadding * 2 + 4,
                "\(lines) body lines: the block occupies \(occupied)pt for a \(content.size.height)pt "
                    + "diagram — the source's own lines are collapsed and must cost nothing")
        }
    }

    func testAFailedDiagramExplainsItselfExactlyOnce() {
        let view = view("```mermaid\nthis is not any kind of diagram\n```\n\nafter\n")
        let explained = fragments(view).filter { $0.renderFailure != nil }
        XCTAssertEqual(
            explained.count, 1,
            "a fence that cannot render should say so once, not once per line")
        XCTAssertFalse(explained.first?.renderFailure?.reason.isEmpty ?? true)
    }

    // MARK: - Source and rendering are never both on screen

    func testSourceModeShowsEveryLineOfADiagramAsCode() throws {
        let source = mermaid(bodyLines: 3)
        let view = view(source, mode: .source)

        XCTAssertTrue(
            view.hiddenRanges.ranges.isEmpty, "source mode collapses nothing at all")
        XCTAssertTrue(
            fragments(view).allSatisfy { $0.decoration.rendered == nil },
            "with the source on screen the diagram must not be drawn over it")

        // Every line of the fence is still a line: full height, in a panel.
        let storage = try XCTUnwrap(view.textStorage)
        let entry = try XCTUnwrap(view.renderedBlocks.entries.first)
        var panelled = 0
        for fragment in fragments(view)
        where NSIntersectionRange(range(of: fragment, in: view), entry.range).length > 0 {
            guard case .code(_, let language) = fragment.decoration else {
                return XCTFail("expected a code panel, got \(fragment.decoration)")
            }
            XCTAssertEqual(language, "mermaid")
            XCTAssertGreaterThan(
                fragment.layoutFragmentFrame.height, 8,
                "a visible line of source needs its height")
            panelled += 1
        }
        XCTAssertEqual(panelled, 6, "```mermaid, graph TD;, three body lines, and ```")

        // And it is set as code, which is what makes it readable as one.
        let body = (source as NSString).range(of: "graph TD;")
        let font = storage.attribute(.font, at: body.location, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font, EditorTheme.standard.monoFont)
    }

    func testSourceModeShowsAFormulaAndAnImageAsWritten() {
        let math = view("$$\nE = mc^2\n$$\n", mode: .source)
        XCTAssertTrue(fragments(math).allSatisfy { $0.decoration.rendered == nil })
        XCTAssertTrue(math.hiddenRanges.ranges.isEmpty)

        let image = view("![A plan](plan.png)\n", mode: .source)
        XCTAssertTrue(
            fragments(image).allSatisfy { $0.decoration.rendered == nil },
            "an image drawn under its own `![…](…)` shows the reader the same thing twice")
    }

    // MARK: - The source comes back, and the picture returns

    func testTheCaretRevealsADiagramsSourceAndLeavingItRestoresTheDiagram() throws {
        let source = mermaid(bodyLines: 2)
        let view = view(source, mode: .livePreview)
        let inside = (source as NSString).range(of: "graph TD;").location
        let outside = (source as NSString).range(of: "after").location

        view.setSelectedRange(NSRange(location: outside, length: 0))
        XCTAssertEqual(
            fragments(view).filter { $0.decoration.rendered != nil }.count, 1,
            "with the caret elsewhere the diagram is drawn")

        view.setSelectedRange(NSRange(location: inside, length: 0))
        let revealed = fragments(view)
        XCTAssertTrue(
            revealed.allSatisfy { $0.decoration.rendered == nil },
            "the caret is in the block, so its source is what must be on screen")
        XCTAssertFalse(
            view.hiddenRanges.covers(try XCTUnwrap(view.renderedBlocks.entries.first).range),
            "the source cannot be collapsed while it is being edited")

        view.setSelectedRange(NSRange(location: outside, length: 0))
        XCTAssertEqual(
            fragments(view).filter { $0.decoration.rendered != nil }.count, 1,
            "leaving the block must put the diagram back")
    }

    func testAnImageParagraphCollapsesAndComesBack() throws {
        let source = "![A plan](plan.png)\n\nafter\n"
        let view = view(source, mode: .livePreview)
        let outside = (source as NSString).range(of: "after").location

        view.setSelectedRange(NSRange(location: outside, length: 0))
        let entry = try XCTUnwrap(view.renderedBlocks.entries.first)
        XCTAssertTrue(
            view.hiddenRanges.covers(entry.range),
            "the `![…](…)` is replaced by the picture, so it collapses whole")
        XCTAssertEqual(fragments(view).filter { $0.decoration.rendered != nil }.count, 1)

        view.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertFalse(view.hiddenRanges.covers(entry.range))
        XCTAssertTrue(fragments(view).allSatisfy { $0.decoration.rendered == nil })
    }

    func testEditingADiagramsSourceStillWorksThroughTheOrdinaryInputPath() {
        let source = mermaid(bodyLines: 1)
        let view = view(source, mode: .livePreview)
        let inside = (source as NSString).range(of: "graph TD;")
        view.setSelectedRange(NSRange(location: NSMaxRange(inside), length: 0))
        view.insertText("\n  A --> B;", replacementRange: view.selectedRange())

        XCTAssertTrue(
            view.markdown.contains("graph TD;\n  A --> B;"),
            "typing into a revealed diagram edits the document, not a copy of it: "
                + view.markdown.debugDescription)
        XCTAssertTrue(
            fragments(view).allSatisfy { $0.decoration.rendered == nil },
            "the caret is still in the block, so the source stays on screen")
    }

    func testClickingACollapsedDiagramLandsInsideIt() throws {
        // The strip and the picture are the only thing on screen for a
        // collapsed block, so a click on them is the *only* way back to the
        // source. If it resolved to the paragraph below, a diagram would be
        // uneditable by pointer.
        let source = mermaid(bodyLines: 3)
        let view = view(source, mode: .livePreview)
        view.setSelectedRange(NSRange(location: (source as NSString).range(of: "after").location, length: 0))

        let drawing = try XCTUnwrap(fragments(view).first { $0.decoration.rendered != nil })
        let entry = try XCTUnwrap(view.renderedBlocks.entries.first)
        let frame = drawing.layoutFragmentFrame
        let point = CGPoint(
            x: frame.midX + view.textContainerOrigin.x,
            y: frame.midY + view.textContainerOrigin.y)

        let offset = view.characterIndexForInsertion(at: point)
        XCTAssertTrue(
            NSLocationInRange(offset, entry.range) || offset == NSMaxRange(entry.range),
            "a click at \(point) in the diagram resolved to \(offset), outside the block "
                + "\(entry.range) it was drawn for")
    }

    // MARK: - Preview, which is the same engine

    func testTheReadOnlyPreviewAlsoDrawsOneDiagram() {
        let controller = MarkdownPreviewController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 520, height: 700)
        controller.show(mermaid(bodyLines: 4), directory: nil)

        guard let text = controller.view.documentView as? MarkdownTextView else {
            return XCTFail("the preview should host a MarkdownTextView")
        }
        XCTAssertEqual(
            fragments(text).filter { $0.decoration.rendered != nil }.count, 1,
            "Quick Look and the hold-Space peek go through this same path")
    }

    // MARK: - The index itself

    func testEntriesAreAscendingAndDisjoint() {
        let source = """
            ![one](a.png)

            ```mermaid
            graph TD;
            A-->B;
            ```

            $$
            x^2
            $$

            ![two](b.png)

            ```swift
            let x = 1
            ```
            """
        let parsed = ParsedDocument.parse(source)
        let rendered = RenderedBlocks(document: parsed, text: source as NSString)
        XCTAssertEqual(rendered.entries.count, 4, "two images, a diagram, and a formula")

        for (previous, next) in zip(rendered.entries, rendered.entries.dropFirst()) {
            XCTAssertLessThanOrEqual(
                NSMaxRange(previous.range), next.range.location,
                "entries must be ascending and disjoint for the binary search to hold")
        }
    }

    func testEntryLookupAgreesWithAFullScan() {
        // The binary search has to answer exactly what a scan would, including
        // for a fragment that begins before the block it holds — a fence
        // indented into a list item does.
        let source = """
            - item

              ```mermaid
              graph TD;
              A-->B;
              ```

            text

            $$
            E = mc^2
            $$

            ![p](p.png)

            trailing
            """
        let parsed = ParsedDocument.parse(source)
        let text = source as NSString
        let rendered = RenderedBlocks(document: parsed, text: text)
        XCTAssertFalse(rendered.entries.isEmpty)

        for location in 0...text.length {
            for length in [0, 1, 5] where location + length <= text.length {
                let probe = NSRange(location: location, length: length)
                let expected = rendered.entries.first {
                    NSIntersectionRange($0.range, probe).length > 0
                        || NSLocationInRange(probe.location, $0.range)
                }
                XCTAssertEqual(
                    rendered.entry(overlapping: probe)?.range, expected?.range,
                    "lookup disagreed with a scan at \(probe)")
            }
        }
    }

    func testAnEmptyRenderableBlockKeepsItsSource() {
        // Nothing can be drawn in its place, so hiding it would be a fence that
        // simply vanished. Both of these produce no entry at all, and the
        // collapse follows the entries.
        for source in ["```mermaid\n```\n", "$$\n$$\n", "```mermaid\n\n\n```\n"] {
            let parsed = ParsedDocument.parse(source)
            let rendered = RenderedBlocks(document: parsed, text: source as NSString)
            XCTAssertTrue(
                rendered.entries.isEmpty, "\(source.debugDescription) has nothing to render")

            let view = view(source)
            XCTAssertTrue(
                fragments(view).allSatisfy { $0.decoration.rendered == nil },
                "\(source.debugDescription) drew content it does not have")
            for fragment in fragments(view) where fragment.decoration != .none {
                guard case .code = fragment.decoration else {
                    return XCTFail("expected an empty fence to draw as code")
                }
            }
        }
    }

    // MARK: - The HTML spelling of a picture

    func testAStandaloneImgTagIsAPicture() throws {
        // Markdown cannot say how wide a picture should be, so a note that
        // needs to say it writes the tag. Rendered as its own source, that is
        // the author's markup shown to a reader who wanted the mark.
        let source = """
            intro

            <img src="assets/mark.svg" alt="The mark" width="72">

            after
            """
        let parsed = ParsedDocument.parse(source)
        let rendered = RenderedBlocks(document: parsed, text: source as NSString)

        let entry = try XCTUnwrap(rendered.entries.first, "the tag should render as a picture")
        XCTAssertEqual(rendered.entries.count, 1)
        XCTAssertEqual(entry.content.source, "assets/mark.svg")
        XCTAssertEqual(entry.content.width, 72)
        guard case .image(let alt) = entry.content.kind else {
            return XCTFail("expected an image")
        }
        XCTAssertEqual(alt, "The mark")
        XCTAssertEqual(
            (source as NSString).substring(with: entry.range)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            #"<img src="assets/mark.svg" alt="The mark" width="72">"#,
            "the range that collapses has to be the tag and nothing else")
    }

    func testAnImgTagCollapsesAndComesBackLikeAnyOtherPicture() throws {
        let source = "<img src=\"mark.svg\" alt=\"m\">\n\nafter\n"
        let view = view(source, mode: .livePreview)
        let outside = (source as NSString).range(of: "after").location

        view.setSelectedRange(NSRange(location: outside, length: 0))
        let entry = try XCTUnwrap(view.renderedBlocks.entries.first)
        XCTAssertTrue(
            view.hiddenRanges.covers(entry.range),
            "the tag is replaced by the picture, so it collapses whole")
        XCTAssertEqual(fragments(view).filter { $0.decoration.rendered != nil }.count, 1)

        view.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertFalse(
            view.hiddenRanges.covers(entry.range),
            "the markup has to come back to be edited")
        XCTAssertTrue(fragments(view).allSatisfy { $0.decoration.rendered == nil })
    }

    func testAnImgTagUnderABulletIsAPictureToo() throws {
        // Under a bullet the same tag is inline HTML inside a paragraph rather
        // than a block of its own, and it is the same picture either way.
        let source = "- <img src=\"mark.svg\">\n"
        let parsed = ParsedDocument.parse(source)
        let rendered = RenderedBlocks(document: parsed, text: source as NSString)
        XCTAssertEqual(try XCTUnwrap(rendered.entries.first).content.source, "mark.svg")
    }

    func testHTMLThatIsNotOnePictureKeepsItsSource() {
        // Everything here is markup the editor cannot draw. Rendering any of
        // it as a picture would hide text the reader wrote.
        for markup in [
            "<div>hello</div>",
            #"<img src="a.svg"><img src="b.svg">"#,
            #"see <img src="a.svg"> here"#,
            "<img>",
            #"<img alt="no source">"#,
            "<!-- <img src=\"a.svg\"> -->",
        ] {
            let source = "before\n\n\(markup)\n\nafter\n"
            let parsed = ParsedDocument.parse(source)
            let rendered = RenderedBlocks(document: parsed, text: source as NSString)
            XCTAssertTrue(
                rendered.entries.isEmpty,
                "\(markup.debugDescription) is markup, not a picture")
        }
    }

    func testBothSpellingsOfAPictureCanShareADocument() {
        let source = """
            ![a](a.png)

            <img src="b.svg" width="120">

            ```mermaid
            graph TD;
            A-->B;
            ```
            """
        let parsed = ParsedDocument.parse(source)
        let rendered = RenderedBlocks(document: parsed, text: source as NSString)
        XCTAssertEqual(rendered.entries.count, 3)
        XCTAssertEqual(rendered.entries.map(\.content.width), [nil, 120, nil])

        for (previous, next) in zip(rendered.entries, rendered.entries.dropFirst()) {
            XCTAssertLessThanOrEqual(
                NSMaxRange(previous.range), next.range.location,
                "entries must stay ascending and disjoint")
        }
    }

    func testNoTextMeansNoRenderedBlocks() {
        let parsed = ParsedDocument.parse("```mermaid\ngraph TD;\nA-->B;\n```\n")
        XCTAssertTrue(RenderedBlocks(document: parsed, text: nil).entries.isEmpty)
        XCTAssertTrue(RenderedBlocks(document: .empty, text: "" as NSString).entries.isEmpty)
        XCTAssertTrue(RenderedBlocks.none.entries.isEmpty)
        XCTAssertNil(RenderedBlocks.none.entry(overlapping: NSRange(location: 0, length: 1)))
    }

    // MARK: - Stress

    /// The three invariants, checked against whatever state a view is in.
    ///
    /// Returns a description of the first violation, so a stress loop can name
    /// the step that broke it rather than merely failing somewhere.
    private func violation(in view: MarkdownTextView) -> String? {
        let hidden = view.hiddenRanges
        let rendered = view.renderedBlocks
        var drawn: [Int: Int] = [:]

        for fragment in fragments(view) {
            let range = range(of: fragment, in: view)
            guard let content = fragment.decoration.rendered else { continue }
            guard let entry = rendered.entry(overlapping: range) else {
                return "a fragment at \(range) draws content belonging to no block"
            }
            if content != entry.content {
                return "the fragment at \(range) draws another block's content"
            }
            if !hidden.covers(entry.range) {
                return "content drawn for \(entry.range) while its source is visible"
            }
            drawn[entry.block, default: 0] += 1
        }
        if let (block, count) = drawn.first(where: { $0.value != 1 }) {
            return "block \(block) drew its content \(count) times"
        }
        // A rendered block whose source has gone must have something drawn in
        // its place: a picture, or an explanation of why there is none.
        for entry in rendered.entries where hidden.covers(entry.range) {
            let pieces = fragments(view).filter {
                NSIntersectionRange(range(of: $0, in: view), entry.range).length > 0
            }
            guard pieces.contains(where: {
                $0.renderedContent != nil || $0.renderFailure != nil
            }) else {
                return "\(entry.range) is collapsed with nothing drawn in its place"
            }
        }
        return nil
    }

    func testEditingInAndAroundDiagramsHoldsTheInvariants() {
        // Splices that repeatedly break and re-form fences, so a block is a
        // diagram, then a code block, then a paragraph, then a diagram again —
        // which is where the collapse and the drawing get a chance to disagree.
        let atoms = [
            "```mermaid\ngraph TD;\nA-->B;\n```\n", "```mermaid\n", "```\n", "graph LR;\n",
            "$$\nx^2\n$$\n", "$$\n", "![p](p.png)\n", "text\n", "\n", "- item\n",
            "> quote\n", "```swift\nlet x = 1\n```\n", "C-->D;\n", "!",
        ]

        for seed in (300...340) as ClosedRange<UInt64> {
            var rng = SeededGenerator(seed: seed)
            let start = (0..<8).map { _ in atoms.randomElement(using: &rng)! }.joined()
            let view = view(start, mode: .livePreview)

            for step in 0..<40 {
                let length = (view.markdown as NSString).length
                let from = length == 0 ? 0 : Int.random(in: 0...length, using: &rng)
                let run = length == 0 ? 0 : Int.random(in: 0...min(12, length - from), using: &rng)
                let target = (view.markdown as NSString).rangeOfComposedCharacterSequences(
                    for: NSRange(location: from, length: run))
                view.setSelectedRange(target)
                view.insertText(atoms.randomElement(using: &rng)!, replacementRange: view.selectedRange())

                // And move the caret somewhere else, since reveal follows it.
                let now = (view.markdown as NSString).length
                view.setSelectedRange(
                    NSRange(location: now == 0 ? 0 : Int.random(in: 0...now, using: &rng), length: 0))

                if let problem = violation(in: view) {
                    return XCTFail("seed \(seed) step \(step): \(problem)")
                }
            }
        }
    }

    func testTheCaretWalksThroughEveryOffsetOfADiagramDocument() {
        let source = """
            ![p](p.png)

            ```mermaid
            graph TD;
            A-->B;
            ```

            $$
            E = mc^2
            $$

            ```mermaid
            nonsense that cannot render
            ```

            tail
            """
        let view = view(source, mode: .livePreview)
        let length = (source as NSString).length

        for offset in 0...length {
            view.setSelectedRange(NSRange(location: offset, length: 0))
            if let problem = violation(in: view) {
                return XCTFail("caret \(offset): \(problem)")
            }
            XCTAssertEqual(view.markdown, source, "caret \(offset) changed the document")
        }
    }

    func testEveryWidthAndModeHoldsTheInvariants() {
        let source = "```mermaid\ngraph TD;\nA-->B;\nB-->C;\n```\n\n![p](p.png)\n\n$$\nx^2\n$$\n"
        for width in [140.0, 260.0, 520.0, 1400.0] as [CGFloat] {
            for mode in EditorMode.allCases {
                let view = view(source, mode: mode, width: width)
                if let problem = violation(in: view) {
                    return XCTFail("width \(width) mode \(mode): \(problem)")
                }
            }
        }
    }

    func testCollapsedRangesFollowTheRevealSet() {
        let source = "```mermaid\ngraph TD;\nA-->B;\n```\n"
        let parsed = ParsedDocument.parse(source)
        let rendered = RenderedBlocks(document: parsed, text: source as NSString)
        let entry = rendered.entries.first

        XCTAssertEqual(rendered.collapsedRanges(revealed: []).count, 1)
        XCTAssertTrue(
            rendered.collapsedRanges(revealed: [entry?.block ?? -1]).isEmpty,
            "a revealed block shows its source")
    }
}
