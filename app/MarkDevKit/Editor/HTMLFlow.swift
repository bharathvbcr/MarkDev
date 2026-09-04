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
/// — a centred heading, a badge row, a `<details>` block, an all-contributors
/// table of linked avatars — and refuses everything else. Unknown tags,
/// scripts, and leftover text after a closer keep their source. HTML comments
/// are hidden separately: GitHub draws nothing for them.
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
        public let mono: Bool
        public let href: String?
    }

    public enum Item: Equatable, Sendable, Hashable {
        case image(Image)
        case run(Run)
        case lineBreak
    }

    public let alignment: Alignment
    public let items: [Item]
    /// 1…6 when this fragment is an `<hN>`. `nil` is body text.
    public let headingLevel: Int?
    /// An HTML table of cells, each itself a fragment. `nil` is not a table.
    public let rows: [[HTMLFlow]]?

    /// The most a fragment may measure before it is refused.
    ///
    /// An HTML *block* has no length limit, and a README can paste a page of
    /// markup. Walking that on the keystroke path has to stop somewhere; a
    /// GitHub badge row is a couple of kilobytes, and 32KB is already far
    /// past any fragment this is meant to draw.
    public static let maximumLength = 32_768

    /// A pathological row of images is still a row, but not an unbounded one.
    public static let maximumItems = 64

    /// All-contributors writes seven columns; a few extra is slack, not a grid.
    public static let maximumColumns = 12

    public static let maximumRows = 32

    public var images: [Image] {
        if let rows {
            return rows.flatMap { $0.flatMap(\.images) }
        }
        return items.compactMap { item in
            if case .image(let image) = item { return image }
            return nil
        }
    }

    public var hasVisibleContent: Bool {
        if let rows {
            return rows.contains { $0.contains { $0.hasVisibleContent } }
        }
        return items.contains { item in
            switch item {
            case .image: true
            case .run(let run): !run.text.isEmpty
            case .lineBreak: false
            }
        }
    }

    public init(
        alignment: Alignment,
        items: [Item],
        headingLevel: Int? = nil,
        rows: [[HTMLFlow]]? = nil
    ) {
        self.alignment = alignment
        self.items = items
        self.headingLevel = headingLevel
        self.rows = rows
    }

    /// Parses `text` as a README HTML fragment, or `nil` if it is anything
    /// else — including a tag this does not draw.
    public static func parse(_ text: String) -> HTMLFlow? {
        guard text.utf8.count <= maximumLength else { return nil }

        var scanner = HTMLTagScanner(HTMLTagScanner.trimmed(text))
        let saved = scanner.cursor
        if let (name, _, selfClosing) = scanner.openTag(), name == "table" {
            guard !selfClosing else { return nil }
            return parseTable(&scanner)
        }
        scanner.cursor = saved

        var alignment: Alignment = .leading
        var wrapper: String?
        var headingLevel: Int?

        if let (name, attributes, selfClosing) = scanner.openTag() {
            if selfClosing { return nil }
            if name == "p" || name == "div" {
                alignment = Self.alignment(from: attributes["align"])
                wrapper = name
            } else if name == "center" {
                alignment = .center
                wrapper = name
            } else if let level = Self.headingLevel(name) {
                alignment = Self.alignment(from: attributes["align"])
                headingLevel = level
                wrapper = name
            } else if name == "details" {
                guard let items = parseDetails(&scanner) else { return nil }
                scanner.skipWhitespace()
                guard scanner.isAtEnd else { return nil }
                let flow = HTMLFlow(alignment: .leading, items: trimming(items))
                return flow.hasVisibleContent ? flow : nil
            } else {
                scanner.cursor = saved
            }
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
        let flow = HTMLFlow(
            alignment: alignment, items: items, headingLevel: headingLevel)
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

    private static func parseDetails(_ scanner: inout HTMLTagScanner) -> [Item]? {
        scanner.skipWhitespace()
        var items: [Item] = []
        let saved = scanner.cursor
        if let (name, _, selfClosing) = scanner.openTag(), name == "summary" {
            guard !selfClosing,
                let summary = parseItems(
                    &scanner, href: nil, until: "summary", closerRequired: true)
            else { return nil }
            items = summary.map { item in
                if case .run(let run) = item {
                    return .run(
                        Run(
                            text: run.text, bold: true, italic: run.italic,
                            mono: run.mono, href: run.href))
                }
                return item
            }
            if !items.isEmpty { items.append(.lineBreak) }
        } else {
            scanner.cursor = saved
        }
        guard let body = parseItems(
            &scanner, href: nil, until: "details", closerRequired: false)
        else { return nil }
        items.append(contentsOf: body)
        return items
    }

    private static func parseTable(_ scanner: inout HTMLTagScanner) -> HTMLFlow? {
        guard let rows = parseTableRows(&scanner, until: "table"),
            rows.count <= maximumRows,
            rows.contains(where: { $0.contains { $0.hasVisibleContent } })
        else { return nil }
        scanner.skipWhitespace()
        guard scanner.isAtEnd else { return nil }
        return HTMLFlow(alignment: .leading, items: [], rows: rows)
    }

    private static func parseTableRows(
        _ scanner: inout HTMLTagScanner, until closer: String
    ) -> [[HTMLFlow]]? {
        var rows: [[HTMLFlow]] = []
        while !scanner.isAtEnd {
            scanner.skipWhitespace()
            if scanner.closeTag(closer) { return rows }
            let saved = scanner.cursor
            guard let (name, _, selfClosing) = scanner.openTag(), !selfClosing else {
                return nil
            }
            if name == "thead" || name == "tbody" || name == "tfoot" {
                guard let inner = parseTableRows(&scanner, until: name) else { return nil }
                rows.append(contentsOf: inner)
                continue
            }
            if name == "tr" {
                guard let row = parseTableRow(&scanner) else { return nil }
                rows.append(row)
                if rows.count > maximumRows { return nil }
                continue
            }
            scanner.cursor = saved
            return nil
        }
        return nil
    }

    private static func parseTableRow(_ scanner: inout HTMLTagScanner) -> [HTMLFlow]? {
        var cells: [HTMLFlow] = []
        while !scanner.isAtEnd {
            scanner.skipWhitespace()
            if scanner.closeTag("tr") { return cells }
            guard let (name, attributes, selfClosing) = scanner.openTag(),
                (name == "td" || name == "th"), !selfClosing
            else { return nil }
            guard let items = parseItems(
                &scanner, href: nil, until: name, closerRequired: true)
            else { return nil }
            cells.append(
                HTMLFlow(
                    alignment: alignment(from: attributes["align"]),
                    items: trimming(items)))
            if cells.count > maximumColumns { return nil }
        }
        return nil
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
        let mono = name == "code" || name == "kbd"
        let unwrap =
            name == "span" || name == "sub" || name == "sup" || name == "small"
            || name == "mark" || name == "u" || name == "s"
        guard (bold || italic || mono || unwrap), !selfClosing else {
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
                        mono: run.mono || mono,
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
        return Run(text: collapsed, bold: false, italic: false, mono: false, href: href)
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

    private static func headingLevel(_ name: String) -> Int? {
        guard name.count == 2, name.first == "h",
            let digit = name.last?.wholeNumberValue, (1...6).contains(digit)
        else { return nil }
        return digit
    }
}
