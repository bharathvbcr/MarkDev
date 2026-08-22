//
//  VaultIndexRegistryTests.swift
//  MarkDevKitTests
//
//  One index per vault root, shared across windows.
//

import XCTest

@testable import MarkDevKit

@MainActor
final class VaultIndexRegistryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        VaultIndexRegistry.shared.reset()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevRegistry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "# Hub\n\n[[Wanderer]]\n".write(
            to: root.appendingPathComponent("Hub.md"), atomically: true, encoding: .utf8)
        try "# Wanderer\n".write(
            to: root.appendingPathComponent("Wanderer.md"), atomically: true, encoding: .utf8)
        for index in 0..<20 {
            try "# Note\(index)\n".write(
                to: root.appendingPathComponent("Note\(index).md"),
                atomically: true, encoding: .utf8)
        }
    }

    override func tearDownWithError() throws {
        VaultIndexRegistry.shared.reset()
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Sharing rules

    func testTheSameRootHandsBackTheSameInstance() {
        let first = VaultIndexRegistry.shared.index(for: root)
        let second = VaultIndexRegistry.shared.index(for: root)
        XCTAssertTrue(first === second, "two windows on one folder must share")
    }

    func testDifferentRootsGetDifferentInstances() throws {
        let other = root.appendingPathComponent("OtherVault")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)

        let mine = VaultIndexRegistry.shared.index(for: root)
        let theirs = VaultIndexRegistry.shared.index(for: other)

        XCTAssertFalse(mine === theirs, "distinct folders must not share an index")
    }

    /// Trailing separators and interior `/./` are spellings of one folder;
    /// the registry keys on the standardized path, so they must share too.
    func testSpellingsOfOneFolderShare() {
        let decorated = URL(
            fileURLWithPath: root.path + "/./"
        ).standardizedFileURL

        let plain = VaultIndexRegistry.shared.index(for: root)
        let spelled = VaultIndexRegistry.shared.index(for: decorated)

        XCTAssertTrue(plain === spelled, "\(decorated.path) should resolve to \(root.path)")
    }

    // MARK: - Cross-window propagation

    /// The whole point of sharing: an update made by one window's reference
    /// is what the other window's reference answers, without either side
    /// re-opening anything.
    func testUpdatesThroughOneWindowAreVisibleInTheOther() {
        let windowA = VaultIndexRegistry.shared.index(for: root)
        let windowB = VaultIndexRegistry.shared.index(for: root)

        XCTAssertFalse(windowB.backlinks(for: "Note3.md").contains { $0.path == "Hub.md" })

        windowA.update(path: "Hub.md", text: "# Hub\n\n[[Note3]]\n")

        XCTAssertEqual(
            windowB.backlinks(for: "Note3.md").map(\.path),
            ["Hub.md"],
            "B answered from a stale copy")
    }

    // MARK: - Stress

    /// Two windows' worth of references hammering one instance: alternating
    /// updates, per-round link and backlink reads, periodic back-and-forth
    /// renames that rewrite files on disk, and background graph layouts in
    /// flight throughout. Nothing here may crash, wedge the lock, or leave
    /// the index disagreeing with itself at the end.
    func testTwoWindowsHammeringOneSharedIndexStayConsistent() async throws {
        let shared = VaultIndexRegistry.shared.index(for: root)

        // Background layouts running across the whole storm.
        var graphs: [Task<VaultGraph, Never>] = []
        for _ in 0..<6 {
            graphs.append(Task.detached { await shared.graphOffMain(depth: 2) })
        }

        // A scratch pair renamed back and forth every few rounds.
        try "# Scratch\n".write(
            to: root.appendingPathComponent("Scratch.md"), atomically: true, encoding: .utf8)
        shared.update(path: "Scratch.md", text: "# Scratch")
        var scratchAt = "Scratch.md"

        for round in 0..<200 {
            // Window A types; window B immediately asks what changed.
            shared.update(
                path: "Hub.md",
                text: "# Hub\n\n[[Wanderer]] [[Note\(round % 20)]]\n")

            let outgoing = shared.links(for: "Hub.md")
            XCTAssertEqual(outgoing.count, 2, "round \(round)")
            XCTAssertTrue(
                outgoing.contains { $0.target == "Wanderer" && $0.path == "Wanderer.md" },
                "round \(round): \(outgoing)")

            XCTAssertEqual(
                shared.backlinks(for: "Note\(round % 20).md").map(\.path),
                ["Hub.md"],
                "round \(round)")

            if round % 40 == 35 {
                let destination = scratchAt == "Scratch.md" ? "Shuffled/Scratch.md" : "Scratch.md"
                if destination.contains("/") {
                    try FileManager.default.createDirectory(
                        at: root.appendingPathComponent("Shuffled"),
                        withIntermediateDirectories: true)
                    try? FileManager.default.removeItem(
                        at: root.appendingPathComponent(destination))
                }
                let moved = shared.renameNote(from: scratchAt, to: destination)
                XCTAssertNotNil(moved, "round \(round): rename refused")
                scratchAt = destination
            }
        }

        for task in graphs {
            let graph = await task.value
            for node in graph.nodes {
                XCTAssertTrue(node.x.isFinite && node.y.isFinite)
            }
        }

        // Settled state agrees with the last write, whichever window asks.
        // Round 199 targeted Note19 — the final write decides, not a
        // convenient earlier one.
        XCTAssertEqual(shared.resolve(target: "Wanderer")?.path, "Wanderer.md")
        XCTAssertTrue(shared.notePaths().contains(scratchAt))
        XCTAssertEqual(
            shared.backlinks(for: "Note19.md").map(\.path), ["Hub.md"],
            "final read disagrees with final write")
    }
}
