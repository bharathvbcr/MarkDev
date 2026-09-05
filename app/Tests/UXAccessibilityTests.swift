//
//  UXAccessibilityTests.swift
//  MarkDevKitTests
//
//  Contracts for keyboard, hierarchy, sizing, and empty-state accessibility.
//

import XCTest

@testable import MarkDevKit

@MainActor
final class UXAccessibilityModelTests: XCTestCase {
    func testNavigatorContextKeepsOnlyBoundedNearestAncestors() {
        let root = URL(fileURLWithPath: "/vault")
        let longName = String(repeating: "x", count: 100)
        let node = root
            .appendingPathComponent("omitted-a")
            .appendingPathComponent("omitted-b")
            .appendingPathComponent("kept-a")
            .appendingPathComponent("kept-b")
            .appendingPathComponent(longName)
            .appendingPathComponent("Index.md")

        let location = NavigatorRowAccessibility.location(
            root: root, node: node, filteredFolder: nil)

        XCTAssertTrue(location.hasPrefix("… / kept-a / kept-b / "))
        XCTAssertFalse(location.contains("omitted-a"))
        XCTAssertLessThanOrEqual(
            location.count,
            NavigatorRowAccessibility.maximumContextComponents
                * NavigatorRowAccessibility.maximumComponentCharacters + 12)
        XCTAssertEqual(NavigatorRowAccessibility.level(for: Int.max), 49)
    }

    func testNavigatorContextCarriesLevelLocationAndDisclosureState() {
        let root = URL(fileURLWithPath: "/vault")
        let folder = root.appendingPathComponent("Projects")

        XCTAssertEqual(
            NavigatorRowAccessibility.value(
                root: root,
                node: folder,
                depth: 2,
                filteredFolder: nil,
                isDirectory: true,
                isExpanded: true),
            "Level 3, Vault root, expanded")
        XCTAssertEqual(
            NavigatorRowAccessibility.location(
                root: root,
                node: folder.appendingPathComponent("Index.md"),
                filteredFolder: "Clients/Acme/Projects/2026"),
            "… / Acme / Projects / 2026")
    }

    func testSelectionSummaryIncludesCharactersAndCharacterOnlySelections() {
        XCTAssertEqual(
            StatusBarSelectionDescription.make(
                selectedWords: 3, selectedCharacters: 14, totalWords: 20),
            "3 of 20 words · 14 characters selected")
        XCTAssertEqual(
            StatusBarSelectionDescription.make(
                selectedWords: 0, selectedCharacters: 4, totalWords: 20),
            "0 of 20 words · 4 characters selected")
        XCTAssertNil(
            StatusBarSelectionDescription.make(
                selectedWords: 0, selectedCharacters: 0, totalWords: 20))
    }

    func testGraphDistinguishesNoVaultFromAnOpenEmptyVault() {
        XCTAssertEqual(
            GraphPanel.emptyReason(hasOpenVault: false, noteCount: 0, tag: nil),
            "No vault open.")
        XCTAssertEqual(
            GraphPanel.emptyReason(hasOpenVault: true, noteCount: 0, tag: nil),
            "This vault has no notes yet.")
        XCTAssertEqual(
            GraphPanel.emptyReason(hasOpenVault: true, noteCount: 2, tag: "work"),
            "No notes tagged work.")
    }

    func testSplitDividerValueIsBoundedAndRejectsInvalidGeometry() {
        XCTAssertEqual(
            SplitDividerAccessibility.value(
                fractions: [0.25, 0.25, 0.5], dividerAfter: 1, axis: .horizontal),
            "50% from the left")
        XCTAssertEqual(
            SplitDividerAccessibility.value(
                fractions: [0.8, 0.8], dividerAfter: 0, axis: .vertical),
            "80% from the top")
        XCTAssertNil(
            SplitDividerAccessibility.value(
                fractions: [.nan, 1], dividerAfter: 0, axis: .horizontal))
        XCTAssertNil(
            SplitDividerAccessibility.value(
                fractions: [1], dividerAfter: 0, axis: .horizontal))
    }

    func testPaletteWidthNeverExceedsItsFiniteContainer() {
        XCTAssertEqual(CommandPaletteLayout.width(availableWidth: 360), 360)
        XCTAssertEqual(CommandPaletteLayout.width(availableWidth: 800), 560)
        XCTAssertEqual(CommandPaletteLayout.width(availableWidth: .nan), 560)
        XCTAssertEqual(CommandPaletteLayout.width(availableWidth: -1), 560)
    }
}

/// Source contracts cover SwiftUI semantics that have no public inspection
/// API without launching an accessibility process. Each assertion names a
/// modifier whose absence recreated the audited production gap.
final class UXAccessibilitySourceContractTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(path),
            encoding: .utf8)
    }

    func testEmptyVaultOffersTheWiredNewNoteAction() throws {
        let navigator = try source("app/MarkDevKit/Navigator/NavigatorView.swift")
        XCTAssertTrue(navigator.contains("onCreateNote(root)"))
        XCTAssertTrue(navigator.contains("navigator.empty.new-note"))
    }

    func testTerminalTabsRetainKeyboardAndAccessibilityActions() throws {
        let terminal = try source("app/MarkDevKit/Terminal/TerminalDrawer.swift")
        XCTAssertTrue(terminal.contains(".focusable()"))
        XCTAssertTrue(terminal.contains(".accessibilityAction(.default)"))
        XCTAssertTrue(terminal.contains(".accessibilityHidden(false)"))
        XCTAssertTrue(terminal.contains(".accessibilityAddTraits(isSelected ? [.isButton, .isSelected]"))
    }

    func testResizeResetAndCloseTargetsRemainExplicit() throws {
        let resize = try source("app/MarkDevKit/Design/ResizeHandle.swift")
        let tabs = try source("app/MarkDevKit/Workspace/PaneTabBar.swift")
        XCTAssertTrue(resize.contains(".accessibilityAction(named: \"Reset Size\")"))
        XCTAssertTrue(resize.contains("isEnabled: valueDescription != nil"))
        XCTAssertTrue(tabs.contains(".controlTarget(Circle(), padding: 4)"))
    }

    func testPaletteDoesNotRestoreTheFixedWidthRegression() throws {
        let palette = try source("app/MarkDevKit/Workspace/CommandPalette.swift")
        XCTAssertFalse(palette.contains(".frame(width: 560)"))
        XCTAssertTrue(palette.contains(".containerRelativeFrame(.horizontal)"))
    }
}
