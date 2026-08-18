//
//  CodeBlockSource.swift
//  MarkDevKit
//
//  Which part of a code block is the code.
//

import Foundation

/// Where a code block's *code* sits inside its own source, and what copying it
/// puts on the pasteboard.
///
/// One owner for a question two features ask. The highlighter needs the body so
/// it does not colour the ```` ``` ```` lines as though they were program text;
/// the copy control needs the same body so what lands on the pasteboard is what
/// the reader would have typed. Answering it twice is how the two drift.
///
/// The delimiters are found as **markers** rather than by matching ```` ``` ````
/// — the marker rule already covers a fence's opening and closing lines, a
/// frontmatter block's `---`, and an indented block's indentation, which are
/// three patterns to recognise but one gap in the parse. See the module docs in
/// `core/src/md/parse.rs`.
public enum CodeBlockSource {
    /// The code inside `block`, excluding its delimiter lines.
    ///
    /// `nil` when the block is nothing but delimiters — an empty fence has no
    /// body, and a zero-length range is not a range worth handing on.
    public static func bodyRange(
        of block: BlockDescriptor, in document: ParsedDocument, text: NSString
    ) -> NSRange? {
        let range = NSIntersectionRange(block.range, NSRange(location: 0, length: text.length))
        guard range.length > 0 else { return nil }

        // Found by binary search, not by filtering every marker in the
        // document: this is asked once per code block, so a scan makes a
        // whole-document pass quadratic — 756ms of a 922ms stall on the first
        // structural edit in a 10,000-line file, before it was fixed.
        let delimiters = document.markers[document.markerIndices(overlapping: range)]

        var start = range.location
        var end = NSMaxRange(range)
        if let first = delimiters.first?.range, first.location <= start {
            start = NSMaxRange(first)
        }
        if let last = delimiters.last?.range, NSMaxRange(last) >= end {
            end = last.location
        }
        guard end > start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    /// The block's code, ready for the pasteboard.
    ///
    /// Everything the parse calls syntax is taken out, rather than only the
    /// delimiters at the two ends. Those are not the same set once a block has
    /// a container: a fence written inside a list item is marked line by line —
    /// ```` ```sh\n␣␣␣␣ ````, then the four spaces opening each further line —
    /// and an indented code block is marked *entirely* by its indentation.
    /// Trimming from the ends alone left every line but the first still
    /// wearing the container's indent, which pastes into a shell as an error.
    ///
    /// Empty when there is nothing to copy, which the caller must treat as
    /// "do not touch the pasteboard": clearing it and writing an empty string
    /// would take away whatever the reader had already copied.
    public static func copyText(
        of block: BlockDescriptor, in document: ParsedDocument, text: NSString
    ) -> String {
        let pieces = code(of: block, in: document, text: text)
        guard !pieces.isEmpty else { return "" }
        return dedented(pieces.map { text.substring(with: $0) }.joined())
    }

    /// Whether the block holds any code at all.
    ///
    /// The same question ``copyText(of:in:text:)`` answers, without building
    /// the string — this is asked once per layout of a fence's head fragment,
    /// and a chip is not worth a copy of the block to decide on. It stops at
    /// the first character that settles it.
    public static func hasCode(
        of block: BlockDescriptor, in document: ParsedDocument, text: NSString
    ) -> Bool {
        for piece in code(of: block, in: document, text: text) {
            for offset in piece.location..<NSMaxRange(piece) {
                let character = text.character(at: offset)
                switch character {
                case 0x20, 0x09, 0x0A, 0x0D: continue
                default: return true
                }
            }
        }
        return false
    }

    /// The runs of a block that are code rather than syntax, in order.
    ///
    /// Markers are merged through ``HiddenRanges`` rather than walked as they
    /// come: they are *not* guaranteed disjoint — a blockquote re-marks its `>`
    /// prefixes over the gap rule's own marker — and two overlapping runs
    /// walked naively would take a character out twice, or leave one behind.
    private static func code(
        of block: BlockDescriptor, in document: ParsedDocument, text: NSString
    ) -> [NSRange] {
        let range = NSIntersectionRange(block.range, NSRange(location: 0, length: text.length))
        guard range.length > 0 else { return [] }

        let syntax = HiddenRanges(
            merging: document.markers[document.markerIndices(overlapping: range)]
                .map { NSIntersectionRange($0.range, range) })

        var pieces: [NSRange] = []
        var cursor = range.location
        for hidden in syntax.ranges {
            if hidden.location > cursor {
                pieces.append(NSRange(location: cursor, length: hidden.location - cursor))
            }
            cursor = max(cursor, NSMaxRange(hidden))
        }
        if cursor < NSMaxRange(range) {
            pieces.append(NSRange(location: cursor, length: NSMaxRange(range) - cursor))
        }
        return pieces
    }

    /// Tidies what taking the syntax out leaves behind.
    ///
    /// Three things, none of them the code's own:
    ///
    /// - **The blank first and last line.** A fence's marker covers ```` ```swift ````
    ///   but not the newline that ends it, so the body opens with one; the
    ///   closing fence leaves the mirror image.
    /// - **A common indent.** The marker pass removes the indentation the
    ///   *parse* attributes to the container, and this removes any that is left
    ///   over — belt and braces, and a no-op whenever the markers already
    ///   covered it, since removing a prefix every line shares can never change
    ///   the shape of the snippet.
    /// - **Carriage returns**, so a note saved with CRLF endings still pastes
    ///   into a shell as lines rather than as one line with `^M` in it.
    ///
    /// The common indent is counted in characters, not in columns. A block
    /// mixing tabs and spaces has no well-defined column width, and guessing
    /// one would let this remove more than it can prove is scaffolding.
    static func dedented(_ source: String) -> String {
        var lines = source.components(separatedBy: "\n").map { line -> String in
            line.hasSuffix("\r") ? String(line.dropLast()) : line
        }
        while let first = lines.first, isBlank(first) { lines.removeFirst() }
        while let last = lines.last, isBlank(last) { lines.removeLast() }
        guard !lines.isEmpty else { return "" }

        // Blank lines are excluded from the measurement and unaffected by it:
        // a run of spaces on an otherwise empty line says nothing about how far
        // the block is indented, and it must not make the answer zero.
        let indent = lines.lazy.filter { !isBlank($0) }.map(leadingWhitespace).min() ?? 0
        guard indent > 0 else { return lines.joined(separator: "\n") }
        return lines
            .map { String($0.dropFirst(min(indent, leadingWhitespace($0)))) }
            .joined(separator: "\n")
    }

    private static func isBlank(_ line: String) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func leadingWhitespace(_ line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.count
    }
}
