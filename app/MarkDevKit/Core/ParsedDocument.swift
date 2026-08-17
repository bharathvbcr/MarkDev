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
