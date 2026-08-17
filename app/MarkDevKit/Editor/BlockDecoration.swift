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

/// Which part of a table a line belongs to.
public enum TableRole: Sendable, Equatable {
    case header
    /// The `|---|---:|` line. Entirely syntax — it carries the rule drawn
    /// under the header rather than any content of its own.
    case separator
    /// A body row, numbered from zero so alternate rows can be tinted.
    case body(row: Int)
}

/// Decoration drawn behind or in place of a block's text.
public enum BlockDecoration: Sendable, Equatable {
    case none
    /// Fenced or indented code. `language` labels the panel; `isDiagram`
    /// marks a Mermaid fence, whose content is a picture rather than a
    /// program and so earns the pop-out affordance most.
    case code(edge: BlockEdge, language: String?, isDiagram: Bool)
    /// A GFM alert, tinted by kind.
    case callout(kind: CalloutKind, edge: BlockEdge)
    case quote(edge: BlockEdge)
    /// A thematic break, drawn as a line in place of its `---`.
    case rule
    /// One line of a table. `edge` is measured against the *whole* table, so
    /// only the first and last lines round their corners.
    case table(edge: BlockEdge, role: TableRole)

    /// Whether this decoration paints a background the text sits on.
    public var hasBackground: Bool {
        switch self {
        case .none, .rule: false
        case .code, .callout, .quote, .table: true
        }
    }
}

/// Something drawn over an inline run rather than behind a whole block.
///
/// Block decoration answers "what is this line", which one enum value per
/// fragment can express. Ornaments answer "what is *inside* this line", of
/// which there may be several — a sentence can hold two tags and a code span.
/// Keeping them separate is what stops the block enum growing a case per
/// inline construct.
public enum InlineOrnament: Sendable, Equatable {
    /// A `- [ ]` task marker, drawn as a real checkbox over the literal text.
    case checkbox(range: NSRange, checked: Bool)
    /// `` `inline code` ``, drawn as a rounded pill.
    case codePill(range: NSRange)
    /// A `#tag`, drawn as a rounded pill.
    case tagPill(range: NSRange)

    public var range: NSRange {
        switch self {
        case .checkbox(let range, _), .codePill(let range), .tagPill(let range): range
        }
    }
}

/// Precomputed decoration for one parse.
///
/// # Why this is an index rather than a search
///
/// TextKit asks for a fragment per *line*, so any lookup that scans the block
/// list is O(blocks) per line and O(document²) overall — which a 10,000-line
/// note notices. Blocks are flattened once, into disjoint segments ordered by
/// position, and every query after that is a binary search.
///
/// Flattening also settles nesting for free: blocks arrive outermost-first, so
/// painting each one over the last leaves the innermost in place. A code fence
/// inside a callout draws as code because it was painted second, not because
/// anything compares lengths.
public struct DocumentDecorations: Sendable {
    /// A stretch of the document governed by one decoration.
    private struct Segment: Sendable {
        /// The area this payload governs, after inner blocks have overpainted
        /// their parts of it. Disjoint from every other segment.
        var range: NSRange
        /// The owning block's full extent, which is what edges are measured
        /// against — a table's last row must round the *table's* bottom, not
        /// its own.
        let blockRange: NSRange
        let payload: Payload
    }

    private enum Payload: Sendable, Equatable {
        case code(language: String?, isDiagram: Bool)
        case callout(CalloutKind)
        case quote
        case rule
        case table(TableRole)
    }

    /// Disjoint, ascending by location.
    private let segments: [Segment]
    /// Ascending by location; ornaments never overlap each other.
    private let ornaments: [InlineOrnament]

    public static let empty = DocumentDecorations(document: .empty)

    public init(document: ParsedDocument) {
        segments = Self.flatten(document.blocks)
        ornaments = Self.ornaments(in: document.spans)
    }

    // MARK: - Queries

    /// The decoration for the fragment covering `range`.
    public func decoration(for range: NSRange) -> BlockDecoration {
        guard let segment = segment(containing: range.location) else { return .none }
        let edge = BlockDecoration.edge(of: range, within: segment.blockRange)

        switch segment.payload {
        case .code(let language, let isDiagram):
            return .code(edge: edge, language: language, isDiagram: isDiagram)
        case .callout(let kind):
            return .callout(kind: kind, edge: edge)
        case .quote:
            return .quote(edge: edge)
        case .rule:
            return .rule
        case .table(let role):
            return .table(edge: edge, role: role)
        }
    }

    /// Every ornament overlapping `range`, in document order.
    public func ornaments(in range: NSRange) -> [InlineOrnament] {
        guard !ornaments.isEmpty, range.length >= 0 else { return [] }
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

    /// The block a fragment at `location` belongs to, for hit testing.
    public func blockRange(containing location: Int) -> NSRange? {
        segment(containing: location)?.blockRange
    }

    private func segment(containing location: Int) -> Segment? {
        var low = 0
        var high = segments.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let range = segments[mid].range
            if location < range.location {
                high = mid - 1
            } else if location >= range.location + range.length {
                low = mid + 1
            } else {
                return segments[mid]
            }
        }
        return nil
    }

    // MARK: - Building

    /// Flattens nested decorated blocks into disjoint segments, in one pass.
    ///
    /// Blocks arrive in document order with ascending starts, and Markdown
    /// blocks nest properly — so a stack of the currently open ones is enough
    /// to say which decoration governs any point: always the innermost, which
    /// is the top of the stack. Each region is emitted as the sweep passes it.
    ///
    /// The obvious alternative — overpaint each block onto an array of
    /// segments — is quadratic in the number of decorated blocks, and this
    /// runs on every keystroke.
    private static func flatten(_ blocks: [BlockDescriptor]) -> [Segment] {
        // `edgeRange` is what a fragment measures its `BlockEdge` against, and
        // it is not always the block's own range: a table's rows must round
        // the *table's* corners, or each row draws as its own rounded card.
        var open: [(range: NSRange, edgeRange: NSRange, payload: Payload)] = []
        var segments: [Segment] = []
        var cursor = 0
        // Body rows are numbered per table so alternate rows can be tinted.
        // Counting here, once, keeps a fragment from having to work out where
        // in its table it sits.
        var rowIndex = 0

        func upperBound(_ range: NSRange) -> Int { range.location + range.length }

        /// Emits the region `cursor..<limit`, closing every block that ends
        /// inside it. Blocks are closed innermost-first, each painting the
        /// tail it still owns.
        func advance(to limit: Int) {
            while let top = open.last, upperBound(top.range) <= limit {
                if cursor < upperBound(top.range) {
                    segments.append(
                        Segment(
                            range: NSRange(
                                location: cursor, length: upperBound(top.range) - cursor),
                            blockRange: top.edgeRange,
                            payload: top.payload))
                    cursor = upperBound(top.range)
                }
                open.removeLast()
            }
            if let top = open.last, cursor < limit {
                segments.append(
                    Segment(
                        range: NSRange(location: cursor, length: limit - cursor),
                        blockRange: top.range,
                        payload: top.payload))
            }
            cursor = max(cursor, limit)
        }

        for block in blocks where block.range.length > 0 {
            let payload: Payload
            switch block.kind {
            case .codeBlock, .mathBlock, .frontmatter:
                payload = .code(language: block.info, isDiagram: false)
            case .mermaidBlock:
                payload = .code(language: block.info ?? "mermaid", isDiagram: true)
            case .callout:
                payload = .callout(block.calloutKind ?? .note)
            case .blockQuote:
                payload = .quote
            case .rule:
                payload = .rule
            case .table:
                rowIndex = 0
                payload = .table(.separator)
            case .tableHead:
                payload = .table(.header)
            case .tableRow:
                payload = .table(.body(row: rowIndex))
                rowIndex += 1
            default:
                continue
            }

            advance(to: block.range.location)

            // A row or header inherits the extent of the table it is in, so
            // the first line rounds the top, the last rounds the bottom, and
            // everything between draws square and meets without a seam.
            var edgeRange = block.range
            if block.kind != .table, case .table = payload,
                let enclosing = open.last(where: {
                    if case .table = $0.payload { return true } else { return false }
                })
            {
                edgeRange = enclosing.edgeRange
            }
            open.append((block.range, edgeRange, payload))
        }

        advance(to: Int.max)
        return segments
    }

    private static func ornaments(in spans: [StyleSpan]) -> [InlineOrnament] {
        var out: [InlineOrnament] = []
        out.reserveCapacity(spans.count / 4)
        for span in spans where span.range.length > 0 {
            switch span.kind {
            case .taskMarker:
                out.append(.checkbox(range: span.range, checked: span.data != 0))
            case .inlineCode:
                out.append(.codePill(range: span.range))
            case .tag:
                out.append(.tagPill(range: span.range))
            default:
                continue
            }
        }
        // No sort: the parser hands back spans ordered by start, and picking a
        // subset of an ordered sequence in order leaves it ordered. That is
        // what ``ornaments(in:)`` binary-searches over, and re-sorting it on
        // every keystroke would be paying for a guarantee already held.
        return out
    }
}

extension BlockDecoration {
    /// The decoration for the fragment covering `range`.
    ///
    /// Builds an index for one query, which suits tests and one-off callers.
    /// Anything asking per line — the editor's fragment delegate — must hold a
    /// ``DocumentDecorations`` instead, or the lookup is quadratic.
    public static func decoration(
        for range: NSRange,
        in document: ParsedDocument
    ) -> BlockDecoration {
        DocumentDecorations(document: document).decoration(for: range)
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
