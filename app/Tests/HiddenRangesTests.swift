//
//  HiddenRangesTests.swift
//  MarkDevKitTests
//

import XCTest

@testable import MarkDevKit

final class HiddenRangesTests: XCTestCase {
    func testMergesOverlappingRanges() {
        let h = HiddenRanges(merging: [
            NSRange(location: 0, length: 5),
            NSRange(location: 3, length: 4),
        ])
        XCTAssertEqual(h.ranges, [NSRange(location: 0, length: 7)])
    }

    func testMergesAdjacentRanges() {
        // Touching runs must fuse, or the caret would step through the seam
        // twice for what looks like one marker.
        let h = HiddenRanges(merging: [
            NSRange(location: 0, length: 2),
            NSRange(location: 2, length: 2),
        ])
        XCTAssertEqual(h.ranges, [NSRange(location: 0, length: 4)])
    }

    func testDiscardsEmptyRangesAndSorts() {
        let h = HiddenRanges(merging: [
            NSRange(location: 10, length: 2),
            NSRange(location: 4, length: 0),
            NSRange(location: 0, length: 2),
        ])
        XCTAssertEqual(h.ranges, [NSRange(location: 0, length: 2), NSRange(location: 10, length: 2)])
    }

    func testBoundariesAreNotInside() {
        // The caret must be able to rest immediately outside a marker run.
        let h = HiddenRanges(merging: [NSRange(location: 2, length: 2)])
        XCTAssertFalse(h.contains(2), "start of a hidden run is a legal caret position")
        XCTAssertFalse(h.contains(4), "end of a hidden run is a legal caret position")
        XCTAssertTrue(h.contains(3), "the interior is not")
    }

    func testVisibleOffsetSkipsHiddenText() {
        // "**bold**" with markers at 0..2 and 6..8.
        let h = HiddenRanges(merging: [
            NSRange(location: 0, length: 2),
            NSRange(location: 6, length: 2),
        ])
        XCTAssertEqual(h.visibleOffset(forSource: 0), 0)
        XCTAssertEqual(h.visibleOffset(forSource: 2), 0, "just past the opening ** is visible 0")
        XCTAssertEqual(h.visibleOffset(forSource: 6), 4, "end of 'bold' is visible 4")
        XCTAssertEqual(h.visibleOffset(forSource: 8), 4, "past the closing ** is still visible 4")
    }

    func testVisibleOffsetIsMonotonic() {
        // A non-monotonic mapping would let a selection invert.
        let h = HiddenRanges(merging: [
            NSRange(location: 3, length: 2),
            NSRange(location: 9, length: 4),
        ])
        var previous = -1
        for offset in 0...20 {
            let mapped = h.visibleOffset(forSource: offset)
            XCTAssertGreaterThanOrEqual(mapped, previous, "mapping regressed at \(offset)")
            previous = mapped
        }
    }

    func testNudgeMovesOutOfHiddenRunsInBothDirections() {
        let h = HiddenRanges(merging: [NSRange(location: 4, length: 4)])
        XCTAssertEqual(h.nudge(6, forward: true), 8)
        XCTAssertEqual(h.nudge(6, forward: false), 4)
        XCTAssertEqual(h.nudge(2, forward: true), 2, "offsets outside a run are untouched")
    }

    func testEmptySetIsIdentity() {
        let h = HiddenRanges.none
        XCTAssertEqual(h.visibleOffset(forSource: 17), 17)
        XCTAssertFalse(h.contains(17))
        XCTAssertEqual(h.totalHiddenLength, 0)
    }

    func testTotalHiddenLength() {
        let h = HiddenRanges(merging: [
            NSRange(location: 0, length: 2),
            NSRange(location: 6, length: 3),
        ])
        XCTAssertEqual(h.totalHiddenLength, 5)
    }

    func testRevealingABlockUnhidesOnlyThatBlocksMarkers() {
        let document = ParsedDocument(
            spans: [],
            markers: [
                SyntaxMarker(range: NSRange(location: 0, length: 2), block: 0),
                SyntaxMarker(range: NSRange(location: 8, length: 2), block: 1),
            ],
            blocks: []
        )
        let hidden = HiddenRanges(document: document, revealingBlock: 0)
        XCTAssertEqual(hidden.ranges, [NSRange(location: 8, length: 2)])
    }
}
