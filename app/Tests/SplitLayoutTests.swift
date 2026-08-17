//
//  SplitLayoutTests.swift
//  MarkDevKitTests
//

import XCTest

@testable import MarkDevKit

final class SplitLayoutTests: XCTestCase {
    private func makePanes(_ count: Int) -> [PaneID] {
        (0..<count).map { _ in PaneID() }
    }

    /// Every split's fractions must sum to 1 and stay above the minimum, or a
    /// pane ends up with no area and no way to get it back.
    private func assertInvariants(
        _ layout: SplitLayout, file: StaticString = #filePath, line: UInt = #line
    ) {
        func check(_ node: SplitNode) {
            guard case .split(let group) = node else { return }
            XCTAssertGreaterThanOrEqual(
                group.children.count, 2, "a split must have at least two children",
                file: file, line: line)
            XCTAssertEqual(
                group.fractions.count, group.children.count,
                "fractions must match children", file: file, line: line)
            XCTAssertEqual(
                group.fractions.reduce(0, +), 1.0, accuracy: 0.0001,
                "fractions must sum to 1", file: file, line: line)
            for fraction in group.fractions {
                XCTAssertGreaterThan(fraction, 0, "no pane may have zero area", file: file, line: line)
            }
            group.children.forEach(check)
        }
        check(layout.root)
    }

    /// Every node in the tree, depth first.
    private func allNodes(_ node: SplitNode) -> [SplitNode] {
        guard case .split(let group) = node else { return [node] }
        return [node] + group.children.flatMap(allNodes)
    }

    // MARK: - Node identity

    // The renderer keys its children on `SplitNode.id`. If two nodes could
    // share one, SwiftUI would hand one pane's editor to another; if a pane's
    // id changed when a *sibling* closed, every pane after the closed one
    // would be rebuilt, losing its scroll position and undo history.

    func testNodeIdentityIsUniqueAcrossTheTree() {
        let panes = makePanes(4)
        var layout = SplitLayout(pane: panes[0])
        layout.split(panes[0], edge: .trailing, with: panes[1])
        layout.split(panes[1], edge: .bottom, with: panes[2])
        layout.split(panes[2], edge: .trailing, with: panes[3])

        let ids = allNodes(layout.root).map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "no two nodes may share an identity")
    }

    func testALeafIdentifiesItselfByItsPane() {
        let pane = PaneID()
        XCTAssertEqual(SplitNode.leaf(pane).id, pane.id)
    }

    func testAPanesIdentitySurvivesAnEarlierSiblingClosing() {
        let panes = makePanes(3)
        var layout = SplitLayout(pane: panes[0])
        layout.split(panes[0], edge: .trailing, with: panes[1])
        layout.split(panes[1], edge: .trailing, with: panes[2])

        let before = allNodes(layout.root).first { $0 == .leaf(panes[2]) }?.id
        layout.close(panes[0])
        let after = allNodes(layout.root).first { $0 == .leaf(panes[2]) }?.id

        XCTAssertNotNil(after)
        XCTAssertEqual(before, after, "closing a sibling must not re-identify a pane")
    }

    // MARK: - Splitting

    func testSinglePaneHasNoSplits() {
        let pane = PaneID()
        let layout = SplitLayout(pane: pane)
        XCTAssertEqual(layout.panes, [pane])
        XCTAssertEqual(layout.paneCount, 1)
    }

    func testSplittingTrailingPlacesNewPaneAfter() {
        let panes = makePanes(2)
        var layout = SplitLayout(pane: panes[0])
        layout.split(panes[0], edge: .trailing, with: panes[1])

        XCTAssertEqual(layout.panes, [panes[0], panes[1]])
        assertInvariants(layout)
    }

    func testSplittingLeadingPlacesNewPaneBefore() {
        let panes = makePanes(2)
        var layout = SplitLayout(pane: panes[0])
        layout.split(panes[0], edge: .leading, with: panes[1])

        XCTAssertEqual(layout.panes, [panes[1], panes[0]])
        assertInvariants(layout)
    }

    func testThreeWaySplitStaysFlat() {
        // Splitting the same axis repeatedly must extend one split rather
        // than nesting. A nested tree would make dividers resize different
        // amounts of the window depending on their depth.
        let panes = makePanes(3)
        var layout = SplitLayout(pane: panes[0])
        layout.split(panes[0], edge: .trailing, with: panes[1])
        layout.split(panes[1], edge: .trailing, with: panes[2])

        guard case .split(let group) = layout.root else {
            return XCTFail("expected a split at the root")
        }
        XCTAssertEqual(group.children.count, 3, "three side-by-side panes should be one split")
        XCTAssertEqual(layout.panes, panes)
        assertInvariants(layout)
    }

    func testCrossAxisSplitNests() {
        let panes = makePanes(3)
        var layout = SplitLayout(pane: panes[0])
        layout.split(panes[0], edge: .trailing, with: panes[1])
        layout.split(panes[1], edge: .bottom, with: panes[2])

        guard case .split(let group) = layout.root else {
            return XCTFail("expected a split at the root")
        }
        XCTAssertEqual(group.axis, .horizontal)
        XCTAssertEqual(group.children.count, 2, "the vertical split should nest, not flatten")
        XCTAssertEqual(layout.panes, panes)
        assertInvariants(layout)
    }

    func testSplittingTakesSpaceOnlyFromTheTargetPane() {
        // A new pane should halve its neighbour, not reshuffle the whole
        // window — otherwise every split jolts the layout.
        let panes = makePanes(3)
        var layout = SplitLayout(pane: panes[0])
        layout.split(panes[0], edge: .trailing, with: panes[1])
        layout.split(panes[0], edge: .trailing, with: panes[2])

        guard case .split(let group) = layout.root else {
            return XCTFail("expected a split")
        }
        // panes[1] kept its half; panes[0] and panes[2] share the other half.
        let second = group.fractions[group.children.firstIndex(of: .leaf(panes[1]))!]
        XCTAssertEqual(second, 0.5, accuracy: 0.0001, "the untouched pane keeps its size")
        assertInvariants(layout)
    }

    func testSplittingAnUnknownPaneDoesNothing() {
        let panes = makePanes(2)
        var layout = SplitLayout(pane: panes[0])
        layout.split(PaneID(), edge: .trailing, with: panes[1])
        XCTAssertEqual(layout.panes, [panes[0]])
    }

    // MARK: - Closing

    func testClosingCollapsesASingleChildSplit() {
        let panes = makePanes(2)
        var layout = SplitLayout(pane: panes[0])
        layout.split(panes[0], edge: .trailing, with: panes[1])

        XCTAssertTrue(layout.close(panes[1]))
        XCTAssertEqual(layout.root, .leaf(panes[0]), "a lone survivor should replace the split")
        assertInvariants(layout)
    }

    func testClosingTheLastPaneIsRefused() {
        // A window with no panes has nothing to show and no way back.
        let pane = PaneID()
        var layout = SplitLayout(pane: pane)
        XCTAssertFalse(layout.close(pane))
        XCTAssertEqual(layout.panes, [pane])
    }

    func testClosingRedistributesSpace() {
        let panes = makePanes(3)
        var layout = SplitLayout(pane: panes[0])
        layout.split(panes[0], edge: .trailing, with: panes[1])
        layout.split(panes[1], edge: .trailing, with: panes[2])

        XCTAssertTrue(layout.close(panes[1]))
        XCTAssertEqual(layout.panes, [panes[0], panes[2]])
        assertInvariants(layout)
    }

    func testClosingFlattensNestedSplits() {
        let panes = makePanes(3)
        var layout = SplitLayout(pane: panes[0])
        layout.split(panes[0], edge: .trailing, with: panes[1])
        layout.split(panes[1], edge: .bottom, with: panes[2])

        // Removing one side of the nested vertical split should leave a
        // plain two-pane horizontal split, not a split wrapping a split.
        XCTAssertTrue(layout.close(panes[2]))
        guard case .split(let group) = layout.root else {
            return XCTFail("expected a split")
        }
        XCTAssertEqual(group.children, [.leaf(panes[0]), .leaf(panes[1])])
        assertInvariants(layout)
    }

    // MARK: - Resizing

    func testResizingMovesOnlyTheAdjacentPair() {
        let panes = makePanes(3)
        var layout = SplitLayout(pane: panes[0])
        layout.split(panes[0], edge: .trailing, with: panes[1])
        layout.split(panes[1], edge: .trailing, with: panes[2])

        guard case .split(let before) = layout.root else { return XCTFail("expected a split") }
        let untouched = before.fractions[2]

        layout.resize(split: before.id, dividerAfter: 0, by: 0.1)

        guard case .split(let after) = layout.root else { return XCTFail("expected a split") }
        XCTAssertEqual(after.fractions[0], before.fractions[0] + 0.1, accuracy: 0.0001)
        XCTAssertEqual(after.fractions[1], before.fractions[1] - 0.1, accuracy: 0.0001)
        XCTAssertEqual(after.fractions[2], untouched, accuracy: 0.0001, "the far pane must not move")
        assertInvariants(layout)
    }

    func testResizingCannotCollapseAPane() {
        // Dragging a divider past the end must stop, not delete a pane.
        let panes = makePanes(2)
        var layout = SplitLayout(pane: panes[0])
        layout.split(panes[0], edge: .trailing, with: panes[1])

        guard case .split(let group) = layout.root else { return XCTFail("expected a split") }
        layout.resize(split: group.id, dividerAfter: 0, by: -10)

        guard case .split(let after) = layout.root else { return XCTFail("expected a split") }
        XCTAssertEqual(after.fractions[0], SplitLayout.minimumFraction, accuracy: 0.0001)
        assertInvariants(layout)

        layout.resize(split: group.id, dividerAfter: 0, by: 10)
        guard case .split(let far) = layout.root else { return XCTFail("expected a split") }
        XCTAssertEqual(
            far.fractions[1], SplitLayout.minimumFraction, accuracy: 0.0001,
            "the other direction must clamp too")
    }

    func testResizingAnUnknownDividerIsIgnored() {
        let panes = makePanes(2)
        var layout = SplitLayout(pane: panes[0])
        layout.split(panes[0], edge: .trailing, with: panes[1])
        let before = layout

        guard case .split(let group) = layout.root else { return XCTFail("expected a split") }
        layout.resize(split: group.id, dividerAfter: 99, by: 0.2)
        XCTAssertEqual(layout, before)

        layout.resize(split: SplitID(), dividerAfter: 0, by: 0.2)
        XCTAssertEqual(layout, before)
    }

    // MARK: - Stress

    func testManySplitsAndClosesKeepInvariants() {
        var layout = SplitLayout(pane: PaneID())
        var live = layout.panes
        let edges: [SplitEdge] = [.trailing, .bottom, .leading, .top]

        for step in 0..<60 {
            let target = live[step % live.count]
            let new = PaneID()
            layout.split(target, edge: edges[step % edges.count], with: new)
            live = layout.panes
            assertInvariants(layout)

            if step % 3 == 2, live.count > 1 {
                layout.close(live[0])
                live = layout.panes
                assertInvariants(layout)
            }
        }

        XCTAssertFalse(layout.panes.isEmpty)
        XCTAssertEqual(Set(layout.panes).count, layout.panes.count, "panes must stay unique")
    }
}
