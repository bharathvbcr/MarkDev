//
//  VaultGraph.swift
//  MarkDevKit
//
//  The link graph as the Rust core hands it over.
//

import Foundation

/// One note in the graph, already placed.
///
/// The coordinates arrive laid out. Swift never runs the force simulation:
/// that is an inner loop over every pair of nodes, and running it on the main
/// actor to draw a frame is how a graph view becomes the reason an app feels
/// slow.
public struct VaultGraphNode: Codable, Identifiable, Sendable, Hashable {
    /// Vault-relative path, and the identity used to open the note.
    public let path: String
    public let title: String
    public let tags: [String]
    /// Links in plus links out, so a hub can be drawn as one.
    public let degree: Int
    /// Hops from the focused note; 0 for the whole-vault view.
    public let depth: Int
    public let x: Double
    public let y: Double

    public var id: String { path }

    /// The name to draw. A note whose front matter has no title falls back to
    /// its file name, because an unlabelled dot is not worth drawing.
    public var displayName: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty else { return trimmed }
        return (path as NSString).deletingPathExtension.components(separatedBy: "/").last ?? path
    }
}

/// A resolved link, by index into ``VaultGraph/nodes``.
public struct VaultGraphEdge: Codable, Sendable, Hashable {
    public let source: Int
    public let target: Int
}

/// The laid-out graph, and what it left out.
public struct VaultGraph: Codable, Sendable, Hashable {
    public let nodes: [VaultGraphNode]
    public let edges: [VaultGraphEdge]
    /// Notes in the whole vault, however few of them are drawn.
    public let totalNotes: Int
    /// Whether a node cap, rather than the reader's own filter, decided what
    /// is missing. The two mean different things, and a graph that silently
    /// shows half a vault is worse than one that says so.
    public let truncated: Bool

    public static let empty = VaultGraph(nodes: [], edges: [], totalNotes: 0, truncated: false)

    public init(
        nodes: [VaultGraphNode], edges: [VaultGraphEdge], totalNotes: Int, truncated: Bool
    ) {
        self.nodes = nodes
        self.edges = edges
        self.totalNotes = totalNotes
        self.truncated = truncated
    }

    enum CodingKeys: String, CodingKey {
        case nodes, edges
        case totalNotes = "total_notes"
        case truncated
    }

    public var isEmpty: Bool { nodes.isEmpty }

    /// The rectangle the layout occupies, in the core's own coordinates.
    ///
    /// Computed rather than assumed to be the core's canvas: a graph of two
    /// notes fills a fraction of it, and scaling to the canvas instead of to
    /// the content would draw them as two specks in the middle.
    public var bounds: CGRect {
        guard let first = nodes.first else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        var minX = first.x, maxX = first.x
        var minY = first.y, maxY = first.y
        for node in nodes.dropFirst() {
            minX = min(minX, node.x)
            maxX = max(maxX, node.x)
            minY = min(minY, node.y)
            maxY = max(maxY, node.y)
        }
        // A single node, or a perfectly vertical chain, has zero extent on an
        // axis. Left as zero it would divide the scale by nothing.
        return CGRect(
            x: minX, y: minY,
            width: max(maxX - minX, 1), height: max(maxY - minY, 1))
    }

    /// The transform that fits the graph into `size`, leaving room for labels.
    ///
    /// One scale for both axes: scaling each independently would stretch a
    /// chain of notes into a line across the panel, which reads as a bug
    /// rather than as a chain.
    public func fit(in size: CGSize, inset: CGFloat = 44) -> (scale: CGFloat, offset: CGPoint) {
        let box = bounds
        let usable = CGSize(
            width: max(size.width - inset * 2, 1),
            height: max(size.height - inset * 2, 1))
        let scale = min(usable.width / box.width, usable.height / box.height)
        let offset = CGPoint(
            x: (size.width - box.width * scale) / 2 - box.minX * scale,
            y: (size.height - box.height * scale) / 2 - box.minY * scale)
        return (scale, offset)
    }

    /// Where `node` lands in a view of `size`.
    public func point(for node: VaultGraphNode, in size: CGSize, inset: CGFloat = 44) -> CGPoint {
        let (scale, offset) = fit(in: size, inset: inset)
        return CGPoint(x: node.x * scale + offset.x, y: node.y * scale + offset.y)
    }

    /// The node nearest `point`, within `radius`.
    ///
    /// Distance-limited so clicking empty canvas clears the selection instead
    /// of snapping to whichever node happens to be least far away.
    public func node(nearest point: CGPoint, in size: CGSize, radius: CGFloat = 28)
        -> VaultGraphNode?
    {
        var best: (node: VaultGraphNode, distance: CGFloat)?
        for node in nodes {
            let position = self.point(for: node, in: size)
            let distance: CGFloat = hypot(position.x - point.x, position.y - point.y)
            if distance <= radius, best == nil || distance < best!.distance {
                best = (node: node, distance: distance)
            }
        }
        return best?.node
    }
}
