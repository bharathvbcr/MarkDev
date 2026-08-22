//
//  VaultReconciliationTests.swift
//  MarkDevKitTests
//
//  The catch-up sweep: FSEvents is lossy around stream birth and the
//  index's own scan predates the subscription, so ``VaultIndex/
//  reconcileWithDisk(excluding:)`` is what makes both gaps harmless. These
//  tests exercise the property that matters — after a sweep, the index
//  describes the disk — for every way the worlds can drift apart.
//

import XCTest

@testable import MarkDevKit

@MainActor
final class VaultReconciliationTests: XCTestCase {
    private var root: URL!
    private var index: VaultIndex!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevReconcile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "# Seed".write(to: root.appendingPathComponent("Seed.md"), atomically: true, encoding: .utf8)
        index = VaultIndex()
        index.open(root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A note created after `open` — inside the scan-to-subscribe gap, or in
    /// an event window FSEvents dropped — must be found by the sweep.
    func testSweepFindsNotesCreatedAfterOpen() async throws {
        try "# Late\n\n[[Seed]]".write(
            to: root.appendingPathComponent("Late.md"), atomically: true, encoding: .utf8)

        let changed = await index.reconcileWithDisk()

        XCTAssertGreaterThan(changed, 0)
        XCTAssertEqual(index.resolve(target: "Late")?.path, "Late.md")
        XCTAssertEqual(
            index.backlinks(for: "Seed.md").count, 1,
            "the new note's link is indexed once it is found")
    }

    /// A note deleted externally must stop answering backlink questions; a
    /// stale graph entry is how "broken link" panels start lying.
    func testSweepForgetsNotesDeletedFromDisk() async throws {
        XCTAssertEqual(index.resolve(target: "Seed")?.path, "Seed.md")
        try FileManager.default.removeItem(at: root.appendingPathComponent("Seed.md"))

        _ = await index.reconcileWithDisk()

        XCTAssertNil(index.resolve(target: "Seed"))
    }

    /// A note whose *content* changed on disk is re-read; backlinks follow
    /// the new text rather than the indexed ghost of the old.
    func testSweepPicksUpExternalContentChanges() async throws {
        try "# Rewritten\n\n[[Elsewhere]]".write(
            to: root.appendingPathComponent("Seed.md"), atomically: true, encoding: .utf8)

        _ = await index.reconcileWithDisk()

        XCTAssertEqual(index.links(for: "Seed.md").first?.target, "Elsewhere")
    }

    /// An open document's buffer outranks its file — the same rule per-event
    /// handling follows. The sweep must not drag disk text under a buffer
    /// the reader is editing.
    func testExcludedURLsAreLeftAlone() async throws {
        let seed = root.appendingPathComponent("Seed.md").standardizedFileURL
        try "# Disk version".write(to: seed, atomically: true, encoding: .utf8)

        // What the editor holds:
        index.update(path: "Seed.md", text: "# Editor version")

        let changed = await index.reconcileWithDisk(excluding: [seed])

        XCTAssertEqual(changed, 0, "nothing else exists to touch")
        XCTAssertEqual(
            index.search("Editor version").count, 1,
            "the editor's text survived the sweep")
        XCTAssertEqual(
            index.search("Disk version").count, 0,
            "disk text was not dragged under the buffer")
    }

    /// A read failure (permissions) is not a deletion: the sweep keeps the
    /// indexed note when the file still exists but cannot be read.
    func testUnreadableButPresentFilesAreNotForgotten() async throws {
        let seed = root.appendingPathComponent("Seed.md")
        try "# Still here".write(to: seed, atomically: true, encoding: .utf8)
        // No chmod games — those flake under sandboxed runners. Instead,
        // prove the invariant by construction: a file that exists but yields
        // no text is exactly what `String(contentsOf:)` returning nil models.
        // Drive the same code path through a directory masquerading as a
        // note? Directories never reach the walker. So assert the honest
        // half: presence without readability keeps the entry, via a file
        // made unreadable to reads but visible to stat.
        guard setPermissions(0o000, on: seed) else {
            throw XCTSkip("cannot drop permissions in this environment")
        }
        defer { setPermissions(0o644, on: seed) }

        _ = await index.reconcileWithDisk()

        XCTAssertNotNil(
            index.resolve(target: "Seed"),
            "an unreadable-but-present note was treated as deleted")
    }

    private func setPermissions(_ mode: Int, on url: URL) -> Bool {
        // Running as root (some CI), chmod cannot make a file unreadable;
        // report honestly so the test skips instead of passing on a lie.
        guard getuid() != 0 else { return false }
        return chmod(url.path, mode_t(mode)) == 0
    }
}

/// The sweep's input: the recursive walk must honour the navigator's
/// visibility rules and survive a symlink loop without hanging or crashing.
@MainActor
final class FileTreeWalkTests: XCTestCase {
    func testWalkFindsNestedMarkdownAndHonoursIgnoredDirectories() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevWalk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "# top".write(to: root.appendingPathComponent("Top.md"), atomically: true, encoding: .utf8)
        let nested = root.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "# deep".write(to: nested.appendingPathComponent("Deep.markdown"), atomically: true, encoding: .utf8)
        try "noise".write(to: nested.appendingPathComponent("skip.txt"), atomically: true, encoding: .utf8)
        let ignored = root.appendingPathComponent("node_modules")
        try FileManager.default.createDirectory(at: ignored, withIntermediateDirectories: true)
        try "# hidden from view".write(
            to: ignored.appendingPathComponent("Ignored.md"), atomically: true, encoding: .utf8)

        let names = Set(
            FileTree.markdownFiles(under: root).map(\.lastPathComponent))

        XCTAssertEqual(names, ["Top.md", "Deep.markdown"])
    }

    /// `link -> parent` is the classic eternal directory. The walk must end,
    /// having found the real files exactly once each.
    func testDirectorySymlinkLoopTerminatesWithoutDuplicates() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevLoop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "# inside".write(to: root.appendingPathComponent("Real.md"), atomically: true, encoding: .utf8)
        try? FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("loop"),
            withDestinationURL: root)

        let files = FileTree.markdownFiles(under: root)

        XCTAssertEqual(files.map(\.lastPathComponent), ["Real.md"])
    }
}
