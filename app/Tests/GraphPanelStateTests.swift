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
            scope: .whole,
            depth: 2,
            tag: nil,
            current: nil,
            contentVersion: VaultContentVersion(revision: 10))
        let after = GraphPanel.rebuildIdentity(
            scope: .whole,
            depth: 2,
            tag: nil,
            current: nil,
            contentVersion: VaultContentVersion(revision: 11))

        XCTAssertEqual(before.contentVersion.revision, 10)
        XCTAssertEqual(after.contentVersion.revision, 11)
        XCTAssertNotEqual(before, after)
    }

    func testVaultRevisionSaturatesWhileItsCacheIdentityKeepsAdvancing() {
        let maximum = VaultContentVersion(revision: UInt64.max)
        let advanced = maximum.advanced()

        XCTAssertEqual(advanced.revision, UInt64.max)
        XCTAssertNotEqual(
            advanced,
            maximum,
            "a content change at the numeric ceiling must still invalidate graph caches")

        let before = GraphPanel.rebuildIdentity(
            scope: .whole, depth: 2, tag: nil, current: nil, contentVersion: maximum)
        let after = GraphPanel.rebuildIdentity(
            scope: .whole, depth: 2, tag: nil, current: nil, contentVersion: advanced)
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

    func testOnlyTheLatestUncancelledGraphRequestMayPublish() throws {
        let old = GraphPanel.rebuildIdentity(
            scope: .whole,
            depth: 2,
            tag: nil,
            current: nil,
            contentVersion: VaultContentVersion(revision: 10))
        let current = GraphPanel.rebuildIdentity(
            scope: .whole,
            depth: 2,
            tag: nil,
            current: nil,
            contentVersion: VaultContentVersion(revision: 11))
        let staleIdentity = try XCTUnwrap(
            UUID(uuidString: "00000000-0000-0000-0000-000000000003"))
        let currentIdentity = try XCTUnwrap(
            UUID(uuidString: "00000000-0000-0000-0000-000000000004"))

        XCTAssertFalse(
            GraphPanel.acceptsRebuildResult(
                request: old,
                identityToken: staleIdentity,
                current: current,
                currentIdentityToken: currentIdentity,
                isCancelled: false))
        XCTAssertFalse(
            GraphPanel.acceptsRebuildResult(
                request: current,
                identityToken: staleIdentity,
                current: current,
                currentIdentityToken: currentIdentity,
                isCancelled: false))
        XCTAssertFalse(
            GraphPanel.acceptsRebuildResult(
                request: current,
                identityToken: currentIdentity,
                current: current,
                currentIdentityToken: currentIdentity,
                isCancelled: true))
        XCTAssertTrue(
            GraphPanel.acceptsRebuildResult(
                request: current,
                identityToken: currentIdentity,
                current: current,
                currentIdentityToken: currentIdentity,
                isCancelled: false))
    }
}

/// Guards every asynchronous/cache identity audited alongside the graph.
///
/// These checks deliberately read the production sources: the vulnerable
/// state is private and only becomes observable after billions of invalidations.
/// A finite stress loop cannot prove that a wrapping counter never aliases an
/// old callback or cache key, while this contract names the exact forbidden
/// mechanism and stays executable in the ordinary app test target.
final class GenerationIdentityContractTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // app
            .deletingLastPathComponent() // repository
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8)
    }

    func testCallbackAndCacheIdentitiesCannotAliasAfterIntegerWrap() throws {
        let wrappingOwners = [
            "app/MarkDevKit/Vault/VaultIndex.swift",
            "app/MarkDevKit/Vault/GraphPanel.swift",
            "app/MarkDevKit/Intelligence/WritingAssistant.swift",
            "app/MarkDevKit/Intelligence/DocumentAssistant.swift",
            "app/MarkDevKit/Editor/TableRowLayout.swift",
        ]

        for path in wrappingOwners {
            XCTAssertFalse(
                try source(path).contains("&+="),
                "\(path) must not authorize stale work with a wrapping integer")
        }

        let table = try source("app/MarkDevKit/Editor/TableRowLayout.swift")
        XCTAssertFalse(
            table.contains("private var revision"),
            "a redundant finite cache revision can alias and is unnecessary when invalidation clears the map")
        XCTAssertTrue(
            table.contains("tables.removeAll(keepingCapacity: true)"),
            "table cache invalidation must keep its synchronous clear as the canonical boundary")

        let request = try source("app/MarkDevKit/Intelligence/IntelligenceService.swift")
        XCTAssertFalse(
            request.contains("generation += 1"),
            "IntelligenceRequest must not trap at integer exhaustion or reuse an old identity")

        for path in [
            "app/MarkDevKit/Vault/VaultIndex.swift",
            "app/MarkDevKit/Vault/GraphPanel.swift",
            "app/MarkDevKit/Intelligence/WritingAssistant.swift",
            "app/MarkDevKit/Intelligence/DocumentAssistant.swift",
            "app/MarkDevKit/Intelligence/IntelligenceService.swift",
        ] {
            XCTAssertTrue(
                try source(path).contains("UUID"),
                "\(path) must use a non-wrapping identity at its stale-work boundary")
        }
    }
}
