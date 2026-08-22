//
//  VaultGraphTests.swift
//  MarkDevKitTests
//
//  The graph as it crosses the FFI, and the geometry the canvas draws with.
//

import XCTest

@testable import MarkDevKit

@MainActor
final class VaultGraphTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevGraph-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func vault(_ notes: [String: String]) throws -> VaultIndex {
        for (name, source) in notes {
            let url = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try source.write(to: url, atomically: true, encoding: .utf8)
        }
        let index = VaultIndex()
        index.open(directory)
        return index
    }

    // MARK: - Crossing the boundary

    func testTheGraphDecodesWithItsSnakeCaseCount() throws {
        // `total_notes` on the Rust side, `totalNotes` here. A decode failure
        // would surface as a silently empty graph, which is indistinguishable
        // from a vault with no links.
        let index = try vault([
            "A.md": "# A\n\nSee [[B]].\n",
            "B.md": "# B\n",
        ])
        let graph = index.graph()

        XCTAssertEqual(graph.totalNotes, 2)
        XCTAssertEqual(graph.nodes.count, 2)
        XCTAssertEqual(graph.edges.count, 1)
        XCTAssertFalse(graph.truncated)
    }

    func testEdgesIndexIntoTheNodesTheyWereBuiltWith() throws {
        // The edge indices are dense positions into `nodes`. If they were
        // vault-wide indices, a filtered graph would draw lines to whichever
        // notes happened to sit at those positions.
        let index = try vault([
            "A.md": "[[B]]\n",
            "B.md": "x\n",
            "C.md": "x\n",
        ])
        let graph = index.graph()

        for edge in graph.edges {
            XCTAssertTrue(graph.nodes.indices.contains(edge.source))
            XCTAssertTrue(graph.nodes.indices.contains(edge.target))
        }
        let linked = Set(graph.edges.flatMap { [graph.nodes[$0.source].path, graph.nodes[$0.target].path] })
        XCTAssertEqual(linked, ["A.md", "B.md"])
    }

    func testALocalGraphIsLimitedToItsNeighbourhood() throws {
        let index = try vault([
            "A.md": "[[B]]\n",
            "B.md": "[[C]]\n",
            "C.md": "x\n",
            "Elsewhere.md": "unrelated\n",
        ])
        let graph = index.graph(focus: "A.md", depth: 1)

        XCTAssertEqual(Set(graph.nodes.map(\.path)), ["A.md", "B.md"])
        XCTAssertEqual(graph.totalNotes, 4, "the count still describes the whole vault")
    }

    func testATagFilterReachesTheCore() throws {
        let index = try vault([
            "A.md": "#project\n",
            "B.md": "no tag\n",
        ])
        XCTAssertEqual(index.graph(tag: "project").nodes.map(\.path), ["A.md"])
        // A leading `#` is how the tag browser shows them.
        XCTAssertEqual(index.graph(tag: "#project").nodes.map(\.path), ["A.md"])
    }

    func testAnUnopenedVaultReturnsAnEmptyGraphRatherThanCrashing() {
        XCTAssertEqual(VaultIndex().graph(), .empty)
    }

    func testAnAbsurdDepthIsClampedRatherThanPassedThrough() throws {
        // The depth reaches a breadth-first walk in Rust. An unbounded value
        // from a stale preference must not become an unbounded traversal.
        let index = try vault(["A.md": "[[B]]\n", "B.md": "x\n"])
        let graph = index.graph(focus: "A.md", depth: Int.max)
        XCTAssertEqual(graph.nodes.count, 2)
    }

    /// The off-main path is the *same* computation on another thread: the
    /// layout is deterministic, so both answers must agree exactly.
    func testTheOffMainGraphMatchesTheSynchronousOne() async throws {
        let index = try vault([
            "A.md": "[[B]]\n[[C]]\n",
            "B.md": "[[C]]\n",
            "C.md": "x\n",
        ])

        let sync = index.graph(depth: 3)
        let async = await index.graphOffMain(depth: 3)

        XCTAssertEqual(async.nodes.map(\.path), sync.nodes.map(\.path))
        XCTAssertEqual(async.edges, sync.edges)
        for (asyncNode, syncNode) in zip(async.nodes, sync.nodes) {
            XCTAssertEqual(asyncNode.x, syncNode.x, accuracy: 0.0001)
            XCTAssertEqual(asyncNode.y, syncNode.y, accuracy: 0.0001)
        }
    }

    func testTheOffMainGraphSurvivesConcurrentIndexUpdates() async throws {
        // The whole point of taking the lock: a layout running while the main
        // actor re-indexes a note must neither crash nor corrupt either side.
        let index = try vault([
            "A.md": "[[B]]\n",
            "B.md": "x\n",
        ])
        async let background: VaultGraph = index.graphOffMain(depth: 2)
        index.update(path: "B.md", text: "[[A]]\n")
        let graph = await background
        XCTAssertFalse(graph.nodes.isEmpty)
    }

    // MARK: - Geometry

    private func graph(_ points: [(String, Double, Double)]) -> VaultGraph {
        VaultGraph(
            nodes: points.map { path, x, y in
                VaultGraphNode(
                    path: path, title: "", tags: [], degree: 1, depth: 0, x: x, y: y)
            },
            edges: [], totalNotes: points.count, truncated: false)
    }

    func testTheLayoutIsFittedToTheContentNotTheCoresCanvas() {
        // Two notes occupy a corner of the core's 1000pt canvas. Scaling to
        // the canvas rather than to the content would draw them as two specks
        // in the middle of an empty panel.
        let model = graph([("A.md", 400, 480), ("B.md", 600, 520)])
        let size = CGSize(width: 800, height: 600)

        let a = model.point(for: model.nodes[0], in: size)
        let b = model.point(for: model.nodes[1], in: size)
        XCTAssertGreaterThan(abs(a.x - b.x), 200, "the pair should fill the panel")
    }

    func testBothAxesShareOneScale() {
        // Scaling independently would stretch a chain into a line across the
        // panel, which reads as a bug rather than as a chain.
        let model = graph([("A.md", 0, 0), ("B.md", 100, 10)])
        let size = CGSize(width: 900, height: 300)

        let a = model.point(for: model.nodes[0], in: size)
        let b = model.point(for: model.nodes[1], in: size)
        let ratio = abs(b.x - a.x) / max(abs(b.y - a.y), 0.001)
        XCTAssertEqual(ratio, 10, accuracy: 0.5, "the 10:1 aspect must survive the fit")
    }

    func testASingleNodeDoesNotDivideByZeroExtent() {
        let model = graph([("Only.md", 500, 500)])
        let point = model.point(for: model.nodes[0], in: CGSize(width: 400, height: 400))
        XCTAssertTrue(point.x.isFinite && point.y.isFinite)
    }

    func testEveryNodeLandsInsideTheView() {
        let model = graph([
            ("A.md", 0, 0), ("B.md", 1000, 1000), ("C.md", 500, 0), ("D.md", 0, 1000),
        ])
        let size = CGSize(width: 640, height: 480)

        for node in model.nodes {
            let point = model.point(for: node, in: size)
            XCTAssertTrue((0...size.width).contains(point.x), "\(node.path) at \(point)")
            XCTAssertTrue((0...size.height).contains(point.y), "\(node.path) at \(point)")
        }
    }

    func testAZeroSizedViewDoesNotProduceNaN() {
        // SwiftUI hands a view a zero size for a frame or two during window
        // setup. A NaN reaching a `Path` corrupts the whole drawing pass
        // rather than failing where it was produced.
        let model = graph([("A.md", 0, 0), ("B.md", 100, 100)])
        for node in model.nodes {
            let point = model.point(for: node, in: .zero)
            XCTAssertFalse(point.x.isNaN || point.y.isNaN, "\(node.path) at \(point)")
        }
    }

    // MARK: - Hit testing

    func testClickingANodeFindsIt() {
        let model = graph([("A.md", 0, 0), ("B.md", 1000, 1000)])
        let size = CGSize(width: 500, height: 500)
        let target = model.point(for: model.nodes[1], in: size)

        XCTAssertEqual(model.node(nearest: target, in: size)?.path, "B.md")
    }

    func testClickingEmptyCanvasFindsNothing() {
        // Without a distance limit a click anywhere would open whichever note
        // happened to be least far away, which makes the canvas untappable.
        let model = graph([("A.md", 500, 500)])
        let size = CGSize(width: 500, height: 500)

        XCTAssertNil(model.node(nearest: CGPoint(x: 5, y: 5), in: size))
    }

    func testTheNearestNodeWinsWhenTwoAreInRange() {
        let model = graph([("A.md", 480, 500), ("B.md", 520, 500)])
        let size = CGSize(width: 600, height: 600)
        let near = model.point(for: model.nodes[0], in: size)

        XCTAssertEqual(
            model.node(nearest: CGPoint(x: near.x + 3, y: near.y), in: size)?.path, "A.md")
    }

    // MARK: - Labels

    func testAnUntitledNoteFallsBackToItsFileName() {
        // An unlabelled dot is not worth drawing.
        let node = VaultGraphNode(
            path: "folder/Some Note.md", title: "   ", tags: [], degree: 0, depth: 0, x: 0, y: 0)
        XCTAssertEqual(node.displayName, "Some Note")
    }

    func testATitledNoteUsesItsTitle() {
        let node = VaultGraphNode(
            path: "folder/note.md", title: "Real Title", tags: [], degree: 0, depth: 0, x: 0, y: 0)
        XCTAssertEqual(node.displayName, "Real Title")
    }
}
