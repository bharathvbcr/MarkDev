//
//  WindowFocusRestorer.swift
//  MarkDevKit
//
//  Safe, one-shot restoration of the responder displaced by transient UI.
//

import AppKit

/// Retains the semantic focus destination for one transient-presentation
/// chain without retaining an AppKit view that SwiftUI has dismantled.
///
/// A pane alone is not enough: the navigator filter, navigator list, and a
/// live terminal can all be first responder while the workspace's *semantic*
/// focused pane still points at an editor. The exact responder is preferred
/// while it remains attached to the same window; the captured pane is a safe
/// fallback after view replacement or teardown.
@MainActor
public final class WindowFocusRestorer {
    public enum RestoreResult: Equatable {
        case restoredOriginalResponder
        case restoredFallback
        case nothingCaptured
    }

    private weak var capturedWindow: NSWindow?
    private weak var capturedResponder: NSResponder?
    private var fallbackPane: PaneID?
    private var hasCapture = false

    public init() {}

    /// Replaces any unconsumed capture. The presentation coordinator permits
    /// only one active chain, so retaining more than one target would make a
    /// stale responder handoff possible without adding a legal use case.
    public func capture(in window: NSWindow?, fallbackPane: PaneID?) {
        capturedWindow = window
        capturedResponder = window?.firstResponder
        self.fallbackPane = fallbackPane
        hasCapture = true
    }

    /// Restores exactly once, never moving a responder across windows.
    ///
    /// SwiftUI may dismantle the original bridge view while dismissing an
    /// overlay. Such a responder is rejected before `makeFirstResponder`; the
    /// caller then restores its semantic editor pane instead.
    @discardableResult
    public func restore(
        in currentWindow: NSWindow?,
        fallback: (PaneID?) -> Void
    ) -> RestoreResult {
        guard hasCapture else { return .nothingCaptured }

        let originalWindow = capturedWindow
        let originalResponder = capturedResponder
        let pane = fallbackPane
        clear()

        if let currentWindow,
            let originalWindow,
            currentWindow === originalWindow,
            let originalResponder,
            Self.isRestorable(originalResponder, in: currentWindow),
            currentWindow.makeFirstResponder(originalResponder)
        {
            return .restoredOriginalResponder
        }

        fallback(pane)
        return .restoredFallback
    }

    /// Invalidates a pending capture during view teardown.
    public func clear() {
        capturedWindow = nil
        capturedResponder = nil
        fallbackPane = nil
        hasCapture = false
    }

    private static func isRestorable(_ responder: NSResponder, in window: NSWindow) -> Bool {
        // Window field editors, SwiftUI focus bridges, Markdown editors, and
        // SwiftTerm's terminal surface are NSViews. Restricting restoration to
        // that concrete attached class rejects stale controller/responders and
        // makes window ownership testable before asking AppKit to install it.
        guard let view = responder as? NSView,
            view.window === window,
            !view.isHiddenOrHasHiddenAncestor,
            view.acceptsFirstResponder
        else { return false }
        return true
    }
}
