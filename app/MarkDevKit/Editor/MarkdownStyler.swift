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
    /// **A scoped pass writes nothing outside its scope, and everything
    /// inside it.** Every layer is clipped, not merely filtered: a code block
    /// that reaches past the scope used to have its monospace font applied
    /// over its *whole* range while the hidden-marker pass only reapplied the
    /// markers inside the scope — which quietly un-hid the closing fence of a
    /// block the caller never asked about. Callers rely on the other half of
    /// the contract too: text outside the scope keeps the attributes it has,
    /// which `NSTextStorage` has already shifted along with the text.
    ///
    /// Runs inside one `beginEditing`/`endEditing` pair so TextKit relayouts
    /// once rather than once per attribute run.
    @MainActor
    public static func apply(
        document: ParsedDocument,
        hidden: HiddenRanges,
        to storage: NSTextStorage,
        theme: EditorTheme = .standard,
        scope: NSRange? = nil
    ) {
        let full = NSRange(location: 0, length: storage.length)
        guard full.length > 0 else { return }
        let target = clamp(scope ?? full, to: full)
        guard target.length > 0 else { return }

        storage.beginEditing()
        defer { storage.endEditing() }

        applyBase(to: storage, range: target, theme: theme)
        applyBlocks(
            document.blocks, document: document, to: storage, limit: full, scope: target,
            theme: theme)
        applySpans(document.spans, to: storage, limit: full, scope: target, theme: theme)
        applyLinkTargets(document, to: storage, limit: full, scope: target)
        // Marker styling must win over the span attributes it overlaps, or a
        // heading's `# ` would be re-inflated to heading size.
        applyMarkers(
            document, hidden: hidden, to: storage, limit: full, scope: target, theme: theme)
        // Truly last. It measures text the other passes have styled, and its
        // padding rides on characters that `applyMarkers` also touches — that
        // pass zeroes kerning on every collapsed marker, which silently wiped
        // the column padding when this ran before it.
        alignTableColumns(document, to: storage, limit: full, theme: theme)
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

    /// Task-marker ranges, in document order, for answering "is this a task
    /// item" without rescanning every span.
    ///
    /// Built once per styling pass and searched, rather than scanned inside
    /// the block loop. Both list items and spans grow with the document, so
    /// the scan this replaced was O(blocks × spans) — a genuine quadratic
    /// that stayed invisible in the keystroke tests, where the scope is a
    /// block or two, and only showed up on open: 10,000 lines cost 8x what
    /// 2,500 did, against 4x the text.
    private static func taskMarkerRanges(in document: ParsedDocument) -> [NSRange] {
        document.spans
            .lazy
            .filter { $0.kind == .taskMarker }
            .map(\.range)
            .sorted { $0.location < $1.location }
    }

    /// Whether a list item carries a task checkbox.
    ///
    /// - Parameter taskMarkers: ``taskMarkerRanges(in:)`` for this document.
    ///   Task markers never overlap, so sorting by location also sorts by
    ///   end, which is what lets this binary-search.
    private static func isTaskItem(
        _ block: BlockDescriptor, taskMarkers: [NSRange]
    ) -> Bool {
        // The first marker that could still reach into the block: everything
        // before it ends at or before the block starts.
        var low = 0
        var high = taskMarkers.count
        while low < high {
            let mid = low + (high - low) / 2
            if NSMaxRange(taskMarkers[mid]) <= block.range.location {
                low = mid + 1
            } else {
                high = mid
            }
        }
        guard low < taskMarkers.count else { return false }
        // Overlap, matching the intersection test this replaced.
        return taskMarkers[low].location < NSMaxRange(block.range)
    }

    @MainActor
    private static func applyBlocks(
        _ blocks: [BlockDescriptor],
        document: ParsedDocument,
        to storage: NSTextStorage,
        limit: NSRange,
        scope: NSRange,
        theme: EditorTheme
    ) {
        // Built on first use, not up front: a scoped restyle usually covers a
        // block or two, and one holding no list items should not pay to walk
        // the document's spans at all.
        var taskMarkers: [NSRange]?

        for block in blocks {
            let range = NSIntersectionRange(clamp(block.range, to: limit), scope)
            guard range.length > 0 else { continue }

            switch block.kind {
            case .codeBlock, .mermaidBlock, .mathBlock, .frontmatter:
                storage.addAttributes(
                    [.font: theme.monoFont, .backgroundColor: theme.codeBackground],
                    range: range
                )
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
                var indent = CGFloat(block.depth) * 8 + 16
                // A task item needs a gutter for its drawn checkbox, since
                // the `- [ ]` it replaces has been collapsed to nothing.
                let markers: [NSRange]
                if let built = taskMarkers {
                    markers = built
                } else {
                    markers = taskMarkerRanges(in: document)
                    taskMarkers = markers
                }
                if isTaskItem(block, taskMarkers: markers) {
                    indent += MarkdownLayoutFragment.Metrics.checkboxGutter
                }
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
            let range = NSIntersectionRange(clamp(span.range, to: limit), scope)
            guard range.length > 0 else { continue }

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
                storage.addAttributes(
                    [
                        .font: theme.monoFont,
                        .foregroundColor: theme.codeColor,
                        .backgroundColor: theme.codeBackground,
                    ],
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
        for span in document.spans where span.kind == .wikiLink {
            let range = NSIntersectionRange(clamp(span.range, to: limit), scope)
            guard range.length > 0 else { continue }
            guard let target = document.target(for: span) else { continue }
            guard
                let encoded = target.addingPercentEncoding(
                    withAllowedCharacters: .urlPathAllowed),
                let url = URL(string: "\(MarkdownStyler.wikiLinkScheme)://\(encoded)")
            else { continue }
            storage.addAttribute(.link, value: url, range: range)
        }
    }

    /// URL scheme used to carry a wikilink target through AppKit's link
    /// machinery. Never registered with the system — it exists only so
    /// `clickedOnLink` can recognise its own links.
    public static let wikiLinkScheme = "markdev-wiki"

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
            let full = clamp(marker.range, to: limit)
            let range = NSIntersectionRange(full, scope)
            guard range.length > 0, !hidden.covers(full) else { continue }
            storage.addAttribute(.foregroundColor, value: theme.markerColor, range: range)
        }

        // Hidden markers: shrunk to nothing but still present in storage.
        for range in hidden.ranges {
            let clamped = NSIntersectionRange(clamp(range, to: limit), scope)
            guard clamped.length > 0 else { continue }
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

extension MarkdownStyler {
    /// Aligns a GFM table's columns.
    ///
    /// # Why kerning rather than tab stops
    ///
    /// The text is never rewritten — MarkDev's whole invariant is that the
    /// buffer holds the real Markdown — so the `|` separators are still
    /// there, merely collapsed. Tab stops would need tab characters that do
    /// not exist. Instead each collapsed pipe is given exactly enough kerning
    /// to carry the next cell to its column, which turns the separators the
    /// document already has into the spacing the table needs.
    ///
    /// Cells are measured as they are actually styled, so a bold or code cell
    /// widens its column rather than overflowing it — which is also why this
    /// runs after every other pass.
    @MainActor
    static func alignTableColumns(
        _ document: ParsedDocument,
        to storage: NSTextStorage,
        limit: NSRange,
        theme: EditorTheme
    ) {
        let tables = document.blocks.filter { $0.kind == .table }

        guard !tables.isEmpty else { return }

        for table in tables {
            let rows = document.blocks.filter {
                $0.kind == .tableRow || $0.kind == .tableHead
            }.filter { NSIntersectionRange($0.range, table.range).length > 0 }
            guard rows.count > 1 else { continue }

            // Cells, grouped by row and ordered across each one.
            let cellsByRow: [[BlockDescriptor]] = rows.map { row in
                document.blocks
                    .filter {
                        $0.kind == .tableCell
                            && NSIntersectionRange($0.range, row.range).length > 0
                    }
                    .sorted { $0.range.location < $1.range.location }
            }

            // Clear the padding this pass is about to recompute, before
            // anything is measured.
            //
            // The kern rides on the cell's last character and `measure`
            // measures the cell *including* that character, so without this
            // the pass reads back its own previous padding and adds to it.
            // The restyle scope cannot be relied on to have cleared it: this
            // layer alone writes across the whole document — one cell's width
            // can decide a column far outside the scope — so it has to clear
            // what it is about to rewrite. Zero rather than removed, matching
            // what `applyMarkers` leaves on a collapsed marker, so an
            // incrementally styled document and a freshly parsed one carry
            // the same attributes.
            for cells in cellsByRow {
                for cell in cells {
                    guard let last = lastCharacter(of: cell.range, in: limit) else { continue }
                    storage.addAttribute(.kern, value: 0, range: last)
                }
            }

            // Widest cell per column decides that column's width.
            var columnWidths: [CGFloat] = []
            for cells in cellsByRow {
                for (index, cell) in cells.enumerated() {
                    let width = measure(cell.range, in: storage, limit: limit)
                    if index < columnWidths.count {
                        columnWidths[index] = max(columnWidths[index], width)
                    } else {
                        columnWidths.append(width)
                    }
                }
            }
            guard !columnWidths.isEmpty else { continue }

            for cells in cellsByRow {
                for (index, cell) in cells.enumerated() where index < columnWidths.count {
                    let width = measure(cell.range, in: storage, limit: limit)
                    let padding = max(columnWidths[index] - width, 0) + Metrics.cellGap

                    // The kern rides on the cell's final character, so the
                    // gap lands between this cell and the next.
                    guard let last = lastCharacter(of: cell.range, in: limit) else { continue }
                    storage.addAttribute(.kern, value: padding, range: last)
                }
            }
        }
    }

    /// Rendered width of a range, as currently styled.
    @MainActor
    private static func measure(
        _ range: NSRange, in storage: NSTextStorage, limit: NSRange
    ) -> CGFloat {
        let clamped = clamp(range, to: limit)
        guard clamped.length > 0 else { return 0 }
        let substring = storage.attributedSubstring(from: clamped)
        return ceil(substring.size().width)
    }

    private static func lastCharacter(of range: NSRange, in limit: NSRange) -> NSRange? {
        let clamped = clamp(range, to: limit)
        guard clamped.length > 0 else { return nil }
        return NSRange(location: clamped.location + clamped.length - 1, length: 1)
    }

    enum Metrics {
        /// Breathing room between columns, on top of the widest cell.
        static let cellGap: CGFloat = 18
    }
}
