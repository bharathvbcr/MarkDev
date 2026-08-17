//
//  BlockDecorationTests.swift
//  MarkDevKitTests
//

import XCTest

@testable import MarkDevKit

final class BlockDecorationTests: XCTestCase {
    private func decoration(_ source: String, at range: NSRange) -> BlockDecoration {
        BlockDecoration.decoration(for: range, in: ParsedDocument.parse(source))
    }

    private func range(of substring: String, in source: String) -> NSRange {
        (source as NSString).range(of: substring)
    }

    // MARK: - Kinds

    func testPlainParagraphsGetNoDecoration() {
        let source = "Just a sentence."
        XCTAssertEqual(decoration(source, at: range(of: "Just", in: source)), .none)
    }

    func testFencedCodeGetsCodeDecorationWithItsLanguage() {
        let source = "```swift\nlet x = 1\n```"
        guard case .code(_, let language) = decoration(
            source, at: range(of: "let x = 1", in: source))
        else { return XCTFail("expected code decoration") }
        XCTAssertEqual(language, "swift")
    }

    func testCalloutsCarryTheirKind() {
        let source = "> [!WARNING]\n> careful"
        guard case .callout(let kind, _) = decoration(
            source, at: range(of: "careful", in: source))
        else { return XCTFail("expected callout decoration") }
        XCTAssertEqual(kind, .warning)
    }

    func testPlainBlockquotesAreQuotes() {
        let source = "> just a quote"
        guard case .quote = decoration(source, at: range(of: "just a quote", in: source)) else {
            return XCTFail("expected quote decoration")
        }
    }

    func testThematicBreaksAreRules() {
        let source = "before\n\n---\n\nafter"
        XCTAssertEqual(decoration(source, at: range(of: "---", in: source)), .rule)
    }

    func testInnermostBlockWins() {
        // A fence inside a callout should draw as code, not as the callout it
        // happens to sit in.
        let source = "> [!NOTE]\n> ```swift\n> let x = 1\n> ```"
        let decoration = decoration(source, at: range(of: "let x = 1", in: source))
        guard case .code = decoration else {
            return XCTFail("expected the inner code block to win, got \(decoration)")
        }
    }

    // MARK: - Edges

    func testASingleLineBlockIsTheOnlyEdge() {
        XCTAssertEqual(
            BlockDecoration.edge(
                of: NSRange(location: 0, length: 10), within: NSRange(location: 0, length: 10)),
            .only)
    }

    func testMultiLineBlocksReportFirstMiddleAndLast() {
        let block = NSRange(location: 0, length: 30)
        XCTAssertEqual(
            BlockDecoration.edge(of: NSRange(location: 0, length: 10), within: block), .first)
        XCTAssertEqual(
            BlockDecoration.edge(of: NSRange(location: 10, length: 10), within: block), .middle)
        XCTAssertEqual(
            BlockDecoration.edge(of: NSRange(location: 20, length: 10), within: block), .last)
    }

    func testOnlyTheOuterEdgesRoundTheirCorners() {
        // Middle fragments must draw square, or consecutive lines of a code
        // block show a seam where the rounded corners meet.
        XCTAssertTrue(BlockEdge.only.roundsTop && BlockEdge.only.roundsBottom)
        XCTAssertTrue(BlockEdge.first.roundsTop)
        XCTAssertFalse(BlockEdge.first.roundsBottom)
        XCTAssertFalse(BlockEdge.middle.roundsTop || BlockEdge.middle.roundsBottom)
        XCTAssertTrue(BlockEdge.last.roundsBottom)
        XCTAssertFalse(BlockEdge.last.roundsTop)
    }

    func testRulesDrawNoBackground() {
        XCTAssertFalse(BlockDecoration.rule.hasBackground)
        XCTAssertFalse(BlockDecoration.none.hasBackground)
        XCTAssertTrue(BlockDecoration.code(edge: .only, language: nil).hasBackground)
    }

    // MARK: - Rendered blocks

    /// The decoration for `range` with every renderable block collapsed —
    /// reading mode, where no caret reveals anything.
    private func decoration(_ source: String, at range: NSRange, withText: Bool) -> BlockDecoration {
        let parsed = ParsedDocument.parse(source)
        let rendered = RenderedBlocks(
            document: parsed, text: withText ? (source as NSString) : nil)
        let hidden = HiddenRanges(
            document: parsed, selection: NSRange(location: 0, length: 0), mode: .reading,
            rendered: rendered)
        return BlockDecoration.decoration(
            for: range, in: parsed, rendered: rendered, hidden: hidden)
    }

    /// The decoration for a block's *first* line, which is the piece that draws
    /// the content standing in for the whole block.
    private func headDecoration(_ source: String, withText: Bool = true) -> BlockDecoration {
        let firstLine = (source as NSString).lineRange(for: NSRange(location: 0, length: 0))
        return decoration(source, at: firstLine, withText: withText)
    }

    func testAMathBlockBecomesRenderedLatex() {
        let source = "$$\nE = mc^2\n$$"
        let decoration = headDecoration(source)
        guard case .rendered(let block) = decoration else {
            return XCTFail("expected rendered math, got \(decoration)")
        }
        XCTAssertEqual(block.kind, .math)
        XCTAssertEqual(block.source, "E = mc^2", "the `$$` delimiters are not part of the formula")
    }

    func testAMermaidFenceBecomesARenderedDiagram() {
        let source = "```mermaid\ngraph TD;\n  A --> B;\n```"
        let decoration = headDecoration(source)
        guard case .rendered(let block) = decoration else {
            return XCTFail("expected a rendered diagram, got \(decoration)")
        }
        XCTAssertEqual(block.kind, .diagram)
        XCTAssertTrue(block.source.hasPrefix("graph TD"), "fence lines are not part of the source")
        XCTAssertFalse(block.source.contains("```"))
    }

    func testOnlyTheFirstLineOfARenderedBlockDrawsIt() {
        // TextKit lays out one fragment per line. Every line claiming the
        // block's content stacked one diagram per line down the page.
        let source = "```mermaid\ngraph TD;\n  A --> B;\n```"
        for line in ["graph TD;", "  A --> B;"] {
            let decoration = decoration(source, at: range(of: line, in: source), withText: true)
            XCTAssertNil(
                decoration.rendered,
                "\(line.debugDescription) must not draw a second copy of the diagram")
        }
    }

    func testAVisibleSourceIsDrawnAsCodeRatherThanRendered() {
        // Source mode, or the caret inside the block: the text is on screen, so
        // drawing the diagram as well would bury the code under it.
        let source = "```mermaid\ngraph TD;\n  A --> B;\n```"
        let parsed = ParsedDocument.parse(source)
        let rendered = RenderedBlocks(document: parsed, text: source as NSString)
        let hidden = HiddenRanges(
            document: parsed, selection: NSRange(location: 0, length: 0), mode: .source,
            rendered: rendered)

        XCTAssertTrue(hidden.ranges.isEmpty, "source mode collapses nothing")
        for line in ["```mermaid", "graph TD;", "  A --> B;"] {
            let decoration = BlockDecoration.decoration(
                for: range(of: line, in: source), in: parsed, rendered: rendered, hidden: hidden)
            guard case .code(_, let language) = decoration else {
                return XCTFail("expected the source drawn as code, got \(decoration)")
            }
            XCTAssertEqual(language, "mermaid", "the panel is labelled with the fence's language")
        }
    }

    func testAVisibleMathBlockIsDrawnAsCode() {
        let source = "$$\nE = mc^2\n$$"
        let parsed = ParsedDocument.parse(source)
        let rendered = RenderedBlocks(document: parsed, text: source as NSString)
        let decoration = BlockDecoration.decoration(
            for: range(of: "E = mc^2", in: source), in: parsed, rendered: rendered,
            hidden: .none)
        guard case .code = decoration else {
            return XCTFail("expected a code panel around the visible source, got \(decoration)")
        }
    }

    func testWithoutTextMathFallsBackToCode() {
        // The source cannot be read without the document text, and drawing it
        // as code beats drawing nothing.
        let source = "$$\nE = mc^2\n$$"
        let decoration = decoration(source, at: range(of: "E = mc^2", in: source), withText: false)
        guard case .code = decoration else {
            return XCTFail("expected a code fallback, got \(decoration)")
        }
    }

    func testAStandaloneImageBecomesARenderedImage() {
        let source = "![A diagram](pictures/plan.png)"
        let decoration = headDecoration(source)
        guard case .rendered(let block) = decoration else {
            return XCTFail("expected a rendered image, got \(decoration)")
        }
        XCTAssertEqual(block.source, "pictures/plan.png")
        guard case .image(let alt) = block.kind else { return XCTFail("expected image kind") }
        XCTAssertEqual(alt, "A diagram", "alt text is shown when the file cannot be loaded")
    }

    func testAVisibleImageParagraphIsPlainProse() {
        // It used to draw the picture *and* keep the `![…](…)` on screen above
        // it, which is the same source-and-rendering collision as the fences.
        let source = "![A diagram](pictures/plan.png)"
        let parsed = ParsedDocument.parse(source)
        let decoration = BlockDecoration.decoration(
            for: NSRange(location: 0, length: (source as NSString).length), in: parsed,
            rendered: RenderedBlocks(document: parsed, text: source as NSString), hidden: .none)
        XCTAssertEqual(decoration, .none, "visible image source is prose, not a picture")
    }

    func testAnInlineImageStaysInline() {
        // Swapping an image inside a sentence for a block would break the
        // line it belongs to.
        let source = "See ![icon](i.png) here in a sentence."
        let decoration = decoration(source, at: range(of: "icon", in: source), withText: true)
        XCTAssertNil(decoration.rendered, "an image mid-sentence must not become a block")
    }

    func testAParagraphWithTwoImagesIsNotAPicture() {
        let source = "![one](a.png) ![two](b.png)"
        XCTAssertNil(headDecoration(source).rendered)
    }

    func testRenderedBlocksPaintNoPanel() {
        let math = BlockDecoration.rendered(RenderedBlock(kind: .math, source: "x"))
        XCTAssertFalse(math.hasBackground)
        XCTAssertNotNil(math.rendered)
    }

    func testEmptyDocumentIsHandled() {
        XCTAssertEqual(
            BlockDecoration.decoration(for: NSRange(location: 0, length: 0), in: .empty), .none)
    }
}

@MainActor
final class SyntaxHighlighterTests: XCTestCase {
    func testKnownLanguagesAreSupported() {
        let highlighter = SyntaxHighlighter()
        XCTAssertTrue(highlighter.supports("rust"))
        XCTAssertTrue(highlighter.supports("swift"))
        XCTAssertFalse(highlighter.supports("klingon"))
    }

    func testSwiftCodeIsHighlighted() {
        let highlighter = SyntaxHighlighter()
        let code = "let editor = MarkdownTextView.make()"
        let spans = highlighter.spans(language: "swift", code: code)

        XCTAssertFalse(spans.isEmpty)
        let keyword = spans.first { $0.kind == .keyword }
        XCTAssertNotNil(keyword, "`let` should be a keyword")
        if let keyword {
            XCTAssertEqual((code as NSString).substring(with: keyword.range), "let")
        }
    }

    func testUnknownLanguagesAndEmptyInputYieldNothing() {
        let highlighter = SyntaxHighlighter()
        XCTAssertTrue(highlighter.spans(language: "klingon", code: "fn main() {}").isEmpty)
        XCTAssertTrue(highlighter.spans(language: nil, code: "fn main() {}").isEmpty)
        XCTAssertTrue(highlighter.spans(language: "rust", code: "").isEmpty)
    }

    func testSpansStayInsideTheCode() {
        // An out-of-range span would crash NSTextStorage rather than mis-colour.
        let highlighter = SyntaxHighlighter()
        let code = "// 🎉\nfn main() { let x = 1; }"
        let length = (code as NSString).length

        for span in highlighter.spans(language: "rust", code: code) {
            XCTAssertGreaterThan(span.range.length, 0)
            XCTAssertLessThanOrEqual(span.range.location + span.range.length, length)
        }
    }

    func testResultsAreCached() {
        // Highlighting is pure, and it runs on the keystroke path.
        let highlighter = SyntaxHighlighter()
        let code = "fn main() { let x = 1; }"
        let first = highlighter.spans(language: "rust", code: code)
        let second = highlighter.spans(language: "rust", code: code)
        XCTAssertEqual(first, second)
    }
}

@MainActor
final class TaskAndTableTests: XCTestCase {
    private func makeView(_ markdown: String) -> MarkdownTextView {
        let view = MarkdownTextView.make()
        view.frame = NSRect(x: 0, y: 0, width: 520, height: 420)
        view.setMarkdown(markdown)
        return view
    }

    // MARK: - Checkboxes

    func testTogglingATaskEditsTheDocument() {
        // Ticking a box is a document change, not view state: `[ ]` and `[x]`
        // are the text, so undo, save, and the index all see it.
        let view = makeView("- [ ] write tests\n")
        let marker = view.parsed.spans.first { $0.kind == .taskMarker }
        XCTAssertNotNil(marker)

        XCTAssertTrue(view.toggleTask(at: marker!.range.location))
        XCTAssertTrue(view.markdown.contains("[x]"))
        XCTAssertFalse(view.markdown.contains("[ ]"))
    }

    func testTogglingIsReversible() {
        let view = makeView("- [x] done\n")
        let marker = view.parsed.spans.first { $0.kind == .taskMarker }
        view.toggleTask(at: marker!.range.location)
        XCTAssertTrue(view.markdown.contains("[ ]"))

        let again = view.parsed.spans.first { $0.kind == .taskMarker }
        view.toggleTask(at: again!.range.location)
        XCTAssertTrue(view.markdown.contains("[x]"))
    }

    func testTogglingIsUndoable() throws {
        // Undo needs a real responder chain: a detached view has no undo
        // manager, so putting it in a window is what makes this test the
        // thing it claims to be.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled], backing: .buffered, defer: false)
        let view = makeView("- [ ] reversible\n")
        window.contentView = view
        window.makeFirstResponder(view)

        let marker = try XCTUnwrap(view.parsed.spans.first { $0.kind == .taskMarker })
        view.toggleTask(at: marker.range.location)
        XCTAssertTrue(view.markdown.contains("[x]"))

        let undo = try XCTUnwrap(view.undoManager, "an editable text view in a window has undo")
        undo.undo()
        XCTAssertTrue(view.markdown.contains("[ ]"), "toggling must be undoable")
    }

    func testTogglingElsewhereDoesNothing() {
        let view = makeView("Just prose, no tasks here.\n")
        XCTAssertFalse(view.toggleTask(at: 3))
        XCTAssertEqual(view.markdown, "Just prose, no tasks here.\n")
    }

    func testTaskMarkersCollapseSoTheCheckboxStandsAlone() {
        let view = makeView("# T\n\n- [x] done\n")
        // Caret in the heading, so the task's own block is not revealed.
        view.setSelectedRange(NSRange(location: 2, length: 0))

        let range = (view.markdown as NSString).range(of: "[x]")
        let font = view.textStorage?.attribute(.font, at: range.location, effectiveRange: nil)
            as? NSFont
        XCTAssertEqual(
            font?.pointSize, EditorTheme.hiddenMarkerFontSize,
            "the raw `[x]` should collapse behind the drawn checkbox")
    }

    func testTaskItemsReserveAGutterForTheirCheckbox() {
        // Without the indent the checkbox would be drawn over the item's text.
        let view = makeView("- [ ] task\n")
        let range = (view.markdown as NSString).range(of: "task")
        let style = view.textStorage?.attribute(
            .paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertGreaterThan(
            style?.headIndent ?? 0, MarkdownLayoutFragment.Metrics.checkboxGutter,
            "a task item needs room for its checkbox")
    }

    func testClickingTheGutterTogglesTheCheckbox() throws {
        // Exercised through `toggleTask` rather than a synthesised click: a
        // `mouseDown` that misses the gutter falls through to `NSTextView`,
        // which starts a drag-tracking loop and waits for a mouse-up a test
        // never sends — so a failure here would hang rather than fail.
        let view = makeView("- [ ] task\n")
        let marker = try XCTUnwrap(view.parsed.spans.first { $0.kind == .taskMarker })

        XCTAssertTrue(view.toggleTask(at: marker.range.location))
        XCTAssertTrue(view.markdown.contains("[x]"))
    }

    // MARK: - Tables

    private func table() -> String {
        """
        | Language | Grammar |
        |---|---|
        | Rust | yes |
        | A much longer language name | no |
        """
    }

    func testTableRowsResolveHeaderAndBody() {
        let source = table()
        let document = ParsedDocument.parse(source)
        let header = (source as NSString).range(of: "Language")
        let body = (source as NSString).range(of: "Rust")

        guard case .tableRow(let headerIsHeader, _) = BlockDecoration.decoration(
            for: header, in: document)
        else { return XCTFail("expected a table row for the header") }
        XCTAssertTrue(headerIsHeader)

        guard case .tableRow(let bodyIsHeader, _) = BlockDecoration.decoration(
            for: body, in: document)
        else { return XCTFail("expected a table row for the body") }
        XCTAssertFalse(bodyIsHeader)
    }

    func testColumnsAreAlignedByKerningTheSeparators() {
        // The text is never rewritten, so alignment rides on the collapsed
        // `|` separators the document already has.
        let view = makeView(table())
        guard let storage = view.textStorage else { return XCTFail("no storage") }

        var kerned = 0
        storage.enumerateAttribute(
            .kern, in: NSRange(location: 0, length: storage.length)
        ) { value, _, _ in
            if let kern = value as? CGFloat, kern > 0 { kerned += 1 }
        }
        XCTAssertGreaterThan(kerned, 0, "table cells should be padded to their columns")
    }

    func testAShorterCellIsPaddedMoreThanALongerOneInTheSameColumn() throws {
        // The property that makes columns line up: within a column, padding
        // makes up the difference, so the shorter cell gets more of it.
        let view = makeView(table())
        let storage = try XCTUnwrap(view.textStorage)

        // First-column cells, in row order.
        let rows = view.parsed.blocks.filter { $0.kind == .tableRow || $0.kind == .tableHead }
            .sorted { $0.range.location < $1.range.location }
        let firstColumn: [BlockDescriptor] = rows.compactMap { row in
            view.parsed.blocks
                .filter {
                    $0.kind == .tableCell
                        && NSIntersectionRange($0.range, row.range).length > 0
                }
                .min { $0.range.location < $1.range.location }
        }
        XCTAssertGreaterThanOrEqual(firstColumn.count, 3)

        /// Padding applied to a cell, read from its final character.
        func padding(_ cell: BlockDescriptor) -> CGFloat {
            let last = cell.range.location + cell.range.length - 1
            return storage.attribute(.kern, at: last, effectiveRange: nil) as? CGFloat ?? 0
        }

        let text = view.markdown as NSString
        let widest = firstColumn.max { text.substring(with: $0.range).count < text.substring(with: $1.range).count }
        let narrowest = firstColumn.min { text.substring(with: $0.range).count < text.substring(with: $1.range).count }
        let wide = try XCTUnwrap(widest)
        let narrow = try XCTUnwrap(narrowest)

        XCTAssertGreaterThan(
            padding(narrow), padding(wide),
            "the shorter cell needs more padding to reach the same column edge")
    }

    func testATableWithoutBodyRowsIsLeftAlone() {
        XCTAssertNoThrow(makeView("| a |\n|---|\n"))
    }
}
