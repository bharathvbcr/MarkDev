//
//  ResizeHandle.swift
//  MarkDevKit
//
//  The draggable seam between two resizable regions.
//

import AppKit
import SwiftUI

/// A hairline divider that can be dragged to resize what sits either side of
/// it, and double-clicked to restore a default.
///
/// One implementation serves both seams in the window — the dividers inside a
/// split tree and the edges of the navigator and inspector. They are the same
/// gesture with the same affordances (hit slop, resize cursor, double-click
/// reset), and a second copy would drift: the first version of this lived
/// privately inside `SplitTreeView`, so the side panels shipped with no way to
/// resize them at all even though the width limits for it already existed.
///
/// The handle reports *incremental* translation and owns no geometry. Whoever
/// draws it decides what a point of drag means and clamps the result — see
/// ``SplitLayout`` and ``PanelSizeRange``.
public struct ResizeHandle: View {
    /// The axis the two regions are laid out along, not the axis of the line:
    /// a `.horizontal` arrangement gets a vertical divider dragged sideways.
    public let axis: SplitAxis
    /// Called with the drag distance since the previous callback, in points.
    public let onDrag: (CGFloat) -> Void
    /// Called on double-click, to restore the default division.
    public let onReset: () -> Void
    /// Spoken description of what this handle separates.
    public let label: String

    @State private var isHovering = false
    @State private var lastTranslation: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        axis: SplitAxis,
        label: String,
        onDrag: @escaping (CGFloat) -> Void,
        onReset: @escaping () -> Void
    ) {
        self.axis = axis
        self.label = label
        self.onDrag = onDrag
        self.onReset = onReset
    }

    public var body: some View {
        // The visible line is hairline; the hit area is much wider, or the
        // divider would be nearly impossible to grab.
        Rectangle()
            .fill(Color.primary.opacity(isHovering ? 0.28 : 0.10))
            .frame(
                width: axis == .horizontal ? GlassTheme.dividerLineWidth : nil,
                height: axis == .vertical ? GlassTheme.dividerLineWidth : nil
            )
            .frame(
                width: axis == .horizontal ? GlassTheme.dividerHitWidth : nil,
                height: axis == .vertical ? GlassTheme.dividerHitWidth : nil
            )
            .contentShape(Rectangle())
            // The pointer is the only affordance a hairline divider has.
            // Push and pop are paired through `isHovering` so a repeated enter
            // cannot stack two cursors on AppKit's stack, and a repeated exit
            // cannot pop one belonging to somebody else.
            .onHover { hovering in
                hovering ? pushCursor() : popCursor()
            }
            // A view removed while the pointer is still over it never receives
            // the exit callback, and the pushed resize cursor would outlive
            // the divider — leaving the whole window stuck showing it. Closing
            // a pane does exactly that to the divider beside it.
            .onDisappear(perform: popCursor)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let current =
                            axis == .horizontal
                            ? value.translation.width : value.translation.height
                        // Drag reports cumulative translation; callers want the
                        // increment since the last callback.
                        onDrag(current - lastTranslation)
                        lastTranslation = current
                    }
                    .onEnded { _ in lastTranslation = 0 }
            )
            .onTapGesture(count: 2, perform: onReset)
            .animation(
                GlassTheme.motion(GlassTheme.quickSpring, reduceMotion: reduceMotion),
                value: isHovering)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityHint("Drag to resize. Double-tap to reset.")
    }

    private func pushCursor() {
        guard !isHovering else { return }
        isHovering = true
        axis == .horizontal ? NSCursor.resizeLeftRight.push() : NSCursor.resizeUpDown.push()
    }

    private func popCursor() {
        guard isHovering else { return }
        isHovering = false
        NSCursor.pop()
    }
}
