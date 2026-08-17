//
//  WorkspaceTests.swift
//  MarkDevKitTests
//

import XCTest

@testable import MarkDevKit

@MainActor
final class WorkspaceTests: XCTestCase {
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
        let workspace = Workspace()
        XCTAssertEqual(workspace.layout.paneCount, 1)
        let state = workspace.state(for: workspace.focusedPane)
        XCTAssertEqual(state.documents.count, 1)
        XCTAssertNotNil(state.current, "a new pane must show something")
        XCTAssertEqual(state.current?.title, "Untitled")
    }

    func testOpeningAFileLoadsItsText() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Note.md")
        try write("# Hello", to: file)

        let workspace = Workspace()
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

        let workspace = Workspace()
        let pane = workspace.focusedPane
        try workspace.open(file, in: pane)

        XCTAssertEqual(workspace.state(for: pane).documents.count, 1)
        XCTAssertEqual(workspace.document(in: pane)?.url, file)
    }

    func testOpeningAMissingFileDoesNotCreateAnEmptyDocument() {
        let workspace = Workspace()
        let pane = workspace.focusedPane
        let before = workspace.state(for: pane)
        let missing = URL(fileURLWithPath: "/definitely/missing-MarkDev-\(UUID().uuidString).md")

        XCTAssertThrowsError(try workspace.open(missing, in: pane))
        XCTAssertEqual(workspace.state(for: pane), before)
    }

    func testOpeningTheSameFileTwiceFocusesTheExistingTab() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Note.md")
        try write("body", to: file)

        let workspace = Workspace()
        let pane = workspace.focusedPane
        try workspace.open(file, in: pane)
        let countAfterFirst = workspace.state(for: pane).documents.count
        try workspace.open(file, in: pane)

        XCTAssertEqual(
            workspace.state(for: pane).documents.count, countAfterFirst,
            "reopening a file must not stack duplicate tabs")
    }

    func testEditingMarksTheDocumentDirty() {
        let workspace = Workspace()
        let pane = workspace.focusedPane
        workspace.updateText("new text", in: pane)

        let current = workspace.document(in: pane)
        XCTAssertEqual(current?.text, "new text")
        XCTAssertTrue(current?.hasUnsavedChanges ?? false)
    }

    func testWritingIdenticalTextDoesNotMarkDirty() {
        // Otherwise round-tripping through the editor binding would mark a
        // pristine document as modified.
        let workspace = Workspace()
        let pane = workspace.focusedPane
        let existing = workspace.document(in: pane)?.text ?? ""
        workspace.updateText(existing, in: pane)
        XCTAssertFalse(workspace.document(in: pane)?.hasUnsavedChanges ?? true)
    }

    func testNewDocumentReusesThePristineUntitledTab() {
        let workspace = Workspace()
        let pane = workspace.focusedPane
        let original = workspace.document(in: pane)?.id

        let created = workspace.newDocument(in: pane)

        XCTAssertEqual(created, original)
        XCTAssertEqual(workspace.state(for: pane).documents.count, 1)
        XCTAssertEqual(workspace.state(for: pane).selection, created)
    }

    func testNewDocumentAddsAndSelectsATabWithoutDiscardingWork() {
        let workspace = Workspace()
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

        let workspace = Workspace()
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

        let workspace = Workspace()
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

        let workspace = Workspace()
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

        let workspace = Workspace()
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

    func testClosingTheLastTabLeavesAnEmptyOne() {
        // A pane with no tabs would render blank with no way to recover.
        let workspace = Workspace()
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

        let workspace = Workspace()
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

        let workspace = Workspace()
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

        let workspace = Workspace()
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
    }

    func testDroppingAnAlreadyOpenFileSharesItsDocumentIdentity() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Shared.md")
        try write("original", to: file)

        let workspace = Workspace()
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

        let workspace = Workspace()
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

        let workspace = Workspace()
        let first = workspace.focusedPane
        try workspace.open(file, in: first)
        let second = workspace.split(first, edge: .trailing)
        workspace.updateText("changed", in: second)
        let document = try XCTUnwrap(workspace.document(in: first))

        XCTAssertFalse(workspace.requiresConfirmationBeforeClosing(document.id, in: first))
        workspace.close(document.id, in: first)
        XCTAssertTrue(workspace.requiresConfirmationBeforeClosing(document.id, in: second))
    }

    func testDocumentsWithUnsavedChangesDeduplicatesSplitViews() {
        let workspace = Workspace()
        let first = workspace.focusedPane
        let second = workspace.split(first, edge: .trailing)
        workspace.updateText("one shared edit", in: second)

        let dirty = workspace.documentsWithUnsavedChanges

        XCTAssertEqual(dirty.count, 1)
        XCTAssertEqual(dirty.first?.id, workspace.document(in: first)?.id)
        XCTAssertEqual(workspace.pane(containing: dirty[0].id), first)
    }

    func testClosingAPaneReturnsFocusToASurvivor() {
        let workspace = Workspace()
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
        let workspace = Workspace()
        let first = workspace.focusedPane
        let second = workspace.split(first, edge: .bottom)
        workspace.updateText("some long document body", in: second)

        workspace.closePane(second)
        workspace.pruneOrphanedPanes()

        XCTAssertEqual(workspace.state(for: second).documents.count, 0)
    }

    func testClosingTheOnlyPaneIsRefused() {
        let workspace = Workspace()
        let only = workspace.focusedPane
        workspace.closePane(only)
        XCTAssertEqual(workspace.layout.paneCount, 1)
    }
}

final class FileTreeTests: XCTestCase {
    private func makeVault() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevTree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
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
}
