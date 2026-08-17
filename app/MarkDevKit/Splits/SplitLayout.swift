//
//  SplitLayout.swift
//  MarkDevKit
//
//  The pane tree behind draggable splits.
//

import Foundation

/// Identifies one pane (a leaf of the split tree).
public struct PaneID: Hashable, Sendable, Identifiable {
    public let id: UUID
    public init(id: UUID = UUID()) { self.id = id }
}

/// Identifies one split node, so a divider drag can address the split it
/// belongs to without carrying a path through the view hierarchy.
public struct SplitID: Hashable, Sendable, Identifiable {
    public let id: UUID
    public init(id: UUID = UUID()) { self.id = id }
}

/// Direction a split divides in.
public enum SplitAxis: Sendable, Hashable {
    /// Children sit side by side; dividers move horizontally.
    case horizontal
    /// Children are stacked; dividers move vertically.
    case vertical
}

/// Which side of a pane a new pane is placed on.
public enum SplitEdge: Sendable, Hashable {
    case leading, trailing, top, bottom

    var axis: SplitAxis {
        switch self {
        case .leading, .trailing: .horizontal
        case .top, .bottom: .vertical
        }
    }

    /// Whether the new pane goes before the existing one.
    var insertsBefore: Bool {
        self == .leading || self == .top
    }
}

/// A node in the pane tree.
public indirect enum SplitNode: Sendable, Equatable, Identifiable {
    case leaf(PaneID)
    case split(SplitNodeGroup)

    /// Identity that survives its siblings changing.
    ///
    /// Borrowed from the pane or split the node stands for, both of which are
    /// UUID-backed, so no two nodes in a tree can collide. The renderer keys
    /// its children on this rather than on position: closing the *first* of
    /// three panes shifts every later pane's index, and a position-keyed list
    /// reads that as "every pane's contents changed" — tearing down the text
    /// views and taking each pane's scroll position and undo stack with them.
    public var id: UUID {
        switch self {
        case .leaf(let pane): pane.id
        case .split(let group): group.id.id
        }
    }

    /// Every pane beneath this node, left to right and top to bottom.
    public var panes: [PaneID] {
        switch self {
        case .leaf(let pane): [pane]
        case .split(let group): group.children.flatMap(\.panes)
        }
    }
}

/// A split with two or more children and the fractions they occupy.
public struct SplitNodeGroup: Sendable, Equatable {
    public let id: SplitID
    public var axis: SplitAxis
    public var children: [SplitNode]
    /// Fraction of the split's length each child takes. Always the same count
    /// as `children`, always summing to 1.
    public var fractions: [Double]

    public init(id: SplitID = SplitID(), axis: SplitAxis, children: [SplitNode], fractions: [Double]) {
        self.id = id
        self.axis = axis
        self.children = children
        self.fractions = fractions
    }
}

/// The arrangement of panes in a window.
///
/// A pure value type: every operation returns a normalised tree, and the
/// SwiftUI layer only reads it. Keeping the geometry rules here — rather than
/// spread through view code — is what makes "no gaps, nothing collapses to
/// zero" testable instead of something to eyeball.
public struct SplitLayout: Sendable, Equatable {
    /// Smallest fraction a pane may shrink to, so a pane can never be dragged
    /// out of existence and become unrecoverable.
    public static let minimumFraction: Double = 0.08

    public private(set) var root: SplitNode

    public init(root: SplitNode) {
        self.root = root
    }

    public init(pane: PaneID) {
        self.root = .leaf(pane)
    }

    /// Every pane, in visual order.
    public var panes: [PaneID] { root.panes }

    public var paneCount: Int { panes.count }

    // MARK: - Mutation

    /// Splits `target`, placing `newPane` on the given edge.
    ///
    /// When the target's parent already divides along the same axis, the new
    /// pane joins that split rather than nesting a second one inside it —
    /// otherwise three side-by-side panes would be represented as a split
    /// containing a split, and their dividers would behave inconsistently.
    public mutating func split(_ target: PaneID, edge: SplitEdge, with newPane: PaneID) {
        guard panes.contains(target) else { return }
        root = Self.split(root, target: target, edge: edge, newPane: newPane)
        root = Self.normalise(root)
    }

    /// Removes `pane`, collapsing any split left with a single child.
    ///
    /// Removing the last pane is refused: a window with no panes has nothing
    /// to show and no way back.
    @discardableResult
    public mutating func close(_ pane: PaneID) -> Bool {
        guard panes.count > 1, panes.contains(pane) else { return false }
        guard let pruned = Self.remove(root, pane: pane) else { return false }
        root = Self.normalise(pruned)
        return true
    }

    /// Moves the divider after `index` within the split `id`.
    ///
    /// `delta` is a fraction of the split's total length. Both neighbours are
    /// clamped to ``minimumFraction``, so dragging past the limit stops
    /// rather than collapsing a pane.
    public mutating func resize(split id: SplitID, dividerAfter index: Int, by delta: Double) {
        root = Self.resize(root, id: id, index: index, delta: delta)
    }

    /// Sets fractions directly, used when restoring a saved layout.
    public mutating func setFractions(split id: SplitID, to fractions: [Double]) {
        root = Self.setFractions(root, id: id, fractions: fractions)
    }

    // MARK: - Recursion

    private static func split(
        _ node: SplitNode, target: PaneID, edge: SplitEdge, newPane: PaneID
    ) -> SplitNode {
        switch node {
        case .leaf(let pane):
            guard pane == target else { return node }
            let children: [SplitNode] =
                edge.insertsBefore ? [.leaf(newPane), .leaf(pane)] : [.leaf(pane), .leaf(newPane)]
            return .split(
                SplitNodeGroup(axis: edge.axis, children: children, fractions: [0.5, 0.5]))

        case .split(var group):
            // Same axis and a direct child: extend this split in place.
            if group.axis == edge.axis,
                let index = group.children.firstIndex(where: { $0 == .leaf(target) })
            {
                let insertAt = edge.insertsBefore ? index : index + 1
                // The new pane takes half of the target's space, so the rest
                // of the layout does not shift when a pane is split.
                let share = group.fractions[index] / 2
                group.fractions[index] = share
                group.children.insert(.leaf(newPane), at: insertAt)
                group.fractions.insert(share, at: insertAt)
                return .split(group)
            }
            group.children = group.children.map {
                split($0, target: target, edge: edge, newPane: newPane)
            }
            return .split(group)
        }
    }

    /// Returns the node with `pane` removed, or `nil` if the node *was* the
    /// pane.
    private static func remove(_ node: SplitNode, pane: PaneID) -> SplitNode? {
        switch node {
        case .leaf(let existing):
            return existing == pane ? nil : node

        case .split(var group):
            var children: [SplitNode] = []
            var fractions: [Double] = []
            for (child, fraction) in zip(group.children, group.fractions) {
                if let kept = remove(child, pane: pane) {
                    children.append(kept)
                    fractions.append(fraction)
                }
            }
            if children.isEmpty { return nil }
            group.children = children
            group.fractions = normalised(fractions)
            return .split(group)
        }
    }

    private static func resize(
        _ node: SplitNode, id: SplitID, index: Int, delta: Double
    ) -> SplitNode {
        guard case .split(var group) = node else { return node }

        if group.id == id {
            guard index >= 0, index + 1 < group.fractions.count else { return node }
            let total = group.fractions[index] + group.fractions[index + 1]
            // The pair's combined share is fixed; only the boundary moves.
            let low = min(max(group.fractions[index] + delta, minimumFraction), total - minimumFraction)
            group.fractions[index] = low
            group.fractions[index + 1] = total - low
            return .split(group)
        }

        group.children = group.children.map { resize($0, id: id, index: index, delta: delta) }
        return .split(group)
    }

    private static func setFractions(
        _ node: SplitNode, id: SplitID, fractions: [Double]
    ) -> SplitNode {
        guard case .split(var group) = node else { return node }
        if group.id == id, fractions.count == group.children.count {
            group.fractions = normalised(fractions)
            return .split(group)
        }
        group.children = group.children.map { setFractions($0, id: id, fractions: fractions) }
        return .split(group)
    }

    /// Restores the tree's invariants: no one-child splits, no nested splits
    /// sharing their parent's axis, fractions summing to 1.
    private static func normalise(_ node: SplitNode) -> SplitNode {
        guard case .split(var group) = node else { return node }

        group.children = group.children.map(normalise)

        // A split with one child is not a split.
        if group.children.count == 1 {
            return group.children[0]
        }

        // Flatten a child that divides along the same axis, distributing its
        // fractions within the parent's share. Without this, splitting the
        // same pane repeatedly builds a lopsided tree whose dividers resize
        // different amounts of the window depending on their depth.
        var children: [SplitNode] = []
        var fractions: [Double] = []
        for (child, fraction) in zip(group.children, group.fractions) {
            if case .split(let inner) = child, inner.axis == group.axis {
                for (innerChild, innerFraction) in zip(inner.children, inner.fractions) {
                    children.append(innerChild)
                    fractions.append(fraction * innerFraction)
                }
            } else {
                children.append(child)
                fractions.append(fraction)
            }
        }

        group.children = children
        group.fractions = normalised(fractions)
        return .split(group)
    }

    /// Scales `fractions` to sum to 1, falling back to an even split.
    private static func normalised(_ fractions: [Double]) -> [Double] {
        let total = fractions.reduce(0, +)
        guard total > 0, fractions.allSatisfy({ $0.isFinite }) else {
            return Array(repeating: 1.0 / Double(max(fractions.count, 1)), count: fractions.count)
        }
        return fractions.map { $0 / total }
    }
}
