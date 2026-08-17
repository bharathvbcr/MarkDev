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

    /// The padding lives inside each button's label rather than around the
    /// group, so every point of the capsule belongs to the control under it.
    /// Padded from the outside, these buttons answer only where their glyphs
    /// are — roughly a third of what the capsule shows — and a click that
    /// lands a couple of points off does nothing at all.
    private var paneControls: some View {
        HStack(spacing: 0) {
            paneControl("rectangle.split.2x1", help: "Split right") {
                onSplit(.trailing)
            }
            paneControl("rectangle.split.1x2", help: "Split down") {
                onSplit(.bottom)
            }
            if canClosePane {
                paneControl("xmark.rectangle", help: "Close pane", action: onClosePane)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 2)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private func paneControl(
        _ symbol: String, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .padding(.horizontal, 4)
                .padding(.vertical, 5)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
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
                        // An 8pt glyph is not a target. The padding has to be
                        // inside the label to count towards the hit region.
                        .padding(2)
                        .contentShape(.rect)
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
        // Selecting a tab must work anywhere on the chip, including the gap
        // beside a short title, not only on the glyphs the tap lands on.
        .contentShape(.capsule)
        .onHover { isHovering = $0 }
        .onTapGesture(perform: onSelect)
        .animation(
            GlassTheme.motion(GlassTheme.quickSpring, reduceMotion: reduceMotion),
            value: isHovering)
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }
}
