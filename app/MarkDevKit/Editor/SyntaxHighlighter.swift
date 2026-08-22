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

    private struct Key: Hashable {
        let language: String
        let code: String
    }

    private var cache: [Key: [HighlightSpan]] = [:]
    /// Recency order, least recently used first; see ``touch``.
    private var order: [Key] = []
    /// Bounded so a long session cannot accumulate every code block ever
    /// scrolled past.
    private let limit = 256

    public init() {}

    /// Empties the cache.
    ///
    /// Only measurements need this. The cache holds 256 blocks, so a document
    /// with more fences than that starts a second pass warm where a smaller
    /// one starts warm throughout — which quietly turns a scaling test into a
    /// measurement of the cache instead of the code.
    func removeAllCachedSpans() {
        cache.removeAll()
        order.removeAll()
    }

    /// Whether a grammar exists for `language`.
    public func supports(_ language: String) -> Bool {
        #if canImport(CMarkDev)
            return language.withCString { md_highlight_supports($0) } == 1
        #else
            return false
        #endif
    }

    /// Whether `spans` would answer from the cache.
    ///
    /// Only measurements need this; it deliberately does not count as a use,
    /// so a test can probe without changing who eviction would take.
    func isCached(language: String, code: String) -> Bool {
        cache[Key(language: language, code: code)] != nil
    }

    /// Highlights `code`, or returns empty when the language is unknown.
    public func spans(language: String?, code: String) -> [HighlightSpan] {
        guard let language, !language.isEmpty, !code.isEmpty else { return [] }

        let key = Key(language: language, code: code)
        if let cached = cache[key] {
            touch(key)
            return cached
        }

        let computed = compute(language: language, code: code)
        cache[key] = computed
        order.append(key)
        if order.count > limit {
            let evicted = order.removeFirst()
            cache.removeValue(forKey: evicted)
        }
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

    private func compute(language: String, code: String) -> [HighlightSpan] {
        #if canImport(CMarkDev)
            var bytes = Array(code.utf8)
            guard
                let handle = language.withCString({ languagePointer in
                    bytes.withUnsafeMutableBufferPointer { buffer in
                        md_highlight(languagePointer, buffer.baseAddress, UInt(buffer.count))
                    }
                })
            else { return [] }
            defer { md_highlight_free(handle) }

            var count: UInt = 0
            guard let base = md_highlight_spans(handle, &count), count > 0 else { return [] }

            return UnsafeBufferPointer(start: base, count: Int(count)).compactMap { raw in
                guard let kind = HighlightKind(rawValue: raw.kind) else { return nil }
                return HighlightSpan(
                    range: NSRange(location: Int(raw.start), length: Int(raw.end - raw.start)),
                    kind: kind)
            }
        #else
            return []
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
