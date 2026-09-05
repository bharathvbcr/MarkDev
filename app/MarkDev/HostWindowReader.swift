//
//  HostWindowReader.swift
//  MarkDev
//
//  Tells a workspace which window it is in, and when that changes.
//

import AppKit
import MarkDevKit
import SwiftUI

/// Reports the `NSWindow` hosting a SwiftUI workspace into its
/// ``DocumentSurface``.
///
/// SwiftUI has no way to ask "which window am I in", and the answer decides
/// where a file opened from Finder goes: a workspace whose window is on screen
/// takes documents, and one whose window has gone does not.
///
/// Separate from ``WindowCloseGuard``, which also finds the window but owns a
/// different decision — whether a close may proceed — and installs itself as
/// the window's delegate to make it. Nothing here touches the delegate.
struct HostWindowReader: NSViewRepresentable {
    let surface: DocumentSurface
    var onWindowChange: ((NSWindow?) -> Void)?

    init(
        surface: DocumentSurface,
        onWindowChange: ((NSWindow?) -> Void)? = nil
    ) {
        self.surface = surface
        self.onWindowChange = onWindowChange
    }

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.surface = surface
        view.onWindowChange = onWindowChange
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.surface = surface
        view.onWindowChange = onWindowChange
        view.report()
    }

    static func dismantleNSView(_ view: ProbeView, coordinator: ()) {
        // The view is going away with its workspace. Say so, so the surface
        // stops claiming a window it no longer has.
        view.stopObservingWindow()
        view.surface?.attach(nil)
        view.onWindowChange?(nil)
        view.surface = nil
        view.onWindowChange = nil
    }

    final class ProbeView: NSView {
        var surface: DocumentSurface?
        var onWindowChange: ((NSWindow?) -> Void)?
        private weak var observedWindow: NSWindow?
        private var screenObservers: [any NSObjectProtocol] = []

        isolated deinit {
            // The observer tokens belong to this main-actor view. An isolated
            // destructor keeps teardown on that actor even if the final
            // reference is released elsewhere.
            for observer in screenObservers {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            report()
        }

        /// Records the current window and retries any queued file open.
        ///
        /// The window is recorded at once — it is held in a plain box, not in
        /// view state, and recording it late would let two moves land out of
        /// order. The *retry* is deferred by a turn, deliberately: this runs
        /// inside SwiftUI's view-update pass, and opening a document there
        /// mutates state SwiftUI is in the middle of reading, which is the
        /// documented way to have the change silently dropped.
        func report() {
            surface?.attach(window)
            observeScreenChanges(for: window)
            // The callback mutates only AppKit window geometry, not SwiftUI
            // state, so reporting synchronously avoids an old window callback
            // landing after this probe has moved to a replacement.
            onWindowChange?(window)
            Task { @MainActor in DocumentInbox.shared.refresh() }
        }

        private func observeScreenChanges(for window: NSWindow?) {
            guard observedWindow !== window else { return }
            stopObservingWindow()
            guard let window else { return }
            observedWindow = window
            let expectedWindowID = ObjectIdentifier(window)

            let center = NotificationCenter.default
            for name in [NSWindow.didChangeScreenNotification,
                         NSWindow.didChangeScreenProfileNotification]
            {
                screenObservers.append(
                    center.addObserver(forName: name, object: window, queue: .main) {
                        [weak self] _ in
                        MainActor.assumeIsolated {
                            guard let self,
                                let eventWindow = self.observedWindow,
                                ObjectIdentifier(eventWindow) == expectedWindowID,
                                self.window === eventWindow
                            else { return }
                            self.onWindowChange?(eventWindow)
                        }
                    })
            }
            screenObservers.append(
                center.addObserver(
                    forName: NSApplication.didChangeScreenParametersNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let observedWindow = self.observedWindow,
                            self.window === observedWindow
                        else { return }
                        self.onWindowChange?(observedWindow)
                    }
                })
        }

        func stopObservingWindow() {
            for observer in screenObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            screenObservers.removeAll(keepingCapacity: true)
            observedWindow = nil
        }
    }
}
