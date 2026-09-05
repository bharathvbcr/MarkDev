//
//  CloseReviewUXContractTests.swift
//  MarkDevKitTests
//
//  App-level close wiring that cannot be imported by the framework test target.
//

import XCTest

final class CloseReviewUXContractTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // app
            .deletingLastPathComponent() // repository
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8)
    }

    private func slice(
        _ source: String,
        from start: String,
        until end: String
    ) throws -> Substring {
        let startIndex = try XCTUnwrap(source.range(of: start)?.lowerBound)
        let endIndex = try XCTUnwrap(
            source.range(of: end, range: startIndex..<source.endIndex)?.lowerBound)
        return source[startIndex..<endIndex]
    }

    /// AppKit asks synchronously whether a window or app may close, but the
    /// answer depends on asynchronous file durability work and a sheet. The
    /// delegate must defer the decision and reply exactly once instead of
    /// spinning a nested run loop in `runModal`.
    func testWindowAndQuitCloseReviewAreDeferred() throws {
        let source = try source("app/MarkDev/WindowCloseGuard.swift")

        XCTAssertTrue(
            source.contains(".terminateLater"),
            "Quit must wait for asynchronous document and terminal review")
        XCTAssertTrue(
            source.contains("reply(toApplicationShouldTerminate:"),
            "every deferred Quit decision must be completed explicitly")
        XCTAssertFalse(
            source.contains("func reviewClose() -> Bool"),
            "a synchronous reviewer cannot wait for durability without blocking AppKit")
    }

    /// Quit approval is the final async lifecycle point at which the app can
    /// settle events already admitted by the non-blocking diagnostics emitter.
    /// The wait must occur only after document approval, remain bounded, and
    /// finish before AppKit receives the positive termination reply.
    func testApprovedQuitPerformsABoundedDiagnosticsDrainBeforeReplying() throws {
        let source = try source("app/MarkDev/WindowCloseGuard.swift")
        let termination = try slice(
            source,
            from: "func applicationShouldTerminate(",
            until: "func applicationWillTerminate(")

        let review = try XCTUnwrap(
            termination.range(of: "reviewForTermination()")?.lowerBound)
        let drain = try XCTUnwrap(
            termination.range(of: "drainForTermination")?.lowerBound)
        let reply = try XCTUnwrap(
            termination.range(of: "reply(toApplicationShouldTerminate:")?.lowerBound)
        XCTAssertLessThan(review, drain)
        XCTAssertLessThan(drain, reply)
        XCTAssertTrue(
            termination.contains("DiagnosticsTerminationDrainPolicy"),
            "Quit must use the tested bounded diagnostics lifecycle policy")
    }

    /// A zero in the aggregate memory-drop row is not evidence that every
    /// sink accepted or completed its writes. Settings must surface those
    /// independent health dimensions rather than presenting a false green.
    func testDiagnosticsSettingsExposeDeliveryPendingAndRegistrationLoss() throws {
        let source = try source("app/MarkDev/SettingsView.swift")
        for signal in [
            "sinkDeliveryDroppedEventCount",
            "outstandingEventCount",
            "rejectedSinkRegistrationCount",
        ] {
            XCTAssertTrue(source.contains(signal), "Settings omits diagnostics signal: \(signal)")
        }
        for identifier in [
            "diagnostics.health.deliveryDropped",
            "diagnostics.health.pending",
            "diagnostics.health.rejectedSinks",
        ] {
            XCTAssertTrue(source.contains(identifier), "Settings row has no stable UI identity: \(identifier)")
        }
    }

    /// File choosers, Save As, support export, and rename prompts are reached
    /// from the same main-actor window as close review. None may start a nested
    /// event loop: doing so lets unrelated commands and teardown callbacks
    /// re-enter half-completed UI state while the modal call is on the stack.
    func testInteractivePanelsNeverUseNestedModalRunLoops() throws {
        for path in ["app/MarkDev/WorkspaceView.swift", "app/MarkDev/SettingsView.swift"] {
            let source = try source(path)
            XCTAssertFalse(
                source.contains("runModal()"),
                "\(path) must present AppKit panels asynchronously")
        }
    }

    /// Debouncing work on a main-actor Task does not make the eventual work
    /// asynchronous. Session encoding, file transactions, autosave batches,
    /// and Rust-backed HTML export must cross their existing off-main seams.
    func testPersistenceAndExportDoNotRunBlockingWorkOnTheWindowActor() throws {
        let source = try source("app/MarkDev/WorkspaceView.swift")
        let persistence = try slice(
            source,
            from: "private func persistSession()",
            until: "/// Recomputes the panels")
        let export = try slice(
            source,
            from: "private func exportHTML()",
            until: "private func printDocument()")

        XCTAssertFalse(source.contains("try workspace.save("))
        XCTAssertFalse(persistence.contains("workspace.autosave()"))
        XCTAssertFalse(persistence.contains("SessionStore.save("))
        XCTAssertTrue(persistence.contains("workspace.autosaveAsync()"))
        XCTAssertTrue(persistence.contains("SessionPersistenceLane.shared.save"))
        XCTAssertTrue(export.contains("Task.detached"))
    }

    /// Tab, pane, window, and Quit must share the same persistence policy.
    /// Otherwise a durability-only document is protected by one route and
    /// silently discarded by another.
    func testCloseLifecycleUsesTheCompleteReviewSetWithoutModalAlerts() throws {
        let source = try source("app/MarkDev/WorkspaceView.swift")
        let lifecycle = try slice(
            source,
            from: "private func closeDocument(",
            until: "/// A toolbar button")

        XCTAssertFalse(
            lifecycle.contains("runModal()"),
            "close review must be a non-blocking sheet")
        XCTAssertFalse(
            lifecycle.contains("documentsWithUnsavedChanges"),
            "dirty-only review loses directory-durability uncertainty")
        XCTAssertTrue(
            lifecycle.contains("documentsRequiringCloseReview"),
            "window and Quit review must include every persistence risk")
    }

    /// SwiftUI may dismantle and rebuild a workspace view while its window is
    /// still alive. A process is ended only by an approved terminal/tab/window
    /// close, never by incidental view disappearance.
    func testTransientWorkspaceDisappearanceDoesNotEndTerminalProcesses() throws {
        let source = try source("app/MarkDev/WorkspaceView.swift")
        let disappearance = try slice(
            source,
            from: "private func workspaceDidDisappear()",
            until: "// MARK: - Terminal")

        XCTAssertFalse(
            disappearance.contains("endAllHosts"),
            "onDisappear is not proof that the containing window closed")
        XCTAssertFalse(
            disappearance.contains("resumeAutosaveIfNeeded"),
            "a disappeared view must not start new work during teardown")
        XCTAssertTrue(
            disappearance.contains("autosaveTask?.cancel()"),
            "teardown must cancel any debounce task that can no longer be observed")
    }

    /// Every overlapping close attempt owns its own autosave suspension. A
    /// losing attempt, an edit while another sheet is open, or a stale teardown
    /// callback must not restart autosave underneath the surviving review.
    func testCloseReviewUsesTokenizedAutosaveSuspension() throws {
        let source = try source("app/MarkDev/WorkspaceView.swift")
        let scheduling = try slice(
            source,
            from: "private func scheduleAutosave()",
            until: "/// Recomputes the panels")
        let lifecycle = try slice(
            source,
            from: "private func closeDocument(",
            until: "/// A toolbar button")

        XCTAssertTrue(
            source.contains("AutosaveSuspensionGate"),
            "close review needs an owner that can distinguish overlapping suspensions")
        XCTAssertTrue(
            scheduling.contains("isSuspended"),
            "edits must not schedule autosave while any close review is active")
        XCTAssertTrue(
            lifecycle.contains("AutosaveSuspensionGate.Token"),
            "each close path must release exactly the suspension it acquired")
    }

    /// Conflict state belongs to a document identity, not to one rendering of
    /// that identity. Closing one side of a split must retain the warning;
    /// closing the final occurrence (directly or by removing its pane) must
    /// prune it from the window-owned conflict set.
    func testExternalConflictCleanupUsesTheCanonicalClosureOutcome() throws {
        let source = try source("app/MarkDev/WorkspaceView.swift")
        let lifecycle = try slice(
            source,
            from: "private func closeDocument(",
            until: "/// Reviews every unique persistence risk")

        XCTAssertGreaterThanOrEqual(
            lifecycle.components(separatedBy: "externalConflicts.subtract(").count - 1,
            2,
            "tab and pane closure must each prune only identities the workspace says are gone")
        XCTAssertFalse(
            lifecycle.contains("externalConflicts.remove(document)"),
            "one split occurrence closing must not erase a conflict shared by a surviving pane")
    }

    /// AppKit's `performClose` normally re-enters `windowShouldClose`, but a
    /// failed close attempt is also allowed to return without doing so. That
    /// branch must be observable through a testable lifecycle seam so the
    /// retained window approval (and its autosave token) is released once.
    func testApprovedCloseAttemptUsesATestableFailureLifecycle() throws {
        let source = try source("app/MarkDev/WindowCloseGuard.swift")

        XCTAssertTrue(
            source.contains("WindowCloseAttemptGate"),
            "delegate re-entry and failed performClose need an AppKit-independent state machine")
        XCTAssertTrue(
            source.contains("performCloseReturned()"),
            "returning without delegate re-entry must explicitly cancel the retained approval")
        XCTAssertFalse(
            source.contains("performingApprovedClose = false"),
            "a Boolean reset cannot distinguish delegate approval, refusal, teardown, and no re-entry")
    }

    /// Moving a file to Trash is a close-plus-destructive mutation. Every
    /// persistence risk must be reviewed and the exact approved document set
    /// revalidated before the filesystem changes, not asynchronously after it.
    func testTrashReviewsBeforeMutationWithoutBlockingTheMainRunLoop() throws {
        let source = try source("app/MarkDev/WorkspaceView.swift")
        let trash = try slice(
            source,
            from: "private func trashVaultItem(",
            until: "private func relativePath(")

        XCTAssertFalse(
            trash.contains("runModal()"),
            "Trash confirmation must not spin a nested AppKit run loop")
        XCTAssertTrue(
            trash.contains("reviewDocumentsForClose"),
            "Trash must review durability-only state as well as edited text")
        let review = try XCTUnwrap(trash.range(of: "reviewDocumentsForClose")?.lowerBound)
        let mutation = try XCTUnwrap(
            trash.range(of: "moveToTrashIfCurrent")?.lowerBound)
        XCTAssertLessThan(
            review,
            mutation,
            "document review must complete before the destructive filesystem mutation")
        XCTAssertFalse(
            trash.contains("closeDocument(document.id"),
            "reviewed tabs must close synchronously after Trash succeeds, not launch a second async review")
    }

    /// Merely mounting an AppKit editor does not mean that editor owns the
    /// keyboard. SwiftUI may deliver the deferred mount after a split has
    /// closed or replaced that pane, so registration, focus, and teardown
    /// need distinct callbacks plus an identity-checked registry.
    func testEditorSurfaceLifecycleSeparatesMountFocusAndUnmount() throws {
        let editor = try source("app/MarkDevKit/Editor/MarkdownEditorView.swift")
        let workspace = try source("app/MarkDev/WorkspaceView.swift")

        XCTAssertTrue(
            editor.contains("onMount:"),
            "mount must register a surface without claiming keyboard focus")
        XCTAssertTrue(
            editor.contains("onFocus:"),
            "keyboard focus must have a callback distinct from initial mount")
        XCTAssertTrue(
            editor.contains("onUnmount:"),
            "dismantling must explicitly retire the exact mounted surface")
        XCTAssertTrue(
            editor.contains("dismantleNSView"),
            "SwiftUI teardown must notify the registry instead of leaving a stale text view")
        XCTAssertTrue(
            editor.contains("context.coordinator.mount(textView)"),
            "mount registration must happen synchronously so it cannot land after dismantle")
        XCTAssertFalse(
            editor.contains("Task { @MainActor [weak textView]"),
            "the former deferred mount could register a retired native view")
        XCTAssertTrue(
            workspace.contains("EditorSurfaceRegistry"),
            "pane-to-view storage needs generation-checked mount and unmount semantics")
        XCTAssertFalse(
            workspace.contains("@State private var editorSurfaces: [PaneID: MarkdownTextView]"),
            "a raw dictionary cannot reject a delayed mount or unmount from an old view generation")
    }

    /// A fresh one-pane window should not be forced to reserve space for two
    /// panes and both optional panels. The minimum must be recomputed from the
    /// live pane/sidebar/inspector combination whenever that state changes.
    func testWindowMinimumGeometryIsDerivedFromLiveWorkspaceState() throws {
        let app = try source("app/MarkDev/MarkDevApp.swift")
        let theme = try source("app/MarkDevKit/Design/GlassTheme.swift")
        let workspace = try source("app/MarkDev/WorkspaceView.swift")

        XCTAssertFalse(
            app.contains("minimumTwoPaneWindowWidth"),
            "the scene must not impose the widest workspace configuration on every window")
        XCTAssertFalse(
            theme.contains("minimumTwoPaneWindowWidth"),
            "a fixed two-pane token cannot represent live optional-panel state")
        XCTAssertTrue(
            theme.contains("WorkspaceWindowGeometry"),
            "adaptive minimum sizing needs a pure, adversarially testable geometry model")
        XCTAssertTrue(
            workspace.contains("workspace.layout.paneCount"),
            "the live number of panes must participate in the window minimum")
        XCTAssertTrue(
            workspace.contains("updateWindowMinimumGeometry"),
            "panel and pane transitions must actively update the host window's minimum")
    }

    /// Workspace overlays and AppKit presentations are mutually exclusive.
    /// One typed owner must serialize them and remember exactly which editor
    /// should regain keyboard focus after dismissal; a UUID generation avoids
    /// stale dismissal aliasing after a wrapping integer revision.
    func testTransientPresentationHasOneTypedOwnerAndDeterministicFocusReturn() throws {
        let workspace = try source("app/MarkDev/WorkspaceView.swift")
        let owner = try source("app/MarkDevKit/Workspace/TransientPresentation.swift")

        XCTAssertTrue(
            workspace.contains("TransientPresentationCoordinator"),
            "palette, peek, graph, prompts, close review, and errors need one arbitration seam")
        XCTAssertTrue(
            workspace.contains("WorkspaceTransientPresentation"),
            "the active transient must be a closed typed set rather than unrelated flags")
        XCTAssertFalse(
            workspace.contains("@State private var showPalette = false"),
            "an independent palette flag permits overlap with sheets, alerts, and graph")
        XCTAssertFalse(
            workspace.contains("@State private var showGraph = false"),
            "an independent graph flag permits overlap with sheets, alerts, and palette")
        XCTAssertFalse(
            workspace.contains("@State private var peek: URL?"),
            "peek must participate in the same presentation arbitration")
        XCTAssertFalse(
            workspace.contains("@State private var errorMessage: String?"),
            "errors must not race a destructive prompt or close-review sheet")
        XCTAssertTrue(
            workspace.contains("restoreEditorFocus"),
            "dismissal must deterministically restore the captured editor responder")
        XCTAssertTrue(
            owner.contains("Generation") && owner.contains("UUID"),
            "presentation generations must not alias after integer wrap")
        XCTAssertFalse(
            owner.contains("&+="),
            "a wrapping integer must not be the authority for stale UI callbacks")
    }

    /// Consent to Trash must stay bound to one directory entry without
    /// following the final symlink. Device/inode/type alone can alias after
    /// inode reuse; the destructive boundary needs the same full stamp used by
    /// document I/O, captured coherently from a no-follow descriptor.
    func testTrashApprovalUsesNoFollowDescriptorCoherentIdentity() throws {
        let workspace = try source("app/MarkDev/WorkspaceView.swift")
        let identity = try source("app/MarkDevKit/Workspace/LocalFileIdentity.swift")

        XCTAssertFalse(
            workspace.contains("attributesOfItem(atPath:"),
            "Foundation path attributes may follow links and are not a descriptor-coherent authority")
        XCTAssertTrue(
            workspace.contains("SecureTrashTarget"),
            "Trash must use the filesystem boundary's typed no-follow target")
        XCTAssertTrue(identity.contains("generation: UInt32"))
        XCTAssertTrue(identity.contains("birthSeconds: Int64"))
        XCTAssertTrue(identity.contains("changedSeconds: Int64"))
        XCTAssertTrue(identity.contains("mode: mode_t"))
        XCTAssertTrue(identity.contains("ownerID: uid_t"))
        XCTAssertTrue(identity.contains("linkCount: UInt64"))
        XCTAssertTrue(
            identity.contains("O_NOFOLLOW") || identity.contains("AT_SYMLINK_NOFOLLOW"),
            "the final directory entry must be inspected without following a replacement symlink")
        XCTAssertTrue(
            identity.contains("SecureTrashTarget"),
            "the full file stamp must be captured and revalidated through one destructive-operation type")
    }

    func testHostWindowTracksScreenChangesWithoutStaleObservers() throws {
        let source = try source("app/MarkDev/HostWindowReader.swift")

        XCTAssertTrue(source.contains("didChangeScreenNotification"))
        XCTAssertTrue(source.contains("didChangeScreenProfileNotification"))
        XCTAssertTrue(source.contains("didChangeScreenParametersNotification"))
        XCTAssertTrue(source.contains("stopObservingWindow()"))
        XCTAssertTrue(
            source.contains("ObjectIdentifier(eventWindow) == expectedWindowID")
                && source.contains("self.window === eventWindow")
                && source.contains("self.window === observedWindow"),
            "a notification retained from an old display/window must be bound to its exact window identity")
    }

    func testCloseReviewSheetAdaptsWidthAndActionsToItsProposal() throws {
        let source = try source("app/MarkDev/CloseReviewSheet.swift")

        XCTAssertFalse(
            source.contains(".frame(width: 510)"),
            "the close sheet must fit compact windows and large accessibility text")
        XCTAssertTrue(source.contains("AdaptiveCloseReviewSheetLayout"))
        XCTAssertTrue(source.contains("CloseReviewActionLayout"))
        XCTAssertTrue(source.contains("CloseReviewSheetLayout.width(availableWidth: proposal.width)"))
    }

    func testDecorationPaletteDefaultIsCreatedOnMainActor() throws {
        let source = try source("app/MarkDevKit/Editor/MarkdownLayoutFragment.swift")

        XCTAssertFalse(
            source.contains(
                "private let lock = OSAllocatedUnfairLock<Snapshot>(\n"
                    + "        initialState: Snapshot(palette: BlockDecorationPalette(theme: .standard)))"),
            "an actor-isolated AppKit palette cannot be a nonisolated stored-property default")
        XCTAssertTrue(
            source.contains("@MainActor\n    init()"),
            "the palette store must establish its AppKit-derived default on the main actor")
    }
}
