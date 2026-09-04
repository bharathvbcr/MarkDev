//
//  MermaidSubgraphPack.swift
//  MarkDevKit
//
//  ELK's layered algorithm puts disconnected subgraphs in one rank, which
//  is the axis *across* the flowchart's direction. A `flowchart LR` README
//  map with three sibling groups and no edges between them therefore arrives
//  as a column. GitHub's mermaid places those groups along the declared
//  direction; this restacks the already-laid-out groups to match, without
//  inventing edges the picture would then have to draw.
//

import BeautifulMermaid
import Foundation

enum MermaidSubgraphPack {
    /// ELK's `elk.spacing.nodeNode` for flowcharts with subgraphs.
    private static let spacing: Double = 28

    /// Moves disconnected top-level subgraphs onto the flowchart's primary
    /// axis. Diagrams ELK already laid out along that axis, or that have
    /// edges between groups, are returned unchanged.
    static func applied(to graph: PositionedGraph) -> PositionedGraph {
        guard graph.diagram.type == .flowchart,
            case .flowchart(let model) = graph.diagram.typedPayload,
            model.direction == .LR || model.direction == .RL,
            case .flowchart(var nodes, var edges, let groups) = graph.content,
            groups.count >= 2,
            groups.count == model.subgraphs.count
        else { return graph }

        let claimed = Set(model.subgraphs.flatMap { nodeIDs(in: $0) })
        let allIDs = Set(model.nodesInOrder.map(\.id))
        guard !allIDs.isEmpty, allIDs.isSubset(of: claimed) else { return graph }

        for edge in model.edges {
            let sourceGroup = topLevelGroupID(for: edge.source, in: model.subgraphs)
            let targetGroup = topLevelGroupID(for: edge.target, in: model.subgraphs)
            // A cross-group edge is why ELK placed the groups; moving them
            // would leave the edge pointing at the old coordinates.
            guard let sourceGroup, let targetGroup, sourceGroup == targetGroup else {
                return graph
            }
        }

        let xSpan = (groups.map(\.x).max() ?? 0) - (groups.map(\.x).min() ?? 0)
        let ySpan = (groups.map(\.y).max() ?? 0) - (groups.map(\.y).min() ?? 0)
        // Already a row: packing again would be a no-op at best and a
        // shuffle at worst.
        guard ySpan > xSpan else { return graph }

        let byID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        let subgraphs =
            model.direction == .RL
            ? Array(model.subgraphs.reversed())
            : model.subgraphs
        var ordered: [PositionedGroup] = []
        ordered.reserveCapacity(groups.count)
        for subgraph in subgraphs {
            guard let group = byID[subgraph.id] else { return graph }
            ordered.append(group)
        }

        let originX = ordered.map(\.x).min() ?? 0
        let originY = ordered.map(\.y).min() ?? 0
        var cursor = originX
        let idsByGroup = Dictionary(
            uniqueKeysWithValues: model.subgraphs.map { ($0.id, nodeIDs(in: $0)) })

        for index in ordered.indices {
            let dx = cursor - ordered[index].x
            let dy = originY - ordered[index].y
            if dx != 0 || dy != 0 {
                translate(
                    &ordered[index], nodes: &nodes, edges: &edges,
                    nodeIDs: idsByGroup[ordered[index].id] ?? [],
                    dx: dx, dy: dy)
            }
            cursor += ordered[index].width + spacing
        }

        var packed = graph
        packed.content = .flowchart(nodes: nodes, edges: edges, groups: ordered)
        packed.width = boundingWidth(groups: ordered, nodes: nodes, padding: originX)
        packed.height = boundingHeight(groups: ordered, nodes: nodes, padding: originY)
        return packed
    }

    private static func boundingWidth(
        groups: [PositionedGroup], nodes: [PositionedNode], padding: Double
    ) -> Double {
        let groupMax = groups.map { $0.x + $0.width }.max() ?? 0
        let nodeMax = nodes.map { $0.x + $0.width }.max() ?? 0
        return max(groupMax, nodeMax) + max(padding, 0)
    }

    private static func boundingHeight(
        groups: [PositionedGroup], nodes: [PositionedNode], padding: Double
    ) -> Double {
        let groupMax = groups.map { $0.y + $0.height }.max() ?? 0
        let nodeMax = nodes.map { $0.y + $0.height }.max() ?? 0
        return max(groupMax, nodeMax) + max(padding, 0)
    }

    private static func translate(
        _ group: inout PositionedGroup,
        nodes: inout [PositionedNode],
        edges: inout [PositionedEdge],
        nodeIDs: Set<String>,
        dx: Double,
        dy: Double
    ) {
        translateGroup(&group, dx: dx, dy: dy)
        for index in nodes.indices where nodeIDs.contains(nodes[index].id) {
            nodes[index].x += dx
            nodes[index].y += dy
        }
        for index in edges.indices {
            guard nodeIDs.contains(edges[index].source),
                nodeIDs.contains(edges[index].target)
            else { continue }
            for point in edges[index].points.indices {
                edges[index].points[point].x += dx
                edges[index].points[point].y += dy
            }
            if var label = edges[index].labelPosition {
                label.x += dx
                label.y += dy
                edges[index].labelPosition = label
            }
        }
    }

    private static func translateGroup(_ group: inout PositionedGroup, dx: Double, dy: Double) {
        group.x += dx
        group.y += dy
        for index in group.children.indices {
            translateGroup(&group.children[index], dx: dx, dy: dy)
        }
    }

    private static func topLevelGroupID(
        for nodeID: String, in subgraphs: [original_src_types.MermaidSubgraph]
    ) -> String? {
        for subgraph in subgraphs where owns(subgraph, nodeID) {
            return subgraph.id
        }
        return nil
    }

    private static func owns(_ subgraph: original_src_types.MermaidSubgraph, _ nodeID: String)
        -> Bool
    {
        subgraph.nodeIds.contains(nodeID) || subgraph.children.contains { owns($0, nodeID) }
    }

    private static func nodeIDs(in subgraph: original_src_types.MermaidSubgraph) -> Set<String> {
        var ids = Set(subgraph.nodeIds)
        for child in subgraph.children {
            ids.formUnion(nodeIDs(in: child))
        }
        return ids
    }
}
