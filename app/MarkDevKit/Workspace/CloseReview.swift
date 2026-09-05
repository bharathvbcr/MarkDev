//
//  CloseReview.swift
//  MarkDevKit
//
//  Typed, non-blocking close-review state shared by every UI close path.
//

import Foundation
import Observation

/// The persistence facts that make a document unsafe to close silently.
public enum DocumentPersistenceRisk: Equatable, Sendable {
    /// The in-memory text is newer than the last authoritative file contents.
    case edited
    /// The saved bytes are visible, but the containing-directory sync was not
    /// confirmed. Rewriting the text is not the only available repair.
    case durabilityUnconfirmed
    /// New edits exist on top of a save whose directory sync was unconfirmed.
    case editedAndDurabilityUnconfirmed
}

/// Every response a document close-review sheet may offer.
public enum DocumentCloseReviewAction: Hashable, Sendable {
    case save
    case retryDurability
    case saveAgain
    case closeAnyway
    case cancel

    public var label: String {
        switch self {
        case .save: "Save"
        case .retryDurability: "Retry Durability"
        case .saveAgain: "Save Again"
        case .closeAnyway: "Close Anyway"
        case .cancel: "Cancel"
        }
    }
}

/// Copy and action ordering for one document close decision.
///
/// This is a value rather than strings assembled by the SwiftUI sheet. It
/// keeps tab, pane, window, and Quit on one policy, and makes the
/// durability-only case impossible to accidentally present as unsaved text.
public struct DocumentPersistencePresentation: Identifiable, Equatable, Sendable {
    public let documentID: OpenDocument.ID
    public let title: String
    public let risk: DocumentPersistenceRisk
    public let headline: String
    public let detail: String
    public let actions: [DocumentCloseReviewAction]

    public var id: OpenDocument.ID { documentID }

    /// Returns `nil` for a document that can be closed without review.
    public init?(document: OpenDocument) {
        guard document.requiresCloseReview else { return nil }

        documentID = document.id
        title = document.title
        switch (document.hasUnsavedChanges, document.hasUnconfirmedDurability) {
        case (true, false):
            risk = .edited
            headline = "Save changes to \(document.title)?"
            detail = "Closing anyway will discard edits that have not been saved."
            actions = [.save, .closeAnyway, .cancel]
        case (false, true):
            risk = .durabilityUnconfirmed
            headline = "Confirm \(document.title) is safely stored?"
            detail =
                "The saved bytes are visible, but MarkDev could not confirm that the "
                + "containing directory was synchronized."
            actions = [.retryDurability, .saveAgain, .closeAnyway, .cancel]
        case (true, true):
            risk = .editedAndDurabilityUnconfirmed
            headline = "Save \(document.title) again before closing?"
            detail =
                "This document has new edits, and the previous save's directory sync "
                + "is still unconfirmed."
            actions = [.saveAgain, .closeAnyway, .cancel]
        case (false, false):
            return nil
        }
    }
}

/// Responses to the final, destructive confirmation after every affected
/// document has completed its own persistence review.
public enum VaultTrashReviewAction: Hashable, Sendable {
    case moveToTrash
    case cancel

    public var label: String {
        switch self {
        case .moveToTrash: "Move to Trash"
        case .cancel: "Cancel"
        }
    }
}

/// The destructive prompt identity together with the reader's response.
/// Keeping the identity lets the UI advance only that exact approved prompt
/// into its filesystem-operation state.
public struct VaultTrashDecision: Equatable, Sendable {
    public let promptID: UUID
    public let action: VaultTrashReviewAction

    public init(promptID: UUID, action: VaultTrashReviewAction) {
        self.promptID = promptID
        self.action = action
    }
}

/// Copy for one vault-item Trash decision.
///
/// Document-save choices remain separate prompts: this confirmation says
/// exactly what will happen to the filesystem only after those choices have
/// settled and been revalidated.
public struct VaultTrashPresentation: Equatable, Sendable {
    public let targetName: String
    public let affectedDocumentCount: Int

    public init(targetName: String, affectedDocumentCount: Int) {
        self.targetName = targetName
        self.affectedDocumentCount = max(0, affectedDocumentCount)
    }

    public var headline: String { "Move \(targetName) to the Trash?" }

    public var detail: String {
        switch affectedDocumentCount {
        case 0:
            return "The item will leave this vault and can be recovered from the Trash."
        case 1:
            return
                "Its open document will close after the item is moved. "
                + "The item can be recovered from the Trash."
        default:
            return
                "\(affectedDocumentCount) open documents will close after the item is moved. "
                + "The item can be recovered from the Trash."
        }
    }

    public let actions: [VaultTrashReviewAction] = [.moveToTrash, .cancel]
}

/// Exact document set authorized for a destructive operation.
///
/// `reviewedDocuments` may contain the post-save version of any risky member;
/// every unreviewed member must remain byte-for-byte model-equal to its
/// original snapshot. Duplicate identities and reviews for documents outside
/// the target set are rejected rather than hidden by a dictionary overwrite.
public struct DestructiveDocumentApproval: Equatable, Sendable {
    public let documents: [OpenDocument]

    public init?(
        originalDocuments: [OpenDocument],
        reviewedDocuments: [OpenDocument]
    ) {
        let originalIDs = originalDocuments.map(\.id)
        let reviewedIDs = reviewedDocuments.map(\.id)
        guard Set(originalIDs).count == originalIDs.count,
            Set(reviewedIDs).count == reviewedIDs.count,
            Set(reviewedIDs).isSubset(of: Set(originalIDs))
        else { return nil }

        let reviewedByID = Dictionary(
            uniqueKeysWithValues: reviewedDocuments.map { ($0.id, $0) })
        documents = originalDocuments.map { reviewedByID[$0.id] ?? $0 }
    }

    public func isCurrent(_ currentDocuments: [OpenDocument]) -> Bool {
        currentDocuments == documents
    }
}

/// One exact running terminal generation that a close decision is about.
///
/// Titles are presentation only and deliberately do not participate in
/// equality. Shells update their title at every prompt; that must not
/// invalidate consent for the same process generation.
public struct TerminalCloseRisk: Identifiable, Sendable {
    public struct ID: Hashable, Sendable {
        public let sessionID: TerminalSessionState.ID
        public let generation: Int

        public init(sessionID: TerminalSessionState.ID, generation: Int) {
            self.sessionID = sessionID
            self.generation = generation
        }
    }

    public let id: ID
    public let title: String

    public init(sessionID: TerminalSessionState.ID, generation: Int, title: String) {
        id = ID(sessionID: sessionID, generation: generation)
        self.title = title
    }
}

extension TerminalCloseRisk: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

extension TerminalCloseRisk: Hashable {
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

public enum TerminalCloseReviewAction: Hashable, Sendable {
    case stopAndClose
    case stopAndRestart
    case cancel

    public var label: String {
        switch self {
        case .stopAndClose: "Stop Terminals and Close"
        case .stopAndRestart: "Stop and Restart"
        case .cancel: "Cancel"
        }
    }
}

/// The destructive operation that follows terminal consent.
public enum TerminalClosePurpose: Equatable, Sendable {
    case closeSessions
    case restartSession
    case closeWindow
}

/// Copy for a review of one or more exact live terminal generations.
public struct TerminalClosePresentation: Equatable, Sendable {
    public let risks: [TerminalCloseRisk]
    public let purpose: TerminalClosePurpose

    public init?(
        risks: [TerminalCloseRisk],
        purpose: TerminalClosePurpose = .closeSessions
    ) {
        guard !risks.isEmpty else { return nil }
        guard purpose != .restartSession || risks.count == 1 else { return nil }
        self.risks = risks
        self.purpose = purpose
    }

    public var headline: String {
        switch purpose {
        case .restartSession:
            return "Restart the running terminal?"
        case .closeSessions:
            return risks.count == 1
                ? "Stop and close the running terminal?"
                : "Stop and close \(risks.count) running terminals?"
        case .closeWindow:
            return risks.count == 1
                ? "Stop the running terminal before closing?"
                : "Stop \(risks.count) running terminals before closing?"
        }
    }

    public var detail: String {
        let operation = purpose == .restartSession ? "Restarting" : "Closing"
        if risks.count == 1, let title = risks.first?.title {
            return "\(operation) will end \(title) and every process it started."
        }
        return "\(operation) will end these terminals and every process they started."
    }

    public var actions: [TerminalCloseReviewAction] {
        switch purpose {
        case .restartSession: [.stopAndRestart, .cancel]
        case .closeSessions, .closeWindow: [.stopAndClose, .cancel]
        }
    }
}

/// The one sheet currently owned by a workspace window.
public enum CloseReviewPrompt: Identifiable, Equatable, Sendable {
    case document(id: UUID, presentation: DocumentPersistencePresentation)
    case terminals(id: UUID, presentation: TerminalClosePresentation)
    case vaultTrash(id: UUID, presentation: VaultTrashPresentation)

    public var id: UUID {
        switch self {
        case .document(let id, _), .terminals(let id, _), .vaultTrash(let id, _): id
        }
    }
}

/// Pure sizing rules shared by the close sheet and its layout tests.
public struct CloseReviewSheetLayout: Equatable, Sendable {
    public enum ActionAxis: Equatable, Sendable {
        case horizontal
        case vertical
    }

    public static let compactWidth: CGFloat = 300
    public static let preferredWidth: CGFloat = 510
    public static let maximumWidth: CGFloat = 620

    public init() {}

    /// Width accepted from the parent's real proposal. A very narrow parent
    /// wins rather than being clipped by a hard minimum; normal sheets settle
    /// at the compact-to-preferred range and never grow without bound.
    public static func width(availableWidth: CGFloat?) -> CGFloat {
        guard let availableWidth, availableWidth.isFinite, availableWidth > 0 else {
            return preferredWidth
        }
        return min(maximumWidth, availableWidth)
    }

    /// Chooses one deterministic action axis from actual fitted button widths.
    /// Accessibility text enlarges those widths naturally, switching to a
    /// vertical stack before any label or Cancel action is clipped.
    public static func actionAxis(
        availableContentWidth: CGFloat,
        buttonWidths: [CGFloat],
        spacing: CGFloat
    ) -> ActionAxis {
        guard availableContentWidth.isFinite, availableContentWidth > 0,
            buttonWidths.allSatisfy({ $0.isFinite && $0 >= 0 }),
            spacing.isFinite, spacing >= 0
        else { return .vertical }
        let gaps = spacing * CGFloat(max(0, buttonWidths.count - 1))
        return buttonWidths.reduce(0, +) + gaps <= availableContentWidth
            ? .horizontal : .vertical
    }
}

/// Ownership tokens that keep autosave out of every overlapping close review.
///
/// Cancellation cannot be represented by one Boolean: a second close attempt
/// can fail closed while the first sheet is still active, and clearing that
/// Boolean would let an edit schedule a write underneath the surviving review.
/// Each attempt therefore releases only its own opaque token. `release` returns
/// true exactly when that valid release made the gate idle, which gives the app
/// one canonical point at which to resume a deferred autosave.
@MainActor
public final class AutosaveSuspensionGate {
    public struct Token: Hashable, Sendable {
        fileprivate let id: UUID

        fileprivate init(id: UUID) { self.id = id }
    }

    private var active: Set<Token> = []

    public init() {}

    public var isSuspended: Bool { !active.isEmpty }

    public func acquire() -> Token {
        while true {
            let token = Token(id: UUID())
            if active.insert(token).inserted { return token }
        }
    }

    /// Returns true only when `token` was live and its release made the gate
    /// idle. Duplicate and stale releases are inert.
    @discardableResult
    public func release(_ token: Token) -> Bool {
        guard active.remove(token) != nil else { return false }
        return active.isEmpty
    }

    /// Invalidates every outstanding owner during view teardown. Their later
    /// deferred releases become no-ops and cannot schedule duplicate work.
    @discardableResult
    public func invalidateAll() -> Bool {
        guard !active.isEmpty else { return false }
        active.removeAll(keepingCapacity: true)
        return true
    }
}

/// AppKit-independent lifecycle for one deferred window-close attempt.
///
/// `performClose` normally re-enters the window delegate synchronously, but
/// it is permitted to return without asking again. Keeping that distinction
/// in a typed state machine makes the missing-reentry branch release its
/// retained workspace approval exactly once instead of silently leaking its
/// autosave suspension. The same gate serializes a window button and Quit:
/// whichever begins review first owns the attempt until cancellation or the
/// real `windowWillClose` boundary.
public struct WindowCloseAttemptGate: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case reviewing
        case awaitingDelegateReentry
        case awaitingWindowClose
    }

    public enum DelegateReentry: Equatable, Sendable {
        case notExpected
        case approved
        case refused
    }

    public private(set) var phase: Phase = .idle

    public init() {}

    public var isActive: Bool { phase != .idle }
    public var expectsDelegateReentry: Bool { phase == .awaitingDelegateReentry }
    public var isAwaitingWindowClose: Bool { phase == .awaitingWindowClose }

    /// Returns false when another window-close or Quit review already owns
    /// the lifecycle. The loser must fail closed without replacing it.
    @discardableResult
    public mutating func beginReview() -> Bool {
        guard phase == .idle else { return false }
        phase = .reviewing
        return true
    }

    /// Retains a successful review either for `performClose` delegate
    /// re-entry or directly for application termination.
    @discardableResult
    public mutating func approveReview(expectingDelegateReentry: Bool) -> Bool {
        guard phase == .reviewing else { return false }
        phase = expectingDelegateReentry ? .awaitingDelegateReentry : .awaitingWindowClose
        return true
    }

    /// Records the original SwiftUI delegate's answer to the one expected
    /// re-entry. Refusal consumes the attempt; approval stays retained until
    /// the actual window-close notification.
    public mutating func delegateReentered(
        originalDelegateApproved: Bool
    ) -> DelegateReentry {
        guard phase == .awaitingDelegateReentry else { return .notExpected }
        if originalDelegateApproved {
            phase = .awaitingWindowClose
            return .approved
        }
        phase = .idle
        return .refused
    }

    /// Called synchronously after `performClose`. `true` means AppKit never
    /// re-entered the delegate and no close began, so the caller must cancel
    /// the retained workspace approval. Repeated calls are inert.
    @discardableResult
    public mutating func performCloseReturned() -> Bool {
        guard phase == .awaitingDelegateReentry else { return false }
        phase = .idle
        return true
    }

    /// Cancels any review/approval and returns true exactly once for that
    /// active attempt. The caller uses the effect to release app-owned state.
    @discardableResult
    public mutating func cancel() -> Bool {
        guard phase != .idle else { return false }
        phase = .idle
        return true
    }

    /// A genuine close consumes retained state without resuming work in the
    /// disappearing window.
    public mutating func windowWillClose() {
        phase = .idle
    }
}

/// Serializes close-review sheets without blocking AppKit's main run loop.
///
/// A close flow asks for one response at a time and awaits it. SwiftUI renders
/// ``prompt`` as a sheet and calls one of the `respond` methods. Concurrent
/// close attempts fail closed with `.cancel` instead of replacing the sheet
/// and stranding the first continuation.
@MainActor
@Observable
public final class CloseReviewCoordinator {
    public private(set) var prompt: CloseReviewPrompt?

    @ObservationIgnored private var active: Active?

    private enum Active {
        case document(
            UUID,
            Set<DocumentCloseReviewAction>,
            CheckedContinuation<DocumentCloseReviewAction, Never>)
        case terminals(
            UUID,
            Set<TerminalCloseReviewAction>,
            CheckedContinuation<TerminalCloseReviewAction, Never>)
        case vaultTrash(
            UUID,
            Set<VaultTrashReviewAction>,
            CheckedContinuation<VaultTrashReviewAction, Never>)

        var id: UUID {
            switch self {
            case .document(let id, _, _), .terminals(let id, _, _),
                .vaultTrash(let id, _, _):
                id
            }
        }
    }

    public init() {}

    public var isPresenting: Bool { active != nil }

    public func requestDocument(
        _ presentation: DocumentPersistencePresentation
    ) async -> DocumentCloseReviewAction {
        let requestID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, active == nil else {
                    continuation.resume(returning: .cancel)
                    return
                }
                active = .document(
                    requestID,
                    Set(presentation.actions),
                    continuation)
                prompt = .document(id: requestID, presentation: presentation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(requestID: requestID) }
        }
    }

    public func requestTerminals(
        _ presentation: TerminalClosePresentation
    ) async -> TerminalCloseReviewAction {
        let requestID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, active == nil else {
                    continuation.resume(returning: .cancel)
                    return
                }
                active = .terminals(
                    requestID,
                    Set(presentation.actions),
                    continuation)
                prompt = .terminals(id: requestID, presentation: presentation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(requestID: requestID) }
        }
    }

    public func requestVaultTrash(
        _ presentation: VaultTrashPresentation
    ) async -> VaultTrashReviewAction {
        await requestVaultTrashDecision(presentation).action
    }

    public func requestVaultTrashDecision(
        _ presentation: VaultTrashPresentation
    ) async -> VaultTrashDecision {
        let requestID = UUID()
        let action: VaultTrashReviewAction = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, active == nil else {
                    continuation.resume(returning: .cancel)
                    return
                }
                active = .vaultTrash(
                    requestID,
                    Set(presentation.actions),
                    continuation)
                prompt = .vaultTrash(id: requestID, presentation: presentation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(requestID: requestID) }
        }
        return VaultTrashDecision(promptID: requestID, action: action)
    }

    public func respond(
        to promptID: UUID,
        with action: DocumentCloseReviewAction
    ) {
        guard case .document(let activeID, let actions, let continuation) = active,
            activeID == promptID, actions.contains(action)
        else { return }
        finish()
        continuation.resume(returning: action)
    }

    public func respond(
        to promptID: UUID,
        with action: TerminalCloseReviewAction
    ) {
        guard case .terminals(let activeID, let actions, let continuation) = active,
            activeID == promptID, actions.contains(action)
        else { return }
        finish()
        continuation.resume(returning: action)
    }

    public func respond(
        to promptID: UUID,
        with action: VaultTrashReviewAction
    ) {
        guard case .vaultTrash(let activeID, let actions, let continuation) = active,
            activeID == promptID, actions.contains(action)
        else { return }
        finish()
        continuation.resume(returning: action)
    }

    /// Treats interactive sheet dismissal and view teardown as Cancel.
    public func dismiss(promptID: UUID) {
        cancel(requestID: promptID)
    }

    public func cancelActivePrompt() {
        guard let active else { return }
        cancel(requestID: active.id)
    }

    private func cancel(requestID: UUID) {
        guard let active, active.id == requestID else { return }
        finish()
        switch active {
        case .document(_, _, let continuation):
            continuation.resume(returning: .cancel)
        case .terminals(_, _, let continuation):
            continuation.resume(returning: .cancel)
        case .vaultTrash(_, _, let continuation):
            continuation.resume(returning: .cancel)
        }
    }

    private func finish() {
        active = nil
        prompt = nil
    }
}
