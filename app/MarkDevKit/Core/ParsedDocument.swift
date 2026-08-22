//
//  ParsedDocument.swift
//  MarkDevKit
//
//  Swift-side owner of a Rust parse result.
//

import Foundation

#if canImport(CMarkDev)
    import CMarkDev
#endif

/// The parsed form of one Markdown document: ordered spans, syntax markers,
/// and block descriptors, ready to become text attributes and layout fragments.
///
/// # Why this copies out of Rust
///
/// The FFI hands back borrowed pointers valid only until `md_free`. Rather
/// than propagate that lifetime rule into every call site, this type copies
/// the arrays once and frees the handle immediately.
///
/// The copy is a `memcpy` of plain-old-data structs — the expensive part of
/// the boundary was always the *number* of calls, not the bytes, and that is
/// already down to one call per parse. In exchange the type becomes a plain
/// value holder that is trivially `Sendable`, which matters under Swift 6
/// strict concurrency because parsing runs off the main actor and the result
/// is applied on it.
public struct ParsedDocument: Sendable, Equatable {
    public let spans: [StyleSpan]
    public let markers: [SyntaxMarker]
    public let blocks: [BlockDescriptor]
    /// Interned strings referenced by link-like spans' `data`.
    public let strings: [String]

    /// The parse's GFM tables, in document order.
    ///
    /// Built once here rather than filtered by each asker: the layout delegate
    /// asks "which table is this row in" once per row fragment, and scanning
    /// every block to answer it is the quadratic this codebase has paid for
    /// four times. Tables neither nest nor overlap, so the array is sorted by
    /// start offset and disjoint — searchable.
    public let tables: [BlockDescriptor]

    /// The parse's table header rows, in document order.
    ///
    /// Kept apart from ``tables`` because "is this row the header" has to be
    /// answered against *the row's own table*: taking the document's first
    /// `.tableHead` shaded only the first table's header and left every later
    /// one looking like body rows.
    private let tableHeads: [BlockDescriptor]

    /// The parse's task markers (`- [x]`), sorted and disjoint.
    ///
    /// The fragment delegate asks "does an item start on this line" once per
    /// fragment; see ``tables`` for why the answer is searched, not scanned.
    private let taskMarkerSpans: [StyleSpan]

    /// An empty result, used for empty documents and as a safe fallback when
    /// the source cannot be parsed.
    public static let empty = ParsedDocument(spans: [], markers: [], blocks: [])

    public init(
        spans: [StyleSpan],
        markers: [SyntaxMarker],
        blocks: [BlockDescriptor],
        strings: [String] = []
    ) {
        self.spans = spans
        self.markers = markers
        self.blocks = blocks
        self.strings = strings

        var tables: [BlockDescriptor] = []
        var heads: [BlockDescriptor] = []
        for block in blocks {
            if block.kind == .table { tables.append(block) }
            else if block.kind == .tableHead { heads.append(block) }
        }
        self.tables = tables
        self.tableHeads = heads
        self.taskMarkerSpans = spans.filter { $0.kind == .taskMarker }
    }

    /// The GFM table containing `range`, found by binary search.
    ///
    /// Tables are disjoint as well as sorted — a table never contains
    /// another — so the first candidate whose end lies past `range.location`
    /// is the only one that can intersect it.
    public func table(containing range: NSRange) -> BlockDescriptor? {
        Self.firstIntersecting(tables, range)
    }

    /// The header row belonging to `table`.
    ///
    /// Scoped to the table's own extent rather than taken from the head of the
    /// document: with two tables on a page, the second's header answers for
    /// itself.
    func tableHead(ofTable table: BlockDescriptor) -> BlockDescriptor? {
        Self.firstIntersecting(tableHeads, table.range)
    }

    /// The `- [x]` marker overlapping `range`, found by binary search.
    func taskMarker(overlapping range: NSRange) -> StyleSpan? {
        Self.firstIntersecting(taskMarkerSpans, range)
    }

    /// The first entry of a sorted, disjoint array that intersects `range`.
    private static func firstIntersecting<T: RangedValue>(
        _ entries: [T], _ range: NSRange
    ) -> T? {
        guard !entries.isEmpty else { return nil }
        var low = 0
        var high = entries.count
        while low < high {
            let mid = low + (high - low) / 2
            if NSMaxRange(entries[mid].range) <= range.location {
                low = mid + 1
            } else {
                high = mid
            }
        }
        guard low < entries.count,
            NSIntersectionRange(entries[low].range, range).length > 0
        else { return nil }
        return entries[low]
    }

    /// The markers overlapping `range`, as an index range into ``markers``.
    ///
    /// The core sorts markers by start offset (`core/src/md/parse.rs`), and the
    /// incremental parser's shift preserves that order, so the window can be
    /// found by binary search. Callers that ask this per block — the code-fence
    /// highlighter does — would otherwise scan every marker in the document for
    /// every block, which is the quadratic shape this codebase has already been
    /// bitten by once; see the ``HiddenRanges`` note on `covers`.
    ///
    /// Markers are *not* guaranteed disjoint: a blockquote re-marks its `>`
    /// prefixes over the gap rule's own marker. The search therefore widens
    /// backwards over neighbours that reach into `range`, which costs a step
    /// per duplicate rather than a document scan. That widening assumes
    /// overlapping markers are *adjacent* in sort order — true of duplicates,
    /// which share a start — rather than one long marker hiding behind several
    /// short ones. `ParsedDocumentTests` checks the result against a full scan
    /// over a document containing every construct the parser emits.
    public func markerIndices(overlapping range: NSRange) -> Range<Int> {
        guard range.length > 0, !markers.isEmpty else { return 0..<0 }
        let end = range.location + range.length

        // First marker starting at or after `end` — everything from there on
        // begins past the range.
        var upper = markers.count
        var low = 0
        var high = markers.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if markers[mid].range.location >= end {
                upper = mid
                high = mid - 1
            } else {
                low = mid + 1
            }
        }

        // First marker starting at or after `range.location`, then widened
        // back over any earlier marker that still reaches into the range.
        var lower = upper
        low = 0
        high = upper - 1
        while low <= high {
            let mid = (low + high) / 2
            if markers[mid].range.location >= range.location {
                lower = mid
                high = mid - 1
            } else {
                low = mid + 1
            }
        }
        while lower > 0, NSMaxRange(markers[lower - 1].range) > range.location {
            lower -= 1
        }

        return lower..<upper
    }

    /// The destination a link-like span points at.
    ///
    /// For a wikilink this is the raw target as written — `Note`,
    /// `folder/Note`, or `Note#Heading` — which is what the vault index
    /// resolves. The span itself covers only the *display* text, so an
    /// aliased `[[Target|shown]]` cannot be read back from the document.
    public func target(for span: StyleSpan) -> String? {
        switch span.kind {
        case .link, .wikiLink, .image:
            let index = Int(span.data)
            return strings.indices.contains(index) ? strings[index] : nil
        default:
            return nil
        }
    }
}

extension ParsedDocument {
    /// Parses `source` via the Rust core.
    ///
    /// Returns ``empty`` if the core rejects the input. That only happens for
    /// invalid UTF-8, which a `String` cannot contain — so in practice this
    /// never fails, and failing soft is better than trapping inside a text
    /// view's edit cycle.
    public static func parse(_ source: String) -> ParsedDocument {
        #if canImport(CMarkDev)
            var utf8 = Array(source.utf8)
            // `md_parse` tolerates a null pointer, but an empty Swift array
            // can yield one, so short-circuit rather than rely on that.
            guard !utf8.isEmpty else { return .empty }

            guard let handle = utf8.withUnsafeMutableBufferPointer({ buffer in
                md_parse(buffer.baseAddress, UInt(buffer.count))
            }) else {
                return .empty
            }
            defer { md_free(handle) }

            let strings = readStrings(handle)
            return ParsedDocument(
                spans: readSpans(handle),
                markers: readMarkers(handle),
                blocks: readBlocks(handle, strings: strings),
                strings: strings
            )
        #else
            return .empty
        #endif
    }
}

#if canImport(CMarkDev)

    /// Asserts the Rust library matches the ABI this build expects.
    ///
    /// A mismatch means `libmarkdev.a` is stale relative to the Swift code,
    /// which would otherwise surface as subtly wrong text ranges rather than
    /// as an error. Failing at startup makes that a build problem, not a
    /// debugging mystery.
    public enum MarkDevCore {
        public static let expectedABIVersion: UInt32 = 1

        public static var actualABIVersion: UInt32 { md_abi_version() }

        public static var isABICompatible: Bool {
            actualABIVersion == expectedABIVersion
        }

        /// Traps on mismatch. Call once at launch.
        public static func verifyABI(file: StaticString = #file, line: UInt = #line) {
            precondition(
                isABICompatible,
                """
                libmarkdev ABI mismatch: Swift expects \(expectedABIVersion), \
                library reports \(actualABIVersion). Rebuild the Rust core \
                (`just build-core`).
                """,
                file: file,
                line: line
            )
        }
    }

    /// Converts the C structs the core hands back into Swift values.
    ///
    /// Shared by the one-shot parse and the incremental document so the two
    /// can never disagree about how a `MDStyleSpan` becomes a `StyleSpan`.
    enum MarkdownBridge {
        static func spans(_ base: UnsafePointer<MDStyleSpan>?, _ count: Int) -> [StyleSpan] {
            guard let base, count > 0 else { return [] }
            return UnsafeBufferPointer(start: base, count: count).compactMap { raw in
                // An unknown kind means the Rust enum gained a case this build
                // does not know. Dropping it degrades styling rather than
                // crashing, and the ABI check catches the real cause.
                guard let kind = SpanKind(rawValue: raw.kind) else { return nil }
                return StyleSpan(
                    range: NSRange(location: Int(raw.start), length: Int(raw.end - raw.start)),
                    kind: kind,
                    depth: raw.depth,
                    data: raw.data
                )
            }
        }

        static func markers(_ base: UnsafePointer<MDSyntaxMarker>?, _ count: Int) -> [SyntaxMarker] {
            guard let base, count > 0 else { return [] }
            return UnsafeBufferPointer(start: base, count: count).map { raw in
                SyntaxMarker(
                    range: NSRange(location: Int(raw.start), length: Int(raw.end - raw.start)),
                    block: Int(raw.block)
                )
            }
        }

        static func blocks(
            _ base: UnsafePointer<MDBlockDescriptor>?,
            _ count: Int,
            strings: [String]
        ) -> [BlockDescriptor] {
            guard let base, count > 0 else { return [] }
            return UnsafeBufferPointer(start: base, count: count).compactMap { raw in
                guard let kind = BlockKind(rawValue: raw.kind) else { return nil }
                let index = Int(raw.info)
                let info = raw.info == MDNO_INFO || !strings.indices.contains(index)
                    ? nil : strings[index]
                return BlockDescriptor(
                    range: NSRange(location: Int(raw.start), length: Int(raw.end - raw.start)),
                    kind: kind,
                    depth: raw.depth,
                    data: raw.data,
                    info: info
                )
            }
        }
    }

    private func readStrings(_ handle: OpaquePointer) -> [String] {
        let count = md_string_count(handle)
        guard count > 0 else { return [] }
        return (0..<count).map { index in
            guard let c = md_string(handle, UInt32(index)) else { return "" }
            return String(cString: c)
        }
    }

    private func readSpans(_ handle: OpaquePointer) -> [StyleSpan] {
        var count: UInt = 0
        let base = md_spans(handle, &count)
        return MarkdownBridge.spans(base, Int(count))
    }

    private func readMarkers(_ handle: OpaquePointer) -> [SyntaxMarker] {
        var count: UInt = 0
        let base = md_markers(handle, &count)
        return MarkdownBridge.markers(base, Int(count))
    }

    private func readBlocks(_ handle: OpaquePointer, strings: [String]) -> [BlockDescriptor] {
        var count: UInt = 0
        let base = md_blocks(handle, &count)
        return MarkdownBridge.blocks(base, Int(count), strings: strings)
    }

#endif
