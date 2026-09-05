//
//  SessionSplitHardeningTests.swift
//  MarkDevKitTests
//
//  Adversarial persisted-state and split-tree boundaries.
//

import XCTest

@testable import MarkDevKit

private enum SplitFixture {
    static func leaf(_ pane: UUID) -> [String: Any] {
        ["leaf": ["_0": ["id": pane.uuidString]]]
    }

    static func split(
        id: UUID = UUID(),
        axis: SplitAxis = .horizontal,
        children: [[String: Any]],
        fractions: [Double]
    ) -> [String: Any] {
        let axisName = axis == .horizontal ? "horizontal" : "vertical"
        return [
            "split": [
                "_0": [
                    "id": ["id": id.uuidString],
                    "axis": [axisName: [:]],
                    "children": children,
                    "fractions": fractions,
                ]
            ]
        ]
    }

    static func data(root: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["root": root], options: [.sortedKeys])
    }

    static func alternatingTree(depth: Int, seed: Int = 0) -> [String: Any] {
        guard depth > 0 else {
            return leaf(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", seed))!)
        }
        let sibling = UUID(
            uuidString: String(format: "10000000-0000-0000-0000-%012d", seed))!
        return split(
            axis: depth.isMultiple(of: 2) ? .horizontal : .vertical,
            children: [alternatingTree(depth: depth - 1, seed: seed + 1), leaf(sibling)],
            fractions: [0.5, 0.5])
    }

    static func shallowTree(nodeCount: Int) -> [String: Any] {
        precondition(
            nodeCount == SplitLayout.maximumNodes
                || nodeCount == SplitLayout.maximumNodes + 1)
        let baseNodeCount = 1 + 2 * SplitLayout.maximumChildrenPerSplit
        let extraWrappers = nodeCount - baseNodeCount
        let children = (0..<SplitLayout.maximumChildrenPerSplit).map {
            index -> [String: Any] in
            var node = leaf(UUID())
            let wrappers = 1 + (index < extraWrappers ? 1 : 0)
            for level in 0..<wrappers {
                node = split(
                    axis: level.isMultiple(of: 2) ? .vertical : .horizontal,
                    children: [node],
                    fractions: [1])
            }
            return node
        }
        return split(
            children: children,
            fractions: Array(
                repeating: 1.0 / Double(SplitLayout.maximumChildrenPerSplit),
                count: SplitLayout.maximumChildrenPerSplit))
    }
}

final class SplitLayoutDecodingHardeningTests: XCTestCase {
    private func decode(_ root: [String: Any]) throws -> SplitLayout {
        try JSONDecoder().decode(SplitLayout.self, from: SplitFixture.data(root: root))
    }

    private func assertGeometry(
        _ node: SplitNode,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .split(let group) = node else { return }
        XCTAssertGreaterThanOrEqual(group.children.count, 2, file: file, line: line)
        XCTAssertEqual(group.children.count, group.fractions.count, file: file, line: line)
        XCTAssertEqual(group.fractions.reduce(0, +), 1, accuracy: 0.000_001, file: file, line: line)
        for fraction in group.fractions {
            XCTAssertTrue(fraction.isFinite, file: file, line: line)
            XCTAssertGreaterThanOrEqual(
                fraction, SplitLayout.minimumFraction, file: file, line: line)
        }
        group.children.forEach { assertGeometry($0, file: file, line: line) }
    }

    func testDecodeRejectsEmptySplit() throws {
        let root = SplitFixture.split(children: [], fractions: [])
        XCTAssertThrowsError(try decode(root))
    }

    func testDecodeCollapsesOneChildSplit() throws {
        let pane = UUID()
        let layout = try decode(SplitFixture.split(children: [SplitFixture.leaf(pane)], fractions: [1]))
        XCTAssertEqual(layout.root, .leaf(PaneID(id: pane)))
    }

    func testDecodeRejectsFractionCountMismatchInsteadOfSilentlyDroppingChildren() throws {
        let root = SplitFixture.split(
            children: [SplitFixture.leaf(UUID()), SplitFixture.leaf(UUID())],
            fractions: [1])
        XCTAssertThrowsError(try decode(root))
    }

    func testDecodeRejectsNegativeAndZeroFractions() throws {
        for fractions in [[-0.1, 1.1], [0, 1]] {
            let root = SplitFixture.split(
                children: [SplitFixture.leaf(UUID()), SplitFixture.leaf(UUID())],
                fractions: fractions)
            XCTAssertThrowsError(try decode(root), "fractions: \(fractions)")
        }
    }

    func testDecodeRepairsPositiveSubminimumFractions() throws {
        let layout = try decode(
            SplitFixture.split(
                children: [SplitFixture.leaf(UUID()), SplitFixture.leaf(UUID())],
                fractions: [0.001, 0.999]))
        assertGeometry(layout.root)
    }

    func testDecodeRejectsDuplicatePaneIdentity() throws {
        let duplicate = UUID()
        let root = SplitFixture.split(
            children: [SplitFixture.leaf(duplicate), SplitFixture.leaf(duplicate)],
            fractions: [0.5, 0.5])
        XCTAssertThrowsError(try decode(root))
    }

    func testDecodeRejectsPaneAndSplitIdentityCollision() throws {
        let duplicate = UUID()
        let root = SplitFixture.split(
            id: duplicate,
            children: [SplitFixture.leaf(duplicate), SplitFixture.leaf(UUID())],
            fractions: [0.5, 0.5])
        XCTAssertThrowsError(try decode(root))
    }

    func testDecodeRejectsDuplicateSplitIdentity() throws {
        let duplicate = UUID()
        let nested = SplitFixture.split(
            id: duplicate,
            axis: .vertical,
            children: [SplitFixture.leaf(UUID()), SplitFixture.leaf(UUID())],
            fractions: [0.5, 0.5])
        let root = SplitFixture.split(
            id: duplicate,
            children: [nested, SplitFixture.leaf(UUID())],
            fractions: [0.5, 0.5])
        XCTAssertThrowsError(try decode(root))
    }

    func testDecodeAcceptsMaximumDepthAndRejectsTheNextLevel() throws {
        XCTAssertNoThrow(try decode(SplitFixture.alternatingTree(depth: 15)))
        XCTAssertThrowsError(try decode(SplitFixture.alternatingTree(depth: 16)))
    }

    func testDecodeAcceptsMaximumNodeCountAndRejectsTheNextNode() throws {
        XCTAssertNoThrow(
            try decode(SplitFixture.shallowTree(nodeCount: SplitLayout.maximumNodes)))
        XCTAssertThrowsError(
            try decode(SplitFixture.shallowTree(nodeCount: SplitLayout.maximumNodes + 1)))
    }

    func testDecodeAcceptsMaximumDirectChildrenAndRejectsTheNextChild() throws {
        let accepted = (0..<SplitLayout.maximumChildrenPerSplit).map { _ in
            SplitFixture.leaf(UUID())
        }
        XCTAssertNoThrow(
            try decode(
                SplitFixture.split(
                    children: accepted,
                    fractions: Array(
                        repeating: 1.0 / Double(SplitLayout.maximumChildrenPerSplit),
                        count: accepted.count))))

        let rejected = accepted + [SplitFixture.leaf(UUID())]
        XCTAssertThrowsError(
            try decode(
                SplitFixture.split(
                    children: rejected,
                    fractions: Array(
                        repeating: 1.0 / Double(rejected.count),
                        count: rejected.count))))
    }

    func testRootInitializerRepairsNonfiniteGeometry() {
        let group = SplitNodeGroup(
            axis: .horizontal,
            children: [.leaf(PaneID()), .leaf(PaneID())],
            fractions: [.nan, .infinity])
        let layout = SplitLayout(root: .split(group))
        assertGeometry(layout.root)
    }

    func testRootInitializerPreservesAKnownPaneWhenStructureIsInvalid() {
        let first = PaneID()
        let invalid = SplitNode.split(
            SplitNodeGroup(axis: .horizontal, children: [.leaf(first), .leaf(first)], fractions: [0.5, 0.5]))

        let layout = SplitLayout(root: invalid)

        XCTAssertEqual(layout.root, .leaf(first))
    }

    func testLiveSplittingRejectsDuplicateIdentityAndCapsResourceGrowth() {
        let first = PaneID()
        var duplicateAttempt = SplitLayout(pane: first)
        duplicateAttempt.split(first, edge: .trailing, with: first)
        XCTAssertEqual(
            duplicateAttempt.panes, [first], "one pane identity cannot name two live editors")

        var layout = SplitLayout(pane: PaneID())
        for _ in 0..<100 {
            layout.split(layout.panes[0], edge: .bottom, with: PaneID())
        }
        XCTAssertLessThanOrEqual(layout.paneCount, 16)
        XCTAssertEqual(Set(layout.panes).count, layout.paneCount)
        assertGeometry(layout.root)
    }

    func testLiveSplittingAcceptsExactPaneLimitAndRefusesTheNextPane() {
        let first = PaneID()
        var layout = SplitLayout(pane: first)
        var target = first

        for index in 1..<SplitLayout.maximumPanes {
            let pane = PaneID()
            let edge: SplitEdge = index.isMultiple(of: 2) ? .bottom : .trailing
            XCTAssertTrue(layout.split(target, edge: edge, with: pane), "pane \(index + 1)")
            target = pane
        }

        XCTAssertEqual(layout.paneCount, SplitLayout.maximumPanes)
        XCTAssertFalse(layout.split(target, edge: .bottom, with: PaneID()))
        XCTAssertEqual(layout.paneCount, SplitLayout.maximumPanes)
        assertGeometry(layout.root)
    }

    func testFlatSplitAcceptsExactChildLimitAndRefusesTheNextChild() {
        let first = PaneID()
        var layout = SplitLayout(pane: first)
        var target = first

        for index in 1..<SplitLayout.maximumChildrenPerSplit {
            let pane = PaneID()
            XCTAssertTrue(
                layout.split(target, edge: .trailing, with: pane), "child \(index + 1)")
            target = pane
        }

        guard case .split(let group) = layout.root else { return XCTFail("expected split") }
        XCTAssertEqual(group.children.count, SplitLayout.maximumChildrenPerSplit)
        XCTAssertFalse(layout.split(target, edge: .trailing, with: PaneID()))
        XCTAssertEqual(layout.paneCount, SplitLayout.maximumChildrenPerSplit)
        assertGeometry(layout.root)
    }

    func testNonfiniteResizeIsIgnored() {
        let panes = [PaneID(), PaneID()]
        var layout = SplitLayout(pane: panes[0])
        layout.split(panes[0], edge: .trailing, with: panes[1])
        let before = layout
        guard case .split(let group) = layout.root else { return XCTFail("expected split") }

        layout.resize(split: group.id, dividerAfter: 0, by: .nan)

        XCTAssertEqual(layout, before)
        assertGeometry(layout.root)
    }
}

@MainActor
final class SessionSnapshotHardeningTests: XCTestCase {
    private let payloadLimit = 1_048_576

    override func tearDown() {
        SessionStore.clear()
        super.tearDown()
    }

    private func snapshot(pane: PaneID = PaneID()) -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            layout: SplitLayout(pane: pane),
            panes: [PaneSnapshot(pane: pane, documents: [], selection: nil)],
            focusedPane: pane,
            vaultRoot: nil)
    }

    private func maximumLayout() -> SplitLayout {
        let first = PaneID()
        var layout = SplitLayout(pane: first)
        var target = first
        for index in 1..<SplitLayout.maximumPanes {
            let pane = PaneID()
            let edge: SplitEdge = index.isMultiple(of: 2) ? .bottom : .trailing
            XCTAssertTrue(layout.split(target, edge: edge, with: pane))
            target = pane
        }
        return layout
    }

    private func documents(_ count: Int, prefix: String = "Note") -> [DocumentSnapshot] {
        (0..<count).map {
            DocumentSnapshot(url: URL(fileURLWithPath: "/tmp/\(prefix)-\($0).md").absoluteString)
        }
    }

    private func encodedWithPadding(_ byteCount: Int) throws -> Data {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot()))
                as? [String: Any])
        object["ignoredPadding"] = ""
        let empty = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        XCTAssertLessThanOrEqual(empty.count, byteCount)
        object["ignoredPadding"] = String(repeating: "x", count: byteCount - empty.count)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        XCTAssertEqual(data.count, byteCount)
        return data
    }

    func testStoredPayloadAcceptsExactLimitAndRejectsOneByteOver() throws {
        UserDefaults.standard.set(try encodedWithPadding(payloadLimit), forKey: "session.workspace")
        let empty = try XCTUnwrap(SessionStore.load())
        XCTAssertTrue(empty.panes.allSatisfy(\.documents.isEmpty))

        UserDefaults.standard.set(
            try encodedWithPadding(payloadLimit + 1), forKey: "session.workspace")
        XCTAssertNil(SessionStore.load())
        XCTAssertNil(UserDefaults.standard.object(forKey: SessionStore.key))
    }

    func testStoredJSONNestingIsBoundedBeforeDecoding() throws {
        func data(nesting: Int) throws -> Data {
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot()))
                    as? [String: Any])
            var nested: Any = 0
            for _ in 0..<nesting { nested = [nested] }
            object["ignoredNesting"] = nested
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }

        UserDefaults.standard.set(try data(nesting: 127), forKey: "session.workspace")
        XCTAssertNotNil(SessionStore.load())

        UserDefaults.standard.set(try data(nesting: 128), forKey: "session.workspace")
        XCTAssertNil(SessionStore.load())
        XCTAssertNil(UserDefaults.standard.object(forKey: SessionStore.key))
    }

    func testMalformedAndWrongTypeStoredValuesAreDiscarded() {
        for value: Any in ["not data", Data("{not json}".utf8)] {
            UserDefaults.standard.set(value, forKey: SessionStore.key)

            XCTAssertNil(SessionStore.load())
            XCTAssertNil(UserDefaults.standard.object(forKey: SessionStore.key))
        }
    }

    func testRejectedStoredSessionLeavesPrivacySafeDiagnosticEvidence() async {
        await DiagnosticsEmitter.shared.flush()
        let before = await DiagnosticsEmitter.shared.snapshot().events.filter {
            $0.code.rawValue == "workspace.session-restore.rejected"
        }.count
        let corrupt = Data("{not json}".utf8)
        UserDefaults.standard.set(corrupt, forKey: SessionStore.key)

        XCTAssertNil(SessionStore.load())
        await DiagnosticsEmitter.shared.flush()

        let events = await DiagnosticsEmitter.shared.snapshot().events.filter {
            $0.code.rawValue == "workspace.session-restore.rejected"
        }
        XCTAssertEqual(events.count, before + 1)
        XCTAssertEqual(events.last?.severity, .warning)
        XCTAssertEqual(events.last?.subsystem, .workspace)
        XCTAssertEqual(
            events.last?.metadata,
            DiagnosticMetadata([.byteCount: .integer(Int64(corrupt.count))]))
        XCTAssertNil(UserDefaults.standard.object(forKey: SessionStore.key))
    }

    func testRejectedSessionSaveLeavesPrivacySafeDiagnosticEvidence() async throws {
        let layout = maximumLayout()
        let padding = String(repeating: "a", count: 5_000)
        var documentOrdinal = 0
        let panes = layout.panes.map { pane -> PaneSnapshot in
            defer { documentOrdinal += SessionStateLimits.maximumDocumentsPerPane }
            let documents = (0..<SessionStateLimits.maximumDocumentsPerPane).map { offset in
                DocumentSnapshot(
                    url: "file:///tmp/\(padding)-\(documentOrdinal + offset).md")
            }
            return PaneSnapshot(pane: pane, documents: documents, selection: nil)
        }
        let oversized = WorkspaceSnapshot(
            layout: layout,
            panes: panes,
            focusedPane: layout.panes[0],
            vaultRoot: nil)
        let encodedByteCount = try JSONEncoder().encode(oversized).count
        XCTAssertGreaterThan(encodedByteCount, SessionStateLimits.maximumEncodedBytes)

        SessionStore.save(snapshot())
        XCTAssertNotNil(UserDefaults.standard.object(forKey: SessionStore.key))
        await DiagnosticsEmitter.shared.flush()
        let before = await DiagnosticsEmitter.shared.snapshot().events.filter {
            $0.code.rawValue == "workspace.session-save.rejected"
        }.count

        SessionStore.save(oversized)
        await DiagnosticsEmitter.shared.flush()

        let events = await DiagnosticsEmitter.shared.snapshot().events.filter {
            $0.code.rawValue == "workspace.session-save.rejected"
        }
        XCTAssertEqual(events.count, before + 1)
        XCTAssertEqual(events.last?.severity, .warning)
        XCTAssertEqual(events.last?.subsystem, .workspace)
        XCTAssertEqual(
            events.last?.metadata,
            DiagnosticMetadata([.byteCount: .integer(Int64(encodedByteCount))]))
        XCTAssertNil(UserDefaults.standard.object(forKey: SessionStore.key))
    }

    func testDecodeAcceptsExactPaneEntryLimitAndRejectsTheNextEntry() throws {
        let layout = maximumLayout()
        let value = WorkspaceSnapshot(
            layout: layout,
            panes: layout.panes.map {
                PaneSnapshot(pane: $0, documents: [], selection: nil)
            },
            focusedPane: layout.panes[0],
            vaultRoot: nil)
        let accepted = try JSONEncoder().encode(value)
        XCTAssertNoThrow(try JSONDecoder().decode(WorkspaceSnapshot.self, from: accepted))

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: accepted) as? [String: Any])
        var paneObjects = try XCTUnwrap(object["panes"] as? [[String: Any]])
        let extra = PaneSnapshot(pane: PaneID(), documents: [], selection: nil)
        paneObjects.append(
            try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(extra))
                    as? [String: Any]))
        object["panes"] = paneObjects

        let oversized = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        XCTAssertThrowsError(try JSONDecoder().decode(WorkspaceSnapshot.self, from: oversized))
    }

    func testDecodeAcceptsExactDocumentLimitAndRejectsTheNextDocumentInAPane() throws {
        let pane = PaneID()
        let value = PaneSnapshot(
            pane: pane,
            documents: documents(SessionStateLimits.maximumDocumentsPerPane),
            selection: nil)
        let accepted = try JSONEncoder().encode(value)
        XCTAssertEqual(
            try JSONDecoder().decode(PaneSnapshot.self, from: accepted).documents.count,
            SessionStateLimits.maximumDocumentsPerPane)

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: accepted) as? [String: Any])
        var documentObjects = try XCTUnwrap(object["documents"] as? [[String: Any]])
        documentObjects.append(
            try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: JSONEncoder().encode(
                        DocumentSnapshot(url: "file:///tmp/Overflow.md")))
                    as? [String: Any]))
        object["documents"] = documentObjects

        let oversized = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        XCTAssertThrowsError(try JSONDecoder().decode(PaneSnapshot.self, from: oversized))
    }

    func testSnapshotAcceptsExactAggregateDocumentLimitAndTruncatesTheNextDocument() {
        let layout = maximumLayout()
        let exactEntries = layout.panes.enumerated().map { index, pane in
            PaneSnapshot(
                pane: pane,
                documents: documents(16, prefix: "Pane-\(index)"),
                selection: nil)
        }
        let exact = WorkspaceSnapshot(
            layout: layout,
            panes: exactEntries,
            focusedPane: layout.panes[0],
            vaultRoot: nil)
        XCTAssertEqual(
            exact.panes.reduce(0) { $0 + $1.documents.count },
            SessionStateLimits.maximumDocuments)

        var overEntries = exactEntries
        overEntries[0] = PaneSnapshot(
            pane: layout.panes[0],
            documents: documents(17, prefix: "Pane-0"),
            selection: nil)
        let truncated = WorkspaceSnapshot(
            layout: layout,
            panes: overEntries,
            focusedPane: layout.panes[0],
            vaultRoot: nil)
        XCTAssertEqual(
            truncated.panes.reduce(0) { $0 + $1.documents.count },
            SessionStateLimits.maximumDocuments)
        XCTAssertEqual(truncated.panes.last?.documents.count, 15)
    }

    func testSnapshotCapsPanesAndDocumentsAndRemovesDuplicatePaneEntries() {
        let layout = maximumLayout()
        let panes = layout.panes
        let documents = documents(40)
        let entries = panes.map {
            PaneSnapshot(pane: $0, documents: documents, selection: nil)
        } + [
            PaneSnapshot(
                pane: panes[0],
                documents: [DocumentSnapshot(url: "file:///tmp/DuplicateEntry.md")],
                selection: nil),
            PaneSnapshot(pane: PaneID(), documents: documents, selection: nil),
        ]

        let value = WorkspaceSnapshot(
            layout: layout, panes: entries, focusedPane: PaneID(), vaultRoot: nil)

        XCTAssertEqual(value.layout.paneCount, SplitLayout.maximumPanes)
        XCTAssertEqual(value.panes.map(\.pane), panes)
        XCTAssertEqual(Set(value.panes.map(\.pane)).count, value.panes.count)
        XCTAssertEqual(value.focusedPane, panes[0])
        XCTAssertTrue(value.panes.allSatisfy { $0.documents.count <= 32 })
        XCTAssertEqual(value.panes.reduce(0) { $0 + $1.documents.count }, 256)
        XCTAssertEqual(value.panes[0].documents.first?.url, "file:///tmp/Note-0.md")
    }

    func testSnapshotDropsNonfileAndDuplicateDocumentURLs() {
        let pane = PaneID()
        let file = DocumentSnapshot(url: URL(fileURLWithPath: "/tmp/Note.md").absoluteString)
        let value = WorkspaceSnapshot(
            layout: SplitLayout(pane: pane),
            panes: [
                PaneSnapshot(
                    pane: pane,
                    documents: [
                        file, file,
                        DocumentSnapshot(url: "https://example.com/remote.md"),
                        DocumentSnapshot(url: "file:///tmp/Note.md?alternate=1"),
                        DocumentSnapshot(url: "file:///tmp/Note.md#selection"),
                        DocumentSnapshot(url: "file://user:password@localhost/tmp/Note.md"),
                        DocumentSnapshot(url: "file:///tmp/\0bad.md"),
                        DocumentSnapshot(url: String(repeating: "x", count: 20_000)),
                    ],
                    selection: nil)
            ],
            focusedPane: pane,
            vaultRoot: "https://example.com/not-a-vault")

        XCTAssertEqual(value.panes[0].documents, [file])
        XCTAssertNil(value.vaultRoot)
    }

    func testDocumentURLAcceptsExactByteLimitAndRejectsTheNextByte() {
        let pane = PaneID()
        let prefix = "file:///"
        let exact = prefix
            + String(repeating: "a", count: SessionStateLimits.maximumURLBytes - prefix.utf8.count)
        let oversized = exact + "a"

        let value = PaneSnapshot(
            pane: pane,
            documents: [DocumentSnapshot(url: exact), DocumentSnapshot(url: oversized)],
            selection: nil)

        XCTAssertEqual(value.documents.count, 1)
        XCTAssertEqual(value.documents[0].url.utf8.count, SessionStateLimits.maximumURLBytes)
    }

    func testSelectedTabSurvivesRoundTripByFileIdentity() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevSessionSelection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("First.md")
        let second = root.appendingPathComponent("Second.md")
        try "first".write(to: first, atomically: true, encoding: .utf8)
        try "second".write(to: second, atomically: true, encoding: .utf8)

        let original = Workspace(documentIO: LocalDocumentIO(), transactionRegistry: ProcessFileTransactionRegistry())
        let pane = original.focusedPane
        try original.open(first, in: pane)
        try original.open(second, in: pane)
        let firstID = try XCTUnwrap(
            original.state(for: pane).documents.first { $0.url == first }?.id)
        original.select(firstID, in: pane)

        let data = try JSONEncoder().encode(original.snapshot())
        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
        let restored = Workspace(documentIO: LocalDocumentIO(), transactionRegistry: ProcessFileTransactionRegistry())
        restored.restore(from: decoded)

        XCTAssertEqual(restored.document(in: pane)?.url, first)
    }
}
