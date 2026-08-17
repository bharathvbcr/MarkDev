//
//  HiddenRanges.swift
//  MarkDevKit
//
//  The set of collapsed syntax markers, and the offset arithmetic that
//  depends on it.
//

import Foundation

/// A normalised, sorted set of hidden character ranges.
///
/// This is the shared foundation for two things that must agree exactly:
///
/// - the read-only renderer, which *deletes* hidden text, and
/// - the live editor, which *draws around* hidden text but must move the
///   caret as though it were deleted.
///
/// Keeping both on one type is deliberate. If caret movement and rendering
/// ever disagreed about what is hidden, the caret would appear to stick or
/// skip for no visible reason — the classic failure of hand-rolled live
/// preview.
public struct HiddenRanges: Sendable, Equatable {
    /// Non-overlapping, ascending, non-empty ranges.
    public let ranges: [NSRange]

    /// Total hidden length at or before each range's start, so offset
    /// mapping is a binary search rather than a scan.
    private let hiddenBefore: [Int]

    public static let none = HiddenRanges(ranges: [])

    /// Merges and sorts `input`, discarding empty ranges.
    public init(merging input: [NSRange]) {
        let sorted = input.filter { $0.length > 0 }.sorted {
            $0.location == $1.location ? $0.length < $1.length : $0.location < $1.location
        }

        var merged: [NSRange] = []
        for range in sorted {
            if let last = merged.last, range.location <= last.location + last.length {
                // Overlapping or adjacent: extend rather than append, so
                // `**bold**` never yields two touching marker runs that the
                // caret would have to step through twice.
                let end = max(last.location + last.length, range.location + range.length)
                merged[merged.count - 1] = NSRange(location: last.location, length: end - last.location)
            } else {
                merged.append(range)
            }
        }
        self.init(ranges: merged)
    }

    /// Assumes `ranges` is already normalised.
    private init(ranges: [NSRange]) {
        self.ranges = ranges
        var running = 0
        var prefix: [Int] = []
        prefix.reserveCapacity(ranges.count)
        for range in ranges {
            prefix.append(running)
            running += range.length
        }
        self.hiddenBefore = prefix
    }

    /// Total number of hidden characters.
    public var totalHiddenLength: Int {
        guard let last = ranges.last, let before = hiddenBefore.last else { return 0 }
        return before + last.length
    }

    /// Whether `offset` falls strictly inside a hidden run.
    ///
    /// Boundaries are *not* inside: an offset at the start or end of a hidden
    /// run is a legal caret position, which is what lets the caret rest just
    /// outside `**` rather than being pushed away from it.
    public func contains(_ offset: Int) -> Bool {
        guard let i = index(covering: offset) else { return false }
        let r = ranges[i]
        return offset > r.location && offset < r.location + r.length
    }

    /// The hidden range containing `offset` strictly inside it, if any.
    public func range(containing offset: Int) -> NSRange? {
        guard let i = index(covering: offset) else { return nil }
        let r = ranges[i]
        return (offset > r.location && offset < r.location + r.length) ? r : nil
    }

    /// Maps an offset in the full source to its offset in the text that
    /// remains once hidden runs are removed.
    ///
    /// Offsets inside a hidden run map to where that run begins, so a
    /// position with no visible counterpart still resolves to a sane one.
    ///
    /// Binary search over the prefix sums, not a scan: this is called once
    /// per span while rendering, so a linear implementation makes whole-file
    /// rendering quadratic.
    public func visibleOffset(forSource offset: Int) -> Int {
        guard !ranges.isEmpty else { return max(0, offset) }

        // Last range starting strictly before `offset`.
        var low = 0
        var high = ranges.count - 1
        var found = -1
        while low <= high {
            let mid = (low + high) / 2
            if ranges[mid].location < offset {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        guard found >= 0 else { return max(0, offset) }

        let range = ranges[found]
        // Either the offset is past this run entirely, or inside it — in
        // which case only the part before the offset counts as hidden.
        let within = min(range.length, offset - range.location)
        let hidden = hiddenBefore[found] + within
        return max(0, offset - hidden)
    }

    /// Whether `range` lies entirely within a single hidden run.
    ///
    /// Binary search rather than a scan, for the same reason as
    /// ``visibleOffset(forSource:)`` — the styler asks this once per marker.
    public func covers(_ range: NSRange) -> Bool {
        guard let i = index(covering: range.location) else { return false }
        let run = ranges[i]
        return range.location >= run.location
            && range.location + range.length <= run.location + run.length
    }

    /// Whether the line holding `offset` is nothing but hidden syntax.
    ///
    /// The newline that ends the line does not count: it is never part of a
    /// marker, and a line whose every visible character is collapsed is
    /// already a line with nothing to show.
    ///
    /// Shared by the two halves of one decision — the styler takes the height
    /// off such a line, and the editor draws a label in its place — so that
    /// "there is nothing here to see" and "something must stand in for it"
    /// can never disagree.
    public func hidesWholeLine(at offset: Int, in text: NSString) -> Bool {
        guard offset >= 0, offset <= text.length else { return false }
        let line = text.lineRange(for: NSRange(location: min(offset, max(text.length - 1, 0)), length: 0))
        let body = HiddenRanges.contentRange(of: line, in: text)
        return body.length > 0 && covers(body)
    }

    /// A line's text, without the newline that ends it.
    static func contentRange(of line: NSRange, in text: NSString) -> NSRange {
        var end = NSMaxRange(line)
        while end > line.location {
            let character = text.character(at: end - 1)
            guard character == 0x0A || character == 0x0D else { break }
            end -= 1
        }
        return NSRange(location: line.location, length: end - line.location)
    }

    /// Moves `offset` out of any hidden run, in the given direction.
    ///
    /// This is what arrow keys and click-positioning use so a hidden marker
    /// behaves as though it were zero-width.
    public func nudge(_ offset: Int, forward: Bool) -> Int {
        guard let r = range(containing: offset) else { return offset }
        return forward ? r.location + r.length : r.location
    }

    /// Index of the range whose span covers `offset`, inclusive of bounds.
    private func index(covering offset: Int) -> Int? {
        var low = 0
        var high = ranges.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let r = ranges[mid]
            if offset < r.location {
                high = mid - 1
            } else if offset > r.location + r.length {
                low = mid + 1
            } else {
                return mid
            }
        }
        return nil
    }
}

extension HiddenRanges {
    /// The markers of `document`, optionally revealing the block the caret is
    /// in.
    ///
    /// Revealing per block — rather than per marker — is what makes editing
    /// feel stable: the whole construct under the caret shows its syntax at
    /// once, instead of characters appearing one at a time as the caret
    /// crosses them.
    public init(document: ParsedDocument, revealingBlock block: Int? = nil) {
        self.init(
            merging: document.markers
                .filter { block == nil || $0.block != block! }
                .map(\.range)
        )
    }
}
