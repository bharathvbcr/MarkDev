//
//  EditorSurfaceRegistryTests.swift
//  MarkDevKitTests
//

import XCTest

@testable import MarkDevKit

@MainActor
final class EditorSurfaceRegistryTests: XCTestCase {
    func testStaleUnmountAndFocusProofCannotAffectReplacement() {
        let registry = EditorSurfaceRegistry()
        let pane = PaneID()
        let first = MarkdownTextView.make()
        let replacement = MarkdownTextView.make()

        let firstToken = registry.mount(first, in: pane)
        let replacementToken = registry.mount(replacement, in: pane)

        XCTAssertFalse(registry.isCurrent(firstToken, surface: first, in: pane))
        XCTAssertFalse(registry.unmount(firstToken, surface: first, in: pane))
        XCTAssertTrue(registry.isCurrent(replacementToken, surface: replacement, in: pane))
        XCTAssertTrue(registry.surface(in: pane) === replacement)
        XCTAssertTrue(registry.unmount(replacementToken, surface: replacement, in: pane))
        XCTAssertNil(registry.surface(in: pane))
        XCTAssertFalse(registry.unmount(replacementToken, surface: replacement, in: pane))
    }

    func testWritingToolsDetachOnlyTheExactFocusedSurface() {
        let tools = WritingTools()
        let first = MarkdownTextView.make()
        let replacement = MarkdownTextView.make()

        tools.attach(to: first)
        tools.attach(to: replacement)
        tools.detach(from: first)
        XCTAssertTrue(tools.inline.surface === replacement)
        XCTAssertTrue(tools.document.surface === replacement)
        XCTAssertTrue(tools.harness.surface === replacement)

        tools.detach(from: replacement)
        XCTAssertNil(tools.inline.surface)
        XCTAssertNil(tools.document.surface)
        XCTAssertNil(tools.harness.surface)
    }

    func testPruneDropsOnlyOrphanedPaneMounts() {
        let registry = EditorSurfaceRegistry()
        let keptPane = PaneID()
        let removedPane = PaneID()
        let kept = MarkdownTextView.make()
        let removed = MarkdownTextView.make()
        _ = registry.mount(kept, in: keptPane)
        _ = registry.mount(removed, in: removedPane)

        registry.prune(keeping: [keptPane])

        XCTAssertTrue(registry.surface(in: keptPane) === kept)
        XCTAssertNil(registry.surface(in: removedPane))
    }
}
