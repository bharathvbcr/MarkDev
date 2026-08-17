//
//  SplitTreeView.swift
//  MarkDevKit
//
//  Renders a SplitLayout with draggable dividers.
//

import SwiftUI

/// Displays the pane tree, with a draggable divider between every pair.
///
/// All geometry rules live in ``SplitLayout``; this view only converts drag
/// distances into fractions and asks the model to apply them. Keeping the
/// clamping out of here is what makes "a pane can never be dragged to zero"
/// a tested property rather than a hope.
public struct SplitTreeView<PaneContent: View>: View {
    @Binding public var layout: SplitLayout
    private let content: (PaneID) -> PaneContent

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        layout: Binding<SplitLayout>,
        @ViewBuilder content: @escaping (PaneID) -> PaneContent
    ) {
        self._layout = layout
        self.content = content
    }

    public var body: some View {
        node(layout.root)
            // Structural changes animate; divider drags do not. Keying the
            // animation on the pane *count* is what separates them: a drag
            // rewrites fractions without adding or removing a pane, and
            // animating those would put a spring between the pointer and the
            // divider — the one place in the window that must feel direct.
            .animation(
                GlassTheme.motion(GlassTheme.spring, reduceMotion: reduceMotion),
                value: layout.paneCount)
    }

    @ViewBuilder
    private func node(_ node: SplitNode) -> some View {
        switch node {
        case .leaf(let pane):
            content(pane)
        case .split(let group):
            group_(group)
        }
    }

    @ViewBuilder
    private func group_(_ group: SplitNodeGroup) -> some View {
        GeometryReader { proxy in
            let total = group.axis == .horizontal ? proxy.size.width : proxy.size.height
            // Dividers occupy real space, so the panes share what is left.
            // Forgetting this is what makes nested splits drift by a few
            // points per level.
            let dividerTotal = GlassTheme.dividerHitWidth * CGFloat(group.children.count - 1)
            let available = max(total - dividerTotal, 0)

            stack(axis: group.axis) {
                // Keyed by node identity, never by position — see
                // ``SplitNode/id``. It is also what lets SwiftUI tell an
                // arriving pane from a shifted one, so only the new pane
                // plays the insertion transition.
                ForEach(children(of: group)) { child in
                    let index = child.index
                    AnyView(node(child.node))
                        .frame(
                            width: group.axis == .horizontal
                                ? available * CGFloat(group.fractions[index]) : nil,
                            height: group.axis == .vertical
                                ? available * CGFloat(group.fractions[index]) : nil
                        )
                        .transition(paneTransition)

                    if index < group.children.count - 1 {
                        ResizeHandle(
                            axis: group.axis,
                            label: group.axis == .horizontal
                                ? "Vertical split divider" : "Horizontal split divider"
                        ) { translation in
                            guard available > 0 else { return }
                            layout.resize(
                                split: group.id,
                                dividerAfter: index,
                                by: Double(translation / available))
                        } onReset: {
                            let even = Array(
                                repeating: 1.0 / Double(group.children.count),
                                count: group.children.count)
                            layout.setFractions(split: group.id, to: even)
                        }
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    @ViewBuilder
    private func stack<Content: View>(
        axis: SplitAxis, @ViewBuilder content: () -> Content
    ) -> some View {
        switch axis {
        case .horizontal: HStack(spacing: 0, content: content)
        case .vertical: VStack(spacing: 0, content: content)
        }
    }

    /// A child paired with the position its fraction and divider are held at.
    private struct PositionedChild: Identifiable {
        let index: Int
        let node: SplitNode
        var id: UUID { node.id }
    }

    private func children(of group: SplitNodeGroup) -> [PositionedChild] {
        group.children.enumerated().map { PositionedChild(index: $0.offset, node: $0.element) }
    }

    /// A pane grows out of, and shrinks back into, the space it occupies.
    ///
    /// Asymmetric because the two events read differently: a new pane should
    /// announce itself, while a closing one should get out of the way before
    /// its neighbours expand, rather than being visibly squeezed.
    private var paneTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .scale(scale: 0.92).combined(with: .opacity),
                removal: .opacity)
    }
}
