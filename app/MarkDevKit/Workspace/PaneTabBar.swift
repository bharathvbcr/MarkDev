//
//  PaneTabBar.swift
//  MarkDevKit
//
//  The tab strip at the top of each pane.
//

import SwiftUI

/// How a split direction presents itself in the chrome.
///
/// The same owner-per-name rule the writing modes follow: the pane control,
/// the menu item, and the palette row all read from here, so a tooltip cannot
/// promise one thing while the menu calls it another.
extension SplitEdge {
    /// The name used in the menu bar and the palette.
    public var commandTitle: String {
        switch self {
        case .leading: "Split Left"
        case .trailing: "Split Right"
        case .top: "Split Up"
        case .bottom: "Split Down"
        }
    }

    public var symbol: String {
        switch self {
        case .leading, .trailing: "rectangle.split.2x1"
        case .top, .bottom: "rectangle.split.1x2"
        }
    }

    /// Tooltip text: what pressing the control *does*, rather than what the
    /// control is called. "Split right" beside a split-right glyph tells a
    /// first-time reader nothing the glyph did not; what they cannot guess is
    /// that the new pane arrives showing the document they are already in.
    public var controlHelp: String {
        switch self {
        case .leading: "Split left — this document opens again in a new pane to the left"
        case .trailing: "Split right — this document opens again in a new pane beside this one"
        case .top: "Split up — this document opens again in a new pane above"
        case .bottom: "Split down — this document opens again in a new pane below"
        }
    }
}

/// Tabs for the documents open in one pane.
public struct PaneTabBar: View {
    public let state: PaneState
    public let isFocused: Bool
    /// Whether the window holds more than one pane. Gates the control that
    /// only means something in a split.
    public let isSplit: Bool
    public let onSelect: (OpenDocument.ID) -> Void
    public let onClose: (OpenDocument.ID) -> Void
    public let onSplit: (SplitEdge) -> Void
    public let onClosePane: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glass

    public init(
        state: PaneState,
        isFocused: Bool,
        isSplit: Bool,
        onSelect: @escaping (OpenDocument.ID) -> Void,
        onClose: @escaping (OpenDocument.ID) -> Void,
        onSplit: @escaping (SplitEdge) -> Void,
        onClosePane: @escaping () -> Void
    ) {
        self.state = state
        self.isFocused = isFocused
        self.isSplit = isSplit
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
                            .transition(
                                reduceMotion
                                    ? .opacity
                                    : .asymmetric(
                                        insertion: .scale(scale: 0.8).combined(with: .opacity),
                                        removal: .scale(scale: 0.8).combined(with: .opacity)))
                        }
                    }
                    .padding(.horizontal, 2)
                    // Keyed on the tab identities rather than the count, so
                    // replacing the pristine tab with an opened file animates
                    // too — that swap keeps the count unchanged.
                    .animation(
                        GlassTheme.motion(GlassTheme.quickSpring, reduceMotion: reduceMotion),
                        value: state.documents.map(\.id))
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

    /// Split and close for this pane.
    ///
    /// Close appears only once there is a split: offering it beside the last
    /// pane advertises something the layout refuses to do.
    private var paneControls: some View {
        HStack(spacing: GlassTheme.Spacing.hairline) {
            ForEach([SplitEdge.trailing, .bottom], id: \.self) { edge in
                PaneControl(
                    symbol: edge.symbol,
                    label: edge.commandTitle,
                    help: edge.controlHelp,
                    reduceMotion: reduceMotion,
                    action: { onSplit(edge) })
            }

            if isSplit {
                Divider().frame(height: 12).opacity(0.4)

                PaneControl(
                    symbol: "xmark",
                    label: "Close Pane",
                    help: "Close this pane (⌃⌘W) — its tabs close with it",
                    reduceMotion: reduceMotion,
                    action: onClosePane)
            }
        }
        .padding(.horizontal, GlassTheme.Spacing.tight)
        .padding(.vertical, 3)
        .glassEffect(.regular.interactive(), in: .capsule)
        .animation(
            GlassTheme.motion(GlassTheme.quickSpring, reduceMotion: reduceMotion),
            value: isSplit)
    }
}

/// One pane control: a glyph with a real hit target under it.
///
/// The glyphs used to be bare `Image`s inside a shared capsule, which made the
/// tappable area the glyph itself — around 9pt of ink for a control sitting
/// beside a scrolling tab strip. The padding here is the target; the
/// background only appears under the pointer.
private struct PaneControl: View {
    let symbol: String
    /// The control's name, spoken by VoiceOver and matching the menu item.
    let label: String
    /// The tooltip, and the spoken hint behind the name.
    let help: String
    let reduceMotion: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption)
                .frame(width: 15, height: 15)
                .padding(4)
                .foregroundStyle(.secondary)
                .background {
                    Circle().fill(isHovering ? Color.primary.opacity(0.12) : .clear)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityHint(help)
        .onHover { isHovering = $0 }
        .animation(
            GlassTheme.motion(GlassTheme.quickSpring, reduceMotion: reduceMotion),
            value: isHovering)
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
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel("Unsaved changes")
            }

            if showClose, isHovering || isCurrent {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        // The glyph is tiny; the target around it should not
                        // be, or closing a tab becomes a game of aim.
                        .frame(width: 12, height: 12)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .transition(.scale.combined(with: .opacity))
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
        // A hovered tab lifts slightly, so a strip of similar capsules says
        // which one the pointer is actually on before it is clicked.
        .scaleEffect(isHovering && !isCurrent ? 1.04 : 1)
        .onHover { isHovering = $0 }
        .onTapGesture(perform: onSelect)
        .animation(
            GlassTheme.motion(GlassTheme.quickSpring, reduceMotion: reduceMotion),
            value: isHovering)
        .animation(
            GlassTheme.motion(GlassTheme.quickSpring, reduceMotion: reduceMotion),
            value: isCurrent)
        .animation(
            GlassTheme.motion(GlassTheme.quickSpring, reduceMotion: reduceMotion),
            value: document.hasUnsavedChanges)
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }
}
