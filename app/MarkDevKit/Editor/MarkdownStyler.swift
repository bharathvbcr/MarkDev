//
//  MarkdownStyler.swift
//  MarkDevKit
//
//  Applies a parse result to an NSTextStorage.
//

import AppKit

/// Turns a ``ParsedDocument`` into text attributes.
///
/// # Why markers shrink instead of disappearing
///
/// Collapsed syntax stays in text storage at a near-zero point size rather
/// than being removed. Keeping the characters is what preserves the
/// behaviours users would otherwise lose:
///
/// - **Copy** yields real Markdown. If hidden syntax were deleted from
///   storage, copying `**bold**` would put `bold` on the pasteboard and
///   quietly destroy the formatting.
/// - **Undo, find, and word count** all operate on the document the user
///   actually has, not a rendering of it.
/// - **Selection and hit-testing** stay native. TextKit's own machinery keeps
///   working, instead of being reimplemented on top of a coordinate space
///   that disagrees with storage.
///
/// The caret is the one thing that must be taught about hidden runs, and that
/// lives in ``MarkdownTextView`` — a single, contained override rather than a
/// parallel text engine.
public enum MarkdownStyler {
    /// Applies `document` and `hidden` to `storage`.
    ///
    /// Pass `scope` to restyle only part of the document. Styling the whole
    /// buffer on every keystroke is O(document) and costs hundreds of
    /// milliseconds once a file is long enough to matter; scoping it to the
    /// edited region is what keeps typing at one frame.
    ///
    /// Runs inside one `beginEditing`/`endEditing` pair so TextKit relayouts
    /// once rather than once per attribute run.
    /// - Parameters:
    ///   - drawsReplacements: whether the fragment renderer is standing in for
    ///     literal syntax — a checkbox for `[ ]`, a laid-out grid for a table's
    ///     pipes. False in source mode, where the reader has asked to see the
    ///     characters as written and must not have them hidden or shifted.
    ///   - contentWidth: usable width of the text container, used to decide
    ///     whether a table's natural column widths will fit before committing
    ///     to them.
    @MainActor
    public static func apply(
        document: ParsedDocument,
        hidden: HiddenRanges,
        to storage: NSTextStorage,
        theme: EditorTheme = .standard,
        scope: NSRange? = nil,
        drawsReplacements: Bool = true,
        contentWidth: CGFloat? = nil
    ) {
        let full = NSRange(location: 0, length: storage.length)
        guard full.length > 0 else { return }
        let target = clamp(scope ?? full, to: full)
        guard target.length > 0 else { return }

        storage.beginEditing()
        defer { storage.endEditing() }

        applyBase(to: storage, range: target, theme: theme)
        applyBlocks(document.blocks, to: storage, limit: full, scope: target, theme: theme)
        applySpans(document.spans, to: storage, limit: full, scope: target, theme: theme)
        applyLinkTargets(document, to: storage, limit: full, scope: target)
        // Last: marker styling must win over the span attributes it overlaps,
        // or a heading's `# ` would be re-inflated to heading size.
        applyMarkers(
            document, hidden: hidden, to: storage, limit: full, scope: target, theme: theme)

        guard drawsReplacements else {
            // Source mode still has to *undo* any alignment a previous live
            // pass left behind, or switching modes would show a table with
            // mysterious gaps inside its pipes.
            clearTableAlignment(document, in: storage, limit: full, scope: target)
            return
        }
        // After the marker pass, which would otherwise recolour the task
        // marker it has just been told to leave visible.
        hideReplacedMarkers(document, to: storage, limit: full, scope: target)
        alignTables(
            document, hidden: hidden, in: storage, limit: full, scope: target, theme: theme,
            contentWidth: contentWidth)
    }

    // MARK: - Layers

    @MainActor
    private static func applyBase(
        to storage: NSTextStorage, range: NSRange, theme: EditorTheme
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = theme.lineSpacing
        paragraph.paragraphSpacing = theme.paragraphSpacing

        // Clearing first means a construct that was deleted cannot leave its
        // styling behind on the text that replaced it.
        storage.setAttributes(
            [
                .font: theme.bodyFont,
                .foregroundColor: theme.textColor,
                .paragraphStyle: paragraph,
            ],
            range: range
        )
    }

    @MainActor
    private static func applyBlocks(
        _ blocks: [BlockDescriptor],
        to storage: NSTextStorage,
        limit: NSRange,
        scope: NSRange,
        theme: EditorTheme
    ) {
        for block in blocks {
            let range = clamp(block.range, to: limit)
            guard range.length > 0, NSIntersectionRange(range, scope).length > 0 else { continue }

            switch block.kind {
            case .codeBlock, .mermaidBlock, .mathBlock, .frontmatter:
                // No `.backgroundColor` here. That attribute paints a box
                // exactly as wide as each line's glyphs, which stacks up as a
                // ragged staircase behind the panel the fragment renderer
                // already draws to the container's edge. One background, drawn
                // once, in the place that knows the block's real width.
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = theme.lineSpacing
                paragraph.firstLineHeadIndent = Metrics.codeInset
                paragraph.headIndent = Metrics.codeInset
                // Negative tail indent is measured from the trailing edge, so
                // a long line stops short of the panel's border instead of
                // running into it.
                paragraph.tailIndent = -Metrics.codeInset
                storage.addAttributes(
                    [.font: theme.monoFont, .paragraphStyle: paragraph],
                    range: range
                )
            case .table:
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = theme.lineSpacing
                paragraph.firstLineHeadIndent = Metrics.codeInset
                paragraph.headIndent = Metrics.codeInset
                paragraph.tailIndent = -Metrics.codeInset
                storage.addAttribute(.paragraphStyle, value: paragraph, range: range)
            case .tableHead:
                // The header earns weight rather than a different colour: a
                // grid read at a glance needs its top row to be findable
                // without also being louder than the data.
                addTrait(.bold, to: storage, range: range)

                // Real layout space above the grid, as paragraph spacing
                // rather than the fragment's `topMargin`.
                //
                // The blank line separating a table from what precedes it is
                // itself syntax, and live preview collapses it to nothing — so
                // the table can end up butting directly against the line
                // above. A fragment margin does not reliably reserve space
                // there; widening it only pushes the panel's own top edge up
                // into the previous line, which is how a table came to draw a
                // border through the bullet above it.
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = theme.lineSpacing
                paragraph.firstLineHeadIndent = Metrics.codeInset
                paragraph.headIndent = Metrics.codeInset
                paragraph.tailIndent = -Metrics.codeInset
                paragraph.paragraphSpacingBefore = Metrics.tableGap
                storage.addAttribute(.paragraphStyle, value: paragraph, range: range)
            case .blockQuote, .callout:
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = theme.lineSpacing
                paragraph.paragraphSpacing = theme.paragraphSpacing
                paragraph.firstLineHeadIndent = 16
                paragraph.headIndent = 16
                storage.addAttributes(
                    [.foregroundColor: theme.quoteColor, .paragraphStyle: paragraph],
                    range: range
                )
            case .listItem:
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = theme.lineSpacing
                // Indent scales with nesting so nested lists read as nested.
                let indent = CGFloat(block.depth) * 8 + 16
                paragraph.firstLineHeadIndent = indent
                paragraph.headIndent = indent
                storage.addAttribute(.paragraphStyle, value: paragraph, range: range)
            default:
                break
            }
        }
    }

    @MainActor
    private static func applySpans(
        _ spans: [StyleSpan],
        to storage: NSTextStorage,
        limit: NSRange,
        scope: NSRange,
        theme: EditorTheme
    ) {
        for span in spans {
            let range = clamp(span.range, to: limit)
            guard range.length > 0, NSIntersectionRange(range, scope).length > 0 else { continue }

            switch span.kind {
            case .heading:
                storage.addAttribute(
                    .font, value: theme.headingFont(level: Int(span.data)), range: range)
            case .strong:
                addTrait(.bold, to: storage, range: range)
            case .emphasis:
                addTrait(.italic, to: storage, range: range)
            case .strikethrough:
                storage.addAttribute(
                    .strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            case .inlineCode:
                // The pill behind this is drawn by the fragment renderer, not
                // set as `.backgroundColor`: the attribute fills a square box
                // tight against the glyphs, with no room at the ends, which is
                // what makes inline code read as pasted-in rather than set.
                storage.addAttributes(
                    [.font: theme.monoFont, .foregroundColor: theme.codeColor],
                    range: range
                )
            case .link:
                storage.addAttributes(
                    [
                        .foregroundColor: theme.linkColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                    ],
                    range: range
                )
            case .wikiLink:
                // Distinguished from external links: a wikilink navigates
                // inside the vault, so it reads as a first-class connection
                // rather than an outbound jump.
                storage.addAttributes(
                    [.foregroundColor: theme.accentColor, .underlineStyle: 0],
                    range: range
                )
            case .tag:
                storage.addAttribute(.foregroundColor, value: theme.tagColor, range: range)
            case .highlight:
                storage.addAttribute(
                    .backgroundColor, value: theme.highlightBackground, range: range)
            case .inlineMath:
                storage.addAttributes(
                    [.font: theme.monoFont, .foregroundColor: theme.accentColor], range: range)
            case .image:
                storage.addAttribute(.foregroundColor, value: theme.secondaryColor, range: range)
            case .footnoteReference, .taskMarker, .inlineHTML:
                storage.addAttribute(.foregroundColor, value: theme.secondaryColor, range: range)
            case .superscript, .subscript:
                break
            }
        }
    }

    /// Tags wikilinks with a `.link` attribute carrying their target.
    ///
    /// Using AppKit's own link attribute rather than hand-rolled hit testing
    /// buys the pointing-hand cursor, `clickedOnLink` routing, and
    /// accessibility for free — all of which would otherwise have to be
    /// reimplemented on top of TextKit 2 coordinates.
    @MainActor
    private static func applyLinkTargets(
        _ document: ParsedDocument,
        to storage: NSTextStorage,
        limit: NSRange,
        scope: NSRange
    ) {
        // Bridged once, not per span. `storage.string` copies the whole
        // document across to Foundation, so pulling it inside the loop turns
        // one pass over the spans into one pass over the *document* per tag —
        // which on a long note costs more than every other styling pass
        // combined.
        var text: NSString?

        for span in document.spans {
            guard span.kind == .wikiLink || span.kind == .tag else { continue }
            let range = clamp(span.range, to: limit)
            guard range.length > 0, NSIntersectionRange(range, scope).length > 0 else { continue }

            let scheme: String
            let target: String?
            if span.kind == .wikiLink {
                scheme = wikiLinkScheme
                target = document.target(for: span)
            } else {
                // A tag is a link to everything carrying it. Routing it
                // through the same machinery as a wikilink is what gives it a
                // pointing-hand cursor and an accessible role, rather than a
                // second hit-testing path built on TextKit 2 coordinates.
                //
                // Its target is read straight out of storage: unlike a link, a
                // tag has no string-table entry, because its target *is* its
                // text.
                guard range.length > 1 else { continue }
                let string = text ?? (storage.string as NSString)
                text = string
                scheme = tagScheme
                target = string.substring(
                    with: NSRange(location: range.location + 1, length: range.length - 1))
            }

            guard let target,
                let encoded = target.addingPercentEncoding(
                    withAllowedCharacters: .urlPathAllowed),
                let url = URL(string: "\(scheme)://\(encoded)")
            else { continue }
            storage.addAttribute(.link, value: url, range: range)
        }
    }

    /// URL scheme used to carry a wikilink target through AppKit's link
    /// machinery. Never registered with the system — it exists only so
    /// `clickedOnLink` can recognise its own links.
    public static let wikiLinkScheme = "markdev-wiki"

    /// URL scheme used to carry a `#tag` through the same machinery.
    public static let tagScheme = "markdev-tag"

    @MainActor
    private static func applyMarkers(
        _ document: ParsedDocument,
        hidden: HiddenRanges,
        to storage: NSTextStorage,
        limit: NSRange,
        scope: NSRange,
        theme: EditorTheme
    ) {
        // Visible markers: dimmed, so revealed syntax reads as scaffolding.
        // `covers` binary-searches; testing each marker against every hidden
        // range made styling quadratic and cost seconds per keystroke on a
        // large document.
        for marker in document.markers {
            let range = clamp(marker.range, to: limit)
            guard range.length > 0, NSIntersectionRange(range, scope).length > 0,
                !hidden.covers(range)
            else { continue }
            storage.addAttribute(.foregroundColor, value: theme.markerColor, range: range)
        }

        // Hidden markers: shrunk to nothing but still present in storage.
        for range in hidden.ranges {
            let clamped = clamp(range, to: limit)
            guard clamped.length > 0, NSIntersectionRange(clamped, scope).length > 0
            else { continue }
            storage.addAttributes(
                [
                    .font: theme.hiddenMarkerFont,
                    .foregroundColor: NSColor.clear,
                    .kern: 0,
                ],
                range: clamped
            )
        }
    }

    // MARK: - Drawn replacements

    /// Makes the characters a drawn ornament stands in for invisible.
    ///
    /// A `[ ]` cannot simply be *hidden* the way `**` is: collapsing it to
    /// 0.01pt would leave the checkbox nowhere to sit, and the line would read
    /// as an unmarked bullet. Instead the characters keep their size — so they
    /// still reserve exactly the space the checkbox needs, on the baseline, at
    /// whatever body size the theme is using — and only their colour goes.
    /// They remain in storage, so ⌘C still copies `- [x] done`.
    @MainActor
    private static func hideReplacedMarkers(
        _ document: ParsedDocument,
        to storage: NSTextStorage,
        limit: NSRange,
        scope: NSRange
    ) {
        for span in document.spans where span.kind == .taskMarker {
            let range = clamp(span.range, to: limit)
            guard range.length > 0, NSIntersectionRange(range, scope).length > 0 else { continue }
            storage.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
        }
    }

    // MARK: - Tables

    /// Lays a table's cells out in columns.
    ///
    /// # Why kerning, and not tab stops
    ///
    /// Live preview hides every `|` and the entire delimiter row, so the
    /// characters that used to separate cells are gone by the time this runs —
    /// `| Name | Qty |` renders as `NameQty`. Tab stops cannot help: there are
    /// no tabs in the source, and inserting any would edit the user's file.
    ///
    /// What is left is the space *between* glyphs, which is exactly what
    /// `.kern` controls. Each cell is measured as rendered, and the difference
    /// between its width and its column's is added after its last character —
    /// or before its first, for a right-aligned column. The document is never
    /// touched; only the gaps between characters that are already there.
    ///
    /// Idempotent by construction: kerning is stripped from the table before
    /// anything is measured, so a restyle measures natural widths rather than
    /// the widths its own last pass produced. Without that, every keystroke in
    /// a table would widen it.
    @MainActor
    private static func alignTables(
        _ document: ParsedDocument,
        hidden: HiddenRanges,
        in storage: NSTextStorage,
        limit: NSRange,
        scope: NSRange,
        theme: EditorTheme,
        contentWidth: CGFloat?
    ) {
        for (index, table) in document.blocks.enumerated() where table.kind == .table {
            let tableRange = clamp(table.range, to: limit)
            guard tableRange.length > 0,
                NSIntersectionRange(tableRange, scope).length > 0
            else { continue }

            storage.removeAttribute(.kern, range: tableRange)

            let cells = self.cells(of: table, from: index, in: document, limit: limit)
            guard !cells.isEmpty else { continue }
            // Column layout exists to stand in for pipes that are not being
            // drawn. When the caret is in the table its pipes are visible —
            // the reader is looking at the source — and padding between them
            // would stretch the very characters they came to edit.
            guard separatorsAreHidden(before: cells[0].1, in: tableRange, hidden: hidden) else {
                continue
            }

            var columnWidths: [Int: CGFloat] = [:]
            var measured: [(cell: BlockDescriptor, range: NSRange, width: CGFloat)] = []
            measured.reserveCapacity(cells.count)
            for (cell, range) in cells {
                let width = storage.attributedSubstring(from: range).size().width
                measured.append((cell, range, width))
                let column = cell.tableColumn ?? 0
                columnWidths[column] = max(columnWidths[column] ?? 0, width)
            }

            let columnCount = table.tableColumnCount ?? ((columnWidths.keys.max() ?? 0) + 1)
            let natural =
                columnWidths.values.reduce(0, +)
                + Metrics.columnGap * CGFloat(max(0, columnCount - 1))
            // A table wider than the page cannot be gridded — the rows would
            // wrap and the columns would stop lining up anyway. Fall back to a
            // fixed gap after every cell, which at least keeps the words apart
            // instead of running them together.
            let available = (contentWidth ?? theme.contentWidth) - Metrics.codeInset * 2
            let fits = natural <= available

            for (cell, range, width) in measured {
                let column = cell.tableColumn ?? 0
                let isLast = column >= columnCount - 1

                // Slack is how much narrower this cell is than its column;
                // alignment decides where inside the column it sits. The gap
                // to the next column is *separate*, and always trails the
                // cell — fold it into the slack and a right-aligned column
                // spends it on the left, leaving its value flush against the
                // next column's ("12" and "45.00" reading as "1245.00").
                let slack = fits ? max(0, (columnWidths[column] ?? width) - width) : 0
                let gap = isLast ? 0 : Metrics.columnGap

                switch cell.tableAlignment ?? .auto {
                case .right:
                    pad(before: range, by: slack, in: storage, within: tableRange)
                    pad(after: range, by: gap, in: storage, limit: limit)
                case .center:
                    pad(before: range, by: slack / 2, in: storage, within: tableRange)
                    pad(after: range, by: slack / 2 + gap, in: storage, limit: limit)
                case .auto, .left:
                    pad(after: range, by: slack + gap, in: storage, limit: limit)
                }
            }
        }
    }

    /// Whether the `|` opening the table's first cell is collapsed.
    ///
    /// One probe is enough because a table reveals as a whole — see
    /// ``RevealPolicy``. If its first pipe is hidden, all of them are.
    private static func separatorsAreHidden(
        before cell: NSRange,
        in table: NSRange,
        hidden: HiddenRanges
    ) -> Bool {
        guard cell.location > table.location else { return false }
        return hidden.covers(NSRange(location: cell.location - 1, length: 1))
    }

    /// Removes any column padding a live-preview pass left behind.
    @MainActor
    private static func clearTableAlignment(
        _ document: ParsedDocument,
        in storage: NSTextStorage,
        limit: NSRange,
        scope: NSRange
    ) {
        for table in document.blocks where table.kind == .table {
            let range = clamp(table.range, to: limit)
            guard range.length > 0, NSIntersectionRange(range, scope).length > 0 else { continue }
            storage.removeAttribute(.kern, range: range)
        }
    }

    /// The cells of `table`, which follow it contiguously in block order.
    @MainActor
    private static func cells(
        of table: BlockDescriptor,
        from index: Int,
        in document: ParsedDocument,
        limit: NSRange
    ) -> [(BlockDescriptor, NSRange)] {
        let end = table.range.location + table.range.length
        var out: [(BlockDescriptor, NSRange)] = []
        var cursor = index + 1
        while cursor < document.blocks.count {
            let block = document.blocks[cursor]
            guard block.range.location < end else { break }
            if block.kind == .tableCell {
                let range = clamp(block.range, to: limit)
                if range.length > 0 { out.append((block, range)) }
            }
            cursor += 1
        }
        return out
    }

    /// Widens the gap after a cell's last character.
    @MainActor
    private static func pad(
        after range: NSRange,
        by amount: CGFloat,
        in storage: NSTextStorage,
        limit: NSRange
    ) {
        guard amount > 0, range.length > 0 else { return }
        let last = NSRange(location: range.location + range.length - 1, length: 1)
        guard last.location >= 0, last.location + last.length <= limit.length else { return }
        storage.addAttribute(.kern, value: amount, range: last)
    }

    /// Widens the gap before a cell's first character, by kerning the `|` that
    /// precedes it — a character that is hidden in live preview but still very
    /// much in the buffer, and so still able to carry spacing.
    @MainActor
    private static func pad(
        before range: NSRange,
        by amount: CGFloat,
        in storage: NSTextStorage,
        within table: NSRange
    ) {
        guard amount > 0, range.location > table.location else { return }
        storage.addAttribute(
            .kern, value: amount, range: NSRange(location: range.location - 1, length: 1))
    }

    enum Metrics {
        /// Horizontal breathing room inside a code panel or table, so text
        /// does not sit against the border drawn around it.
        static let codeInset: CGFloat = 12
        /// Minimum space between two table columns.
        static let columnGap: CGFloat = 20
        /// Space reserved above a table, so its panel clears whatever line
        /// precedes it once the blank line between them has collapsed.
        static let tableGap: CGFloat = 14
    }

    // MARK: - Helpers

    /// Adds a symbolic trait while keeping the font already in place, so
    /// `**bold**` inside a heading stays heading-sized.
    @MainActor
    private static func addTrait(
        _ trait: NSFontDescriptor.SymbolicTraits,
        to storage: NSTextStorage,
        range: NSRange
    ) {
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let base = (value as? NSFont) ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
            let descriptor = base.fontDescriptor.withSymbolicTraits(
                base.fontDescriptor.symbolicTraits.union(trait))
            if let font = NSFont(descriptor: descriptor, size: base.pointSize) {
                storage.addAttribute(.font, value: font, range: subrange)
            }
        }
    }

    /// Keeps a range inside the storage.
    ///
    /// Ranges arrive from a parse of text that may have changed since, so an
    /// unclamped range would raise an out-of-bounds exception inside a
    /// keystroke rather than merely mis-style a word.
    private static func clamp(_ range: NSRange, to limit: NSRange) -> NSRange {
        let location = min(max(range.location, 0), limit.length)
        let length = min(range.length, limit.length - location)
        return NSRange(location: location, length: max(0, length))
    }
}
