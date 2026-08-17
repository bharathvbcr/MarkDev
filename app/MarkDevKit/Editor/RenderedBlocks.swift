//
//  RenderedBlocks.swift
//  MarkDevKit
//
//  Which blocks are drawn as content instead of as their own source, resolved
//  once per parse.
//

import Foundation

/// Content drawn *in place of* a block's source text.
public struct RenderedBlock: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case math
        case diagram
        /// Alt text, shown if the file cannot be loaded.
        case image(alt: String)
    }

    public let kind: Kind
    /// The source to render — LaTeX, Mermaid, or an image path.
    public let source: String

    public init(kind: Kind, source: String) {
        self.kind = kind
        self.source = source
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
                content = Self.math(block, in: text)
            case .mermaidBlock:
                content = Self.diagram(block, in: text)
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
            guard Self.looksLikeAnImage(block.range, in: text) else { continue }

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

            guard let content = Self.image(block, in: document, text: text, images: spans),
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
    private static func math(_ block: BlockDescriptor, in text: NSString) -> RenderedBlock? {
        guard let body = clamp(block.range, to: text.length) else { return nil }
        let raw = text.substring(with: body)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = raw
            .trimmingPrefix("$$")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let latex = stripped.hasSuffix("$$")
            ? String(stripped.dropLast(2)) : stripped
        let cleaned = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : RenderedBlock(kind: .math, source: cleaned)
    }

    /// The body of a fenced block, without its delimiter lines.
    private static func diagram(_ block: BlockDescriptor, in text: NSString) -> RenderedBlock? {
        guard let body = clamp(block.range, to: text.length) else { return nil }
        var lines = text.substring(with: body).components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true {
            lines.removeFirst()
        }
        if lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true {
            lines.removeLast()
        }
        let source = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
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
        guard let span = onlyImage(in: block.range, among: images) else { return nil }
        guard let source = document.target(for: span), !source.isEmpty else { return nil }

        // The paragraph must be the image and nothing else of substance.
        guard let body = clamp(block.range, to: text.length) else { return nil }
        let paragraph = text.substring(with: body).trimmingCharacters(in: .whitespacesAndNewlines)
        guard paragraph.hasPrefix("!["), paragraph.hasSuffix(")") else { return nil }

        let alt = clamp(span.range, to: text.length).map { text.substring(with: $0) } ?? ""
        return RenderedBlock(kind: .image(alt: alt), source: source)
    }

    /// The single image span inside `range`, or `nil` if there are none or
    /// more than one.
    ///
    /// `images` is sorted by start offset, so the first candidate is found by
    /// binary search and "is there a second" costs one more step.
    private static func onlyImage(in range: NSRange, among images: [StyleSpan]) -> StyleSpan? {
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
