//
//  SyntaxHighlighter.swift
//  MarkDevKit
//
//  Code-fence highlighting, bridged from the Rust tree-sitter core.
//

import AppKit

#if canImport(CMarkDev)
    import CMarkDev
#endif

/// A highlighted token class. Mirrors `HighlightKind` in
/// `core/src/highlight/mod.rs` — append cases, never renumber.
public enum HighlightKind: UInt16, Sendable, CaseIterable {
    case keyword = 0
    case string = 1
    case number = 2
    case comment = 3
    case function = 4
    case type = 5
    case constant = 6
    case variable = 7
    case `operator` = 8
    case punctuation = 9
    case attribute = 10
}

/// A highlighted range, relative to the code block's own text.
public struct HighlightSpan: Sendable, Equatable {
    public let range: NSRange
    public let kind: HighlightKind

    public init(range: NSRange, kind: HighlightKind) {
        self.range = range
        self.kind = kind
    }
}

/// Highlights fenced code, caching results.
///
/// Highlighting is pure — the same language and text always give the same
/// spans — so results are cached by content. Without it, every restyle would
/// reparse every visible code block through tree-sitter, on the keystroke
/// path.
@MainActor
public final class SyntaxHighlighter {
    public static let shared = SyntaxHighlighter()

    public static let maximumCodeBytes = Int(MDMAX_HIGHLIGHT_CODE_BYTES)
    public static let maximumLanguageBytes = Int(MDMAX_HIGHLIGHT_LANGUAGE_BYTES)
    public static let maximumSpans = Int(MDMAX_HIGHLIGHT_SPANS)
    public static let maximumCachedBytes = 16 * 1_024 * 1_024
    public static let maximumCachedEntries = 256

    private struct Key: Hashable {
        let language: String
        let code: String
    }

    private struct Entry {
        let spans: [HighlightSpan]
        let cost: Int
    }

    private var cache: [Key: Entry] = [:]
    /// Recency order, least recently used first; see ``touch``.
    private var order: [Key] = []
    /// Bounded so a long session cannot accumulate every code block ever
    /// scrolled past.
    private let maximumEntries: Int
    private let maximumBytes: Int
    private(set) var cachedByteCost = 0

    public convenience init() {
        self.init(
            maximumEntries: Self.maximumCachedEntries,
            maximumBytes: Self.maximumCachedBytes)
    }

    init(maximumEntries: Int, maximumBytes: Int) {
        self.maximumEntries = max(0, maximumEntries)
        self.maximumBytes = max(0, maximumBytes)
    }

    var cachedEntryCount: Int { cache.count }

    /// Empties the cache.
    ///
    /// Only measurements need this. The cache holds 256 blocks, so a document
    /// with more fences than that starts a second pass warm where a smaller
    /// one starts warm throughout — which quietly turns a scaling test into a
    /// measurement of the cache instead of the code.
    func removeAllCachedSpans() {
        cache.removeAll()
        order.removeAll()
        cachedByteCost = 0
    }

    /// Whether a grammar exists for `language`.
    public func supports(_ language: String) -> Bool {
        #if canImport(CMarkDev)
            guard BoundedText.fitsUTF8(language, maximum: Self.maximumLanguageBytes) else {
                return false
            }
            var bytes = Array(language.utf8)
            return bytes.withUnsafeMutableBufferPointer { buffer in
                md_highlight_supports(buffer.baseAddress, UInt(buffer.count)) == 1
            }
        #else
            return false
        #endif
    }

    /// Whether `spans` would answer from the cache.
    ///
    /// Only measurements need this; it deliberately does not count as a use,
    /// so a test can probe without changing who eviction would take.
    func isCached(language: String, code: String) -> Bool {
        guard BoundedText.fitsUTF8(language, maximum: Self.maximumLanguageBytes),
            BoundedText.fitsUTF8(code, maximum: Self.maximumCodeBytes)
        else { return false }
        return cache[Key(language: language, code: code)] != nil
    }

    /// Highlights `code`, or returns empty when the language is unknown.
    public func spans(language: String?, code: String) -> [HighlightSpan] {
        guard let language, !language.isEmpty, !code.isEmpty,
            BoundedText.fitsUTF8(language, maximum: Self.maximumLanguageBytes),
            BoundedText.fitsUTF8(code, maximum: Self.maximumCodeBytes)
        else { return [] }

        let key = Key(language: language, code: code)
        if let cached = cache[key] {
            touch(key)
            return cached.spans
        }

        guard let computed = compute(language: language, code: code) else { return [] }
        admit(computed, for: key)
        return computed
    }

    /// Moves `key` to the most recently used end of ``order``.
    ///
    /// Eviction takes the least *recently used* entry, not the oldest
    /// inserted one: scrolling back over early fences is use, and those
    /// blocks stay warm — where insertion-order eviction re-ran tree-sitter
    /// on every pass back through a long document. With 256 entries at most,
    /// the linear scan costs far less than the parse it prevents.
    private func touch(_ key: Key) {
        guard let index = order.firstIndex(of: key) else { return }
        order.remove(at: index)
        order.append(key)
    }

    private func admit(_ spans: [HighlightSpan], for key: Key) {
        let spanBytes = spans.count.multipliedReportingOverflow(
            by: MemoryLayout<HighlightSpan>.stride)
        guard !spanBytes.overflow else { return }
        let first = key.language.utf8.count.addingReportingOverflow(key.code.utf8.count)
        guard !first.overflow else { return }
        let total = first.partialValue.addingReportingOverflow(spanBytes.partialValue)
        guard !total.overflow, total.partialValue <= maximumBytes, maximumEntries > 0 else { return }

        while cache.count >= maximumEntries || cachedByteCost > maximumBytes - total.partialValue {
            guard let evicted = order.first else { return }
            order.removeFirst()
            if let removed = cache.removeValue(forKey: evicted) {
                cachedByteCost -= removed.cost
            }
        }
        let entry = Entry(spans: spans, cost: total.partialValue)
        cache[key] = entry
        order.append(key)
        cachedByteCost += entry.cost
    }

    /// `nil` means the core refused malformed or oversized output. A valid
    /// unknown language is the distinct successful value `[]` and may cache.
    private func compute(language: String, code: String) -> [HighlightSpan]? {
        #if canImport(CMarkDev)
            guard BoundedText.fitsUTF8(language, maximum: Self.maximumLanguageBytes),
                BoundedText.fitsUTF8(code, maximum: Self.maximumCodeBytes)
            else { return nil }
            var languageBytes = Array(language.utf8)
            var bytes = Array(code.utf8)
            guard let handle = languageBytes.withUnsafeMutableBufferPointer({ languageBuffer in
                bytes.withUnsafeMutableBufferPointer { codeBuffer in
                    md_highlight(
                        languageBuffer.baseAddress,
                        UInt(languageBuffer.count),
                        codeBuffer.baseAddress,
                        UInt(codeBuffer.count))
                    }
                })
            else { return nil }
            defer { md_highlight_free(handle) }

            var rawCount: UInt = 0
            let base = md_highlight_spans(handle, &rawCount)
            guard let count = MarkdownBridge.acceptedCount(
                rawCount, maximum: Self.maximumSpans)
            else { return nil }
            guard count == 0 || base != nil else { return nil }
            guard let base else { return [] }

            let codeLength = (code as NSString).length
            var result: [HighlightSpan] = []
            result.reserveCapacity(count)
            for raw in UnsafeBufferPointer(start: base, count: count) {
                guard let kind = HighlightKind(rawValue: raw.kind),
                    raw.end >= raw.start,
                    let start = Int(exactly: raw.start),
                    let end = Int(exactly: raw.end),
                    end <= codeLength
                else { return nil }
                result.append(
                    HighlightSpan(
                        range: NSRange(location: start, length: end - start),
                        kind: kind))
            }
            return result
        #else
            return nil
        #endif
    }

}

extension EditorTheme {
    /// Colour for a highlighted token.
    ///
    /// Semantic system colours rather than a hand-picked palette: they track
    /// light and dark, and they match the colours the reader already sees in
    /// Xcode and Terminal.
    public func color(for kind: HighlightKind) -> NSColor {
        switch kind {
        case .keyword: .systemPink
        case .string: .systemRed
        case .number: .systemOrange
        case .comment: .secondaryLabelColor
        case .function: .systemBlue
        case .type: .systemTeal
        case .constant: .systemPurple
        case .variable: .labelColor
        case .operator: .systemIndigo
        case .punctuation: .tertiaryLabelColor
        case .attribute: .systemYellow
        }
    }
}
