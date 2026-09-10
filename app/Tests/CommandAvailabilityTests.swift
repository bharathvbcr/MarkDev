//
//  CommandAvailabilityTests.swift
//  MarkDevKitTests
//
//  Every command renderer consumes one enablement contract.
//

import Foundation
import MarkDevKit
import XCTest

final class CommandAvailabilityTests: XCTestCase {
    private func availability(
        hasFocusedPane: Bool = true,
        paneCount: Int = 1,
        maximumPaneCount: Int = SplitLayout.maximumPanes,
        hasDocument: Bool = true,
        hasEditorSurface: Bool = true,
        hasAttachedWritingSurface: Bool = true,
        hasTextSelection: Bool = true,
        hasProofreadingMarks: Bool = true,
        canRevealHarnessTerminal: Bool = true,
        isPerformingDestructiveOperation: Bool = false,
        canSaveVault: Bool = false
    ) -> CommandAvailability {
        CommandAvailability(
            hasFocusedPane: hasFocusedPane,
            paneCount: paneCount,
            maximumPaneCount: maximumPaneCount,
            hasDocument: hasDocument,
            hasEditorSurface: hasEditorSurface,
            hasAttachedWritingSurface: hasAttachedWritingSurface,
            hasTextSelection: hasTextSelection,
            hasProofreadingMarks: hasProofreadingMarks,
            canRevealHarnessTerminal: canRevealHarnessTerminal,
            isPerformingDestructiveOperation: isPerformingDestructiveOperation,
            canSaveVault: canSaveVault)
    }

    func testSavingVaultsRequiresAnUnsavedOpenVaultAndViewingWorksWithoutADocument() {
        XCTAssertFalse(availability().allows(.saveVault))
        XCTAssertTrue(availability(hasDocument: false, canSaveVault: true).allows(.saveVault))
        XCTAssertTrue(availability(hasDocument: false).allows(.showSavedVaults))
        let busy = availability(isPerformingDestructiveOperation: true, canSaveVault: true)
        XCTAssertFalse(busy.allows(.saveVault))
        XCTAssertFalse(busy.allows(.showSavedVaults))
    }

    func testNoDocumentDisablesOnlyCommandsThatNeedDocumentAuthority() {
        let state = availability(hasDocument: false)

        for action in [
            CommandAction.save, .saveAs, .exportHTML, .printDocument,
            .writingTools, .proofreadDocument, .clearProofreading, .analyzeNote, .askHarness,
        ] {
            XCTAssertFalse(state.allows(action), "\(action) requires a current document")
        }

        XCTAssertTrue(state.allows(.newDocument))
        XCTAssertTrue(state.allows(.openFile))
        XCTAssertTrue(state.allows(.toggleTerminal))
        XCTAssertTrue(state.allows(.moveTerminal))
        XCTAssertTrue(state.allows(.zoomIn), "zoom targets the mounted editor surface")
    }

    func testPaneActionsRespectSingleMaximumAndMissingPaneStates() {
        let onePane = availability(paneCount: 1)
        XCTAssertTrue(onePane.allows(.splitRight))
        XCTAssertTrue(onePane.allows(.splitDown))
        XCTAssertFalse(onePane.allows(.closePane))
        XCTAssertFalse(onePane.allows(.focusNextPane))
        XCTAssertFalse(onePane.allows(.focusPreviousPane))

        let twoPanes = availability(paneCount: 2)
        XCTAssertTrue(twoPanes.allows(.splitRight))
        XCTAssertTrue(twoPanes.allows(.closePane))
        XCTAssertTrue(twoPanes.allows(.focusNextPane))
        XCTAssertTrue(twoPanes.allows(.focusPreviousPane))

        let full = availability(paneCount: 4, maximumPaneCount: 4)
        XCTAssertFalse(full.allows(.splitRight))
        XCTAssertFalse(full.allows(.splitDown))
        XCTAssertTrue(full.allows(.closePane))

        let missing = availability(hasFocusedPane: false, paneCount: 2)
        XCTAssertFalse(missing.allows(.newDocument))
        XCTAssertFalse(missing.allows(.splitRight))
        XCTAssertFalse(missing.allows(.closePane))
        XCTAssertFalse(missing.allows(.focusNextPane))
    }

    func testEditorAndWritingActionsRequireTheirExactSurfaceAuthority() {
        let noEditor = availability(
            hasEditorSurface: false,
            hasAttachedWritingSurface: false,
            hasTextSelection: false,
            hasProofreadingMarks: false)
        for action in [
            CommandAction.zoomIn, .zoomOut, .resetZoom, .printDocument,
            .writingTools, .proofreadDocument, .clearProofreading, .analyzeNote, .askHarness,
        ] {
            XCTAssertFalse(noEditor.allows(action), "\(action) cannot target a missing editor")
        }

        let mountedButNotAttached = availability(
            hasAttachedWritingSurface: false,
            hasTextSelection: true,
            hasProofreadingMarks: true)
        XCTAssertTrue(mountedButNotAttached.allows(.zoomIn))
        XCTAssertTrue(mountedButNotAttached.allows(.printDocument))
        XCTAssertFalse(mountedButNotAttached.allows(.writingTools))
        XCTAssertFalse(mountedButNotAttached.allows(.proofreadDocument))
        XCTAssertFalse(mountedButNotAttached.allows(.clearProofreading))

        let caretOnly = availability(
            hasTextSelection: false,
            hasProofreadingMarks: false)
        XCTAssertTrue(
            caretOnly.allows(.writingTools),
            "the attached panel opens to explain why a selection is required")
        XCTAssertTrue(caretOnly.allows(.proofreadDocument))
        XCTAssertFalse(caretOnly.allows(.clearProofreading))

        let selectedWithMarks = availability(
            hasTextSelection: true,
            hasProofreadingMarks: true)
        XCTAssertTrue(selectedWithMarks.allows(.writingTools))
        XCTAssertTrue(selectedWithMarks.allows(.clearProofreading))
    }

    func testHarnessTerminalNeedsBothDiscoveryAndTerminalCapacityOrReuse() {
        XCTAssertFalse(
            availability(canRevealHarnessTerminal: false).allows(.openHarnessTerminal))
        XCTAssertTrue(
            availability(canRevealHarnessTerminal: true).allows(.openHarnessTerminal))

        // Ordinary terminal visibility and placement do not need MANVI.
        let unavailableHarness = availability(canRevealHarnessTerminal: false)
        XCTAssertTrue(unavailableHarness.allows(.toggleTerminal))
        XCTAssertTrue(unavailableHarness.allows(.moveTerminal))
        XCTAssertTrue(unavailableHarness.allows(.askHarness))
    }

    func testDestructiveOperationRejectsEveryWorkspaceActionAndPaletteFile() {
        let state = availability(isPerformingDestructiveOperation: true)
        for action in [
            CommandAction.newDocument, .openFile, .openVault, .saveVault, .showSavedVaults, .save, .saveAs,
            .toggleCommandPalette, .toggleSidebar, .toggleInspector, .toggleTerminal,
            .toggleGraph, .splitRight, .splitDown, .closePane, .focusNextPane,
            .focusPreviousPane, .setMode(.source), .writingTools, .proofreadDocument,
            .clearProofreading, .analyzeNote, .askHarness, .openHarnessTerminal,
            .moveTerminal, .zoomIn, .zoomOut, .resetZoom, .exportHTML, .printDocument,
        ] {
            XCTAssertFalse(state.allows(action), "\(action) must wait for the operation")
        }

        XCTAssertTrue(state.allows(.newWindow), "another window is process-scoped")
        XCTAssertFalse(state.allows(.file(URL(fileURLWithPath: "/tmp/note.md"))))
        XCTAssertFalse(
            state.allows(.searchResult(URL(fileURLWithPath: "/tmp/note.md"), line: 1)))
    }
}

/// Source contracts pin the integration points that existed independently
/// before this fix. The pure tests above prove policy; these prove that every
/// command surface actually asks it.
final class CommandAvailabilitySourceContractTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(path),
            encoding: .utf8)
    }

    func testMenusPalettePaneChromeAndDispatchUseCanonicalAvailability() throws {
        let menu = try source("app/MarkDev/WorkspaceCommands.swift")
        let palette = try source("app/MarkDevKit/Workspace/CommandPalette.swift")
        let pane = try source("app/MarkDevKit/Workspace/PaneTabBar.swift")
        let workspace = try source("app/MarkDev/WorkspaceView.swift")

        XCTAssertTrue(menu.contains("handler?.availability.allows(action) != true"))
        XCTAssertTrue(palette.contains("commands.filter { availability.allows($0.kind) }"))
        XCTAssertTrue(pane.contains("availability.allows(.closePane)"))
        XCTAssertTrue(pane.contains(".disabled(!isEnabled)"))
        XCTAssertTrue(workspace.contains("availability: commandAvailability"))
        XCTAssertTrue(workspace.contains("guard commandAvailability.allows(command.kind)"))
        XCTAssertTrue(workspace.contains("guard commandAvailability.allows(action)"))
    }
}
