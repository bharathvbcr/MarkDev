//
//  TableRowLayout.swift
//  MarkDevKit
//
//  Laying a GFM table out as a real grid: styling each cell, measuring what
//  it needs, solving the columns, and wrapping the cells inside them.
//

import AppKit

/// One cell, wrapped inside its column and ready to paint.
///
/// A finished value rather than a live text system, for the reason
/// `BlockDecorationPalette` is one: TextKit's fragment callbacks may be
/// nonisolated, so anything a fragment draws from has to be safe to touch off
/// the main actor. `CTLine` is immutable once created, which is what makes
/// this sound — the same bargain the palette makes by holding `CTFont` and
/// `CGColor` instead of their AppKit counterparts.
///
/// Lines are broken with `CTTypesetter` rather than by an `NSParagraphStyle`,
/// so line breaking and alignment are both decided here, in code that can be
/// asserted against, rather than inside a paragraph style whose handling of
/// alignment differs between the layout systems.
struct TableCellDrawing: @unchecked Sendable {
    struct Line {
        let line: CTLine
        /// Leading edge, already carrying this line's alignment offset.
        let x: CGFloat
        /// Baseline, measured down from the cell's top.
        let baseline: CGFloat
    }

    /// A source-preserving inline formula placed in this cell's coordinates.
    struct Formula {
        let image: CGImage
        let rect: CGRect
    }

    var lines: [Line] = []
    /// Where inline code sits, in the cell's own coordinates.
    var pills: [CGRect] = []
    /// Formula bitmaps CoreText reserves room for but cannot paint itself.
    var formulas: [Formula] = []
    /// Height the wrapped text occupies at the width it was given.
    var height: CGFloat = 0

    /// Wraps `text` to `width`, aligning each line in the column.
    static func make(
        text: NSAttributedString, width: CGFloat, alignment: TableAlignment, lineSpacing: CGFloat
    ) -> TableCellDrawing {
        var drawing = TableCellDrawing()
        let length = text.length
        // A column can be solved to nothing when the gaps alone overrun the
        // container. Laying text out at that width would ask the typesetter
        // for a break every glyph; an empty cell is the honest answer.
        guard length > 0, width >= 1 else { return drawing }

        let typesetter = CTTypesetterCreateWithAttributedString(text)
        var start = 0
        var top: CGFloat = 0

        while start < length {
            var count = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
            // Never zero: a single glyph wider than the column would otherwise
            // suggest a break of nothing and spin here forever. One character
            // per line overflows the column visibly, which is the correct
            // outcome for a word that cannot be broken — and the solver's
            // floor is what stops it happening for real text.
            if count <= 0 { count = 1 }
            let range = CFRange(location: start, length: min(count, length - start))
            let line = CTTypesetterCreateLine(typesetter, range)

            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let advance = CGFloat(
                CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            // Trailing spaces do not count toward how wide the line *looks*,
            // so a centred or right-aligned line is not shoved left by the
            // space that ended it.
            let visible = max(advance - CGFloat(CTLineGetTrailingWhitespaceWidth(line)), 0)

            let slack = max(width - visible, 0)
            let x: CGFloat
            switch alignment {
            case .auto, .left: x = 0
            case .center: x = slack / 2
            case .right: x = slack
            }

            let baseline = top + ascent
            drawing.lines.append(Line(line: line, x: x, baseline: baseline))
            drawing.pills.append(
                contentsOf: pillRects(
                    in: text, line: line, range: range,
                    x: x, top: top, height: ascent + descent))
            drawing.formulas.append(
                contentsOf: formulaRects(
                    in: text, line: line, range: range,
                    x: x, baseline: baseline))

            top = baseline + descent + leading + lineSpacing
            start = range.location + range.length
        }

        // The reserve font gives CoreText enough *advance* for a formula, but
        // SwiftMath's baseline can still put the bitmap above the cell's zero
        // or below CoreText's descent. Normalise the finished drawing, not
        // just its text metrics: every item moves together so baselines and
        // code pills keep their relationship, then the bitmap extents join
        // the line metrics in deciding the cell's height.
        let textBottom = max(top - lineSpacing, 0)
        let formulaTop = drawing.formulas.map(\.rect.minY).min() ?? 0
        let shift = max(-formulaTop, 0)
        if shift > 0 {
            drawing.lines = drawing.lines.map {
                Line(line: $0.line, x: $0.x, baseline: $0.baseline + shift)
            }
            drawing.pills = drawing.pills.map { $0.offsetBy(dx: 0, dy: shift) }
            drawing.formulas = drawing.formulas.map {
                Formula(image: $0.image, rect: $0.rect.offsetBy(dx: 0, dy: shift))
            }
        }
        let formulaBottom = drawing.formulas.map(\.rect.maxY).max() ?? 0
        // The gap after the final line belongs between lines, not under them.
        drawing.height = ceil(max(textBottom + shift, formulaBottom))
        return drawing
    }

    /// Where inline code runs land on one laid-out line.
    ///
    /// Measured per line rather than per run: a run that wrapped occupies a
    /// rect on each line it touches, and one measured from the string alone
    /// would paint a single pill straight across the break.
    private static func pillRects(
        in text: NSAttributedString,
        line: CTLine,
        range: CFRange,
        x: CGFloat,
        top: CGFloat,
        height: CGFloat
    ) -> [CGRect] {
        var rects: [CGRect] = []
        let lineRange = NSRange(location: range.location, length: range.length)
        guard lineRange.length > 0 else { return rects }

        text.enumerateAttribute(.inlineCodeRun, in: lineRange) { value, runRange, _ in
            guard value != nil else { return }
            let clipped = NSIntersectionRange(runRange, lineRange)
            guard clipped.length > 0 else { return }
            let from = CTLineGetOffsetForStringIndex(line, clipped.location, nil)
            let to = CTLineGetOffsetForStringIndex(line, NSMaxRange(clipped), nil)
            let width = to - from
            guard width.isFinite, width > 0, from.isFinite else { return }
            rects.append(CGRect(x: x + from, y: top, width: width, height: height))
        }
        return rects
    }

    /// Formula rectangles on one wrapped line, aligned to CoreText's actual
    /// baseline exactly as the editor fragment aligns them to TextKit's.
    private static func formulaRects(
        in text: NSAttributedString,
        line: CTLine,
        range: CFRange,
        x: CGFloat,
        baseline: CGFloat
    ) -> [Formula] {
        var formulas: [Formula] = []
        let lineRange = NSRange(location: range.location, length: range.length)
        guard lineRange.length > 0 else { return formulas }

        text.enumerateAttribute(.inlineMathRun, in: lineRange) { value, runRange, _ in
            guard let run = value as? InlineMathRun else { return }
            let clipped = NSIntersectionRange(runRange, lineRange)
            guard clipped.length > 0 else { return }
            let offset = CTLineGetOffsetForStringIndex(line, clipped.location, nil)
            let rect = CGRect(
                x: x + offset,
                y: baseline + run.baselineFromBottom - run.size.height,
                width: run.size.width,
                height: run.size.height)
            guard rect.width > 0, rect.height > 0,
                rect.origin.x.isFinite, rect.origin.y.isFinite,
                rect.width.isFinite, rect.height.isFinite
            else { return }
            formulas.append(Formula(image: run.image, rect: rect))
        }
        return formulas
    }

    /// Paints the cell with its top-left at `origin`.
    ///
    /// The text matrix is flipped because the editor's context is: without it
    /// every glyph is drawn upside down. Same idiom as the block label and the
    /// drawn list marker.
    func draw(in context: CGContext, at origin: CGPoint) {
        guard !lines.isEmpty else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for line in lines {
            context.textPosition = CGPoint(
                x: origin.x + line.x, y: origin.y + line.baseline)
            CTLineDraw(line.line, context)
        }
        for formula in formulas {
            let rect = formula.rect.offsetBy(dx: origin.x, dy: origin.y)
            context.saveGState()
            context.translateBy(x: 0, y: rect.midY)
            context.scaleBy(x: 1, y: -1)
            context.translateBy(x: 0, y: -rect.midY)
            context.draw(formula.image, in: rect)
            context.restoreGState()
        }
    }
}

/// Everything one row's fragment needs in order to draw itself.
///
/// Sendable for the same reason its cells are: a fragment may be asked to draw
/// off the main actor, and everything here is a finished value by then.
struct TableRowLayout: Sendable {
    /// The solved columns, shared by every row of the table.
    let grid: TableGrid
    /// This row's cells, already wrapped inside their columns.
    let cells: [TableCellDrawing]
    /// Height of the row's tallest cell, plus the row's own padding.
    let height: CGFloat
    let isHeader: Bool
    let isLast: Bool

    init(grid: TableGrid, cells: [TableCellDrawing], isHeader: Bool, isLast: Bool) {
        self.grid = grid
        self.cells = cells
        self.isHeader = isHeader
        self.isLast = isLast
        // An empty row is still a row: it keeps a line's worth of height so a
        // blank row in the source reads as a blank row rather than as a rule
        // drawn on top of the row below it.
        let tallest = cells.map(\.height).max() ?? 0
        height = max(tallest, Metrics.emptyRowHeight) + Metrics.verticalPadding * 2
    }

    enum Metrics {
        /// Space between one column's text and the next column's.
        static let columnGap: CGFloat = 18
        /// Breathing room above and below a row's text.
        static let verticalPadding: CGFloat = 5
        /// The least a row may be, so an empty one is still visible.
        static let emptyRowHeight: CGFloat = 14
    }
}

/// Turns a parsed table into solved, drawable rows, and remembers the answer.
///
/// One owner for the whole question. The delegate asks it per row fragment
/// during layout — several times for one table, and again on every resize —
/// so both halves are cached: the styled cell text against the cell's source,
/// and the solved grid against the table's text and the width it was solved
/// for.
///
/// Cells are styled from a range-local projection of the document parse rather
/// than by reading the document's storage. By the time a row is drawn its text
/// is *hidden* — collapsed to `hiddenMarkerFontSize` like any other block
/// replaced by rendered content — so the storage no longer holds anything
/// worth measuring. Projecting the document parse is the important part: a
/// cell is inline context, so reparsing `# literal` as a standalone document
/// turns it into a heading and loses reference definitions outside the cell.
@MainActor
final class TableLayoutResolver {
    /// Styled cell text and what it measures, keyed by the cell's source.
    ///
    /// The measurements ride with the text because they are the expensive
    /// part of re-solving: a keystroke anywhere in the document drops the
    /// solved grids, and re-measuring every visible cell — one `size()` for
    /// the cell and one per word for its floor — is work that has nothing to
    /// do with the edit.
    private var cells: [StyledKey: StyledCell] = [:]

    /// Cells already broken into lines, keyed by source, width and alignment.
    ///
    /// Typesetting is the other half of re-solving, and it is the half that
    /// grows with the text. Keyed on width because that is what the line
    /// breaks depend on.
    private var drawings: [DrawingKey: TableCellDrawing] = [:]

    private struct StyledCell {
        let key: StyledKey
        let text: NSAttributedString
        let natural: CGFloat
        let minimum: CGFloat
    }

    private struct RangeKey: Hashable {
        let location: Int
        let length: Int
    }

    private struct SpanKey: Hashable {
        let range: RangeKey
        let kind: UInt16
        let depth: UInt16
        let data: UInt32
        /// Link and wikilink styling depends on the interned destination, not
        /// only its numeric slot, which is local to one parse.
        let target: String?
    }

    private struct CellSource {
        let text: String
        let document: ParsedDocument
        let spans: [SpanKey]
        let markers: [RangeKey]

        func key(bold: Bool) -> StyledKey {
            StyledKey(text: text, bold: bold, spans: spans, markers: markers)
        }
    }

    private struct StyledKey: Hashable {
        let text: String
        let bold: Bool
        let spans: [SpanKey]
        let markers: [RangeKey]
    }

    private struct DrawingKey: Hashable {
        let style: StyledKey
        let width: CGFloat
        let alignment: TableAlignment
        let lineSpacing: CGFloat
    }
    /// Solved tables, keyed by position, parse revision, and width.
    private var tables: [Key: Solved] = [:]
    private var fingerprint: Fingerprint?

    /// One table's solved rows, with the ranges that select between them.
    private struct Solved {
        var rows: [TableRowLayout]
        /// Each row's range, ascending, parallel to `rows`.
        var rowRanges: [NSRange]
    }

    private struct Key: Hashable {
        /// The table's own position, not its text.
        ///
        /// Keying on the source would mean building a substring of the whole
        /// table for every row fragment TextKit lays out — O(table) per row,
        /// which is O(table²) for the table, and exactly the shape that has
        /// cost this codebase seconds per keystroke three times over. The
        /// parse's revision is what makes a position sufficient: any edit
        /// bumps it, so an entry can never outlive the text it describes.
        let revision: Int
        let location: Int
        let length: Int
        let width: CGFloat
    }

    /// What the caches are valid for. Colours are baked into the styled cell
    /// text, so a switch to dark mode invalidates every one of them.
    private struct Fingerprint: Equatable {
        let bodyFont: NSFont
        let textColor: NSColor
        let monoFont: NSFont
        let lineSpacing: CGFloat
        let secondaryColor: NSColor
        let accentColor: NSColor
        let codeColor: NSColor
        let linkColor: NSColor
        let tagColor: NSColor
        let highlightBackground: NSColor
        let markerColor: NSColor
    }

    /// Bumped whenever the document is reparsed.
    private var revision = 0

    /// Drops the solved grids, keeping the styled cells.
    ///
    /// Called on every reparse. The cells survive because they are keyed on
    /// their own source: an edit to one row does not change what `Rust` looks
    /// like, and re-styling every cell of every table per keystroke is the
    /// cost this cache exists to avoid.
    func invalidate() {
        revision &+= 1
        tables.removeAll(keepingCapacity: true)
    }

    /// Drops everything cached. Called when the theme or the appearance
    /// changes, because both are baked into the styled cells.
    func flush() {
        cells.removeAll(keepingCapacity: true)
        drawings.removeAll(keepingCapacity: true)
        tables.removeAll(keepingCapacity: true)
    }

    private func flushIfThemeChanged(_ theme: EditorTheme, ink: NSColor) {
        let current = Fingerprint(
            bodyFont: theme.bodyFont,
            textColor: ink,
            monoFont: theme.monoFont,
            lineSpacing: theme.lineSpacing,
            secondaryColor: theme.secondaryColor,
            accentColor: theme.accentColor,
            codeColor: theme.codeColor,
            linkColor: theme.linkColor,
            tagColor: theme.tagColor,
            highlightBackground: theme.highlightBackground,
            markerColor: theme.markerColor)
        guard current != fingerprint else { return }
        fingerprint = current
        flush()
    }

    /// The layout for the row covering `rowRange`, or `nil` if that range is
    /// not a row of `table`.
    ///
    /// - Parameter table: the table block containing the row. Passed in rather
    ///   than searched for here: the caller keeps the document's tables sorted
    ///   and binary-searches them, so this is not paid per row fragment.
    func layout(
        forRowAt rowRange: NSRange,
        inTable table: BlockDescriptor,
        document: ParsedDocument,
        text: NSString,
        availableWidth: CGFloat,
        theme: EditorTheme,
        ink: NSColor
    ) -> TableRowLayout? {
        flushIfThemeChanged(theme, ink: ink)

        let key = Key(
            revision: revision,
            location: table.range.location,
            length: table.range.length,
            width: availableWidth)

        let solved: Solved
        if let cached = tables[key] {
            solved = cached
        } else {
            solved = solve(
                table: table, in: document, text: text,
                availableWidth: availableWidth, theme: theme, ink: ink)
            // Bounded: the window can be dragged through hundreds of widths,
            // and an unbounded cache keyed on width would grow for its
            // lifetime. The whole map goes rather than the oldest entry —
            // solving is cheap once the cells are styled, and a real LRU here
            // would be machinery for a problem nobody has.
            if tables.count > 64 { tables.removeAll(keepingCapacity: true) }
            tables[key] = solved
        }

        // Binary search rather than a scan: TextKit asks once per row, so a
        // scan here would be quadratic in the number of rows.
        var low = 0
        var high = solved.rowRanges.count
        while low < high {
            let mid = low + (high - low) / 2
            if NSMaxRange(solved.rowRanges[mid]) <= rowRange.location {
                low = mid + 1
            } else {
                high = mid
            }
        }
        guard low < solved.rowRanges.count,
            NSIntersectionRange(solved.rowRanges[low], rowRange).length > 0
                || solved.rowRanges[low].location == rowRange.location
        else { return nil }
        return solved.rows[low]
    }

    // MARK: - Solving

    private func solve(
        table: BlockDescriptor,
        in document: ParsedDocument,
        text: NSString,
        availableWidth: CGFloat,
        theme: EditorTheme,
        ink: NSColor
    ) -> Solved {
        let columnCount = max(table.tableColumnCount ?? 0, 1)

        // One sweep of the blocks the table actually spans, not a filter of
        // the document per row. `document.blocks` is sorted by start offset,
        // so the table's own blocks are a contiguous run that can be found by
        // binary search and walked once — which is what keeps a document of
        // many tables linear rather than quadratic in its blocks.
        var index = Self.firstBlockIndex(atOrAfter: table.range.location, in: document.blocks)
        let tableEnd = NSMaxRange(table.range)

        var rowRanges: [NSRange] = []
        var sourcesByRow: [[CellSource]] = []
        var alignments = [TableAlignment](repeating: .auto, count: columnCount)
        var headerIndex: Int?

        while index < document.blocks.count, document.blocks[index].range.location < tableEnd {
            let block = document.blocks[index]
            index += 1
            switch block.kind {
            case .tableRow, .tableHead:
                if block.kind == .tableHead, headerIndex == nil {
                    headerIndex = rowRanges.count
                }
                rowRanges.append(block.range)
                // Placed by the column the parser assigned, never by order of
                // appearance: a row squared off with padding has holes, and
                // positional filling would slide every later cell one column
                // to the left.
                sourcesByRow.append(
                    (0..<columnCount).map { _ in Self.emptyCellSource })
            case .tableCell:
                guard let column = block.tableColumn, column < columnCount,
                    !sourcesByRow.isEmpty
                else { continue }
                sourcesByRow[sourcesByRow.count - 1][column] = cellSource(
                    block.range, in: text, document: document)
                if let alignment = block.tableAlignment, alignment != .auto {
                    alignments[column] = alignment
                }
            default:
                continue
            }
        }

        // Style every cell, then let each column ask for what its widest cell
        // needs and admit the least it can survive at.
        var styled: [[StyledCell]] = []
        var demands = (0..<columnCount).map {
            TableColumnDemand(natural: 0, minimum: 0, alignment: alignments[$0])
        }
        for (rowIndex, sources) in sourcesByRow.enumerated() {
            var row: [StyledCell] = []
            for (column, source) in sources.enumerated() {
                let cell = styledCell(
                    source, bold: rowIndex == headerIndex, theme: theme, ink: ink)
                row.append(cell)
                demands[column] = TableColumnDemand(
                    natural: max(demands[column].natural, cell.natural),
                    minimum: max(demands[column].minimum, cell.minimum),
                    alignment: alignments[column]
                )
            }
            styled.append(row)
        }

        let grid = TableGrid.solve(
            demands: demands,
            available: availableWidth,
            gap: TableRowLayout.Metrics.columnGap)

        let rows = styled.enumerated().map { rowIndex, row in
            TableRowLayout(
                grid: grid,
                cells: row.enumerated().map { column, cell in
                    drawing(
                        cell,
                        source: sourcesByRow[rowIndex][column],
                        width: grid.columns.indices.contains(column)
                            ? grid.columns[column].width : 0,
                        alignment: grid.columns.indices.contains(column)
                            ? grid.columns[column].alignment : .auto,
                        lineSpacing: theme.lineSpacing,
                        theme: theme,
                        ink: ink)
                },
                isHeader: rowIndex == headerIndex,
                isLast: rowIndex == styled.count - 1
            )
        }
        return Solved(rows: rows, rowRanges: rowRanges)
    }

    /// Index of the first block starting at or after `location`.
    ///
    /// Blocks arrive sorted by start offset, which is what makes this a binary
    /// search rather than the scan it replaced.
    private static func firstBlockIndex(
        atOrAfter location: Int, in blocks: [BlockDescriptor]
    ) -> Int {
        var low = 0
        var high = blocks.count
        while low < high {
            let mid = low + (high - low) / 2
            if blocks[mid].range.location < location {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    /// A cell's source, trimmed of the padding the author used to line the
    /// pipes up. That padding is presentation in the source file and has
    /// nothing to say about the column's width.
    private static let emptyCellSource = CellSource(
        text: "", document: .empty, spans: [], markers: [])

    private func cellSource(
        _ range: NSRange, in text: NSString, document: ParsedDocument
    ) -> CellSource {
        var start = min(max(range.location, 0), text.length)
        var end = min(NSMaxRange(range), text.length)
        while start < end, Self.isWhitespace(text.character(at: start)) { start += 1 }
        while end > start, Self.isWhitespace(text.character(at: end - 1)) { end -= 1 }
        guard end > start else { return Self.emptyCellSource }

        let absolute = NSRange(location: start, length: end - start)
        let localSpans = document.spans.compactMap { span -> StyleSpan? in
            let clipped = NSIntersectionRange(span.range, absolute)
            guard clipped.length > 0 else { return nil }
            return StyleSpan(
                range: NSRange(
                    location: clipped.location - absolute.location, length: clipped.length),
                kind: span.kind, depth: span.depth, data: span.data)
        }
        let localMarkers = document.markers.compactMap { marker -> SyntaxMarker? in
            let clipped = NSIntersectionRange(marker.range, absolute)
            guard clipped.length > 0 else { return nil }
            return SyntaxMarker(
                range: NSRange(
                    location: clipped.location - absolute.location, length: clipped.length),
                block: 0)
        }
        let localDocument = ParsedDocument(
            spans: localSpans, markers: localMarkers, blocks: [], strings: document.strings)
        let spanKeys = localSpans.map { span in
            SpanKey(
                range: RangeKey(location: span.range.location, length: span.range.length),
                kind: span.kind.rawValue,
                depth: span.depth,
                data: span.data,
                target: localDocument.target(for: span))
        }
        let markerKeys = localMarkers.map {
            RangeKey(location: $0.range.location, length: $0.range.length)
        }
        return CellSource(
            text: text.substring(with: absolute), document: localDocument,
            spans: spanKeys, markers: markerKeys)
    }

    private static func isWhitespace(_ character: unichar) -> Bool {
        UnicodeScalar(character).map(CharacterSet.whitespaces.contains) ?? false
    }

    /// One cell's text, styled the way the document styles inline Markdown.
    private func styledCell(
        _ source: CellSource, bold: Bool, theme: EditorTheme, ink: NSColor
    ) -> StyledCell {
        let key = source.key(bold: bold)
        if let cached = cells[key] { return cached }

        let content: NSAttributedString
        if source.text.isEmpty {
            content = NSAttributedString(string: "")
        } else {
            let parsed = source.document
            let storage = NSTextStorage(string: source.text)
            // `.reading` hides every marker: the cell is being drawn, not
            // edited, so its `**` has no more business showing than a
            // formula's `$$` does.
            let hidden = HiddenRanges(
                document: parsed, selection: NSRange(location: NSNotFound, length: 0),
                mode: .reading)
            MarkdownStyler.apply(
                document: parsed, hidden: hidden, to: storage, theme: theme)
            InlineMathTypesetter.apply(
                document: parsed, hidden: hidden, to: storage, theme: theme,
                ink: ink)

            let whole = NSRange(location: 0, length: storage.length)
            // The styler's paragraph styles belong to a document — indents,
            // block spacing, the panel insets a code cell would inherit. The
            // cell's own layout replaces all of it, and leaving them on adds
            // a stray indent to any cell holding a list-like character.
            storage.removeAttribute(.paragraphStyle, range: whole)
            if bold, whole.length > 0 {
                storage.enumerateAttribute(.font, in: whole) { value, range, _ in
                    guard let font = value as? NSFont else { return }
                    let descriptor = font.fontDescriptor.withSymbolicTraits(
                        font.fontDescriptor.symbolicTraits.union(.bold))
                    if let bolder = NSFont(descriptor: descriptor, size: font.pointSize) {
                        storage.addAttribute(.font, value: bolder, range: range)
                    }
                }
            }
            content = NSAttributedString(attributedString: storage)
        }

        let cell = StyledCell(
            key: key,
            text: content,
            natural: ceil(content.size().width),
            minimum: Self.widestWord(in: content))

        // Bounded for the same reason the table cache is: a long document of
        // wide tables would otherwise keep every cell it ever styled.
        if cells.count > 4096 { cells.removeAll(keepingCapacity: true) }
        cells[key] = cell
        return cell
    }

    /// One cell broken into lines at `width`, remembered across re-solves.
    private func drawing(
        _ cell: StyledCell,
        source: CellSource,
        width: CGFloat,
        alignment: TableAlignment,
        lineSpacing: CGFloat,
        theme: EditorTheme,
        ink: NSColor
    ) -> TableCellDrawing {
        let key = DrawingKey(
            style: cell.key, width: width, alignment: alignment, lineSpacing: lineSpacing)
        if let cached = drawings[key] { return cached }
        let text: NSAttributedString
        if source.text.contains("$"), width >= 1 {
            // The natural cell is measured before the grid is solved. Refit a
            // copy once the real column width is known so a wide equation is
            // scaled to its cell rather than clipped at the next column.
            let parsed = source.document
            let fitted = NSTextStorage(attributedString: cell.text)
            let hidden = HiddenRanges(
                document: parsed, selection: NSRange(location: NSNotFound, length: 0),
                mode: .reading)
            InlineMathTypesetter.apply(
                document: parsed, hidden: hidden, to: fitted, theme: theme,
                maxWidth: width, ink: ink)
            text = NSAttributedString(attributedString: fitted)
        } else {
            text = cell.text
        }
        let made = TableCellDrawing.make(
            text: text, width: width, alignment: alignment, lineSpacing: lineSpacing)
        if drawings.count > 4096 { drawings.removeAll(keepingCapacity: true) }
        drawings[key] = made
        return made
    }

    /// The widest run with no break opportunity in it — the width below which
    /// squeezing a column buys nothing, because the text cannot wrap tighter
    /// and would simply be clipped.
    static func widestWord(in text: NSAttributedString) -> CGFloat {
        let string = text.string as NSString
        guard string.length > 0 else { return 0 }

        var widest: CGFloat = 0
        var start = 0
        // A manual sweep rather than `components(separatedBy:)`: the widths
        // have to be measured *as styled*, so each word is measured as the
        // attributed substring it actually is.
        for index in 0...string.length {
            let isBreak: Bool
            if index == string.length {
                isBreak = true
            } else {
                let character = string.character(at: index)
                let scalar = Unicode.Scalar(character)
                isBreak = scalar.map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
            }
            guard isBreak else { continue }
            if index > start {
                let word = text.attributedSubstring(
                    from: NSRange(location: start, length: index - start))
                widest = max(widest, ceil(word.size().width))
            }
            start = index + 1
        }
        return widest
    }
}
