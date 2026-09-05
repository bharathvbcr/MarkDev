//
//  WorkspaceTests.swift
//  MarkDevKitTests
//

import XCTest

@testable import MarkDevKit

@MainActor
final class WorkspaceTests: XCTestCase {
    private func makeWorkspace() -> Workspace {
        Workspace(
            documentIO: LocalDocumentIO(),
            transactionRegistry: ProcessFileTransactionRegistry())
    }

    private func makeVault() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testStartsWithOneUntitledDocument() {
        let workspace = makeWorkspace()
        XCTAssertEqual(workspace.layout.paneCount, 1)
        let state = workspace.state(for: workspace.focusedPane)
        XCTAssertEqual(state.documents.count, 1)
        XCTAssertNotNil(state.current, "a new pane must show something")
        XCTAssertEqual(state.current?.title, "Untitled")
    }

    func testInitializerDoesNotLaunderRemoteVaultAuthority() throws {
        let hostile = try XCTUnwrap(
            URL(string: "file://remote.example/tmp/LocalVault/"))

        XCTAssertNil(Workspace(vaultRoot: hostile).vaultRoot)
        XCTAssertEqual(
            Workspace(vaultRoot: URL(fileURLWithPath: "/tmp/LocalVault", isDirectory: true))
                .vaultRoot,
            URL(fileURLWithPath: "/tmp/LocalVault", isDirectory: true).standardizedFileURL)
    }

    func testRestoreDoesNotLaunderRemoteVaultAuthority() async throws {
        let localRoot = try makeVault()
        defer { try? FileManager.default.removeItem(at: localRoot) }
        let hostileRoot = try XCTUnwrap(
            URL(string: "file://remote.example\(localRoot.path)/"))
        let pane = PaneID()
        let snapshot = WorkspaceSnapshot(
            layout: SplitLayout(pane: pane),
            panes: [],
            focusedPane: pane,
            vaultRoot: hostileRoot.absoluteString)

        let synchronous = makeWorkspace()
        synchronous.restore(from: snapshot)
        XCTAssertNil(synchronous.vaultRoot)

        let asynchronous = makeWorkspace()
        _ = try await asynchronous.restoreAsync(from: snapshot)
        XCTAssertNil(asynchronous.vaultRoot)
    }

    func testExternalChangeObservationDoesNotLaunderRemoteVaultAuthority() async throws {
        let localRoot = try makeVault()
        defer { try? FileManager.default.removeItem(at: localRoot) }
        let hostileRoot = try XCTUnwrap(
            URL(string: "file://remote.example\(localRoot.path)/"))
        let workspace = makeWorkspace()
        workspace.vaultRoot = hostileRoot

        do {
            _ = try await workspace.observeExternalChangesAsync([])
            XCTFail("a remote-authority vault must be rejected before normalization")
        } catch {
            XCTAssertEqual(error as? WorkspaceError, .unsupportedLocation(hostileRoot))
        }
    }

    func testDiskRebaseDoesNotLaunderRemoteFileAuthorities() async throws {
        let localRoot = try makeVault()
        defer { try? FileManager.default.removeItem(at: localRoot) }
        let localSource = localRoot.appendingPathComponent("Source.md")
        let localDestination = localRoot.appendingPathComponent("Destination.md")
        let hostileSource = try XCTUnwrap(
            URL(string: "file://remote.example\(localSource.path)"))
        let workspace = Workspace(vaultRoot: localRoot)

        do {
            _ = try await workspace.rebaseFromDiskAsync(
                from: hostileSource,
                to: localDestination,
                within: localRoot)
            XCTFail("a remote-authority source must be rejected before normalization")
        } catch {
            XCTAssertEqual(error as? WorkspaceError, .unsupportedLocation(hostileSource))
        }
    }

    func testRemoteAuthorityPathIsNeverClassifiedInsideALocalVault() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(vaultRoot: root)
        let hostile = try XCTUnwrap(
            URL(string: "file://remote.example\(root.path)/Note.md"))

        XCTAssertFalse(workspace.isInsideVault(hostile))
        XCTAssertTrue(workspace.isOutsideVault(hostile))
    }

    func testOpeningAFileLoadsItsText() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Note.md")
        try write("# Hello", to: file)

        let workspace = makeWorkspace()
        try workspace.open(file, in: workspace.focusedPane)

        let current = workspace.document(in: workspace.focusedPane)
        XCTAssertEqual(current?.text, "# Hello")
        XCTAssertEqual(current?.title, "Note")
    }

    func testOpeningAFileReplacesThePristineUntitledTab() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Note.md")
        try write("# Hello", to: file)

        let workspace = makeWorkspace()
        let pane = workspace.focusedPane
        try workspace.open(file, in: pane)

        XCTAssertEqual(workspace.state(for: pane).documents.count, 1)
        XCTAssertEqual(workspace.document(in: pane)?.url, file)
    }

    func testOpeningAMissingFileDoesNotCreateAnEmptyDocument() {
        let workspace = makeWorkspace()
        let pane = workspace.focusedPane
        let before = workspace.state(for: pane)
        let missing = URL(fileURLWithPath: "/definitely/missing-MarkDev-\(UUID().uuidString).md")

        XCTAssertThrowsError(try workspace.open(missing, in: pane))
        XCTAssertEqual(workspace.state(for: pane), before)
    }

    func testOpeningIntoAClosedPaneFailsLoudly() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Note.md")
        try write("body", to: file)

        let workspace = makeWorkspace()
        let missingPane = PaneID()

        XCTAssertThrowsError(try workspace.open(file, in: missingPane)) { error in
            XCTAssertEqual(error as? WorkspaceError, .paneUnavailable)
        }
    }

    func testOpeningARemoteLocationIsRefusedRatherThanFetched() {
        // `String(contentsOf:)` takes an `https:` URL and fetches it,
        // synchronously, on the main actor. Every open funnels through this
        // boundary — Finder, a drop, a wikilink, `onOpenURL` — so opening a
        // note must be refused here rather than turned into a network request.
        let workspace = makeWorkspace()
        let pane = workspace.focusedPane
        let before = workspace.state(for: pane)
        let remote = URL(string: "https://example.com/note.md")!

        XCTAssertThrowsError(try workspace.open(remote, in: pane)) { error in
            XCTAssertEqual(error as? WorkspaceError, .unsupportedLocation(remote))
        }
        XCTAssertEqual(workspace.state(for: pane), before)
    }

    func testRemoteAuthorityFileURLIsNotCollapsedIntoItsLocalPath() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let localFile = root.appendingPathComponent("Authority.md")
        try write("must stay local", to: localFile)
        let remoteAuthority = try XCTUnwrap(
            URL(string: "file://remote.example\(localFile.path)"))
        let workspace = makeWorkspace()
        let pane = workspace.focusedPane
        let before = workspace.state(for: pane)

        XCTAssertThrowsError(try workspace.open(remoteAuthority, in: pane)) { error in
            XCTAssertEqual(
                error as? WorkspaceError,
                .unsupportedLocation(remoteAuthority))
        }
        XCTAssertEqual(workspace.state(for: pane), before)
    }

    func testOpeningARemoteLocationBesideAPaneLeavesNoSplit() {
        let workspace = makeWorkspace()
        let pane = workspace.focusedPane
        let layout = workspace.layout

        XCTAssertThrowsError(
            try workspace.open(URL(string: "https://example.com/note.md")!, beside: pane))
        XCTAssertEqual(workspace.layout, layout)
    }

    /// A file handed in by Finder is untrusted input. Letting one enormous
    /// Markdown file flow into Data, String, the parser, and TextKit on the
    /// main actor can exhaust the process before an error can be shown.
    func testOpeningAnOversizedDocumentIsRefusedBeforeTheWorkspaceChanges() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Huge.md")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 17 * 1_024 * 1_024)
        try handle.close()

        let workspace = makeWorkspace()
        let pane = workspace.focusedPane
        let before = workspace.state(for: pane)

        XCTAssertThrowsError(try workspace.open(file, in: pane))
        XCTAssertEqual(workspace.state(for: pane), before)
    }

    func testOpeningTheSameFileTwiceFocusesTheExistingTab() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Note.md")
        try write("body", to: file)

        let workspace = makeWorkspace()
        let pane = workspace.focusedPane
        try workspace.open(file, in: pane)
        let countAfterFirst = workspace.state(for: pane).documents.count
        try workspace.open(file, in: pane)

        XCTAssertEqual(
            workspace.state(for: pane).documents.count, countAfterFirst,
            "reopening a file must not stack duplicate tabs")
    }

    func testOpeningASymlinkAndItsTargetReusesOneCanonicalDocumentIdentity() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Target.md")
        let alias = root.appendingPathComponent("Alias.md")
        try write("body", to: target)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)

        let workspace = makeWorkspace()
        let pane = workspace.focusedPane
        try workspace.open(alias, in: pane)
        let firstID = try XCTUnwrap(workspace.document(in: pane)?.id)
        try workspace.open(target, in: pane)

        XCTAssertEqual(workspace.state(for: pane).documents.count, 1)
        XCTAssertEqual(workspace.document(in: pane)?.id, firstID)
        XCTAssertEqual(
            workspace.document(in: pane)?.url,
            target.resolvingSymlinksInPath().standardizedFileURL)
    }

    func testSavingADocumentOpenedThroughASymlinkPreservesTheLinkAndWritesItsTarget() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Target.md")
        let alias = root.appendingPathComponent("Alias.md")
        try write("before", to: target)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)

        let workspace = makeWorkspace()
        let pane = workspace.focusedPane
        try workspace.open(alias, in: pane)
        workspace.updateText("after", in: pane)
        try workspace.save(in: pane)

        XCTAssertTrue(
            try alias.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true,
            "saving through an alias must not replace the alias itself")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "after")
    }

    func testSaveAsCannotBypassAnAlreadyOpenDestinationThroughASymlinkSpelling() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Target.md")
        let alias = root.appendingPathComponent("Alias.md")
        try write("target", to: target)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)

        let workspace = makeWorkspace()
        let pane = workspace.focusedPane
        try workspace.open(target, in: pane)
        _ = workspace.newDocument(in: pane)
        workspace.updateText("other", in: pane)

        XCTAssertThrowsError(try workspace.save(in: pane, to: alias, overwrite: true)) { error in
            guard case WorkspaceError.destinationAlreadyOpen(let refused) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(refused, target.resolvingSymlinksInPath().standardizedFileURL)
        }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "target")
    }

    func testEditingMarksTheDocumentDirty() {
        let workspace = makeWorkspace()
        let pane = workspace.focusedPane
        workspace.updateText("new text", in: pane)

        let current = workspace.document(in: pane)
        XCTAssertEqual(current?.text, "new text")
        XCTAssertTrue(current?.hasUnsavedChanges ?? false)
    }

    func testWritingIdenticalTextDoesNotMarkDirty() {
        // Otherwise round-tripping through the editor binding would mark a
        // pristine document as modified.
        let workspace = makeWorkspace()
        let pane = workspace.focusedPane
        let existing = workspace.document(in: pane)?.text ?? ""
        workspace.updateText(existing, in: pane)
        XCTAssertFalse(workspace.document(in: pane)?.hasUnsavedChanges ?? true)
    }

    func testNewDocumentReusesThePristineUntitledTab() {
        let workspace = makeWorkspace()
        let pane = workspace.focusedPane
        let original = workspace.document(in: pane)?.id

        let created = workspace.newDocument(in: pane)

        XCTAssertEqual(created, original)
        XCTAssertEqual(workspace.state(for: pane).documents.count, 1)
        XCTAssertEqual(workspace.state(for: pane).selection, created)
    }

    func testNewDocumentAddsAndSelectsATabWithoutDiscardingWork() {
        let workspace = makeWorkspace()
        let pane = workspace.focusedPane
        workspace.updateText("keep me", in: pane)
        let existing = workspace.document(in: pane)?.id

        let created = workspace.newDocument(in: pane)

        XCTAssertNotEqual(created, existing)
        XCTAssertEqual(workspace.state(for: pane).documents.count, 2)
        XCTAssertEqual(workspace.state(for: pane).selection, created)
        XCTAssertEqual(workspace.document(in: pane)?.text, "")
        XCTAssertTrue(
            workspace.state(for: pane).documents.contains {
                $0.id == existing && $0.text == "keep me" && $0.hasUnsavedChanges
            })
    }

    func testEditingBackToPersistedTextClearsDirtyState() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Note.md")
        try write("original", to: file)

        let workspace = makeWorkspace()
        let pane = workspace.focusedPane
        try workspace.open(file, in: pane)
        workspace.updateText("changed", in: pane)
        workspace.updateText("original", in: pane)

        XCTAssertFalse(workspace.document(in: pane)?.hasUnsavedChanges ?? true)
    }

    func testSaveWritesAtomicallyAndClearsDirtyState() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Note.md")
        try write("original", to: file)

        let workspace = makeWorkspace()
        let pane = workspace.focusedPane
        try workspace.open(file, in: pane)
        workspace.updateText("changed", in: pane)

        let savedURL = try workspace.save(in: pane)

        XCTAssertEqual(savedURL, file)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "changed")
        XCTAssertFalse(workspace.document(in: pane)?.hasUnsavedChanges ?? true)
    }

    func testSaveAsNamesAnUntitledDocument() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Created.md")

        let workspace = makeWorkspace()
        let pane = workspace.focusedPane
        workspace.updateText("new note", in: pane)

        try workspace.save(in: pane, to: file)

        XCTAssertEqual(workspace.document(in: pane)?.url, file)
        XCTAssertEqual(workspace.document(in: pane)?.title, "Created")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "new note")
    }

    func testSaveRefusesToOverwriteAnExternalEdit() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Note.md")
        try write("original", to: file)

        let workspace = makeWorkspace()
        let pane = workspace.focusedPane
        try workspace.open(file, in: pane)
        workspace.updateText("local edit", in: pane)
        try write("external edit", to: file)

        XCTAssertThrowsError(try workspace.save(in: pane)) { error in
            guard case WorkspaceError.documentChangedOnDisk(file) = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "external edit")
        XCTAssertTrue(workspace.document(in: pane)?.hasUnsavedChanges ?? false)
    }

    func testSaveRefusesANonFileDestination() {
        let workspace = makeWorkspace()
        let pane = workspace.focusedPane
        workspace.updateText("private draft", in: pane)
        let remote = URL(string: "https://example.com/note.md")!

        XCTAssertThrowsError(try workspace.save(in: pane, to: remote)) { error in
            XCTAssertEqual(error as? WorkspaceError, .unsupportedLocation(remote))
        }
        XCTAssertTrue(workspace.document(in: pane)?.hasUnsavedChanges ?? false)
    }

    func testRemoteAuthoritySaveAsCannotAliasTheCurrentLocalDocument() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Private.md")
        try write("on disk", to: file)
        let hostile = try XCTUnwrap(
            URL(string: "file://remote.example\(file.path)"))
        let workspace = makeWorkspace()
        let pane = workspace.focusedPane
        try workspace.open(file, in: pane)
        workspace.updateText("private edit", in: pane)

        XCTAssertThrowsError(
            try workspace.save(in: pane, to: hostile, overwrite: true)
        ) { error in
            XCTAssertEqual(error as? WorkspaceError, .unsupportedLocation(hostile))
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "on disk")
        XCTAssertTrue(workspace.document(in: pane)?.hasUnsavedChanges ?? false)
    }

    func testAsyncRemoteAuthoritySaveAsCannotAliasTheCurrentLocalDocument() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Private.md")
        try write("on disk", to: file)
        let hostile = try XCTUnwrap(
            URL(string: "file://remote.example\(file.path)"))
        let workspace = makeWorkspace()
        let pane = workspace.focusedPane
        try workspace.open(file, in: pane)
        workspace.updateText("private edit", in: pane)

        do {
            _ = try await workspace.authorizeSaveDestination(hostile, overwrite: true)
            XCTFail("remote authority must be retained in the authorization error")
        } catch {
            XCTAssertEqual(error as? WorkspaceError, .unsupportedLocation(hostile))
        }

        let documentID = try XCTUnwrap(workspace.document(in: pane)?.id)
        do {
            _ = try await workspace.saveAsync(
                document: documentID,
                to: hostile,
                overwrite: true)
            XCTFail("remote authority must not route to the current local file")
        } catch {
            XCTAssertEqual(error as? WorkspaceError, .unsupportedLocation(hostile))
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "on disk")
        XCTAssertTrue(workspace.document(in: pane)?.hasUnsavedChanges ?? false)
    }

    func testSavingABackgroundDocumentSavesThatIdentityNotTheSelectedTab() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("First.md")
        let second = root.appendingPathComponent("Second.md")
        try write("first on disk", to: first)
        try write("second on disk", to: second)

        let workspace = makeWorkspace()
        let pane = workspace.focusedPane
        try workspace.open(first, in: pane)
        let firstID = try XCTUnwrap(workspace.document(in: pane)?.id)
        workspace.updateText("first edited", in: pane)
        try workspace.open(second, in: pane)
        let selectedBefore = workspace.state(for: pane).selection

        try workspace.save(document: firstID)

        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "first edited")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "second on disk")
        XCTAssertEqual(workspace.state(for: pane).selection, selectedBefore)
        XCTAssertFalse(
            workspace.state(for: pane).documents.first(where: { $0.id == firstID })?
                .hasUnsavedChanges ?? true)
    }

    func testKeepingMineRebasesOnDiskAndKeepsTheLocalCopyDirty() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Note.md")
        try write("original", to: file)

        let workspace = makeWorkspace()
        let pane = workspace.focusedPane
        try workspace.open(file, in: pane)
        workspace.updateText("mine", in: pane)
        let documentID = try XCTUnwrap(workspace.document(in: pane)?.id)
        try write("theirs", to: file)

        try workspace.keepLocal(document: documentID)

        let kept = try XCTUnwrap(workspace.document(in: pane))
        XCTAssertEqual(kept.text, "mine")
        XCTAssertTrue(kept.hasUnsavedChanges)
        XCTAssertTrue(workspace.requiresConfirmationBeforeClosing(documentID, in: pane))
        XCTAssertEqual(workspace.autosave(), 1)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "mine")
    }

    func testClosingTheLastTabLeavesAnEmptyOne() {
        // A pane with no tabs would render blank with no way to recover.
        let workspace = makeWorkspace()
        let pane = workspace.focusedPane
        guard let only = workspace.state(for: pane).current else {
            return XCTFail("expected a document")
        }
        workspace.close(only.id, in: pane)

        let state = workspace.state(for: pane)
        XCTAssertEqual(state.documents.count, 1)
        XCTAssertNotEqual(state.documents[0].id, only.id)
        XCTAssertNotNil(state.current)
    }

    func testSplittingCarriesTheCurrentDocument() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Carried.md")
        try write("carried text", to: file)

        let workspace = makeWorkspace()
        let first = workspace.focusedPane
        try workspace.open(file, in: first)

        let second = workspace.split(first, edge: .trailing)
        XCTAssertEqual(workspace.layout.paneCount, 2)
        XCTAssertEqual(
            workspace.document(in: second)?.text, "carried text",
            "a new pane should open on something, not blank")
        XCTAssertEqual(workspace.focusedPane, second, "focus follows the new pane")
    }

    func testOpeningAFileBesideAPaneCreatesATrailingSplit() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("Original.md")
        let dropped = root.appendingPathComponent("Dropped.md")
        try write("# Original", to: original)
        try write("# Dropped", to: dropped)

        let workspace = makeWorkspace()
        let first = workspace.focusedPane
        try workspace.open(original, in: first)

        let second = try workspace.open(dropped, beside: first, edge: .trailing)

        XCTAssertEqual(workspace.layout.paneCount, 2)
        XCTAssertEqual(workspace.layout.panes, [first, second])
        XCTAssertEqual(workspace.document(in: first)?.url, original)
        XCTAssertEqual(workspace.document(in: second)?.url, dropped)
        XCTAssertEqual(workspace.document(in: second)?.text, "# Dropped")
        XCTAssertEqual(workspace.focusedPane, second)
    }

    func testOpeningAMissingFileBesideAPaneDoesNotLeaveASplit() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("Original.md")
        let missing = root.appendingPathComponent("Missing.md")
        try write("# Original", to: original)

        let workspace = makeWorkspace()
        let first = workspace.focusedPane
        try workspace.open(original, in: first)
        let layoutBefore = workspace.layout
        let panesBefore = workspace.panes

        XCTAssertThrowsError(
            try workspace.open(missing, beside: first, edge: .trailing))
        XCTAssertEqual(workspace.layout, layoutBefore)
        XCTAssertEqual(workspace.panes, panesBefore)
        XCTAssertEqual(workspace.focusedPane, first)
    }

    func testMarkdownDropPolicyMatchesDeclaredExtensionsAndRejectsDirectories() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let markdownDirectory = root.appendingPathComponent("Archive.md", isDirectory: true)
        try FileManager.default.createDirectory(
            at: markdownDirectory, withIntermediateDirectories: false)

        for name in ["Note.md", "Note.MARKDOWN", "Note.mdown", "Note.mdx", "Note.mkd"] {
            XCTAssertTrue(MarkdownDropPolicy.accepts(root.appendingPathComponent(name)), name)
        }
        XCTAssertFalse(MarkdownDropPolicy.accepts(root.appendingPathComponent("Image.png")))
        XCTAssertFalse(MarkdownDropPolicy.accepts(root.appendingPathComponent("README")))
        XCTAssertFalse(MarkdownDropPolicy.accepts(markdownDirectory))
        XCTAssertFalse(MarkdownDropPolicy.accepts(try XCTUnwrap(
            URL(string: "file://remote.example\(root.path)/Note.md"))))
    }

    func testDroppingAnAlreadyOpenFileSharesItsDocumentIdentity() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Shared.md")
        try write("original", to: file)

        let workspace = makeWorkspace()
        let first = workspace.focusedPane
        try workspace.open(file, in: first)
        let second = try workspace.open(file, beside: first)

        XCTAssertEqual(workspace.document(in: first)?.id, workspace.document(in: second)?.id)
        workspace.updateText("edited in split", in: second)
        XCTAssertEqual(workspace.document(in: first)?.text, "edited in split")
    }

    func testSplitSharesOneDocumentIdentityAndPropagatesEdits() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Shared.md")
        try write("original", to: file)

        let workspace = makeWorkspace()
        let first = workspace.focusedPane
        try workspace.open(file, in: first)
        let second = workspace.split(first, edge: .trailing)

        XCTAssertEqual(workspace.document(in: first)?.id, workspace.document(in: second)?.id)
        workspace.updateText("edited from second pane", in: second)
        XCTAssertEqual(workspace.document(in: first)?.text, "edited from second pane")
        XCTAssertTrue(workspace.document(in: first)?.hasUnsavedChanges ?? false)
    }

    func testDirtyDocumentOnlyNeedsConfirmationBeforeItsLastViewCloses() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Shared.md")
        try write("original", to: file)

        let workspace = makeWorkspace()
        let first = workspace.focusedPane
        try workspace.open(file, in: first)
        let second = workspace.split(first, edge: .trailing)
        workspace.updateText("changed", in: second)
        let document = try XCTUnwrap(workspace.document(in: first))

        XCTAssertFalse(workspace.requiresConfirmationBeforeClosing(document.id, in: first))
        workspace.close(document.id, in: first)
        XCTAssertTrue(workspace.requiresConfirmationBeforeClosing(document.id, in: second))
    }

    func testCloseOutcomeReportsIdentityOnlyAfterTheFinalSplitOccurrenceCloses() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Shared.md")
        try write("shared", to: file)

        let workspace = makeWorkspace()
        let first = workspace.focusedPane
        try workspace.open(file, in: first)
        let second = workspace.split(first, edge: .trailing)
        let documentID = try XCTUnwrap(workspace.document(in: first)?.id)

        let firstClose = workspace.close(documentID, in: first)
        XCTAssertTrue(
            firstClose.documentIDsNoLongerOpen.isEmpty,
            "the identity remains live in the other split")

        let finalClose = workspace.close(documentID, in: second)
        XCTAssertEqual(finalClose.documentIDsNoLongerOpen, [documentID])
    }

    func testClosePaneOutcomeSeparatesSharedAndLastOccurrenceDocuments() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let sharedFile = root.appendingPathComponent("Shared.md")
        let uniqueFile = root.appendingPathComponent("Unique.md")
        try write("shared", to: sharedFile)
        try write("unique", to: uniqueFile)

        let workspace = makeWorkspace()
        let first = workspace.focusedPane
        try workspace.open(sharedFile, in: first)
        let sharedID = try XCTUnwrap(workspace.document(in: first)?.id)
        let second = workspace.split(first, edge: .trailing)
        try workspace.open(uniqueFile, in: second)
        let uniqueID = try XCTUnwrap(workspace.document(in: second)?.id)

        let outcome = workspace.closePane(second)

        XCTAssertEqual(outcome.documentIDsNoLongerOpen, [uniqueID])
        XCTAssertEqual(workspace.document(in: first)?.id, sharedID)
        XCTAssertNotNil(workspace.pane(containing: sharedID))
    }

    func testDocumentsWithUnsavedChangesDeduplicatesSplitViews() {
        let workspace = makeWorkspace()
        let first = workspace.focusedPane
        let second = workspace.split(first, edge: .trailing)
        workspace.updateText("one shared edit", in: second)

        let dirty = workspace.documentsWithUnsavedChanges

        XCTAssertEqual(dirty.count, 1)
        XCTAssertEqual(dirty.first?.id, workspace.document(in: first)?.id)
        XCTAssertEqual(workspace.pane(containing: dirty[0].id), first)
    }

    func testClosingAPaneReturnsFocusToASurvivor() {
        let workspace = makeWorkspace()
        let first = workspace.focusedPane
        let second = workspace.split(first, edge: .trailing)

        workspace.closePane(second)
        XCTAssertEqual(workspace.layout.paneCount, 1)
        XCTAssertTrue(
            workspace.layout.panes.contains(workspace.focusedPane),
            "focus must land on a pane that still exists")
    }

    func testPruningDropsStateForRemovedPanes() {
        // Without pruning, every closed pane keeps the full text of its
        // documents alive for the window's lifetime.
        let workspace = makeWorkspace()
        let first = workspace.focusedPane
        let second = workspace.split(first, edge: .bottom)
        workspace.updateText("some long document body", in: second)

        workspace.closePane(second)
        workspace.pruneOrphanedPanes()

        XCTAssertEqual(workspace.state(for: second).documents.count, 0)
    }

    func testClosingTheOnlyPaneIsRefused() {
        let workspace = makeWorkspace()
        let only = workspace.focusedPane
        workspace.closePane(only)
        XCTAssertEqual(workspace.layout.paneCount, 1)
    }

    // MARK: - Moving between panes

    func testFocusMovesThroughPanesInVisualOrderAndWraps() {
        let workspace = makeWorkspace()
        let first = workspace.focusedPane
        let second = workspace.split(first, edge: .trailing)
        let third = workspace.split(second, edge: .trailing)
        XCTAssertEqual(workspace.layout.panes, [first, second, third])

        workspace.focusedPane = first
        workspace.focusPane(offset: 1)
        XCTAssertEqual(workspace.focusedPane, second)

        workspace.focusPane(offset: 1)
        XCTAssertEqual(workspace.focusedPane, third)

        workspace.focusPane(offset: 1)
        XCTAssertEqual(workspace.focusedPane, first, "focus must wrap forwards")

        workspace.focusPane(offset: -1)
        XCTAssertEqual(workspace.focusedPane, third, "focus must wrap backwards")
    }

    func testFocusingAnotherPaneDoesNothingWithOnlyOne() {
        let workspace = makeWorkspace()
        let only = workspace.focusedPane
        workspace.focusPane(offset: 1)
        XCTAssertEqual(workspace.focusedPane, only)
    }

    func testFocusMovesEvenWhenTheFocusedPaneIsNoLongerInTheLayout() {
        // Closing a pane can leave focus pointing at it until the layout
        // change is observed. The shortcut must still move rather than
        // silently doing nothing.
        let workspace = makeWorkspace()
        let first = workspace.focusedPane
        let second = workspace.split(first, edge: .bottom)
        let third = workspace.split(second, edge: .bottom)
        workspace.closePane(third)
        workspace.focusedPane = third

        workspace.focusPane(offset: 1)
        XCTAssertTrue(
            workspace.layout.panes.contains(workspace.focusedPane),
            "focus must land somewhere that exists")
    }
}

final class FileTreeTests: XCTestCase {
    private func makeVault() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevTree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testRemoteAuthorityCannotInventoryTheMatchingLocalDirectory() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        try "local".write(
            to: root.appendingPathComponent("Local.md"),
            atomically: true,
            encoding: .utf8)
        let hostile = try XCTUnwrap(URL(string: "file://remote.example\(root.path)/"))

        XCTAssertTrue(FileTree.children(of: hostile).isEmpty)
        let scan = FileTree.scanMarkdownFiles(under: hostile)
        XCTAssertTrue(scan.files.isEmpty)
        XCTAssertFalse(scan.isComplete)
        XCTAssertEqual(scan.unreadableDirectories, 1)
    }

    func testListsMarkdownAndDirectoriesOnly() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }

        try "a".write(to: root.appendingPathComponent("Note.md"), atomically: true, encoding: .utf8)
        try "b".write(to: root.appendingPathComponent("Other.markdown"), atomically: true, encoding: .utf8)
        try "c".write(to: root.appendingPathComponent("image.png"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Folder"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)

        let names = FileTree.children(of: root).map(\.name)
        XCTAssertTrue(names.contains("Note.md"))
        XCTAssertTrue(names.contains("Other.markdown"))
        XCTAssertTrue(names.contains("Folder"))
        XCTAssertFalse(names.contains("image.png"), "non-markdown files are noise here")
        XCTAssertFalse(names.contains(".git"), "ignored directories must stay hidden")
    }

    func testDirectoriesSortBeforeFiles() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }

        try "a".write(to: root.appendingPathComponent("aaa.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("zzz"), withIntermediateDirectories: true)

        let nodes = FileTree.children(of: root)
        XCTAssertEqual(nodes.first?.name, "zzz", "directories come first, as in Finder")
    }

    func testUnreadableDirectoryYieldsEmptyRatherThanFailing() {
        let missing = URL(fileURLWithPath: "/definitely/not/a/real/path-\(UUID().uuidString)")
        XCTAssertEqual(FileTree.children(of: missing), [])
    }
}

final class FuzzyMatchTests: XCTestCase {
    func testMatchesSubsequences() {
        XCTAssertNotNil(FuzzyMatch.score("MarkDevView", query: "mdv"))
        XCTAssertNotNil(FuzzyMatch.score("Release Notes.md", query: "notes"))
    }

    func testRejectsNonSubsequences() {
        XCTAssertNil(FuzzyMatch.score("abc", query: "cab"), "order must be respected")
        XCTAssertNil(FuzzyMatch.score("short", query: "muchlongerquery"))
    }

    func testEmptyQueryMatchesEverything() {
        XCTAssertEqual(FuzzyMatch.score("anything", query: ""), 0)
        let all = ["a", "b"]
        XCTAssertEqual(FuzzyMatch.rank(all, query: "") { $0 }, all)
    }

    func testWordBoundariesRankHigher() {
        let boundary = FuzzyMatch.score("Meeting Notes", query: "mn") ?? 0
        let scattered = FuzzyMatch.score("mountain", query: "mn") ?? 0
        XCTAssertGreaterThan(
            boundary, scattered,
            "initials of words should beat letters buried mid-word")
    }

    func testConsecutiveRunsRankHigher() {
        let consecutive = FuzzyMatch.score("readme", query: "read") ?? 0
        let scattered = FuzzyMatch.score("rxexaxd", query: "read") ?? 0
        XCTAssertGreaterThan(consecutive, scattered)
    }

    func testShorterCandidatesWinTies() {
        let ranked = FuzzyMatch.rank(
            ["Notes about a great many other things.md", "Notes.md"], query: "notes") { $0 }
        XCTAssertEqual(ranked.first, "Notes.md")
    }

    func testRankingDropsNonMatches() {
        let ranked = FuzzyMatch.rank(["alpha", "beta", "gamma"], query: "ga") { $0 }
        XCTAssertEqual(ranked, ["gamma"])
    }
}

final class CommandPaletteNavigationTests: XCTestCase {
    func testActionIdentityDoesNotDependOnVisibleTitle() {
        let command = Command(
            title: "Guardar", symbol: "square.and.arrow.down", kind: .action(.save))
        XCTAssertEqual(command.kind, .action(.save))
    }

    func testArrowNavigationWrapsInBothDirections() {
        XCTAssertEqual(CommandPalette.movedHighlight(0, by: -1, resultCount: 4), 3)
        XCTAssertEqual(CommandPalette.movedHighlight(3, by: 1, resultCount: 4), 0)
    }

    func testLargeOffsetsStayInBounds() {
        XCTAssertEqual(CommandPalette.movedHighlight(1, by: 9, resultCount: 4), 2)
        XCTAssertEqual(CommandPalette.movedHighlight(1, by: -10, resultCount: 4), 3)
    }

    func testEmptyResultsHaveNoSelection() {
        XCTAssertNil(CommandPalette.movedHighlight(0, by: 1, resultCount: 0))
    }

    /// A hover fired because the list scrolled under a stationary pointer
    /// arrives at the point the pointer is already at. Taking the highlight
    /// there lets a keyboard-driven scroll — or a mouse merely crossing the
    /// palette — walk the list on its own.
    func testAStationaryPointerDoesNotTakeTheHighlight() {
        let resting = CGPoint(x: 120, y: 64)
        XCTAssertFalse(CommandPalette.pointerMoved(from: resting, to: resting))
        XCTAssertFalse(
            CommandPalette.pointerMoved(from: resting, to: CGPoint(x: 120.2, y: 63.8)))
    }

    func testAMovedPointerTakesTheHighlight() {
        let resting = CGPoint(x: 120, y: 64)
        XCTAssertTrue(CommandPalette.pointerMoved(from: nil, to: resting))
        XCTAssertTrue(CommandPalette.pointerMoved(from: resting, to: CGPoint(x: 120, y: 86)))
        XCTAssertTrue(CommandPalette.pointerMoved(from: resting, to: CGPoint(x: 98, y: 64)))
    }
}
