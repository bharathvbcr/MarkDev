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

/// Content drawn *in place of* a block's source text.
public struct RenderedBlock: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case math
        case diagram
        /// Alt text, shown if the file cannot be loaded.
        case image(alt: String)
    }

    public let kind: Kind
    /// The source to render — LaTeX, Mermaid, or an image path.
    public let source: String

    public init(kind: Kind, source: String) {
        self.kind = kind
        self.source = source
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
    /// - Parameter text: the document's text, needed to read the source of a
    ///   block that is replaced by rendered content. Without it, math and
    ///   diagrams fall back to being drawn as code.
    public static func decoration(
        for range: NSRange,
        in document: ParsedDocument,
        text: NSString? = nil
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

        // A standalone image is checked before the innermost-block search.
        // Paragraphs are not decorated blocks in general — treating them as
        // such would let the paragraph inside a callout win the innermost
        // rule and erase the callout's own decoration.
        if let text {
            for block in document.blocks where block.kind == .paragraph {
                guard NSIntersectionRange(block.range, range).length > 0
                    || block.range.contains(range.location)
                else { continue }
                if let image = imageBlock(block, in: document, text: text) {
                    // Only the leading line draws it; see `BlockDecoration.rendered`.
                    return edge(of: range, within: block.range).roundsTop
                        ? .rendered(image) : .none
                }
            }
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
            if let text, let latex = mathSource(of: block, in: text) {
                // Only the leading line draws it; see `BlockDecoration.rendered`.
                return edge.roundsTop
                    ? .rendered(RenderedBlock(kind: .math, source: latex)) : .none
            }
            return .code(edge: edge, language: nil)
        case .mermaidBlock:
            if let text, let source = fencedSource(of: block, in: text) {
                return edge.roundsTop
                    ? .rendered(RenderedBlock(kind: .diagram, source: source)) : .none
            }
            return .code(edge: edge, language: block.info)
        case .codeBlock, .frontmatter:
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

    /// The LaTeX inside a `$$…$$` block.
    private static func mathSource(of block: BlockDescriptor, in text: NSString) -> String? {
        guard let body = clamp(block.range, to: text.length) else { return nil }
        let raw = text.substring(with: body)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = raw
            .trimmingPrefix("$$")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let latex = stripped.hasSuffix("$$")
            ? String(stripped.dropLast(2)) : stripped
        let cleaned = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// The body of a fenced block, without its delimiter lines.
    private static func fencedSource(of block: BlockDescriptor, in text: NSString) -> String? {
        guard let body = clamp(block.range, to: text.length) else { return nil }
        var lines = text.substring(with: body).components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true {
            lines.removeFirst()
        }
        if lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true {
            lines.removeLast()
        }
        let source = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
        return source.isEmpty ? nil : source
    }

    /// An image standing alone in its own paragraph.
    ///
    /// Only whole-paragraph images are replaced. An image sitting inside a
    /// sentence has to stay inline, and swapping it for a block would break
    /// the line it belongs to.
    private static func imageBlock(
        _ block: BlockDescriptor,
        in document: ParsedDocument,
        text: NSString
    ) -> RenderedBlock? {
        let images = document.spans.filter {
            $0.kind == .image && NSIntersectionRange($0.range, block.range).length > 0
        }
        guard images.count == 1, let span = images.first else { return nil }
        guard let source = document.target(for: span), !source.isEmpty else { return nil }

        // The paragraph must be the image and nothing else of substance.
        guard let body = clamp(block.range, to: text.length) else { return nil }
        let paragraph = text.substring(with: body).trimmingCharacters(in: .whitespacesAndNewlines)
        guard paragraph.hasPrefix("!["), paragraph.hasSuffix(")") else { return nil }

        let alt = clamp(span.range, to: text.length).map { text.substring(with: $0) } ?? ""
        return RenderedBlock(kind: .image(alt: alt), source: source)
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
