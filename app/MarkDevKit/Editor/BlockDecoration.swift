//
//  BlockDecoration.swift
//  MarkDevKit
//
//  What to draw behind a block, decided without touching a view.
//

import Foundation

/// Where a line sits within its block.
///
/// A fenced code block spans several lines, and TextKit lays out one fragment
/// per line — so the rounded background has to be drawn in pieces that join
/// up. Each fragment needs to know which piece it is.
public enum BlockEdge: Sendable, Equatable {
    /// The block occupies a single line.
    case only
    case first
    case middle
    case last

    public var roundsTop: Bool { self == .only || self == .first }
    public var roundsBottom: Bool { self == .only || self == .last }
}

extension CalloutKind {
    /// The alert's name, drawn where its `[!NOTE]` line was collapsed.
    ///
    /// Without it the flavour survives only as a tint, and "is this a warning
    /// or a caution" becomes a question about two shades of orange-red.
    public var title: String {
        switch self {
        case .note: "NOTE"
        case .tip: "TIP"
        case .important: "IMPORTANT"
        case .warning: "WARNING"
        case .caution: "CAUTION"
        }
    }
}

/// Decoration drawn behind or in place of a block's text.
public enum BlockDecoration: Sendable, Equatable {
    case none
    /// Fenced or indented code. `language` labels the first line.
    case code(edge: BlockEdge, language: String?)
    /// A GFM alert, tinted by kind.
    case callout(kind: CalloutKind, edge: BlockEdge)
    case quote(edge: BlockEdge)
    /// A thematic break, drawn as a line in place of its `---`.
    case rule
    /// A block replaced by rendered content: a formula, a diagram, an image.
    ///
    /// Carried by the block's **leading** fragment only. TextKit lays out one
    /// fragment per line, so a fence answering `.rendered` for every line of
    /// its source draws the whole picture once per line and pays its full
    /// height each time: a four-line Mermaid fence rendered as four stacked
    /// copies of the same diagram. The remaining lines are collapsed syntax
    /// and decorate as `.none`.
    case rendered(RenderedBlock)
    /// A task list item, whose `[ ]` is drawn as a checkbox.
    case task(checked: Bool)
    /// A GFM table row. `isHeader` shades the first row.
    case tableRow(isHeader: Bool, isLast: Bool)

    /// Whether this decoration paints a background the text sits on.
    public var hasBackground: Bool {
        switch self {
        case .none, .rule, .rendered, .task: false
        case .code, .callout, .quote, .tableRow: true
        }
    }

    /// Whether the checkbox is ticked, for a task item.
    public var taskChecked: Bool? {
        if case .task(let checked) = self { return checked }
        return nil
    }

    /// The content standing in for the block's text, if any.
    public var rendered: RenderedBlock? {
        if case .rendered(let block) = self { return block }
        return nil
    }
}

extension BlockDecoration {
    /// The decoration for the fragment covering `range`.
    ///
    /// Resolved from the innermost decorated block containing the range, so a
    /// code fence inside a callout draws as code rather than as the callout
    /// it sits in.
    ///
    /// - Parameters:
    ///   - rendered: the document's blocks that draw content in place of their
    ///     source, from ``RenderedBlocks``.
    ///   - hidden: what is collapsed right now. Rendered content is drawn
    ///     **only** where the source it replaces is entirely invisible, which
    ///     is the whole reason this takes the caret's consequences as an
    ///     argument. Defaulting both to "nothing" means a caller that forgets
    ///     them gets the document's own source drawn — the direction that
    ///     shows the reader their text rather than hides it.
    public static func decoration(
        for range: NSRange,
        in document: ParsedDocument,
        rendered: RenderedBlocks = .none,
        hidden: HiddenRanges = .none
    ) -> BlockDecoration {
        // A task item is resolved first: its `- [x]` sits inside a list item
        // whose own decoration would otherwise win.
        if let task = taskItem(for: range, in: document) {
            return task
        }

        // Table rows likewise: the row is what draws, not the table around it.
        if let row = tableRow(for: range, in: document) {
            return row
        }

        // A block replaced by content, checked before the innermost-block
        // search. A standalone image lives in a *paragraph*, and paragraphs are
        // not decorated blocks in general — treating them as such would let the
        // paragraph inside a callout win the innermost rule and erase the
        // callout's own decoration.
        if let entry = rendered.entry(overlapping: range) {
            if let piece = renderedPiece(of: entry, at: range, hidden: hidden) {
                return piece
            }
            // Source visible: fall through and draw the block as what it is.
        }

        var best: (block: BlockDescriptor, length: Int)?

        for block in document.blocks {
            guard decorates(block.kind) else { continue }
            guard NSIntersectionRange(block.range, range).length > 0 || block.range.contains(range.location)
            else { continue }
            // Innermost wins: the shortest containing block.
            if best == nil || block.range.length < best!.length {
                best = (block, block.range.length)
            }
        }

        guard let block = best?.block else { return .none }
        let edge = edge(of: range, within: block.range)

        switch block.kind {
        case .mathBlock:
            // `$$…$$` while its source is on screen: a fence in all but name,
            // and it reads as one. The formula is drawn only once the source
            // has gone, which is ``renderedPiece(of:at:hidden:)`` above.
            return .code(edge: edge, language: nil)
        case .codeBlock, .mermaidBlock, .frontmatter:
            return .code(edge: edge, language: block.info)
        case .callout:
            return .callout(kind: block.calloutKind ?? .note, edge: edge)
        case .blockQuote:
            return .quote(edge: edge)
        case .rule:
            return .rule
        default:
            return .none
        }
    }

    private static func decorates(_ kind: BlockKind) -> Bool {
        switch kind {
        case .codeBlock, .mermaidBlock, .mathBlock, .frontmatter, .callout, .blockQuote, .rule:
            true
        default:
            false
        }
    }

    /// What the fragment at `range` draws for a block that renders as content,
    /// or `nil` if that block's source is on screen and should be drawn as it
    /// is written.
    ///
    /// Two conditions, and both are load-bearing:
    ///
    /// - **The source must be entirely collapsed.** Content is drawn *in place
    ///   of* the text, not over it. Drawing both put a full-size diagram under
    ///   every line of its own source, which is what made a mermaid fence
    ///   impossible to read or edit in source mode — the code was on screen,
    ///   separated by three hundred points of picture per line.
    /// - **Only the block's first piece draws it.** TextKit lays out one
    ///   fragment per line, so a five-line fence is five fragments; each one
    ///   holding the whole block's content reserved five diagrams' worth of
    ///   height and stacked five copies down the page. The rest draw nothing,
    ///   which costs them nothing: a line of pure collapsed syntax has no
    ///   height left to give.
    private static func renderedPiece(
        of entry: RenderedBlocks.Entry, at range: NSRange, hidden: HiddenRanges
    ) -> BlockDecoration? {
        guard hidden.covers(entry.range) else { return nil }
        guard range.length > 0, edge(of: range, within: entry.range).roundsTop else {
            return BlockDecoration.none
        }
        return .rendered(entry.content)
    }

    /// The task decoration for a fragment holding a `- [ ]` marker.
    private static func taskItem(
        for range: NSRange, in document: ParsedDocument
    ) -> BlockDecoration? {
        let marker = document.spans.first { span in
            span.kind == .taskMarker && NSIntersectionRange(span.range, range).length > 0
        }
        guard let marker else { return nil }
        return .task(checked: marker.data == 1)
    }

    /// The row decoration for a fragment inside a GFM table.
    ///
    /// Resolved per row rather than per table: TextKit lays out one fragment
    /// per line, so the table's shading and rules have to be drawn a row at a
    /// time, and only the row knows whether it is the header.
    private static func tableRow(
        for range: NSRange, in document: ParsedDocument
    ) -> BlockDecoration? {
        guard let table = document.blocks.first(where: {
            $0.kind == .table && NSIntersectionRange($0.range, range).length > 0
        }) else { return nil }

        let head = document.blocks.first { $0.kind == .tableHead }
        let isHeader = head.map { NSIntersectionRange($0.range, range).length > 0 } ?? false
        let tableEnd = table.range.location + table.range.length
        let isLast = range.location + range.length >= tableEnd

        return .tableRow(isHeader: isHeader, isLast: isLast)
    }

    private static func clamp(_ range: NSRange, to length: Int) -> NSRange? {
        let location = min(max(range.location, 0), length)
        let size = min(range.length, length - location)
        return size > 0 ? NSRange(location: location, length: size) : nil
    }

    /// Which piece of a multi-line block `range` covers.
    static func edge(of range: NSRange, within block: NSRange) -> BlockEdge {
        let blockEnd = block.location + block.length
        let rangeEnd = range.location + range.length
        // A fragment's range includes its trailing newline, so "reaches the
        // end" has to allow for the block ending on the same line.
        let atStart = range.location <= block.location
        let atEnd = rangeEnd >= blockEnd

        switch (atStart, atEnd) {
        case (true, true): return .only
        case (true, false): return .first
        case (false, true): return .last
        case (false, false): return .middle
        }
    }
}
