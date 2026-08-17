//
//  AssistScope.swift
//  MarkDevKit
//
//  Which characters a writing action runs on.
//

import Foundation

extension BlockKind {
    /// Blocks whose text is not prose, and which a rewrite must never touch.
    ///
    /// Code is the obvious one. Frontmatter and raw HTML are here for the same
    /// reason: their content is structured data that happens to be made of
    /// words, and "make this friendlier" applied to a YAML block produces a
    /// note that no longer parses.
    public var isVerbatim: Bool {
        switch self {
        case .codeBlock, .mermaidBlock, .mathBlock, .frontmatter, .htmlBlock:
            true
        default:
            false
        }
    }
}

/// What a writing action should be given, resolved from a selection.
///
/// A value with named failure cases rather than an optional range: each way of
/// having nothing to work on needs its own sentence in the panel, and
/// returning `nil` for all four is how a feature ends up doing nothing with no
/// explanation. This is the whole decision, so it is also the whole test —
/// the panel does no scoping of its own.
public enum AssistScope: Equatable, Sendable {
    /// The range to send to the model.
    case resolved(NSRange)
    /// Nothing to work on: an empty document, or a caret in blank space.
    case empty
    /// The caret or selection sits inside code, maths, or frontmatter.
    case verbatim
    /// More text than one request should carry, in UTF-16 units.
    case tooLong(Int)

    /// The range, when there is one.
    public var range: NSRange? {
        if case .resolved(let range) = self { return range }
        return nil
    }

    /// What to tell the reader. Empty when there is a range.
    public var explanation: String {
        switch self {
        case .resolved:
            ""
        case .empty:
            "Select some text, or put the cursor in a paragraph, to use the writing tools."
        case .verbatim:
            "The writing tools don’t run on code blocks, maths, or frontmatter."
        case .tooLong(let length):
            "That’s \(length.formatted()) characters — more than one request can carry. "
                + "Select a smaller passage."
        }
    }
}

extension AssistScope {
    /// The most text one request may carry, in UTF-16 units.
    ///
    /// The on-device context window is a few thousand tokens and has to hold
    /// the instructions, the input, *and* the answer — and a rewrite's answer
    /// is about as long as its input. Four thousand characters is roughly a
    /// thousand tokens, which leaves the window comfortable rather than
    /// trusting the request not to tip over it.
    public static let maximumLength = 4_000

    /// Resolves what `selection` means for a writing action.
    ///
    /// A ranged selection is taken literally. A bare caret expands to the
    /// innermost block around it, which is what makes "put the cursor in a
    /// paragraph and hit Rewrite" work without a drag.
    public static func resolve(
        selection: NSRange,
        in document: ParsedDocument,
        text: NSString,
        limit: Int = maximumLength
    ) -> AssistScope {
        let full = NSRange(location: 0, length: text.length)
        let selection = NSIntersectionRange(selection, full)

        let candidate: NSRange
        if selection.length > 0 {
            candidate = selection
        } else {
            let caret = min(selection.location, text.length)
            guard let block = innermostBlock(at: caret, in: document, bounds: full) else {
                return .empty
            }
            candidate = block.range
        }

        if enclosingVerbatimBlock(of: candidate, in: document) != nil { return .verbatim }

        let trimmed = trimmingWhitespace(candidate, in: text)
        guard trimmed.length > 0 else { return .empty }
        guard trimmed.length <= limit else { return .tooLong(trimmed.length) }
        return .resolved(trimmed)
    }

    /// The deepest block containing `offset`.
    ///
    /// Depth rather than document order: blocks nest, so a paragraph inside a
    /// list item is contained by both the list and the item, and only the
    /// paragraph is the thing the caret is actually in.
    static func innermostBlock(
        at offset: Int,
        in document: ParsedDocument,
        bounds: NSRange
    ) -> BlockDescriptor? {
        var best: BlockDescriptor?
        for block in document.blocks {
            let range = NSIntersectionRange(block.range, bounds)
            guard range.length > 0 else { continue }
            // A caret at the very end of a block still belongs to it —
            // otherwise the last position in a paragraph resolves to nothing.
            guard offset >= range.location, offset <= range.location + range.length else { continue }
            if let current = best, block.depth < current.depth { continue }
            best = block
        }
        return best
    }

    /// A verbatim block that fully contains `range`, if any.
    ///
    /// Containment, not intersection. A selection that starts in prose and
    /// runs past a code fence is a normal thing to drag, and refusing it would
    /// be more annoying than useful — the model is told to leave code alone.
    /// A selection that is *entirely* inside a fence is unambiguous.
    static func enclosingVerbatimBlock(
        of range: NSRange,
        in document: ParsedDocument
    ) -> BlockDescriptor? {
        document.blocks.first { block in
            block.kind.isVerbatim
                && block.range.location <= range.location
                && block.range.location + block.range.length >= range.location + range.length
        }
    }

    /// `range` with leading and trailing whitespace removed.
    ///
    /// A double-click that catches the trailing newline, or a caret in a block
    /// whose range includes its terminator, would otherwise send the model a
    /// blank line to preserve and get one back in a different place.
    static func trimmingWhitespace(_ range: NSRange, in text: NSString) -> NSRange {
        let whitespace = CharacterSet.whitespacesAndNewlines
        var start = range.location
        var end = range.location + range.length
        while start < end, let scalar = Unicode.Scalar(text.character(at: start)),
            whitespace.contains(scalar)
        {
            start += 1
        }
        while end > start, let scalar = Unicode.Scalar(text.character(at: end - 1)),
            whitespace.contains(scalar)
        {
            end -= 1
        }
        return NSRange(location: start, length: end - start)
    }
}

/// Splits a document into the passages a proofreading pass checks.
///
/// # Why the document is not sent in one piece
///
/// It does not fit. The window is a few thousand tokens, so a pass over
/// anything longer than a short note has to be a sequence of requests. Doing
/// that by character count alone would cut sentences in half and invent
/// grammar mistakes at every seam, so the split follows the document's own
/// block structure and falls back to line boundaries only inside a block that
/// is on its own too large.
public enum ProofreadingPlan {
    /// Every passage of `document` worth proofreading, in document order.
    ///
    /// Verbatim blocks are skipped: there is no such thing as a comma splice
    /// in a code fence. Nothing else is dropped — an oversized block is split
    /// rather than skipped, so the chunks always cover the whole of the
    /// document's prose.
    public static func chunks(
        of document: ParsedDocument,
        text: NSString,
        limit: Int = AssistScope.maximumLength
    ) -> [NSRange] {
        let bounds = NSRange(location: 0, length: text.length)
        var chunks: [NSRange] = []
        var pending: NSRange?

        func flush() {
            if let pending, pending.length > 0 { chunks.append(pending) }
            pending = nil
        }

        for block in document.blocks where block.depth == 0 {
            let range = NSIntersectionRange(block.range, bounds)
            guard range.length > 0 else { continue }
            if block.kind.isVerbatim {
                // A fence interrupts the run: the passages either side of it
                // are not continuous prose and should not share a request.
                flush()
                continue
            }

            let trimmed = AssistScope.trimmingWhitespace(range, in: text)
            guard trimmed.length > 0 else { continue }

            if trimmed.length > limit {
                flush()
                chunks.append(contentsOf: splitByLine(trimmed, in: text, limit: limit))
                continue
            }

            if let current = pending, current.length + trimmed.length <= limit {
                pending = NSUnionRange(current, trimmed)
            } else {
                flush()
                pending = trimmed
            }
        }
        flush()
        return chunks
    }

    /// Cuts an oversized range at line boundaries.
    ///
    /// A single line longer than the limit is emitted whole rather than cut
    /// mid-word. That can exceed the limit, and deliberately so: the limit is
    /// a comfortable margin inside the real context window, and one long line
    /// reported as a context-window error is far better than silently
    /// proofreading half a sentence.
    static func splitByLine(_ range: NSRange, in text: NSString, limit: Int) -> [NSRange] {
        var chunks: [NSRange] = []
        var pending: NSRange?
        var offset = range.location
        let end = range.location + range.length

        while offset < end {
            let line = NSIntersectionRange(text.lineRange(for: NSRange(location: offset, length: 0)), range)
            guard line.length > 0 else { break }
            offset = line.location + line.length

            let trimmed = AssistScope.trimmingWhitespace(line, in: text)
            guard trimmed.length > 0 else { continue }

            if let current = pending, current.length + trimmed.length <= limit {
                pending = NSUnionRange(current, trimmed)
            } else {
                if let current = pending { chunks.append(current) }
                pending = trimmed
            }
        }
        if let pending { chunks.append(pending) }
        return chunks
    }
}
