//
//  HTMLComment.swift
//  MarkDevKit
//
//  HTML comments in a note. GitHub draws nothing for them; neither do we.
//

import Foundation

/// Whether a run of raw HTML is nothing but comments.
///
/// Recognising a comment means hiding it, so this admits only what CommonMark
/// already called raw HTML and which is comments and whitespace — nothing
/// else. A comment with leftover text after its closer, a `<div>`, a
/// processing instruction, or an unterminated `<!--` all keep their source.
enum HTMLComment {
    /// The most a comment block may measure before it is refused.
    ///
    /// An HTML *block* has no length limit. Walking a page of markup on the
    /// keystroke path has to stop somewhere; all-contributors markers are a
    /// line or two, and 32KB is already far past any comment this is meant
    /// to hide.
    static let maximumLength = 32_768

    /// Whether `text` is one or more HTML comments, and nothing else.
    static func parse(_ text: String) -> Bool {
        guard text.utf8.count <= maximumLength else { return false }
        var scanner = HTMLTagScanner(HTMLTagScanner.trimmed(text))
        guard consumeComment(&scanner) else { return false }
        while !scanner.isAtEnd {
            scanner.skipWhitespace()
            guard !scanner.isAtEnd else { break }
            guard consumeComment(&scanner) else { return false }
        }
        return scanner.isAtEnd
    }

    /// Consumes one `<!-- … -->`, or leaves the position alone.
    private static func consumeComment(_ scanner: inout HTMLTagScanner) -> Bool {
        let saved = scanner.cursor
        guard scanner.take("<!--") else {
            scanner.cursor = saved
            return false
        }
        while !scanner.isAtEnd {
            if scanner.take("-->") { return true }
            scanner.cursor += 1
        }
        scanner.cursor = saved
        return false
    }
}
