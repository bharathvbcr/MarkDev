//
//  ModeSwitcher.swift
//  MarkDevKit
//
//  The Live / Source / Read control, and the one place a mode is named.
//

import SwiftUI

/// How a writing mode presents itself.
///
/// One owner for a mode's name, glyph, and explanation. These used to be
/// written out separately in the toolbar picker, the command palette, and the
/// menu bar, so a mode could reach the reader under two different names and a
/// fourth mode would have to be added in three places to be reachable at all.
extension EditorMode {
    /// The short label, shown only while the mode is selected.
    public var title: String {
        switch self {
        case .livePreview: "Live"
        case .source: "Source"
        case .reading: "Read"
        }
    }

    /// The full name, for menus and the palette — rows there have room, and
    /// someone typing "reading" should find the mode.
    public var commandTitle: String {
        switch self {
        case .livePreview: "Live Preview"
        case .source: "Source Mode"
        case .reading: "Reading Mode"
        }
    }

    public var symbol: String {
        switch self {
        case .livePreview: "eye"
        case .source: "chevron.left.forwardslash.chevron.right"
        case .reading: "book"
        }
    }

    /// What the mode does. An unselected segment is a glyph and nothing else,
    /// so this is the only thing that can say what pressing it will do — it
    /// carries both the tooltip and the VoiceOver description.
    public var summary: String {
        switch self {
        case .livePreview: "Live — syntax hidden except in the block you are editing"
        case .source: "Source — every Markdown marker visible"
        case .reading: "Read — all syntax hidden, editing off"
        }
    }
}

/// The writing-mode control: a glyph per mode, with the selected one spelling
/// itself out.
///
/// A three-up segmented picker holding three words is among the widest things
/// in the toolbar, and two thirds of that width names modes the reader is not
/// in. Collapsing the others to their glyph returns the space to the tab strip
/// while keeping the state that matters — the mode you are actually in —
/// spelled out rather than left as an icon to decode.
public struct ModeSwitcher: View {
    @Binding public var mode: EditorMode

    @State private var hovered: EditorMode?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selectionPill

    public init(mode: Binding<EditorMode>) {
        self._mode = mode
    }

    public var body: some View {
        HStack(spacing: GlassTheme.Spacing.hairline) {
            ForEach(EditorMode.allCases, id: \.self, content: segment)
        }
        // Driven from the value rather than each button's action so a mode
        // set from the menu bar or the palette slides the pill too, instead
        // of snapping only when the change came from a click here.
        .animation(GlassTheme.motion(GlassTheme.spring, reduceMotion: reduceMotion), value: mode)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Writing mode")
    }

    private func segment(_ option: EditorMode) -> some View {
        let isSelected = option == mode
        return Button {
            mode = option
        } label: {
            HStack(spacing: GlassTheme.Spacing.tight) {
                Image(systemName: option.symbol)
                    .font(.caption)
                    // A fixed glyph box: the symbols differ in width, and
                    // without it the pill's travel stutters as it passes them.
                    .frame(width: 16)
                if isSelected {
                    Text(option.title)
                        .font(.caption.weight(.semibold))
                        .fixedSize()
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, isSelected ? GlassTheme.Spacing.snug : GlassTheme.Spacing.tight)
            .padding(.vertical, 4)
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .background {
                if isSelected {
                    Capsule()
                        .fill(Color.accentColor.opacity(0.32))
                        // The pill is one view moving between segments rather
                        // than three fading in and out, so the control reads
                        // as a switch being thrown.
                        .matchedGeometryEffect(id: "mode.selection", in: selectionPill)
                } else if hovered == option {
                    Capsule().fill(Color.primary.opacity(0.08))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? option : (hovered == option ? nil : hovered) }
        .animation(
            GlassTheme.motion(GlassTheme.quickSpring, reduceMotion: reduceMotion),
            value: hovered)
        .help(option.summary)
        .accessibilityLabel(option.commandTitle)
        .accessibilityHint(option.summary)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
