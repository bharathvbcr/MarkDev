//
//  GraphPanelStateTests.swift
//  MarkDevKitTests
//
//  State transitions that keep the graph controls and canvas truthful.
//

import XCTest

@testable import MarkDevKit

@MainActor
final class GraphPanelStateTests: XCTestCase {
    func testAContentEditAdvancesRevisionWhenTheNoteCountDoesNotChange() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevGraphPanel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try "[[B]]\n".write(
            to: directory.appendingPathComponent("A.md"), atomically: true, encoding: .utf8)
        try "B\n".write(
            to: directory.appendingPathComponent("B.md"), atomically: true, encoding: .utf8)
        let index = VaultIndex()
        index.open(directory)
        let count = index.noteCount
        let revision = index.contentRevision

        index.update(path: "A.md", text: "No links now.\n")

        XCTAssertEqual(index.noteCount, count)
        XCTAssertGreaterThan(index.contentRevision, revision)
        XCTAssertTrue(index.graph().edges.isEmpty)
    }

    func testNoCurrentNoteNormalizesLocalScopeToWholeVault() {
        XCTAssertEqual(GraphPanel.resolvedScope(.local, current: nil), .whole)
        XCTAssertEqual(GraphPanel.resolvedScope(.local, current: "A.md"), .local)
    }

    func testRebuildIdentityChangesWithContentRevision() {
        let before = GraphPanel.rebuildIdentity(
            scope: .whole, depth: 2, tag: nil, current: nil, contentRevision: 10)
        let after = GraphPanel.rebuildIdentity(
            scope: .whole, depth: 2, tag: nil, current: nil, contentRevision: 11)

        XCTAssertNotEqual(before, after)
    }

    func testAnEmptyRecomputeReplacesThePreviouslyDrawnGraph() {
        let previous = VaultGraph(
            nodes: [
                VaultGraphNode(
                    path: "A.md", title: "A", tags: [], degree: 0, depth: 0, x: 0, y: 0)
            ],
            edges: [], totalNotes: 1, truncated: false)

        XCTAssertEqual(
            GraphPanel.graphAfterRebuild(previous: previous, computed: .empty),
            .empty)
    }

    func testOnlyTheLatestUncancelledGraphRequestMayPublish() {
        let old = GraphPanel.rebuildIdentity(
            scope: .whole, depth: 2, tag: nil, current: nil, contentRevision: 10)
        let current = GraphPanel.rebuildIdentity(
            scope: .whole, depth: 2, tag: nil, current: nil, contentRevision: 11)

        XCTAssertFalse(
            GraphPanel.acceptsRebuildResult(
                request: old,
                generation: 4,
                current: current,
                currentGeneration: 5,
                isCancelled: false))
        XCTAssertFalse(
            GraphPanel.acceptsRebuildResult(
                request: current,
                generation: 4,
                current: current,
                currentGeneration: 5,
                isCancelled: false))
        XCTAssertFalse(
            GraphPanel.acceptsRebuildResult(
                request: current,
                generation: 5,
                current: current,
                currentGeneration: 5,
                isCancelled: true))
        XCTAssertTrue(
            GraphPanel.acceptsRebuildResult(
                request: current,
                generation: 5,
                current: current,
                currentGeneration: 5,
                isCancelled: false))
    }
}
