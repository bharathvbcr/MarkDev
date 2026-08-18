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

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.surface = surface
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.surface = surface
        view.report()
    }

    static func dismantleNSView(_ view: ProbeView, coordinator: ()) {
        // The view is going away with its workspace. Say so, so the surface
        // stops claiming a window it no longer has.
        view.surface?.attach(nil)
        view.surface = nil
    }

    final class ProbeView: NSView {
        var surface: DocumentSurface?

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
            Task { @MainActor in DocumentInbox.shared.refresh() }
        }
    }
}
