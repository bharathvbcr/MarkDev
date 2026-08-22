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
    @State private var isDragging = false
    @State private var lastTranslation: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Whether the seam should show itself. Dragging counts on its own: the
    /// pointer routinely leaves the 10pt band mid-drag, and a divider that
    /// dims the moment it does looks like the grab was lost.
    private var isActive: Bool { isHovering || isDragging }

    /// Thickness of the drawn line. A hairline at rest so the window reads as
    /// panels rather than a grid; thicker under the pointer, which is the only
    /// feedback saying the 1pt line is a 10pt target.
    private var lineWidth: CGFloat {
        isActive ? GlassTheme.dividerActiveLineWidth : GlassTheme.dividerLineWidth
    }

    private var lineColor: Color {
        if isDragging { return .accentColor.opacity(0.85) }
        return isHovering ? .accentColor.opacity(0.55) : .primary.opacity(0.10)
    }

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
        Capsule()
            .fill(lineColor)
            .frame(
                width: axis == .horizontal ? lineWidth : nil,
                height: axis == .vertical ? lineWidth : nil
            )
            // A short grip at the midpoint, so the seam is legible as a
            // control at a glance instead of only once the pointer finds it.
            .overlay {
                Capsule()
                    .fill(Color.primary.opacity(isActive ? 0.40 : 0))
                    .frame(
                        width: axis == .horizontal
                            ? GlassTheme.dividerGripThickness : GlassTheme.dividerGripLength,
                        height: axis == .vertical
                            ? GlassTheme.dividerGripThickness : GlassTheme.dividerGripLength
                    )
            }
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
                        isDragging = true
                        let current =
                            axis == .horizontal
                            ? value.translation.width : value.translation.height
                        // Drag reports cumulative translation; callers want the
                        // increment since the last callback.
                        onDrag(current - lastTranslation)
                        lastTranslation = current
                    }
                    .onEnded { _ in
                        isDragging = false
                        lastTranslation = 0
                    }
            )
            .onTapGesture(count: 2) {
                withAnimation(
                    GlassTheme.motion(GlassTheme.spring, reduceMotion: reduceMotion)
                ) {
                    onReset()
                }
            }
            .animation(
                GlassTheme.motion(GlassTheme.quickSpring, reduceMotion: reduceMotion),
                value: isActive)
            // Nothing about a hairline says it can be double-clicked, so the
            // reset was reachable only by accident. The tooltip is the one
            // place a pointer user can be told.
            .help("\(label) — drag to resize, double-click to reset")
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityHint("Drag to resize. Double-tap to reset.")
            // Adjustable, not just labelled: a divider a screen reader can
            // describe but not move is a wall with a sign on it. The step is
            // coarse because VoiceOver adjustments repeat while held.
            .accessibilityAdjustableAction { direction in
                let step: CGFloat = 24
                switch direction {
                case .increment: onDrag(step)
                case .decrement: onDrag(-step)
                @unknown default: break
                }
            }
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
