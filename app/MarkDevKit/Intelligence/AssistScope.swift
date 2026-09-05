//
//  AssistScope.swift
//  MarkDevKit
//
//  Which characters a writing action runs on.
//

import Foundation

/// Overflow-safe operations for ranges received from parsers, editors, and models.
///
/// Foundation's `NSIntersectionRange` and `NSMaxRange` predate Swift's checked
/// integer arithmetic. Keeping every addition here means a malformed range is
/// refused instead of trapping while a writing action is trying to validate it.
enum CheckedTextRange {
    static func end(of range: NSRange) -> Int? {
        guard range.location >= 0, range.length >= 0 else { return nil }
        let (end, overflow) = range.location.addingReportingOverflow(range.length)
        return overflow ? nil : end
    }

    static func intersection(_ range: NSRange, _ bounds: NSRange) -> NSRange? {
        guard let rangeEnd = end(of: range), let boundsEnd = end(of: bounds) else { return nil }
        let start = max(range.location, bounds.location)
        let end = min(rangeEnd, boundsEnd)
        guard end >= start else {
            // Preserve a caret as a caret at the nearest legal edge.
            let caret = min(max(range.location, bounds.location), boundsEnd)
            return NSRange(location: caret, length: 0)
        }
        return NSRange(location: start, length: end - start)
    }

    static func covering(_ first: NSRange, _ second: NSRange) -> NSRange? {
        guard let firstEnd = end(of: first), let secondEnd = end(of: second) else { return nil }
        let start = min(first.location, second.location)
        let end = max(firstEnd, secondEnd)
        return NSRange(location: start, length: end - start)
    }

    static func contains(_ outer: NSRange, _ inner: NSRange) -> Bool {
        guard let outerEnd = end(of: outer), let innerEnd = end(of: inner) else { return false }
        return outer.location <= inner.location && outerEnd >= innerEnd
    }

    static func intersects(_ first: NSRange, _ second: NSRange) -> Bool {
        guard let firstEnd = end(of: first), let secondEnd = end(of: second) else { return false }
        return first.location < secondEnd && second.location < firstEnd
    }
}

extension BlockKind {
    /// Blocks whose text is not prose, and which a rewrite must never touch.
    ///
    /// Code is the obvious one. Frontmatter and raw HTML are here for the same
    /// reason: their content is structured data that happens to be made of
    /// words, and "make this friendlier" applied to a YAML block produces a
    /// note that no longer parses.
    public var isVerbatim: Bool {
        switch self {
        case .codeBlock, .mermaidBlock, .mathBlock, .frontmatter, .htmlBlock,
            .linkReferenceDefinition:
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
        guard limit > 0, let selection = CheckedTextRange.intersection(selection, full) else {
            return .empty
        }

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
            guard let range = CheckedTextRange.intersection(block.range, bounds) else { continue }
            guard range.length > 0 else { continue }
            // A caret at the very end of a block still belongs to it —
            // otherwise the last position in a paragraph resolves to nothing.
            guard let end = CheckedTextRange.end(of: range), offset >= range.location, offset <= end
            else { continue }
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
                && CheckedTextRange.contains(block.range, range)
        }
    }

    /// `range` with leading and trailing whitespace removed.
    ///
    /// A double-click that catches the trailing newline, or a caret in a block
    /// whose range includes its terminator, would otherwise send the model a
    /// blank line to preserve and get one back in a different place.
    static func trimmingWhitespace(_ range: NSRange, in text: NSString) -> NSRange {
        guard let range = CheckedTextRange.intersection(
            range, NSRange(location: 0, length: text.length)),
            let rangeEnd = CheckedTextRange.end(of: range)
        else { return NSRange(location: 0, length: 0) }
        let whitespace = CharacterSet.whitespacesAndNewlines
        var start = range.location
        var end = rangeEnd
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
        guard limit >= 2 else { return [] }
        let bounds = NSRange(location: 0, length: text.length)
        var chunks: [NSRange] = []
        var pending: NSRange?

        func flush() {
            if let pending, pending.length > 0 { chunks.append(pending) }
            pending = nil
        }

        for block in document.blocks where block.depth == 0 {
            guard let range = CheckedTextRange.intersection(block.range, bounds) else { continue }
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

            if let current = pending,
                let combined = CheckedTextRange.covering(current, trimmed),
                combined.length <= limit
            {
                pending = combined
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
    /// A single line longer than the limit is split on a UTF-16 boundary that
    /// never bisects a surrogate pair. The request limit is a contract, not a
    /// hint: emitting one giant line whole would bypass the context bound that
    /// caused the document to be chunked in the first place.
    static func splitByLine(_ range: NSRange, in text: NSString, limit: Int) -> [NSRange] {
        guard limit >= 2,
            let range = CheckedTextRange.intersection(
                range, NSRange(location: 0, length: text.length)),
            let end = CheckedTextRange.end(of: range)
        else { return [] }
        var chunks: [NSRange] = []
        var pending: NSRange?
        var offset = range.location

        while offset < end {
            guard let line = CheckedTextRange.intersection(
                text.lineRange(for: NSRange(location: offset, length: 0)), range),
                let lineEnd = CheckedTextRange.end(of: line), line.length > 0
            else { break }
            offset = lineEnd

            let trimmed = AssistScope.trimmingWhitespace(line, in: text)
            guard trimmed.length > 0 else { continue }

            if trimmed.length > limit {
                if let current = pending { chunks.append(current) }
                pending = nil
                chunks.append(contentsOf: splitLongLine(trimmed, in: text, limit: limit))
            } else if let current = pending,
                let combined = CheckedTextRange.covering(current, trimmed),
                combined.length <= limit
            {
                pending = combined
            } else {
                if let current = pending { chunks.append(current) }
                pending = trimmed
            }
        }
        if let pending { chunks.append(pending) }
        return chunks
    }

    private static func splitLongLine(
        _ range: NSRange, in text: NSString, limit: Int
    ) -> [NSRange] {
        guard let end = CheckedTextRange.end(of: range) else { return [] }
        var chunks: [NSRange] = []
        let quotient = range.length / limit
        let remainder = range.length % limit
        chunks.reserveCapacity(quotient + (remainder == 0 ? 0 : 1))
        var offset = range.location

        while offset < end {
            var length = min(limit, end - offset)
            guard let next = CheckedTextRange.end(
                of: NSRange(location: offset, length: length))
            else { return [] }
            if next < end, length > 0 {
                let left = text.character(at: next - 1)
                let right = text.character(at: next)
                if (0xD800...0xDBFF).contains(left), (0xDC00...0xDFFF).contains(right) {
                    length -= 1
                }
            }
            guard length > 0 else { return [] }
            chunks.append(NSRange(location: offset, length: length))
            guard let advanced = CheckedTextRange.end(
                of: NSRange(location: offset, length: length))
            else { return [] }
            offset = advanced
        }
        return chunks
    }
}
