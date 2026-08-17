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

/// Something drawn *over* a run of a fragment's own text, rather than behind
/// the whole block.
///
/// # Why this is not a `BlockDecoration`
///
/// A block decoration is positioned from the fragment's origin and the text
/// container's width — it does not need to know where any particular glyph
/// is. A checkbox does: it stands in for four specific characters, and the
/// only position that is right for it is the one those characters occupy.
///
/// Deriving it instead from an indent — collapsing the `- [ ]` and drawing the
/// box in the gutter the indent opens up — makes the box's position depend on
/// the origin passed to `draw(at:in:)`, and that origin does not mean the same
/// thing in a detached view rendered with `cacheDisplay` as it does in the
/// running app. An ornament sidesteps that: its rect comes from the glyphs, so
/// it is correct in fragment-local coordinates before any origin is applied.
public enum InlineOrnament: Sendable, Equatable {
    /// A `- [ ]` task marker, drawn as a real checkbox over the literal text.
    case checkbox(range: NSRange, checked: Bool)

    public var range: NSRange {
        switch self {
        case .checkbox(let range, _): range
        }
    }
}

/// Every ornament in one parse, ordered for lookup by fragment.
///
/// # Why this is an index rather than a scan
///
/// ``BlockDecoration/decoration(for:in:)`` scans the block list on every
/// fragment, which is affordable because blocks are few. Spans are not: a long
/// note has tens of thousands, and TextKit asks for a fragment per *line*, so
/// the same scan would be O(lines × spans) and would show up in the editor's
/// per-keystroke budget. Building the list once per parse and binary-searching
/// it keeps the lookup logarithmic.
public struct InlineOrnaments: Sendable, Equatable {
    /// Ascending by location; ornaments never overlap each other.
    private let ornaments: [InlineOrnament]

    public static let empty = InlineOrnaments(ornaments: [])

    private init(ornaments: [InlineOrnament]) {
        self.ornaments = ornaments
    }

    public init(document: ParsedDocument) {
        // Spans arrive in document order, so the checkbox list is already
        // sorted and the search below needs no sort of its own.
        ornaments = document.spans
            .filter { $0.kind == .taskMarker && $0.range.length > 0 }
            .map { .checkbox(range: $0.range, checked: $0.data == 1) }
    }

    /// Every ornament overlapping `range`, in document order.
    public func ornaments(in range: NSRange) -> [InlineOrnament] {
        guard !ornaments.isEmpty, range.length > 0 else { return [] }
        let end = range.location + range.length

        // First ornament that could reach into `range`.
        var low = 0
        var high = ornaments.count
        while low < high {
            let mid = (low + high) / 2
            let candidate = ornaments[mid].range
            if candidate.location + candidate.length <= range.location {
                low = mid + 1
            } else {
                high = mid
            }
        }

        var out: [InlineOrnament] = []
        var index = low
        while index < ornaments.count, ornaments[index].range.location < end {
            out.append(ornaments[index])
            index += 1
        }
        return out
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
