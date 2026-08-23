//
//  TableStressTests.swift
//  MarkDevKitTests
//
//  The drawn table grid under abuse: random tables, random widths, random
//  edits, and every degenerate shape that can be written down.
//
//  The invariant these exist for is narrow and unforgiving. A table row's
//  source is *collapsed* — shrunk to nothing, like a formula's — and the grid
//  is drawn in its place. So a row that fails to resolve a layout does not
//  render badly; it renders as nothing at all, and an empty band where a row
//  should be is indistinguishable from a table that genuinely has one. Every
//  test here that sweeps a document ends by asserting the same thing: no row
//  is ever hidden without something drawn in its place.
//

import AppKit
import XCTest

@testable import MarkDevKit

@MainActor
final class TableStressTests: XCTestCase {

    // MARK: - Harness

    private func view(_ markdown: String, width: CGFloat = 520) -> MarkdownTextView {
        let view = MarkdownTextView.make()
        view.frame = NSRect(x: 0, y: 0, width: width, height: 900)
        view.setMarkdown(markdown)
        // Off the table unless a test says otherwise: live preview reveals the
        // block holding the caret, and `setMarkdown` leaves it at the end.
        view.setSelectedRange(NSRange(location: 0, length: 0))
        layout(view)
        return view
    }

    private func layout(_ view: MarkdownTextView) {
        guard let manager = view.textLayoutManager else { return }
        // The view's own layout first: that is where the text container
        // settles to its new width, and where the tables notice.
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        manager.invalidateLayout(for: manager.documentRange)
        manager.ensureLayout(for: manager.documentRange)
        // A real display pass. The tables re-solve in `viewWillDraw`, which is
        // the first point at which the frame, the text container and the
        // fragments have all settled — so a harness that never draws is
        // testing a state the app never shows.
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
        }
    }

    /// Every table-row fragment in the view, with the layout it resolved.
    private func rowFragments(
        in view: MarkdownTextView
    ) -> [(range: NSRange, row: TableRowLayout?)] {
        var found: [(NSRange, TableRowLayout?)] = []
        guard let manager = view.textLayoutManager,
            let start = manager.documentRange.location as NSTextLocation?
        else { return [] }

        manager.enumerateTextLayoutFragments(from: start) { fragment in
            guard let fragment = fragment as? MarkdownLayoutFragment,
                case .tableRow = fragment.decoration,
                let element = fragment.textElement?.elementRange
            else { return true }
            let from = manager.offset(from: start, to: element.location)
            let to = manager.offset(from: start, to: element.endLocation)
            guard from >= 0, to >= from else { return true }
            found.append((NSRange(location: from, length: to - from), fragment.tableRow))
            return true
        }
        return found
    }

    /// The invariant: a collapsed row always has a grid drawn in its place.
    ///
    /// Asserted from the text itself rather than from the fragment's own
    /// opinion — a row counts as collapsed when its characters are at the
    /// hidden size, which is what the reader would see as an empty band.
    private func assertNoRowIsHiddenWithoutBeingDrawn(
        in view: MarkdownTextView, _ message: String, file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let storage = view.textStorage else { return }
        // Only lines the parse calls a row. A table's delimiter line
        // (`|---|---|`) sits inside the table's range and so decorates as a
        // row too, but it is entirely syntax: it collapses to nothing and
        // correctly draws nothing, which is what the reader wants to see.
        let rows = view.parsed.blocks.filter { $0.kind == .tableRow || $0.kind == .tableHead }

        for (range, row) in rowFragments(in: view) {
            guard range.length > 0, NSMaxRange(range) <= storage.length else { continue }
            guard rows.contains(where: { NSIntersectionRange($0.range, range).length > 0 })
            else { continue }
            let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            let isCollapsed = (font?.pointSize ?? 99) <= EditorTheme.hiddenMarkerFontSize + 0.001
            guard isCollapsed else { continue }
            XCTAssertNotNil(
                row,
                "\(message): a row's source was collapsed with no grid drawn in its place",
                file: file, line: line)
        }
    }

    /// Every row of one table agrees about where its columns are.
    private func assertColumnsAgree(
        in view: MarkdownTextView, _ message: String, file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let grids = rowFragments(in: view).compactMap(\.row).map(\.grid)
        guard let first = grids.first else { return }
        for grid in grids.dropFirst() {
            XCTAssertEqual(
                grid.offsets, first.offsets,
                "\(message): a column moved between rows", file: file, line: line)
        }
    }

    // MARK: - Random tables at random widths

    func testRandomTablesAtRandomWidthsKeepTheirColumns() {
        var generator = SeededGenerator(seed: 20_260_817)

        for iteration in 0..<120 {
            let columns = Int.random(in: 1...6, using: &generator)
            let rows = Int.random(in: 1...8, using: &generator)
            let source = Self.randomTable(
                columns: columns, rows: rows, using: &generator)
            let width = CGFloat(Int.random(in: 60...1400, using: &generator))

            let view = view("Intro.\n\n" + source, width: width)
            let where_ = "iteration \(iteration), \(columns)x\(rows) at \(width)pt"

            assertNoRowIsHiddenWithoutBeingDrawn(in: view, where_)
            assertColumnsAgree(in: view, where_)

            for row in rowFragments(in: view).compactMap(\.row) {
                XCTAssertEqual(
                    row.cells.count, row.grid.columns.count,
                    "\(where_): a row has a different number of cells than columns")
                XCTAssertTrue(
                    row.height.isFinite && row.height > 0,
                    "\(where_): a row has no usable height")
                if !row.grid.overflows {
                    XCTAssertLessThanOrEqual(
                        row.grid.width, view.tableWidth + 0.01,
                        "\(where_): the table overran the width it was solved for")
                }
            }
        }
    }

    /// Builds a table of random cells, including empties and long runs.
    private static func randomTable(
        columns: Int, rows: Int, using generator: inout SeededGenerator
    ) -> String {
        let words = [
            "one", "podman", "`code`", "**bold**", "*italic*", "",
            "$x^2$", "$\\le&#x20;$",
            "a rather longer cell that will want to wrap somewhere",
            "supercalifragilisticexpialidocious_unbreakable_identifier",
            "日本語のセル", "🎉 emoji", "[link](x.md)", "0", "—",
        ]
        func cell() -> String { words.randomElement(using: &generator)! }

        var lines: [String] = []
        lines.append("| " + (0..<columns).map { _ in cell() }.joined(separator: " | ") + " |")
        let markers = [":---", "---:", ":---:", "---"]
        lines.append(
            "|" + (0..<columns).map { _ in markers.randomElement(using: &generator)! }
                .joined(separator: "|") + "|")
        for _ in 0..<rows {
            lines.append("| " + (0..<columns).map { _ in cell() }.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Degenerate shapes

    func testScientificFormulaeInTableCellsAreDrawnAtEveryWidth() {
        let source = """
            Intro.

            | Bound | Learning rule |
            |---|---|
            | $\\le&#x20;$ | Online 3-factor plasticity ($\\Delta w = \\eta e M - \\lambda w$), STDP eligibility, DFA/e-prop/BPTT reference baselines |
            """

        for width in [40, 120, 300, 520, 1_600] as [CGFloat] {
            let rendered = view(source, width: width)
            let rows = rowFragments(in: rendered).compactMap(\.row)
            let formulas = rows.flatMap(\.cells).flatMap(\.formulas)
            XCTAssertEqual(formulas.count, 2, "formula loss at \(width)pt")
            XCTAssertTrue(
                formulas.allSatisfy {
                    $0.rect.width > 0 && $0.rect.height > 0
                        && $0.rect.origin.x.isFinite && $0.rect.origin.y.isFinite
                        && $0.rect.width.isFinite && $0.rect.height.isFinite
                },
                "invalid formula geometry at \(width)pt")
            for row in rows {
                for (column, cell) in row.cells.enumerated() {
                    guard row.grid.columns.indices.contains(column) else { continue }
                    let columnWidth = row.grid.columns[column].width
                    for formula in cell.formulas {
                        XCTAssertGreaterThanOrEqual(
                            formula.rect.minX, -0.5,
                            "formula starts before its cell at \(width)pt")
                        XCTAssertLessThanOrEqual(
                            formula.rect.maxX, columnWidth + 0.5,
                            "formula crosses its column at \(width)pt")
                        XCTAssertGreaterThanOrEqual(
                            formula.rect.minY, -1,
                            "formula rises outside its row at \(width)pt")
                        XCTAssertLessThanOrEqual(
                            formula.rect.maxY, cell.height + 1,
                            "formula falls outside its row at \(width)pt")
                    }
                }
            }
            assertNoRowIsHiddenWithoutBeingDrawn(in: rendered, "scientific math at \(width)pt")
            assertColumnsAgree(in: rendered, "scientific math at \(width)pt")
        }
    }

    func testTableCellsKeepTheDocumentsInlineContext() throws {
        let source = """
            Intro.

            | Literal | Reference |
            |---|---|
            | # not a heading | [paper][source] |

            [source]: reference.md
            """
        let rendered = view(source, width: 900)
        let body = try XCTUnwrap(
            rowFragments(in: rendered).compactMap(\.row).first { !$0.isHeader })
        XCTAssertEqual(body.cells.count, 2)

        let bodyFont = EditorTheme.standard.bodyFont
        let bodyLineHeight = ceil(bodyFont.ascender - bodyFont.descender + bodyFont.leading)
        XCTAssertLessThanOrEqual(
            body.cells[0].height, bodyLineHeight + 1,
            "a leading '# ' inside a GFM cell is literal text, not a standalone heading")

        let referenceWidth = body.cells[1].lines.reduce(CGFloat.zero) { widest, line in
            max(widest, CGFloat(CTLineGetTypographicBounds(line.line, nil, nil, nil)))
        }
        let paperWidth = ("paper" as NSString).size(
            withAttributes: [.font: bodyFont]).width
        XCTAssertLessThanOrEqual(
            referenceWidth, paperWidth + 2,
            "a reference link in a cell must hide syntax using definitions from its document")
    }

    func testTableCacheInvalidatesForEveryGeometryBearingThemeChange() throws {
        let source = """
            | Words |
            |---|
            | one two three four five six seven eight nine ten |
            """
        let document = ParsedDocument.parse(source)
        let table = try XCTUnwrap(document.tables.first)
        let row = try XCTUnwrap(document.blocks.first { $0.kind == .tableRow })
        let resolver = TableLayoutResolver()
        var compact = EditorTheme.standard
        compact.lineSpacing = 1
        let first = try XCTUnwrap(resolver.layout(
            forRowAt: row.range, inTable: table, document: document,
            text: source as NSString, availableWidth: 90,
            theme: compact, ink: .black))

        var spacious = compact
        spacious.lineSpacing = 31
        let second = try XCTUnwrap(resolver.layout(
            forRowAt: row.range, inTable: table, document: document,
            text: source as NSString, availableWidth: 90,
            theme: spacious, ink: .black))

        XCTAssertGreaterThan(
            second.height, first.height + 20,
            "line spacing is baked into cached cell drawings and must invalidate them")
    }

    func testStyledCellCacheKeysCannotCollideWithAuthoredControlCharacters() throws {
        let prefix = "\u{1}bold\u{1}"
        func columnWidth(body: String) throws -> CGFloat {
            let source = "| x |\n|---|\n| \(body) |\n"
            let document = ParsedDocument.parse(source)
            let table = try XCTUnwrap(document.tables.first)
            let row = try XCTUnwrap(document.blocks.first { $0.kind == .tableRow })
            let resolver = TableLayoutResolver()
            return try XCTUnwrap(resolver.layout(
                forRowAt: row.range, inTable: table, document: document,
                text: source as NSString, availableWidth: 1_000,
                theme: .standard, ink: .black)).grid.columns[0].width
        }

        let adversarial = try columnWidth(body: prefix + "x")
        let visibleControl = try columnWidth(body: "boldx")
        XCTAssertGreaterThanOrEqual(
            adversarial, visibleControl - 1,
            "authored text must not alias the cache's internal bold sentinel")
    }

    func testTableFormulaeSurviveRevealEditAndCollapseCycles() {
        let original = """
            Before.

            | Bound | Rule |
            |---|---|
            | $\\le&#x20;$ | $\\Delta w = \\eta e M - \\lambda w$ |

            After.
            """
        let rendered = view(original, width: 420)
        guard let table = rendered.parsed.tables.first else {
            return XCTFail("fixture must parse as a table")
        }

        rendered.setSelectedRange(NSRange(location: table.range.location + 2, length: 0))
        layout(rendered)
        XCTAssertTrue(
            rowFragments(in: rendered).compactMap(\.row).isEmpty,
            "the caret must reveal the table's editable source instead of drawing over it")

        rendered.insertText("x", replacementRange: rendered.selectedRange())
        rendered.setSelectedRange(NSRange(location: 0, length: 0))
        layout(rendered)

        let rows = rowFragments(in: rendered).compactMap(\.row)
        XCTAssertEqual(rows.flatMap(\.cells).flatMap(\.formulas).count, 2)
        XCTAssertTrue(rendered.markdown.contains("$\\le&#x20;$"))
        XCTAssertTrue(rendered.markdown.contains("$\\Delta w = \\eta e M - \\lambda w$"))
        assertNoRowIsHiddenWithoutBeingDrawn(in: rendered, "reveal/edit/collapse")
    }

    func testTallAndNestedTableFormulaeStayInsideTheirCellsAtEveryWidth() {
        let formulae = [
            "\\frac{a}{b}",
            "\\sum_{i=0}^{n} i^2",
            "\\int_{-\\infty}^{\\infty} e^{-x^2} dx",
            "x^{x^{x^{x}}}",
            "\\sqrt{\\frac{1+\\sqrt{5}}{2}}",
            "\\left(\\frac{a+b}{c+d}\\right)^{12}",
        ]
        let rows = formulae.map { "| $\($0)$ |" }.joined(separator: "\n")
        let source = "Intro.\n\n| Formula |\n|---|\n" + rows + "\n"

        for width in [35, 60, 100, 180, 420] as [CGFloat] {
            let rendered = view(source, width: width)
            let drawings = rowFragments(in: rendered).compactMap(\.row)
            let bodyRows = drawings.filter { !$0.isHeader }
            let cells = bodyRows.flatMap(\.cells)
            XCTAssertEqual(cells.flatMap(\.formulas).count, formulae.count)
            for row in bodyRows {
                for (column, cell) in row.cells.enumerated() {
                    let columnWidth = row.grid.columns.indices.contains(column)
                        ? row.grid.columns[column].width : 0
                    for formula in cell.formulas {
                        XCTAssertGreaterThanOrEqual(formula.rect.minY, -0.5)
                        XCTAssertLessThanOrEqual(formula.rect.maxY, cell.height + 0.5)
                        XCTAssertGreaterThanOrEqual(formula.rect.minX, -0.5)
                        XCTAssertLessThanOrEqual(formula.rect.maxX, columnWidth + 0.5)
                    }
                }
            }
        }
    }

    func testDegenerateTablesDoNotBreakTheGrid() {
        let cases: [(String, String)] = [
            ("one column", "| a |\n|---|\n| b |\n"),
            ("header only", "| a | b |\n|---|---|\n"),
            ("empty cells", "| a | b |\n|---|---|\n|  |  |\n"),
            ("short row", "| a | b | c |\n|---|---|---|\n| 1 |\n"),
            ("surplus cells", "| a | b |\n|---|---|\n| 1 | 2 | 3 | 4 |\n"),
            ("unbreakable word", "| a | b |\n|---|---|\n| \(String(repeating: "x", count: 300)) | y |\n"),
            ("many columns", "|" + (0..<24).map { "c\($0)" }.joined(separator: "|") + "|\n"
                + "|" + Array(repeating: "---", count: 24).joined(separator: "|") + "|\n"
                + "|" + (0..<24).map { "v\($0)" }.joined(separator: "|") + "|\n"),
            ("cjk", "| 列 | 値 |\n|---|---|\n| 日本語のとても長いセルの内容です | 値 |\n"),
            ("emoji", "| a | b |\n|---|---|\n| 🎉🎊🥳 | 👨‍👩‍👧‍👦 |\n"),
            ("nested emphasis", "| a | b |\n|---|---|\n| ***both*** `x` | [l](y) |\n"),
            ("pipes escaped", "| a | b |\n|---|---|\n| x \\| y | z |\n"),
            ("table at document start", "| a | b |\n|---|---|\n| 1 | 2 |\n\ntail\n"),
            ("table in a quote", "> | a | b |\n> |---|---|\n> | 1 | 2 |\n"),
            ("table in a list", "- item\n\n  | a | b |\n  |---|---|\n  | 1 | 2 |\n"),
            ("two tables", "| a |\n|---|\n| 1 |\n\ntext\n\n| b |\n|---|\n| 2 |\n"),
        ]

        for (name, source) in cases {
            for width in [40, 120, 300, 520, 1600] as [CGFloat] {
                let view = view("Intro.\n\n" + source, width: width)
                assertNoRowIsHiddenWithoutBeingDrawn(in: view, "\(name) at \(width)pt")
                assertColumnsAgree(in: view, "\(name) at \(width)pt")
            }
        }
    }

    func testAnUnbreakableWordOverflowsRatherThanVanishing() {
        // The one case the solver cannot satisfy: a word wider than the whole
        // container. It must still be drawn — the failure this guards is the
        // column being solved to nothing and the cell rendering as blank.
        let word = String(repeating: "W", count: 120)
        let view = view("Intro.\n\n| a | b |\n|---|---|\n| \(word) | y |\n", width: 200)

        let rows = rowFragments(in: view).compactMap(\.row)
        XCTAssertFalse(rows.isEmpty)
        let body = rows[rows.count - 1]
        XCTAssertFalse(body.cells[0].lines.isEmpty, "the long word was not drawn at all")
    }

    // MARK: - The caret

    func testSweepingTheCaretThroughATableNeverLosesARow() {
        let source = "Intro.\n\n| Name | Value |\n|---|---|\n| a | 1 |\n| b | 2 |\n\nTail.\n"
        let view = view(source)
        let length = (view.markdown as NSString).length

        for offset in stride(from: 0, through: length, by: 1) {
            view.setSelectedRange(NSRange(location: offset, length: 0))
            layout(view)
            assertNoRowIsHiddenWithoutBeingDrawn(in: view, "caret at \(offset)")
            assertColumnsAgree(in: view, "caret at \(offset)")
        }
    }

    func testTheGridReturnsWhenTheCaretLeavesTheTable() {
        let source = "Intro.\n\n| Name | Value |\n|---|---|\n| a | 1 |\n\nTail.\n"
        let view = view(source)
        XCTAssertFalse(rowFragments(in: view).compactMap(\.row).isEmpty)

        let inside = (view.markdown as NSString).range(of: "| a | 1 |")
        view.setSelectedRange(NSRange(location: inside.location + 2, length: 0))
        layout(view)
        XCTAssertTrue(
            rowFragments(in: view).compactMap(\.row).isEmpty,
            "the source should be on screen while the caret is in the table")

        view.setSelectedRange(NSRange(location: 0, length: 0))
        layout(view)
        XCTAssertFalse(
            rowFragments(in: view).compactMap(\.row).isEmpty,
            "the grid should come back when the caret leaves")
    }

    func testSourceModeShowsTheMarkdownAndDrawsNoGrid() {
        let view = view("Intro.\n\n| a | b |\n|---|---|\n| 1 | 2 |\n")
        view.mode = .source
        layout(view)

        XCTAssertTrue(
            rowFragments(in: view).compactMap(\.row).isEmpty,
            "source mode must not draw a grid over the Markdown")
        assertNoRowIsHiddenWithoutBeingDrawn(in: view, "source mode")
    }

    func testReadingModeDrawsTheGridWithNoCaretAtAll() {
        let view = view("Intro.\n\n| a | b |\n|---|---|\n| 1 | 2 |\n")
        view.mode = .reading
        layout(view)

        XCTAssertFalse(
            rowFragments(in: view).compactMap(\.row).isEmpty,
            "preview and Quick Look render through this mode")
        assertNoRowIsHiddenWithoutBeingDrawn(in: view, "reading mode")
    }

    // MARK: - Editing

    func testTypingInAndAroundATableKeepsEveryRowDrawn() {
        var generator = SeededGenerator(seed: 99_1701)
        let insertions = ["x", " ", "|", "\n", "**", "`", "-", "#", "]"]

        for seed in 0..<25 {
            let view = view(
                "Intro.\n\n| Name | Value |\n|---|---|\n| a | 1 |\n| b | 2 |\n\nTail.\n")

            for step in 0..<12 {
                let length = (view.markdown as NSString).length
                guard length > 0 else { break }
                let at = Int.random(in: 0...length, using: &generator)
                let insert = insertions.randomElement(using: &generator)!

                view.setSelectedRange(NSRange(location: at, length: 0))
                view.insertText(insert, replacementRange: NSRange(location: at, length: 0))
                // Off the table, so the assertion is about drawn rows rather
                // than about the row the caret happens to be revealing.
                view.setSelectedRange(NSRange(location: 0, length: 0))
                layout(view)

                let where_ = "seed \(seed), step \(step), inserted \(insert.debugDescription) at \(at)"
                assertNoRowIsHiddenWithoutBeingDrawn(in: view, where_)
                assertColumnsAgree(in: view, where_)
            }
        }
    }

    func testATableThatStopsBeingATableLeavesNothingBehind() {
        // The shape that bit the kerning pass: text that was a table and is
        // not any more. There the padding survived and turned up as an 18pt
        // gap in the middle of a code block; here the risk is a solved grid
        // outliving the rows it described.
        let view = view("Intro.\n\n| a | b |\n|---|---|\n| 1 | 2 |\n")
        XCTAssertFalse(rowFragments(in: view).compactMap(\.row).isEmpty)

        view.setMarkdown("Intro.\n\nJust prose now, no pipes at all.\n")
        view.setSelectedRange(NSRange(location: 0, length: 0))
        layout(view)

        XCTAssertTrue(
            rowFragments(in: view).isEmpty,
            "a document with no table should have no table fragments")
        assertNoRowIsHiddenWithoutBeingDrawn(in: view, "after the table was removed")
    }

    func testWideningAndNarrowingTheViewResolvesTheColumnsAgain() {
        let view = view(
            "Intro.\n\n| Concern | Details |\n|---|---|\n"
                + "| Local dependencies | a value long enough to need wrapping at some widths |\n",
            width: 300)

        var widths: [CGFloat: CGFloat] = [:]
        for width in [200, 360, 520, 900, 1400, 240] as [CGFloat] {
            view.frame = NSRect(x: 0, y: 0, width: width, height: 900)
            view.textContainer?.size = NSSize(
                width: width, height: CGFloat.greatestFiniteMagnitude)
            layout(view)

            assertNoRowIsHiddenWithoutBeingDrawn(in: view, "at \(width)pt")
            assertColumnsAgree(in: view, "at \(width)pt")

            let grids = rowFragments(in: view).compactMap(\.row).map(\.grid)
            if let grid = grids.first {
                widths[width] = grid.width
                if grid.overflows {
                    // The honest case: the words themselves are wider than the
                    // view. It must say so rather than clip silently, and it
                    // must still be as narrow as it can be drawn.
                    XCTAssertTrue(
                        grid.isCompressed, "an overflowing table must be compressed")
                } else {
                    XCTAssertLessThanOrEqual(
                        grid.width, view.tableWidth + 0.01,
                        "the table overran the view at \(width)pt")
                }
            }
        }

        // The table actually tracked the view rather than keeping one solved
        // geometry: a cache keyed carelessly would have returned the first.
        XCTAssertGreaterThan(
            Set(widths.values).count, 1, "the grid never re-solved for a new width")
    }

    /// `invalidateLayout` re-lays-out the *same* fragments; it does not ask
    /// the delegate for new ones.
    ///
    /// This is why ``MarkdownTextView/reresolveTableFragments()`` has to exist
    /// at all, and it is worth pinning down rather than believing: the obvious
    /// reading of "invalidate the layout" is that everything is rebuilt, and
    /// on that reading a resize would fix the columns by itself. It does not,
    /// and a table kept the geometry of whatever width the window opened at.
    ///
    /// If a future macOS changes this, the extra hooks become redundant rather
    /// than wrong — but this test is where that would be noticed.
    func testInvalidatingLayoutKeepsTheSameFragmentObjects() {
        let view = view("Intro.\n\n| a | b |\n|---|---|\n| 1 | 2 |\n")
        guard let manager = view.textLayoutManager else { return XCTFail("no manager") }

        func identities() -> [ObjectIdentifier] {
            var out: [ObjectIdentifier] = []
            manager.enumerateTextLayoutFragments(from: manager.documentRange.location) { f in
                out.append(ObjectIdentifier(f))
                return true
            }
            return out
        }

        let before = identities()
        XCTAssertFalse(before.isEmpty)
        manager.invalidateLayout(for: manager.documentRange)
        manager.ensureLayout(for: manager.documentRange)
        XCTAssertEqual(
            identities(), before,
            "if fragments were rebuilt here, the width hooks would be unnecessary")
    }

    // MARK: - Caching

    func testTheSameTableSolvedTwiceGivesTheSameAnswer() {
        let source = "Intro.\n\n| a | b |\n|---|---|\n| 1 | 2 |\n"
        let first = rowFragments(in: view(source)).compactMap(\.row).map(\.grid.offsets)
        let second = rowFragments(in: view(source)).compactMap(\.row).map(\.grid.offsets)
        XCTAssertEqual(first, second, "solving is not deterministic")
    }

    func testChangingTheThemeRebuildsTheCells() {
        let view = view("Intro.\n\n| a | b |\n|---|---|\n| 1 | 2 |\n")
        let before = rowFragments(in: view).compactMap(\.row).first?.grid.width

        var bigger = EditorTheme.standard
        bigger.bodyFont = NSFont.systemFont(ofSize: EditorTheme.standard.bodyFont.pointSize * 2)
        view.theme = bigger
        view.setSelectedRange(NSRange(location: 0, length: 0))
        layout(view)

        let after = rowFragments(in: view).compactMap(\.row).first?.grid.width
        XCTAssertNotNil(before)
        XCTAssertNotNil(after)
        XCTAssertNotEqual(
            before, after,
            "cells are styled with the theme's font; a theme change must re-measure them")
    }
}
