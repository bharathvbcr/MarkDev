import AppKit
import SwiftUI
import XCTest

@testable import MarkDevKit

final class SavedVaultIntegrationTests: XCTestCase {
    func testSavedVaultActionsAreReachableFromMenusPaletteAndSidebar() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let menu = try source("app/MarkDev/WorkspaceCommands.swift")
        let workspace = try source("app/MarkDev/WorkspaceView.swift")
        XCTAssertTrue(menu.contains("action: .saveVault"))
        XCTAssertTrue(menu.contains("action: .showSavedVaults"))
        XCTAssertTrue(workspace.contains("kind: .action(.saveVault)"))
        XCTAssertTrue(workspace.contains("kind: .action(.showSavedVaults)"))
        XCTAssertTrue(workspace.contains("SavedVaultsView("))
        XCTAssertTrue(workspace.contains("onOpen: { scheduleVaultOpen($0) }"),
                      "saved folders must use the existing cancellation and error-handling path")
    }
}

@MainActor
final class SavedVaultRenderingTests: XCTestCase {
    func testSavedVaultSectionRendersEmptyPopulatedCollapsedAndErrorStates() async throws {
        let suite = "MarkDev.SavedVaultRender.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SavedVaultStore(defaults: defaults)
        let narrowWidth = GlassTheme.sidebar.minimum - 2 * GlassTheme.Spacing.snug
        try await capture(store, name: "empty", expanded: true, width: narrowWidth)
        for path in ["/Users/test/Work/Notes", "/Users/test/Personal/Notes", "/Volumes/Research/研究 Notes"] {
            try store.save(URL(fileURLWithPath: path, isDirectory: true))
        }
        try await capture(store, name: "saved-light", expanded: true, width: 260)
        try await capture(store, name: "saved-narrow-dark", expanded: true, width: narrowWidth, dark: true)
        try await capture(store, name: "collapsed", expanded: false, width: narrowWidth)
        defaults.set(Data("invalid".utf8), forKey: SavedVaultStore.key)
        try await capture(SavedVaultStore(defaults: defaults), name: "unreadable", expanded: true, width: narrowWidth)
    }

    private func capture(
        _ store: SavedVaultStore, name: String, expanded: Bool, width: CGFloat, dark: Bool = false
    ) async throws {
        let view = NSHostingView(rootView:
            SavedVaultsView(
                store: store,
                currentRoot: URL(fileURLWithPath: "/Users/test/Work/Notes", isDirectory: true),
                canSave: store.vaults.isEmpty,
                isExpanded: .constant(expanded),
                onSave: {}, onOpen: { _ in }, onError: { _ in }
            )
            .frame(width: width)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 340),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = view
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(100))
        view.layoutSubtreeIfNeeded()
        let bitmap = try RenderingTestBitmap.capture(view, scale: 2)
        XCTAssertGreaterThan(RenderingTestBitmap.inkedPixels(bitmap), 100, "\(name) must draw content")
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "saved-vaults-\(name)"
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["MARKDEV_SAVED_VAULTS_RENDER_DIR"] {
            let root = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try png.write(to: root.appendingPathComponent("\(name).png"))
        }
    }
}
