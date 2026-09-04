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
        let status = try XCTUnwrap(vault.initialScanStatus)
        XCTAssertTrue(status.isComplete)
        XCTAssertTrue(status.scanPerformed)
        XCTAssertEqual(status.discoveredFiles, 2)
        XCTAssertEqual(status.selectedFiles, 2)
        XCTAssertEqual(status.indexedFiles, 2)
        XCTAssertEqual(status.skippedFiles, 0)
        XCTAssertEqual(status.indexedBytes, status.selectedBytes)
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

        XCTAssertEqual(
            vault.update(path: "Alpha.md", text: "# Alpha\n\n[[Beta]]"), .changed)

        XCTAssertEqual(vault.backlinks(for: "Beta.md").map(\.path), ["Alpha.md"])
    }

    func testUpdateIsLengthDelimitedAndNoOpDoesNotInvalidateReaders() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try write("# Alpha\n", to: root.appendingPathComponent("Alpha.md"))

        let vault = VaultIndex()
        vault.open(root)
        let initialRevision = vault.contentRevision
        XCTAssertEqual(vault.update(path: "Alpha.md", text: "# Alpha\n"), .unchanged)
        XCTAssertEqual(vault.contentRevision, initialRevision)

        let embeddedNUL = "# Alpha\nbefore\0needle-after-nul"
        XCTAssertEqual(vault.update(path: "Alpha.md", text: embeddedNUL), .changed)
        XCTAssertEqual(vault.search("needle-after-nul").map(\.path), ["Alpha.md"])
        let changedRevision = vault.contentRevision
        XCTAssertEqual(vault.update(path: "Alpha.md", text: embeddedNUL), .unchanged)
        XCTAssertEqual(vault.contentRevision, changedRevision)
    }

    func testVaultBoundaryRejectsOversizedPathsTextAndQueries() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try write("# Alpha\n", to: root.appendingPathComponent("Alpha.md"))

        let vault = VaultIndex()
        vault.open(root)
        let revision = vault.contentRevision
        XCTAssertEqual(
            vault.update(path: String(repeating: "p", count: 4_097), text: "# nope"),
            .rejected)
        XCTAssertEqual(
            vault.update(
                path: "Alpha.md",
                text: String(repeating: "x", count: FileTree.defaultMaximumNoteBytes + 1)),
            .rejected)
        XCTAssertEqual(vault.contentRevision, revision)
        XCTAssertTrue(vault.search(String(repeating: "q", count: 4_097)).isEmpty)
        XCTAssertNil(vault.resolve(target: "Alpha\0ignored"))
    }

    func testInitialScanStatusReportsSkippedOversizedNoteAsIncomplete() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try write("# Small", to: root.appendingPathComponent("Small.md"))
        let oversized = root.appendingPathComponent("Oversized.md")
        XCTAssertTrue(FileManager.default.createFile(atPath: oversized.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(FileTree.defaultMaximumNoteBytes + 1))
        try handle.close()

        let vault = VaultIndex()
        vault.open(root)

        let status = try XCTUnwrap(vault.initialScanStatus)
        XCTAssertFalse(status.isComplete)
        XCTAssertEqual(status.discoveredFiles, 2)
        XCTAssertEqual(status.selectedFiles, 1)
        XCTAssertEqual(status.indexedFiles, 1)
        XCTAssertEqual(status.skippedFiles, 1)
        XCTAssertEqual(status.oversizedFiles, 1)
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
        XCTAssertEqual(outcome.failedRewrites, 0)
        XCTAssertTrue(outcome.isComplete)
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
