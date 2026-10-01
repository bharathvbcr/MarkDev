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

    /// Inline formulae, sorted and disjoint.
    ///
    /// Styling asks for these on every caret-driven restyle. Keeping the
    /// index with the parse avoids filtering every emphasis/link/code span in
    /// a large document just to find the usually tiny formula set.
    public let inlineMathSpans: [StyleSpan]

    /// `prefixMaxEnd[i]` is the maximum end of `markers[0..<i]`.
    ///
    /// `markerIndices(overlapping:)` widens backwards using this so a long
    /// marker (a callout's `[!IMPORTANT]`, a link definition) is not skipped
    /// because a short marker sits between it and the probe.
    private let markerPrefixMaxEnd: [Int]

    /// Prefix maximum for the full span array. Unlike task/math subsets,
    /// general Markdown spans can nest and overlap, so start-only binary
    /// search is insufficient when a short inner span follows a long outer
    /// span.
    private let spanPrefixMaxEnd: [Int]

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
        self.inlineMathSpans = spans.filter { $0.kind == .inlineMath }

        self.markerPrefixMaxEnd = Self.prefixMaximumEnds(markers)
        self.spanPrefixMaxEnd = Self.prefixMaximumEnds(spans)
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
        guard !entries.isEmpty, let rangeEnd = checkedEnd(of: range) else { return nil }
        var low = 0
        var high = entries.count
        while low < high {
            let mid = low + (high - low) / 2
            if (checkedEnd(of: entries[mid].range) ?? 0) <= range.location {
                low = mid + 1
            } else {
                high = mid
            }
        }
        guard low < entries.count,
            let entryEnd = checkedEnd(of: entries[low].range),
            entries[low].range.location < rangeEnd,
            entryEnd > range.location
        else { return nil }
        return entries[low]
    }

    /// The markers overlapping `range`, as an index range into ``markers``.
    ///
    /// The core sorts markers by start offset (`core/crates/markdev-md/src/parse.rs`), and the
    /// incremental parser's shift preserves that order, so the window can be
    /// found by binary search. Callers that ask this per block — the code-fence
    /// highlighter does — would otherwise scan every marker in the document for
    /// every block, which is the quadratic shape this codebase has already been
    /// bitten by once; see the ``HiddenRanges`` note on `covers`.
    ///
    /// Markers are *not* guaranteed disjoint: a blockquote re-marks its `>`
    /// prefixes over the gap rule's own marker. The search therefore widens
    /// backwards over any earlier marker whose end reaches into `range`, using
    /// a prefix-max-end table so a long run (`[!IMPORTANT]`, a link definition)
    /// is not skipped because a short marker sits between it and the probe.
    public func markerIndices(overlapping range: NSRange) -> Range<Int> {
        Self.overlapWindow(markers, prefixMaximumEnds: markerPrefixMaxEnd, range: range)
    }

    /// The spans that can overlap `range`, as an index window into ``spans``.
    ///
    /// The window may include a non-overlapping nested neighbour between two
    /// matches; callers already inspect the returned ranges. Its important
    /// guarantee is that an earlier long span is never missed merely because
    /// a later short span ends before the query begins.
    public func spanIndices(overlapping range: NSRange) -> Range<Int> {
        Self.overlapWindow(spans, prefixMaximumEnds: spanPrefixMaxEnd, range: range)
    }

    /// The destination a link-like span points at.
    ///
    /// For a wikilink this is the raw target as written — `Note`,
    /// `folder/Note`, or `Note#Heading` — which is what the vault index
    /// resolves. The span itself covers only the *display* text, so an
    /// aliased `[[Target|shown]]` cannot be read back from the document.
    public func target(for span: StyleSpan) -> String? {
        switch span.kind {
        case .link, .wikiLink, .image, .footnoteReference:
            let index = Int(span.data)
            return strings.indices.contains(index) ? strings[index] : nil
        default:
            return nil
        }
    }

    fileprivate static func checkedEnd(of range: NSRange) -> Int? {
        guard range.location >= 0, range.length >= 0 else { return nil }
        let (end, overflow) = range.location.addingReportingOverflow(range.length)
        return overflow ? nil : end
    }

    private static func prefixMaximumEnds<T: RangedValue>(_ entries: [T]) -> [Int] {
        var running = 0
        var prefix: [Int] = []
        prefix.reserveCapacity(entries.count + 1)
        prefix.append(0)
        for entry in entries {
            // Invalid manually-constructed ranges must not trap. FFI-created
            // documents reject them before initialization.
            running = max(running, checkedEnd(of: entry.range) ?? Int.max)
            prefix.append(running)
        }
        return prefix
    }

    private static func overlapWindow<T: RangedValue>(
        _ entries: [T], prefixMaximumEnds: [Int], range: NSRange
    ) -> Range<Int> {
        guard range.length > 0, !entries.isEmpty, let end = checkedEnd(of: range) else {
            return 0..<0
        }

        var upper = entries.count
        var low = 0
        var high = entries.count
        while low < high {
            let mid = low + (high - low) / 2
            if entries[mid].range.location >= end {
                upper = mid
                high = mid
            } else {
                low = mid + 1
            }
        }

        var lower = upper
        low = 0
        high = upper
        while low < high {
            let mid = low + (high - low) / 2
            if entries[mid].range.location >= range.location {
                lower = mid
                high = mid
            } else {
                low = mid + 1
            }
        }
        while lower > 0, prefixMaximumEnds[lower] > range.location {
            lower -= 1
        }
        return lower..<upper
    }
}

/// A checked parse distinguishes a valid document with no structure from a
/// resource or ABI refusal. Callers that can surface degradation should use
/// this result rather than equating both cases with ``ParsedDocument/empty``.
public enum ParsedDocumentParseOutcome: Sendable, Equatable {
    case parsed(ParsedDocument)
    case rejected
}

extension SyntaxMarker: RangedValue {}

extension ParsedDocument {
    /// Parses `source` via the bounded Rust ABI.
    public static func parseChecked(_ source: String) -> ParsedDocumentParseOutcome {
        #if canImport(CMarkDev)
            guard MarkdownReadLimits.acceptedDocumentByteCount(source) != nil else {
                return .rejected
            }
            let utf16Count = (source as NSString).length
            guard UInt32(exactly: utf16Count) != nil else {
                return .rejected
            }

            var utf8 = Array(source.utf8)
            guard let handle = utf8.withUnsafeMutableBufferPointer({ buffer in
                md_parse(buffer.baseAddress, UInt(buffer.count))
            }) else {
                return .rejected
            }
            defer { md_free(handle) }
            guard let parsed = MarkdownBridge.parse(handle, documentLength: utf16Count) else {
                return .rejected
            }
            return .parsed(parsed)
        #else
            return .rejected
        #endif
    }

    /// Compatibility surface for renderers whose safe refusal is plain source.
    /// A rejected parse returns ``empty`` so authored text remains visible;
    /// callers that report status must use ``parseChecked(_:)``.
    public static func parse(_ source: String) -> ParsedDocument {
        switch parseChecked(source) {
        case .parsed(let document): document
        case .rejected: .empty
        }
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
        public static let expectedABIVersion: UInt32 = 3

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
        private static let maximumRecords = Int(MDMAX_STRUCTURAL_RECORDS)
        private static let maximumStrings = Int(MDMAX_INTERNED_STRINGS)
        private static let maximumStringBytes = Int(MDMAX_INTERNED_STRING_BYTES)
        private static let maximumTotalStringBytes = Int(MDMAX_TOTAL_STRING_BYTES)
        private static let maximumNesting = UInt16(MDMAX_PARSE_NESTING)

        static func parse(_ handle: OpaquePointer, documentLength: Int) -> ParsedDocument? {
            var spanCount: UInt = 0
            let spanBase = md_spans(handle, &spanCount)
            var markerCount: UInt = 0
            let markerBase = md_markers(handle, &markerCount)
            var blockCount: UInt = 0
            let blockBase = md_blocks(handle, &blockCount)
            return decode(
                documentLength: documentLength,
                spanBase: spanBase,
                spanCount: spanCount,
                markerBase: markerBase,
                markerCount: markerCount,
                blockBase: blockBase,
                blockCount: blockCount,
                stringCount: md_string_count(handle),
                stringAt: { index, length in md_string(handle, index, length) }
            )
        }

        static func document(_ handle: OpaquePointer, documentLength: Int) -> ParsedDocument? {
            var spanCount: UInt = 0
            let spanBase = md_document_spans(handle, &spanCount)
            var markerCount: UInt = 0
            let markerBase = md_document_markers(handle, &markerCount)
            var blockCount: UInt = 0
            let blockBase = md_document_blocks(handle, &blockCount)
            return decode(
                documentLength: documentLength,
                spanBase: spanBase,
                spanCount: spanCount,
                markerBase: markerBase,
                markerCount: markerCount,
                blockBase: blockBase,
                blockCount: blockCount,
                stringCount: md_document_string_count(handle),
                stringAt: { index, length in md_document_string(handle, index, length) }
            )
        }

        private static func decode(
            documentLength: Int,
            spanBase: UnsafePointer<MDStyleSpan>?,
            spanCount rawSpanCount: UInt,
            markerBase: UnsafePointer<MDSyntaxMarker>?,
            markerCount rawMarkerCount: UInt,
            blockBase: UnsafePointer<MDBlockDescriptor>?,
            blockCount rawBlockCount: UInt,
            stringCount rawStringCount: UInt,
            stringAt: (UInt32, UnsafeMutablePointer<UInt>) -> UnsafePointer<UInt8>?
        ) -> ParsedDocument? {
            guard documentLength >= 0,
                let spanCount = acceptedCount(rawSpanCount, maximum: maximumRecords),
                let markerCount = acceptedCount(rawMarkerCount, maximum: maximumRecords),
                let blockCount = acceptedCount(rawBlockCount, maximum: maximumRecords),
                let firstTotal = checkedAdd(spanCount, markerCount),
                let recordTotal = checkedAdd(firstTotal, blockCount),
                recordTotal <= maximumRecords,
                let strings = strings(count: rawStringCount, at: stringAt),
                let spans = spans(
                    spanBase,
                    count: spanCount,
                    documentLength: documentLength,
                    stringCount: strings.count),
                let blocks = blocks(
                    blockBase,
                    count: blockCount,
                    documentLength: documentLength,
                    strings: strings),
                let markers = markers(
                    markerBase,
                    count: markerCount,
                    documentLength: documentLength,
                    blockCount: blocks.count)
            else { return nil }

            return ParsedDocument(
                spans: spans,
                markers: markers,
                blocks: blocks,
                strings: strings)
        }

        static func acceptedCount(_ raw: UInt, maximum: Int) -> Int? {
            guard let count = Int(exactly: raw), count <= maximum else { return nil }
            return count
        }

        private static func checkedAdd(_ left: Int, _ right: Int) -> Int? {
            let (sum, overflow) = left.addingReportingOverflow(right)
            return overflow ? nil : sum
        }

        private static func strings(
            count rawCount: UInt,
            at stringAt: (UInt32, UnsafeMutablePointer<UInt>) -> UnsafePointer<UInt8>?
        ) -> [String]? {
            guard let count = acceptedCount(rawCount, maximum: maximumStrings) else { return nil }
            var result: [String] = []
            result.reserveCapacity(count)
            var totalBytes = 0
            for index in 0..<count {
                guard let rawIndex = UInt32(exactly: index) else { return nil }
                var rawLength: UInt = 0
                guard let base = stringAt(rawIndex, &rawLength),
                    let length = acceptedCount(rawLength, maximum: maximumStringBytes),
                    let nextTotal = checkedAdd(totalBytes, length),
                    nextTotal <= maximumTotalStringBytes,
                    let string = String(
                        bytes: UnsafeBufferPointer(start: base, count: length),
                        encoding: .utf8)
                else { return nil }
                result.append(string)
                totalBytes = nextTotal
            }
            return result
        }

        private static func spans(
            _ base: UnsafePointer<MDStyleSpan>?,
            count: Int,
            documentLength: Int,
            stringCount: Int
        ) -> [StyleSpan]? {
            guard count == 0 || base != nil else { return nil }
            guard let base else { return [] }
            var result: [StyleSpan] = []
            result.reserveCapacity(count)
            for raw in UnsafeBufferPointer(start: base, count: count) {
                guard let kind = SpanKind(rawValue: raw.kind),
                    raw.depth <= maximumNesting,
                    let range = range(start: raw.start, end: raw.end, limit: documentLength)
                else { return nil }
                if kind == .link || kind == .wikiLink || kind == .image
                    || kind == .footnoteReference
                {
                    guard UInt64(raw.data) < UInt64(stringCount) else { return nil }
                }
                result.append(
                    StyleSpan(range: range, kind: kind, depth: raw.depth, data: raw.data))
            }
            guard isSortedByStartThenEnd(result) else { return nil }
            return result
        }

        private static func markers(
            _ base: UnsafePointer<MDSyntaxMarker>?,
            count: Int,
            documentLength: Int,
            blockCount: Int
        ) -> [SyntaxMarker]? {
            guard count == 0 || base != nil else { return nil }
            guard let base else { return [] }
            var result: [SyntaxMarker] = []
            result.reserveCapacity(count)
            for raw in UnsafeBufferPointer(start: base, count: count) {
                guard let range = range(start: raw.start, end: raw.end, limit: documentLength),
                    let block = Int(exactly: raw.block),
                    block >= 0,
                    block < blockCount
                else { return nil }
                result.append(SyntaxMarker(range: range, block: block))
            }
            guard isSortedByStartThenEnd(result) else { return nil }
            return result
        }

        private static func blocks(
            _ base: UnsafePointer<MDBlockDescriptor>?,
            count: Int,
            documentLength: Int,
            strings: [String]
        ) -> [BlockDescriptor]? {
            guard count == 0 || base != nil else { return nil }
            guard let base else { return [] }
            var result: [BlockDescriptor] = []
            result.reserveCapacity(count)
            for raw in UnsafeBufferPointer(start: base, count: count) {
                guard let kind = BlockKind(rawValue: raw.kind),
                    raw.depth <= maximumNesting,
                    let range = range(start: raw.start, end: raw.end, limit: documentLength)
                else { return nil }
                let info: String?
                if raw.info == MDNO_INFO {
                    info = nil
                } else {
                    guard let index = Int(exactly: raw.info), strings.indices.contains(index) else {
                        return nil
                    }
                    info = strings[index]
                }
                result.append(
                    BlockDescriptor(
                        range: range,
                        kind: kind,
                        depth: raw.depth,
                        data: raw.data,
                        info: info))
            }
            guard isSortedByStart(result) else { return nil }
            return result
        }

        private static func range(start: UInt32, end: UInt32, limit: Int) -> NSRange? {
            guard end >= start,
                let location = Int(exactly: start),
                let upper = Int(exactly: end),
                upper <= limit
            else { return nil }
            return NSRange(location: location, length: upper - location)
        }

        /// Spans and markers only.
        ///
        /// `core/crates/markdev-md/src/parse.rs` sorts both explicitly by `(start, end)`
        /// before handing them over, so the tie-break is part of their
        /// contract and worth asserting.
        private static func isSortedByStartThenEnd<T: RangedValue>(_ values: [T]) -> Bool {
            zip(values, values.dropFirst()).allSatisfy { left, right in
                left.range.location < right.range.location
                    || (left.range.location == right.range.location
                        && (ParsedDocument.checkedEnd(of: left.range) ?? Int.max)
                            <= (ParsedDocument.checkedEnd(of: right.range) ?? Int.max))
            }
        }

        /// Blocks, which are **not** sorted by `(start, end)` and must not be.
        ///
        /// The core never sorts `blocks` at all: a descriptor is pushed when
        /// its construct *opens*, so the array is a pre-order walk in which a
        /// container precedes its contents. At a shared start that puts the
        /// wider parent first — `list(0, 22)` ahead of `listItem(0, 7)` — and
        /// its end is therefore the *larger* of the two, the exact opposite of
        /// the span ordering.
        ///
        /// Asserting the span rule here rejected every nested construct in the
        /// language. An ordered list, a table, a task list and a display
        /// formula each failed the check, `decode` returned nil, and
        /// `setMarkdown` refused the document and left the editor **blank** —
        /// a silent, total failure for ordinary notes. A single-item list
        /// passed only by coincidence, its one child ending exactly where its
        /// parent does.
        ///
        /// Pre-order is load-bearing elsewhere (a container's contents are the
        /// contiguous slice that follows it), so the fix belongs here rather
        /// than in a sort upstream. What the binary searches actually require
        /// is this and nothing more: starts never go backwards.
        /// `prefixMaximumEnds` exists precisely because the ends do not rise
        /// with them. The stronger nesting property is pinned in the core, in
        /// `core/tests/incremental.rs`, where a violation fails a test instead
        /// of blanking a reader's document.
        private static func isSortedByStart<T: RangedValue>(_ values: [T]) -> Bool {
            zip(values, values.dropFirst()).allSatisfy { left, right in
                left.range.location <= right.range.location
            }
        }
    }

#endif
