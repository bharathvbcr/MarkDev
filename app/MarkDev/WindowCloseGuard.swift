//
//  WindowCloseGuard.swift
//  MarkDev
//
//  Routes window close and application termination through the same
//  unsaved-document review used by tab and pane closure.
//

import AppKit
import MarkDevKit
import OSLog
import SwiftUI

@MainActor
private protocol WindowCloseReviewing: AnyObject {
    func reviewClose() async -> Bool
    func closeApprovalIsCurrent() -> Bool
    func closeReviewWasCancelled()
}

/// Weak registry used only for application termination. Window close itself
/// travels through `NSWindowDelegate`; Quit has no SwiftUI view callback, so
/// the application delegate asks every live window reviewer directly.
@MainActor
private final class WindowCloseRegistry {
    static let shared = WindowCloseRegistry()

    /// A pathological number of windows must not keep Quit suspended forever.
    /// Failing closed lets a later attempt retry after the churn settles.
    private static let maximumReviewersPerAttempt = 256

    private final class WeakReviewer {
        weak var value: (any WindowCloseReviewing)?

        init(_ value: any WindowCloseReviewing) {
            self.value = value
        }
    }

    private var reviewers: [ObjectIdentifier: WeakReviewer] = [:]
    private var revision = UUID()

    func register(_ reviewer: any WindowCloseReviewing) {
        let id = ObjectIdentifier(reviewer)
        guard reviewers[id]?.value !== reviewer else { return }
        reviewers[id] = WeakReviewer(reviewer)
        advanceRevision()
        removeReleasedReviewers()
    }

    func unregister(_ reviewer: any WindowCloseReviewing) {
        let id = ObjectIdentifier(reviewer)
        guard reviewers.removeValue(forKey: id) != nil else { return }
        advanceRevision()
    }

    /// Reviews one stable snapshot of the live windows. Any window arriving,
    /// leaving, or rebuilding while sheets are being answered invalidates the
    /// attempt; Quit then replies `false` instead of approving an unreviewed
    /// surface.
    func reviewForTermination() async -> Bool {
        removeReleasedReviewers()
        let attemptRevision = revision
        let snapshot = reviewers.values.compactMap(\.value)
        guard snapshot.count <= Self.maximumReviewersPerAttempt else {
            cancelApprovals(in: snapshot)
            return false
        }

        for reviewer in snapshot {
            guard await reviewer.reviewClose(), revision == attemptRevision else {
                cancelApprovals(in: snapshot)
                return false
            }
        }
        guard revision == attemptRevision,
            snapshot.allSatisfy({ $0.closeApprovalIsCurrent() })
        else {
            cancelApprovals(in: snapshot)
            return false
        }
        return true
    }

    private func removeReleasedReviewers() {
        let released = reviewers.filter { $0.value.value == nil }.map(\.key)
        guard !released.isEmpty else { return }
        for id in released { reviewers[id] = nil }
        advanceRevision()
    }

    private func advanceRevision() {
        revision = UUID()
    }

    private func cancelApprovals(in reviewers: [any WindowCloseReviewing]) {
        for reviewer in reviewers { reviewer.closeReviewWasCancelled() }
    }
}

/// Makes a SwiftUI window participate in AppKit's close decision without
/// replacing behavior owned by SwiftUI's private window delegate.
struct WindowCloseGuard: NSViewRepresentable {
    let reviewClose: @MainActor () async -> Bool
    let approvalIsCurrent: @MainActor () -> Bool
    let reviewCancelled: @MainActor () -> Void
    let windowWillClose: @MainActor () -> Void

    init(
        reviewClose: @escaping @MainActor () async -> Bool,
        approvalIsCurrent: @escaping @MainActor () -> Bool,
        reviewCancelled: @escaping @MainActor () -> Void,
        windowWillClose: @escaping @MainActor () -> Void
    ) {
        self.reviewClose = reviewClose
        self.approvalIsCurrent = approvalIsCurrent
        self.reviewCancelled = reviewCancelled
        self.windowWillClose = windowWillClose
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            reviewClose: reviewClose,
            approvalIsCurrent: approvalIsCurrent,
            reviewCancelled: reviewCancelled,
            windowWillClose: windowWillClose)
    }

    func makeNSView(context: Context) -> WindowProbeView {
        let view = WindowProbeView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ view: WindowProbeView, context: Context) {
        context.coordinator.reviewCloseAction = reviewClose
        context.coordinator.approvalIsCurrent = approvalIsCurrent
        context.coordinator.onCloseReviewCancelled = reviewCancelled
        context.coordinator.onWindowWillClose = windowWillClose
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
        var reviewCloseAction: @MainActor () async -> Bool
        var approvalIsCurrent: @MainActor () -> Bool
        var onCloseReviewCancelled: @MainActor () -> Void
        var onWindowWillClose: @MainActor () -> Void
        private weak var window: NSWindow?
        private var reviewTask: Task<Void, Never>?
        private var closeAttempt = WindowCloseAttemptGate()
        // NSObject's forwarding hooks are nonisolated overrides even though
        // NSWindow delegates are main-actor bound. Access is still confined
        // to AppKit's main thread; this annotation bridges that mismatch.
        nonisolated(unsafe) private weak var originalDelegate: (any NSWindowDelegate)?

        init(
            reviewClose: @escaping @MainActor () async -> Bool,
            approvalIsCurrent: @escaping @MainActor () -> Bool,
            reviewCancelled: @escaping @MainActor () -> Void,
            windowWillClose: @escaping @MainActor () -> Void
        ) {
            reviewCloseAction = reviewClose
            self.approvalIsCurrent = approvalIsCurrent
            onCloseReviewCancelled = reviewCancelled
            onWindowWillClose = windowWillClose
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
            reviewTask?.cancel()
            reviewTask = nil
            cancelAttemptIfNeeded()
            if let window, window.delegate === self {
                window.delegate = originalDelegate
            }
            WindowCloseRegistry.shared.unregister(self)
            window = nil
            originalDelegate = nil
        }

        func reviewClose() async -> Bool {
            guard closeAttempt.beginReview() else { return false }
            let approved = await reviewCloseAction()
            guard !Task.isCancelled, approved, approvalIsCurrent(),
                closeAttempt.approveReview(expectingDelegateReentry: false)
            else {
                cancelAttemptIfNeeded()
                return false
            }
            return true
        }

        func closeApprovalIsCurrent() -> Bool {
            closeAttempt.isAwaitingWindowClose && approvalIsCurrent()
        }

        func closeReviewWasCancelled() {
            reviewTask?.cancel()
            reviewTask = nil
            cancelAttemptIfNeeded()
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if closeAttempt.expectsDelegateReentry {
                let approved = originalDelegate?.windowShouldClose?(sender) ?? true
                switch closeAttempt.delegateReentered(
                    originalDelegateApproved: approved
                ) {
                case .approved:
                    return true
                case .refused:
                    onCloseReviewCancelled()
                    return false
                case .notExpected:
                    return false
                }
            }

            guard reviewTask == nil, closeAttempt.beginReview() else { return false }
            reviewTask = Task { @MainActor [weak self, weak sender] in
                guard let self else { return }
                let approved = await reviewCloseAction()
                guard !Task.isCancelled else {
                    reviewTask = nil
                    cancelAttemptIfNeeded()
                    return
                }
                reviewTask = nil
                guard approved, approvalIsCurrent(), let sender,
                    sender === window, sender.delegate === self,
                    closeAttempt.approveReview(expectingDelegateReentry: true)
                else {
                    cancelAttemptIfNeeded()
                    return
                }

                // `performClose` asks the delegate again. The one-shot bypass
                // reaches the original SwiftUI delegate on that second call,
                // preserving its private close behavior without re-presenting
                // this review sheet.
                sender.performClose(nil)
                if closeAttempt.performCloseReturned() {
                    // AppKit returned without asking the delegate again and
                    // without beginning a close. Release the exact retained
                    // workspace approval instead of suspending autosave forever.
                    onCloseReviewCancelled()
                }
            }
            return false
        }

        func windowWillClose(_ notification: Notification) {
            reviewTask?.cancel()
            reviewTask = nil
            closeAttempt.windowWillClose()
            onWindowWillClose()
            originalDelegate?.windowWillClose?(notification)
        }

        private func cancelAttemptIfNeeded() {
            guard closeAttempt.cancel() else { return }
            onCloseReviewCancelled()
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
    private static let lifecycleLogger = Logger(
        subsystem: "dev.markdev.MarkDev",
        category: "termination")

    /// Watches for a window becoming key, so a file waiting for somewhere to
    /// go is retried the moment there is somewhere.
    ///
    /// The inbox cannot see this for itself: readiness is answered by AppKit,
    /// and nothing in SwiftUI reports "a window is now on screen".
    private var keyWindowObserver: (any NSObjectProtocol)?
    /// Coalesces repeated Quit requests and guarantees that every deferred
    /// AppKit termination decision receives one eventual reply.
    private var terminationReviewTask: Task<Void, Never>?
    private let diagnosticsDrainPolicy = DiagnosticsTerminationDrainPolicy()

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
        guard terminationReviewTask == nil else { return .terminateLater }

        terminationReviewTask = Task { @MainActor in
            let approved = await WindowCloseRegistry.shared.reviewForTermination()
            let drainPolicy: DiagnosticsTerminationDrainPolicy = diagnosticsDrainPolicy
            var finalApproval = approved && !Task.isCancelled
            if finalApproval {
                let drainOutcome = await drainPolicy.drainForTermination()
                if drainOutcome == .cancelled {
                    finalApproval = false
                }
                if drainOutcome != .settled {
                    Self.lifecycleLogger.warning(
                        "Diagnostics termination drain ended with \(drainOutcome.rawValue, privacy: .public)")
                }
            }
            terminationReviewTask = nil
            sender.reply(toApplicationShouldTerminate: finalApproval)
        }
        return .terminateLater
    }

    /// Ends every shell the app forked.
    ///
    /// A terminal's process used to die with the view that hosted it. It no
    /// longer does — the pty is owned by ``TerminalSessions`` so the terminal
    /// can be moved between the drawer and the sidebar without restarting — so
    /// the guarantee has to be restated at genuine lifecycle boundaries. An
    /// approved window close ends that window's hosts in `windowWillClose`;
    /// this is the process-wide fallback for Quit, which does not ask every
    /// window delegate whether it may close.
    func applicationWillTerminate(_ notification: Notification) {
        terminationReviewTask?.cancel()
        terminationReviewTask = nil
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
