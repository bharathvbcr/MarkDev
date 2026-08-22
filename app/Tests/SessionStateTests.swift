//
//  SessionStateTests.swift
//  MarkDevKitTests
//
//  What a window carries across launches.
//

import XCTest

@testable import MarkDevKit

@MainActor
final class SessionStateTests: XCTestCase {
    private func makeVault() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Snapshot and restore

    func testARestoredWorkspaceOpensTheSameNotesInTheSamePanes() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("First.md")
        let second = root.appendingPathComponent("Second.md")
        try write("# First", to: first)
        try write("# Second", to: second)

        let original = Workspace(vaultRoot: root)
        try original.open(first, in: original.focusedPane)
        let otherPane = original.split(original.focusedPane, edge: .trailing)
        try original.open(second, in: otherPane)

        let snapshot = original.snapshot()
        // Round-trip through the same encoding the store uses, so the test
        // fails for decoding reasons too rather than only for model reasons.
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)

        let restored = Workspace()
        restored.restore(from: decoded)

        XCTAssertEqual(restored.layout.paneCount, 2)
        XCTAssertEqual(
            restored.document(in: restored.layout.panes[0])?.text, "# First")
        XCTAssertEqual(
            restored.document(in: restored.layout.panes[1])?.text, "# Second")
        XCTAssertEqual(restored.vaultRoot?.standardizedFileURL, root.standardizedFileURL)
        XCTAssertEqual(restored.focusedPane, decoded.focusedPane)
        XCTAssertEqual(
            restored.state(for: restored.layout.panes[1]).selection,
            restored.document(in: restored.layout.panes[1])?.id,
            "the pane's frontmost tab must survive the trip")
    }

    func testARestoreSkipsDocumentsThatNoLongerExist() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let kept = root.appendingPathComponent("Kept.md")
        try write("# Kept", to: kept)

        let paneID = PaneID()
        let missing = root.appendingPathComponent("Deleted.md")
        let snapshot = WorkspaceSnapshot(
            layout: SplitLayout(pane: paneID),
            panes: [
                PaneSnapshot(
                    pane: paneID,
                    documents: [
                        DocumentSnapshot(url: missing.absoluteString),
                        DocumentSnapshot(url: kept.absoluteString),
                    ],
                    selection: nil)
            ],
            focusedPane: paneID,
            vaultRoot: nil)

        let restored = Workspace()
        restored.restore(from: snapshot)

        let documents = restored.state(for: paneID).documents
        XCTAssertEqual(documents.count, 1, "a deleted note must not become an empty tab")
        XCTAssertEqual(documents.first?.url?.lastPathComponent, "Kept.md")
    }

    func testAPaneWhoseNotesAreAllGoneRestoresAsPristine() throws {
        let paneID = PaneID()
        let snapshot = WorkspaceSnapshot(
            layout: SplitLayout(pane: paneID),
            panes: [
                PaneSnapshot(
                    pane: paneID,
                    documents: [DocumentSnapshot(url: "file:///nowhere/Gone.md")],
                    selection: nil)
            ],
            focusedPane: paneID,
            vaultRoot: nil)

        let restored = Workspace()
        restored.restore(from: snapshot)

        let state = restored.state(for: paneID)
        XCTAssertEqual(state.documents.count, 1)
        XCTAssertEqual(state.documents.first?.title, "Untitled")
    }

    func testUntitledDocumentsAreNotCarriedAcrossLaunches() {
        let workspace = Workspace()
        workspace.updateText("Draft nobody saved", in: workspace.focusedPane)

        let snapshot = workspace.snapshot()
        XCTAssertTrue(snapshot.panes.allSatisfy(\.documents.isEmpty))
    }

    func testAFocusedPaneMissingFromTheLayoutFallsBackToTheFirst() throws {
        let paneID = PaneID()
        let snapshot = WorkspaceSnapshot(
            layout: SplitLayout(pane: paneID),
            panes: [PaneSnapshot(pane: paneID, documents: [], selection: nil)],
            focusedPane: PaneID(),
            vaultRoot: nil)

        let restored = Workspace()
        restored.restore(from: snapshot)

        XCTAssertEqual(restored.focusedPane, paneID)
    }

    // MARK: - Autosave

    func testAutosaveWritesDirtyFilesAndClearsTheirDirtyState() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Note.md")
        try write("# Before", to: file)

        let workspace = Workspace()
        try workspace.open(file, in: workspace.focusedPane)
        workspace.updateText("# After", in: workspace.focusedPane)
        XCTAssertTrue(workspace.document(in: workspace.focusedPane)!.hasUnsavedChanges)

        let written = workspace.autosave()

        XCTAssertEqual(written, 1)
        XCTAssertFalse(
            workspace.document(in: workspace.focusedPane)!.hasUnsavedChanges,
            "a document autosave wrote must no longer report unsaved work")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "# After")
    }

    func testAutosaveNeverOverwritesAnExternalEdit() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Note.md")
        try write("# Mine", to: file)

        let workspace = Workspace()
        try workspace.open(file, in: workspace.focusedPane)
        workspace.updateText("# Also mine", in: workspace.focusedPane)

        // Another app gets in between the open and the autosave.
        try "# Theirs".write(to: file, atomically: true, encoding: .utf8)

        let written = workspace.autosave()

        XCTAssertEqual(written, 0)
        XCTAssertEqual(
            try String(contentsOf: file, encoding: .utf8), "# Theirs",
            "autosave must lose the race against an external edit")
        XCTAssertTrue(
            workspace.document(in: workspace.focusedPane)!.hasUnsavedChanges,
            "the document stays dirty so an explicit save surfaces the conflict")
    }

    func testAutosaveLeavesUntitledDocumentsAlone() {
        let workspace = Workspace()
        workspace.updateText("Unsaved scratch", in: workspace.focusedPane)

        XCTAssertEqual(workspace.autosave(), 0)
        XCTAssertTrue(workspace.document(in: workspace.focusedPane)!.hasUnsavedChanges)
    }
}
