//
//  DocumentStats.swift
//  MarkDevKit
//
//  Word, character, and reading-time counts for the status readout.
//

import Foundation

/// How long a document is, for the status bar.
///
/// # What counts as a word
///
/// A word is a run of non-whitespace containing at least one letter or digit.
/// That rule is what keeps Markdown scaffolding out of the total: `##`, `---`,
/// `**`, `|`, and a bare `-` bullet are punctuation runs, not words, and a
/// writer checking a word count against a brief does not want the table
/// pipes in it. `don't` and `state-of-the-art` stay single words, because
/// splitting on punctuation would inflate the count instead.
///
/// # Why this is a value type
///
/// Counting walks the whole document, so it must never run on the keystroke
/// path. Keeping it a pure, `Sendable` value computed from a `String` lets the
/// caller push it onto a background task and debounce it, and lets the rule
/// above be pinned down by tests rather than read off the screen.
public struct DocumentStats: Sendable, Equatable {
    public let words: Int
    /// Characters as a reader counts them — grapheme clusters, so an emoji or
    /// an accented letter is one character rather than the two or three UTF-16
    /// units it occupies in storage.
    public let characters: Int
    /// Lines as an editor numbers them: a non-empty document has at least one,
    /// and a trailing newline opens a further, empty line.
    public let lines: Int

    public static let empty = DocumentStats(words: 0, characters: 0, lines: 0)

    public init(words: Int, characters: Int, lines: Int) {
        self.words = words
        self.characters = characters
        self.lines = lines
    }

    public init(_ text: String) {
        var words = 0
        var lines = text.isEmpty ? 0 : 1
        var isInsideWord = false
        var wordHasContent = false

        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                lines += 1
            }

            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if isInsideWord, wordHasContent { words += 1 }
                isInsideWord = false
                wordHasContent = false
            } else {
                isInsideWord = true
                if CharacterSet.alphanumerics.contains(scalar) { wordHasContent = true }
            }
        }
        // A document that does not end in whitespace leaves its last word open.
        if isInsideWord, wordHasContent { words += 1 }

        self.words = words
        self.characters = text.count
        self.lines = lines
    }

    /// Minutes to read at 220 words per minute, rounded up.
    ///
    /// Any prose at all reads as at least a minute: reporting "0 min" for a
    /// paragraph is worse than slightly over-stating it.
    public var readingMinutes: Int {
        guard words > 0 else { return 0 }
        return max(1, Int((Double(words) / 220).rounded(.up)))
    }
}
