//
//  WorkspaceUIHardeningTests.swift
//  MarkDevKitTests
//
//  Behavioral regressions for transient focus, compact chrome, and keyboard
//  accessibility. App-target-only SwiftUI wiring is pinned separately below.
//

import AppKit
import XCTest

@testable import MarkDevKit

@MainActor
final class WindowFocusRestorerTests: XCTestCase {
    private final class FocusView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    func testRestoresTheExactNavigatorOrTerminalResponder() {
        let window = makeWindow()
        let original = FocusView(frame: NSRect(x: 0, y: 0, width: 120, height: 40))
        let presentation = FocusView(frame: NSRect(x: 0, y: 50, width: 120, height: 40))
        window.contentView?.addSubview(original)
        window.contentView?.addSubview(presentation)
        XCTAssertTrue(window.makeFirstResponder(original))

        let pane = PaneID()
        let restorer = WindowFocusRestorer()
        restorer.capture(in: window, fallbackPane: pane)
        XCTAssertTrue(window.makeFirstResponder(presentation))

        var fallbackPane: PaneID?
        XCTAssertEqual(
            restorer.restore(in: window) { fallbackPane = $0 },
            .restoredOriginalResponder)
        XCTAssertTrue(window.firstResponder === original)
        XCTAssertNil(fallbackPane)
    }

    func testDetachedResponderFallsBackToTheCapturedPaneExactlyOnce() {
        let window = makeWindow()
        let original = FocusView(frame: NSRect(x: 0, y: 0, width: 120, height: 40))
        window.contentView?.addSubview(original)
        XCTAssertTrue(window.makeFirstResponder(original))

        let pane = PaneID()
        let restorer = WindowFocusRestorer()
        restorer.capture(in: window, fallbackPane: pane)
        original.removeFromSuperview()

        var fallbacks: [PaneID?] = []
        XCTAssertEqual(
            restorer.restore(in: window) { fallbacks.append($0) },
            .restoredFallback)
        XCTAssertEqual(fallbacks, [pane])
        XCTAssertEqual(
            restorer.restore(in: window) { fallbacks.append($0) },
            .nothingCaptured)
        XCTAssertEqual(fallbacks, [pane], "a consumed restoration must never fire twice")
    }

    func testNeverInstallsAResponderIntoAnotherWindow() {
        let originalWindow = makeWindow()
        let replacementWindow = makeWindow()
        let original = FocusView(frame: NSRect(x: 0, y: 0, width: 120, height: 40))
        originalWindow.contentView?.addSubview(original)
        XCTAssertTrue(originalWindow.makeFirstResponder(original))

        let pane = PaneID()
        let restorer = WindowFocusRestorer()
        restorer.capture(in: originalWindow, fallbackPane: pane)

        var fallbackPane: PaneID?
        XCTAssertEqual(
            restorer.restore(in: replacementWindow) { fallbackPane = $0 },
            .restoredFallback)
        XCTAssertEqual(fallbackPane, pane)
        XCTAssertFalse(replacementWindow.firstResponder === original)
    }

    func testClearReleasesTheCaptureWithoutCallingFallback() {
        let window = makeWindow()
        let original = FocusView(frame: NSRect(x: 0, y: 0, width: 120, height: 40))
        window.contentView?.addSubview(original)
        XCTAssertTrue(window.makeFirstResponder(original))

        let restorer = WindowFocusRestorer()
        restorer.capture(in: window, fallbackPane: PaneID())
        restorer.clear()

        var fallbackWasCalled = false
        XCTAssertEqual(
            restorer.restore(in: window) { _ in fallbackWasCalled = true },
            .nothingCaptured)
        XCTAssertFalse(fallbackWasCalled)
    }

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
    }
}

final class WorkspaceChromeLayoutTests: XCTestCase {
    private let onePane = SplitLayout(pane: PaneID())

    func testNarrowWindowPreservesAnEditorBeforeOptionalPanels() {
        let layout = WorkspaceChromeLayout(
            availableWidth: 360,
            layout: onePane,
            wantsSidebar: true,
            wantsInspector: true,
            preferredNarrowPanel: .sidebar,
            sidebarWidth: 260,
            inspectorWidth: 300)

        XCTAssertFalse(layout.showsSidebar)
        XCTAssertFalse(layout.showsInspector)
        XCTAssertGreaterThanOrEqual(layout.editorWidth, GlassTheme.minimumEditorPaneWidth)
    }

    func testOnePanelSurvivesAtLaptopConstrainedWidthAndPriorityCanSwapIt() {
        let sidebarFirst = WorkspaceChromeLayout(
            availableWidth: 540,
            layout: onePane,
            wantsSidebar: true,
            wantsInspector: true,
            preferredNarrowPanel: .sidebar,
            sidebarWidth: 260,
            inspectorWidth: 300)
        XCTAssertTrue(sidebarFirst.showsSidebar)
        XCTAssertFalse(sidebarFirst.showsInspector)
        XCTAssertEqual(sidebarFirst.sidebarWidth, 260)
        XCTAssertGreaterThanOrEqual(sidebarFirst.editorWidth, GlassTheme.minimumEditorPaneWidth)

        let inspectorFirst = WorkspaceChromeLayout(
            availableWidth: 540,
            layout: onePane,
            wantsSidebar: true,
            wantsInspector: true,
            preferredNarrowPanel: .inspector,
            sidebarWidth: 260,
            inspectorWidth: 300)
        XCTAssertFalse(inspectorFirst.showsSidebar)
        XCTAssertTrue(inspectorFirst.showsInspector)
        XCTAssertEqual(inspectorFirst.inspectorWidth, 270)
        XCTAssertGreaterThanOrEqual(inspectorFirst.editorWidth, GlassTheme.minimumEditorPaneWidth)
    }

    func testBothPanelsShrinkToTheirMinimaBeforeEitherCollapses() {
        let exact = WorkspaceChromeLayout(
            availableWidth: 680,
            layout: onePane,
            wantsSidebar: true,
            wantsInspector: true,
            preferredNarrowPanel: .sidebar,
            sidebarWidth: 420,
            inspectorWidth: 460)

        XCTAssertTrue(exact.showsSidebar)
        XCTAssertTrue(exact.showsInspector)
        XCTAssertEqual(exact.sidebarWidth, GlassTheme.sidebar.minimum)
        XCTAssertEqual(exact.inspectorWidth, GlassTheme.inspector.minimum)
        XCTAssertEqual(exact.editorWidth, GlassTheme.minimumEditorPaneWidth)
    }

    func testHorizontalSplitsReserveEveryEditorColumn() {
        let second = PaneID()
        let horizontal = SplitLayout(
            root: .split(
                SplitNodeGroup(
                    axis: .horizontal,
                    children: [.leaf(onePane.panes[0]), .leaf(second)],
                    fractions: [0.5, 0.5])))
        let layout = WorkspaceChromeLayout(
            availableWidth: 950,
            layout: horizontal,
            wantsSidebar: true,
            wantsInspector: true,
            preferredNarrowPanel: .sidebar,
            sidebarWidth: 260,
            inspectorWidth: 300)

        XCTAssertTrue(layout.showsSidebar)
        XCTAssertTrue(layout.showsInspector)
        XCTAssertEqual(layout.sidebarWidth, GlassTheme.sidebar.minimum)
        XCTAssertEqual(layout.inspectorWidth, GlassTheme.inspector.minimum)
        XCTAssertEqual(layout.editorWidth, 530)
    }

    func testInvalidWidthUsesClampedPreferencesRatherThanInventingCompactState() {
        let layout = WorkspaceChromeLayout(
            availableWidth: .nan,
            layout: onePane,
            wantsSidebar: true,
            wantsInspector: true,
            preferredNarrowPanel: .sidebar,
            sidebarWidth: .infinity,
            inspectorWidth: -1)

        XCTAssertTrue(layout.showsSidebar)
        XCTAssertTrue(layout.showsInspector)
        XCTAssertEqual(layout.sidebarWidth, GlassTheme.sidebar.preferred)
        XCTAssertEqual(layout.inspectorWidth, GlassTheme.inspector.minimum)
    }
}

final class WorkspacePresentationAccessibilityTests: XCTestCase {
    func testOnlyDismissibleOverlaysConsumeWindowEscape() {
        let local = URL(fileURLWithPath: "/vault/Note.md")
        XCTAssertTrue(WorkspaceTransientPresentation.commandPalette.dismissesOnEscape)
        XCTAssertTrue(WorkspaceTransientPresentation.peek(local).dismissesOnEscape)
        XCTAssertTrue(WorkspaceTransientPresentation.graph.dismissesOnEscape)
        XCTAssertFalse(WorkspaceTransientPresentation.nativePanel(UUID()).dismissesOnEscape)
        XCTAssertFalse(WorkspaceTransientPresentation.closeReview(UUID()).dismissesOnEscape)
        XCTAssertFalse(WorkspaceTransientPresentation.destructivePrompt(UUID()).dismissesOnEscape)
        XCTAssertFalse(
            WorkspaceTransientPresentation.destructiveOperation(
                id: UUID(), title: "Moving"
            ).dismissesOnEscape)
        XCTAssertFalse(WorkspaceTransientPresentation.error("Failed").dismissesOnEscape)
    }

    func testOnlyAttentionModalOverlaysHideTheWorkspaceAccessibilityTree() {
        let local = URL(fileURLWithPath: "/vault/Note.md")
        XCTAssertTrue(WorkspaceTransientPresentation.commandPalette.hidesWorkspaceAccessibility)
        XCTAssertTrue(
            WorkspaceTransientPresentation.destructiveOperation(
                id: UUID(), title: "Moving"
            ).hidesWorkspaceAccessibility)
        XCTAssertFalse(WorkspaceTransientPresentation.peek(local).hidesWorkspaceAccessibility)
        XCTAssertFalse(WorkspaceTransientPresentation.graph.hidesWorkspaceAccessibility)
        XCTAssertFalse(WorkspaceTransientPresentation.closeReview(UUID()).hidesWorkspaceAccessibility)
    }

}

/// App-target-only modifier attachment cannot be introspected from the
/// framework test bundle. Keep this contract narrowly scoped to each complete
/// view builder instead of accepting a token anywhere in a multi-thousand-line
/// source file.
final class WorkspaceUIIntegrationContractTests: XCTestCase {
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

    func testWindowOwnsEscapeInsteadOfUnfocusedGraphAndPeekViews() throws {
        let workspace = try source("app/MarkDev/WorkspaceView.swift")
        let graph = try source("app/MarkDevKit/Vault/GraphPanel.swift")
        let peek = try source("app/MarkDevKit/Render/PeekPanel.swift")

        XCTAssertTrue(workspace.contains(".onExitCommand(perform: dismissEscapeEligibleTransient)"))
        XCTAssertFalse(graph.contains(".onKeyPress(.escape)"))
        XCTAssertFalse(peek.contains(".onKeyPress(.escape)"))
    }

    func testPaletteAndDestructiveProgressAreAccessibilityModal() throws {
        let workspace = try source("app/MarkDev/WorkspaceView.swift")

        XCTAssertTrue(
            workspace.contains(
                ".accessibilityHidden(transientPresentation.hidesWorkspaceAccessibility)"))
        XCTAssertGreaterThanOrEqual(
            workspace.components(separatedBy: ".accessibilityAddTraits(.isModal)").count - 1,
            2)
    }

    func testSaveOptionsMenuHasAStableSpokenName() throws {
        let workspace = try source("app/MarkDev/WorkspaceView.swift")
        guard let start = workspace.range(of: "private var saveMenu: some View")?.lowerBound,
            let end = workspace.range(
                of: "private var inspectorToggle", range: start..<workspace.endIndex
            )?.lowerBound
        else { return XCTFail("saveMenu builder not found") }

        let saveMenu = String(workspace[start..<end])
        XCTAssertTrue(saveMenu.contains(".accessibilityLabel(\"Save options\")"))
    }

    func testNavigatorDoesNotSuppressTheNativeKeyboardFocusIndicator() throws {
        let navigator = try source("app/MarkDevKit/Navigator/NavigatorView.swift")
        XCTAssertFalse(
            navigator.contains(".focusEffectDisabled()"),
            "the focused list must retain the system focus ring used by Full Keyboard Access")
    }

    func testGraphHeaderContainsAnIntrinsicWidthFallback() throws {
        let graph = try source("app/MarkDevKit/Vault/GraphPanel.swift")
        guard let start = graph.range(of: "private var controls: some View")?.lowerBound,
            let end = graph.range(of: "private var content: some View", range: start..<graph.endIndex)?.lowerBound
        else { return XCTFail("graph controls builder not found") }

        let controls = String(graph[start..<end])
        XCTAssertTrue(controls.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(controls.contains("compactControls"))
    }
}
