//
//  NavigatorStateTests.swift
//  MarkDevKitTests
//
//  Reload and vault-wide filter state that does not require a live SwiftUI tree.
//

import XCTest

@testable import MarkDevKit

final class NavigatorTreeReloadTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevNavigator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testRevisionReloadPreservesAndRehydratesExistingExpansion() throws {
        let projects = root.appendingPathComponent("Projects", isDirectory: true)
        let current = projects.appendingPathComponent("Current", isDirectory: true)
        let note = current.appendingPathComponent("Plan.md")
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try "# Plan".write(to: note, atomically: true, encoding: .utf8)

        let snapshot = NavigatorTreeReloader.rebuild(
            root: root,
            previousRoot: root,
            expanded: [projects, current])

        XCTAssertEqual(snapshot.expanded, [projects, current])
        let projectsNode = try XCTUnwrap(snapshot.nodes.first { $0.url == projects })
        let currentNode = try XCTUnwrap(projectsNode.children?.first { $0.url == current })
        XCTAssertEqual(currentNode.children?.map(\.url), [note])
    }

    func testRevisionReloadPrunesADeletedExpandedDirectoryWithoutLosingItsParent() throws {
        let projects = root.appendingPathComponent("Projects", isDirectory: true)
        let removed = projects.appendingPathComponent("Removed", isDirectory: true)
        try FileManager.default.createDirectory(at: removed, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: removed)

        let snapshot = NavigatorTreeReloader.rebuild(
            root: root,
            previousRoot: root,
            expanded: [projects, removed])

        XCTAssertEqual(snapshot.expanded, [projects])
        XCTAssertNotNil(snapshot.nodes.first { $0.url == projects }?.children)
    }

    func testAChildsExpansionSurvivesItsParentBeingCollapsedAndReopened() throws {
        let projects = root.appendingPathComponent("Projects", isDirectory: true)
        let current = projects.appendingPathComponent("Current", isDirectory: true)
        let note = current.appendingPathComponent("Plan.md")
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try "# Plan".write(to: note, atomically: true, encoding: .utf8)

        let collapsed = NavigatorTreeReloader.rebuild(
            root: root,
            previousRoot: root,
            expanded: [current])
        XCTAssertEqual(collapsed.expanded, [current])
        XCTAssertNil(collapsed.nodes.first { $0.url == projects }?.children)

        let reopened = NavigatorTreeReloader.rebuild(
            root: root,
            previousRoot: root,
            expanded: [projects, current])

        let projectsNode = try XCTUnwrap(reopened.nodes.first { $0.url == projects })
        let currentNode = try XCTUnwrap(projectsNode.children?.first { $0.url == current })
        XCTAssertEqual(currentNode.children?.map(\.url), [note])
    }

    func testTreeEnumerationIsCappedAndReportsIncompleteCoverage() throws {
        for index in 0..<5 {
            try "# \(index)".write(
                to: root.appendingPathComponent("Note-\(index).md"),
                atomically: true,
                encoding: .utf8)
        }

        let snapshot = NavigatorTreeReloader.rebuild(
            root: root,
            previousRoot: nil,
            expanded: [],
            maxEntries: 2)

        XCTAssertLessThanOrEqual(snapshot.nodes.count, 2)
        XCTAssertTrue(snapshot.hitEntryLimit)
        XCTAssertNotNil(snapshot.incompleteMessage)
    }

    func testDeepExpansionIsBoundedBeforeRecursiveHydrationCanExhaustTheStack() throws {
        var parent = root!
        var expanded = Set<URL>()
        for depth in 0...NavigatorTreeReloader.maximumDepth {
            parent = parent.appendingPathComponent("Level-\(depth)", isDirectory: true)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            expanded.insert(parent)
        }

        let snapshot = NavigatorTreeReloader.rebuild(
            root: root,
            previousRoot: root,
            expanded: expanded,
            maxEntries: 1_000)

        XCTAssertTrue(snapshot.hitDepthLimit)
        XCTAssertLessThan(snapshot.expanded.count, expanded.count)
        XCTAssertNotNil(snapshot.incompleteMessage)
    }

    func testTreeReloadGenerationRejectsAStaleSameRootCompletion() {
        let request = NavigatorTreeRequest(root: root, revision: 7, expanded: [])
        let newer = NavigatorTreeRequest(root: root, revision: 8, expanded: [])
        var state = NavigatorTreeReloadState()
        let oldGeneration = state.begin(request)
        _ = state.begin(newer)
        let currentGeneration = state.begin(request)

        XCTAssertFalse(state.complete(request, generation: oldGeneration))
        XCTAssertTrue(state.isPending(request))
        XCTAssertTrue(state.complete(request, generation: currentGeneration))
        XCTAssertFalse(state.isPending(request))
    }

    func testChangingRootsClearsExpansionEvenWhenTheOldDirectoriesStillExist() throws {
        let oldFolder = root.appendingPathComponent("Old", isDirectory: true)
        try FileManager.default.createDirectory(at: oldFolder, withIntermediateDirectories: true)
        let otherRoot = root.appendingPathComponent("OtherVault", isDirectory: true)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)

        let snapshot = NavigatorTreeReloader.rebuild(
            root: otherRoot,
            previousRoot: root,
            expanded: [oldFolder])

        XCTAssertTrue(snapshot.expanded.isEmpty)
    }
}

final class NavigatorFilterStateTests: XCTestCase {
    private func scan(
        files: [URL] = [],
        unreadableDirectories: Int = 0,
        oversizedFiles: Int = 0,
        hitEntryLimit: Bool = false
    ) -> FileTree.ScanResult {
        FileTree.ScanResult(
            files: files,
            visitedEntries: files.count,
            skippedSymlinks: 0,
            unreadableDirectories: unreadableDirectories,
            unreadableEntries: 0,
            oversizedFiles: oversizedFiles,
            hitDepthLimit: false,
            hitEntryLimit: hitEntryLimit)
    }

    private func snapshot(
        files: [URL] = [],
        unreadableDirectories: Int = 0,
        oversizedFiles: Int = 0,
        hitEntryLimit: Bool = false
    ) -> NavigatorFilterSnapshot {
        NavigatorFilterSnapshot(
            matches: files.map { FileNode(url: $0, isDirectory: false) },
            scan: scan(
                files: files,
                unreadableDirectories: unreadableDirectories,
                oversizedFiles: oversizedFiles,
                hitEntryLimit: hitEntryLimit),
            totalMatches: files.count)
    }

    func testVaultWideFilterFindsANoteInsideANeverExpandedFolder() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevNavigatorFilter-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let collapsed = root.appendingPathComponent("Collapsed", isDirectory: true)
        try FileManager.default.createDirectory(at: collapsed, withIntermediateDirectories: true)
        let hidden = collapsed.appendingPathComponent("Hidden Design.md")
        try "# Hidden".write(to: hidden, atomically: true, encoding: .utf8)

        let initial = FileTree.children(of: root)
        XCTAssertNil(initial.first?.children, "the folder must still be collapsed")
        let result = FileTree.scanMarkdownFiles(under: root)

        let ranked = try XCTUnwrap(
            NavigatorFilterResults.rankedSnapshot(
                in: result,
                query: "hidden",
                isCancelled: { false }))

        XCTAssertEqual(ranked.matches.map(\.url), [hidden])
    }

    func testCappedAndUnreadableScansAreNeverPresentedAsComplete() {
        let capped = scan(hitEntryLimit: true)
        let unreadable = scan(unreadableDirectories: 1)
        let oversized = scan(oversizedFiles: 1)
        let complete = scan()

        XCTAssertNotNil(NavigatorFilterResults.incompleteMessage(for: capped))
        XCTAssertNotNil(NavigatorFilterResults.incompleteMessage(for: unreadable))
        XCTAssertNotNil(NavigatorFilterResults.incompleteMessage(for: oversized))
        XCTAssertNil(NavigatorFilterResults.incompleteMessage(for: complete))
    }

    func testARealEntryCapProducesNoFalseCompleteEmptyResult() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevNavigatorCap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "# Note".write(
            to: root.appendingPathComponent("Note.md"), atomically: true, encoding: .utf8)

        let capped = FileTree.scanMarkdownFiles(
            under: root,
            limits: FileTree.ScanLimits(maxDepth: 48, maxEntries: 0))

        XCTAssertTrue(capped.hitEntryLimit)
        XCTAssertFalse(capped.isComplete)
        XCTAssertNotNil(NavigatorFilterResults.incompleteMessage(for: capped))
    }

    func testRootAndRevisionChurnRejectsAnOldCompletionEvenWhenTheRequestCyclesBack() {
        let rootA = URL(fileURLWithPath: "/tmp/Vault-A")
        let rootB = URL(fileURLWithPath: "/tmp/Vault-B")
        let requestA = NavigatorFilterRequest(root: rootA, revision: 4, query: "note")
        let requestB = NavigatorFilterRequest(root: rootB, revision: 8, query: "note")
        let oldFile = rootA.appendingPathComponent("Old.md")
        let newFile = rootA.appendingPathComponent("New.md")
        var state = NavigatorFilterSearchState()

        let firstA = state.begin(requestA)
        _ = state.begin(requestB)
        let secondA = state.begin(requestA)

        XCTAssertFalse(
            state.complete(snapshot(files: [oldFile]), for: requestA, generation: firstA))
        XCTAssertTrue(state.isLoading(requestA))
        XCTAssertTrue(
            state.complete(snapshot(files: [newFile]), for: requestA, generation: secondA))
        XCTAssertEqual(state.result(for: requestA)?.matches.map(\.url), [newFile])
    }

    func testRapidQueryReplacementRejectsTheCancelledQueryCompletion() {
        let root = URL(fileURLWithPath: "/tmp/Vault")
        let alpha = NavigatorFilterRequest(root: root, revision: 3, query: "alpha")
        let beta = NavigatorFilterRequest(root: root, revision: 3, query: "beta")
        let oldFile = root.appendingPathComponent("Alpha.md")
        let currentFile = root.appendingPathComponent("Beta.md")
        var state = NavigatorFilterSearchState()
        let alphaGeneration = state.begin(alpha)
        let betaGeneration = state.begin(beta)

        XCTAssertFalse(
            state.complete(
                snapshot(files: [oldFile]),
                for: alpha,
                generation: alphaGeneration))
        XCTAssertTrue(state.isLoading(beta))
        XCTAssertTrue(
            state.complete(
                snapshot(files: [currentFile]),
                for: beta,
                generation: betaGeneration))
        XCTAssertEqual(state.result(for: beta)?.matches.map(\.url), [currentFile])
    }

    func testPathologicalVaultRankingPublishesOnlyABoundedTopResultSet() throws {
        let files = (0..<20_000).map {
            URL(fileURLWithPath: "/vault/Note-\($0).md")
        }
        let result = scan(files: files)

        let ranked = try XCTUnwrap(
            NavigatorFilterResults.rankedSnapshot(
                in: result,
                query: "note",
                limit: 200,
                isCancelled: { false }))

        XCTAssertEqual(ranked.matches.count, 200)
        XCTAssertEqual(ranked.totalMatches, files.count)
        XCTAssertTrue(ranked.didLimitMatches)
        XCTAssertNotNil(NavigatorFilterResults.incompleteMessage(for: ranked))
    }

    func testSupersededRankingStopsAtItsCooperativeCancellationBoundary() {
        let files = (0..<20_000).map {
            URL(fileURLWithPath: "/vault/Note-\($0).md")
        }
        var cancellationChecks = 0

        let ranked = NavigatorFilterResults.rankedSnapshot(
            in: scan(files: files),
            query: "note",
            isCancelled: {
                cancellationChecks += 1
                return cancellationChecks == 3
            })

        XCTAssertNil(ranked)
        XCTAssertEqual(cancellationChecks, 3)
    }

    func testFilterIsPendingBeforeItsBackgroundInventoryBegins() {
        let request = NavigatorFilterRequest(
            root: URL(fileURLWithPath: "/tmp/Vault"), revision: 1, query: "note")

        XCTAssertTrue(NavigatorFilterSearchState().isPending(request))
    }

    func testResetInvalidatesAnInFlightScan() {
        let request = NavigatorFilterRequest(
            root: URL(fileURLWithPath: "/tmp/Vault"), revision: 1, query: "note")
        var state = NavigatorFilterSearchState()
        let generation = state.begin(request)

        state.reset()

        XCTAssertFalse(state.complete(snapshot(), for: request, generation: generation))
        XCTAssertNil(state.result(for: request))
        XCTAssertFalse(state.isLoading(request))
    }
}
