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

    override func setUp() async throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevReconcile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "# Seed".write(to: root.appendingPathComponent("Seed.md"), atomically: true, encoding: .utf8)
        index = VaultIndex()
        index.open(root)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A note created after `open` — inside the scan-to-subscribe gap, or in
    /// an event window FSEvents dropped — must be found by the sweep.
    func testSweepFindsNotesCreatedAfterOpen() async throws {
        try "# Late\n\n[[Seed]]".write(
            to: root.appendingPathComponent("Late.md"), atomically: true, encoding: .utf8)

        let result = await index.reconcileWithDisk()

        XCTAssertGreaterThan(result.changedNotes, 0)
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

    func testUnchangedCompleteSweepReportsNoChangeAndDoesNotInvalidateReaders() async {
        let revision = index.contentRevision

        let result = await index.reconcileWithDisk()

        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.changedNotes, 0, "a scanned file is not necessarily a changed file")
        XCTAssertEqual(
            index.contentRevision, revision,
            "an idempotent catch-up must not invalidate graph and palette snapshots")
    }

    /// An open document's buffer outranks its file — the same rule per-event
    /// handling follows. The sweep must not drag disk text under a buffer
    /// the reader is editing.
    func testExcludedURLsAreLeftAlone() async throws {
        let seed = root.appendingPathComponent("Seed.md").standardizedFileURL
        try "# Disk version".write(to: seed, atomically: true, encoding: .utf8)

        // What the editor holds:
        index.update(path: "Seed.md", text: "# Editor version")

        let result = await index.reconcileWithDisk(excluding: [seed])

        XCTAssertEqual(result.changedNotes, 0, "nothing else exists to touch")
        XCTAssertEqual(
            index.search("Editor version").count, 1,
            "the editor's text survived the sweep")
        XCTAssertEqual(
            index.search("Disk version").count, 0,
            "disk text was not dragged under the buffer")
    }

    func testRemoteAuthorityCannotExcludeTheMatchingLocalNoteFromReconciliation() async throws {
        let seed = root.appendingPathComponent("Seed.md").standardizedFileURL
        try "# Disk version".write(to: seed, atomically: true, encoding: .utf8)
        _ = index.update(path: "Seed.md", text: "# Editor version")
        let hostile = try XCTUnwrap(
            URL(string: "file://remote.example\(seed.path)"))

        let result = await index.reconcileWithDisk(excluding: [hostile])

        XCTAssertGreaterThan(result.changedNotes, 0)
        XCTAssertEqual(index.search("Disk version").count, 1)
        XCTAssertEqual(index.search("Editor version").count, 0)
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
        defer { _ = setPermissions(0o644, on: seed) }

        _ = await index.reconcileWithDisk()

        XCTAssertNotNil(
            index.resolve(target: "Seed"),
            "an unreadable-but-present note was treated as deleted")
    }

    func testIncompleteBoundedSweepNeverDeletesAnUnseenIndexedNote() async throws {
        index.update(path: "Unseen.md", text: "# Unseen")
        XCTAssertEqual(index.resolve(target: "Unseen")?.path, "Unseen.md")

        let result = await index.reconcileWithDisk(
            excluding: [],
            scanLimits: FileTree.ScanLimits(maxDepth: 48, maxEntries: 0))

        XCTAssertFalse(result.isComplete, "a capped walk was reported as complete")
        XCTAssertTrue(result.scan.hitEntryLimit)
        XCTAssertEqual(
            index.resolve(target: "Unseen")?.path, "Unseen.md",
            "absence from a capped sample was treated as proven deletion")
    }

    func testTotalByteCappedSweepNeverDeletesUnseenNotesAndReportsActualBytes() async throws {
        try "12345678".write(
            to: root.appendingPathComponent("Another.md"), atomically: true, encoding: .utf8)
        index.update(path: "Unseen.md", text: "# Unseen")

        let result = await index.reconcileWithDisk(
            excluding: [],
            scanLimits: FileTree.ScanLimits(
                maxDepth: 48,
                maxEntries: 100,
                maxNoteBytes: 1_024,
                maxTotalBytes: 8))

        XCTAssertFalse(result.isComplete)
        XCTAssertTrue(result.scan.hitTotalByteLimit)
        XCTAssertEqual(result.scan.discoveredFiles, 2)
        XCTAssertEqual(result.scan.skippedFiles, 1)
        XCTAssertLessThanOrEqual(result.bytesRead, 8)
        XCTAssertEqual(
            index.resolve(target: "Unseen")?.path, "Unseen.md",
            "absence from a byte-capped sample was treated as proof of deletion")
    }

    func testOversizedNoteMakesSweepIncompleteWithoutDeletingItsIndexEntry() async throws {
        let huge = root.appendingPathComponent("Huge.md")
        XCTAssertTrue(FileManager.default.createFile(atPath: huge.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: 32 * 1024 * 1024)
        try handle.close()
        index.update(path: "Huge.md", text: "# Indexed before it grew")

        let result = await index.reconcileWithDisk(
            excluding: [],
            scanLimits: FileTree.ScanLimits(
                maxDepth: 48, maxEntries: 100, maxNoteBytes: 1_048_576))

        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(result.scan.oversizedFiles, 1)
        XCTAssertEqual(
            index.resolve(target: "Huge")?.path, "Huge.md",
            "an oversized skipped note was mistaken for a deleted note")
    }

    func testVaultRootReplacedByAFileCannotAuthorizeDeletingTheIndex() async throws {
        XCTAssertEqual(index.resolve(target: "Seed")?.path, "Seed.md")
        try FileManager.default.removeItem(at: root)
        try "not a directory".write(to: root, atomically: true, encoding: .utf8)

        let result = await index.reconcileWithDisk()

        XCTAssertFalse(result.isComplete, "a non-directory vault root is not a complete scan")
        XCTAssertGreaterThan(result.scan.unreadableDirectories, 0)
        XCTAssertEqual(
            index.resolve(target: "Seed")?.path, "Seed.md",
            "an invalid root was mistaken for proof that every note was deleted")
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

    func testWalkUsesTheSameFilesystemHiddenPolicyAsTheNavigator() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevWalkHidden-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let visible = root.appendingPathComponent("Visible.md")
        var hidden = root.appendingPathComponent("FinderHidden.md")
        try "visible".write(to: visible, atomically: true, encoding: .utf8)
        try "hidden".write(to: hidden, atomically: true, encoding: .utf8)
        var values = URLResourceValues()
        values.isHidden = true
        try hidden.setResourceValues(values)

        let scan = FileTree.scanMarkdownFiles(under: root)

        XCTAssertEqual(scan.files.map(\.lastPathComponent), ["Visible.md"])
        XCTAssertEqual(FileTree.children(of: root).map(\.url.lastPathComponent), ["Visible.md"])
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

    func testWalkNeverFollowsADirectorySymlinkOutsideTheVault() throws {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevOutsideLink-\(UUID().uuidString)")
        let root = sandbox.appendingPathComponent("vault")
        let outside = sandbox.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        try "# Inside".write(
            to: root.appendingPathComponent("Inside.md"), atomically: true, encoding: .utf8)
        try "# Secret".write(
            to: outside.appendingPathComponent("Secret.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked-outside"), withDestinationURL: outside)

        let relative = FileTree.markdownFiles(under: root).map {
            $0.path.replacingOccurrences(of: root.path + "/", with: "")
        }

        XCTAssertEqual(relative, ["Inside.md"])
        XCTAssertFalse(
            FileTree.children(of: root).contains { $0.name == "linked-outside" },
            "the navigator exposed a traversable portal outside the vault")
    }

    func testWalkDoesNotFollowSelfParentOrChainedDirectorySymlinks() throws {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevSymlinkChains-\(UUID().uuidString)")
        let root = sandbox.appendingPathComponent("vault")
        let real = root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        try "# One".write(
            to: real.appendingPathComponent("One.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("self"), withDestinationURL: root)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("parent"), withDestinationURL: sandbox)
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("chain-a").path,
            withDestinationPath: "chain-b")
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("chain-b").path,
            withDestinationPath: "real")

        let relative = FileTree.markdownFiles(under: root).map {
            $0.path.replacingOccurrences(of: root.path + "/", with: "")
        }

        XCTAssertEqual(relative, ["real/One.md"])
    }

    func testWalkDepthLimitIsBoundedAndReportedIncomplete() throws {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevWalkDepth-\(UUID().uuidString)")
        let root = sandbox.appendingPathComponent("vault")
        let nested = root.appendingPathComponent("one/two/three")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        try "# Top".write(
            to: root.appendingPathComponent("Top.md"), atomically: true, encoding: .utf8)
        try "# One".write(
            to: root.appendingPathComponent("one/One.md"), atomically: true, encoding: .utf8)
        try "# Two".write(
            to: root.appendingPathComponent("one/two/Two.md"), atomically: true, encoding: .utf8)
        try "# Too deep".write(
            to: nested.appendingPathComponent("TooDeep.md"), atomically: true, encoding: .utf8)

        let scan = FileTree.scanMarkdownFiles(
            under: root,
            limits: FileTree.ScanLimits(maxDepth: 1, maxEntries: 100))
        let relative = scan.files.map {
            $0.path.replacingOccurrences(of: root.path + "/", with: "")
        }

        XCTAssertEqual(relative, ["Top.md", "one/One.md"])
        XCTAssertTrue(scan.hitDepthLimit)
        XCTAssertFalse(scan.isComplete)
    }

    func testWalkHugeFanoutStopsAtEntryLimitAndReportsTheCap() throws {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevWalkFanout-\(UUID().uuidString)")
        let root = sandbox.appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        for index in 0..<512 {
            try "# note".write(
                to: root.appendingPathComponent(String(format: "Note-%04d.md", index)),
                atomically: true,
                encoding: .utf8)
        }

        let scan = FileTree.scanMarkdownFiles(
            under: root,
            limits: FileTree.ScanLimits(maxDepth: 48, maxEntries: 64))

        XCTAssertEqual(scan.visitedEntries, 64)
        XCTAssertLessThanOrEqual(scan.files.count, 64)
        XCTAssertTrue(scan.hitEntryLimit)
        XCTAssertFalse(scan.isComplete)
    }

    func testWalkAndBoundedReadRefuseAnOversizedNoteWithoutAllocatingItsSize() throws {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevWalkOversized-\(UUID().uuidString)")
        let root = sandbox.appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try "# Small".write(
            to: root.appendingPathComponent("Small.md"), atomically: true, encoding: .utf8)
        let huge = root.appendingPathComponent("Huge.md")
        XCTAssertTrue(FileManager.default.createFile(atPath: huge.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: 32 * 1024 * 1024)
        try handle.close()

        let limits = FileTree.ScanLimits(
            maxDepth: 48, maxEntries: 100, maxNoteBytes: 1_048_576)
        let scan = FileTree.scanMarkdownFiles(under: root, limits: limits)

        XCTAssertEqual(scan.files.map(\.lastPathComponent), ["Small.md"])
        XCTAssertEqual(scan.oversizedFiles, 1)
        XCTAssertFalse(scan.isComplete)
        guard case .oversized = FileTree.readUTF8File(
            at: huge, inside: root, maximumBytes: limits.maxNoteBytes)
        else {
            return XCTFail("bounded read accepted an oversized note")
        }
    }

    func testBoundedReaderRejectsFIFOWithoutWaitingForAWriter() throws {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevWalkFIFO-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let fifo = sandbox.appendingPathComponent("Swapped.md")
        XCTAssertEqual(Darwin.mkfifo(fifo.path, 0o600), 0)

        let started = ContinuousClock.now
        let result = FileTree.openVerifiedRegularFile(at: fifo)
        let elapsed = started.duration(to: .now)

        XCTAssertNil(result)
        XCTAssertLessThan(elapsed, .milliseconds(100), "opening a FIFO blocked")
    }

    func testWalkTotalByteBudgetCarriesExactIncompleteCoverage() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevWalkTotalBytes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["A.md", "B.md", "C.md"] {
            try "12345678".write(
                to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        let scan = FileTree.scanMarkdownFiles(
            under: root,
            limits: FileTree.ScanLimits(
                maxDepth: 48, maxEntries: 100, maxNoteBytes: 1_024, maxTotalBytes: 10))

        XCTAssertEqual(scan.discoveredFiles, 3)
        XCTAssertEqual(scan.discoveredBytes, 24)
        XCTAssertEqual(scan.files.count, 1)
        XCTAssertEqual(scan.selectedBytes, 8)
        XCTAssertEqual(scan.skippedFiles, 2)
        XCTAssertTrue(scan.hitTotalByteLimit)
        XCTAssertFalse(scan.isComplete)
    }
}
