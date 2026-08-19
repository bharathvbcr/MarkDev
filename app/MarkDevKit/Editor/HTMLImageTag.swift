//
//  HTMLImageTag.swift
//  MarkDevKit
//
//  A lone `<img>` tag, read out of the raw HTML a note is allowed to contain.
//

import CoreGraphics
import Foundation

/// One `<img>` tag standing on its own.
///
/// Markdown has no way to say how wide a picture should be, so a note that
/// needs one — a mark at the head of a README, a badge — writes the HTML tag
/// instead. That tag is otherwise rendered as its own source, which is the
/// author's markup shown to a reader who wanted the picture.
///
/// # Why this is a parser and not a regular expression
///
/// The tag has to be recognised *exactly*, because recognising it means
/// hiding the source it was written as. A pattern loose enough to match
/// `<img src=x>` also matches the first half of `<img src=a><img src=b>`, and
/// a paragraph holding two pictures is a paragraph — the same rule
/// ``RenderedBlocks`` already applies to Markdown images. Parsing to the end
/// of the string and refusing anything left over is what makes "this block is
/// one picture and nothing else" a decidable question.
///
/// Only `src`, `alt` and `width` are read. `align`, `hspace` and `vspace` ask
/// for text to flow around the picture, which the editor draws in place of a
/// whole block and cannot do; they are ignored rather than half-honoured.
public struct HTMLImageTag: Equatable, Sendable {
    /// The `src`, as written — resolved against the document's directory by
    /// the renderer, exactly like a Markdown image's target.
    public let source: String
    /// The `alt`, shown when the file cannot be loaded. Empty if the tag gave
    /// none.
    public let alt: String
    /// The `width` attribute, in points, if it gave a usable one.
    ///
    /// A percentage is dropped rather than resolved: it is a fraction of a
    /// containing box that this layout does not have, and guessing the column
    /// would make `width="100%"` mean something different in a split pane.
    public let width: CGFloat?

    /// The most a lone `<img>` tag may measure before it is refused.
    ///
    /// A tag is a line of a note, not a document: the longest thing in one is
    /// a path or an `alt`, and four kilobytes is already far past either. The
    /// bound is here because this runs on the parse path — an HTML *block* has
    /// no length limit at all, and can be a whole page of markup that has to
    /// be walked past on every keystroke.
    public static let maximumLength = 4096

    public init(source: String, alt: String = "", width: CGFloat? = nil) {
        self.source = source
        self.alt = alt
        self.width = width
    }

    /// Parses `text` as a single `<img>` tag, or answers `nil` if it is
    /// anything else — including a tag with something either side of it.
    public static func parse(_ text: String) -> HTMLImageTag? {
        // Before the trim, which copies. `utf8.count` is the length already
        // stored for a native string rather than a walk over it.
        guard text.utf8.count <= maximumLength else { return nil }

        var scanner = TagScanner(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard scanner.take("<img"), scanner.atTagNameBoundary else { return nil }

        var attributes: [String: String] = [:]
        while true {
            scanner.skipWhitespace()
            if scanner.take("/>") || scanner.take(">") { break }
            guard let (name, value) = scanner.attribute() else { return nil }
            // First wins, which is how a browser reads a repeated attribute.
            if attributes[name] == nil { attributes[name] = value }
        }
        // Nothing may follow the tag: the block is the picture, or it is text.
        guard scanner.isAtEnd else { return nil }

        let source = (attributes["src"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return nil }
        return HTMLImageTag(
            source: source,
            alt: attributes["alt"] ?? "",
            width: attributes["width"].flatMap(points(from:)))
    }

    /// Reads an HTML length attribute.
    ///
    /// HTML measures these in CSS pixels, which are points here — the editor
    /// lays out in points and the display's scale is TextKit's business.
    private static func points(from value: String) -> CGFloat? {
        let text = value.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !text.hasSuffix("%") else { return nil }
        let digits = text.prefix { $0.isNumber || $0 == "." }
        guard let number = Double(digits), number.isFinite, number >= 1 else { return nil }
        // Anything after the number must be a unit HTML does not have. A
        // stray `72pt` is the author's meaning plainly enough; `72 and a bit`
        // is not, and is refused by `Double` above.
        return CGFloat(number)
    }
}

/// A character-at-a-time reader over one tag.
///
/// Deliberately small: this reads a single element with quoted attributes, and
/// stops at the first thing it does not understand. It is not an HTML parser
/// and must not grow into one.
private struct TagScanner {
    private let characters: [Character]
    private var index: Int

    init(_ text: String) {
        characters = Array(text)
        index = 0
    }

    var isAtEnd: Bool { index >= characters.count }

    /// Whether the element's name has ended — so `<image>` is not read as
    /// `<img>` with a stray `e`.
    var atTagNameBoundary: Bool {
        guard let next = peek() else { return false }
        return next.isWhitespace || next == ">" || next == "/"
    }

    private func peek(_ offset: Int = 0) -> Character? {
        let position = index + offset
        return position < characters.count ? characters[position] : nil
    }

    /// Consumes `text`, case-insensitively, or leaves the position alone.
    mutating func take(_ text: String) -> Bool {
        let wanted = Array(text)
        guard index + wanted.count <= characters.count else { return false }
        for (offset, character) in wanted.enumerated() {
            guard characters[index + offset].lowercased() == character.lowercased() else {
                return false
            }
        }
        index += wanted.count
        return true
    }

    mutating func skipWhitespace() {
        while let next = peek(), next.isWhitespace { index += 1 }
    }

    /// One `name`, `name=value`, `name="value"` or `name='value'` pair.
    ///
    /// The name is lowercased: HTML attribute names are case-insensitive, and
    /// `SRC` in a hand-written tag is the same attribute as `src`.
    mutating func attribute() -> (name: String, value: String)? {
        var name = ""
        while let next = peek(), !next.isWhitespace, next != "=", next != ">", next != "/" {
            name.append(next)
            index += 1
        }
        guard !name.isEmpty else { return nil }

        skipWhitespace()
        guard take("=") else { return (name.lowercased(), "") }
        skipWhitespace()

        var value = ""
        if let quote = peek(), quote == "\"" || quote == "'" {
            index += 1
            while let next = peek(), next != quote {
                // A value never crosses a line. HTML would let it, and letting
                // it here is how a tag with one quote missing swallows the
                // lines below it: `src="mark.svg` runs on through the next
                // line's `width="` and comes back a *valid* tag with a
                // nonsense source. Accepting that hides three lines of the
                // reader's note and draws a broken picture over them. Found by
                // `PictureStressTests.testMutatedTagsAreNeverAccepted…`.
                guard !next.isNewline else { return nil }
                value.append(next)
                index += 1
            }
            // An unterminated quote means the tag is not a tag.
            guard peek() == quote else { return nil }
            index += 1
        } else {
            while let next = peek(), !next.isWhitespace, next != ">" {
                value.append(next)
                index += 1
            }
            guard !value.isEmpty else { return nil }
        }
        return (name.lowercased(), HTMLEntities.decoded(value))
    }
}

/// The handful of entities a hand-written tag actually uses.
///
/// A file name with an `&` in it arrives as `&amp;`, and resolving that
/// against the document's directory unchanged looks for a file whose name has
/// `&amp;` in it. The rest are here because they are what a quoted `alt`
/// carries.
private enum HTMLEntities {
    private static let known: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
    ]

    static func decoded(_ text: String) -> String {
        guard text.contains("&") else { return text }

        var result = ""
        var rest = Substring(text)
        while let start = rest.firstIndex(of: "&") {
            result += rest[rest.startIndex..<start]
            rest = rest[rest.index(after: start)...]
            guard let end = rest.firstIndex(of: ";"),
                rest.distance(from: rest.startIndex, to: end) <= 8
            else {
                result.append("&")
                continue
            }
            let name = String(rest[rest.startIndex..<end])
            if let replacement = expand(name) {
                result += replacement
                rest = rest[rest.index(after: end)...]
            } else {
                // Not an entity this knows: the `&` is a literal, and the text
                // after it is rescanned rather than swallowed.
                result.append("&")
            }
        }
        return result + rest
    }

    private static func expand(_ name: String) -> String? {
        if let known = known[name.lowercased()] { return known }
        guard name.hasPrefix("#") else { return nil }
        let digits = name.dropFirst()
        let value: UInt32?
        if digits.hasPrefix("x") || digits.hasPrefix("X") {
            value = UInt32(digits.dropFirst(), radix: 16)
        } else {
            value = UInt32(digits)
        }
        guard let value, let scalar = Unicode.Scalar(value) else { return nil }
        return String(Character(scalar))
    }
}
