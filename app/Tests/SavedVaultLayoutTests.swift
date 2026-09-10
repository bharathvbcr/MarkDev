import MarkDevKit
import XCTest

final class SavedVaultLayoutTests: XCTestCase {
    func testSidebarPriorityUsesItsMinimumBeforeFallingBackToInspector() {
        for width in [450.0, 489, 490, 500, 529, 540, 679] {
            let layout = layout(width: width, preference: .sidebar)
            XCTAssertTrue(layout.showsSidebar, "the saved-vault sidebar fits at \(width)")
            XCTAssertFalse(layout.showsInspector, "the requested sidebar has priority at \(width)")
            XCTAssertEqual(layout.sidebarWidth, min(420, width - 270))
            XCTAssertGreaterThanOrEqual(layout.editorWidth, GlassTheme.minimumEditorPaneWidth)
        }
    }

    func testSidebarRemainsTheFallbackWhenInspectorCannotFit() {
        let result = layout(width: 480, preference: .inspector)
        XCTAssertTrue(result.showsSidebar, "a 210-point sidebar fits even though the inspector does not")
        XCTAssertFalse(result.showsInspector)
        XCTAssertEqual(result.sidebarWidth, 210)
        XCTAssertEqual(result.editorWidth, GlassTheme.minimumEditorPaneWidth)
    }

    func testPanelWidthsAndEditorFloorHoldAcrossEveryNarrowWidth() {
        for width in 360...900 {
            for preference in [WorkspaceNarrowPanelPreference.sidebar, .inspector] {
                let result = layout(width: Double(width), preference: preference)
                let dividers = (result.showsSidebar ? 1 : 0) + (result.showsInspector ? 1 : 0)
                XCTAssertGreaterThanOrEqual(result.editorWidth, GlassTheme.minimumEditorPaneWidth)
                XCTAssertEqual(
                    result.editorWidth + result.sidebarWidth + result.inspectorWidth
                        + Double(dividers) * GlassTheme.dividerHitWidth,
                    Double(width))
                if result.showsSidebar {
                    XCTAssertTrue((GlassTheme.sidebar.minimum...GlassTheme.sidebar.maximum).contains(result.sidebarWidth))
                }
                if result.showsInspector {
                    XCTAssertTrue((GlassTheme.inspector.minimum...GlassTheme.inspector.maximum).contains(result.inspectorWidth))
                }
            }
        }
    }

    private func layout(
        width: Double, preference: WorkspaceNarrowPanelPreference
    ) -> WorkspaceChromeLayout {
        WorkspaceChromeLayout(
            availableWidth: width,
            layout: SplitLayout(pane: PaneID()),
            wantsSidebar: true,
            wantsInspector: true,
            preferredNarrowPanel: preference,
            sidebarWidth: 420,
            inspectorWidth: 460)
    }
}
