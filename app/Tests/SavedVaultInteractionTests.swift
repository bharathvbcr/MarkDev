import AppKit
import SwiftUI
import XCTest

@testable import MarkDevKit

@MainActor
final class SavedVaultInteractionTests: XCTestCase {
    func testNativeControlsSaveOpenAndRemoveTheIntendedVault() async throws {
        let suite = "MarkDev.SavedVaultInteraction.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SavedVaultStore(defaults: defaults)
        let root = URL(fileURLWithPath: "/Users/test/Work/Notes", isDirectory: true)
        let other = URL(fileURLWithPath: "/Users/test/Personal/Notes", isDirectory: true)
        var opened: [URL] = []
        var errors: [String] = []
        let view = NSHostingView(rootView: SavedVaultsView(
            store: store, currentRoot: root, canSave: true, isExpanded: .constant(true),
            onSave: {
                do { try store.save(root) }
                catch { errors.append(error.localizedDescription) }
            },
            onOpen: { opened.append($0) },
            onError: { errors.append($0) }
        ).frame(width: 260)
            // Logic tests have no system accessibility client to activate
            // SwiftUI's accessibility tree.
            .environment(\.accessibilityEnabled, true))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 340),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await settle(view)
        let save = try XCTUnwrap(elements(in: view).first {
            $0.accessibilityIdentifier?() == "vaults.saveCurrent"
        })
        XCTAssertTrue(save.accessibilityPerformPress?() ?? false)
        try await settle(view)
        XCTAssertTrue(store.contains(root), "pressing Save must change the real store")
        try store.save(other)
        try await settle(view)
        // The logic-test host does not expose SwiftUI's scroll contents in its
        // accessibility tree. Send native window events to the rendered first
        // row instead, retaining assertions on the actual actions' effects.
        let scroll = try XCTUnwrap(elements(in: view).compactMap { $0 as? NSScrollView }.first)
        try clickFirstRow(in: scroll, window: window, remove: false)
        try await settle(view)
        XCTAssertEqual(opened, [other], "same-named folders must open their own URL")

        try clickFirstRow(in: scroll, window: window, remove: true)
        try await settle(view)
        XCTAssertTrue(store.contains(root))
        XCTAssertFalse(store.contains(other))
        XCTAssertEqual(SavedVaultStore(defaults: defaults).vaults, store.vaults)
        XCTAssertTrue(errors.isEmpty, errors.joined(separator: "\n"))
    }

    private func settle(_ view: NSView) async throws {
        try await Task.sleep(for: .milliseconds(100))
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
    }

    // SwiftUI's nodes implement these Objective-C selectors without declaring
    // the full NSAccessibilityProtocol conformance. Optional selector dispatch
    // preserves those nodes without an unchecked protocol cast.
    private func elements(in root: NSObject) -> [AnyObject] {
        var pending: [AnyObject] = [root]
        var result: [AnyObject] = []
        var seen: Set<ObjectIdentifier> = []
        while let element = pending.popLast(), result.count < 256 {
            guard seen.insert(ObjectIdentifier(element)).inserted else { continue }
            result.append(element)
            let children = element.accessibilityChildren?() as? [NSObject] ?? []
            pending.append(contentsOf: children)
            if let native = element as? NSView {
                pending.append(contentsOf: native.subviews)
            }
        }
        XCTAssertTrue(pending.isEmpty, "the accessibility traversal must not silently truncate")
        return result
    }

    private func clickFirstRow(in scroll: NSScrollView, window: NSWindow, remove: Bool) throws {
        let document = try XCTUnwrap(scroll.documentView)
        let point = NSPoint(
            x: remove ? document.bounds.maxX - 14 : document.bounds.midX,
            y: document.isFlipped ? document.bounds.minY + 24 : document.bounds.maxY - 24)
        let location = document.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
        }
    }
}
