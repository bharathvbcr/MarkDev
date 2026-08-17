//
//  DocumentOutline.swift
//  MarkDevKit
//
//  The outline of the document on screen, from the parse the editor already did.
//

import Foundation

/// Builds an outline from a parsed document.
///
/// # Why the editor's parse and not the vault index
///
/// The vault index can only produce an outline for a note it has a path for,
/// which left the inspector empty for every file opened on its own — a file
/// dropped on the icon, or handed over by Launch Services, had no outline at
/// all even though the editor had parsed it a keystroke earlier. This reads
/// the parse that already exists, so the outline works with or without a vault
/// and tracks unsaved edits by construction.
///
/// The vault index keeps what only it can know: backlinks, unlinked mentions,
/// and link resolution across notes.
public enum DocumentOutline {
    /// Headings of `text`, in document order.
    ///
    /// `document` must be the parse of `text`. Offsets are UTF-16 code units,
    /// which is what the editor's reveal and `NSTextStorage` both index by.
    public static func headings(in document: ParsedDocument, text: String) -> [VaultHeading] {
        let blocks =
            document.blocks
            .filter { $0.kind == .heading }
            .sorted { $0.range.location < $1.range.location }
        guard !blocks.isEmpty else { return [] }

        let source = text as NSString
        var headings: [VaultHeading] = []
        headings.reserveCapacity(blocks.count)

        // Line numbers come from a single walk of the text rather than a scan
        // per heading: a long document with many headings would otherwise be
        // quadratic in its own length, and this runs after every reparse.
        var next = 0
        var line: UInt32 = 1
        var offset = 0

        for unit in text.utf16 {
            guard next < blocks.count else { break }
            while next < blocks.count, blocks[next].range.location <= offset {
                append(blocks[next], line: line, source: source, into: &headings)
                next += 1
            }
            if unit == 0x0A { line += 1 }
            offset += 1
        }
        // Anything left starts at or past the end of the text, which only
        // happens if a parse and its text disagree. Dropping a heading is a
        // worse outcome than giving it the final line number.
        while next < blocks.count {
            append(blocks[next], line: line, source: source, into: &headings)
            next += 1
        }
        return headings
    }

    private static func append(
        _ block: BlockDescriptor,
        line: UInt32,
        source: NSString,
        into headings: inout [VaultHeading]
    ) {
        let range = NSIntersectionRange(
            block.range, NSRange(location: 0, length: source.length))
        guard range.length > 0 else { return }

        let title = title(of: source.substring(with: range))
        // An empty heading — `#` on its own — has nothing to show or click.
        guard !title.isEmpty else { return }

        headings.append(
            VaultHeading(
                level: UInt8(clamping: block.headingLevel ?? 1),
                text: title,
                offset: UInt32(clamping: range.location),
                line: line))
    }

    /// The text of a heading, with its syntax removed.
    ///
    /// A heading block covers its own markers, and a Setext heading covers its
    /// underline as well, so this works from the first line only.
    static func title(of block: String) -> String {
        let firstLine = block.prefix { $0 != "\n" && $0 != "\r" }
        var title = String(firstLine.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)

        // A closed ATX heading — `## Title ##`. Only a hash run separated by
        // whitespace closes a heading, so a title that genuinely ends in one,
        // like `C#`, keeps it.
        let withoutClosingRun = String(title.reversed().drop { $0 == "#" }.reversed())
        if withoutClosingRun.count != title.count,
            let boundary = withoutClosingRun.last,
            boundary == " " || boundary == "\t"
        {
            title = withoutClosingRun.trimmingCharacters(in: .whitespaces)
        }
        return title
    }
}
