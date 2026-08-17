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

    /// Whether this decoration paints a background the text sits on.
    public var hasBackground: Bool {
        switch self {
        case .none, .rule: false
        case .code, .callout, .quote: true
        }
    }
}

extension BlockDecoration {
    /// The decoration for the fragment covering `range`.
    ///
    /// Resolved from the innermost decorated block containing the range, so a
    /// code fence inside a callout draws as code rather than as the callout
    /// it sits in.
    public static func decoration(
        for range: NSRange,
        in document: ParsedDocument
    ) -> BlockDecoration {
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
        case .codeBlock, .mermaidBlock, .mathBlock, .frontmatter:
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
