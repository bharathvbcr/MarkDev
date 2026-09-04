//
//  ShortcutContractTests.swift
//  MarkDevKitTests
//
//  Visible shortcut documentation must match the native menu assignment.
//

import XCTest

final class ShortcutContractTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // app
            .deletingLastPathComponent() // repository
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8)
    }

    /// `source` with `//` comment lines removed.
    private func code(_ relativePath: String) throws -> String {
        try source(relativePath)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    func testGraphAndFindPreviousUseDistinctNativeShortcutsEverywhereTheyAreShown() throws {
        let menu = try source("app/MarkDev/WorkspaceCommands.swift")
        let palette = try source("app/MarkDev/WorkspaceView.swift")
        let settings = try source("app/MarkDev/SettingsView.swift")
        let readme = try source("README.md")

        XCTAssertTrue(
            menu.contains(
                "\"Graph View\", action: .toggleGraph, key: \"g\", modifiers: [.command, .option]"),
            "Graph View must own Option-Command-G in the native menu")
        XCTAssertTrue(
            menu.contains(".keyboardShortcut(\"g\", modifiers: [.command, .shift])"),
            "Find Previous keeps the platform-standard Shift-Command-G")
        XCTAssertTrue(
            palette.contains("kind: .action(.toggleGraph), shortcut: \"⌥⌘G\")"),
            "the palette must advertise the native menu chord")
        XCTAssertTrue(settings.contains("\"⌥⌘I / ⌥⌘G\""))
        XCTAssertTrue(readme.contains("| `⌥ ⌘ G` | Toggle Vault Graph View |"))
        XCTAssertTrue(readme.contains("| `⌘ G` / `⇧ ⌘ G` | Find Next / Previous Match |"))
        XCTAssertFalse(
            menu.contains(
                "\"Graph View\", action: .toggleGraph, key: \"g\", modifiers: [.command, .shift]"),
            "one key event cannot safely name two visible commands")
    }

    /// The menu bar must not carry two menus with the same name.
    ///
    /// `CommandMenu("View")` does not add to the View menu AppKit already
    /// provides — it declares a *second* one. The bar then read
    /// "File Edit View View Editor", with Zoom In in one and Enter Full Screen
    /// in the other, and no way for a reader to know which to open. Verified
    /// against the running app through the accessibility hierarchy; pinned
    /// here because that check needs a launched app and this one does not.
    func testNoCommandMenuDuplicatesAMenuAppKitAlreadyProvides() throws {
        // Comments stripped: this file explains the bug it is guarding, and
        // the explanation necessarily spells the offending call out. A text
        // contract that reads its own rationale as a violation is a test that
        // fails for writing itself down.
        let menu = try code("app/MarkDev/WorkspaceCommands.swift")

        // The menus macOS builds for every app. Declaring a `CommandMenu` with
        // one of these names appends a duplicate rather than merging into it.
        for provided in ["File", "Edit", "View", "Window", "Help"] {
            XCTAssertFalse(
                menu.contains("CommandMenu(\"\(provided)\")"),
                "a CommandMenu named \(provided) is a second \(provided) menu; "
                    + "use CommandGroup with the matching placement instead")
        }

        XCTAssertTrue(
            menu.contains("CommandGroup(after: .toolbar)"),
            "the zoom commands must join the existing View menu")
        for item in ["Zoom In", "Zoom Out", "Actual Size"] {
            XCTAssertTrue(menu.contains("\"\(item)\""), "\(item) must still be offered")
        }
    }

    /// The Help menu must not be an item that only reports its own absence.
    ///
    /// AppKit's default looks for a help book; MarkDev ships none, so
    /// "MarkDev Help" did nothing but raise "Help isn't available".
    func testTheHelpMenuPointsAtDocumentationThatExists() throws {
        let code = try code("app/MarkDev/WorkspaceCommands.swift")
        XCTAssertTrue(
            code.contains("CommandGroup(replacing: .help)"),
            "the default help item has no help book to open")
        XCTAssertTrue(code.contains("MarkDev Documentation"))

        // The destination is a path this repository actually contains, so the
        // menu cannot point at a page that was renamed away.
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: repositoryRoot.appendingPathComponent("docs/README.md").path),
            "the Help menu names docs/README.md; it must exist")
        XCTAssertTrue(code.contains("docs/README.md"))
    }
}
