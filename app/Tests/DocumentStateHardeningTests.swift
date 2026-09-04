//
//  DocumentStateHardeningTests.swift
//  MarkDevKitTests
//
//  Adversarial file identity, cache freshness, and document-size boundaries.
//

import Darwin
import XCTest

@testable import MarkDevKit

private struct TestFileStamp {
    let device: UInt64
    let inode: UInt64
    let generation: UInt32
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int
}

private func testFileStamp(_ url: URL) throws -> TestFileStamp {
    var value = stat()
    let result = url.withUnsafeFileSystemRepresentation { path in
        path.map { Darwin.lstat($0, &value) } ?? -1
    }
    guard result == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    return TestFileStamp(
        device: UInt64(value.st_dev),
        inode: UInt64(value.st_ino),
        generation: value.st_gen,
        size: value.st_size,
        modifiedSeconds: value.st_mtimespec.tv_sec,
        modifiedNanoseconds: value.st_mtimespec.tv_nsec,
        changedSeconds: value.st_ctimespec.tv_sec,
        changedNanoseconds: value.st_ctimespec.tv_nsec)
}

private final class WeakVaultReference {
    weak var value: VaultIndex?

    init(_ value: VaultIndex) {
        self.value = value
    }
}

final class NoteTextCacheIdentityTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkDevCacheIdentity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAtomicReplacementWithSameSizeAndModificationTimeInvalidatesCachedBytes() throws {
        let cache = NoteTextCache(maximumFileBytes: 64, maximumTotalBytes: 256)
        let file = directory.appendingPathComponent("Note.md")
        let replacement = directory.appendingPathComponent("Replacement.md")
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

        try Data("AAAAAAAA".utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: fixedDate], ofItemAtPath: file.path)
        XCTAssertEqual(try cache.utf8Text(at: file), "AAAAAAAA")
        let oldHandle = try FileHandle(forReadingFrom: file)
        defer { try? oldHandle.close() }
        let before = try testFileStamp(file)

        try Data("BBBBBBBB".utf8).write(to: replacement)
        try FileManager.default.setAttributes(
            [.modificationDate: fixedDate], ofItemAtPath: replacement.path)
        XCTAssertEqual(Darwin.rename(replacement.path, file.path), 0)
        let after = try testFileStamp(file)

        XCTAssertEqual(after.size, before.size, "the test must defeat the size-only check")
        XCTAssertEqual(after.modifiedSeconds, before.modifiedSeconds)
        XCTAssertEqual(after.modifiedNanoseconds, before.modifiedNanoseconds)
        XCTAssertTrue(
            (after.device, after.inode, after.generation)
                != (before.device, before.inode, before.generation),
            "holding the old descriptor must make this a distinct file identity")
        XCTAssertEqual(try cache.utf8Text(at: file), "BBBBBBBB")
        XCTAssertEqual(cache.hits, 0, "a replacement is a miss even when metadata was forged")
        XCTAssertEqual(cache.misses, 2)
    }

    func testInPlaceRewriteWithSameSizeAndRestoredModificationTimeInvalidatesViaChangeTime()
        throws
    {
        let cache = NoteTextCache(maximumFileBytes: 64, maximumTotalBytes: 256)
        let file = directory.appendingPathComponent("Note.md")
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try Data("AAAAAAAA".utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: fixedDate], ofItemAtPath: file.path)
        XCTAssertEqual(try cache.utf8Text(at: file), "AAAAAAAA")
        let before = try testFileStamp(file)

        // Ensure a distinct change-time tick without relying on mtime, which is
        // deliberately restored to its original value below.
        usleep(2_000)
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data("BBBBBBBB".utf8))
        try handle.synchronize()
        try handle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: fixedDate], ofItemAtPath: file.path)
        let after = try testFileStamp(file)

        XCTAssertEqual(after.inode, before.inode, "this case must retain file identity")
        XCTAssertEqual(after.size, before.size)
        XCTAssertEqual(after.modifiedSeconds, before.modifiedSeconds)
        XCTAssertEqual(after.modifiedNanoseconds, before.modifiedNanoseconds)
        XCTAssertTrue(
            after.changedSeconds != before.changedSeconds
                || after.changedNanoseconds != before.changedNanoseconds,
            "the filesystem must expose a change-time transition for this test")
        XCTAssertEqual(try cache.utf8Text(at: file), "BBBBBBBB")
        XCTAssertEqual(cache.hits, 0)
        XCTAssertEqual(cache.misses, 2)
    }

    func testRepeatedForgedMetadataReplacementsNeverReuseCachedBytes() throws {
        let cache = NoteTextCache(maximumFileBytes: 64, maximumTotalBytes: 256)
        let file = directory.appendingPathComponent("Repeated.md")
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try Data("00000000".utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: fixedDate], ofItemAtPath: file.path)
        XCTAssertEqual(try cache.utf8Text(at: file), "00000000")

        for iteration in 1...128 {
            let oldHandle = try FileHandle(forReadingFrom: file)
            let replacement = directory.appendingPathComponent("Replacement-\(iteration).md")
            let expected = String(format: "%08d", iteration)
            try Data(expected.utf8).write(to: replacement)
            try FileManager.default.setAttributes(
                [.modificationDate: fixedDate], ofItemAtPath: replacement.path)
            XCTAssertEqual(Darwin.rename(replacement.path, file.path), 0)

            XCTAssertEqual(try cache.utf8Text(at: file), expected, "replacement \(iteration)")
            try oldHandle.close()
        }

        XCTAssertEqual(cache.hits, 0)
        XCTAssertEqual(cache.misses, 129)
    }

    /// Thread Sanitizer is the assertion: getters race the locked writes in the
    /// pre-fix implementation even though their integer values often look sane.
    func testConcurrentReadsClearsAndStatisticsRemainRaceFree() throws {
        let cache = NoteTextCache(maximumFileBytes: 64, maximumTotalBytes: 256)
        let file = directory.appendingPathComponent("Note.md")
        try Data("race-proof".utf8).write(to: file)
        _ = try cache.read(file)

        DispatchQueue.concurrentPerform(iterations: 4_000) { iteration in
            if iteration.isMultiple(of: 97) {
                cache.clear()
            } else {
                _ = try? cache.read(file)
            }
            _ = cache.hits
            _ = cache.misses
            _ = cache.cachedBytes
            let statistics = cache.statistics
            _ = statistics.hits
            _ = statistics.misses
            _ = statistics.cachedBytes
        }

        let final = cache.statistics
        XCTAssertGreaterThanOrEqual(final.hits, 0)
        XCTAssertGreaterThanOrEqual(final.misses, 0)
        XCTAssertGreaterThanOrEqual(final.cachedBytes, 0)
        XCTAssertLessThanOrEqual(final.cachedBytes, cache.maximumTotalBytes)
    }
}

@MainActor
final class WorkspaceBoundaryHardeningTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkDevWorkspaceBoundary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A refused edit must be distinguishable from an empty pane.
    ///
    /// Both answered `false` from `updateText`, and only one of them costs the
    /// reader anything: the model keeps the old string, SwiftUI pushes it back
    /// into the editor, and the paste is reverted. Nothing said so.
    func testAnOversizedEditIsReportedRatherThanFoldedInWithAnEmptyPane() {
        let workspace = Workspace()
        let pane = workspace.focusedPane
        let oversized = String(
            repeating: "x", count: MarkdownReadLimits.maximumDocumentBytes + 1)

        let refusal = workspace.apply(text: oversized, in: pane)
        XCTAssertEqual(
            refusal,
            .refusedTooLarge(
                byteCount: MarkdownReadLimits.maximumDocumentBytes + 1,
                limit: MarkdownReadLimits.maximumDocumentBytes))
        XCTAssertFalse(refusal.didApply)
        XCTAssertNotNil(refusal.readerMessage, "a lost paste must have something to say")

        // A pane that no longer exists is the other `false`, and there is
        // nothing to tell the reader about it — they have lost no text.
        // Closing a pane's last *document* opens a fresh untitled one, so the
        // only way to have no document is to have no pane.
        let stale = workspace.split(pane, edge: .trailing)
        workspace.closePane(stale)
        XCTAssertNil(workspace.document(in: stale), "the pane must really be gone")
        let outcome = workspace.apply(text: "anything", in: stale)
        XCTAssertFalse(outcome.didApply)
        XCTAssertNil(outcome.readerMessage)
    }

    func testAnAcceptedEditSaysSoAndCarriesNoMessage() {
        let workspace = Workspace()
        let pane = workspace.focusedPane

        XCTAssertEqual(workspace.apply(text: "# Note", in: pane), .applied)
        XCTAssertEqual(
            workspace.apply(text: "# Note", in: pane), .unchanged,
            "re-sending identical text is not an edit")
        XCTAssertNil(workspace.apply(text: "# Note", in: pane).readerMessage)
        XCTAssertTrue(workspace.apply(text: "# Note", in: pane).didApply)
    }

    /// The `Bool` wrapper keeps meaning exactly what it did.
    func testTheBooleanWrapperStillFoldsTheFourOutcomesTheSameWay() {
        let workspace = Workspace()
        let pane = workspace.focusedPane
        let oversized = String(
            repeating: "x", count: MarkdownReadLimits.maximumDocumentBytes + 1)

        XCTAssertTrue(workspace.updateText("first", in: pane))
        XCTAssertTrue(workspace.updateText("first", in: pane), "unchanged still reads as applied")
        XCTAssertFalse(workspace.updateText(oversized, in: pane))
        XCTAssertEqual(workspace.document(in: pane)?.text, "first")
    }

    func testWorkspaceAcceptsExactDocumentLimitAndRejectsOneBytePastIt() {
        let workspace = Workspace()
        let pane = workspace.focusedPane
        let exact = String(
            repeating: "é", count: MarkdownReadLimits.maximumDocumentBytes / 2)
        let oversized = exact + "x"

        workspace.updateText(exact, in: pane)
        XCTAssertEqual(workspace.document(in: pane)?.text.utf8.count, exact.utf8.count)

        workspace.updateText(oversized, in: pane)
        let retained = workspace.document(in: pane)?.text
        XCTAssertEqual(
            retained?.utf8.count, exact.utf8.count,
            "a rejected binding update must preserve the exact-size document")
        XCTAssertEqual(retained?.last, "é")
    }

    func testEditorRefusesAnInsertionOneBytePastTheLimitWithoutMutatingStorage() {
        let editor = MarkdownTextView.make()
        let oversized = String(
            repeating: "x", count: MarkdownReadLimits.maximumDocumentBytes + 1)

        XCTAssertFalse(
            editor.shouldChangeText(
                in: NSRange(location: 0, length: 0), replacementString: oversized))
        XCTAssertEqual(editor.markdown, "")
    }

    func testEditorSetMarkdownPreservesTheLastDocumentWhenReplacementIsOversized() {
        let editor = MarkdownTextView.make()
        XCTAssertTrue(editor.setMarkdown("safe"))
        let oversized = String(
            repeating: "x", count: MarkdownReadLimits.maximumDocumentBytes + 1)

        XCTAssertFalse(editor.setMarkdown(oversized))
        XCTAssertEqual(editor.markdown, "safe")
    }

    func testIncrementalRebuildRefusesOneBytePastTheLimitAndPreservesItsParse() {
        let document = IncrementalDocument(text: "# Safe")
        let before = document.parsed
        let oversized = String(
            repeating: "x", count: MarkdownReadLimits.maximumDocumentBytes + 1)

        document.rebuild(from: oversized)

        XCTAssertEqual(document.parsed, before)
    }

    func testIncrementalRebuildAcceptsTheExactByteLimit() {
        let document = IncrementalDocument(text: "")
        let exact = String(
            repeating: "x", count: MarkdownReadLimits.maximumDocumentBytes)

        XCTAssertTrue(document.rebuild(from: exact))
        XCTAssertEqual(document.rejectedEdits, 0)
    }

    func testIncrementalEditRejectsAUTF16OffsetThatDoesNotFitTheCoreABI() {
        let document = IncrementalDocument(text: "# Safe")
        let before = document.parsed

        XCTAssertFalse(
            document.apply(
                range: NSRange(location: Int(UInt32.max) + 1, length: 0),
                replacement: "",
                fullText: "# Safe"))
        XCTAssertEqual(document.parsed, before)
    }

    func testIncrementalEditRejectsOverflowingRangeArithmetic() {
        let document = IncrementalDocument(text: "# Safe")
        let before = document.parsed

        XCTAssertFalse(
            document.apply(
                range: NSRange(location: 1, length: Int.max),
                replacement: "",
                fullText: "# Safe"))
        XCTAssertEqual(document.parsed, before)
    }

    func testSameLengthCoreRefusalIsNotMisreportedAsAFullReparse() {
        let document = IncrementalDocument(text: "# Safe")
        let before = document.parsed
        let fullBefore = document.fullReparses

        XCTAssertFalse(
            document.apply(
                range: NSRange(location: 2, length: 1),
                replacement: "\0",
                fullText: "# \0afe"))

        XCTAssertEqual(document.parsed, before)
        XCTAssertEqual(document.rejectedEdits, 1)
        XCTAssertEqual(document.fullReparses, fullBefore)
        XCTAssertEqual(document.resyncs, 0)
    }

    func testRejectedRebuildPreservesBothTheParseAndUsableIncrementalHandle() {
        let document = IncrementalDocument(text: "plain prose here")
        let before = document.parsed
        XCTAssertFalse(document.rebuild(from: "before\0after"))
        XCTAssertEqual(document.parsed, before)
        XCTAssertEqual(document.rejectedEdits, 1)

        // The refusal cost the handle nothing: an ordinary edit is still
        // absorbed by the *incremental* path rather than forcing a rebuild.
        //
        // The offset is past the fourth column deliberately. `apply` reports
        // `true` only for a shift — a full reparse is a success that returns
        // `false` — and `clear_of_line_start` refuses any edit nearer the
        // margin than that, since four columns of indent open an indented code
        // block. Asked at offset 2, this can only ever reparse, so the shift
        // it was written to prove was unreachable there.
        XCTAssertTrue(
            document.apply(
                range: NSRange(location: 6, length: 1),
                replacement: "X",
                fullText: "plain Xrose here"))
        XCTAssertEqual(document.rejectedEdits, 1, "an accepted edit must not count as refused")
        XCTAssertEqual(document.shiftedEdits, 1)
        XCTAssertEqual(document.resyncs, 0, "the Rust and Swift copies must not have drifted")
    }

    func testOpeningHardLinksReusesOneDocumentIdentity() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("Original.md")
        let hardLink = directory.appendingPathComponent("HardLink.md")
        try "body".write(to: original, atomically: true, encoding: .utf8)
        try FileManager.default.linkItem(at: original, to: hardLink)

        let workspace = Workspace()
        let pane = workspace.focusedPane
        try workspace.open(original, in: pane)
        let identity = try XCTUnwrap(workspace.document(in: pane)?.id)
        try workspace.open(hardLink, in: pane)

        XCTAssertEqual(workspace.state(for: pane).documents.count, 1)
        XCTAssertEqual(workspace.document(in: pane)?.id, identity)
    }

    func testManualSaveAndAutosaveAcceptTheExactByteLimit() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manual = directory.appendingPathComponent("Manual.md")
        let automatic = directory.appendingPathComponent("Automatic.md")
        try "before".write(to: manual, atomically: true, encoding: .utf8)
        try "before".write(to: automatic, atomically: true, encoding: .utf8)
        let exact = String(
            repeating: "x", count: MarkdownReadLimits.maximumDocumentBytes)

        let workspace = Workspace()
        let pane = workspace.focusedPane
        try workspace.open(manual, in: pane)
        XCTAssertTrue(workspace.updateText(exact, in: pane))
        try workspace.save(in: pane)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: manual.path)[.size] as? Int,
            MarkdownReadLimits.maximumDocumentBytes)

        try workspace.open(automatic, in: pane)
        XCTAssertTrue(workspace.updateText(exact, in: pane))
        XCTAssertEqual(workspace.autosave(), 1)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: automatic.path)[.size] as? Int,
            MarkdownReadLimits.maximumDocumentBytes)
    }

    func testOversizedExternalDocumentReplacementIsRejectedBeforeSaveOrAutosave() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Protected.md")
        try "safe".write(to: file, atomically: true, encoding: .utf8)
        let workspace = Workspace()
        let pane = workspace.focusedPane
        try workspace.open(file, in: pane)
        var replacement = try XCTUnwrap(workspace.document(in: pane))
        replacement.text = String(
            repeating: "x", count: MarkdownReadLimits.maximumDocumentBytes + 1)
        replacement.hasUnsavedChanges = true

        XCTAssertFalse(workspace.replace(document: replacement))
        XCTAssertEqual(workspace.autosave(), 0)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "safe")
    }

    func testSaveAsCannotBypassAnOpenDestinationThroughAHardLink() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("Original.md")
        let hardLink = directory.appendingPathComponent("HardLink.md")
        try "protected".write(to: original, atomically: true, encoding: .utf8)
        try FileManager.default.linkItem(at: original, to: hardLink)

        let workspace = Workspace()
        let pane = workspace.focusedPane
        try workspace.open(original, in: pane)
        _ = workspace.newDocument(in: pane)
        workspace.updateText("other", in: pane)

        XCTAssertThrowsError(try workspace.save(in: pane, to: hardLink, overwrite: true)) {
            guard case WorkspaceError.destinationAlreadyOpen = $0 else {
                return XCTFail("unexpected error: \($0)")
            }
        }
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "protected")
    }

    func testRepointingAnOpenSymlinkCannotRedirectASave() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("First.md")
        let second = directory.appendingPathComponent("Second.md")
        let alias = directory.appendingPathComponent("Alias.md")
        try "first".write(to: first, atomically: true, encoding: .utf8)
        try "second".write(to: second, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first)

        let workspace = Workspace()
        let pane = workspace.focusedPane
        try workspace.open(alias, in: pane)
        workspace.updateText("edited", in: pane)
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: second)

        try workspace.save(in: pane)

        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "edited")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "second")
        XCTAssertTrue(try alias.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    }

    func testSaveAsRejectsADanglingSymlinkInsteadOfReplacingIt() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let dangling = directory.appendingPathComponent("Dangling.md")
        try FileManager.default.createSymbolicLink(
            at: dangling,
            withDestinationURL: directory.appendingPathComponent("Missing.md"))
        let workspace = Workspace()
        workspace.updateText("draft", in: workspace.focusedPane)

        XCTAssertThrowsError(
            try workspace.save(
                in: workspace.focusedPane,
                to: dangling,
                overwrite: true)
        ) { error in
            XCTAssertEqual(error as? WorkspaceError, .unsafeDestination(dangling))
        }
        XCTAssertTrue(
            try dangling.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    }
}

@MainActor
final class VaultAsyncLifetimeHardeningTests: XCTestCase {
    private func makeVault(named name: String = UUID().uuidString) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkDevVaultLifetime-\(name)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testAlreadyCancelledGraphRequestDoesNotReturnAComputedGraph() async throws {
        VaultIndexRegistry.shared.reset()
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        try "[[B]]\n".write(
            to: root.appendingPathComponent("A.md"), atomically: true, encoding: .utf8)
        try "B\n".write(
            to: root.appendingPathComponent("B.md"), atomically: true, encoding: .utf8)
        let index = VaultIndex()
        index.open(root)

        let request = Task { () -> VaultGraph in
            withUnsafeCurrentTask { $0?.cancel() }
            return await index.graphOffMain(depth: 2)
        }
        let result = await request.value

        XCTAssertTrue(result.isEmpty, "cancelled work must never publish a completed stale graph")
    }

    func testRepeatedCancelledGraphRequestsNeverPublish() async throws {
        VaultIndexRegistry.shared.reset()
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        for note in 0..<64 {
            try "[[Note-\((note + 1) % 64)]]\n".write(
                to: root.appendingPathComponent("Note-\(note).md"),
                atomically: true,
                encoding: .utf8)
        }
        let index = VaultIndex()
        index.open(root)

        for iteration in 0..<128 {
            let request = Task { () -> VaultGraph in
                withUnsafeCurrentTask { $0?.cancel() }
                return await index.graphOffMain(depth: 5)
            }
            let result = await request.value
            XCTAssertTrue(result.isEmpty, "cancelled request \(iteration)")
        }
    }

    func testRegistryDoesNotRetainAnIndexAfterItsLastOwnerReleasesIt() throws {
        VaultIndexRegistry.shared.reset()
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        weak var released: VaultIndex?

        autoreleasepool {
            let index = VaultIndexRegistry.shared.index(for: root)
            released = index
            XCTAssertNotNil(released)
        }

        XCTAssertNil(released, "the registry must not make every opened vault process-lifetime state")
    }

    func testRegistryDoesNotRetainHundredsOfDistinctReleasedVaults() throws {
        VaultIndexRegistry.shared.reset()
        let parent = try makeVault(named: "Many-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        var references: [WeakVaultReference] = []
        references.reserveCapacity(256)

        for index in 0..<256 {
            let root = parent.appendingPathComponent("Vault-\(index)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            autoreleasepool {
                references.append(WeakVaultReference(VaultIndexRegistry.shared.index(for: root)))
            }
        }

        XCTAssertTrue(
            references.allSatisfy { $0.value == nil },
            "the registry retained \(references.compactMap(\.value).count) released indexes")
    }
}
