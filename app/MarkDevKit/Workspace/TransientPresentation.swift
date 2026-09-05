//
//  TransientPresentation.swift
//  MarkDevKit
//
//  One arbitration boundary for every window-owned transient surface.
//

import Foundation

/// A transient surface that temporarily owns a workspace window's attention.
///
/// Keeping these cases closed and typed makes overlap unrepresentable. SwiftUI
/// overlays, close/destructive sheets, and errors all render from the one
/// active value instead of maintaining independent Booleans that can become
/// true together.
public enum WorkspaceTransientPresentation: Equatable, Sendable {
    case commandPalette
    case peek(URL)
    case graph
    case nativePanel(UUID)
    case closeReview(UUID)
    case destructivePrompt(UUID)
    case destructiveOperation(id: UUID, title: String)
    case error(String)

    public var isOverlay: Bool {
        switch self {
        case .commandPalette, .peek, .graph: true
        case .nativePanel, .closeReview, .destructivePrompt, .destructiveOperation, .error: false
        }
    }

    public var blocksWorkspaceInteraction: Bool {
        if case .destructiveOperation = self { return true }
        return false
    }

    /// Whether the workspace window, rather than a focus-owning child view,
    /// consumes Escape for this presentation.
    ///
    /// Sheets, alerts, and destructive consent keep the platform's own cancel
    /// semantics. Only lightweight overlays are dismissed here, so an Escape
    /// intended for an editor operation is never swallowed while no overlay
    /// is visible.
    public var dismissesOnEscape: Bool {
        switch self {
        case .commandPalette, .peek, .graph: true
        case .nativePanel, .closeReview, .destructivePrompt, .destructiveOperation, .error:
            false
        }
    }

    /// Whether this presentation is the only content VoiceOver should expose
    /// in its window.
    ///
    /// The palette has a modal scrim and keyboard capture; the destructive
    /// progress surface blocks every workspace action. Graph and Peek remain
    /// deliberately modeless, while platform sheets and alerts supply their
    /// own accessibility modality.
    public var hidesWorkspaceAccessibility: Bool {
        switch self {
        case .commandPalette, .destructiveOperation: true
        case .peek, .graph, .nativePanel, .closeReview, .destructivePrompt, .error: false
        }
    }

    public var closeReviewID: UUID? {
        switch self {
        case .closeReview(let id), .destructivePrompt(let id): id
        case .commandPalette, .peek, .graph, .nativePanel, .destructiveOperation, .error: nil
        }
    }
}

/// Pure transition system for a workspace window's transient UI.
///
/// A UUID is used for every activation and focus-restoration intent. Unlike a
/// wrapping integer revision, an old dismissal cannot become current again
/// after enough transitions. Callers still compare the complete token and
/// fail closed if an injected/test UUID is reused.
public struct TransientPresentationCoordinator: Sendable {
    public struct Generation: Hashable, Sendable {
        public let id: UUID

        public init(id: UUID = UUID()) { self.id = id }
    }

    public struct Active: Equatable, Sendable {
        public let generation: Generation
        public let presentation: WorkspaceTransientPresentation
        public let restoreFocusTo: PaneID?
    }

    public struct FocusRestorationIntent: Equatable, Sendable {
        public let id: UUID
        public let pane: PaneID?

        public init(id: UUID = UUID(), pane: PaneID?) {
            self.id = id
            self.pane = pane
        }
    }

    public enum PresentationResult: Equatable, Sendable {
        case presented(Generation)
        case replaced(previous: Generation, current: Generation)
        case alreadyPresented(Generation)
        case deferredError
        case refused
    }

    public enum DismissalResult: Equatable, Sendable {
        case ignored
        case advancedToDeferredError(Generation)
        case restoreFocus(FocusRestorationIntent)
    }

    public private(set) var active: Active?
    public private(set) var pendingFocusRestoration: FocusRestorationIntent?
    private var deferredError: String?

    public init() {}

    public var errorMessage: String? {
        guard case .error(let message) = active?.presentation else { return nil }
        return message
    }

    public var isPerformingDestructiveOperation: Bool {
        guard case .destructiveOperation = active?.presentation else { return false }
        return true
    }

    /// Presents an overlay or review prompt under the legal priority rules.
    ///
    /// Overlays may replace one another. A protected presentation preempts an
    /// overlay while inheriting its original focus target. Nothing preempts a
    /// protected presentation; an error is retained as one bounded deferred
    /// message and everything else is refused.
    @discardableResult
    public mutating func present(
        _ presentation: WorkspaceTransientPresentation,
        restoringFocusTo pane: PaneID?,
        generation: Generation = Generation()
    ) -> PresentationResult {
        switch presentation {
        case .destructiveOperation, .error:
            // These states have narrower transition APIs below. Refusing them
            // here makes bypassing consent or error priority unrepresentable.
            return .refused
        case .commandPalette, .peek, .graph, .nativePanel, .closeReview, .destructivePrompt:
            break
        }
        pendingFocusRestoration = nil
        guard let current = active else {
            active = Active(
                generation: generation,
                presentation: presentation,
                restoreFocusTo: pane)
            return .presented(generation)
        }
        if current.presentation == presentation {
            return .alreadyPresented(current.generation)
        }
        if current.presentation.isOverlay {
            active = Active(
                generation: generation,
                presentation: presentation,
                restoreFocusTo: current.restoreFocusTo ?? pane)
            return .replaced(previous: current.generation, current: generation)
        }
        return .refused
    }

    /// Presents an error explicitly. It preempts an overlay, presents from
    /// idle, or waits behind one protected review/operation. It can never
    /// silently replace a close or destructive decision.
    @discardableResult
    public mutating func presentError(
        _ message: String,
        restoringFocusTo pane: PaneID?,
        generation: Generation = Generation()
    ) -> PresentationResult {
        pendingFocusRestoration = nil
        guard let current = active else {
            active = Active(
                generation: generation,
                presentation: .error(message),
                restoreFocusTo: pane)
            return .presented(generation)
        }
        if current.presentation.isOverlay {
            active = Active(
                generation: generation,
                presentation: .error(message),
                restoreFocusTo: current.restoreFocusTo ?? pane)
            return .replaced(previous: current.generation, current: generation)
        }
        if case .error = current.presentation { return .refused }
        if deferredError == nil { deferredError = message }
        return .deferredError
    }

    /// Advances only the exact destructive prompt into the operation bearing
    /// the same approval identity. No other protected state has an API that
    /// can become a destructive operation.
    @discardableResult
    public mutating func beginDestructiveOperation(
        promptID: UUID,
        generation expected: Generation,
        title: String,
        generation replacement: Generation = Generation()
    ) -> PresentationResult {
        guard let current = active,
            current.generation == expected,
            current.presentation == .destructivePrompt(promptID)
        else { return .refused }
        active = Active(
            generation: replacement,
            presentation: .destructiveOperation(id: promptID, title: title),
            restoreFocusTo: current.restoreFocusTo)
        pendingFocusRestoration = nil
        return .replaced(previous: expected, current: replacement)
    }

    /// Dismisses only the exact activation named by `generation`.
    ///
    /// If an error arrived while a protected sheet was active it advances
    /// directly to that alert. Focus is restored only after the final member
    /// of the presentation chain is gone.
    @discardableResult
    public mutating func dismiss(_ generation: Generation) -> DismissalResult {
        guard let current = active, current.generation == generation else {
            return .ignored
        }
        if let deferredError {
            self.deferredError = nil
            let next = Generation()
            active = Active(
                generation: next,
                presentation: .error(deferredError),
                restoreFocusTo: current.restoreFocusTo)
            return .advancedToDeferredError(next)
        }
        active = nil
        let intent = FocusRestorationIntent(pane: current.restoreFocusTo)
        pendingFocusRestoration = intent
        return .restoreFocus(intent)
    }

    /// Clears an active or deferred error without disturbing another protected
    /// presentation. Returns a focus result only when the visible alert ended.
    @discardableResult
    public mutating func clearError() -> DismissalResult {
        deferredError = nil
        guard let active, case .error = active.presentation else { return .ignored }
        return dismiss(active.generation)
    }

    /// Consumes a still-current restoration intent exactly once. Beginning a
    /// later presentation invalidates it before a deferred AppKit responder
    /// handoff can steal focus back.
    @discardableResult
    public mutating func consumeFocusRestoration(
        _ intent: FocusRestorationIntent
    ) -> Bool {
        guard pendingFocusRestoration == intent, active == nil else { return false }
        pendingFocusRestoration = nil
        return true
    }

    /// View teardown invalidates every activation, deferred error, and focus
    /// callback. Later sheet or animation callbacks are therefore inert.
    public mutating func invalidateAll() {
        active = nil
        deferredError = nil
        pendingFocusRestoration = nil
    }
}
