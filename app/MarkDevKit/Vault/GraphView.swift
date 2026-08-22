//
//  GraphView.swift
//  MarkDevKit
//
//  The vault's link structure, drawn.
//

import SwiftUI

/// A force-directed picture of the vault's links.
///
/// Drawn in a `Canvas` rather than as a stack of SwiftUI shapes: a vault of a
/// few hundred notes is a few hundred circles and a thousand lines, and one
/// view per node means one identity, one layout pass, and one diff each frame
/// for every one of them. `Canvas` is a single view that draws them all.
///
/// The layout itself arrives finished from the Rust core — see ``VaultGraph``.
public struct GraphView: View {
    public let graph: VaultGraph
    /// The note the graph is centred on, highlighted rather than filtered.
    public var current: String?
    /// Called when a node is clicked.
    public var onOpen: (String) -> Void

    @State private var hovered: String?
    @State private var selected: String?
    @Environment(\.colorScheme) private var colorScheme

    public init(
        graph: VaultGraph,
        current: String? = nil,
        onOpen: @escaping (String) -> Void
    ) {
        self.graph = graph
        self.current = current
        self.onOpen = onOpen
    }

    public var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            Canvas { context, canvasSize in
                draw(in: &context, size: canvasSize)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    hovered = graph.node(nearest: point, in: size)?.path
                case .ended:
                    hovered = nil
                }
            }
            .onTapGesture { point in
                // A click on empty canvas clears the selection rather than
                // opening whichever note is least far away.
                guard let node = graph.node(nearest: point, in: size) else {
                    selected = nil
                    return
                }
                selected = node.path
                onOpen(node.path)
            }
            .accessibilityLabel(accessibilitySummary)
            // The nodes themselves, spoken and activatable. A picture with a
            // one-line summary left every note unreachable to VoiceOver; the
            // synthetic children below are the same buttons the pointer
            // gets, ordered most-connected first so the hubs come early.
            .accessibilityChildren {
                GraphNodeAccessibility(nodes: accessibleNodes, onOpen: onOpen)
            }
        }
        .overlay(alignment: .bottomLeading) { legend }
    }

    /// The nodes exposed as accessible children, deterministically ordered.
    ///
    /// Capped: a vault at `MAX_NODES` would otherwise hand VoiceOver fifteen
    /// hundred elements it has to walk, and nobody navigates a hairball by
    /// reading all of it. The cap is stated in the summary rather than
    /// silently applied.
    private var accessibleNodes: [VaultGraphNode] {
        graph.accessibilityNodes(limit: Self.accessibilityNodeLimit)
    }

    static let accessibilityNodeLimit = 100

    private var accessibilitySummary: String {
        graph.isEmpty ? "Link graph, empty" : "Link graph: \(countSummary)"
    }

    // MARK: - Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        guard !graph.isEmpty else { return }
        let positions = graph.nodes.map { graph.point(for: $0, in: size) }
        let highlighted = hovered ?? selected ?? current
        let neighbours = neighbourhood(of: highlighted)

        // Edges first, so nodes sit on top of the lines that meet them.
        for edge in graph.edges {
            guard positions.indices.contains(edge.source),
                positions.indices.contains(edge.target)
            else { continue }

            let touchesHighlight =
                highlighted != nil
                && (graph.nodes[edge.source].path == highlighted
                    || graph.nodes[edge.target].path == highlighted)

            var path = Path()
            path.move(to: positions[edge.source])
            path.addLine(to: positions[edge.target])
            context.stroke(
                path,
                with: .color(edgeColor(highlighted: touchesHighlight, dimmed: highlighted != nil)),
                lineWidth: touchesHighlight ? 1.6 : 1)
        }

        for (index, node) in graph.nodes.enumerated() {
            let point = positions[index]
            let radius = self.radius(of: node)
            let isHighlighted = node.path == highlighted
            let isNear = neighbours.contains(node.path)
            // Dimming everything unrelated is what makes a hover legible in a
            // dense graph; without it the highlight is lost in the mesh.
            let dim = highlighted != nil && !isHighlighted && !isNear

            let circle = Path(
                ellipseIn: CGRect(
                    x: point.x - radius, y: point.y - radius,
                    width: radius * 2, height: radius * 2))
            context.fill(circle, with: .color(nodeColor(node, dimmed: dim)))
            if isHighlighted {
                context.stroke(circle, with: .color(.primary), lineWidth: 2)
            }

            // Labels only where they can be read. Drawing every name in a
            // vault of hundreds produces an unreadable wall of text, so the
            // rule is: hubs always, and whatever the reader is pointing at.
            guard isHighlighted || isNear || node.degree >= labelThreshold else { continue }
            let text = Text(node.displayName)
                .font(.system(size: 10, weight: isHighlighted ? .semibold : .regular))
                .foregroundStyle(dim ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
            context.draw(
                context.resolve(text),
                at: CGPoint(x: point.x, y: point.y + radius + 8),
                anchor: .top)
        }
    }

    /// Radius from degree, on a square-root scale.
    ///
    /// Linear scaling makes one hub swamp the picture; area proportional to
    /// degree keeps the difference readable without the largest node eating
    /// the canvas.
    private func radius(of node: VaultGraphNode) -> CGFloat {
        let base: CGFloat = 4
        return base + sqrt(CGFloat(node.degree)) * 2.4
    }

    /// The degree at which a node is named without being pointed at.
    ///
    /// Scaled to the graph: in a vault of six notes every node is a hub and
    /// every label fits, while in one of six hundred only the real hubs
    /// should be named.
    private var labelThreshold: Int {
        graph.nodes.count <= 25 ? 0 : max(3, graph.nodes.count / 40)
    }

    /// The highlighted node's immediate neighbours.
    private func neighbourhood(of path: String?) -> Set<String> {
        guard let path, let index = graph.nodes.firstIndex(where: { $0.path == path }) else {
            return []
        }
        var result: Set<String> = []
        for edge in graph.edges {
            if edge.source == index, graph.nodes.indices.contains(edge.target) {
                result.insert(graph.nodes[edge.target].path)
            } else if edge.target == index, graph.nodes.indices.contains(edge.source) {
                result.insert(graph.nodes[edge.source].path)
            }
        }
        return result
    }

    private func nodeColor(_ node: VaultGraphNode, dimmed: Bool) -> Color {
        let base: Color = node.path == current ? .accentColor : .secondary
        return base.opacity(dimmed ? 0.18 : (node.path == current ? 0.95 : 0.65))
    }

    private func edgeColor(highlighted: Bool, dimmed: Bool) -> Color {
        if highlighted { return .accentColor.opacity(0.75) }
        return .secondary.opacity(dimmed ? 0.08 : 0.22)
    }

    // MARK: - Chrome

    @ViewBuilder
    private var legend: some View {
        if graph.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(countSummary)
                if graph.truncated {
                    // Never present a capped sample as complete coverage.
                    Label(
                        "Showing the best-connected notes",
                        systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(GlassTheme.Spacing.snug)
        }
    }

    private var countSummary: String {
        let notes = graph.nodes.count == 1 ? "1 note" : "\(graph.nodes.count) notes"
        let links = graph.edges.count == 1 ? "1 link" : "\(graph.edges.count) links"
        // Both numbers, always: "40 notes" alone cannot say whether the other
        // 300 were filtered out or never drawn.
        guard graph.nodes.count < graph.totalNotes else { return "\(notes), \(links)" }
        return "\(notes) of \(graph.totalNotes), \(links)"
    }

}

/// The canvas's synthetic accessibility children.
///
/// `accessibilityChildren(viewType:)` asks for a *view type*; its body is
/// never rendered — SwiftUI lifts each element into the accessibility tree
/// under the canvas. A button per node means activation opens the note,
/// which is exactly what a click does for the pointer.
private struct GraphNodeAccessibility: View {
    let nodes: [VaultGraphNode]
    let onOpen: (String) -> Void

    var body: some View {
        ForEach(nodes) { node in
            Button {
                onOpen(node.path)
            } label: {
                // Never drawn; the labels below are what VoiceOver speaks.
                EmptyView()
            }
            .accessibilityLabel(
                "\(node.displayName), \(node.degree == 1 ? "1 link" : "\(node.degree) links")")
        }
    }
}
