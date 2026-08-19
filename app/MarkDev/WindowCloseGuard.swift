//
//  WindowCloseGuard.swift
//  MarkDev
//
//  Routes window close and application termination through the same
//  unsaved-document review used by tab and pane closure.
//

import AppKit
import MarkDevKit
import SwiftUI

@MainActor
private protocol WindowCloseReviewing: AnyObject {
    func reviewClose() -> Bool
}

/// Weak registry used only for application termination. Window close itself
/// travels through `NSWindowDelegate`; Quit has no SwiftUI view callback, so
/// the application delegate asks every live window reviewer directly.
@MainActor
private final class WindowCloseRegistry {
    static let shared = WindowCloseRegistry()

    private final class WeakReviewer {
        weak var value: (any WindowCloseReviewing)?

        init(_ value: any WindowCloseReviewing) {
            self.value = value
        }
    }

    private var reviewers: [ObjectIdentifier: WeakReviewer] = [:]
    private(set) var terminationApproved = false

    func register(_ reviewer: any WindowCloseReviewing) {
        reviewers[ObjectIdentifier(reviewer)] = WeakReviewer(reviewer)
        removeReleasedReviewers()
    }

    func unregister(_ reviewer: any WindowCloseReviewing) {
        reviewers[ObjectIdentifier(reviewer)] = nil
    }

    func reviewForTermination() -> Bool {
        terminationApproved = false
        removeReleasedReviewers()
        for reviewer in reviewers.values.compactMap(\.value) {
            guard reviewer.reviewClose() else { return false }
        }
        terminationApproved = true
        return true
    }

    private func removeReleasedReviewers() {
        reviewers = reviewers.filter { $0.value.value != nil }
    }
}

/// Makes a SwiftUI window participate in AppKit's close decision without
/// replacing behavior owned by SwiftUI's private window delegate.
struct WindowCloseGuard: NSViewRepresentable {
    let shouldClose: @MainActor () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(shouldClose: shouldClose)
    }

    func makeNSView(context: Context) -> WindowProbeView {
        let view = WindowProbeView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ view: WindowProbeView, context: Context) {
        context.coordinator.shouldClose = shouldClose
        context.coordinator.install(on: view.window)
    }

    static func dismantleNSView(_ view: WindowProbeView, coordinator: Coordinator) {
        coordinator.uninstall()
        view.coordinator = nil
    }

    final class WindowProbeView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.install(on: window)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate, WindowCloseReviewing {
        var shouldClose: @MainActor () -> Bool
        private weak var window: NSWindow?
        // NSObject's forwarding hooks are nonisolated overrides even though
        // NSWindow delegates are main-actor bound. Access is still confined
        // to AppKit's main thread; this annotation bridges that mismatch.
        nonisolated(unsafe) private weak var originalDelegate: (any NSWindowDelegate)?

        init(shouldClose: @escaping @MainActor () -> Bool) {
            self.shouldClose = shouldClose
        }

        func install(on newWindow: NSWindow?) {
            guard let newWindow, window !== newWindow else { return }
            uninstall()
            window = newWindow
            originalDelegate = newWindow.delegate
            newWindow.delegate = self
            WindowCloseRegistry.shared.register(self)
        }

        func uninstall() {
            if let window, window.delegate === self {
                window.delegate = originalDelegate
            }
            WindowCloseRegistry.shared.unregister(self)
            window = nil
            originalDelegate = nil
        }

        func reviewClose() -> Bool {
            shouldClose()
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            let approved = WindowCloseRegistry.shared.terminationApproved || reviewClose()
            guard approved else { return false }
            return originalDelegate?.windowShouldClose?(sender) ?? true
        }

        // SwiftUI owns other window-delegate behavior. Forward every selector
        // this proxy does not implement so resize, focus, and restoration hooks
        // remain intact.
        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || originalDelegate?.responds(to: selector) == true
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            if originalDelegate?.responds(to: selector) == true {
                return originalDelegate
            }
            return super.forwardingTarget(for: selector)
        }
    }
}

@MainActor
final class MarkDevApplicationDelegate: NSObject, NSApplicationDelegate {
    /// Watches for a window becoming key, so a file waiting for somewhere to
    /// go is retried the moment there is somewhere.
    ///
    /// The inbox cannot see this for itself: readiness is answered by AppKit,
    /// and nothing in SwiftUI reports "a window is now on screen".
    private var keyWindowObserver: (any NSObjectProtocol)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { DocumentInbox.shared.refresh() }
        }
    }

    /// Clicking the Dock icon with no windows open must bring one back.
    ///
    /// Returning true is the whole of it: AppKit reopens the window group
    /// itself. Asking ``DocumentInbox`` for a window here *as well* — which
    /// looks like belt and braces — opens two windows on every Dock click,
    /// measured. The inbox's own request is for the other case: a document
    /// arriving when there is no window and no reopen to piggyback on.
    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool
    ) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        WindowCloseRegistry.shared.reviewForTermination() ? .terminateNow : .terminateCancel
    }

    /// Ends every shell the app forked.
    ///
    /// A terminal's process used to die with the view that hosted it. It no
    /// longer does — the pty is owned by ``TerminalSessions`` so the terminal
    /// can be moved between the drawer and the sidebar without restarting — so
    /// the guarantee has to be restated at the two points a view teardown used
    /// to cover. The window's is in `WorkspaceView.onDisappear`; this is the
    /// other, and it is the one that matters most, because Quit is how a Mac
    /// app usually ends and a shell orphaned there outlives everything that
    /// could find it.
    func applicationWillTerminate(_ notification: Notification) {
        LiveShells.shared.endAll()
    }

    /// Receives files opened from Finder, the Dock, or `open`.
    ///
    /// This is the hook, not SwiftUI's `onOpenURL`: that covers URL schemes,
    /// while Launch Services delivers *file* opens here. Without it MarkDev
    /// was ranked `Owner` of every Markdown document on the machine and
    /// answered a double-click by showing an empty untitled window — the one
    /// thing a default Markdown app must not do.
    ///
    /// The request usually arrives before any window exists, so it is queued
    /// rather than acted on; see ``DocumentInbox``.
    func application(_ application: NSApplication, open urls: [URL]) {
        DocumentInbox.shared.receive(urls)
    }

}
