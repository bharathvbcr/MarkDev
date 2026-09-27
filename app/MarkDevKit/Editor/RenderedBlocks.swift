//
//  RenderedBlocks.swift
//  MarkDevKit
//
//  Which blocks are drawn as content instead of as their own source, resolved
//  once per parse.
//

import CoreGraphics
import Foundation

/// Content drawn *in place of* a block's source text.
public struct RenderedBlock: Sendable, Equatable, Hashable {
    public enum Kind: Sendable, Equatable, Hashable {
        case math
        case diagram
        /// Alt text, shown if the file cannot be loaded.
        case image(alt: String)
        /// A GitHub-README HTML fragment: badges, a centred tagline, a hero
        /// image. Drawn by the fragment, not rasterised as one bitmap.
        case htmlFlow(HTMLFlow)
        /// An HTML comment. GitHub draws nothing for it; the source collapses
        /// and nothing stands in its place.
        case htmlComment
        /// An Obsidian `![[Note]]` embed standing alone in its paragraph: a
        /// read-only card showing the start of the note, or of the section
        /// or block the embed names. `source` is the embed target as written.
        case noteEmbed(title: String)
    }

    public let kind: Kind
    /// The source to render — LaTeX, Mermaid, or an image path.
    public let source: String
    /// A width the note asked for, in points, if it said one.
    ///
    /// An `<img width=…>` can, and so can Obsidian's `![alt|300](…)` and
    /// `![[pic.png|300]]`; a plain `![](…)` cannot. Carried on the block
    /// rather than resolved here because it is part of *what to draw*, which
    /// is what the render cache is keyed on — deciding it a second time at the
    /// render call is how a warmed entry becomes one nothing ever hits.
    public let width: CGFloat?
    /// Whether an `<img width="100%">` asked this picture to fill its column.
    public let fillsColumn: Bool

    public init(
        kind: Kind, source: String, width: CGFloat? = nil, fillsColumn: Bool = false
    ) {
        self.kind = kind
        self.source = source
        self.width = width
        self.fillsColumn = fillsColumn
    }

    /// The pictures the prefetcher should rasterise for this block.
    ///
    /// An HTML flow is not itself a bitmap — it is a layout of pictures and
    /// text — so warming it means warming each local image it contains.
    public var prefetchUnits: [RenderedBlock] {
        switch kind {
        case .htmlFlow(let flow):
            return flow.images.map {
                RenderedBlock(
                    kind: .image(alt: $0.alt), source: $0.source, width: $0.width,
                    fillsColumn: $0.fillsColumn)
            }
        case .htmlComment:
            return []
        default:
            return [self]
        }
    }
}

/// The blocks of one document that render as content, and what each renders.
///
/// # Why this is an index built per parse
///
/// Two questions have to give the same answer, and they are asked from
/// different places:
///
/// - ``HiddenRanges`` asks *which source to collapse*, once per styling pass.
/// - ``BlockDecoration`` asks *what to draw here*, once per layout fragment.
///
/// When those two disagreed, both failure directions actually shipped. A
/// mermaid fence was collapsed and then drawn by **every** fragment of the
/// block — TextKit lays out one fragment per line, so a five-line fence
/// reserved five diagrams' worth of height and stacked five copies down the
/// page. An image paragraph was the mirror image: drawn without ever being
/// collapsed, so the picture appeared *below* its own `![…](…)`. Resolving it
/// once and handing the same value to both is what makes the two agree by
/// construction rather than by two calculations that happen to match.
///
/// It also takes a document-wide scan off the per-fragment path. Deciding
/// "is this paragraph a standalone image" used to walk every block and every
/// span for every fragment — the quadratic shape this codebase has already
/// paid for in the marker, span, and list-item indices.
public struct RenderedBlocks: Sendable, Equatable {
    /// One block that draws content in place of its text.
    public struct Entry: Sendable, Equatable {
        /// Index into `document.blocks`, for testing against the reveal set.
        public let block: Int
        /// The block's whole range, clamped to the text it was parsed from.
        public let range: NSRange
        public let content: RenderedBlock
    }

    /// Ascending by `range.location`, and disjoint.
    public let entries: [Entry]

    public static let none = RenderedBlocks(entries: [])

    private init(entries: [Entry]) {
        self.entries = entries
    }

    /// Resolves every block of `document` that renders as content.
    ///
    /// - Parameter text: the document's text. Without it nothing renders —
    ///   every source here is read out of the text, and a block whose source
    ///   cannot be read must draw itself rather than a blank.
    public init(document: ParsedDocument, text: NSString?) {
        guard let text, text.length > 0 else {
            self.init(entries: [])
            return
        }

        // Fences and formulas first, then the paragraphs that hold nothing but
        // a picture. The order is not cosmetic: `$$\n$$\n` parses as a
        // *paragraph containing a math block*, so a paragraph is only a picture
        // when nothing more specific already claims its text.
        var found: [Entry] = []
        var paragraphs: [(index: Int, block: BlockDescriptor)] = []
        for (index, block) in document.blocks.enumerated() {
            let content: RenderedBlock?
            switch block.kind {
            case .mathBlock:
                content = Self.math(block, in: document, text: text)
            case .mermaidBlock:
                content = Self.diagram(block, in: document, text: text)
            case .htmlBlock:
                content = Self.htmlContent(block.range, in: text)
            case .paragraph:
                paragraphs.append((index, block))
                continue
            default:
                continue
            }
            guard let content, let range = Self.clamp(block.range, to: text.length) else {
                continue
            }
            found.append(Entry(block: index, range: range, content: content))
        }

        // Both lists arrive in block open order, which is ascending by start
        // offset, so this is a merge walk rather than a containment test per
        // pair — paragraphs and fences both grow with the document.
        //
        // The image spans are built at most once, and only for a document that
        // has a paragraph shaped like a picture. This runs on the keystroke
        // path, and every document has paragraphs while almost none has a
        // standalone image: sorting the span list up front cost every note the
        // price of a feature it does not use.
        var images: [StyleSpan]?
        var inlineHTML: [StyleSpan]?
        let claimed = found.map(\.range)
        var cursor = 0
        for (index, block) in paragraphs {
            while cursor < claimed.count, NSMaxRange(claimed[cursor]) <= block.range.location {
                cursor += 1
            }
            if cursor < claimed.count,
                NSIntersectionRange(claimed[cursor], block.range).length > 0
            { continue }
            // Cheapest test first, and it reads two characters rather than
            // copying the paragraph out.
            //
            // A paragraph can hold the HTML spelling as well. Which paragraphs
            // is not something to reason about: a lone `<img>` on its own line
            // is an *html block* wherever it sits — measured, including under a
            // bullet, inside a blockquote and in a footnote definition — so the
            // paragraph case is the tag that shares its paragraph with
            // something, and the something is why the span index below has the
            // last word.
            guard Self.looksLikeAnImage(block.range, in: text) else {
                guard let body = Self.clamp(block.range, to: text.length),
                    Self.looksLikeAnImageTag(body, in: text)
                else { continue }
                // Built once, and only for a document that has a paragraph
                // shaped like a tag — the same bargain `images` makes, and for
                // the same reason: almost no note has one.
                let spans: [StyleSpan]
                if let built = inlineHTML {
                    spans = built
                } else {
                    spans = document.spans
                        .lazy
                        .filter { $0.kind == .inlineHTML }
                        .sorted { $0.range.location < $1.range.location }
                    inlineHTML = spans
                }
                if let content = Self.htmlImage(inParagraph: block, in: text, among: spans) {
                    found.append(Entry(block: index, range: body, content: content))
                }
                continue
            }

            let spans: [StyleSpan]
            if let built = images {
                spans = built
            } else {
                spans = document.spans
                    .lazy
                    .filter { $0.kind == .image }
                    .sorted { $0.range.location < $1.range.location }
                images = spans
            }

            guard
                let content = Self.image(block, in: document, text: text, images: spans)
                    ?? Self.noteEmbed(block, in: document, text: text),
                let range = Self.clamp(block.range, to: text.length)
            else { continue }
            found.append(Entry(block: index, range: range, content: content))
        }

        // Blocks arrive in open order — a parent before its children — so a
        // plain sort by start offset is what puts these in document order, and
        // the innermost of two starting together comes first.
        found.sort {
            $0.range.location == $1.range.location
                ? $0.range.length < $1.range.length : $0.range.location < $1.range.location
        }

        // Nothing above can nest inside anything else above, so an overlap
        // would mean the parse disagrees with that. Dropping the later one keeps
        // the set disjoint, which is what ``entry(overlapping:)`` searches.
        var disjoint: [Entry] = []
        for entry in found {
            if let last = disjoint.last, entry.range.location < NSMaxRange(last.range) {
                continue
            }
            disjoint.append(entry)
        }
        self.init(entries: disjoint)
    }

    /// The entry whose block covers `range`, if any.
    ///
    /// Binary search over disjoint, ascending ranges. A fragment can begin
    /// *before* the block it holds — a fence indented into a list item starts
    /// two columns into its line — so the entry starting at or before the
    /// fragment and the one after it are both candidates.
    public func entry(overlapping range: NSRange) -> Entry? {
        guard !entries.isEmpty else { return nil }

        var low = 0
        var high = entries.count - 1
        var found = -1
        while low <= high {
            let mid = (low + high) / 2
            if entries[mid].range.location <= range.location {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        for index in [found, found + 1] where entries.indices.contains(index) {
            let candidate = entries[index].range
            // The second test is for a zero-length fragment range, which
            // intersects nothing but still sits inside a block.
            if NSIntersectionRange(candidate, range).length > 0
                || NSLocationInRange(range.location, candidate)
            {
                return entries[index]
            }
        }
        return nil
    }

    /// The ranges whose source is replaced by drawn content right now.
    ///
    /// Unlike a marker, the whole block goes: a formula's source is replaced by
    /// the typeset formula, not merely stripped of its `$$`. These hide only
    /// while the caret is elsewhere — the source has to come back to be
    /// edited, which is the same bargain live preview makes everywhere else,
    /// and it is the *only* way the source of a diagram is ever reachable.
    ///
    /// - Parameter revealed: block indices whose syntax is on screen, from
    ///   ``RevealPolicy/revealedBlocks(in:selection:mode:)``.
    public func collapsedRanges(revealed: Set<Int>) -> [NSRange] {
        entries.lazy.filter { !revealed.contains($0.block) }.map(\.range)
    }

    // MARK: - Reading a block's source

    /// The LaTeX inside a `$$…$$` block.
    private static func math(
        _ block: BlockDescriptor, in document: ParsedDocument, text: NSString
    ) -> RenderedBlock? {
        // Markers, not a second fence scan: a formula inside a quote or list
        // wears that container's prefixes, and trimming `$$` off the raw
        // substring leaves `> x^2` which SwiftMath cannot typeset.
        let cleaned = CodeBlockSource.copyText(of: block, in: document, text: text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : RenderedBlock(kind: .math, source: cleaned)
    }

    /// The body of a fenced block, without its delimiter lines.
    private static func diagram(
        _ block: BlockDescriptor, in document: ParsedDocument, text: NSString
    ) -> RenderedBlock? {
        // Same owner the copy chip uses: a mermaid fence inside a callout is
        // marked line by line (`> ```mermaid`, then `> ` on every body line),
        // and leaving those prefixes in the source is a diagram that never
        // draws.
        let source = CodeBlockSource.copyText(of: block, in: document, text: text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return source.isEmpty ? nil : RenderedBlock(kind: .diagram, source: source)
    }

    /// Whether `range`'s text opens with `![` and closes with `)`, ignoring
    /// surrounding whitespace.
    ///
    /// Reads characters straight out of the string rather than copying the
    /// paragraph and trimming it. Every paragraph in the document is asked this
    /// on every parse, so the copy was an allocation per paragraph per
    /// keystroke; the full test in ``image(_:in:text:images:)`` still runs on
    /// whatever this admits.
    private static func looksLikeAnImage(_ range: NSRange, in text: NSString) -> Bool {
        guard let body = clamp(range, to: text.length), body.length >= 4 else { return false }

        var first = body.location
        let end = NSMaxRange(body)
        while first < end, isWhitespace(text.character(at: first)) { first += 1 }
        guard first + 1 < end,
            text.character(at: first) == 0x21,  // !
            text.character(at: first + 1) == 0x5B  // [
        else { return false }

        var last = end - 1
        while last > first, isWhitespace(text.character(at: last)) { last -= 1 }
        return text.character(at: last) == 0x29  // )
    }

    /// A block that is one `<img>` tag, a GitHub-README HTML fragment, or an
    /// HTML comment.
    ///
    /// The lone-tag path is the cheap one and runs first. Comments collapse
    /// with nothing drawn — GitHub does the same. A fragment is recognised
    /// only so that the source it replaces is certainly something this can
    /// draw: anything ``HTMLFlow`` refuses stays on the page as the markup
    /// the author wrote.
    ///
    /// The two cheap tests come first and read characters straight out of the
    /// string, for the reason ``looksLikeAnImage(_:in:)`` does: this is asked
    /// of every paragraph and every HTML block in the document on every parse,
    /// and an HTML block can be a whole page of markup. Copying each one out
    /// to look at it would be that allocation per block per keystroke.
    private static func htmlContent(_ range: NSRange, in text: NSString) -> RenderedBlock? {
        if let picture = htmlImage(range, in: text) { return picture }
        if htmlComment(range, in: text) { return RenderedBlock(kind: .htmlComment, source: "") }
        guard let body = clamp(range, to: text.length),
            body.length <= HTMLFlow.maximumLength,
            looksLikeHTMLFlow(body, in: text),
            let flow = HTMLFlow.parse(text.substring(with: body)),
            flow.hasVisibleContent
        else { return nil }
        return RenderedBlock(
            kind: .htmlFlow(flow), source: flow.images.first?.source ?? "")
    }

    /// A block that is one `<img>` tag and nothing else.
    private static func htmlImage(_ range: NSRange, in text: NSString) -> RenderedBlock? {
        guard let body = clamp(range, to: text.length),
            body.length <= HTMLImageTag.maximumLength,
            looksLikeAnImageTag(body, in: text),
            let tag = HTMLImageTag.parse(text.substring(with: body))
        else { return nil }
        return RenderedBlock(
            kind: .image(alt: tag.alt), source: tag.source, width: tag.width,
            fillsColumn: tag.fillsColumn)
    }

    /// A paragraph whose whole content is one raw-HTML `<img>` tag.
    ///
    /// The tag is read out of the span **the core marked as raw HTML**, never
    /// out of the paragraph's characters — and that is the whole of the safety
    /// here. Whether a run of `<…>` is markup or the text of it is a question
    /// about the document, not about the string: `<img\u{00A0}src="x.svg">`,
    /// `<img src="a.svg"alt="b">` and ``<img src=a`b.svg>`` are each a
    /// paragraph of ordinary text to the core, and reading the paragraph
    /// directly — which is what this used to do — hid all three and drew a
    /// picture over them. `<img src=x.svg <img src=y.svg>` was the one that
    /// showed the shape of it: the core reads visible text and *then* a tag
    /// naming `y.svg`, and the old path hid the text and drew `x.svg`.
    ///
    /// Everything outside the span has to be whitespace, for the reason
    /// ``image(_:in:text:images:)`` insists the same: the block is hidden
    /// whole, so anything else in it is text the reader loses. That check is
    /// last because it is the only one that walks the paragraph; a `<br>` or a
    /// `<span>` is turned away by ``looksLikeAnImageTag(_:in:)`` first.
    private static func htmlImage(
        inParagraph block: BlockDescriptor, in text: NSString, among spans: [StyleSpan]
    ) -> RenderedBlock? {
        guard let span = onlySpan(in: block.range, among: spans),
            let body = clamp(block.range, to: text.length),
            let tag = clamp(span.range, to: text.length),
            looksLikeAnImageTag(tag, in: text),
            isOnlyWhitespace(in: body, outside: tag, of: text)
        else { return nil }
        return htmlImage(tag, in: text)
    }

    /// Whether everything in `body` that `inner` does not cover is whitespace.
    private static func isOnlyWhitespace(
        in body: NSRange, outside inner: NSRange, of text: NSString
    ) -> Bool {
        guard inner.location >= body.location, NSMaxRange(inner) <= NSMaxRange(body) else {
            return false
        }
        for offset in body.location..<inner.location
        where !isWhitespace(text.character(at: offset)) {
            return false
        }
        for offset in NSMaxRange(inner)..<NSMaxRange(body)
        where !isWhitespace(text.character(at: offset)) {
            return false
        }
        return true
    }

    /// Whether `body`'s text opens with `<img` and closes with `>`.
    ///
    /// Five characters, and the decision for everything that is not a picture:
    /// a `<div>`, a comment, a table of raw HTML. ``HTMLImageTag/parse(_:)``
    /// decides for what gets past it.
    private static func looksLikeAnImageTag(_ body: NSRange, in text: NSString) -> Bool {
        guard body.length >= 4 else { return false }

        var first = body.location
        let end = NSMaxRange(body)
        while first < end, isWhitespace(text.character(at: first)) { first += 1 }
        guard first + 3 < end,
            text.character(at: first) == 0x3C,  // <
            (text.character(at: first + 1) | 0x20) == 0x69,  // i
            (text.character(at: first + 2) | 0x20) == 0x6D,  // m
            (text.character(at: first + 3) | 0x20) == 0x67  // g
        else { return false }

        var last = end - 1
        while last > first, isWhitespace(text.character(at: last)) { last -= 1 }
        return text.character(at: last) == 0x3E  // >
    }

    /// Whether `body` is an HTML comment, and nothing else.
    private static func htmlComment(_ range: NSRange, in text: NSString) -> Bool {
        guard let body = clamp(range, to: text.length),
            body.length <= HTMLComment.maximumLength,
            looksLikeHTMLComment(body, in: text)
        else { return false }
        return HTMLComment.parse(text.substring(with: body))
    }

    /// Whether `body` opens with `<!--`.
    ///
    /// Four characters, and the decision for everything that is not a
    /// comment: a `<div>`, a doctype, a processing instruction. ``HTMLComment/parse``
    /// decides for what gets past it.
    private static func looksLikeHTMLComment(_ body: NSRange, in text: NSString) -> Bool {
        guard body.length >= 4 else { return false }
        var first = body.location
        let end = NSMaxRange(body)
        while first < end, isWhitespace(text.character(at: first)) { first += 1 }
        guard first + 3 < end,
            text.character(at: first) == 0x3C,  // <
            text.character(at: first + 1) == 0x21,  // !
            text.character(at: first + 2) == 0x2D,  // -
            text.character(at: first + 3) == 0x2D  // -
        else { return false }
        return true
    }

    /// Whether `body` opens with a tag ``HTMLFlow`` might accept.
    ///
    /// Five or six characters, and the decision for everything that is not
    /// README chrome: a `<table>`, a `<script>`. ``HTMLFlow/parse``
    /// decides for what gets past it.
    private static func looksLikeHTMLFlow(_ body: NSRange, in text: NSString) -> Bool {
        guard body.length >= 3 else { return false }
        var first = body.location
        let end = NSMaxRange(body)
        while first < end, isWhitespace(text.character(at: first)) { first += 1 }
        guard first < end, text.character(at: first) == 0x3C else { return false }  // <
        first += 1
        guard first < end else { return false }
        let letter = text.character(at: first) | 0x20
        switch letter {
        case 0x70, 0x61, 0x62, 0x64, 0x65, 0x69, 0x73, 0x68, 0x63, 0x74:
            // p a b d e i s h c t — headings, center, table, details
            return true
        default:
            return false
        }
    }

    private static func isWhitespace(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x09 || character == 0x0A || character == 0x0D
    }

    /// An image standing alone in its own paragraph.
    ///
    /// Only whole-paragraph images are replaced. An image sitting inside a
    /// sentence has to stay inline, and swapping it for a block would break
    /// the line it belongs to.
    private static func image(
        _ block: BlockDescriptor,
        in document: ParsedDocument,
        text: NSString,
        images: [StyleSpan]
    ) -> RenderedBlock? {
        guard let span = onlySpan(in: block.range, among: images) else { return nil }
        guard let source = document.target(for: span), !source.isEmpty else { return nil }

        // The paragraph must be the image and nothing else of substance.
        guard let body = clamp(block.range, to: text.length) else { return nil }
        let paragraph = text.substring(with: body).trimmingCharacters(in: .whitespacesAndNewlines)
        // `![alt](pic.png)`, or Obsidian's `![[pic.png]]` embed.
        let isEmbed = paragraph.hasPrefix("![[") && paragraph.hasSuffix("]]")
        guard paragraph.hasPrefix("!["), isEmbed || paragraph.hasSuffix(")") else { return nil }

        let written = isEmbed ? embedAlt(paragraph) : markdownImageAlt(paragraph)
        let (alt, width) = obsidianSize(written)
        let shown = alt.isEmpty && isEmbed ? (source as NSString).lastPathComponent : alt
        return RenderedBlock(kind: .image(alt: shown), source: source, width: width)
    }

    /// A paragraph that is one `![[Note]]` embed and nothing else.
    ///
    /// The parser reports a note embed as a wikilink (so the vault counts
    /// it), which is why the image span index above does not see it.
    private static func noteEmbed(
        _ block: BlockDescriptor, in document: ParsedDocument, text: NSString
    ) -> RenderedBlock? {
        guard let body = clamp(block.range, to: text.length) else { return nil }
        let paragraph = text.substring(with: body).trimmingCharacters(in: .whitespacesAndNewlines)
        guard paragraph.hasPrefix("![["), paragraph.hasSuffix("]]"),
            paragraph.components(separatedBy: "[[").count == 2
        else { return nil }
        let links = document.spans.filter {
            $0.kind == .wikiLink && NSIntersectionRange($0.range, body).length > 0
        }
        guard links.count == 1, let target = document.target(for: links[0]), !target.isEmpty
        else { return nil }
        let inner = paragraph.dropFirst(3).dropLast(2)
        let title: String
        if let bar = inner.lastIndex(of: "|") {
            title = String(inner[inner.index(after: bar)...]).trimmingCharacters(in: .whitespaces)
        } else {
            let page = target.split(separator: "#", maxSplits: 1).first.map(String.init) ?? target
            title = (page as NSString).lastPathComponent
        }
        return RenderedBlock(
            kind: .noteEmbed(title: title.isEmpty ? target : title), source: target)
    }

    /// The text after the last `|` of `![[pic.png|…]]`, or nothing.
    private static func embedAlt(_ paragraph: String) -> String {
        let inner = paragraph.dropFirst(3).dropLast(2)
        guard let bar = inner.lastIndex(of: "|") else { return "" }
        return String(inner[inner.index(after: bar)...])
    }

    /// Obsidian writes a display width where the alt text goes:
    /// `![caption|300](pic.png)`, `![[pic.png|300]]`, `![[pic.png|300x200]]`.
    /// Returns the alt without the size, and the width in points. Anything
    /// that is not a plain number keeps its text as alt.
    static func obsidianSize(_ alt: String) -> (alt: String, width: CGFloat?) {
        func width(_ spec: Substring) -> CGFloat? {
            let trimmed = spec.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(
                separator: "x", maxSplits: 1, omittingEmptySubsequences: false)
            guard let first = parts.first, (1...5).contains(first.count),
                first.allSatisfy(\.isASCII), first.allSatisfy(\.isNumber),
                let value = Int(first), (1...10_000).contains(value)
            else { return nil }
            if parts.count == 2 {
                let second = parts[1]
                guard (1...5).contains(second.count), second.allSatisfy(\.isASCII),
                    second.allSatisfy(\.isNumber)
                else { return nil }
            }
            return CGFloat(value)
        }
        if let bar = alt.lastIndex(of: "|") {
            if let size = width(alt[alt.index(after: bar)...]) {
                return (String(alt[..<bar]).trimmingCharacters(in: .whitespaces), size)
            }
            return (alt, nil)
        }
        if let size = width(alt[...]) {
            return ("", size)
        }
        return (alt, nil)
    }

    /// `http(s):` and protocol-relative URLs. Opening a note must not fetch.
    static func isRemoteReference(_ source: String) -> Bool {
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") { return true }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            return false
        }
        return scheme == "http" || scheme == "https"
    }

    /// The `alt` inside `![alt](…)`, not the whole construct.
    private static func markdownImageAlt(_ paragraph: String) -> String {
        guard paragraph.hasPrefix("!["), let close = paragraph.firstIndex(of: "]") else {
            return ""
        }
        return String(paragraph[paragraph.index(paragraph.startIndex, offsetBy: 2)..<close])
    }

    /// The single span inside `range`, or `nil` if there are none or more than
    /// one.
    ///
    /// `spans` is one kind of span, already filtered and sorted by start
    /// offset, so the first candidate is found by binary search and "is there a
    /// second" costs one more step. Shared by the two spellings of a picture:
    /// a paragraph holding two images is a paragraph, and so is one holding two
    /// tags.
    private static func onlySpan(in range: NSRange, among images: [StyleSpan]) -> StyleSpan? {
        guard !images.isEmpty, range.length > 0 else { return nil }

        // First span that could still reach into `range`: everything before it
        // ends at or before the range starts. Image spans nest inside nothing,
        // so sorting by location also sorts them by end.
        var low = 0
        var high = images.count
        while low < high {
            let mid = low + (high - low) / 2
            if NSMaxRange(images[mid].range) <= range.location {
                low = mid + 1
            } else {
                high = mid
            }
        }
        guard low < images.count,
            NSIntersectionRange(images[low].range, range).length > 0
        else { return nil }
        // A paragraph holding two images is a paragraph, not a picture.
        if low + 1 < images.count,
            NSIntersectionRange(images[low + 1].range, range).length > 0
        {
            return nil
        }
        return images[low]
    }

    private static func clamp(_ range: NSRange, to length: Int) -> NSRange? {
        let location = min(max(range.location, 0), length)
        let size = min(range.length, length - location)
        return size > 0 ? NSRange(location: location, length: size) : nil
    }
}
