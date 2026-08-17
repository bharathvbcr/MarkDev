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

    var lines: [Line] = []
    /// Where inline code sits, in the cell's own coordinates.
    var pills: [CGRect] = []
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

            top = baseline + descent + leading + lineSpacing
            start = range.location + range.length
        }

        // The gap after the final line belongs between lines, not under them.
        drawing.height = ceil(max(top - lineSpacing, 0))
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
/// Cells are styled by re-parsing the cell's own source rather than by reading
/// the document's storage, and that is not a shortcut. By the time a row is
/// drawn its text is *hidden* — collapsed to `hiddenMarkerFontSize` like any
/// other block replaced by rendered content — so the storage no longer holds
/// anything worth measuring. Styling a copy is what lets the cell keep its
/// bold, its links and its code while the row itself is stood down.
@MainActor
final class TableLayoutResolver {
    /// Styled cell text and what it measures, keyed by the cell's source.
    ///
    /// The measurements ride with the text because they are the expensive
    /// part of re-solving: a keystroke anywhere in the document drops the
    /// solved grids, and re-measuring every visible cell — one `size()` for
    /// the cell and one per word for its floor — is work that has nothing to
    /// do with the edit.
    private var cells: [String: StyledCell] = [:]

    /// Cells already broken into lines, keyed by source, width and alignment.
    ///
    /// Typesetting is the other half of re-solving, and it is the half that
    /// grows with the text. Keyed on width because that is what the line
    /// breaks depend on.
    private var drawings: [DrawingKey: TableCellDrawing] = [:]

    private struct StyledCell {
        let text: NSAttributedString
        let natural: CGFloat
        let minimum: CGFloat
    }

    private struct DrawingKey: Hashable {
        let source: String
        let bold: Bool
        let width: CGFloat
        let alignment: TableAlignment
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

    private func flushIfThemeChanged(_ theme: EditorTheme) {
        let current = Fingerprint(
            bodyFont: theme.bodyFont, textColor: theme.textColor, monoFont: theme.monoFont)
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
        theme: EditorTheme
    ) -> TableRowLayout? {
        flushIfThemeChanged(theme)

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
                availableWidth: availableWidth, theme: theme)
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
        theme: EditorTheme
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
        var sourcesByRow: [[String]] = []
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
                sourcesByRow.append([String](repeating: "", count: columnCount))
            case .tableCell:
                guard let column = block.tableColumn, column < columnCount,
                    !sourcesByRow.isEmpty
                else { continue }
                sourcesByRow[sourcesByRow.count - 1][column] = cellSource(block.range, in: text)
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
                let cell = styledCell(source, bold: rowIndex == headerIndex, theme: theme)
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
                        bold: rowIndex == headerIndex,
                        width: grid.columns.indices.contains(column)
                            ? grid.columns[column].width : 0,
                        alignment: grid.columns.indices.contains(column)
                            ? grid.columns[column].alignment : .auto,
                        lineSpacing: theme.lineSpacing)
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
    private func cellSource(_ range: NSRange, in text: NSString) -> String {
        let start = min(max(range.location, 0), text.length)
        let length = min(range.length, text.length - start)
        guard length > 0 else { return "" }
        return text.substring(with: NSRange(location: start, length: length))
            .trimmingCharacters(in: .whitespaces)
    }

    /// One cell's text, styled the way the document styles inline Markdown.
    private func styledCell(
        _ source: String, bold: Bool, theme: EditorTheme
    ) -> StyledCell {
        let key = bold ? "\u{1}bold\u{1}" + source : source
        if let cached = cells[key] { return cached }

        let content: NSAttributedString
        if source.isEmpty {
            content = NSAttributedString(string: "")
        } else {
            let parsed = ParsedDocument.parse(source)
            let storage = NSTextStorage(string: source)
            // `.reading` hides every marker: the cell is being drawn, not
            // edited, so its `**` has no more business showing than a
            // formula's `$$` does.
            let hidden = HiddenRanges(
                document: parsed, selection: NSRange(location: NSNotFound, length: 0),
                mode: .reading)
            MarkdownStyler.apply(
                document: parsed, hidden: hidden, to: storage, theme: theme)

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
        source: String,
        bold: Bool,
        width: CGFloat,
        alignment: TableAlignment,
        lineSpacing: CGFloat
    ) -> TableCellDrawing {
        let key = DrawingKey(source: source, bold: bold, width: width, alignment: alignment)
        if let cached = drawings[key] { return cached }
        let made = TableCellDrawing.make(
            text: cell.text, width: width, alignment: alignment, lineSpacing: lineSpacing)
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
