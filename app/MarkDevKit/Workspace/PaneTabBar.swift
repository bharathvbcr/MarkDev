//
//  PaneTabBar.swift
//  MarkDevKit
//
//  The tab strip at the top of each pane.
//

import SwiftUI

/// Tabs for the documents open in one pane.
public struct PaneTabBar: View {
    public let state: PaneState
    public let isFocused: Bool
    public let onSelect: (OpenDocument.ID) -> Void
    public let onClose: (OpenDocument.ID) -> Void
    public let onSplit: (SplitEdge) -> Void
    public let onClosePane: () -> Void
    public let canClosePane: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glass

    public init(
        state: PaneState,
        isFocused: Bool,
        canClosePane: Bool,
        onSelect: @escaping (OpenDocument.ID) -> Void,
        onClose: @escaping (OpenDocument.ID) -> Void,
        onSplit: @escaping (SplitEdge) -> Void,
        onClosePane: @escaping () -> Void
    ) {
        self.state = state
        self.isFocused = isFocused
        self.canClosePane = canClosePane
        self.onSelect = onSelect
        self.onClose = onClose
        self.onSplit = onSplit
        self.onClosePane = onClosePane
    }

    public var body: some View {
        GlassEffectContainer(spacing: GlassTheme.Spacing.tight) {
            HStack(spacing: GlassTheme.Spacing.tight) {
                ScrollView(.horizontal) {
                    HStack(spacing: GlassTheme.Spacing.tight) {
                        ForEach(state.documents) { document in
                            TabChip(
                                document: document,
                                isCurrent: document.id == state.current?.id,
                                showClose: state.documents.count > 1,
                                reduceMotion: reduceMotion,
                                onSelect: { onSelect(document.id) },
                                onClose: { onClose(document.id) }
                            )
                            .glassEffectID(document.id, in: glass)
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .scrollIndicators(.never)

                Spacer(minLength: GlassTheme.Spacing.tight)
                paneControls
            }
        }
        .padding(.horizontal, GlassTheme.Spacing.snug)
        .padding(.vertical, GlassTheme.Spacing.tight)
        // The focused pane is brighter; without a cue, a multi-pane window
        // gives no clue where typing will land.
        .opacity(isFocused ? 1 : 0.62)
        .animation(
            GlassTheme.motion(GlassTheme.quickSpring, reduceMotion: reduceMotion),
            value: isFocused)
    }

    private var paneControls: some View {
        HStack(spacing: 2) {
            Button { onSplit(.trailing) } label: {
                Image(systemName: "rectangle.split.2x1")
            }
            .help("Split right")

            Button { onSplit(.bottom) } label: {
                Image(systemName: "rectangle.split.1x2")
            }
            .help("Split down")

            if canClosePane {
                Button(action: onClosePane) {
                    Image(systemName: "xmark.rectangle")
                }
                .help("Close pane")
            }
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, GlassTheme.Spacing.tight)
        .padding(.vertical, 5)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

/// A single tab.
private struct TabChip: View {
    let document: OpenDocument
    let isCurrent: Bool
    let showClose: Bool
    let reduceMotion: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: GlassTheme.Spacing.tight) {
            Text(document.title)
                .font(.caption)
                .lineLimit(1)

            if document.hasUnsavedChanges {
                // A dot, not a close button that turns into a dot on hover:
                // unsaved state should never be ambiguous.
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel("Unsaved changes")
            }

            if showClose, isHovering || isCurrent {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Close \(document.title)")
            }
        }
        .padding(.horizontal, GlassTheme.Spacing.snug)
        .padding(.vertical, 5)
        .glassEffect(
            isCurrent ? .regular.tint(.accentColor.opacity(0.28)).interactive() : .regular,
            in: .capsule
        )
        .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
        .onHover { isHovering = $0 }
        .onTapGesture(perform: onSelect)
        .animation(
            GlassTheme.motion(GlassTheme.quickSpring, reduceMotion: reduceMotion),
            value: isHovering)
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }
}
