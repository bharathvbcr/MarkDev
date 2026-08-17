//
//  PreviewRenderer.swift
//  MarkDevKit
//
//  Read-only rendering, shared by Finder Quick Look and the in-app peek.
//

import AppKit
import Foundation

/// Renders Markdown to a static attributed string with syntax removed.
///
/// This is the *reading* path. Unlike the editor, it can delete hidden syntax
/// outright rather than draw around it, because nothing here has a caret to
/// keep consistent. That makes it cheap enough for a Quick Look extension,
/// which is memory-capped and judged on time-to-first-paint.
///
/// Rich blocks (math, Mermaid, tables) render as styled text here; the full
/// fragment-based treatment belongs to the editor.
public enum PreviewRenderer {
    /// Typography for the read-only surface.
    public struct Theme: Sendable {
        public var bodySize: CGFloat
        public var codeSize: CGFloat
        public var headingScale: [CGFloat]

        public static let standard = Theme(
            bodySize: 14,
            codeSize: 12.5,
            // Index 0 is H1.
            headingScale: [2.0, 1.6, 1.35, 1.2, 1.1, 1.0]
        )

        public init(bodySize: CGFloat, codeSize: CGFloat, headingScale: [CGFloat]) {
            self.bodySize = bodySize
            self.codeSize = codeSize
            self.headingScale = headingScale
        }

        func headingSize(level: Int) -> CGFloat {
            let index = min(max(level, 1), headingScale.count) - 1
            return bodySize * headingScale[index]
        }
    }

    /// Renders `source` using a previously computed parse.
    public static func attributedString(
        for source: String,
        parsed: ParsedDocument,
        theme: Theme = .standard
    ) -> NSAttributedString {
        let hidden = HiddenRanges(document: parsed)
        let visible = strippingHidden(source, hidden: hidden)

        let result = NSMutableAttributedString(
            string: visible,
            attributes: [
                .font: NSFont.systemFont(ofSize: theme.bodySize),
                .foregroundColor: NSColor.labelColor,
            ]
        )

        // Spans are applied after stripping, so every range is remapped from
        // source offsets into visible offsets.
        for span in parsed.spans {
            let mapped = remap(span.range, hidden: hidden, limit: result.length)
            guard mapped.length > 0 else { continue }
            apply(span: span, to: result, range: mapped, theme: theme)
        }

        return result
    }

    /// Convenience for callers that have not parsed yet.
    public static func attributedString(
        for source: String,
        theme: Theme = .standard
    ) -> NSAttributedString {
        attributedString(for: source, parsed: .parse(source), theme: theme)
    }

    // MARK: - Attributes

    private static func apply(
        span: StyleSpan,
        to string: NSMutableAttributedString,
        range: NSRange,
        theme: Theme
    ) {
        switch span.kind {
        case .strong:
            addTrait(.bold, to: string, range: range)
        case .emphasis:
            addTrait(.italic, to: string, range: range)
        case .strikethrough:
            string.addAttribute(
                .strikethroughStyle,
                value: NSUnderlineStyle.single.rawValue,
                range: range
            )
        case .heading:
            let size = theme.headingSize(level: Int(span.data))
            string.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: size), range: range)
        case .inlineCode:
            string.addAttributes(
                [
                    .font: NSFont.monospacedSystemFont(ofSize: theme.codeSize, weight: .regular),
                    .foregroundColor: NSColor.systemPink,
                ],
                range: range
            )
        case .link, .wikiLink:
            string.addAttributes(
                [
                    .foregroundColor: NSColor.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ],
                range: range
            )
        case .tag:
            string.addAttribute(.foregroundColor, value: NSColor.systemTeal, range: range)
        case .highlight:
            string.addAttribute(
                .backgroundColor,
                value: NSColor.systemYellow.withAlphaComponent(0.35),
                range: range
            )
        case .inlineMath:
            string.addAttribute(
                .font,
                value: NSFont.monospacedSystemFont(ofSize: theme.bodySize, weight: .regular),
                range: range
            )
        case .image, .footnoteReference, .taskMarker, .inlineHTML, .superscript, .subscript:
            // Rendered structurally rather than by character attributes.
            break
        }
    }

    /// Adds a symbolic trait without discarding the font already applied,
    /// so `**bold** inside a heading` stays heading-sized.
    private static func addTrait(
        _ trait: NSFontDescriptor.SymbolicTraits,
        to string: NSMutableAttributedString,
        range: NSRange
    ) {
        string.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let base = (value as? NSFont) ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
            let descriptor = base.fontDescriptor.withSymbolicTraits(
                base.fontDescriptor.symbolicTraits.union(trait)
            )
            if let font = NSFont(descriptor: descriptor, size: base.pointSize) {
                string.addAttribute(.font, value: font, range: subrange)
            }
        }
    }

    // MARK: - Offset mapping

    /// Removes every hidden run from `source`.
    private static func strippingHidden(_ source: String, hidden: HiddenRanges) -> String {
        guard !hidden.ranges.isEmpty else { return source }
        let ns = source as NSString
        let result = NSMutableString(capacity: ns.length)
        var cursor = 0
        for range in hidden.ranges {
            let clamped = NSRange(
                location: min(range.location, ns.length),
                length: min(range.length, max(0, ns.length - min(range.location, ns.length)))
            )
            if clamped.location > cursor {
                result.append(ns.substring(with: NSRange(location: cursor, length: clamped.location - cursor)))
            }
            cursor = max(cursor, clamped.location + clamped.length)
        }
        if cursor < ns.length {
            result.append(ns.substring(from: cursor))
        }
        return result as String
    }

    /// Translates a source range into the stripped string's coordinates.
    private static func remap(_ range: NSRange, hidden: HiddenRanges, limit: Int) -> NSRange {
        let start = min(hidden.visibleOffset(forSource: range.location), limit)
        let end = min(hidden.visibleOffset(forSource: range.location + range.length), limit)
        return NSRange(location: start, length: max(0, end - start))
    }
}
