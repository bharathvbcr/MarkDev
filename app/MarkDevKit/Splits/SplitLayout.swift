//
//  SplitLayout.swift
//  MarkDevKit
//
//  The pane tree behind draggable splits.
//

import Foundation

/// Identifies one pane (a leaf of the split tree).
public struct PaneID: Hashable, Sendable, Identifiable, Codable {
    public let id: UUID
    public init(id: UUID = UUID()) { self.id = id }
}

/// Identifies one split node, so a divider drag can address the split it
/// belongs to without carrying a path through the view hierarchy.
public struct SplitID: Hashable, Sendable, Identifiable, Codable {
    public let id: UUID
    public init(id: UUID = UUID()) { self.id = id }
}

/// Direction a split divides in.
public enum SplitAxis: Sendable, Hashable, Codable {
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
public indirect enum SplitNode: Sendable, Equatable, Identifiable, Codable {
    case leaf(PaneID)
    case split(SplitNodeGroup)

    private enum VariantKeys: String, CodingKey {
        case leaf
        case split
    }

    private enum AssociatedValueKey: String, CodingKey {
        case value = "_0"
    }

    public init(from decoder: Decoder) throws {
        self = try SplitLayout.decodeNode(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: VariantKeys.self)
        switch self {
        case .leaf(let pane):
            var value = container.nestedContainer(
                keyedBy: AssociatedValueKey.self, forKey: .leaf)
            try value.encode(pane, forKey: .value)
        case .split(let group):
            var value = container.nestedContainer(
                keyedBy: AssociatedValueKey.self, forKey: .split)
            try value.encode(group, forKey: .value)
        }
    }

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
public struct SplitNodeGroup: Sendable, Equatable, Codable {
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

    private enum CodingKeys: String, CodingKey {
        case id
        case axis
        case children
        case fractions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(SplitID.self, forKey: .id)
        axis = try container.decode(SplitAxis.self, forKey: .axis)

        var childContainer = try container.nestedUnkeyedContainer(forKey: .children)
        if let count = childContainer.count, count > SplitLayout.maximumChildrenPerSplit {
            throw DecodingError.dataCorruptedError(
                forKey: .children,
                in: container,
                debugDescription: "A split has too many direct children.")
        }
        var decodedChildren: [SplitNode] = []
        decodedChildren.reserveCapacity(min(childContainer.count ?? 0, SplitLayout.maximumChildrenPerSplit))
        while !childContainer.isAtEnd {
            guard decodedChildren.count < SplitLayout.maximumChildrenPerSplit else {
                throw DecodingError.dataCorruptedError(
                    forKey: .children,
                    in: container,
                    debugDescription: "A split has too many direct children.")
            }
            decodedChildren.append(try childContainer.decode(SplitNode.self))
        }
        children = decodedChildren

        var fractionContainer = try container.nestedUnkeyedContainer(forKey: .fractions)
        if let count = fractionContainer.count, count > SplitLayout.maximumChildrenPerSplit {
            throw DecodingError.dataCorruptedError(
                forKey: .fractions,
                in: container,
                debugDescription: "A split has too many fractions.")
        }
        var decodedFractions: [Double] = []
        decodedFractions.reserveCapacity(
            min(fractionContainer.count ?? 0, SplitLayout.maximumChildrenPerSplit))
        while !fractionContainer.isAtEnd {
            guard decodedFractions.count < SplitLayout.maximumChildrenPerSplit else {
                throw DecodingError.dataCorruptedError(
                    forKey: .fractions,
                    in: container,
                    debugDescription: "A split has too many fractions.")
            }
            decodedFractions.append(try fractionContainer.decode(Double.self))
        }
        fractions = decodedFractions
    }
}

/// The arrangement of panes in a window.
///
/// A pure value type: every operation returns a normalised tree, and the
/// SwiftUI layer only reads it. Keeping the geometry rules here — rather than
/// spread through view code — is what makes "no gaps, nothing collapses to
/// zero" testable instead of something to eyeball.
public struct SplitLayout: Sendable, Equatable, Codable {
    /// Smallest fraction a pane may shrink to, so a pane can never be dragged
    /// out of existence and become unrecoverable.
    public static let minimumFraction: Double = 0.08

    /// A window remains usable at this many editors, while also bounding the
    /// amount of view and document state a corrupted session can request.
    public static let maximumPanes = 16

    /// Fifteen alternating binary splits can describe sixteen panes. Anything
    /// deeper cannot add a valid pane within ``maximumPanes``.
    public static let maximumDepth = 15

    /// More children cannot each retain ``minimumFraction`` of their parent.
    public static let maximumChildrenPerSplit = 12

    static let maximumNodes = maximumPanes * 2 - 1

    public private(set) var root: SplitNode

    public init(root: SplitNode) {
        // Programmatic callers get a repaired finite geometry. Structurally
        // hostile trees preserve their first reachable pane when possible;
        // persisted input uses the stricter throwing decoder below.
        self.root = Self.recoveredRoot(root)
    }

    public init(pane: PaneID) {
        self.root = .leaf(pane)
    }

    private enum CodingKeys: String, CodingKey {
        case root
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        root = try container.decode(SplitNode.self, forKey: .root)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(root, forKey: .root)
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
    @discardableResult
    public mutating func split(_ target: PaneID, edge: SplitEdge, with newPane: PaneID) -> Bool {
        let existingPanes = panes
        guard existingPanes.contains(target), !existingPanes.contains(newPane),
            existingPanes.count < Self.maximumPanes
        else { return false }

        let candidate = Self.split(root, target: target, edge: edge, newPane: newPane)
        guard let canonical = try? Self.canonicalRoot(candidate, strict: false),
            canonical.panes.contains(newPane)
        else { return false }
        root = canonical
        return true
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
        guard delta.isFinite else { return }
        root = Self.resize(root, id: id, index: index, delta: delta)
    }

    /// Sets fractions directly, used when restoring a saved layout.
    public mutating func setFractions(split id: SplitID, to fractions: [Double]) {
        guard fractions.allSatisfy({ $0.isFinite && $0 > 0 }) else { return }
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

    /// Restores the tree's invariants after a trusted in-memory mutation.
    private static func normalise(_ node: SplitNode) -> SplitNode {
        recoveredRoot(node)
    }

    private static func recoveredRoot(_ node: SplitNode) -> SplitNode {
        (try? canonicalRoot(node, strict: false))
            ?? firstPane(in: node).map(SplitNode.leaf)
            ?? .leaf(PaneID())
    }

    /// Finds a recovery leaf without recursively materializing every pane in
    /// an already-invalid tree. Inspection is itself capped at the node limit.
    private static func firstPane(in node: SplitNode) -> PaneID? {
        var pending = [node]
        var inspected = 0
        while let current = pending.popLast(), inspected < maximumNodes {
            inspected += 1
            switch current {
            case .leaf(let pane):
                return pane
            case .split(let group):
                let room = max(maximumNodes - inspected - pending.count, 0)
                pending.append(contentsOf: group.children.prefix(room).reversed())
            }
        }
        return nil
    }

    /// Scales `fractions` to sum to 1 while enforcing the recoverable minimum,
    /// falling back to an even split for invalid programmatic input.
    private static func normalised(_ fractions: [Double]) -> [Double] {
        constrainedFractions(fractions)
            ?? Array(
                repeating: 1.0 / Double(max(fractions.count, 1)),
                count: fractions.count)
    }

    private enum LayoutError: Error, CustomStringConvertible {
        case invalid(String)

        var description: String {
            switch self {
            case .invalid(let message): message
            }
        }
    }

    private struct ValidationState {
        var identities: Set<UUID> = []
        var paneCount = 0
        var nodeCount = 0
    }

    private struct DecodeBudget {
        var identities: Set<UUID> = []
        var paneCount = 0
        var nodeCount = 0
    }

    private struct WireKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init(_ stringValue: String) {
            self.stringValue = stringValue
        }

        init?(stringValue: String) {
            self.init(stringValue)
        }

        init?(intValue: Int) {
            return nil
        }
    }

    private enum GroupCodingKeys: String, CodingKey {
        case id
        case axis
        case children
        case fractions
    }

    /// Decodes a whole node tree with one shared allocation budget. Calling
    /// `decode` recursively on `SplitNode` would create a fresh counter for
    /// every child and would only discover an oversized tree after allocating
    /// all of it.
    fileprivate static func decodeNode(from decoder: Decoder) throws -> SplitNode {
        var budget = DecodeBudget()
        let decoded = try decodeRawNode(from: decoder, depth: 0, budget: &budget)
        do {
            return try canonicalRoot(decoded, strict: true)
        } catch {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid split layout: \(error)"))
        }
    }

    private static func decodeRawNode(
        from decoder: Decoder,
        depth: Int,
        budget: inout DecodeBudget
    ) throws -> SplitNode {
        budget.nodeCount += 1
        guard budget.nodeCount <= maximumNodes else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "The split tree contains too many nodes."))
        }

        let container = try decoder.container(keyedBy: WireKey.self)
        guard container.allKeys.count == 1, let variant = container.allKeys.first,
            variant.stringValue == "leaf" || variant.stringValue == "split"
        else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "A split node must contain exactly one known variant."))
        }
        let associatedDecoder = try container.superDecoder(forKey: variant)
        let associated = try associatedDecoder.container(keyedBy: WireKey.self)
        guard associated.allKeys.count == 1,
            let valueKey = associated.allKeys.first,
            valueKey.stringValue == "_0"
        else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: associatedDecoder.codingPath,
                    debugDescription: "A split variant must contain exactly one value."))
        }
        let valueDecoder = try associated.superDecoder(forKey: valueKey)

        if variant.stringValue == "leaf" {
            let pane = try PaneID(from: valueDecoder)
            budget.paneCount += 1
            guard budget.paneCount <= maximumPanes,
                budget.identities.insert(pane.id).inserted
            else {
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: valueDecoder.codingPath,
                        debugDescription: "The split tree has too many or duplicate panes."))
            }
            return .leaf(pane)
        }

        guard depth < maximumDepth else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: valueDecoder.codingPath,
                    debugDescription: "The split tree exceeds its depth limit."))
        }
        return .split(
            try decodeRawGroup(from: valueDecoder, depth: depth, budget: &budget))
    }

    private static func decodeRawGroup(
        from decoder: Decoder,
        depth: Int,
        budget: inout DecodeBudget
    ) throws -> SplitNodeGroup {
        let container = try decoder.container(keyedBy: GroupCodingKeys.self)
        let id = try container.decode(SplitID.self, forKey: .id)
        let axis = try container.decode(SplitAxis.self, forKey: .axis)
        guard budget.identities.insert(id.id).inserted else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "The split tree contains a duplicate identity.")
        }

        var childContainer = try container.nestedUnkeyedContainer(forKey: .children)
        if let count = childContainer.count,
            count == 0 || count > maximumChildrenPerSplit
        {
            throw DecodingError.dataCorruptedError(
                forKey: .children,
                in: container,
                debugDescription: "A split has an invalid number of direct children.")
        }
        var fractionContainer = try container.nestedUnkeyedContainer(forKey: .fractions)
        if let count = fractionContainer.count, count > maximumChildrenPerSplit {
            throw DecodingError.dataCorruptedError(
                forKey: .fractions,
                in: container,
                debugDescription: "A split has too many fractions.")
        }
        if let childCount = childContainer.count, let fractionCount = fractionContainer.count,
            childCount != fractionCount
        {
            throw DecodingError.dataCorruptedError(
                forKey: .fractions,
                in: container,
                debugDescription: "Fractions do not match the split's children.")
        }

        var children: [SplitNode] = []
        children.reserveCapacity(min(childContainer.count ?? 0, maximumChildrenPerSplit))
        while !childContainer.isAtEnd {
            guard children.count < maximumChildrenPerSplit else {
                throw DecodingError.dataCorruptedError(
                    forKey: .children,
                    in: container,
                    debugDescription: "A split has too many direct children.")
            }
            let childDecoder = try childContainer.superDecoder()
            children.append(
                try decodeRawNode(from: childDecoder, depth: depth + 1, budget: &budget))
        }

        var fractions: [Double] = []
        fractions.reserveCapacity(min(fractionContainer.count ?? 0, maximumChildrenPerSplit))
        while !fractionContainer.isAtEnd {
            guard fractions.count < maximumChildrenPerSplit else {
                throw DecodingError.dataCorruptedError(
                    forKey: .fractions,
                    in: container,
                    debugDescription: "A split has too many fractions.")
            }
            fractions.append(try fractionContainer.decode(Double.self))
        }
        return SplitNodeGroup(id: id, axis: axis, children: children, fractions: fractions)
    }

    /// One canonical owner for both decoded and live trees. Both paths collapse
    /// a one-child split because its survivor is unambiguous. Persisted input
    /// rejects invalid geometry; live programmatic input may repair it.
    private static func canonicalRoot(_ node: SplitNode, strict: Bool) throws -> SplitNode {
        var state = ValidationState()
        return try canonical(node, depth: 0, strict: strict, state: &state)
    }

    private static func canonical(
        _ node: SplitNode,
        depth: Int,
        strict: Bool,
        state: inout ValidationState
    ) throws -> SplitNode {
        state.nodeCount += 1
        guard state.nodeCount <= maximumNodes else {
            throw LayoutError.invalid("too many nodes")
        }
        guard state.identities.insert(node.id).inserted else {
            throw LayoutError.invalid("duplicate pane or split identity")
        }

        switch node {
        case .leaf(let pane):
            state.paneCount += 1
            guard state.paneCount <= maximumPanes else {
                throw LayoutError.invalid("too many panes")
            }
            return .leaf(pane)

        case .split(var group):
            guard depth < maximumDepth else {
                throw LayoutError.invalid("tree is too deep")
            }
            guard !group.children.isEmpty else {
                throw LayoutError.invalid("an empty split has no recoverable pane")
            }
            guard group.children.count <= maximumChildrenPerSplit else {
                throw LayoutError.invalid("too many direct children")
            }

            var sourceFractions = group.fractions
            let validGeometry = sourceFractions.count == group.children.count
                && sourceFractions.allSatisfy { $0.isFinite && $0 > 0 }
            if !validGeometry {
                guard !strict else {
                    throw LayoutError.invalid("fractions do not match finite positive children")
                }
                sourceFractions = Array(repeating: 1, count: group.children.count)
            }

            var canonicalChildren: [SplitNode] = []
            canonicalChildren.reserveCapacity(group.children.count)
            for child in group.children {
                canonicalChildren.append(
                    try canonical(child, depth: depth + 1, strict: strict, state: &state))
            }

            if canonicalChildren.count == 1 {
                return canonicalChildren[0]
            }

            // Flatten same-axis descendants at the model seam, carrying each
            // child's share into the parent before minimum-fraction repair.
            var flattenedChildren: [SplitNode] = []
            var flattenedFractions: [Double] = []
            for (child, fraction) in zip(canonicalChildren, sourceFractions) {
                if case .split(let inner) = child, inner.axis == group.axis {
                    for (innerChild, innerFraction) in zip(inner.children, inner.fractions) {
                        flattenedChildren.append(innerChild)
                        flattenedFractions.append(fraction * innerFraction)
                    }
                } else {
                    flattenedChildren.append(child)
                    flattenedFractions.append(fraction)
                }
            }
            guard flattenedChildren.count <= maximumChildrenPerSplit else {
                throw LayoutError.invalid("flattening would create an unusable split")
            }
            guard let fractions = constrainedFractions(flattenedFractions) else {
                throw LayoutError.invalid("fractions cannot be normalized")
            }
            group.children = flattenedChildren
            group.fractions = fractions
            return .split(group)
        }
    }

    /// Projects positive weights onto a unit interval with a hard lower bound.
    /// Existing usable fractions remain unchanged; only undersized panes and
    /// their siblings are redistributed.
    private static func constrainedFractions(_ fractions: [Double]) -> [Double]? {
        guard !fractions.isEmpty, fractions.count <= maximumChildrenPerSplit,
            Double(fractions.count) * minimumFraction <= 1,
            fractions.allSatisfy({ $0.isFinite && $0 > 0 })
        else { return nil }

        let total = fractions.reduce(0, +)
        guard total.isFinite, total > 0 else { return nil }
        let weights = fractions.map { $0 / total }
        var result = Array(repeating: 0.0, count: fractions.count)
        var remaining = Array(fractions.indices)
        var available = 1.0

        while !remaining.isEmpty {
            let weightTotal = remaining.reduce(0.0) { $0 + weights[$1] }
            guard weightTotal.isFinite, weightTotal > 0 else { return nil }
            let undersized = remaining.filter {
                available * weights[$0] / weightTotal < minimumFraction
            }
            if undersized.isEmpty {
                for index in remaining {
                    result[index] = available * weights[index] / weightTotal
                }
                break
            }
            let undersizedSet = Set(undersized)
            for index in undersized {
                result[index] = minimumFraction
                available -= minimumFraction
            }
            remaining.removeAll { undersizedSet.contains($0) }
            guard available >= -1e-12 else { return nil }
        }

        if let largest = result.indices.max(by: { result[$0] < result[$1] }) {
            result[largest] += 1 - result.reduce(0, +)
        }
        guard result.allSatisfy({ $0.isFinite && $0 + 1e-12 >= minimumFraction }) else {
            return nil
        }
        return result
    }
}
