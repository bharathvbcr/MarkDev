//
//  MarkdownStyler.swift
//  MarkDevKit
//
//  Applies a parse result to an NSTextStorage.
//

import AppKit

/// Turns a ``ParsedDocument`` into text attributes.
///
/// # Why markers shrink instead of disappearing
///
/// Collapsed syntax stays in text storage at a near-zero point size rather
/// than being removed. Keeping the characters is what preserves the
/// behaviours users would otherwise lose:
///
/// - **Copy** yields real Markdown. If hidden syntax were deleted from
///   storage, copying `**bold**` would put `bold` on the pasteboard and
///   quietly destroy the formatting.
/// - **Undo, find, and word count** all operate on the document the user
///   actually has, not a rendering of it.
/// - **Selection and hit-testing** stay native. TextKit's own machinery keeps
///   working, instead of being reimplemented on top of a coordinate space
///   that disagrees with storage.
///
/// The caret is the one thing that must be taught about hidden runs, and that
/// lives in ``MarkdownTextView`` — a single, contained override rather than a
/// parallel text engine.
public enum MarkdownStyler {
    /// Applies `document` and `hidden` to `storage`.
    ///
    /// Pass `scope` to restyle only part of the document. Styling the whole
    /// buffer on every keystroke is O(document) and costs hundreds of
    /// milliseconds once a file is long enough to matter; scoping it to the
    /// edited region is what keeps typing at one frame.
    ///
    /// Runs inside one `beginEditing`/`endEditing` pair so TextKit relayouts
    /// once rather than once per attribute run.
    ///
    /// - Parameter drawsReplacements: whether a fragment will draw stand-ins
    ///   for markers that are entirely syntax. Source mode passes `false`: it
    ///   promises the characters as written, so nothing may be painted over
    ///   them and nothing may be painted *out* of them either.
    @MainActor
    public static func apply(
        document: ParsedDocument,
        hidden: HiddenRanges,
        to storage: NSTextStorage,
        theme: EditorTheme = .standard,
        scope: NSRange? = nil,
        drawsReplacements: Bool = true
    ) {
        let full = NSRange(location: 0, length: storage.length)
        guard full.length > 0 else { return }
        let target = clamp(scope ?? full, to: full)
        guard target.length > 0 else { return }

        storage.beginEditing()
        defer { storage.endEditing() }

        applyBase(to: storage, range: target, theme: theme)
        applyBlocks(document.blocks, to: storage, limit: full, scope: target, theme: theme)
        applySpans(document.spans, to: storage, limit: full, scope: target, theme: theme)
        applyLinkTargets(document, to: storage, limit: full, scope: target)
        // Last: marker styling must win over the span attributes it overlaps,
        // or a heading's `# ` would be re-inflated to heading size.
        applyMarkers(
            document, hidden: hidden, to: storage, limit: full, scope: target, theme: theme)

        guard drawsReplacements else { return }
        // After the marker pass, which would otherwise recolour the task
        // marker it has just been told to leave visible.
        hideReplacedMarkers(document, to: storage, limit: full, scope: target)
    }

    // MARK: - Drawn replacements

    /// Makes the characters a drawn ornament stands in for invisible.
    ///
    /// A `- [ ]` cannot simply be *hidden* the way `**` is: collapsing it to
    /// 0.01pt would leave the checkbox nowhere to sit, and the line would read
    /// as an unmarked bullet. Instead the characters keep their size — so they
    /// still reserve exactly the space the checkbox needs, on the baseline, at
    /// whatever body size the theme is using — and only their colour goes.
    /// They remain in storage, so ⌘C still copies `- [x] done`.
    @MainActor
    private static func hideReplacedMarkers(
        _ document: ParsedDocument,
        to storage: NSTextStorage,
        limit: NSRange,
        scope: NSRange
    ) {
        for span in document.spans where span.kind == .taskMarker {
            let range = clamp(span.range, to: limit)
            guard range.length > 0, NSIntersectionRange(range, scope).length > 0 else { continue }
            storage.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
        }
    }

    // MARK: - Layers

    @MainActor
    private static func applyBase(
        to storage: NSTextStorage, range: NSRange, theme: EditorTheme
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = theme.lineSpacing
        paragraph.paragraphSpacing = theme.paragraphSpacing

        // Clearing first means a construct that was deleted cannot leave its
        // styling behind on the text that replaced it.
        storage.setAttributes(
            [
                .font: theme.bodyFont,
                .foregroundColor: theme.textColor,
                .paragraphStyle: paragraph,
            ],
            range: range
        )
    }

    @MainActor
    private static func applyBlocks(
        _ blocks: [BlockDescriptor],
        to storage: NSTextStorage,
        limit: NSRange,
        scope: NSRange,
        theme: EditorTheme
    ) {
        for block in blocks {
            let range = clamp(block.range, to: limit)
            guard range.length > 0, NSIntersectionRange(range, scope).length > 0 else { continue }

            switch block.kind {
            case .codeBlock, .mermaidBlock, .mathBlock, .frontmatter:
                storage.addAttributes(
                    [.font: theme.monoFont, .backgroundColor: theme.codeBackground],
                    range: range
                )
            case .blockQuote, .callout:
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = theme.lineSpacing
                paragraph.paragraphSpacing = theme.paragraphSpacing
                paragraph.firstLineHeadIndent = 16
                paragraph.headIndent = 16
                storage.addAttributes(
                    [.foregroundColor: theme.quoteColor, .paragraphStyle: paragraph],
                    range: range
                )
            case .listItem:
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = theme.lineSpacing
                // Indent scales with nesting so nested lists read as nested.
                let indent = CGFloat(block.depth) * 8 + 16
                paragraph.firstLineHeadIndent = indent
                paragraph.headIndent = indent
                storage.addAttribute(.paragraphStyle, value: paragraph, range: range)
            default:
                break
            }
        }
    }

    @MainActor
    private static func applySpans(
        _ spans: [StyleSpan],
        to storage: NSTextStorage,
        limit: NSRange,
        scope: NSRange,
        theme: EditorTheme
    ) {
        for span in spans {
            let range = clamp(span.range, to: limit)
            guard range.length > 0, NSIntersectionRange(range, scope).length > 0 else { continue }

            switch span.kind {
            case .heading:
                storage.addAttribute(
                    .font, value: theme.headingFont(level: Int(span.data)), range: range)
            case .strong:
                addTrait(.bold, to: storage, range: range)
            case .emphasis:
                addTrait(.italic, to: storage, range: range)
            case .strikethrough:
                storage.addAttribute(
                    .strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            case .inlineCode:
                storage.addAttributes(
                    [
                        .font: theme.monoFont,
                        .foregroundColor: theme.codeColor,
                        .backgroundColor: theme.codeBackground,
                    ],
                    range: range
                )
            case .link:
                storage.addAttributes(
                    [
                        .foregroundColor: theme.linkColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                    ],
                    range: range
                )
            case .wikiLink:
                // Distinguished from external links: a wikilink navigates
                // inside the vault, so it reads as a first-class connection
                // rather than an outbound jump.
                storage.addAttributes(
                    [.foregroundColor: theme.accentColor, .underlineStyle: 0],
                    range: range
                )
            case .tag:
                storage.addAttribute(.foregroundColor, value: theme.tagColor, range: range)
            case .highlight:
                storage.addAttribute(
                    .backgroundColor, value: theme.highlightBackground, range: range)
            case .inlineMath:
                storage.addAttributes(
                    [.font: theme.monoFont, .foregroundColor: theme.accentColor], range: range)
            case .image:
                storage.addAttribute(.foregroundColor, value: theme.secondaryColor, range: range)
            case .footnoteReference, .taskMarker, .inlineHTML:
                storage.addAttribute(.foregroundColor, value: theme.secondaryColor, range: range)
            case .superscript, .subscript:
                break
            }
        }
    }

    /// Tags wikilinks with a `.link` attribute carrying their target.
    ///
    /// Using AppKit's own link attribute rather than hand-rolled hit testing
    /// buys the pointing-hand cursor, `clickedOnLink` routing, and
    /// accessibility for free — all of which would otherwise have to be
    /// reimplemented on top of TextKit 2 coordinates.
    @MainActor
    private static func applyLinkTargets(
        _ document: ParsedDocument,
        to storage: NSTextStorage,
        limit: NSRange,
        scope: NSRange
    ) {
        for span in document.spans where span.kind == .wikiLink {
            let range = clamp(span.range, to: limit)
            guard range.length > 0, NSIntersectionRange(range, scope).length > 0 else { continue }
            guard let target = document.target(for: span) else { continue }
            guard
                let encoded = target.addingPercentEncoding(
                    withAllowedCharacters: .urlPathAllowed),
                let url = URL(string: "\(MarkdownStyler.wikiLinkScheme)://\(encoded)")
            else { continue }
            storage.addAttribute(.link, value: url, range: range)
        }
    }

    /// URL scheme used to carry a wikilink target through AppKit's link
    /// machinery. Never registered with the system — it exists only so
    /// `clickedOnLink` can recognise its own links.
    public static let wikiLinkScheme = "markdev-wiki"

    @MainActor
    private static func applyMarkers(
        _ document: ParsedDocument,
        hidden: HiddenRanges,
        to storage: NSTextStorage,
        limit: NSRange,
        scope: NSRange,
        theme: EditorTheme
    ) {
        // Visible markers: dimmed, so revealed syntax reads as scaffolding.
        // `covers` binary-searches; testing each marker against every hidden
        // range made styling quadratic and cost seconds per keystroke on a
        // large document.
        for marker in document.markers {
            let range = clamp(marker.range, to: limit)
            guard range.length > 0, NSIntersectionRange(range, scope).length > 0,
                !hidden.covers(range)
            else { continue }
            storage.addAttribute(.foregroundColor, value: theme.markerColor, range: range)
        }

        // Hidden markers: shrunk to nothing but still present in storage.
        for range in hidden.ranges {
            let clamped = clamp(range, to: limit)
            guard clamped.length > 0, NSIntersectionRange(clamped, scope).length > 0
            else { continue }
            storage.addAttributes(
                [
                    .font: theme.hiddenMarkerFont,
                    .foregroundColor: NSColor.clear,
                    .kern: 0,
                ],
                range: clamped
            )
        }
    }

    // MARK: - Helpers

    /// Adds a symbolic trait while keeping the font already in place, so
    /// `**bold**` inside a heading stays heading-sized.
    @MainActor
    private static func addTrait(
        _ trait: NSFontDescriptor.SymbolicTraits,
        to storage: NSTextStorage,
        range: NSRange
    ) {
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let base = (value as? NSFont) ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
            let descriptor = base.fontDescriptor.withSymbolicTraits(
                base.fontDescriptor.symbolicTraits.union(trait))
            if let font = NSFont(descriptor: descriptor, size: base.pointSize) {
                storage.addAttribute(.font, value: font, range: subrange)
            }
        }
    }

    /// Keeps a range inside the storage.
    ///
    /// Ranges arrive from a parse of text that may have changed since, so an
    /// unclamped range would raise an out-of-bounds exception inside a
    /// keystroke rather than merely mis-style a word.
    private static func clamp(_ range: NSRange, to limit: NSRange) -> NSRange {
        let location = min(max(range.location, 0), limit.length)
        let length = min(range.length, limit.length - location)
        return NSRange(location: location, length: max(0, length))
    }
}
