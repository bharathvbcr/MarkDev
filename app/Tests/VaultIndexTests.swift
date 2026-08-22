//
//  VaultIndexTests.swift
//  MarkDevKitTests
//

import XCTest

@testable import MarkDevKit

@MainActor
final class VaultIndexTests: XCTestCase {
    private func makeDirectory(named name: String = "Vault") throws -> URL {
        let parent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevVaultIndex-\(UUID().uuidString)")
        let directory = parent.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testQueriesCrossTheSwiftRustBoundary() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try write("# Alpha\n\nLinks to [[Béta#Details]]. #swift", to: root.appendingPathComponent("Alpha.md"))
        try write("# Béta\n\n## Details\n\nBody text", to: root.appendingPathComponent("Beta.md"))

        let vault = VaultIndex()
        vault.open(root)

        XCTAssertEqual(vault.noteCount, 2)
        XCTAssertEqual(Set(vault.notePaths()), ["Alpha.md", "Beta.md"])
        XCTAssertEqual(vault.backlinks(for: "Beta.md").map(\.path), ["Alpha.md"])
        XCTAssertEqual(vault.outline(for: "Beta.md").map(\.text), ["Béta", "Details"])
        XCTAssertEqual(vault.tags(), [TagCount(tag: "swift", count: 1)])
        XCTAssertEqual(vault.search("body").first?.path, "Beta.md")
        XCTAssertEqual(vault.resolve(target: "Béta", anchor: "Details")?.path, "Beta.md")
        XCTAssertNotNil(vault.resolve(target: "Béta", anchor: "Details")?.offset)
    }

    func testUpdateUsesUnsavedEditorText() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try write("# Alpha\n", to: root.appendingPathComponent("Alpha.md"))
        try write("# Beta\n", to: root.appendingPathComponent("Beta.md"))

        let vault = VaultIndex()
        vault.open(root)
        XCTAssertTrue(vault.backlinks(for: "Beta.md").isEmpty)

        vault.update(path: "Alpha.md", text: "# Alpha\n\n[[Beta]]")

        XCTAssertEqual(vault.backlinks(for: "Beta.md").map(\.path), ["Alpha.md"])
    }

    // MARK: - Rename with link rewriting

    func testRenameNoteMovesTheFileAndRewritesLinksAcrossTheVault() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try write("# Roadmap", to: root.appendingPathComponent("Roadmap.md"))
        try write(
            "See [[Roadmap]] and [file](Roadmap.md).\n",
            to: root.appendingPathComponent("Diary.md"))

        let vault = VaultIndex()
        vault.open(root)

        let outcome = try XCTUnwrap(vault.renameNote(from: "Roadmap.md", to: "Plans/Map.md"))

        XCTAssertEqual(outcome.rewrittenNotes, 1)
        XCTAssertEqual(outcome.rewrittenLinks, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Roadmap.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Plans/Map.md").path))

        let diary = try String(contentsOf: root.appendingPathComponent("Diary.md"), encoding: .utf8)
        XCTAssertEqual(diary, "See [[Map]] and [file](Plans/Map.md).\n")

        // The index answers for the new path and not the old one.
        XCTAssertEqual(vault.notePaths(), ["Diary.md", "Plans/Map.md"])
        // The old *path* spelling is gone; the note's TITLE still resolves,
        // which is correct — titles follow the note wherever it lives.
        XCTAssertNil(vault.resolve(target: "Projects/Roadmap"))
        XCTAssertEqual(vault.resolve(target: "Roadmap")?.path, "Plans/Map.md")
        XCTAssertEqual(vault.resolve(target: "Map")?.path, "Plans/Map.md")
    }

    func testRenameNoteRefusesADestinationThatAlreadyExists() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try write("# A", to: root.appendingPathComponent("A.md"))
        try write("# B", to: root.appendingPathComponent("B.md"))

        let vault = VaultIndex()
        vault.open(root)

        XCTAssertNil(vault.renameNote(from: "A.md", to: "B.md"))
        // Nothing moved on disk either — the refusal is real.
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("A.md").path))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("B.md"), encoding: .utf8), "# B")
    }

    func testRemoveNoteForgetsANoteWithoutTouchingAnythingElse() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try write("# Alpha\n[[Beta]]", to: root.appendingPathComponent("Alpha.md"))
        try write("# Beta", to: root.appendingPathComponent("Beta.md"))

        let vault = VaultIndex()
        vault.open(root)
        vault.removeNote("Beta.md")

        XCTAssertEqual(vault.notePaths(), ["Alpha.md"])
        XCTAssertTrue(vault.backlinks(for: "Beta.md").isEmpty)
        // The file itself is the caller's business; only the index changed.
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Beta.md").path))
    }

    func testRelativePathsRejectSiblingPrefixAndTraversal() throws {
        let root = try makeDirectory(named: "Vault")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let note = root.appendingPathComponent("Note.md")
        try write("# Note", to: note)
        let sibling = root.deletingLastPathComponent()
            .appendingPathComponent("Vault-copy/Outside.md")

        let vault = VaultIndex()
        vault.open(root)

        XCTAssertEqual(vault.relativePath(for: note), "Note.md")
        XCTAssertNil(vault.relativePath(for: sibling))
        XCTAssertNil(vault.url(for: "../Outside.md"))
        XCTAssertNil(vault.url(for: ""))
    }

    func testSearchRejectsNonPositiveLimits() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try write("# Note\n\nsearchable", to: root.appendingPathComponent("Note.md"))

        let vault = VaultIndex()
        vault.open(root)

        XCTAssertEqual(vault.search("searchable", limit: 0), [])
        XCTAssertEqual(vault.search("searchable", limit: -1), [])
    }
}
