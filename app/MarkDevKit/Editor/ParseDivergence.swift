//
//  ParseDivergence.swift
//  MarkDevKit
//
//  Where two parses of one document, separated by a single edit, stop
//  agreeing — and therefore how much of the buffer has to be restyled.
//

import Foundation

/// The range an edit made stale.
///
/// # Why this is not simply "the block you typed in"
///
/// Attributes in `NSTextStorage` move with the text around them, so an element
/// of the parse that came through an edit unchanged is still styled correctly
/// afterwards, wherever it sits. What needs restyling is exactly what the two
/// parses disagree about — which is a question about the parse results, not
/// about the keystroke.
///
/// Each of the three lists is compared from both ends: leading elements as
/// they are, because an edit at offset `n` moves nothing before `n`; trailing
/// elements against their old selves shifted by the edit's length, because
/// that is what an edit does to every offset past it. What lies between the
/// two runs is what changed, and the scope reaches around the whole *extent*
/// of every element in it — elements nest, so a changed list can still hold
/// an item that matched, and stopping at that item would leave the rest of
/// the list wearing the old parse's styling. A list whose every element is
/// accounted for constrains nothing at all.
///
/// The result is one **contiguous** range rather than a union of element
/// ranges. The characters *between* elements — the newlines separating two
/// paragraphs — belong to no element, and a scope stitched together from
/// element ranges leaves them carrying the style of whatever used to surround
/// them.
///
/// # Why all three lists, and not just the blocks
///
/// Block structure catches the loud cases: an opening fence swallowing the
/// rest of the file, a heading demoted to a paragraph. It does not catch a
/// construct whose *meaning* changes with no change to any block — a link
/// reference definition added at the foot of a file turns `[foo]` into a link
/// a thousand lines above it, and nothing about the blocks moves. Comparing
/// the spans and markers as well makes the guarantee a simple one: **the scope
/// covers every element the two parses disagree about**, wherever it is.
enum ParseDivergence {
    /// How much of the parse can have changed.
    enum Depth {
        /// The core proved the edit could not change structure and only moved
        /// offsets — see `Document::apply` in `core/src/md/incremental.rs`.
        /// The spans and markers are then the old ones with new numbers on
        /// them, by construction, so only the blocks are worth comparing.
        case offsetsOnly
        /// The document was reparsed. Anything, anywhere, may have changed.
        case reparsed
    }

    /// The range to restyle, in the post-edit document's coordinates.
    ///
    /// - Parameters:
    ///   - edited: the range the new text occupies, after the edit.
    ///   - delta: how much longer the document became.
    ///   - documentLength: the post-edit length, which the result is clamped to.
    static func restyleScope(
        from previous: ParsedDocument,
        to current: ParsedDocument,
        edited: NSRange,
        delta: Int,
        documentLength: Int,
        depth: Depth
    ) -> NSRange {
        // The replaced range in the *old* document's coordinates.
        let editEndBefore = edited.location + edited.length - delta

        var lower = Int.max
        var upper = Int.min

        /// Narrows the scope to include one list's disagreement, if it has any.
        func consider<Element: ParseElement>(
            _ old: [Element],
            _ new: [Element],
            _ matches: (Element, Element, Int) -> Bool
        ) {
            // Leading run: elements that end before the edit and came through
            // it unchanged. An edit at offset `n` moves no offset below `n`,
            // so these are compared as they are.
            var head = 0
            while head < old.count, head < new.count,
                NSMaxRange(old[head].range) <= edited.location,
                matches(old[head], new[head], 0)
            {
                head += 1
            }

            // Trailing run, from the far end back towards the edit.
            var tail = 0
            while head + tail < old.count, head + tail < new.count,
                old[old.count - 1 - tail].range.location >= editEndBefore,
                matches(old[old.count - 1 - tail], new[new.count - 1 - tail], delta)
            {
                tail += 1
            }

            // Every element accounted for: this list has no opinion.
            guard head + tail < old.count || head + tail < new.count else { return }

            // What is left in the middle is what changed, and the scope has to
            // reach around all of it — *extent*, not merely start offset.
            // Elements nest, so a divergent list can still hold an item the
            // trailing run matched; stopping at that item's start would leave
            // the rest of the list styled from the old parse.
            for element in new[head..<(new.count - tail)] {
                lower = min(lower, element.range.location)
                upper = max(upper, NSMaxRange(element.range))
            }
            // The old parse's divergent elements matter too: an element that
            // disappeared still leaves its text behind, and that text needs
            // restyling where it now sits. Both possible positions are taken,
            // since an element straddling the edit moves only its end.
            for element in old[head..<(old.count - tail)] {
                let range = element.range
                lower = min(lower, min(range.location, range.location + delta))
                upper = max(upper, max(NSMaxRange(range), NSMaxRange(range) + delta))
            }
        }

        consider(previous.blocks, current.blocks) { old, new, delta in
            matches(old, new, shiftedBy: delta)
        }
        if depth == .reparsed {
            consider(previous.spans, current.spans) { old, new, delta in
                matches(old, new, shiftedBy: delta, from: previous, to: current)
            }
            consider(previous.markers, current.markers) { old, new, delta in
                matches(old, new, shiftedBy: delta)
            }
        }

        guard lower <= upper else { return edited }
        let start = max(0, min(lower, documentLength))
        let end = min(max(upper, start), documentLength)
        return NSUnionRange(edited, NSRange(location: start, length: end - start))
    }

    // MARK: - Matching

    private static func matches(
        _ old: BlockDescriptor, _ new: BlockDescriptor, shiftedBy delta: Int
    ) -> Bool {
        old.range.location + delta == new.range.location
            && old.range.length == new.range.length
            && old.kind == new.kind
            && old.depth == new.depth
            && old.data == new.data
            && old.info == new.info
    }

    private static func matches(
        _ old: SyntaxMarker, _ new: SyntaxMarker, shiftedBy delta: Int
    ) -> Bool {
        old.range.location + delta == new.range.location
            && old.range.length == new.range.length
            && old.block == new.block
    }

    private static func matches(
        _ old: StyleSpan,
        _ new: StyleSpan,
        shiftedBy delta: Int,
        from previous: ParsedDocument,
        to current: ParsedDocument
    ) -> Bool {
        guard old.range.location + delta == new.range.location,
            old.range.length == new.range.length,
            old.kind == new.kind,
            old.depth == new.depth
        else { return false }

        switch old.kind {
        case .link, .wikiLink, .image:
            // `data` indexes the parse's own string table, which is renumbered
            // whenever a link anywhere in the document appears or disappears.
            // Two spans with the same number can point at different notes, so
            // compare what it points at rather than the number.
            return previous.target(for: old) == current.target(for: new)
        default:
            return old.data == new.data
        }
    }
}

/// One element of a parse result, positioned in the document.
protocol ParseElement {
    var range: NSRange { get }
}

extension BlockDescriptor: ParseElement {}
extension StyleSpan: ParseElement {}
extension SyntaxMarker: ParseElement {}
