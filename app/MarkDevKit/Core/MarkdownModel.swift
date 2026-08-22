//
//  MarkdownModel.swift
//  MarkDevKit
//
//  Swift-native mirrors of the flat model in core/src/md/model.rs.
//

import Foundation

/// Anything carrying a UTF-16 range that can be searched as a sorted,
/// disjoint array.
protocol RangedValue {
    var range: NSRange { get }
}

extension StyleSpan: RangedValue {}
extension BlockDescriptor: RangedValue {}

/// An inline construct carrying character attributes.
///
/// Raw values are the FFI contract shared with `SpanKind` in
/// `core/src/md/model.rs` — append cases, never renumber them.
public enum SpanKind: UInt16, Sendable, CaseIterable {
    case emphasis = 0
    case strong = 1
    case strikethrough = 2
    case superscript = 3
    case `subscript` = 4
    case inlineCode = 5
    case link = 6
    case wikiLink = 7
    case image = 8
    case inlineMath = 9
    case heading = 10
    case taskMarker = 11
    case footnoteReference = 12
    case tag = 13
    case highlight = 14
    case inlineHTML = 15
}

/// A block construct that maps to a custom `NSTextLayoutFragment`.
///
/// Raw values mirror `BlockKind` in `core/src/md/model.rs`.
public enum BlockKind: UInt16, Sendable, CaseIterable {
    case paragraph = 0
    case heading = 1
    case codeBlock = 2
    case mermaidBlock = 3
    case mathBlock = 4
    case table = 5
    case tableHead = 6
    case tableRow = 7
    case tableCell = 8
    case blockQuote = 9
    case callout = 10
    case list = 11
    case listItem = 12
    case rule = 13
    case frontmatter = 14
    case footnoteDefinition = 15
    case htmlBlock = 16
    case definitionList = 17
    case definitionListTitle = 18
    case definitionListDefinition = 19
}

/// How a table column's cells sit in their column.
///
/// Mirrors `TableAlignment` in `core/src/md/model.rs`, packed into a
/// `tableCell` block's `data` alongside the column index.
public enum TableAlignment: UInt32, Sendable, CaseIterable {
    /// No `:` in the delimiter row. Lays out left, but stays distinct from an
    /// explicit `:---` so the source can be round-tripped unchanged.
    case auto = 0
    case left = 1
    case center = 2
    case right = 3

    /// Bits of a cell's `data` given over to alignment.
    static let bits: UInt32 = 2
    static let mask: UInt32 = (1 << bits) - 1
}

/// GFM alert flavour, carried in a callout block's `data`.
public enum CalloutKind: UInt32, Sendable, CaseIterable {
    case note = 0
    case tip = 1
    case important = 2
    case warning = 3
    case caution = 4
}

/// An inline range carrying character attributes.
///
/// `range` is in UTF-16 code units, matching `NSTextStorage` indexing. The
/// conversion from Rust byte offsets happens in Rust so no caller here has to
/// think about it.
public struct StyleSpan: Sendable, Equatable {
    public let range: NSRange
    public let kind: SpanKind
    public let depth: UInt16
    /// Heading level, task checked-ness, or a string-table index.
    public let data: UInt32

    public init(range: NSRange, kind: SpanKind, depth: UInt16, data: UInt32) {
        self.range = range
        self.kind = kind
        self.depth = depth
        self.data = data
    }
}

/// A run of literal syntax that live preview collapses.
public struct SyntaxMarker: Sendable, Equatable {
    public let range: NSRange
    /// Index into ``ParsedDocument/blocks``, so the reveal policy can flip
    /// every marker in the caret's block without searching.
    public let block: Int

    public init(range: NSRange, block: Int) {
        self.range = range
        self.block = block
    }
}

/// A block-level range that maps to a layout fragment.
public struct BlockDescriptor: Sendable, Equatable {
    public let range: NSRange
    public let kind: BlockKind
    public let depth: UInt16
    public let data: UInt32
    /// Code-fence language, resolved from the string table at parse time.
    public let info: String?

    public init(range: NSRange, kind: BlockKind, depth: UInt16, data: UInt32, info: String?) {
        self.range = range
        self.kind = kind
        self.depth = depth
        self.data = data
        self.info = info
    }

    /// The alert flavour, for ``BlockKind/callout`` blocks.
    public var calloutKind: CalloutKind? {
        kind == .callout ? CalloutKind(rawValue: data) : nil
    }

    /// The heading level 1–6, for ``BlockKind/heading`` blocks.
    public var headingLevel: Int? {
        kind == .heading ? Int(data) : nil
    }

    /// The column this cell occupies, for ``BlockKind/tableCell`` blocks.
    ///
    /// Rows are squared off by the parser — surplus cells dropped, short rows
    /// padded — so this indexes the table's columns directly and never runs
    /// past the header.
    public var tableColumn: Int? {
        kind == .tableCell ? Int(data >> TableAlignment.bits) : nil
    }

    /// How this cell sits in its column, for ``BlockKind/tableCell`` blocks.
    public var tableAlignment: TableAlignment? {
        guard kind == .tableCell else { return nil }
        return TableAlignment(rawValue: data & TableAlignment.mask)
    }

    /// The number of columns, for ``BlockKind/table`` blocks.
    public var tableColumnCount: Int? {
        kind == .table ? Int(data) : nil
    }
}
