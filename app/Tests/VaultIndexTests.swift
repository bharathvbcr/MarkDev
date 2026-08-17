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
