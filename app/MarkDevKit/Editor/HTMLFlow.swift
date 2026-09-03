//
//  HTMLFlow.swift
//  MarkDevKit
//
//  A constrained HTML fragment: GitHub README chrome, not a browser.
//

import CoreGraphics
import Foundation

/// A handful of HTML that GitHub READMEs actually write, drawn in place of
/// its source.
///
/// The editor is not an HTML renderer. Recognising a fragment means hiding
/// it, so this admits only the constructs a README uses to *present* a note
/// — a centred paragraph of badges, a tagline with `<br>` and `<strong>`, a
/// hero `<img width="100%">` — and refuses everything else. Unknown tags,
/// comments, tables, scripts, and leftover text after a closer all keep
/// their source, which is the honest answer for markup this cannot draw.
///
/// The grammar of each tag is CommonMark's, via ``HTMLTagScanner``. A
/// looser reader would hide lines the core still calls text.
public struct HTMLFlow: Equatable, Sendable, Hashable {
    public enum Alignment: Equatable, Sendable {
        case leading
        case center
        case trailing
    }

    public struct Image: Equatable, Sendable, Hashable {
        public let source: String
        public let alt: String
        public let width: CGFloat?
        public let fillsColumn: Bool
        /// The wrapping `<a href>`, if the picture is a link.
        public let href: String?
    }

    public struct Run: Equatable, Sendable, Hashable {
        public let text: String
        public let bold: Bool
        public let italic: Bool
        public let href: String?
    }

    public enum Item: Equatable, Sendable, Hashable {
        case image(Image)
        case run(Run)
        case lineBreak
    }

    public let alignment: Alignment
    public let items: [Item]

    /// The most a fragment may measure before it is refused.
    ///
    /// An HTML *block* has no length limit, and a README can paste a page of
    /// markup. Walking that on the keystroke path has to stop somewhere; a
    /// GitHub badge row is a couple of kilobytes, and 32KB is already far
    /// past any fragment this is meant to draw.
    public static let maximumLength = 32_768

    /// A pathological row of images is still a row, but not an unbounded one.
    public static let maximumItems = 64

    public var images: [Image] {
        items.compactMap { item in
            if case .image(let image) = item { return image }
            return nil
        }
    }

    public var hasVisibleContent: Bool {
        items.contains { item in
            switch item {
            case .image: true
            case .run(let run): !run.text.isEmpty
            case .lineBreak: false
            }
        }
    }

    public init(alignment: Alignment, items: [Item]) {
        self.alignment = alignment
        self.items = items
    }

    /// Parses `text` as a README HTML fragment, or `nil` if it is anything
    /// else — including a tag this does not draw.
    public static func parse(_ text: String) -> HTMLFlow? {
        guard text.utf8.count <= maximumLength else { return nil }

        var scanner = HTMLTagScanner(HTMLTagScanner.trimmed(text))
        var alignment: Alignment = .leading
        var wrapper: String?

        let saved = scanner.cursor
        if let (name, attributes, selfClosing) = scanner.openTag(),
            name == "p" || name == "div"
        {
            guard !selfClosing else { return nil }
            alignment = Self.alignment(from: attributes["align"])
            wrapper = name
        } else {
            scanner.cursor = saved
        }

        // A wrapper's closer is optional: CommonMark HTML blocks end on a
        // blank line, and a README that omitted `</p>` is still the fragment.
        // `<strong>` and `<a>` must close, or we would hide an unclosed tag.
        guard var items = parseItems(
            &scanner, href: nil, until: wrapper, closerRequired: false),
            items.count <= maximumItems
        else { return nil }

        scanner.skipWhitespace()
        guard scanner.isAtEnd else { return nil }

        items = trimming(items)
        let flow = HTMLFlow(alignment: alignment, items: items)
        return flow.hasVisibleContent ? flow : nil
    }

    // MARK: - Body

    /// Phrasing content until `until` closes, or until the scanner ends.
    ///
    /// `href` is inherited from an enclosing `<a>` so
    /// `<a><strong>x</strong></a>` keeps the link on the inner text.
    private static func parseItems(
        _ scanner: inout HTMLTagScanner,
        href: String?,
        until closer: String?,
        closerRequired: Bool
    ) -> [Item]? {
        var items: [Item] = []
        while !scanner.isAtEnd {
            if let closer, scanner.closeTag(closer) { return items }

            if let breakItem = takeBreak(&scanner) {
                items.append(breakItem)
                continue
            }
            if let image = HTMLImageTag.consume(&scanner) {
                items.append(.image(Self.image(from: image, href: href)))
                continue
            }
            if href == nil, let nested = takeAnchor(&scanner) {
                items.append(contentsOf: nested)
                continue
            }
            if let phrase = takePhrase(&scanner, href: href) {
                items.append(contentsOf: phrase)
                continue
            }
            if let run = takeText(&scanner, href: href) {
                if !run.text.isEmpty { items.append(.run(run)) }
                continue
            }
            return nil
        }
        if closerRequired { return nil }
        return items
    }

    private static func image(from tag: HTMLImageTag, href: String?) -> Image {
        Image(
            source: tag.source, alt: tag.alt, width: tag.width,
            fillsColumn: tag.fillsColumn, href: href)
    }

    private static func takeBreak(_ scanner: inout HTMLTagScanner) -> Item? {
        let saved = scanner.cursor
        guard let (name, _, _) = scanner.openTag(), name == "br" else {
            scanner.cursor = saved
            return nil
        }
        return .lineBreak
    }

    private static func takeAnchor(_ scanner: inout HTMLTagScanner) -> [Item]? {
        let saved = scanner.cursor
        guard let (name, attributes, selfClosing) = scanner.openTag(), name == "a" else {
            scanner.cursor = saved
            return nil
        }
        guard !selfClosing else { return nil }
        return parseItems(
            &scanner, href: attributes["href"], until: "a", closerRequired: true)
    }

    private static func takePhrase(_ scanner: inout HTMLTagScanner, href: String?) -> [Item]? {
        let saved = scanner.cursor
        guard let (name, _, selfClosing) = scanner.openTag() else {
            scanner.cursor = saved
            return nil
        }
        let bold = name == "strong" || name == "b"
        let italic = name == "em" || name == "i"
        guard bold || italic, !selfClosing else {
            scanner.cursor = saved
            return nil
        }
        guard let inner = parseItems(
            &scanner, href: href, until: name, closerRequired: true)
        else { return nil }
        return inner.map { item in
            switch item {
            case .run(let run):
                return .run(
                    Run(
                        text: run.text,
                        bold: run.bold || bold,
                        italic: run.italic || italic,
                        href: run.href ?? href))
            case .image, .lineBreak:
                return item
            }
        }
    }

    private static func takeText(_ scanner: inout HTMLTagScanner, href: String?) -> Run? {
        var raw = ""
        while let next = scanner.peek(), next != "<" {
            raw.append(next)
            scanner.cursor += 1
        }
        guard !raw.isEmpty else { return nil }
        let collapsed = collapseWhitespace(HTMLEntities.decoded(raw))
        return Run(text: collapsed, bold: false, italic: false, href: href)
    }

    /// HTML phrasing whitespace: newlines become spaces, and a run of spaces
    /// is one space. A leading space after a previous run is kept so
    /// `foo <strong>bar</strong>` does not weld the words; ``trimming(_:)``
    /// drops runs that collapse to nothing.
    private static func collapseWhitespace(_ text: String) -> String {
        var result = ""
        var space = false
        for character in text {
            if HTMLTagScanner.isWhitespace(character) {
                space = true
                continue
            }
            if space {
                if !result.isEmpty { result.append(" ") }
                space = false
            }
            result.append(character)
        }
        return result
    }

    private static func trimming(_ items: [Item]) -> [Item] {
        var result = items.filter { item in
            if case .run(let run) = item { return !run.text.isEmpty }
            return true
        }
        while let first = result.first, case .lineBreak = first { result.removeFirst() }
        while let last = result.last, case .lineBreak = last { result.removeLast() }
        return result
    }

    private static func alignment(from value: String?) -> Alignment {
        switch value?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "center", "middle": return .center
        case "right": return .trailing
        case "left": return .leading
        default: return .leading
        }
    }
}
