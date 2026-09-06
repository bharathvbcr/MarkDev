//
//  WorkspaceChromeLayout.swift
//  MarkDevKit
//
//  Pure width allocation for the sidebar, editor columns, and inspector.
//

import CoreGraphics
import Foundation

/// Which optional panel keeps its place when only one fits beside the editor.
public enum WorkspaceNarrowPanelPreference: Equatable, Sendable {
    case sidebar
    case inspector
}

/// Resolved chrome widths for one window width and split layout.
///
/// The editor columns always keep ``GlassTheme.minimumEditorPaneWidth`` each.
/// Optional panels shrink to their minima before either collapses, and when
/// only one panel fits the ``preferredNarrowPanel`` choice decides which.
public struct WorkspaceChromeLayout: Equatable, Sendable {
    public let showsSidebar: Bool
    public let showsInspector: Bool
    public let sidebarWidth: CGFloat
    public let inspectorWidth: CGFloat
    /// Combined width available to every editor column (split dividers sit inside).
    public let editorWidth: CGFloat

    public init(
        availableWidth: CGFloat,
        layout: SplitLayout,
        wantsSidebar: Bool,
        wantsInspector: Bool,
        preferredNarrowPanel: WorkspaceNarrowPanelPreference,
        sidebarWidth preferredSidebar: CGFloat,
        inspectorWidth preferredInspector: CGFloat
    ) {
        let editorColumns = max(1, Self.horizontalPaneCount(in: layout.root))
        let editorMinimum = CGFloat(editorColumns) * GlassTheme.minimumEditorPaneWidth

        let sidebarPreferred = GlassTheme.sidebar.clamping(preferredSidebar)
        let inspectorPreferred = GlassTheme.inspector.clamping(preferredInspector)

        guard availableWidth.isFinite, availableWidth > 0 else {
            // Invalid widths keep both wanted panels at clamped preferences —
            // inventing a compact collapse from NaN would hide a real bug.
            showsSidebar = wantsSidebar
            showsInspector = wantsInspector
            sidebarWidth = wantsSidebar ? sidebarPreferred : 0
            inspectorWidth = wantsInspector ? inspectorPreferred : 0
            editorWidth = editorMinimum
            return
        }

        let width = availableWidth

        let bothCost =
            GlassTheme.sidebar.minimum
            + GlassTheme.inspector.minimum
            + editorMinimum
            + 2 * GlassTheme.dividerHitWidth
        let sidebarOnlyCost =
            sidebarPreferred + editorMinimum + GlassTheme.dividerHitWidth
        let inspectorOnlyCost =
            GlassTheme.inspector.minimum + editorMinimum + GlassTheme.dividerHitWidth

        if wantsSidebar, wantsInspector, width >= bothCost {
            let preferredCost =
                sidebarPreferred + inspectorPreferred + editorMinimum
                + 2 * GlassTheme.dividerHitWidth
            let sidebar: CGFloat
            let inspector: CGFloat
            if width >= preferredCost {
                sidebar = sidebarPreferred
                inspector = inspectorPreferred
            } else {
                // Preferences do not fit beside the editor floor — keep both
                // panels at their minima and give every leftover point to the
                // editor columns (including horizontal-split slack).
                sidebar = GlassTheme.sidebar.minimum
                inspector = GlassTheme.inspector.minimum
            }
            let used = sidebar + inspector + 2 * GlassTheme.dividerHitWidth
            showsSidebar = true
            showsInspector = true
            sidebarWidth = sidebar
            inspectorWidth = inspector
            editorWidth = max(editorMinimum, width - used)
            return
        }

        if wantsSidebar, wantsInspector {
            // Only one panel fits (or neither). Honour the narrow preference.
            switch preferredNarrowPanel {
            case .sidebar:
                if width >= sidebarOnlyCost {
                    showsSidebar = true
                    showsInspector = false
                    sidebarWidth = sidebarPreferred
                    inspectorWidth = 0
                    editorWidth = max(
                        editorMinimum,
                        width - sidebarPreferred - GlassTheme.dividerHitWidth)
                    return
                }
                if width >= inspectorOnlyCost {
                    let inspector = min(
                        inspectorPreferred,
                        width - editorMinimum - GlassTheme.dividerHitWidth)
                    showsSidebar = false
                    showsInspector = true
                    sidebarWidth = 0
                    inspectorWidth = GlassTheme.inspector.clamping(inspector)
                    editorWidth = max(
                        editorMinimum,
                        width - inspectorWidth - GlassTheme.dividerHitWidth)
                    return
                }
            case .inspector:
                let inspectorFit = width - editorMinimum - GlassTheme.dividerHitWidth
                if inspectorFit >= GlassTheme.inspector.minimum {
                    let inspector = min(inspectorPreferred, inspectorFit)
                    showsSidebar = false
                    showsInspector = true
                    sidebarWidth = 0
                    inspectorWidth = GlassTheme.inspector.clamping(inspector)
                    editorWidth = max(
                        editorMinimum,
                        width - inspectorWidth - GlassTheme.dividerHitWidth)
                    return
                }
                if width >= sidebarOnlyCost {
                    showsSidebar = true
                    showsInspector = false
                    sidebarWidth = sidebarPreferred
                    inspectorWidth = 0
                    editorWidth = max(
                        editorMinimum,
                        width - sidebarPreferred - GlassTheme.dividerHitWidth)
                    return
                }
            }
            showsSidebar = false
            showsInspector = false
            sidebarWidth = 0
            inspectorWidth = 0
            editorWidth = width
            return
        }

        if wantsSidebar {
            if width >= GlassTheme.sidebar.minimum + editorMinimum + GlassTheme.dividerHitWidth {
                let sidebar = min(
                    sidebarPreferred,
                    width - editorMinimum - GlassTheme.dividerHitWidth)
                showsSidebar = true
                showsInspector = false
                sidebarWidth = GlassTheme.sidebar.clamping(sidebar)
                inspectorWidth = 0
                editorWidth = max(
                    editorMinimum,
                    width - sidebarWidth - GlassTheme.dividerHitWidth)
                return
            }
        }

        if wantsInspector {
            if width >= GlassTheme.inspector.minimum + editorMinimum + GlassTheme.dividerHitWidth {
                let inspector = min(
                    inspectorPreferred,
                    width - editorMinimum - GlassTheme.dividerHitWidth)
                showsSidebar = false
                showsInspector = true
                sidebarWidth = 0
                inspectorWidth = GlassTheme.inspector.clamping(inspector)
                editorWidth = max(
                    editorMinimum,
                    width - inspectorWidth - GlassTheme.dividerHitWidth)
                return
            }
        }

        showsSidebar = false
        showsInspector = false
        sidebarWidth = 0
        inspectorWidth = 0
        editorWidth = width
    }

    private static func horizontalPaneCount(in node: SplitNode) -> Int {
        switch node {
        case .leaf:
            return 1
        case .split(let group):
            let childWidths = group.children.map { horizontalPaneCount(in: $0) }
            switch group.axis {
            case .horizontal:
                return childWidths.reduce(0, +)
            case .vertical:
                return childWidths.max() ?? 1
            }
        }
    }
}
