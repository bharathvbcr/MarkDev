//
//  MarkdownStyler.swift
//  MarkDevKit
//
//  Applies a parse result to an NSTextStorage.
//

import AppKit

extension NSAttributedString.Key {
    /// Marks a run of inline code so the layout fragment can draw a pill
    /// behind it.
    ///
    /// A private key rather than `.backgroundColor` because the two are not
    /// the same shape: AppKit's background fills the line's full height, edge
    /// to edge, which reads as a slab rather than as a code span — and in a
    /// heading it collides with the lines around it. Everything the styler
    /// knows is still expressed as an attribute, so the drawing layer stays a
    /// pure function of text storage.
    public static let inlineCodeRun = NSAttributedString.Key("dev.markdev.inlineCode")
}

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
    ///
    /// - Returns: the range this pass actually wrote — `scope` grown to whole
    ///   lines. **A later attribute layer must scope itself to this, not to
    ///   the range it asked for.** The pass opens by clearing `setAttributes`
    ///   over the grown range, so a layer that reapplies its own attributes
    ///   over the *requested* range leaves whatever the growth reached erased.
    ///   The growth reaches both ways, and a code fence a line off the scope
    ///   in either direction lost its tree-sitter colours exactly this way —
    ///   and kept them lost, since nothing revisits a block the next edit does
    ///   not touch.
    @MainActor
    @discardableResult
    public static func apply(
        document: ParsedDocument,
        hidden: HiddenRanges,
        to storage: NSTextStorage,
        theme: EditorTheme = .standard,
        scope: NSRange? = nil
    ) -> NSRange {
        let empty = NSRange(location: 0, length: 0)
        let full = NSRange(location: 0, length: storage.length)
        guard full.length > 0 else { return empty }
        // Grown to whole lines. Paragraph attributes are a property of a line
        // — TextKit lays one out with the style of its first character — so a
        // scope ending mid-line would leave that line's style decided by
        // whichever half the edit happened to reach. Line-aligning it here
        // also means every pass below can treat "touches the scope" and "is
        // wholly inside it" as the same question about a line.
        let target = wholeLines(
            clamp(scope ?? full, to: full), in: storage.string as NSString, limit: full)
        guard target.length > 0 else { return empty }

        storage.beginEditing()
        defer { storage.endEditing() }

        applyBase(to: storage, range: target, theme: theme)
        applyBlocks(
            document.blocks, document: document, to: storage, limit: full, scope: target,
            theme: theme)
        applyBlockSpacing(document.blocks, to: storage, limit: full, scope: target, theme: theme)
        applySpans(document.spans, to: storage, limit: full, scope: target, theme: theme)
        applyLinkTargets(document, to: storage, limit: full, scope: target)
        // Marker styling must win over the span attributes it overlaps, or a
        // heading's `# ` would be re-inflated to heading size.
        applyMarkers(
            document, hidden: hidden, to: storage, limit: full, scope: target, theme: theme)
        // After the markers, because it asks what they left visible.
        collapseFullyHiddenLines(hidden: hidden, in: storage, limit: full, scope: target)
        return target
    }

    // MARK: - Layers

    @MainActor
    private static func applyBase(
        to storage: NSTextStorage, range: NSRange, theme: EditorTheme
    ) {
        // No paragraph spacing here: `NSParagraphStyle` ends a paragraph at
        // every newline, and a Markdown paragraph is routinely hard-wrapped
        // across several of them. Spacing set here opens a 12pt gap in the
        // middle of one sentence, so a wrapped README reads as double-spaced.
        // ``applyBlockSpacing`` puts it back where it belongs — the last line
        // of each block.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = theme.lineSpacing

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
        let text = storage.string as NSString

        for block in blocks {
            // Paragraph attributes are decided per *line*: TextKit lays a line
            // out with the style of its first character. A nested list item's
            // parsed range begins after the spaces that indent it, so applying
            // its indent to that range alone left the line reading the style
            // of the item it is nested in — every nested list came out one
            // level short.
            //
            // A block therefore counts as in scope when any of *its lines* is,
            // not merely when its own range is: an item that begins two spaces
            // into a line the scope starts at would otherwise sit out the
            // pass, leaving the enclosing quote's indent on a line the item
            // owns. Writes are still clipped to the scope, and the scope is
            // whole lines, so every line inside it ends up styled by exactly
            // the blocks a full pass would have used, in the same order.
            let lines = NSIntersectionRange(
                lineAligned(clamp(block.range, to: limit), in: text, limit: limit), scope)
            guard lines.length > 0 else { continue }
            let range = NSIntersectionRange(clamp(block.range, to: limit), scope)

            switch block.kind {
            case .codeBlock, .mermaidBlock, .mathBlock, .frontmatter:
                // No `.backgroundColor`: the panel is drawn by
                // ``MarkdownLayoutFragment``, which reaches the text
                // container's edge. A character background stops where each
                // line's text does, so painting both stacks a second, ragged
                // tint on top of the panel — one darker box per line, ending
                // mid-air.
                let paragraph = NSMutableParagraphStyle()
                // Code sits tighter than prose: a listing is read as a block,
                // and body leading between its lines makes a five-line fence
                // as tall as a paragraph.
                paragraph.lineSpacing = theme.codeLineSpacing
                paragraph.firstLineHeadIndent = MarkdownLayoutFragment.Metrics.panelInset
                paragraph.headIndent = MarkdownLayoutFragment.Metrics.panelInset
                // Negative: measured in from the trailing margin, so a long
                // line wraps inside the panel rather than against its edge.
                paragraph.tailIndent = -MarkdownLayoutFragment.Metrics.panelInset
                storage.addAttribute(.font, value: theme.monoFont, range: range)
                storage.addAttribute(.paragraphStyle, value: paragraph, range: lines)
            case .tableRow, .tableHead:
                // The same inset a code panel gives its text: a row's shading
                // reaches the container's edge, so without it the first
                // column's letters sit on the panel's border.
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = theme.lineSpacing
                paragraph.firstLineHeadIndent = MarkdownLayoutFragment.Metrics.panelInset
                paragraph.headIndent = MarkdownLayoutFragment.Metrics.panelInset
                storage.addAttribute(.paragraphStyle, value: paragraph, range: lines)
            case .blockQuote, .callout:
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = theme.lineSpacing
                paragraph.firstLineHeadIndent = 16
                paragraph.headIndent = 16
                storage.addAttribute(.foregroundColor, value: theme.quoteColor, range: range)
                storage.addAttribute(.paragraphStyle, value: paragraph, range: lines)
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
                storage.addAttribute(.paragraphStyle, value: paragraph, range: lines)
            default:
                break
            }
        }
    }

    /// Puts paragraph spacing on the last line of each top-level block.
    ///
    /// Spacing belongs to a *block*, not to a line. Markdown paragraphs are
    /// routinely hard-wrapped, and `NSParagraphStyle` treats every newline as
    /// the end of a paragraph — so spacing applied in the base pass opens the
    /// gap inside a sentence and makes ordinary prose read as double-spaced.
    ///
    /// Top-level blocks only: a list item's spacing is the list's business,
    /// and paying it per item turns a tight list into a spaced one.
    @MainActor
    private static func applyBlockSpacing(
        _ blocks: [BlockDescriptor],
        to storage: NSTextStorage,
        limit: NSRange,
        scope: NSRange,
        theme: EditorTheme
    ) {
        guard theme.paragraphSpacing > 0 else { return }
        let text = storage.string as NSString

        for block in topLevel(blocks) {
            // Cheapest test first: a block the scope cannot reach is skipped
            // before it costs a line lookup. This pass walks every block in
            // the document, and it runs on the keystroke path.
            guard NSIntersectionRange(clamp(block.range, to: limit), scope).length > 0
            else { continue }
            // A block that paints a panel already carries its own padding,
            // and spacing on its last line would be drawn *inside* the panel:
            // the fragment's frame is what the background covers, and the gap
            // is part of that frame. Its separation is the panel's margins.
            guard !drawsPanel(block.kind) else { continue }
            let clamped = clamp(block.range, to: limit)
            // Nothing to add where the document already leaves a blank line —
            // that line is real, the reader typed it and can put the caret in
            // it, and spacing on top of it is the same gap counted twice.
            guard !isFollowedByBlankLine(clamped, in: text) else { continue }
            // The block's last line, whole: a line is laid out with the style
            // of its first character, so spacing written onto the final
            // character alone would simply not be read.
            // The block's last line, whole: a line is laid out with the style
            // of its first character, so spacing written onto the final
            // character alone would simply not be read. The scope covers whole
            // lines, so a line it touches at all is a line it holds entirely.
            let last = clamp(
                text.lineRange(for: NSRange(location: NSMaxRange(clamped) - 1, length: 0)),
                to: limit)
            let range = NSIntersectionRange(last, scope)
            guard range.length == last.length else { continue }

            // Extends whatever that line already carries — a list's spacing
            // has to keep the list's indent, or the last item jumps left.
            let base = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
                as? NSParagraphStyle
            let paragraph = (base?.mutableCopy() as? NSMutableParagraphStyle)
                ?? NSMutableParagraphStyle()
            paragraph.paragraphSpacing = theme.paragraphSpacing
            storage.addAttribute(.paragraphStyle, value: paragraph, range: range)
        }
    }

    /// `range` grown outwards to whole lines, plus the line after it.
    ///
    /// Used for the pass's scope, where both ends have to move: a line that is
    /// half in scope is a line whose style depends on where an edit happened
    /// to stop.
    ///
    /// The extra line at each end is not slack — a line's style depends on its
    /// neighbours in both directions:
    ///
    /// - **Forwards.** An edit that inserts a newline pushes the characters
    ///   after it onto the *following* line, and a line's style is decided by
    ///   its first character, so that pushed character arrives wearing the
    ///   style of the line it used to end. It is how a blank line after a
    ///   fence kept the code block's indent.
    /// - **Backwards.** A block's spacing is written on its last line and
    ///   decided by whether a blank line follows it, so typing on a line
    ///   changes the gap belonging to the line before it.
    ///
    /// Two lines is a fixed cost; the alternative is a stale line at whichever
    /// end of the scope the edit happened to land on.
    private static func wholeLines(
        _ range: NSRange, in text: NSString, limit: NSRange
    ) -> NSRange {
        guard range.length > 0, NSMaxRange(range) <= text.length else { return range }
        var start = text.lineRange(for: NSRange(location: range.location, length: 0)).location
        if start > 0 {
            start = text.lineRange(for: NSRange(location: start - 1, length: 0)).location
        }
        var end = NSMaxRange(
            text.lineRange(for: NSRange(location: NSMaxRange(range) - 1, length: 0)))
        if end < text.length {
            end = NSMaxRange(text.lineRange(for: NSRange(location: end, length: 0)))
        }
        return clamp(NSRange(location: start, length: end - start), to: limit)
    }

    /// `range` grown back to the head of the line it starts on, held inside
    /// the document.
    ///
    /// Only the *start* moves. TextKit reads a line's style from its first
    /// character, so reaching back to the line's head is what makes the style
    /// count; reaching forward would hand the block's style to the line that
    /// follows it, which is another block's — or nobody's.
    ///
    /// **Held inside the document, not inside the scope.** This is the one
    /// deliberate exception to "a scoped pass writes only inside its scope",
    /// and it is bounded to the head of one line. Clipping it instead leaves that line's *first* character wearing
    /// the previous parse's style while the rest of the line gets the new one
    /// — and since the first character is the one TextKit lays the line out
    /// from, the stale half wins: a list item nested in a quote kept the
    /// quote's indent. The value written is the current parse's answer for a
    /// line the block owns, so writing it over the whole line is what a full
    /// restyle would have done anyway.
    private static func lineAligned(
        _ range: NSRange, in text: NSString, limit: NSRange
    ) -> NSRange {
        guard range.length > 0, NSMaxRange(range) <= text.length else { return range }
        let first = text.lineRange(for: NSRange(location: range.location, length: 0))
        return clamp(
            NSRange(location: first.location, length: NSMaxRange(range) - first.location),
            to: limit)
    }

    /// Whether a block is drawn on a background of its own.
    private static func drawsPanel(_ kind: BlockKind) -> Bool {
        switch kind {
        case .codeBlock, .mermaidBlock, .mathBlock, .frontmatter, .callout, .blockQuote, .table:
            true
        default:
            false
        }
    }

    /// Whether the line after `range`'s last line is empty.
    ///
    /// A block's parsed range sometimes takes in the blank line that follows
    /// it and sometimes stops at its own text, so this asks about the line
    /// after the block's *last* one either way.
    private static func isFollowedByBlankLine(_ range: NSRange, in text: NSString) -> Bool {
        guard range.length > 0, NSMaxRange(range) <= text.length else { return false }
        let last = text.lineRange(for: NSRange(location: NSMaxRange(range) - 1, length: 0))
        // The block's own last line is already blank when its range swallowed
        // the separator.
        if HiddenRanges.contentRange(of: last, in: text).length == 0 { return true }
        guard NSMaxRange(last) < text.length else { return false }
        let next = text.lineRange(for: NSRange(location: NSMaxRange(last), length: 0))
        return HiddenRanges.contentRange(of: next, in: text).length == 0
    }

    /// The blocks no other block contains, in document order.
    ///
    /// A linear sweep rather than a containment test per pair: blocks arrive
    /// sorted by start offset with parents before their children, so a block
    /// starting at or after the current top-level block's end is the next
    /// top-level one.
    private static func topLevel(_ blocks: [BlockDescriptor]) -> [BlockDescriptor] {
        var result: [BlockDescriptor] = []
        var end = Int.min
        for block in blocks where block.range.length > 0 {
            guard block.range.location >= end else { continue }
            result.append(block)
            end = NSMaxRange(block.range)
        }
        return result
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
                // Marked, not tinted. `.backgroundColor` paints a rectangle
                // the full height of the *line*, so a code word in a heading
                // gets a slab that touches the line above it and the one
                // below. ``MarkdownLayoutFragment`` draws a pill around the
                // run instead, sized to the type rather than to the leading.
                storage.addAttributes(
                    [
                        .font: theme.monoFont,
                        .foregroundColor: theme.codeColor,
                        .inlineCodeRun: true,
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

    /// Takes the height back off lines that are nothing but hidden syntax.
    ///
    /// Collapsing a marker shrinks its *characters*; the line they sat on is
    /// still a line, and it still carries the newline that ends it at full
    /// size. A fenced block's ```` ``` ```` lines are exactly that — once
    /// hidden, each leaves a blank the height of a line of code at the top and
    /// bottom of the panel, and a GFM alert leaves one where its `[!NOTE]`
    /// used to be. The characters stay in storage, as every collapsed marker
    /// does; only their metrics go.
    ///
    /// Whole lines only, and only lines that lie entirely inside the scope: a
    /// half-collapsed line would be a line whose height depended on where an
    /// edit happened to reach.
    @MainActor
    private static func collapseFullyHiddenLines(
        hidden: HiddenRanges,
        in storage: NSTextStorage,
        limit: NSRange,
        scope: NSRange
    ) {
        guard !hidden.ranges.isEmpty else { return }
        let text = storage.string as NSString
        let font = NSFont.systemFont(ofSize: EditorTheme.hiddenMarkerFontSize)

        var previousLine = NSRange(location: NSNotFound, length: 0)
        for range in hidden.ranges {
            let clamped = NSIntersectionRange(clamp(range, to: limit), scope)
            guard clamped.length > 0 else { continue }

            // Every line the run touches, not only the one it starts on: a
            // closing fence's marker begins on the *previous* line's newline,
            // so keying off its start alone left every closing ``` holding a
            // line's worth of blank at the foot of the panel.
            var cursor = clamped.location
            while cursor < NSMaxRange(clamped) {
                let line = text.lineRange(for: NSRange(location: cursor, length: 0))
                cursor = max(NSMaxRange(line), cursor + 1)
                guard !NSEqualRanges(line, previousLine) else { continue }
                previousLine = line
                // Whole lines only — a half-collapsed line would be a line
                // whose height depended on where an edit happened to reach.
                // Scope decides *whether* to look, never how much to write.
                guard NSIntersectionRange(line, scope).length > 0 else { continue }

                // The same question the editor asks before drawing a label in
                // the line's place, asked in the one place that answers it.
                guard hidden.hidesWholeLine(at: line.location, in: text) else { continue }
                collapse(line: line, in: storage, font: font)
            }
        }
    }

    /// Takes the leading off one line, keeping the gap that follows its block.
    @MainActor
    private static func collapse(line: NSRange, in storage: NSTextStorage, font: NSFont) {
        storage.addAttributes(
            [.font: font, .foregroundColor: NSColor.clear, .kern: 0], range: line)

        // The leading goes; the spacing *after* the block does not. A fenced
        // block ends on a line that is pure syntax, so dropping everything
        // here would take the gap between the panel and the paragraph below
        // it as well.
        let existing = storage.attribute(
            .paragraphStyle, at: line.location, effectiveRange: nil) as? NSParagraphStyle
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = existing?.paragraphSpacing ?? 0
        storage.addAttribute(.paragraphStyle, value: paragraph, range: line)
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
