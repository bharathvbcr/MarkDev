//
//  DocumentSurface.swift
//  MarkDevKit
//
//  Whether a window is in a state to be shown a document.
//

import AppKit

/// How usable a registered surface is for showing a document *right now*.
///
/// Ordered: a request goes to the most ready surface there is.
public enum DocumentSurfaceReadiness: Int, Comparable, Sendable {
    /// Its window has been closed, or was released. Never chosen, and purged.
    case gone = 0
    /// Registered, but its window has not been shown yet.
    ///
    /// Distinct from ``gone`` because the two look identical at the instant a
    /// window is created: SwiftUI runs `onAppear` while the window still
    /// reports `isVisible == false`. Treating that as gone would drop the
    /// registration of the window that is about to appear — the request would
    /// then open a *second* window beside the one already on its way.
    case preparing = 1
    /// A real window that is not frontmost — behind another, on another
    /// Space, or miniaturised.
    case background = 2
    /// The key window. The one the reader is looking at.
    case frontmost = 3

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The window a workspace is hosted in, and how ready it is to be handed a
/// document.
///
/// # Why a box rather than view state
///
/// The hosting window is discovered from AppKit, during SwiftUI's view-update
/// pass. Writing it into `@State` from there is the documented way to have the
/// value silently dropped, and every reader of it — the inbox asking which
/// window should take a file — needs the *current* answer rather than one
/// captured when a view body last ran. So it is a reference the view owns and
/// AppKit fills in.
///
/// # Why closing is observed rather than polled
///
/// A window that has not been shown yet and one that has been closed are the
/// same thing from the outside: `isVisible` is false for both. They must be
/// answered differently — one is worth waiting for and the other never will
/// be — and asking "has it ever been visible" only works if somebody happens
/// to ask while it is. A window shown and closed with no question in between
/// would then report itself as still on its way, and hold a document back
/// waiting for a window that has already gone. So the close is observed.
@MainActor
public final class DocumentSurface {
    /// The hosting window, while it has one. Weak: a closed window must not be
    /// kept alive by the registration that named it.
    public private(set) weak var window: NSWindow?

    /// Whether this surface has had a window on screen. Sampled whenever the
    /// window is asked about, and settled by ``hasClosed`` when it goes.
    private var hasBeenShown = false
    private var hasClosed = false
    private var closeObserver: (any NSObjectProtocol)?

    public init() {}

    deinit {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
    }

    /// Records the window this surface is hosted in, or `nil` on leaving one.
    public func attach(_ window: NSWindow?) {
        guard window !== self.window else {
            noteVisibility()
            return
        }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        self.window = window

        if let window {
            hasClosed = false
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.hasClosed = true }
            }
        }
        noteVisibility()
    }

    /// How ready this surface is, asked fresh each time.
    public var readiness: DocumentSurfaceReadiness {
        noteVisibility()
        guard let window, !hasClosed else { return departedOrPreparing }
        if window.isVisible { return window.isKeyWindow ? .frontmost : .background }
        // A miniaturised window is not visible and is not gone: it is a real
        // window that answers to `makeKeyAndOrderFront`.
        if window.isMiniaturized { return .background }
        return departedOrPreparing
    }

    /// Whether a document can be shown here at this instant.
    ///
    /// Asked again at delivery rather than trusting the readiness that chose
    /// this surface: choosing and delivering are two moments, and a window can
    /// close between them.
    public var canShowDocument: Bool { readiness >= .background }

    /// Brings the hosting window forward, so an opened document is seen.
    ///
    /// Answers whether there was a window to bring forward.
    @discardableResult
    public func bringToFront() -> Bool {
        guard canShowDocument, let window else { return false }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        return true
    }

    private var departedOrPreparing: DocumentSurfaceReadiness {
        hasBeenShown || hasClosed ? .gone : .preparing
    }

    private func noteVisibility() {
        if window?.isVisible == true { hasBeenShown = true }
    }
}
