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

    private func decoration(_ source: String, at range: NSRange, withText: Bool) -> BlockDecoration {
        BlockDecoration.decoration(
            for: range, in: ParsedDocument.parse(source),
            text: withText ? (source as NSString) : nil)
    }

    func testAMathBlockBecomesRenderedLatex() {
        let source = "$$\nE = mc^2\n$$"
        let decoration = decoration(source, at: range(of: "E = mc^2", in: source), withText: true)
        guard case .rendered(let block) = decoration else {
            return XCTFail("expected rendered math, got \(decoration)")
        }
        XCTAssertEqual(block.kind, .math)
        XCTAssertEqual(block.source, "E = mc^2", "the `$$` delimiters are not part of the formula")
    }

    func testAMermaidFenceBecomesARenderedDiagram() {
        let source = "```mermaid\ngraph TD;\n  A --> B;\n```"
        let decoration = decoration(source, at: range(of: "graph TD", in: source), withText: true)
        guard case .rendered(let block) = decoration else {
            return XCTFail("expected a rendered diagram, got \(decoration)")
        }
        XCTAssertEqual(block.kind, .diagram)
        XCTAssertTrue(block.source.hasPrefix("graph TD"), "fence lines are not part of the source")
        XCTAssertFalse(block.source.contains("```"))
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
        let decoration = decoration(source, at: NSRange(location: 2, length: 3), withText: true)
        guard case .rendered(let block) = decoration else {
            return XCTFail("expected a rendered image, got \(decoration)")
        }
        XCTAssertEqual(block.source, "pictures/plan.png")
        guard case .image(let alt) = block.kind else { return XCTFail("expected image kind") }
        XCTAssertEqual(alt, "A diagram", "alt text is shown when the file cannot be loaded")
    }

    func testAnInlineImageStaysInline() {
        // Swapping an image inside a sentence for a block would break the
        // line it belongs to.
        let source = "See ![icon](i.png) here in a sentence."
        let decoration = decoration(source, at: range(of: "icon", in: source), withText: true)
        XCTAssertNil(decoration.rendered, "an image mid-sentence must not become a block")
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

    /// A view showing `markdown` with the caret parked off the table.
    ///
    /// The caret matters: live preview reveals the block holding it, and a
    /// revealed table shows its Markdown instead of its grid. A fixture that
    /// leaves the caret where `setMarkdown` puts it — the end of the document
    /// — is asserting about a table that is deliberately not being drawn.
    private func drawnTableView(_ markdown: String, width: CGFloat = 520)
        -> MarkdownTextView
    {
        let view = MarkdownTextView.make()
        view.frame = NSRect(x: 0, y: 0, width: width, height: 420)
        view.setMarkdown("Intro.\n\n" + markdown)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.textLayoutManager?.ensureLayout(for: view.textLayoutManager!.documentRange)
        return view
    }

    /// The solved rows the fragments actually hold, in document order.
    private func drawnRows(in view: MarkdownTextView) -> [TableRowLayout] {
        var rows: [TableRowLayout] = []
        guard let manager = view.textLayoutManager else { return rows }
        manager.enumerateTextLayoutFragments(from: manager.documentRange.location) { fragment in
            if let row = (fragment as? MarkdownLayoutFragment)?.tableRow { rows.append(row) }
            return true
        }
        return rows
    }

    func testEveryRowIsDrawnAgainstTheSameColumns() {
        // This is what "the columns line up" means once the grid is drawn
        // rather than kerned: one solved geometry, shared by every row. The
        // kerning this replaced made the same promise per cell, and could
        // only keep it by re-measuring the whole table on every pass.
        let rows = drawnRows(in: drawnTableView(table()))
        XCTAssertGreaterThanOrEqual(rows.count, 3, "expected a header and two body rows")

        let first = rows[0].grid
        for row in rows.dropFirst() {
            XCTAssertEqual(row.grid.columns.map(\.width), first.columns.map(\.width))
            XCTAssertEqual(row.grid.offsets, first.offsets)
        }
    }

    func testAColumnStartsAtTheSameOffsetInEveryRow() {
        let rows = drawnRows(in: drawnTableView(table()))
        XCTAssertFalse(rows.isEmpty)

        // Every row's second column begins at one x, whatever its first cell
        // holds — the property a reader sees as a straight edge down the page.
        let offsets = Set(rows.compactMap { $0.grid.offsets.indices.contains(1)
            ? $0.grid.offsets[1] : nil })
        XCTAssertEqual(offsets.count, 1, "a column moved between rows")
    }

    func testALongCellWrapsInsideItsColumnRatherThanRunningPastTheTable() {
        let source = """
            | Concern | Details |
            |---|---|
            | Local dependencies | a value long enough that it cannot possibly \
            sit on one line inside a column of this width, and so has to wrap |
            """
        let width: CGFloat = 420
        let view = drawnTableView(source, width: width)
        let rows = drawnRows(in: view)
        XCTAssertFalse(rows.isEmpty)

        let body = rows[rows.count - 1]
        XCTAssertGreaterThan(
            body.cells[1].lines.count, 1, "the long cell should have wrapped")
        XCTAssertLessThanOrEqual(
            body.grid.width, width,
            "the table overran the view it was solved for")
        // Wrapped inside its own column: the second column's lines start at
        // the column, not back at the row's leading edge.
        XCTAssertTrue(
            body.cells[1].lines.allSatisfy { $0.x >= 0 },
            "a wrapped line escaped its column")
    }

    func testARowsSourceIsCollapsedWhileItsGridIsDrawn() throws {
        let view = drawnTableView(table())
        let storage = try XCTUnwrap(view.textStorage)
        let pipe = (view.markdown as NSString).range(of: "| Rust |")
        XCTAssertNotEqual(pipe.location, NSNotFound)

        let font = storage.attribute(.font, at: pipe.location, effectiveRange: nil) as? NSFont
        XCTAssertEqual(
            font?.pointSize ?? 0, EditorTheme.hiddenMarkerFontSize, accuracy: 0.001,
            "a drawn row must not also lay its pipes out as text")
    }

    func testTheGridGivesWayToTheSourceWhenTheCaretEntersTheTable() {
        let view = drawnTableView(table())
        XCTAssertFalse(drawnRows(in: view).isEmpty, "the grid should be drawn to begin with")

        let inside = (view.markdown as NSString).range(of: "Rust")
        view.setSelectedRange(NSRange(location: inside.location, length: 0))
        view.textLayoutManager?.invalidateLayout(for: view.textLayoutManager!.documentRange)
        view.textLayoutManager?.ensureLayout(for: view.textLayoutManager!.documentRange)

        // The whole table, not merely the row holding the caret: rows are
        // solved against columns they share, so revealing one row's pipes in
        // the middle of a drawn grid would put a line laid out to a width
        // nothing else uses between two rows that still agree with each other.
        XCTAssertTrue(
            drawnRows(in: view).isEmpty,
            "the table should show its Markdown while the caret is inside it")
    }

    func testATableWithoutBodyRowsIsLeftAlone() {
        XCTAssertNoThrow(makeView("| a |\n|---|\n"))
    }
}
