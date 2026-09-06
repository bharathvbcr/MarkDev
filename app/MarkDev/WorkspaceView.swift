//
//  WorkspaceView.swift
//  MarkDev
//
//  The window: navigator, split panes, tabs, and the command palette.
//

import AppKit
import MarkDevKit
import SwiftUI

struct WorkspaceView: View {
    private struct WindowCloseApproval {
        let documents: [OpenDocument]
        let terminals: [TerminalCloseRisk]
        let autosaveSuspension: AutosaveSuspensionGate.Token
    }

    private struct NativePanelLease {
        let id: UUID
        let generation: TransientPresentationCoordinator.Generation
    }

    @State private var workspace = Workspace()
    @State private var workspaceIOLifecycle = WorkspaceIOLifecycle()
    @State private var workspaceIOTasks = WorkspaceIOTaskBag()
    @State private var closeReviews = CloseReviewCoordinator()
    @State private var autosaveSuspensions = AutosaveSuspensionGate()
    @State private var transientPresentation = TransientPresentationCoordinator()
    @State private var dropTargetPane: PaneID?

    // Shell preferences outlive the window. Resizing the navigator or picking
    // a writing mode is a decision about how someone works, not about the
    // document in front of them, and making them re-make it at every launch
    // is the whole reason chrome settings feel disposable.
    @AppStorage("shell.showSidebar") private var showSidebar = true
    @AppStorage("shell.showInspector") private var showInspector = true
    @AppStorage(EditorPreferences.Key.mode)
    private var mode: EditorMode = EditorPreferences.defaultMode
    @AppStorage(EditorPreferences.Key.themePreset)
    private var themePreset: EditorPreferences.ThemePreset = EditorPreferences.defaultThemePreset
    @AppStorage("shell.inspectorTab") private var inspectorTab: InspectorTab = .outline
    @AppStorage("shell.sidebarWidth") private var storedSidebarWidth =
        Double(GlassTheme.sidebar.preferred)
    @AppStorage("shell.inspectorWidth") private var storedInspectorWidth =
        Double(GlassTheme.inspector.preferred)
    @AppStorage("shell.showTerminal") private var showTerminal = false
    /// Which panel the terminal is drawn in. A preference about how someone
    /// works, so it outlives the window like the others.
    @AppStorage("shell.terminalPlacement") private var terminalPlacement: TerminalPlacement =
        .drawer
    @AppStorage("shell.assistEngine") private var assistEngine: AssistEngine = .apple
    @AppStorage("shell.terminalHeight") private var storedTerminalHeight =
        Double(GlassTheme.terminal.preferred)

    private var terminalHeight: CGFloat {
        GlassTheme.terminal.clamping(CGFloat(storedTerminalHeight))
    }

    /// Panel widths, clamped on the way out as well as on the way in: the
    /// stored value survives a build whose limits have changed, and a hand-
    /// edited preference cannot wedge a panel off-screen.
    private var sidebarWidth: CGFloat {
        GlassTheme.sidebar.clamping(CGFloat(storedSidebarWidth))
    }

    private var inspectorWidth: CGFloat {
        GlassTheme.inspector.clamping(CGFloat(storedInspectorWidth))
    }

    /// Compatibility projections for the existing view builders. These are
    /// all views of one typed owner, so only one can ever be non-empty.
    private var showPalette: Bool {
        get { transientPresentation.active?.presentation == .commandPalette }
        nonmutating set {
            if newValue {
                presentTransient(.commandPalette)
            } else {
                dismissTransient { $0 == .commandPalette }
            }
        }
    }

    private var peek: URL? {
        get {
            guard case .peek(let url) = transientPresentation.active?.presentation else {
                return nil
            }
            return url
        }
        nonmutating set {
            if let newValue {
                presentTransient(.peek(newValue))
            } else {
                dismissTransient {
                    if case .peek = $0 { return true }
                    return false
                }
            }
        }
    }

    private var showGraph: Bool {
        get { transientPresentation.active?.presentation == .graph }
        nonmutating set {
            if newValue {
                presentTransient(.graph)
            } else {
                dismissTransient { $0 == .graph }
            }
        }
    }

    /// Surfaced rather than swallowed: opening and saving can fail for
    /// reasons the user can act on. Errors use the same arbiter as sheets and
    /// overlays, so a failure cannot appear underneath a destructive choice.
    private var errorMessage: String? {
        get { transientPresentation.errorMessage }
        nonmutating set {
            if let newValue {
                _ = transientPresentation.presentError(
                    newValue,
                    restoringFocusTo: workspace.focusedPane)
            } else {
                handleTransientDismissal(transientPresentation.clearError())
            }
        }
    }

    /// Diagnostics retain only typed counts and a sanitized file extension;
    /// absolute paths, filenames, dependency payloads, and note text never
    /// cross the logging boundary.
    private func emitWorkspaceIO(
        _ code: DiagnosticCode,
        item: URL? = nil,
        failedCount: Int = 1,
        droppedCount: Int = 0
    ) {
        var metadata: [DiagnosticMetadataKey: DiagnosticMetadataValue] = [
            .failedCount: .integer(Int64(clamping: max(0, failedCount))),
            .droppedCount: .integer(Int64(clamping: max(0, droppedCount))),
        ]
        if let item { metadata[.fileType] = .file(item) }
        DiagnosticsEmitter.shared.emit(
            severity: .error,
            subsystem: .workspace,
            code: code,
            operationID: DiagnosticOperationID(),
            metadata: DiagnosticMetadata(metadata))
    }

    /// Derived editor state, keyed by document identity so tabs and split
    /// views share it without recomputing.
    @State private var documentStats: [OpenDocument.ID: DocumentStats] = [:]
    @State private var documentOutlines: [OpenDocument.ID: [VaultHeading]] = [:]
    @State private var statsTasks: [OpenDocument.ID: Task<Void, Never>] = [:]

    /// Apple Intelligence for this window.
    @State private var writingTools = WritingTools()

    /// Each pane's live editor, registered as the views are built.
    ///
    /// "Focus next pane" has to move the *keyboard*, not just a stored
    /// value — the tab strip used to brighten while typing kept landing in
    /// the pane that was never left, which reads as the shortcut doing
    /// nothing. The registry is what makes first responder reachable by pane.
    @State private var editorSurfaces = EditorSurfaceRegistry()
    /// `EditorSurfaceRegistry` deliberately owns weak AppKit references and
    /// is not observable. This epoch makes mounts, focus attachment, and
    /// unmounts invalidate SwiftUI's command snapshot without duplicating any
    /// editor authority.
    @State private var commandSurfaceRevision: UInt64 = 0

    /// The vault's link graph — shared process-wide, not owned here: two
    /// windows on one folder used to re-walk and hold the whole corpus twice.
    /// Swapped when the open vault changes; every reader below keeps working.
    @State private var vault = VaultIndex()

    /// Reads ahead along the focused note's links. Owned beside the index it
    /// asks, and for the same reason: one window, one read-ahead.
    @State private var warmer = ConnectedNoteWarmer()
    @State private var outline: [VaultHeading] = []
    @State private var backlinks: [Backlink] = []
    @State private var mentions: [UnlinkedMention] = []
    @State private var outgoingLinks: [OutgoingLink] = []

    /// Pending scroll-to-offset per pane, from the outline and from links.
    @State private var reveals: [PaneID: RevealRequest] = [:]

    /// Active selection word and character statistics per pane.
    @State private var selectionStats: [PaneID: (words: Int, chars: Int)] = [:]

    /// Destination of hovered link per pane.
    @State private var hoveredLinks: [PaneID: String] = [:]

    /// The window this workspace is in, and how ready it is to be shown a
    /// document opened from Finder. Filled in by ``HostWindowReader``.
    @State private var surface = DocumentSurface()

    /// This workspace's registration with ``DocumentInbox``, withdrawn when it
    /// goes away. Held so *this* registration is withdrawn and no other:
    /// SwiftUI builds a throwaway workspace for every incoming file open, and
    /// clearing a shared handler would let the throwaway's departure silence
    /// the window on screen.
    @State private var inboxRegistration: DocumentSurfaceToken?

    /// Every open shell. Owned here, not by the drawer, so hiding the drawer
    /// does not kill a running build — see ``TerminalSessions``.
    @State private var terminals = TerminalSessions()
    /// Exact state approved by the most recent window/Quit review. AppKit asks
    /// for the final answer later, so any intervening edit or PTY generation
    /// invalidates that approval.
    @State private var windowCloseApproval: WindowCloseApproval?

    /// Watches the open vault via the shared coordinator, which keeps one
    /// FSEvent stream per folder no matter how many windows are open on it.
    /// Held so *this* subscription is the one cancelled on disappear.
    @State private var watchToken: UUID?
    @State private var watchedRoot: URL?
    /// Bumped on every watched change, into the navigator's re-scan trigger.
    @State private var vaultRevision = 0
    /// Open documents whose file changed underneath them, awaiting the
    /// reader's decision. Keyed by document identity; a split view showing
    /// the same note twice shows the banner once per view but decides once.
    @State private var externalConflicts: Set<OpenDocument.ID> = []
    /// Whether the drawer has ever been opened in this window.
    ///
    /// Once it has, it stays mounted — collapsed to nothing when hidden — so
    /// the shells inside it survive ⌘J. Until then it is not built at all, so
    /// an app whose terminal is never opened never forks one.
    @State private var terminalMounted = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow
    @Namespace private var glass

    /// Vertical space the floating toolbar occupies, so content can clear it.
    private static let toolbarHeight: CGFloat = 52
    /// One prompt per document is deliberate, but the operation must remain
    /// bounded if corrupted session data somehow restores an extreme tab set.
    private static let maximumDocumentsPerCloseReview = 512

    /// Coordinate space shared by the floating chrome and the panels beneath
    /// it, so one can be measured against the other.
    private static let workspaceSpace = "workspace"

    /// Bottom edge of the sidebar's header row, in `workspaceSpace`.
    ///
    /// `nil` until the first layout pass reports one.
    @State private var sidebarHeaderBottom: CGFloat?

    /// Carries that edge from the toolbar, which draws the header, to the
    /// sidebar panel, which draws the rule under it.
    ///
    /// The two are siblings in the `ZStack`, so the panel cannot simply ask
    /// how tall the header came out — and the header's height is the headline
    /// font's, which moves with the system text size. A constant would be
    /// right at one text size and wrong at every other.
    private struct SidebarHeaderBottomKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    /// Distance from the panel's top edge down to the rule.
    ///
    /// The panel insets itself by `snug`, so subtracting that converts the
    /// header's measured bottom into the panel's own coordinates. Landing the
    /// rule exactly on the header's bottom edge is what balances the header:
    /// the chip's own padding then reads as equal space above and below the
    /// title. Falls back to the toolbar's nominal height until measured.
    private var sidebarHeaderInset: CGFloat {
        guard let bottom = sidebarHeaderBottom else { return Self.toolbarHeight }
        return max(0, bottom - GlassTheme.Spacing.snug)
    }

    private var errorPresentation: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } })
    }

    private var closeReviewPresentation: Binding<CloseReviewPrompt?> {
        Binding(
            get: {
                guard let prompt = closeReviews.prompt,
                    transientPresentation.active?.presentation.closeReviewID == prompt.id
                else { return nil }
                return prompt
            },
            set: { proposed in
                guard proposed == nil, let prompt = closeReviews.prompt else { return }
                closeReviews.dismiss(promptID: prompt.id)
            })
    }

    private func presentTransient(_ presentation: WorkspaceTransientPresentation) {
        _ = transientPresentation.present(
            presentation,
            restoringFocusTo: workspace.focusedPane)
    }

    /// Acquires the window's one transient-presentation slot for an AppKit
    /// sheet. The UUID plus coordinator generation makes a late completion
    /// inert after teardown or after another protected presentation takes
    /// ownership.
    private func beginNativePanel() -> NativePanelLease? {
        let id = UUID()
        let result = transientPresentation.present(
            .nativePanel(id),
            restoringFocusTo: workspace.focusedPane)
        let generation: TransientPresentationCoordinator.Generation
        switch result {
        case .presented(let value), .replaced(previous: _, current: let value):
            generation = value
        case .alreadyPresented, .deferredError, .refused:
            return nil
        }
        return NativePanelLease(id: id, generation: generation)
    }

    private func nativePanelIsCurrent(_ lease: NativePanelLease) -> Bool {
        guard let active = transientPresentation.active else { return false }
        return active.generation == lease.generation
            && active.presentation == .nativePanel(lease.id)
    }

    private func finishNativePanel(_ lease: NativePanelLease) {
        guard nativePanelIsCurrent(lease) else { return }
        handleTransientDismissal(transientPresentation.dismiss(lease.generation))
    }

    private func dismissTransient(
        where matches: (WorkspaceTransientPresentation) -> Bool
    ) {
        guard let active = transientPresentation.active,
            matches(active.presentation)
        else { return }
        handleTransientDismissal(transientPresentation.dismiss(active.generation))
    }

    private func dismissEscapeEligibleTransient() {
        dismissTransient(where: \.dismissesOnEscape)
    }

    private func handleTransientDismissal(
        _ result: TransientPresentationCoordinator.DismissalResult
    ) {
        guard case .restoreFocus(let intent) = result else { return }
        restoreEditorFocus(intent)
    }

    /// Defers one responder turn so AppKit has finished removing the overlay,
    /// sheet, or alert. The intent is consumed by UUID identity immediately
    /// before the handoff; any newer presentation invalidates the callback.
    private func restoreEditorFocus(
        _ intent: TransientPresentationCoordinator.FocusRestorationIntent
    ) {
        Task { @MainActor in
            await Task.yield()
            guard transientPresentation.consumeFocusRestoration(intent) else { return }
            moveKeyboard(to: intent.pane ?? workspace.focusedPane)
        }
    }

    private func closeReviewPromptChanged(
        from oldPrompt: CloseReviewPrompt?,
        to newPrompt: CloseReviewPrompt?
    ) {
        if let oldPrompt, oldPrompt.id != newPrompt?.id {
            // The Trash task advances its exact prompt token into the actual
            // operation (or dismisses it on Cancel). Retain that ownership
            // across the continuation handoff instead of briefly restoring
            // editor focus between consent and mutation.
            let trashTaskOwnsCompletion: Bool
            if case .vaultTrash = oldPrompt, newPrompt == nil {
                trashTaskOwnsCompletion = true
            } else {
                trashTaskOwnsCompletion = false
            }
            if !trashTaskOwnsCompletion {
                dismissTransient { $0.closeReviewID == oldPrompt.id }
            }
        }
        guard let newPrompt else { return }
        let presentation: WorkspaceTransientPresentation
        switch newPrompt {
        case .vaultTrash:
            presentation = .destructivePrompt(newPrompt.id)
        case .document, .terminals:
            presentation = .closeReview(newPrompt.id)
        }
        let result = transientPresentation.present(
            presentation,
            restoringFocusTo: workspace.focusedPane)
        if result == .refused {
            // A protected presentation already owns this window. Fail the
            // competing close/destructive request closed rather than layering
            // a second sheet beneath it.
            closeReviews.dismiss(promptID: newPrompt.id)
        }
    }

    private var workspaceShell: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                if showSidebar {
                    sidebar
                        .frame(width: sidebarWidth)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    ResizeHandle(
                        axis: .horizontal,
                        label: "Navigator divider",
                        onDrag: {
                            storedSidebarWidth = Double(
                                GlassTheme.sidebar.clamping(sidebarWidth + $0))
                        },
                        onReset: {
                            storedSidebarWidth = Double(GlassTheme.sidebar.preferred)
                        })
                }

                VStack(spacing: 0) {
                    SplitTreeView(layout: workspace.layoutBinding) { pane in
                        paneView(pane)
                    }
                    // Cleared from the floating toolbar once, at the container,
                    // rather than per pane: padding each pane individually
                    // pushes every pane in a vertical split down, and leaves
                    // the tab bars colliding with the toolbar the moment a
                    // split appears.
                    .padding(.top, Self.toolbarHeight)
                    // Content still runs under the chrome's edges, giving the
                    // glass something to refract instead of a flat panel.
                    .backgroundExtensionEffect()

                    if showTerminal && terminalPlacement == .drawer {
                        ResizeHandle(
                            axis: .vertical,
                            label: "Terminal divider",
                            onDrag: {
                                storedTerminalHeight = Double(
                                    GlassTheme.terminal.clamping(terminalHeight - $0))
                            },
                            onReset: {
                                storedTerminalHeight = Double(GlassTheme.terminal.preferred)
                            })
                    }
                    if terminalMounted && terminalPlacement == .drawer {
                        // Collapsed rather than removed. The shells no longer
                        // depend on it — they are owned by ``TerminalSessions``
                        // so that the terminal can be moved to the inspector
                        // without restarting — but rebuilding the whole panel
                        // on every ⌘J still costs a relayout of every session's
                        // view for nothing.
                        terminalPanel(placement: .drawer)
                        .frame(height: showTerminal ? terminalHeight : 0)
                        .clipped()
                        .opacity(showTerminal ? 1 : 0)
                        .allowsHitTesting(showTerminal)
                        .accessibilityHidden(!showTerminal)
                    }
                }

                if showInspector {
                    ResizeHandle(
                        axis: .horizontal,
                        label: "Inspector divider",
                        onDrag: {
                            storedInspectorWidth = Double(
                                GlassTheme.inspector.clamping(inspectorWidth - $0))
                        },
                        onReset: {
                            storedInspectorWidth = Double(GlassTheme.inspector.preferred)
                        })
                    inspector
                        .frame(width: inspectorWidth)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }

            toolbar
        }
    }

    private var workspaceBase: some View {
        workspaceShell
        .background(.background)
        // Dropping files on a window is how a Mac editor is expected to accept
        // work, and it is the only route into MarkDev that needs neither the
        // menu bar nor prior knowledge of ⌘K. A dropped folder opens as a
        // vault, which is the only sensible reading of a folder here.
        .dropDestination(for: URL.self) { urls, _ in
            open(dropped: urls)
        }
        .background(
            WindowCloseGuard(
                reviewClose: { await reviewClosingAll() },
                approvalIsCurrent: { windowCloseApprovalIsCurrent() },
                reviewCancelled: { cancelWindowCloseApproval() },
                windowWillClose: { workspaceWindowWillClose() }))
        .background(
            HostWindowReader(
                surface: surface,
                onWindowChange: { _ in updateWindowMinimumGeometry() }))
        .focusedSceneValue(
            \.workspaceCommandHandler,
            WorkspaceCommandHandler(
                availability: commandAvailability,
                perform: { run($0) }))
        .focusedSceneValue(\.tabSwitcher, makeTabSwitcher())
        .sheet(item: closeReviewPresentation) { prompt in
            CloseReviewSheet(
                prompt: prompt,
                respondToDocument: { promptID, action in
                    closeReviews.respond(to: promptID, with: action)
                },
                respondToTerminals: { promptID, action in
                    closeReviews.respond(to: promptID, with: action)
                },
                respondToVaultTrash: { promptID, action in
                    closeReviews.respond(to: promptID, with: action)
                })
        }
        .alert(
            "Couldn’t Complete Action",
            isPresented: errorPresentation
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .animation(GlassTheme.motion(GlassTheme.spring, reduceMotion: reduceMotion), value: showSidebar)
    }

    private var workspaceWithOverlays: some View {
        workspaceBase
        .accessibilityHidden(transientPresentation.hidesWorkspaceAccessibility)
        .disabled(transientPresentation.isPerformingDestructiveOperation)
        .overlay {
            if showPalette {
                ZStack(alignment: .top) {
                    // Clicking away from a launcher is how every launcher is
                    // dismissed; without the scrim, Escape was the only way
                    // out. It also dims the window enough to say the palette
                    // has the keyboard.
                    Rectangle()
                        .fill(.black.opacity(0.14))
                        .ignoresSafeArea()
                        .onTapGesture { showPalette = false }
                        .transition(.opacity)
                        .accessibilityHidden(true)

                    CommandPalette(
                        isPresented: Binding(
                            get: { showPalette },
                            set: { showPalette = $0 }),
                        commands: commands,
                        availability: commandAvailability,
                        contentSearch: workspace.vaultRoot == nil
                            ? nil : { await contentSearchCommands(for: $0) },
                        contentRevision: vault.contentRevision
                    ) { run($0) }
                        .padding(.top, 90)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .scale(scale: 0.94, anchor: .top)
                                    .combined(with: .opacity)
                                    .combined(with: .offset(y: -14)))
                }
                .accessibilityAddTraits(.isModal)
            }
        }
        .animation(
            GlassTheme.motion(GlassTheme.quickSpring, reduceMotion: reduceMotion),
            value: showPalette
        )
        // Above the palette's overlay so the two can never fight for the same
        // space; in practice only one is ever up, since peeking needs the
        // sidebar to hold focus.
        .overlay {
            if let peek {
                PeekPanel(
                    url: peek,
                    onOpen: {
                        let target = peek
                        self.peek = nil
                        scheduleFileOpen(target)
                    },
                    onDismiss: { self.peek = nil }
                )
                .transition(
                    reduceMotion
                        ? .opacity
                        : .scale(scale: 0.97).combined(with: .opacity))
            }
        }
        .animation(
            GlassTheme.motion(GlassTheme.quickSpring, reduceMotion: reduceMotion),
            value: peek)
        .overlay {
            if showGraph {
                GraphPanel(
                    vault: vault,
                    current: workspace.document(in: workspace.focusedPane)?.url
                        .flatMap { vault.relativePath(for: $0) },
                    onOpen: { path in
                        guard let url = vault.url(for: path) else { return }
                        showGraph = false
                        scheduleFileOpen(url)
                    },
                    onDismiss: { showGraph = false }
                )
                .transition(
                    reduceMotion
                        ? .opacity
                        : .scale(scale: 0.97).combined(with: .opacity))
            }
        }
        .animation(
            GlassTheme.motion(GlassTheme.quickSpring, reduceMotion: reduceMotion),
            value: showGraph)
        .overlay {
            if case .destructiveOperation(_, let title) =
                transientPresentation.active?.presentation
            {
                ZStack {
                    Rectangle()
                        .fill(.black.opacity(0.16))
                        .ignoresSafeArea()
                    VStack(spacing: GlassTheme.Spacing.snug) {
                        ProgressView()
                            .controlSize(.large)
                        Text(title)
                            .font(.headline)
                    }
                    .padding(GlassTheme.Spacing.loose)
                    .glassEffect(.regular, in: .rect(cornerRadius: GlassTheme.Radius.large))
                }
                .accessibilityAddTraits(.isModal)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(title)
                .accessibilityIdentifier("workspace.destructive-operation")
            }
        }
    }

    var body: some View {
        workspaceWithOverlays
        .coordinateSpace(.named(Self.workspaceSpace))
        .onExitCommand(perform: dismissEscapeEligibleTransient)
        // Keeps the last real measurement rather than clearing it. Collapsing
        // removes the header, which publishes zero; resetting on that would
        // send the rule back to its fallback and make it visibly slide into
        // place on every re-open. Only the first open ever uses the fallback.
        .onPreferenceChange(
            SidebarHeaderBottomKey.self,
            perform: updateSidebarHeaderBottom)
        .onChange(of: workspace.layout) { _, _ in
            pruneOrphanedState()
            updateWindowMinimumGeometry()
        }
        .onChange(of: showSidebar) { _, _ in updateWindowMinimumGeometry() }
        .onChange(of: showInspector) { _, _ in updateWindowMinimumGeometry() }
        .onChange(of: closeReviews.prompt) { oldPrompt, newPrompt in
            closeReviewPromptChanged(from: oldPrompt, to: newPrompt)
        }
        .onChange(of: workspace.focusedPane) { _, pane in
            refreshVault()
            moveKeyboard(to: pane)
        }
        .onOpenURL { url in
            scheduleFileOpen(url)
        }
        // Files from Finder, the Dock, or `open`. Registered rather than
        // drained: a double-click that launches the app delivers its request
        // before this view exists, and SwiftUI builds a throwaway workspace
        // for each request besides — so the inbox picks the surface with a
        // window on screen instead of trusting whoever asked last.
        .onAppear(perform: workspaceDidAppear)
        .animation(
            GlassTheme.motion(GlassTheme.spring, reduceMotion: reduceMotion),
            value: showInspector)
        .animation(
            GlassTheme.motion(GlassTheme.spring, reduceMotion: reduceMotion),
            value: showTerminal)
        .onDisappear(perform: workspaceDidDisappear)
    }

    private func updateSidebarHeaderBottom(_ bottom: CGFloat) {
        guard bottom > 0 else { return }
        sidebarHeaderBottom = bottom
    }

    private func updateWindowMinimumGeometry() {
        guard let window = surface.window else { return }
        let geometry = WorkspaceWindowGeometry(
            layout: workspace.layout,
            showsSidebar: showSidebar,
            showsInspector: showInspector)
        let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame
        let availableWidth = visibleFrame.map { max(1, $0.width - 32) }
        let availableHeight = visibleFrame.map { max(1, $0.height - 32) }
        window.contentMinSize = NSSize(
            width: geometry.minimumWidth(maximumAvailableWidth: availableWidth),
            height: min(
                WorkspaceWindowGeometry.minimumHeight,
                availableHeight ?? WorkspaceWindowGeometry.minimumHeight))
    }

    private func workspaceDidAppear() {
        writingTools.harness.refreshAvailability()
        restoreSessionOnce()
        if let inboxRegistration { DocumentInbox.shared.unregister(inboxRegistration) }
        inboxRegistration = DocumentInbox.shared.register(
            readiness: { surface.readiness },
            deliver: { takeFromInbox($0) })
        updateWindowMinimumGeometry()
        resumeAutosaveIfNeeded()
    }

    private func workspaceDidDisappear() {
        workspaceIOLifecycle.invalidateAll()
        workspaceIOTasks.cancelAll()
        closeReviews.cancelActivePrompt()
        transientPresentation.invalidateAll()
        discardWindowCloseApproval(resumeAutosave: false)
        _ = autosaveSuspensions.invalidateAll()
        autosaveTask?.cancel()
        autosaveTask = nil
        if let inboxRegistration {
            DocumentInbox.shared.unregister(inboxRegistration)
        }
        inboxRegistration = nil
        for task in statsTasks.values { task.cancel() }
        for editor in editorSurfaces.mountedSurfaces {
            writingTools.detach(from: editor)
        }
        editorSurfaces.prune(keeping: [])
        stopWatching()
        // A harness turn outliving its window would keep burning the local
        // model with nobody watching and no remaining panel to stop it.
        writingTools.harness.stop()
    }

    // MARK: - Terminal

    /// The terminal, wherever it is being drawn.
    ///
    /// One builder for both placements rather than a view per panel: the two
    /// differ only in chrome, and a second copy is how the drawer's `+` and the
    /// sidebar's `+` come to open different things.
    private func terminalPanel(placement: TerminalPlacement) -> some View {
        TerminalDrawer(
            sessions: terminals,
            document: workspace.document(in: workspace.focusedPane)?.url,
            vault: workspace.vaultRoot,
            placement: placement,
            onClose: placement == .drawer ? { showTerminal = false } : nil,
            onCloseSession: { closeTerminal($0) },
            onRestartSession: { restartTerminal($0) },
            onMove: { setTerminalPlacement(placement.other) },
            onOpenHarness: writingTools.harness.availability.isReady
                ? { openHarnessTerminal() } : nil,
            onError: { errorMessage = $0 }
        )
    }

    /// Closing a terminal tab destroys a process tree, so it follows the same
    /// non-blocking review path as closing the window. The exact generation is
    /// checked again in the same main-actor turn as the mutation.
    private func closeTerminal(_ id: TerminalSessionState.ID) {
        Task { @MainActor in
            guard terminals.sessions.contains(where: { $0.id == id }) else { return }
            let reviewedRisk = terminals.closeRisk(for: id)
            if let reviewedRisk {
                guard await reviewTerminalRisks(
                    [reviewedRisk], purpose: .closeSessions)
                else { return }
                guard terminals.isUnchangedOrExited(afterReviewing: reviewedRisk) else {
                    errorMessage =
                        "The terminal restarted while its close decision was open. Nothing was stopped."
                    return
                }
            }

            guard terminals.sessions.contains(where: { $0.id == id }) else { return }
            if let reviewedRisk {
                guard terminals.isUnchangedOrExited(afterReviewing: reviewedRisk) else { return }
            } else {
                // A process that launched after the initial no-risk check was
                // never shown in a prompt.
                guard terminals.closeRisk(for: id) == nil else { return }
            }
            terminals.close(id)
        }
    }

    /// Restart replaces a process just as surely as close destroys it. It has
    /// distinct copy and a distinct typed confirmation, while retaining the
    /// same generation validation immediately before the counter advances.
    private func restartTerminal(_ id: TerminalSessionState.ID) {
        Task { @MainActor in
            guard terminals.sessions.contains(where: { $0.id == id }) else { return }
            let reviewedRisk = terminals.closeRisk(for: id)
            if let reviewedRisk {
                guard await reviewTerminalRisks(
                    [reviewedRisk], purpose: .restartSession)
                else { return }
                guard terminals.isUnchangedOrExited(afterReviewing: reviewedRisk) else {
                    errorMessage =
                        "The terminal changed while its restart decision was open. Nothing was stopped."
                    return
                }
            }

            guard terminals.sessions.contains(where: { $0.id == id }) else { return }
            if let reviewedRisk {
                guard terminals.isUnchangedOrExited(afterReviewing: reviewedRisk) else { return }
            } else {
                guard terminals.closeRisk(for: id) == nil else { return }
            }
            guard terminals.restart(id) else {
                errorMessage = "The terminal could not be restarted safely."
                return
            }
        }
    }

    /// Whether the terminal is on screen right now.
    ///
    /// Two different questions depending on where it lives, which is why this
    /// is derived rather than stored: in the drawer it is a panel that is open
    /// or closed, and in the inspector it is a *tab*, so it is showing exactly
    /// when the inspector is open on it. A single stored flag would go out of
    /// step the first time somebody clicked the tab directly, and ⌘J would then
    /// toggle the wrong way round.
    private var isTerminalVisible: Bool {
        switch terminalPlacement {
        case .drawer: showTerminal
        case .inspector: showInspector && inspectorTab == .terminal
        }
    }

    /// Shows or hides the terminal, wherever it lives.
    private func setTerminal(visible: Bool) {
        switch terminalPlacement {
        case .drawer:
            if visible { terminalMounted = true }
            showTerminal = visible
        case .inspector:
            if visible {
                showInspector = true
                inspectorTab = .terminal
            } else if inspectorTab == .terminal {
                // Leaving the tab selected would mean ⌘J appeared to do
                // nothing. The inspector itself stays open: the reader asked to
                // put the terminal away, not the panel it is in.
                inspectorTab = .outline
            }
        }
    }

    /// Moves the terminal between the drawer and the inspector.
    ///
    /// Nothing restarts: both panels draw the same sessions, and the pty view
    /// is re-parented rather than rebuilt — see ``TerminalProcessHost``. What
    /// this has to do is make sure the destination is actually on screen, since
    /// moving a terminal into a panel the reader has closed is a move that
    /// looks like a deletion.
    private func setTerminalPlacement(_ placement: TerminalPlacement) {
        terminalPlacement = placement
        terminalMounted = true
        setTerminal(visible: true)
    }

    /// Opens a shell already running the harness, rooted at the note's folder.
    ///
    /// A typed startup action is sent to an interactive login shell rather
    /// than making MANVI the shell. Rooted at the note rather than at the vault
    /// because that is what the reader is working on, and MANVI resolves
    /// everything it reads from where it was started.
    private func openHarnessTerminal() {
        do {
            let startup = try writingTools.harness.terminalStartupAction()
            let directory =
                workspace.document(in: workspace.focusedPane)?.url?.deletingLastPathComponent()
                ?? workspace.vaultRoot
            let config = TerminalSession.resolve(
                document: nil,
                vault: directory,
                startupAction: startup)
            let id = try terminals.reveal(config)
            // Create the host in the same actor turn as identity approval. The
            // host revalidates again before forking, which removes the former
            // gap where a hidden/lazy terminal could retain a stale raw path.
            _ = terminals.host(for: id)
            setTerminal(visible: true)
            if let failure = terminals.sessions.first(where: { $0.id == id })?.launchFailure {
                errorMessage = failure.reason
            }
        } catch let failure as TerminalOpenFailure {
            errorMessage = failure.reason
        } catch let failure as TerminalLaunchFailure {
            DiagnosticsEmitter.shared.emit(
                severity: .error,
                subsystem: .terminal,
                code: .harnessTerminalFailed,
                operationID: DiagnosticOperationID(),
                metadata: DiagnosticMetadata([.available: .boolean(false)]))
            errorMessage = failure.reason
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Opens a shell rooted at `directory`, from the sidebar.
    ///
    /// Reveals rather than opens: clicking a folder twice should bring its
    /// shell forward, not fork a second one beside the first.
    private func openTerminal(in directory: URL) {
        // The session first, then the drawer. The drawer opens a default shell
        // when it appears to nothing, so mounting it first would fork one at
        // the vault root and *then* add the requested folder beside it.
        let config = TerminalSession.resolve(document: nil, vault: directory)
        do {
            try terminals.reveal(config)
            setTerminal(visible: true)
        } catch let failure as TerminalOpenFailure {
            errorMessage = failure.reason
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Chrome

    /// The floating chrome, split into two clusters that line up with the two
    /// columns beneath it.
    ///
    /// The brand and sidebar toggle belong to the **sidebar column** and are
    /// held to its exact width; search and the mode picker belong to the
    /// **content column**. The brand chip therefore comes and goes with the
    /// sidebar: pinning it above a panel that is no longer there leaves it
    /// reading as a header for nothing.
    ///
    /// Laying the toolbar out as one continuous row instead lets its items
    /// drift out of step with the panels below — adding the brand chip pushed
    /// the search capsule across the sidebar's edge, so the chrome no longer
    /// agreed with the layout it sat on.
    private var toolbar: some View {
        GlassEffectContainer(spacing: GlassTheme.Spacing.snug) {
            ViewThatFits(in: .horizontal) {
                regularToolbarContent
                compactToolbarContent
            }
        }
        .padding(.top, GlassTheme.Spacing.snug)
    }

    private var regularToolbarContent: some View {
        HStack(spacing: 0) {
            HStack(spacing: GlassTheme.Spacing.snug) {
                if showSidebar {
                    brandChip
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    Spacer(minLength: GlassTheme.Spacing.snug)
                }
                sidebarToggle
            }
            .padding(.leading, GlassTheme.Spacing.snug)
            .padding(.trailing, showSidebar ? GlassTheme.Spacing.snug : 0)
            .frame(width: showSidebar ? sidebarWidth : nil, alignment: .leading)
            .background {
                if showSidebar {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: SidebarHeaderBottomKey.self,
                            value: proxy.frame(in: .named(Self.workspaceSpace)).maxY)
                    }
                }
            }

            HStack(spacing: GlassTheme.Spacing.snug) {
                searchButton
                saveMenu
                Spacer(minLength: GlassTheme.Spacing.snug)
                modePicker
                inspectorToggle
            }
            .padding(.horizontal, GlassTheme.Spacing.snug)
        }
    }

    /// Icon-only fallback chosen from the real width proposal. Every regular
    /// toolbar action remains reachable when panels or large text leave too
    /// little room for the brand, Search label, and expanded mode switcher.
    private var compactToolbarContent: some View {
        HStack(spacing: GlassTheme.Spacing.tight) {
            sidebarToggle
            compactSearchButton
            saveMenu
            Spacer(minLength: GlassTheme.Spacing.tight)
            compactModeMenu
            inspectorToggle
        }
        .padding(.horizontal, GlassTheme.Spacing.snug)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("workspace.toolbar.compact")
    }

    /// The mark is drawn from the same geometry the app icon is rendered
    /// from, so the chrome and the Dock never disagree.
    ///
    /// Deliberately **not** glass. It only exists while the sidebar is open,
    /// which is exactly when it is sitting on the navigator's own glass panel
    /// — a capsule there is a surface floating on a surface, and the point of
    /// glass is to separate the navigation layer from content, not to outline
    /// every label within it. The padding stays: it lands the logo on the
    /// panel's inner content edge, in line with the filter field below.
    private var brandChip: some View {
        HStack(spacing: GlassTheme.Spacing.tight) {
            MarkDevLogoView()
                .frame(width: 18, height: 18)
                // Decorative here: the wordmark beside it already says the
                // name, and VoiceOver should not say it twice.
                .accessibilityHidden(true)
            Text("MarkDev")
                .font(.headline)
                .fixedSize()
        }
        // `snug` on every side, matching the toggle beside it and the inset
        // the panel itself sits at. The header then reads as one rhythm: the
        // panel is 10pt inside the window, and its title is 10pt inside the
        // panel. `tight` here left the title 6pt from the top edge while the
        // toggle sat at 10pt, so the two were subtly out of line with each
        // other and with everything below them.
        .padding(GlassTheme.Spacing.snug)
    }

    /// Carries its glass in every state, through ``ChromeToggle``.
    ///
    /// This used to drop the capsule while the navigator was open, on the
    /// grounds that the toggle was then riding the panel and needed no surface
    /// of its own. It shares ``ChromeToggle`` with the inspector toggle
    /// instead: the tint already says which state it is in, and a control that
    /// gains and loses its surface reads as two different controls in the same
    /// spot. One owner for chrome toggles is also what keeps the hit region,
    /// hover, and accessibility traits from drifting between them.
    private var sidebarToggle: some View {
        ChromeToggle(
            symbol: "sidebar.leading",
            label: showSidebar ? "Hide navigator (⌘\\)" : "Show navigator (⌘\\)",
            isOn: showSidebar,
            reduceMotion: reduceMotion
        ) {
            showSidebar.toggle()
        }
        .glassEffectID("sidebar", in: glass)
    }

    private var searchButton: some View {
        Button {
            showPalette.toggle()
        } label: {
            HStack(spacing: GlassTheme.Spacing.tight) {
                Image(systemName: "magnifyingglass")
                Text("Search").font(.caption)
                Text("⌘K").font(.caption2).foregroundStyle(.tertiary)
            }
            .fixedSize()
            .controlTarget(
                Capsule(),
                padding: EdgeInsets(
                    top: GlassTheme.Spacing.snug,
                    leading: GlassTheme.Spacing.regular,
                    bottom: GlassTheme.Spacing.snug,
                    trailing: GlassTheme.Spacing.regular))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .glassEffectID("palette", in: glass)
        .help("Search files and commands (⌘K)")
    }

    private var compactSearchButton: some View {
        Button { showPalette.toggle() } label: {
            Image(systemName: "magnifyingglass")
                .controlTarget(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .help("Search files and commands (⌘K)")
        .accessibilityLabel("Search files and commands")
        .accessibilityIdentifier("workspace.toolbar.search.compact")
    }

    private var modePicker: some View {
        ModeSwitcher(mode: $mode)
            .padding(.horizontal, GlassTheme.Spacing.tight)
            .padding(.vertical, 3)
            .glassEffect(.regular.interactive(), in: .capsule)
            .glassEffectID("mode", in: glass)
    }

    private var compactModeMenu: some View {
        Menu {
            ForEach(EditorMode.allCases, id: \.self) { option in
                Button {
                    mode = option
                } label: {
                    Label(option.commandTitle, systemImage: option == mode ? "checkmark" : option.symbol)
                }
            }
        } label: {
            Image(systemName: mode.symbol)
                .controlTarget(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .glassEffect(.regular.interactive(), in: .circle)
        .help("Writing mode: \(mode.title)")
        .accessibilityLabel("Writing mode: \(mode.title)")
        .accessibilityIdentifier("workspace.toolbar.mode.compact")
    }

    /// Save is a menu rather than a button because "Save As…" has to live
    /// somewhere reachable without the menu bar.
    private var saveMenu: some View {
        Menu {
            Button("Save") { saveDocument() }
            Button("Save As…") { saveDocumentAs() }
        } label: {
            Image(systemName: "square.and.arrow.down")
                .controlTarget(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // Matched to the other toolbar controls. Left bare, it read as an
        // unstyled glyph dropped between two glass capsules.
        .glassEffect(.regular.interactive(), in: .circle)
        .glassEffectID("save", in: glass)
        .help("Save (⌘S)")
        .accessibilityLabel("Save options")
    }

    private var inspectorToggle: some View {
        ChromeToggle(
            symbol: "sidebar.trailing",
            label: showInspector ? "Hide inspector (⌥⌘I)" : "Show inspector (⌥⌘I)",
            isOn: showInspector,
            reduceMotion: reduceMotion
        ) {
            showInspector.toggle()
        }
        .glassEffectID("inspector", in: glass)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            // Closes off the strip the toolbar floats over, so the brand and
            // the toggle read as this panel's header rather than as two items
            // hovering above the tree. Inset to the same edges as the filter
            // field below it, and only ever drawn with the sidebar open —
            // collapsed, there is no header for it to underline.
            Divider()
                .padding(.top, sidebarHeaderInset)
                .padding(.horizontal, GlassTheme.Spacing.snug)

            NavigatorView(
                root: workspace.vaultRoot,
                revision: vaultRevision,
                onOpen: { scheduleFileOpen($0) },
                onChooseVault: { openVault() },
                onPeek: { peek = $0 },
                onOpenTerminal: { openTerminal(in: $0) },
                onCreateNote: { createNote(in: $0) },
                onRename: { renameNote(at: $0) },
                onDelete: { trashVaultItem(at: $0) },
                onDropNotes: { urls, folder in dropNotes(urls, into: folder) }
            )
            .onChange(of: vaultRevision) { _, _ in
                refreshVault()
            }
        }
        .glassPanel(radius: GlassTheme.Radius.large, padding: EdgeInsets())
        .padding(GlassTheme.Spacing.snug)
    }

    // MARK: - Panes

    @ViewBuilder
    private func paneView(_ pane: PaneID) -> some View {
        let state = workspace.state(for: pane)
        let document = state.current
        let isFocused = workspace.focusedPane == pane
        let isSplit = workspace.layout.paneCount > 1

        VStack(spacing: 0) {
            PaneTabBar(
                state: state,
                isFocused: isFocused,
                availability: commandAvailability,
                onSelect: {
                    retireSessionRestore()
                    workspace.select($0, in: pane)
                    if pane == workspace.focusedPane { refreshVault() }
                    persistSession()
                },
                onClose: { closeDocument($0, in: pane) },
                onSplit: {
                    retireSessionRestore()
                    workspace.split(pane, edge: $0)
                    persistSession()
                },
                onClosePane: { closePane(pane) }
            )

            // Surfaced the moment the watcher sees it, not at save time when
            // it can only be an error: the reader chooses between versions
            // while both still make sense.
            if let document, externalConflicts.contains(document.id) {
                conflictBar(document)
            }

            MarkdownEditorView(
                text: Binding(
                    get: { workspace.document(in: pane)?.text ?? "" },
                    set: {
                        retireSessionRestore()
                        // Reported rather than dropped: a refusal here reverts
                        // the editor to the pre-edit text on the next update
                        // pass, so without this the reader watches a paste
                        // disappear with nothing said.
                        if let refusal = workspace.apply(text: $0, in: pane).readerMessage {
                            errorMessage = refusal
                        }
                        if pane == workspace.focusedPane { refreshVault() }
                        scheduleAutosave()
                    }
                ),
                mode: mode,
                theme: themePreset.theme,
                prefetchOwner: ContentPrefetcher.Owner(id: pane.id),
                documentDirectory: workspace.document(in: pane)?.url?
                    .deletingLastPathComponent(),
                reveal: reveals[pane],
                onParse: { parsed in
                    guard let current = workspace.document(in: pane) else { return }
                    handleParse(parsed, text: current.text, document: current.id, pane: pane)
                },
                onFollowWikiLink: { followWikiLink($0, in: pane) },
                onFollowDocumentLink: { followDocumentLink($0, in: pane) },
                onMount: { surface in
                    let token = editorSurfaces.mount(surface, in: pane)
                    commandSurfaceRevision &+= 1
                    return token
                },
                onFocus: { token, surface in
                    guard editorSurfaces.isCurrent(
                        token,
                        surface: surface,
                        in: pane)
                    else { return }
                    workspace.focusedPane = pane
                    writingTools.attach(to: surface)
                    commandSurfaceRevision &+= 1
                },
                onUnmount: { token, surface in
                    _ = editorSurfaces.unmount(
                        token,
                        surface: surface,
                        in: pane)
                    // `WritingTools` performs its own identity check. This is
                    // intentionally called even for a stale registry token so
                    // a dismantled formerly-focused view cannot remain held.
                    writingTools.detach(from: surface)
                    commandSurfaceRevision &+= 1
                },
                onSelectionStats: { words, chars in
                    selectionStats[pane] = (words, chars)
                },
                onHoveredLink: { link in
                    hoveredLinks[pane] = link
                },
                onDocumentRejected: { errorMessage = $0 },
                onAssetIngestionError: { errorMessage = $0 }
            )
            .onTapGesture { workspace.focusedPane = pane }

            StatusBar(
                location: statusLocation(for: document),
                hasUnsavedChanges: document?.hasUnsavedChanges ?? false,
                stats: document.flatMap { documentStats[$0.id] } ?? .empty,
                selectedWords: selectionStats[pane]?.words,
                selectedCharacters: selectionStats[pane]?.chars,
                hoveredLink: hoveredLinks[pane])
        }
        .contentShape(Rectangle())
        .onTapGesture { workspace.focusedPane = pane }

        .overlay {
            if dropTargetPane == pane {
                ZStack {
                    RoundedRectangle(cornerRadius: GlassTheme.Radius.medium)
                        .fill(Color.accentColor.opacity(0.10))
                    RoundedRectangle(cornerRadius: GlassTheme.Radius.medium)
                        .strokeBorder(
                            Color.accentColor,
                            style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                    Label("Open in Split", systemImage: "rectangle.split.2x1")
                        .font(.headline)
                        .padding(.horizontal, GlassTheme.Spacing.loose)
                        .padding(.vertical, GlassTheme.Spacing.regular)
                        .glassEffect(.regular, in: .capsule)
                }
                .padding(GlassTheme.Spacing.snug)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .dropDestination(
            for: URL.self,
            action: { urls, _ in openDroppedMarkdown(urls, beside: pane) },
            isTargeted: { targeted in
                if targeted {
                    dropTargetPane = pane
                } else if dropTargetPane == pane {
                    dropTargetPane = nil
                }
            })
        // Which pane is focused decides where a link, an outline row, or a
        // newly opened file lands. The dimmed tab strip says it too, but only
        // where the tabs are; the outline runs the full height of the pane,
        // beside the text the reader is actually looking at.
        .overlay {
            if isSplit {
                RoundedRectangle(cornerRadius: GlassTheme.Radius.medium)
                    .strokeBorder(
                        Color.accentColor.opacity(isFocused ? 0.45 : 0),
                        lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
        .animation(
            GlassTheme.motion(GlassTheme.quickSpring, reduceMotion: reduceMotion),
            value: isFocused)
    }

    private var inspector: some View {
        InspectorView(
            outline: outline,
            backlinks: backlinks,
            mentions: mentions,
            outgoing: outgoingLinks,
            assistant: writingTools.document,
            harness: writingTools.harness,
            terminal: terminalPlacement == .inspector
                ? AnyView(terminalPanel(placement: .inspector))
                : nil,
            tab: $inspectorTab,
            engine: $assistEngine,
            onReveal: { offset in
                reveals[workspace.focusedPane] = RevealRequest(offset: offset)
            },
            onOpenNote: { path, offset in
                guard let url = vault.url(for: path) else { return }
                scheduleFileOpen(url) { pane in
                    reveals[pane] = RevealRequest(offset: Int(offset))
                }
            },
            onMoveTerminalHere: { setTerminalPlacement(.inspector) }
        )
        .padding(.top, Self.toolbarHeight)
        .glassPanel(radius: GlassTheme.Radius.large, padding: EdgeInsets())
        .padding(GlassTheme.Spacing.snug)
    }

    // MARK: - Vault

    /// Opens a file, returning the result directly instead of making callers
    /// infer it from whichever alert the window happened to show beforehand.
    @discardableResult
    private func openFile(
        _ url: URL,
        in requestedPane: PaneID? = nil,
        presentingOutcome: Bool = true,
        lifecycleToken suppliedToken: WorkspaceIOLifecycle.Token? = nil
    ) async -> DocumentOpenAttempt {
        guard !transientPresentation.isPerformingDestructiveOperation else {
            let attempt = DocumentOpenAttempt.failed(
                "Finish the current filesystem operation before opening another document.")
            if presentingOutcome { errorMessage = attempt.failureMessage }
            return attempt
        }
        let pane = requestedPane ?? workspace.focusedPane
        let ownsToken = suppliedToken == nil
        if ownsToken {
            workspaceIOLifecycle.invalidate(.sessionRestore)
        }
        let token = suppliedToken ?? workspaceIOLifecycle.begin(.documentOpen(pane))
        defer {
            if ownsToken { workspaceIOLifecycle.finish(token) }
        }

        let attempt: DocumentOpenAttempt
        do {
            try await workspace.openAsync(url, in: pane) {
                workspaceIOLifecycle.isCurrent(token)
            }
            guard workspaceIOLifecycle.isCurrent(token) else { return .cancelled }
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            refreshVault()
            persistSession()
            attempt = .opened
        } catch is CancellationError {
            attempt = .cancelled
        } catch {
            emitWorkspaceIO(.workspaceOpenFailed, item: url)
            let message = WorkspaceIOFailure.presentation(
                error,
                operation: .openDocument,
                item: url)
            attempt = message.map(DocumentOpenAttempt.failed) ?? .cancelled
        }
        // Success intentionally clears a previous failure. A stale alert is
        // not the outcome of the operation the reader just completed.
        if presentingOutcome, workspaceIOLifecycle.isCurrent(token) {
            errorMessage = attempt.failureMessage
        }
        return attempt
    }

    /// Synchronous adapter for SwiftUI callbacks. One pane owns at most one
    /// direct open task; batches use their own bounded scope below.
    private func scheduleFileOpen(
        _ url: URL,
        in requestedPane: PaneID? = nil,
        onOpened: @escaping @MainActor @Sendable (PaneID) -> Void = { _ in }
    ) {
        let pane = requestedPane ?? workspace.focusedPane
        workspaceIOTasks.cancel(.documentBatch(pane))
        workspaceIOTasks.cancel(.editorDrop(pane))
        workspaceIOLifecycle.invalidate(.documentBatch(pane))
        workspaceIOLifecycle.invalidate(.editorDrop(pane))
        workspaceIOLifecycle.invalidate(.sessionRestore)
        workspaceIOTasks.cancel(.sessionRestore)
        workspaceIOTasks.launch(in: .documentOpen(pane), priority: .userInitiated) {
            let result = await openFile(url, in: pane)
            guard result.didOpen else { return }
            onOpened(pane)
        }
    }

    private func retireSessionRestore() {
        workspaceIOLifecycle.invalidate(.sessionRestore)
        workspaceIOTasks.cancel(.sessionRestore)
    }

    /// Answers whether this workspace can show `request`, and takes it on if
    /// it can.
    ///
    /// The window is checked here rather than trusted from the readiness that
    /// chose this surface: choosing and delivering are two moments, and the
    /// whole failure this replaces was a workspace that no longer had a window
    /// accepting documents on behalf of the one that did.
    ///
    /// Opening itself is deferred a turn. This is called from the inbox, which
    /// the view registers with during SwiftUI's update pass, and mutating
    /// workspace state from inside that pass is the documented way to have the
    /// change dropped.
    private func takeFromInbox(_ request: DocumentOpenRequest) -> Bool {
        guard !request.isEmpty else { return false }
        guard surface.canShowDocument else { return false }
        surface.bringToFront()
        Task { @MainActor in
            // Asked once more on the far side of the deferral: a turn is short,
            // but it is long enough for a window to close, and handing the
            // files back is what keeps "taken" from meaning "lost".
            guard surface.canShowDocument else {
                DocumentInbox.shared.requeue(request)
                return
            }
            openFromInbox(request)
        }
        return true
    }

    /// Opens whatever Launch Services handed the app.
    ///
    /// Routed through the same rules as a drag onto the window — a folder is a
    /// vault, a file is a document — rather than a second interpretation of
    /// what an incoming URL means.
    private func openFromInbox(_ request: DocumentOpenRequest) {
        guard !request.isEmpty else { return }
        _ = open(dropped: request.urls, alreadyDropped: request.dropped)
    }

    /// Opens dropped files, and treats a dropped folder as a vault.
    ///
    /// Reports success if *anything* was usable rather than requiring the whole
    /// drop to be: a selection dragged out of Finder routinely carries an
    /// image or a PDF alongside the notes, and rejecting the entire drop for
    /// one of them reads as the app refusing a drag it plainly understood.
    /// Whatever could not be opened still surfaces through the usual alert.
    @discardableResult
    private func open(dropped urls: [URL], alreadyDropped: Int = 0) -> Bool {
        let request = DocumentOpenRequest.bounded(
            urls,
            dropped: alreadyDropped,
            limit: WorkspaceIOBounds.maximumOpenItems)
        guard !request.isEmpty else {
            if let truncation = request.truncationMessage { errorMessage = truncation }
            return false
        }
        let pane = workspace.focusedPane
        let scope = WorkspaceIOLifecycle.Scope.documentBatch(pane)
        workspaceIOLifecycle.invalidate(.sessionRestore)
        workspaceIOTasks.cancel(.sessionRestore)
        workspaceIOTasks.cancel(.documentOpen(pane))
        workspaceIOTasks.cancel(.editorDrop(pane))
        workspaceIOLifecycle.invalidate(.documentOpen(pane))
        workspaceIOLifecycle.invalidate(.editorDrop(pane))
        let token = workspaceIOLifecycle.begin(scope)
        workspaceIOTasks.launch(in: scope, priority: .userInitiated) {
            var outcome = DocumentOpenBatchOutcome()
            var openedVault = false
            for url in request.urls {
                guard workspaceIOLifecycle.isCurrent(token) else { return }
                let attempt: DocumentOpenAttempt
                do {
                    switch try await workspace.classifyLocalEntry(at: url) {
                    case .regularFile:
                        attempt = await openFile(
                            url,
                            in: pane,
                            presentingOutcome: false,
                            lifecycleToken: token)
                    case .directory where !openedVault:
                        openedVault = await openVaultRoot(url, presentingOutcome: false)
                        attempt = openedVault
                            ? .opened
                            : .failed("The vault could not be opened safely.")
                    case .directory:
                        attempt = .failed("Only one vault can be opened from a single batch.")
                    case .unsupported:
                        attempt = .failed("This item is not a regular file or folder.")
                    }
                } catch is CancellationError {
                    return
                } catch {
                    let message = WorkspaceIOFailure.presentation(
                        error,
                        operation: .openDocument,
                        item: url)
                    attempt = message.map(DocumentOpenAttempt.failed) ?? .cancelled
                }
                outcome.record(attempt, item: url)
            }
            guard workspaceIOLifecycle.isCurrent(token) else { return }
            if !outcome.failures.isEmpty || outcome.omittedFailureCount > 0
                || request.dropped > 0
            {
                emitWorkspaceIO(
                    .workspaceIOBatchIncomplete,
                    failedCount: outcome.failures.count + outcome.omittedFailureCount,
                    droppedCount: request.dropped)
            }
            errorMessage = outcome.failureMessage ?? request.truncationMessage
            workspaceIOLifecycle.finish(token)
        }
        return true
    }

    /// Opens Markdown dropped directly on an editor in one new trailing pane.
    /// Additional Markdown files from the same drag become tabs in that pane.
    /// Unsupported items are not claimed by this pane target.
    @discardableResult
    private func openDroppedMarkdown(_ urls: [URL], beside pane: PaneID) -> Bool {
        let markdown = urls.filter { FileTree.isMarkdown($0) && !$0.hasDirectoryPath }
        let request = DocumentOpenRequest.bounded(
            markdown,
            limit: WorkspaceIOBounds.maximumOpenItems)
        guard !request.isEmpty else { return false }
        dropTargetPane = nil
        let scope = WorkspaceIOLifecycle.Scope.editorDrop(pane)
        workspaceIOLifecycle.invalidate(.sessionRestore)
        workspaceIOTasks.cancel(.sessionRestore)
        workspaceIOTasks.cancel(.documentOpen(pane))
        workspaceIOTasks.cancel(.documentBatch(pane))
        workspaceIOLifecycle.invalidate(.documentOpen(pane))
        workspaceIOLifecycle.invalidate(.documentBatch(pane))
        let token = workspaceIOLifecycle.begin(scope)
        workspaceIOTasks.launch(in: scope, priority: .userInitiated) {
            var outcome = DocumentOpenBatchOutcome()
            var destination: PaneID?
            for url in request.urls {
                guard workspaceIOLifecycle.isCurrent(token) else { return }
                let attempt: DocumentOpenAttempt
                do {
                    guard try await workspace.classifyLocalEntry(at: url) == .regularFile else {
                        outcome.record(
                            .failed("This item is not a regular Markdown file."),
                            item: url)
                        continue
                    }
                    if let destination {
                        try await workspace.openAsync(url, in: destination) {
                            workspaceIOLifecycle.isCurrent(token)
                        }
                    } else {
                        destination = try await workspace.openAsync(
                            url,
                            beside: pane,
                            edge: .trailing)
                        {
                            workspaceIOLifecycle.isCurrent(token)
                        }
                    }
                    attempt = .opened
                } catch is CancellationError {
                    return
                } catch {
                    let message = WorkspaceIOFailure.presentation(
                        error,
                        operation: .openDocument,
                        item: url)
                    attempt = message.map(DocumentOpenAttempt.failed) ?? .cancelled
                }
                outcome.record(attempt, item: url)
            }
            guard workspaceIOLifecycle.isCurrent(token) else { return }
            if let destination {
                workspace.focusedPane = destination
                refreshVault()
                persistSession()
            }
            if !outcome.failures.isEmpty || outcome.omittedFailureCount > 0
                || request.dropped > 0
            {
                emitWorkspaceIO(
                    .workspaceIOBatchIncomplete,
                    failedCount: outcome.failures.count + outcome.omittedFailureCount,
                    droppedCount: request.dropped)
            }
            errorMessage = outcome.failureMessage ?? request.truncationMessage
            workspaceIOLifecycle.finish(token)
        }
        return true
    }

    @discardableResult
    private func openVaultRoot(
        _ url: URL,
        presentingOutcome: Bool = true
    ) async -> Bool {
        let token = workspaceIOLifecycle.begin(.vault)
        defer { workspaceIOLifecycle.finish(token) }
        do {
            let index = try await VaultIndexRegistry.shared.indexAsync(for: url)
            try Task.checkCancellation()
            guard workspaceIOLifecycle.isCurrent(token), let root = index.root else {
                return false
            }
            workspace.vaultRoot = root
            vault = index
            startWatching(root)
            refreshVault()
            NSDocumentController.shared.noteNewRecentDocumentURL(root)
            persistSession()
            if presentingOutcome {
                errorMessage = index.initialScanStatus?.isComplete == false
                    ? "The vault opened, but some files were skipped. Check Diagnostics for coverage."
                    : nil
            }
            if index.initialScanStatus?.isComplete == false {
                emitWorkspaceIO(.workspaceIOBatchIncomplete, item: root)
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard workspaceIOLifecycle.isCurrent(token) else { return false }
            emitWorkspaceIO(.workspaceVaultOpenFailed, item: url)
            if presentingOutcome {
                errorMessage = WorkspaceIOFailure.presentation(
                    error,
                    operation: .openVault,
                    item: url)
            }
            return false
        }
    }

    private func scheduleVaultOpen(_ url: URL) {
        workspaceIOLifecycle.invalidateAll()
        workspaceIOTasks.cancelAll()
        workspaceIOTasks.launch(in: .vault, priority: .userInitiated) {
            _ = await openVaultRoot(url)
        }
    }

    /// Starts (or joins) the shared watch for an open vault.
    ///
    /// Subscribing alone is not enough to make this window correct: FSEvents
    /// drops writes that race a stream's birth, and every note changed
    /// between ``VaultIndex/open``'s scan and this subscription sits outside
    /// any event by construction. One catch-up sweep — debounced past both
    /// windows — walks the vault and reconciles whatever slipped through,
    /// additions and deletions alike. It re-reads files ``open`` already
    /// parsed microseconds ago; idempotent, and cheap next to being wrong.
    private func startWatching(_ root: URL) {
        // Re-subscribing over the same root must not orphan the old token:
        // cancel it first or the coordinator would fan out twice to here.
        stopWatching()
        guard BoundedRegularFileReader.hasLocalFileAuthority(root) else { return }
        watchToken = VaultWatchCoordinator.shared.subscribe(to: root) { paths in
            handleWatchedPaths(paths)
        }
        watchedRoot = root.standardizedFileURL

        let index = vault
        let expectedRoot = root.standardizedFileURL
        let token = workspaceIOLifecycle.begin(.watchCatchUp)
        workspaceIOTasks.launch(in: .watchCatchUp, priority: .utility) {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled,
                workspaceIOLifecycle.isCurrent(token),
                workspace.vaultRoot?.standardizedFileURL == expectedRoot,
                vault === index
            else { return }
            let result = await index.reconcileWithDisk(excluding: openDocumentURLs)
            guard !Task.isCancelled,
                workspaceIOLifecycle.isCurrent(token),
                workspace.vaultRoot?.standardizedFileURL == expectedRoot,
                vault === index
            else { return }
            if result.changedNotes > 0 {
                vaultRevision += 1
            }
            if !result.isComplete {
                emitWorkspaceIO(.workspaceIOBatchIncomplete)
                errorMessage = WorkspaceIOFailure.presentation(
                    VaultIndexError.openFailed,
                    operation: .watchVault,
                    item: nil)
            }
            workspaceIOLifecycle.finish(token)
        }
    }

    private func stopWatching() {
        workspaceIOLifecycle.invalidate(.watcher)
        workspaceIOLifecycle.invalidate(.watchCatchUp)
        workspaceIOTasks.cancel(.watcher)
        workspaceIOTasks.cancel(.watchCatchUp)
        if let watchToken, let watchedRoot {
            VaultWatchCoordinator.shared.unsubscribe(watchToken, root: watchedRoot)
        }
        watchToken = nil
        watchedRoot = nil
    }

    /// Files currently held by an editor anywhere in this window; their
    /// buffers outrank the disk during reconciliation, exactly as in
    /// ``handleWatchedPaths``.
    private var openDocumentURLs: Set<URL> {
        var urls = Set<URL>()
        for pane in workspace.layout.panes {
            for document in workspace.state(for: pane).documents {
                if let url = document.url {
                    urls.insert(url.standardizedFileURL)
                }
            }
        }
        return urls
    }

    // MARK: - Vault file operations

    /// Creates `Untitled.md` (numbered as needed) in `folder` and opens it.
    private func createNote(in folder: URL) {
        let pane = workspace.focusedPane
        let scope = WorkspaceIOLifecycle.Scope.createNote(pane)
        guard let vaultRoot = workspace.vaultRoot,
            BoundedRegularFileReader.hasLocalFileAuthority(vaultRoot),
            isLexicallyInside(folder, root: vaultRoot)
        else {
            errorMessage = WorkspaceIOFailure.presentation(
                WorkspaceError.unsafeDestination(folder),
                operation: .createDocument,
                item: folder)
            return
        }
        let expectedRoot = vaultRoot.standardizedFileURL
        guard !workspaceIOTasks.isActive(scope) else {
            errorMessage = "A note is already being created in this pane."
            return
        }
        workspaceIOLifecycle.invalidate(.sessionRestore)
        workspaceIOTasks.cancel(.sessionRestore)
        let token = workspaceIOLifecycle.begin(scope)
        workspaceIOTasks.launch(in: scope, priority: .userInitiated) {
            do {
                let created = try await workspace.createUniqueEmptyDocument(
                    in: folder,
                    pane: pane,
                    maximumAttempts: WorkspaceIOBounds.maximumCreateAttempts)
                {
                    workspaceIOLifecycle.isCurrent(token)
                        && workspace.vaultRoot?.standardizedFileURL == expectedRoot
                }
                guard workspaceIOLifecycle.isCurrent(token),
                    workspace.vaultRoot?.standardizedFileURL == expectedRoot
                else { return }
                NSDocumentController.shared.noteNewRecentDocumentURL(created.url)
                vaultRevision += 1
                refreshVault()
                persistSession()
                errorMessage = created.isFullyDurable
                    ? nil
                    : "The note was created, but storage has not confirmed its directory entry yet."
                if !created.isFullyDurable {
                    emitWorkspaceIO(.workspaceCreateFailed, item: created.url)
                }
            } catch is CancellationError {
                return
            } catch {
                guard workspaceIOLifecycle.isCurrent(token) else { return }
                emitWorkspaceIO(.workspaceCreateFailed, item: folder)
                errorMessage = WorkspaceIOFailure.presentation(
                    error,
                    operation: .createDocument,
                    item: folder)
            }
            workspaceIOLifecycle.finish(token)
        }
    }

    /// Asks for a new name, then moves the note and rewrites its links.
    ///
    /// The rewrite is the core's to do — it is the only place that knows how
    /// a target resolves — and open documents are retargeted afterwards, so
    /// a note being edited keeps its buffer instead of fighting the watcher
    /// over which version is real.
    private func renameNote(at url: URL) {
        Task { @MainActor in
            guard let name = await prompt(
                "Rename", field: url.deletingPathExtension().lastPathComponent)
            else { return }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            // A name is one path component: separators would invent folders
            // and `..` would walk out of them. Refused here rather than
            // "handled" downstream, because a rename that lands somewhere
            // unexpected reads as the note having vanished.
            guard !trimmed.isEmpty, !trimmed.contains("/"), trimmed != ".", trimmed != "..",
                !trimmed.hasPrefix(".")
            else { return }

            guard workspace.vaultRoot != nil,
                !workspace.isOutsideVault(url)
            else { return }
            let destination = url.deletingLastPathComponent()
                .appendingPathComponent(trimmed)
                .appendingPathExtension("md")

            applyRename(from: url, to: destination)
        }
    }

    /// Moves one note and settles the open-document consequences before the
    /// next item in a drag batch is allowed to start. The caller owns watcher
    /// suspension and the final UI refresh so a many-note drop remains one
    /// operation rather than recursively starting competing rename tasks.
    private func performRename(
        from url: URL,
        to destination: URL,
        root: URL,
        index: VaultIndex,
        token: WorkspaceIOLifecycle.Token
    ) async throws -> WorkspaceRenameAttempt {
        for candidate in [url, destination, root] {
            guard BoundedRegularFileReader.hasLocalFileAuthority(candidate) else {
                throw WorkspaceError.unsupportedLocation(candidate)
            }
        }
        let from = relativePath(of: url, from: root)
        let to = relativePath(of: destination, from: root)
        let outcome = try await index.renameNoteOffMain(from: from, to: to)
        guard workspaceIOLifecycle.isCurrent(token),
            workspace.vaultRoot?.standardizedFileURL == root,
            vault === index
        else { throw CancellationError() }

        let report: WorkspaceDiskRebaseReport
        do {
            report = try await workspace.rebaseFromDiskAsync(
                from: url,
                to: destination,
                within: root)
        } catch is CancellationError {
            guard workspaceIOLifecycle.isCurrent(token),
                workspace.vaultRoot?.standardizedFileURL == root,
                vault === index
            else { throw CancellationError() }
            // The Rust owner reports cancellation only before the irreversible
            // move. Once it returned an outcome, the note is already at its
            // destination and must remain a partial success in the UI.
            emitWorkspaceIO(.workspaceRenameFailed, item: url)
            return .movedWithIssue(
                "The note moved, but its open-tab updates were interrupted.")
        } catch {
            guard workspaceIOLifecycle.isCurrent(token),
                workspace.vaultRoot?.standardizedFileURL == root,
                vault === index
            else { throw CancellationError() }
            emitWorkspaceIO(.workspaceRenameFailed, item: url)
            return .movedWithIssue(
                WorkspaceIOFailure.presentation(
                    error,
                    operation: .renameDocument,
                    item: url)
                    ?? "The note moved, but its open-tab updates could not be completed.")
        }
        guard workspaceIOLifecycle.isCurrent(token),
            workspace.vaultRoot?.standardizedFileURL == root,
            vault === index
        else { throw CancellationError() }

        let rebaseFailures = report.staleDocumentCount
            + report.failedItemNames.count
            + report.omittedFailureCount
            + report.omittedDocumentCount
        let linkFailures = max(outcome.failedRewrites, outcome.isComplete ? 0 : 1)
        let failureCount = linkFailures + rebaseFailures
        guard failureCount > 0 else { return .moved }
        emitWorkspaceIO(
            .workspaceRenameFailed,
            item: url,
            failedCount: failureCount)
        return .movedWithIssue(
            "The note moved, but \(failureCount) related updates failed.")
    }

    /// Moves a note within the vault and settles every consequence: open
    /// views follow it, bystander rewrites are rebased so no phantom banner
    /// appears for this app's own edit, and the session is re-recorded.
    ///
    /// One body for both entries — the Rename… command and a note dragged
    /// onto a folder — because "what a rename means" must not depend on how
    /// it was asked for.
    private func applyRename(from url: URL, to destination: URL) {
        guard let vaultRoot = workspace.vaultRoot,
            BoundedRegularFileReader.hasLocalFileAuthority(vaultRoot),
            isLexicallyInside(url, root: vaultRoot),
            isLexicallyInside(destination, root: vaultRoot)
        else {
            errorMessage = WorkspaceIOFailure.presentation(
                WorkspaceError.unsafeDestination(destination),
                operation: .renameDocument,
                item: url)
            return
        }
        let root = vaultRoot.standardizedFileURL
        let scope = WorkspaceIOLifecycle.Scope.rename
        guard !workspaceIOTasks.isActive(scope) else {
            errorMessage = "Finish the current note move before starting another."
            return
        }
        let index = vault
        let token = workspaceIOLifecycle.begin(scope)
        stopWatching()
        workspaceIOTasks.launch(in: scope, priority: .userInitiated) {
            defer {
                if workspaceIOLifecycle.isCurrent(token),
                    workspace.vaultRoot?.standardizedFileURL == root,
                    vault === index
                {
                    startWatching(root)
                }
                workspaceIOLifecycle.finish(token)
            }
            do {
                let attempt = try await performRename(
                    from: url,
                    to: destination,
                    root: root,
                    index: index,
                    token: token)
                guard workspaceIOLifecycle.isCurrent(token),
                    workspace.vaultRoot?.standardizedFileURL == root,
                    vault === index
                else { return }

                vaultRevision += 1
                refreshVault()
                persistSession()
                var result = WorkspaceRenameBatchOutcome()
                result.record(attempt, item: url)
                errorMessage = result.issueMessage
            } catch is CancellationError {
                return
            } catch {
                guard workspaceIOLifecycle.isCurrent(token) else { return }
                emitWorkspaceIO(.workspaceRenameFailed, item: url)
                errorMessage = WorkspaceIOFailure.presentation(
                    error,
                    operation: .renameDocument,
                    item: url)
            }
        }
    }

    /// Notes dropped on a folder: one move per dropped note, failures named
    /// rather than swallowed. A drag routinely carries several files; only
    /// Markdown inside this vault is claimed.
    private func dropNotes(_ urls: [URL], into folder: URL) {
        let request = WorkspaceRenameBatchRequest.bounded(urls)
        guard let vaultRoot = workspace.vaultRoot,
            BoundedRegularFileReader.hasLocalFileAuthority(vaultRoot),
            isLexicallyInside(folder, root: vaultRoot)
        else {
            errorMessage = WorkspaceIOFailure.presentation(
                WorkspaceError.unsafeDestination(folder),
                operation: .renameDocument,
                item: folder)
            return
        }
        let root = vaultRoot.standardizedFileURL
        var moves: [(source: URL, destination: URL)] = []
        moves.reserveCapacity(request.urls.count)
        for fileURL in request.urls {
            guard FileTree.isMarkdown(fileURL), !fileURL.hasDirectoryPath,
                workspace.isInsideVault(fileURL)
            else { continue }

            // Dropping onto the note's own folder is a no-op, not an error.
            let destination = folder.appendingPathComponent(
                fileURL.deletingPathExtension().lastPathComponent)
                .appendingPathExtension("md")
            if destination.standardizedFileURL == fileURL { continue }
            guard isLexicallyInside(destination, root: root) else { continue }
            moves.append((fileURL, destination.standardizedFileURL))
        }
        guard !moves.isEmpty else {
            if let message = request.truncationMessage { errorMessage = message }
            return
        }
        let plannedMoves = moves

        let scope = WorkspaceIOLifecycle.Scope.rename
        guard !workspaceIOTasks.isActive(scope) else {
            errorMessage = "Finish the current note move before starting another."
            return
        }
        let index = vault
        let token = workspaceIOLifecycle.begin(scope)
        stopWatching()
        workspaceIOTasks.launch(in: scope, priority: .userInitiated) {
            defer {
                if workspaceIOLifecycle.isCurrent(token),
                    workspace.vaultRoot?.standardizedFileURL == root,
                    vault === index
                {
                    startWatching(root)
                }
                workspaceIOLifecycle.finish(token)
            }
            var outcome = WorkspaceRenameBatchOutcome()
            for move in plannedMoves {
                guard !Task.isCancelled, workspaceIOLifecycle.isCurrent(token) else { return }
                do {
                    let attempt = try await performRename(
                        from: move.source,
                        to: move.destination,
                        root: root,
                        index: index,
                        token: token)
                    outcome.record(attempt, item: move.source)
                } catch is CancellationError {
                    return
                } catch {
                    guard workspaceIOLifecycle.isCurrent(token) else { return }
                    emitWorkspaceIO(.workspaceRenameFailed, item: move.source)
                    let message = WorkspaceIOFailure.presentation(
                        error,
                        operation: .renameDocument,
                        item: move.source)
                        ?? "The note could not be moved safely."
                    outcome.record(.failed(message), item: move.source)
                }
            }
            guard workspaceIOLifecycle.isCurrent(token),
                workspace.vaultRoot?.standardizedFileURL == root,
                vault === index
            else { return }
            if outcome.movedCount > 0 {
                vaultRevision += 1
                refreshVault()
                persistSession()
            }
            if !outcome.issues.isEmpty || outcome.omittedIssueCount > 0 || request.dropped > 0 {
                emitWorkspaceIO(
                    .workspaceIOBatchIncomplete,
                    failedCount: outcome.issues.count + outcome.omittedIssueCount,
                    droppedCount: request.dropped)
            }
            let messages = [outcome.issueMessage, request.truncationMessage].compactMap { $0 }
            errorMessage = messages.isEmpty ? nil : messages.joined(separator: " ")
        }
    }

    /// Reviews every affected persistence risk, then confirms and performs one
    /// exact Trash mutation. The file moves before its tabs close so an I/O
    /// failure leaves the workspace untouched; closure is synchronous after a
    /// successful move because the exact document snapshots are already
    /// approved and revalidated.
    private func trashVaultItem(at url: URL) {
        Task { @MainActor in await reviewAndTrashVaultItem(at: url) }
    }

    private func reviewAndTrashVaultItem(at url: URL) async {
        guard BoundedRegularFileReader.hasLocalFileAuthority(url),
            let vaultRoot = workspace.vaultRoot,
            BoundedRegularFileReader.hasLocalFileAuthority(vaultRoot)
        else {
            errorMessage = "Open a vault before moving one of its items to the Trash."
            return
        }
        let doomed = url.standardizedFileURL
        let expectedVaultRoot = vaultRoot.standardizedFileURL
        let vaultComponents = expectedVaultRoot.resolvingSymlinksInPath().pathComponents
        let targetComponents = doomed.resolvingSymlinksInPath().pathComponents
        guard targetComponents.count > vaultComponents.count,
            Array(targetComponents.prefix(vaultComponents.count)) == vaultComponents
        else {
            errorMessage = "Only an item inside the open vault can be moved to the Trash."
            return
        }
        // Containment compares components, never string prefixes — trashing
        // `Notes` must not reach into `Notes-copy`. This is the same rule
        // ``VaultIndex/relativePath(for:)`` enforces, restated here because
        // this function once violated it and closed sibling folders' tabs.
        func isInside(_ candidate: URL) -> Bool {
            let home = doomed.pathComponents
            let theirs = candidate.pathComponents
            return theirs.count > home.count && Array(theirs.prefix(home.count)) == home
        }

        func affectedDocuments() -> [OpenDocument] {
            var seen: Set<OpenDocument.ID> = []
            var affected: [OpenDocument] = []
            for pane in workspace.layout.panes {
                for document in workspace.state(for: pane).documents {
                    guard seen.insert(document.id).inserted,
                        let documentURL = document.url?.standardizedFileURL,
                        documentURL == doomed || isInside(documentURL)
                    else { continue }
                    affected.append(document)
                }
            }
            return affected
        }

        let autosaveSuspension = suspendAutosaveForCloseReview()
        defer { releaseAutosaveSuspension(autosaveSuspension) }

        let originalDocuments = affectedDocuments()
        guard let reviewedDocuments = await reviewDocumentsForClose(
            originalDocuments.filter(\.requiresCloseReview))
        else { return }
        guard let documentApproval = DestructiveDocumentApproval(
            originalDocuments: originalDocuments,
            reviewedDocuments: reviewedDocuments),
            documentApproval.isCurrent(affectedDocuments())
        else {
            errorMessage =
                "An affected document changed while Trash review was open. Nothing was moved."
            return
        }

        let approvedTarget: SecureTrashTarget
        do {
            approvedTarget = try await Task.detached(priority: .userInitiated) {
                try SecureTrashTarget(at: doomed)
            }.value
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        let trashDecision = await closeReviews.requestVaultTrashDecision(
            VaultTrashPresentation(
                targetName: url.lastPathComponent,
                affectedDocumentCount: documentApproval.documents.count))
        guard trashDecision.action == .moveToTrash else {
            finishTrashPrompt(id: trashDecision.promptID)
            return
        }
        guard workspace.vaultRoot?.standardizedFileURL == expectedVaultRoot,
            documentApproval.isCurrent(affectedDocuments())
        else {
            errorMessage =
                "The vault item or an affected document changed while confirmation was open. Nothing was moved."
            finishTrashPrompt(id: trashDecision.promptID)
            return
        }

        guard let operationGeneration = beginApprovedTrashOperation(
            promptID: trashDecision.promptID,
            targetName: url.lastPathComponent)
        else {
            errorMessage = "The Trash approval expired before the operation began. Nothing was moved."
            finishTrashPrompt(id: trashDecision.promptID)
            return
        }
        defer { finishDestructiveOperation(operationGeneration) }

        let mutation: SecureTrashTarget.MutationResult
        do {
            // Revalidation and Foundation's blocking move share one off-main
            // synchronous seam. `SecureTrashTarget` documents the remaining
            // equal-UID pathname race that FileManager cannot close atomically.
            mutation = try await Task.detached(priority: .userInitiated) {
                try approvedTarget.moveToTrashIfCurrent()
            }.value
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        guard mutation == .moved else {
            errorMessage =
                "The vault item changed after confirmation. The replacement was not moved."
            return
        }

        var closedDocumentIDs: Set<OpenDocument.ID> = []
        for pane in workspace.layout.panes {
            for document in workspace.state(for: pane).documents {
                guard let documentURL = document.url?.standardizedFileURL,
                    documentURL == doomed || isInside(documentURL)
                else { continue }
                let outcome = workspace.close(document.id, in: pane)
                closedDocumentIDs.formUnion(outcome.documentIDsNoLongerOpen)
            }
        }
        externalConflicts.subtract(closedDocumentIDs)
        if !url.hasDirectoryPath {
            vault.removeNote(relativePath(of: doomed, from: expectedVaultRoot))
        }
        vaultRevision += 1
        refreshVault()
        persistSession()
    }

    private func finishTrashPrompt(id: UUID) {
        dismissTransient { $0 == .destructivePrompt(id) }
    }

    private func beginApprovedTrashOperation(
        promptID: UUID,
        targetName: String
    ) -> TransientPresentationCoordinator.Generation? {
        guard let active = transientPresentation.active,
            active.presentation == .destructivePrompt(promptID)
        else { return nil }
        let result = transientPresentation.beginDestructiveOperation(
            promptID: promptID,
            generation: active.generation,
            title: "Moving \(targetName) to the Trash…")
        guard case .replaced(previous: _, current: let generation) = result else {
            return nil
        }
        return generation
    }

    private func finishDestructiveOperation(
        _ generation: TransientPresentationCoordinator.Generation
    ) {
        handleTransientDismissal(transientPresentation.dismiss(generation))
    }

    private func relativePath(of url: URL, from root: URL) -> String {
        let rootComponents = root.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard components.count > rootComponents.count else { return url.lastPathComponent }
        return components.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private func isLexicallyInside(_ url: URL, root: URL) -> Bool {
        guard BoundedRegularFileReader.hasLocalFileAuthority(url),
            BoundedRegularFileReader.hasLocalFileAuthority(root)
        else { return false }
        let rootComponents = root.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        return components.count > rootComponents.count
            && components.prefix(rootComponents.count).elementsEqual(rootComponents)
    }

    /// One text prompt with a prefilled field. Shared by rename today; new-
    /// folder and similar asks belong here too rather than growing their own
    /// alert plumbing.
    private func prompt(_ title: String, field prefill: String) async -> String? {
        guard let window = windowForFocus else {
            errorMessage = "The rename sheet needs an open document window."
            return nil
        }
        guard window.attachedSheet == nil else {
            errorMessage = "Finish the current dialog before renaming a note."
            return nil
        }
        guard let lease = beginNativePanel() else { return nil }
        defer { finishNativePanel(lease) }

        let alert = NSAlert()
        alert.messageText = title
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = prefill
        alert.accessoryView = input
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = input
        let response = await alert.beginSheetModal(for: window)
        guard nativePanelIsCurrent(lease), response == .alertFirstButtonReturn else {
            return nil
        }
        return input.stringValue
    }

    /// Reacts to a batch of watched changes, coalesced.
    ///
    /// Three consumers, one event stream. The navigator re-scans on anything;
    /// the index is fed only Markdown *not* open in an editor, because for
    /// those the editor's buffer is authoritative — indexing disk text under
    /// it would make backlinks describe a version the reader cannot see and
    /// is about to overwrite.
    private func handleWatchedPaths(_ changedPaths: [String]) {
        guard let expectedRoot = workspace.vaultRoot?.standardizedFileURL else { return }
        let index = vault
        let scope = WorkspaceIOLifecycle.Scope.watcher
        let token = workspaceIOLifecycle.begin(scope)
        workspaceIOTasks.launch(in: scope, priority: .utility) {
            do {
                // A save from another tool often lands as several events over
                // a few milliseconds; reacting per event would reindex once
                // per notification instead of once per settled batch.
                try await Task.sleep(for: .milliseconds(350))
                let change = try await workspace.observeExternalChangesAsync(
                    changedPaths,
                    maximumPaths: WorkspaceIOBounds.maximumWatchedPaths)
                guard workspaceIOLifecycle.isCurrent(token),
                    workspace.vaultRoot?.standardizedFileURL == expectedRoot,
                    vault === index
                else { return }

                vaultRevision += 1
                for note in change.changedNotes {
                    _ = index.update(path: note.relativePath, text: note.text)
                }
                for path in change.missingNotePaths {
                    index.removeNote(path)
                }
                externalConflicts.formUnion(change.conflictingDocumentIDs)
                if !change.failedItemNames.isEmpty
                    || change.omittedFailureCount > 0
                    || change.omittedPathCount > 0
                    || change.staleDocumentCount > 0
                {
                    emitWorkspaceIO(
                        .workspaceIOBatchIncomplete,
                        failedCount: change.failedItemNames.count
                            + change.omittedFailureCount
                            + change.staleDocumentCount,
                        droppedCount: change.omittedPathCount)
                    errorMessage = WorkspaceIOFailure.presentation(
                        VaultIndexError.openFailed,
                        operation: .watchVault,
                        item: nil)
                }
            } catch is CancellationError {
                return
            } catch {
                guard workspaceIOLifecycle.isCurrent(token) else { return }
                emitWorkspaceIO(.workspaceExternalReadFailed)
                errorMessage = WorkspaceIOFailure.presentation(
                    error,
                    operation: .watchVault,
                    item: nil)
            }
            workspaceIOLifecycle.finish(token)
        }
    }

    /// The workspace's identity for `url`, if it is open anywhere here.
    private func workspaceOpenDocument(matching url: URL) -> OpenDocument? {
        guard BoundedRegularFileReader.hasLocalFileAuthority(url) else { return nil }
        let normalizedURL = url.standardizedFileURL
        for pane in workspace.layout.panes {
            for document in workspace.state(for: pane).documents
            where document.url?.standardizedFileURL == normalizedURL {
                return document
            }
        }
        return nil
    }

    /// Re-reads a note whose file changed elsewhere, discarding the local view.
    private func acceptExternalVersion(of documentID: OpenDocument.ID) {
        guard let pane = workspace.pane(containing: documentID),
            let document = workspace.state(for: pane).documents.first(where: { $0.id == documentID }),
            let url = document.url
        else {
            errorMessage = WorkspaceIOFailure.presentation(
                WorkspaceError.noDocument,
                operation: .reloadDocument,
                item: nil)
            return
        }
        let scope = WorkspaceIOLifecycle.Scope.externalDocument(documentID)
        let token = workspaceIOLifecycle.begin(scope)
        workspaceIOTasks.launch(in: scope, priority: .userInitiated) {
            do {
                try await workspace.reloadFromDiskAsync(document: documentID)
                guard workspaceIOLifecycle.isCurrent(token) else { return }
                externalConflicts.remove(documentID)
                refreshVault()
                persistSession()
                errorMessage = nil
            } catch is CancellationError {
                return
            } catch {
                // The conflict stays visible: a failed or stale reload is not
                // a resolved conflict.
                guard workspaceIOLifecycle.isCurrent(token) else { return }
                emitWorkspaceIO(.workspaceExternalReadFailed, item: url)
                errorMessage = WorkspaceIOFailure.presentation(
                    error,
                    operation: .reloadDocument,
                    item: url)
            }
            workspaceIOLifecycle.finish(token)
        }
    }

    /// The bar over an editor whose file changed underneath it.
    private func conflictBar(_ document: OpenDocument) -> some View {
        HStack(spacing: GlassTheme.Spacing.snug) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
            Text("\(document.title) changed on disk.")
                .font(.callout)
                .lineLimit(1)
            Spacer(minLength: GlassTheme.Spacing.snug)
            Button("Keep Mine") { keepLocalVersion(of: document.id) }
                .controlSize(.small)
            Button("Reload") { acceptExternalVersion(of: document.id) }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, GlassTheme.Spacing.regular)
        .padding(.vertical, 6)
        .background(.yellow.opacity(0.14))
    }

    /// Keeps the local view while rebasing its guard on the exact bytes now on
    /// disk. The document remains dirty until a guarded save succeeds.
    private func keepLocalVersion(of documentID: OpenDocument.ID) {
        guard let pane = workspace.pane(containing: documentID),
            let url = workspace.state(for: pane).documents.first(where: {
                $0.id == documentID
            })?.url
        else {
            errorMessage = WorkspaceIOFailure.presentation(
                WorkspaceError.noDocument,
                operation: .reloadDocument,
                item: nil)
            return
        }
        let scope = WorkspaceIOLifecycle.Scope.externalDocument(documentID)
        let token = workspaceIOLifecycle.begin(scope)
        workspaceIOTasks.launch(in: scope, priority: .userInitiated) {
            do {
                try await workspace.keepLocalAsync(document: documentID)
                guard workspaceIOLifecycle.isCurrent(token) else { return }
                externalConflicts.remove(documentID)
                scheduleAutosave()
                errorMessage = nil
            } catch is CancellationError {
                return
            } catch {
                // Keep the banner until the choice was actually applied.
                guard workspaceIOLifecycle.isCurrent(token) else { return }
                emitWorkspaceIO(.workspaceExternalReadFailed, item: url)
                errorMessage = WorkspaceIOFailure.presentation(
                    error,
                    operation: .reloadDocument,
                    item: url)
            }
            workspaceIOLifecycle.finish(token)
        }
    }

    // MARK: - Session

    /// Whether this window has already read the stored session.
    ///
    /// SwiftUI re-runs `onAppear` when a view re-enters the hierarchy; without
    /// the guard, a later pass would rebuild the window over work the reader
    /// has done since launch.
    @State private var sessionRestored = false
    /// Coalesces session writes; see ``persistSession()``.
    @State private var sessionPersistTask: Task<Void, Never>?
    /// Debounces autosave behind typing; see ``scheduleAutosave()``.
    @State private var autosaveTask: Task<Void, Never>?

    /// What the Go-to-Tab menu shows for the focused pane.
    ///
    /// Capped at nine because ⌘0 is not on offer; a tenth tab still exists
    /// everywhere else (tabs strip, palette), it just has no digit.
    private func makeTabSwitcher() -> TabSwitcher {
        let state = workspace.state(for: workspace.focusedPane)
        return TabSwitcher(
            tabs: state.documents.prefix(9).map { document in
                TabSwitcher.Entry(
                    id: document.id,
                    title: document.title,
                    isCurrent: document.id == state.selection)
            },
            select: { selectTab(at: $0) })
    }

    /// Selects the focused pane's `index`th tab; a no-op past the last one.
    private func selectTab(at index: Int) {
        let documents = workspace.state(for: workspace.focusedPane).documents
        guard documents.indices.contains(index) else { return }
        workspace.select(documents[index].id, in: workspace.focusedPane)
        refreshVault()
        persistSession()
    }

    /// Makes the pane's editor first responder, so ⌥⌘→/← moves the keyboard
    /// and not only the highlighted tab.
    ///
    /// A pane whose editor has not been built yet (a split created this same
    /// turn) simply keeps its stored selection; SwiftUI mounts the view into
    /// the registry, and the next focus move lands without conflating mount
    /// with keyboard ownership.
    private func moveKeyboard(to pane: PaneID) {
        guard let surface = editorSurfaces.surface(in: pane), surface.window != nil else { return }
        windowForFocus?.makeFirstResponder(surface)
    }

    /// This workspace's hosting window, when it is on screen.
    private var windowForFocus: NSWindow? {
        surface.window ?? editorSurfaces.mountedSurfaces.first?.window
    }

    /// Restores the last window shape, once.
    ///
    /// Runs *before* the inbox registration so a file arriving at launch opens
    /// into the restored layout rather than racing it. A snapshot naming a
    /// vault that has since been renamed or removed restores its tabs anyway —
    /// they are absolute paths — and simply leaves the navigator empty, which
    /// is the honest picture of a missing folder.
    private func restoreSessionOnce() {
        guard !sessionRestored else { return }
        sessionRestored = true
        // Claimed, not merely loaded: a second window must start empty rather
        // than open the first window's tabs over its own.
        guard let snapshot = SessionStore.claimRestore() else { return }
        let scope = WorkspaceIOLifecycle.Scope.sessionRestore
        let token = workspaceIOLifecycle.begin(scope)
        workspaceIOTasks.launch(in: scope, priority: .userInitiated) {
            do {
                let report = try await workspace.restoreAsync(from: snapshot) {
                    workspaceIOLifecycle.isCurrent(token)
                }
                guard workspaceIOLifecycle.isCurrent(token) else { return }
                if let root = workspace.vaultRoot {
                    let opened = await openVaultRoot(root, presentingOutcome: false)
                    guard workspaceIOLifecycle.isCurrent(token) else { return }
                    if !opened {
                        emitWorkspaceIO(.workspaceVaultOpenFailed, item: root)
                        errorMessage = WorkspaceIOFailure.presentation(
                            VaultIndexError.openFailed,
                            operation: .restoreSession,
                            item: root)
                    }
                }
                refreshVault()
                if !report.isComplete {
                    emitWorkspaceIO(
                        .workspaceIOBatchIncomplete,
                        failedCount: report.failedItemNames.count
                            + report.omittedFailureCount)
                    errorMessage = WorkspaceIOFailure.presentation(
                        VaultIndexError.openFailed,
                        operation: .restoreSession,
                        item: nil)
                }
            } catch is CancellationError {
                return
            } catch {
                guard workspaceIOLifecycle.isCurrent(token) else { return }
                emitWorkspaceIO(.workspaceIOBatchIncomplete)
                errorMessage = WorkspaceIOFailure.presentation(
                    error,
                    operation: .restoreSession,
                    item: nil)
            }
            workspaceIOLifecycle.finish(token)
        }
    }

    /// Records the window's shape, coalesced.
    ///
    /// Called from every mutation that changes what a relaunch should bring
    /// back — opening, closing, splitting, saving, choosing a vault. Debounced
    /// because several of those arrive together (a drop opens five tabs and
    /// splits a pane), and only the final shape is worth writing.
    private func persistSession() {
        sessionPersistTask?.cancel()
        sessionPersistTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let snapshot = workspace.snapshot()
            await SessionPersistenceLane.shared.save(snapshot)
        }
    }

    /// Writes dirty documents a moment after typing stops.
    ///
    /// Autosave is deliberately not per keystroke and not on a fixed clock:
    /// one debounced write after the reader pauses buys crash safety without
    /// touching the disk mid-sentence. A failure remains non-modal, keeps the
    /// document dirty, and is recorded by the workspace diagnostics; the next
    /// explicit save surfaces the actionable error.
    private func scheduleAutosave() {
        guard !autosaveSuspensions.isSuspended else { return }
        autosaveTask?.cancel()
        autosaveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            let report = await workspace.autosaveAsync()
            guard !Task.isCancelled else { return }
            if report.succeededCount > 0 {
                persistSession()
            }
        }
    }

    /// Recomputes the panels for whatever the focused pane is showing.
    ///
    /// The index is updated from the editor's text rather than the file on
    /// disk, so backlinks reflect what is on screen instead of the last save.
    private func refreshVault() {
        guard let document = workspace.document(in: workspace.focusedPane) else {
            outline = []
            backlinks = []
            mentions = []
            outgoingLinks = []
            warmer.cancel()
            return
        }

        // The editor parse owns the outline, so it works for unsaved and
        // standalone files as well as notes inside a vault.
        outline = documentOutlines[document.id] ?? []

        // The harness runs against a file and a vault, so both follow the
        // focused document. Set before the vault guard below, not after: a note
        // outside any vault is exactly the case where the harness has only the
        // file to go on, and skipping it there would point a run at whichever
        // note happened to be open previously.
        writingTools.harness.documentURL = document.url
        writingTools.harness.vaultURL = workspace.vaultRoot

        guard let url = document.url, let path = vault.relativePath(for: url) else {
            backlinks = []
            mentions = []
            outgoingLinks = []
            warmer.cancel()
            return
        }

        vault.update(path: path, text: document.text)
        backlinks = vault.backlinks(for: path)
        mentions = vault.unlinkedMentions(for: path)
        outgoingLinks = vault.links(for: path)
        // After the update, so a link typed a moment ago is one this can see.
        // Debounced inside the warmer: this runs on every keystroke.
        warmer.warm(
            from: url,
            in: vault,
            owner: ContentPrefetcher.Owner(id: workspace.focusedPane.id))
    }

    /// Publishes cheap parse-derived state immediately and schedules the
    /// whole-document count away from the typing path.
    private func handleParse(
        _ parsed: ParsedDocument,
        text: String,
        document: OpenDocument.ID,
        pane: PaneID
    ) {
        documentOutlines[document] = DocumentOutline.headings(in: parsed, text: text)
        if pane == workspace.focusedPane {
            outline = documentOutlines[document] ?? []
        }
        scheduleStats(for: document, text: text)
    }

    private func scheduleStats(for document: OpenDocument.ID, text: String) {
        statsTasks[document]?.cancel()
        statsTasks[document] = Task {
            do {
                try await Task.sleep(for: .milliseconds(180))
            } catch {
                return
            }
            let computed = await Task.detached(priority: .utility) {
                DocumentStats(text)
            }.value
            guard !Task.isCancelled else { return }
            documentStats[document] = computed
            statsTasks[document] = nil
        }
    }

    private func statusLocation(for document: OpenDocument?) -> String? {
        guard let url = document?.url else { return nil }
        return vault.relativePath(for: url) ?? url.lastPathComponent
    }

    private func pruneOrphanedState() {
        workspace.pruneOrphanedPanes()
        let liveDocuments = Set(
            workspace.layout.panes.flatMap { workspace.state(for: $0).documents.map(\.id) })
        documentStats = documentStats.filter { liveDocuments.contains($0.key) }
        documentOutlines = documentOutlines.filter { liveDocuments.contains($0.key) }
        for id in Array(statsTasks.keys) where !liveDocuments.contains(id) {
            statsTasks[id]?.cancel()
            statsTasks[id] = nil
        }
        // Editors of closed panes would otherwise hand a dead view to
        // ``moveKeyboard(to:)`` on the next ⌥⌘→.
        editorSurfaces.prune(keeping: Set(workspace.layout.panes))
    }

    /// Follows a `[[wikilink]]` from the editor.
    private func followWikiLink(_ raw: String, in pane: PaneID) {
        let (target, anchor) = Self.splitAnchor(raw)
        guard let resolution = vault.resolve(target: target, anchor: anchor),
            let url = vault.url(for: resolution.path)
        else {
            // A link to a note that does not exist yet is normal in a vault;
            // saying so beats doing nothing.
            errorMessage = "No note named “\(target)” in this vault."
            return
        }
        scheduleFileOpen(url, in: pane) { opened in
            if let offset = resolution.offset {
                reveals[opened] = RevealRequest(offset: Int(offset))
            }
        }
    }

    /// Follows a relative Markdown / `file:` link from the editor.
    private func followDocumentLink(_ raw: String, in pane: PaneID) {
        guard let documentDirectory = workspace.document(in: pane)?.url?
            .deletingLastPathComponent()
        else {
            errorMessage = "Save this note before following relative links."
            return
        }

        let (target, anchor) = Self.splitAnchor(raw)
        let destination: URL
        if target.hasPrefix("/") {
            // Either a `file:` absolute path inside the vault, or Obsidian's
            // vault-root-relative `/docs/note.md`. Prefer an in-vault absolute
            // hit; otherwise resolve from the vault root.
            let absolute = URL(fileURLWithPath: target).standardizedFileURL
            if vault.relativePath(for: absolute) != nil {
                destination = absolute
            } else if let root = vault.root {
                let relative = String(target.drop(while: { $0 == "/" }))
                destination = root.appendingPathComponent(relative).standardizedFileURL
            } else {
                errorMessage = "That link points outside this vault."
                return
            }
        } else {
            destination = URL(fileURLWithPath: target, relativeTo: documentDirectory)
                .standardizedFileURL
        }

        guard vault.relativePath(for: destination) != nil else {
            errorMessage = "That link points outside this vault."
            return
        }

        let sourcePath = workspace.document(in: pane).flatMap { document in
            document.url.flatMap { vault.relativePath(for: $0) }
        }

        workspaceIOTasks.cancel(.documentBatch(pane))
        workspaceIOTasks.cancel(.editorDrop(pane))
        workspaceIOLifecycle.invalidate(.documentBatch(pane))
        workspaceIOLifecycle.invalidate(.editorDrop(pane))
        workspaceIOLifecycle.invalidate(.sessionRestore)
        workspaceIOTasks.cancel(.sessionRestore)
        workspaceIOTasks.launch(in: .documentOpen(pane), priority: .userInitiated) {
            let entry: WorkspaceLocalEntryKind?
            do {
                entry = try await workspace.classifyLocalEntry(at: destination)
            } catch {
                errorMessage = "That file could not be opened."
                return
            }

            let kind: DocumentLinkOpenKind
            switch entry {
            case .some(.directory):
                kind = .classify(isDirectory: true, isRegularFile: false, isMarkdown: false)
            case .some(.regularFile):
                kind = .classify(
                    isDirectory: false,
                    isRegularFile: true,
                    isMarkdown: FileTree.isMarkdown(destination))
            case .some(.unsupported), .none:
                kind = .missing
            }

            switch kind {
            case .markdownNote:
                let result = await openFile(destination, in: pane)
                guard result.didOpen else { return }
                guard let anchor, !anchor.isEmpty, let sourcePath else { return }
                if let resolution = vault.resolve(
                    from: sourcePath, target: target, anchor: anchor),
                    let offset = resolution.offset
                {
                    reveals[pane] = RevealRequest(offset: Int(offset))
                }
            case .directory:
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            case .otherFile:
                NSWorkspace.shared.open(destination)
            case .missing:
                errorMessage = "No such file: \(destination.lastPathComponent)"
            }
        }
    }

    private static func splitAnchor(_ raw: String) -> (String, String?) {
        guard let hash = raw.firstIndex(of: "#") else { return (raw, nil) }
        return (
            String(raw[raw.startIndex..<hash]),
            String(raw[raw.index(after: hash)...])
        )
    }

    // MARK: - Commands

    /// The only enablement snapshot for menus, palette rows, and pane chrome.
    /// It is rebuilt from observable state, so a close, split, editor mount,
    /// proofreading result, harness discovery, or destructive transition
    /// invalidates every surface in the same SwiftUI update.
    private var commandAvailability: CommandAvailability {
        _ = commandSurfaceRevision
        let focusedPane = workspace.focusedPane
        let focusedSurface = editorSurfaces.surface(in: focusedPane)
        let hasAttachedWritingSurface = focusedSurface != nil
            && writingTools.inline.surface === focusedSurface
            && writingTools.document.surface === focusedSurface
            && writingTools.harness.surface === focusedSurface

        let hasTerminalSlot = terminals.sessions.count < TerminalSessions.limit
            || terminals.sessions.contains(where: { !$0.isLive })
        var canRevealHarnessTerminal = false
        if case .found(let location) = writingTools.harness.availability {
            let directory = workspace.document(in: focusedPane)?.url?.deletingLastPathComponent()
                ?? workspace.vaultRoot
            let requested = TerminalSession.resolve(
                document: nil,
                vault: directory,
                startupAction: .runExecutable(location))
            let hasReusableSession = terminals.sessions.contains { session in
                session.isLive
                    && session.config.workingDirectory == requested.workingDirectory
                    && session.config.startupAction == requested.startupAction
            }
            canRevealHarnessTerminal = hasReusableSession || hasTerminalSlot
        }

        return CommandAvailability(
            hasFocusedPane: workspace.layout.panes.contains(focusedPane),
            paneCount: workspace.layout.paneCount,
            hasDocument: workspace.document(in: focusedPane) != nil,
            hasEditorSurface: focusedSurface != nil,
            hasAttachedWritingSurface: hasAttachedWritingSurface,
            hasTextSelection: (selectionStats[focusedPane]?.chars ?? 0) > 0,
            hasProofreadingMarks: hasAttachedWritingSurface
                && !writingTools.document.issues.isEmpty,
            canRevealHarnessTerminal: canRevealHarnessTerminal,
            isPerformingDestructiveOperation:
                transientPresentation.isPerformingDestructiveOperation)
    }

    private var commands: [Command] {
        var list: [Command] = [
            Command(
                title: "New Document", symbol: "doc.badge.plus",
                kind: .action(.newDocument), shortcut: "⌘N"),
            Command(
                title: "New Window", symbol: "macwindow.on.rectangle",
                kind: .action(.newWindow)),
            Command(
                title: "Open File…", symbol: "doc",
                kind: .action(.openFile), shortcut: "⌘O"),
            Command(
                title: "Open Vault…", symbol: "folder",
                kind: .action(.openVault), shortcut: "⇧⌘O"),
            Command(
                title: "Save", symbol: "square.and.arrow.down",
                kind: .action(.save), shortcut: "⌘S"),
            Command(
                title: "Save As…", symbol: "square.and.arrow.down.on.square",
                kind: .action(.saveAs), shortcut: "⇧⌘S"),
            Command(
                title: showSidebar ? "Hide Sidebar" : "Show Sidebar", symbol: "sidebar.leading",
                kind: .action(.toggleSidebar), shortcut: "⌘\\"),
            Command(
                title: showInspector ? "Hide Inspector" : "Show Inspector",
                symbol: "sidebar.trailing", kind: .action(.toggleInspector), shortcut: "⌥⌘I"),
            Command(
                title: isTerminalVisible ? "Hide Terminal" : "Show Terminal",
                symbol: "apple.terminal", kind: .action(.toggleTerminal), shortcut: "⌘J"),
            Command(
                title: showGraph ? "Hide Graph" : "Graph View",
                symbol: "point.3.filled.connected.trianglepath.dotted",
                kind: .action(.toggleGraph), shortcut: "⌥⌘G"),
            Command(
                title: SplitEdge.trailing.commandTitle,
                subtitle: SplitEdge.trailing.controlHelp,
                symbol: SplitEdge.trailing.symbol,
                kind: .action(.splitRight)),
            Command(
                title: SplitEdge.bottom.commandTitle,
                subtitle: SplitEdge.bottom.controlHelp,
                symbol: SplitEdge.bottom.symbol,
                kind: .action(.splitDown)),
            Command(
                title: "Rewrite Selection…", symbol: "apple.intelligence",
                kind: .action(.writingTools), shortcut: "⇧⌘E"),
            Command(
                title: "Proofread Document", symbol: "text.badge.checkmark",
                kind: .action(.proofreadDocument), shortcut: "⇧⌘P"),
            Command(
                title: "Clear Proofreading Marks", symbol: "eraser",
                kind: .action(.clearProofreading)),
            Command(
                title: "Read This Note",
                subtitle: "Summary, key points, a title, and tags",
                symbol: "sparkles.rectangle.stack",
                kind: .action(.analyzeNote)),
            Command(
                title: "Ask MANVI…",
                subtitle: "The local harness, with the whole vault to read",
                symbol: "cpu", kind: .action(.askHarness)),
            Command(
                title: "Run MANVI in a Terminal",
                symbol: "apple.terminal", kind: .action(.openHarnessTerminal)),
            Command(
                title: terminalPlacement == .drawer
                    ? "Move Terminal to Sidebar" : "Move Terminal to Drawer",
                symbol: terminalPlacement == .drawer
                    ? "arrow.right.to.line" : "arrow.down.to.line",
                kind: .action(.moveTerminal)),
            Command(
                title: "Zoom In", symbol: "plus.magnifyingglass",
                kind: .action(.zoomIn), shortcut: "⌘+"),
            Command(
                title: "Zoom Out", symbol: "minus.magnifyingglass",
                kind: .action(.zoomOut), shortcut: "⌘-"),
            Command(
                title: "Actual Size", symbol: "1.magnifyingglass",
                kind: .action(.resetZoom), shortcut: "⌘0"),
            Command(
                title: "Export as HTML…", symbol: "square.and.arrow.up",
                kind: .action(.exportHTML)),
            Command(
                title: "Print…", symbol: "printer",
                kind: .action(.printDocument), shortcut: "⌘P"),
        ]

        if workspace.layout.paneCount > 1 {
            list += [
                Command(
                    title: "Close Pane", symbol: "xmark.rectangle",
                    kind: .action(.closePane), shortcut: "⌃⌘W"),
                Command(
                    title: "Focus Next Pane", symbol: "arrow.forward.square",
                    kind: .action(.focusNextPane), shortcut: "⌥⌘→"),
                Command(
                    title: "Focus Previous Pane", symbol: "arrow.backward.square",
                    kind: .action(.focusPreviousPane), shortcut: "⌥⌘←"),
            ]
        }

        // Built from the enum rather than written out, so a mode cannot exist
        // in the switcher and be missing from the palette.
        list += EditorMode.allCases.enumerated().map { index, editorMode in
            Command(
                title: editorMode.commandTitle,
                subtitle: editorMode.summary,
                symbol: editorMode.symbol,
                kind: .action(.setMode(editorMode)),
                shortcut: "⌃\(index + 1)")
        }

        // Every vault note is reachable, not just an already-open tab. URLs
        // are deduplicated because one document may be visible in many panes.
        var seen: Set<URL> = []
        for path in vault.notePaths() {
            guard let url = vault.url(for: path), seen.insert(url).inserted else { continue }
            list.append(
                Command(
                    title: url.deletingPathExtension().lastPathComponent,
                    subtitle: path,
                    symbol: "doc.text",
                    kind: .file(url)))
        }
        for pane in workspace.layout.panes {
            for (position, document) in workspace.state(for: pane).documents.enumerated() {
                guard let url = document.url, seen.insert(url).inserted else { continue }
                // The focused pane's tabs carry their ⌘N shortcut here, so
                // the palette is where a reader can *see* that ⌘3 means
                // anything — the menu shows it too, but only once looked at.
                let shortcut =
                    pane == workspace.focusedPane && position < 9
                    ? "⌘\(position + 1)" : nil
                list.append(
                    Command(
                        title: document.title,
                        subtitle: url.deletingLastPathComponent().path,
                        symbol: "doc.text",
                        kind: .file(url),
                        shortcut: shortcut))
            }
        }
        return list
    }

    /// Full-text hits for the palette, from the vault's own search index.
    ///
    /// The context line is the snippet the core scored, trimmed of the
    /// Markdown it is dressed in so a row reads at palette size.
    private func contentSearchCommands(for query: String) async -> [Command] {
        let hits = await vault.searchOffMain(query, limit: 8)
        guard !Task.isCancelled else { return [] }
        return hits.compactMap { hit in
            guard let url = vault.url(for: hit.path) else { return nil }
            var context = hit.context.trimmingCharacters(in: .whitespacesAndNewlines)
            if context.count > 80 {
                context = String(context.prefix(80)) + "…"
            }
            return Command(
                title: hit.title,
                subtitle: context.isEmpty ? hit.path : context,
                symbol: "magnifyingglass",
                kind: .searchResult(url, line: hit.line))
        }
    }

    private func run(_ command: Command) {
        guard commandAvailability.allows(command.kind) else { return }
        switch command.kind {
        case .file(let url):
            scheduleFileOpen(url)
        case .searchResult(let url, let line):
            scheduleFileOpen(url) { pane in
                if let text = workspace.document(in: pane)?.text {
                    reveals[pane] = RevealRequest(
                        offset: Command.offset(ofLine: line, in: text))
                }
            }
        case .action(let action):
            run(action)
        }
    }

    private func run(_ action: CommandAction) {
        guard commandAvailability.allows(action) else { return }
        switch action {
        case .newDocument:
            retireSessionRestore()
            workspace.newDocument(in: workspace.focusedPane)
            refreshVault()
        case .newWindow:
            openWindow(id: MarkDevApp.workspaceWindowID)
        case .toggleCommandPalette: showPalette.toggle()
        case .openFile: openFilePanel()
        case .openVault: openVault()
        case .save: saveDocument()
        case .saveAs: saveDocumentAs()
        case .toggleSidebar: showSidebar.toggle()
        case .toggleInspector: showInspector.toggle()
        case .toggleTerminal: setTerminal(visible: !isTerminalVisible)
        case .toggleGraph: showGraph.toggle()
        case .splitRight:
            retireSessionRestore()
            workspace.split(workspace.focusedPane, edge: .trailing)
            persistSession()
        case .splitDown:
            retireSessionRestore()
            workspace.split(workspace.focusedPane, edge: .bottom)
            persistSession()
        case .closePane: closePane(workspace.focusedPane)
        case .focusNextPane: workspace.focusPane(offset: 1)
        case .focusPreviousPane: workspace.focusPane(offset: -1)
        case .setMode(let editorMode): mode = editorMode
        case .writingTools: writingTools.inline.open()
        case .proofreadDocument: runProofreading()
        case .clearProofreading: writingTools.document.clearIssues()
        case .analyzeNote: analyzeNote()
        case .askHarness: showAssist(engine: .harness)
        case .openHarnessTerminal: openHarnessTerminal()
        case .moveTerminal: setTerminalPlacement(terminalPlacement.other)
        case .zoomIn:
            editorSurfaces.surface(in: workspace.focusedPane)?.zoomIn()
        case .zoomOut:
            editorSurfaces.surface(in: workspace.focusedPane)?.zoomOut()
        case .resetZoom:
            editorSurfaces.surface(in: workspace.focusedPane)?.resetZoom()
        case .exportHTML:
            exportHTML()
        case .printDocument:
            printDocument()
        }
    }

    private func exportHTML() {
        Task { @MainActor in await chooseHTMLExportDestination() }
    }

    private func chooseHTMLExportDestination() async {
        guard let doc = workspace.document(in: workspace.focusedPane) else { return }
        guard let window = windowForFocus else {
            errorMessage = "The Export sheet needs an open document window."
            return
        }
        guard window.attachedSheet == nil else {
            errorMessage = "Finish the current dialog before exporting HTML."
            return
        }
        guard let lease = beginNativePanel() else { return }
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.html]
        savePanel.nameFieldStringValue = (doc.url?.deletingPathExtension().lastPathComponent ?? "Untitled") + ".html"
        let response = await savePanel.beginSheetModal(for: window)
        guard nativePanelIsCurrent(lease) else { return }
        finishNativePanel(lease)
        guard response == .OK, let url = savePanel.url else { return }

        let title = doc.url?.deletingPathExtension().lastPathComponent ?? "Document"
        do {
            try await Task.detached(priority: .userInitiated) {
                try HTMLExporter.write(markdown: doc.text, title: title, to: url)
            }.value
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func printDocument() {
        guard let surface = editorSurfaces.surface(in: workspace.focusedPane) else { return }
        surface.printView(nil)
    }

    /// Starts a proofreading pass and shows where its results will appear.
    ///
    /// Revealing the panel is part of the action, not a nicety: a pass whose
    /// findings land in a hidden tab reads as a menu item that did nothing
    /// except draw some underlines with no way to act on them.
    private func runProofreading() {
        showAssist(engine: .apple)
        writingTools.document.proofread()
    }

    private func analyzeNote() {
        showAssist(engine: .apple)
        writingTools.document.analyze()
    }

    /// Opens the Assist panel on one engine.
    ///
    /// Revealing the panel is part of every one of these actions, not a
    /// nicety: a result that lands in a hidden tab reads as a menu item that
    /// did nothing.
    private func showAssist(engine: AssistEngine) {
        showInspector = true
        inspectorTab = .assist
        assistEngine = engine
        if engine == .harness {
            writingTools.harness.documentURL =
                workspace.document(in: workspace.focusedPane)?.url
            writingTools.harness.vaultURL = workspace.vaultRoot
            writingTools.harness.refreshAvailability()
        }
    }

    private func openVault() {
        Task { @MainActor in await chooseVault() }
    }

    private func chooseVault() async {
        guard let window = windowForFocus else {
            errorMessage = "The Open Vault sheet needs an open document window."
            return
        }
        guard window.attachedSheet == nil else {
            errorMessage = "Finish the current dialog before opening a vault."
            return
        }
        guard let lease = beginNativePanel() else { return }
        defer { finishNativePanel(lease) }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Vault"
        let response = await panel.beginSheetModal(for: window)
        guard nativePanelIsCurrent(lease), response == .OK, let url = panel.url else {
            return
        }
        scheduleVaultOpen(url)
    }

    // MARK: - Document lifecycle

    private func openFilePanel() {
        Task { @MainActor in await chooseFiles() }
    }

    private func chooseFiles() async {
        guard let window = windowForFocus else {
            errorMessage = "The Open sheet needs an open document window."
            return
        }
        guard window.attachedSheet == nil else {
            errorMessage = "Finish the current dialog before opening files."
            return
        }
        guard let lease = beginNativePanel() else { return }
        defer { finishNativePanel(lease) }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Open"
        let response = await panel.beginSheetModal(for: window)
        guard nativePanelIsCurrent(lease), response == .OK else { return }
        _ = open(dropped: panel.urls)
    }

    private func saveDocument(in pane: PaneID? = nil) {
        let pane = pane ?? workspace.focusedPane
        guard let document = workspace.document(in: pane) else {
            errorMessage = WorkspaceError.noDocument.localizedDescription
            return
        }
        Task { @MainActor in
            _ = await saveDocument(document.id, in: pane)
        }
    }

    /// Saves the document named by an alert, not whichever tab happens to be
    /// selected while that modal alert is on screen.
    private func saveDocument(_ documentID: OpenDocument.ID, in pane: PaneID) async -> Bool {
        guard let document = workspace.state(for: pane).documents.first(where: {
            $0.id == documentID
        }) else {
            errorMessage = WorkspaceError.noDocument.localizedDescription
            return false
        }
        guard document.url != nil else {
            return await saveDocumentAs(documentID, in: pane)
        }
        do {
            _ = try await workspace.saveAsync(document: documentID)
            refreshVault()
            persistSession()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func saveDocumentAs(in pane: PaneID? = nil) {
        let pane = pane ?? workspace.focusedPane
        guard let document = workspace.document(in: pane) else {
            errorMessage = WorkspaceError.noDocument.localizedDescription
            return
        }
        Task { @MainActor in
            _ = await saveDocumentAs(document.id, in: pane)
        }
    }

    private func saveDocumentAs(
        _ documentID: OpenDocument.ID,
        in pane: PaneID
    ) async -> Bool {
        guard let document = workspace.state(for: pane).documents.first(where: {
            $0.id == documentID
        }) else {
            errorMessage = WorkspaceError.noDocument.localizedDescription
            return false
        }
        guard let window = windowForFocus else {
            errorMessage = "The Save sheet needs an open document window."
            return false
        }
        guard window.attachedSheet == nil else {
            errorMessage = "Finish the current dialog before saving this document."
            return false
        }
        guard let lease = beginNativePanel() else { return false }
        defer { finishNativePanel(lease) }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = document.url?.lastPathComponent ?? "Untitled.md"
        panel.prompt = "Save"
        let response = await panel.beginSheetModal(for: window)
        guard nativePanelIsCurrent(lease), response == .OK, let url = panel.url else {
            return false
        }

        do {
            // NSSavePanel has already obtained explicit overwrite consent.
            let authorization = try await workspace.authorizeSaveDestination(
                url, overwrite: true)
            guard nativePanelIsCurrent(lease) else { return false }
            _ = try await workspace.saveAsync(
                document: documentID,
                authorization: authorization)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            refreshVault()
            persistSession()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func closeDocument(_ document: OpenDocument.ID, in pane: PaneID) {
        retireSessionRestore()
        Task { @MainActor in
            guard let expected = workspace.state(for: pane).documents.first(where: {
                $0.id == document
            }) else { return }
            let autosaveSuspension = suspendAutosaveForCloseReview()
            defer { releaseAutosaveSuspension(autosaveSuspension) }

            let approved: OpenDocument
            if workspace.requiresConfirmationBeforeClosing(document, in: pane) {
                guard let reviewed = await reviewDocumentForClose(expected) else { return }
                approved = reviewed
            } else {
                approved = expected
            }

            guard workspace.state(for: pane).documents.contains(where: {
                $0.id == document
            }), currentDocument(document) == approved else { return }
            let outcome = workspace.close(document, in: pane)
            retireExternalIOTasks(for: outcome.documentIDsNoLongerOpen)
            externalConflicts.subtract(outcome.documentIDsNoLongerOpen)
            if pane == workspace.focusedPane { refreshVault() }
            persistSession()
        }
    }

    private func closePane(_ pane: PaneID) {
        retireSessionRestore()
        Task { @MainActor in
            // The layout refuses to remove the last pane, so asking about its
            // work first would prompt for a close that cannot happen.
            guard workspace.layout.paneCount > 1,
                workspace.layout.panes.contains(pane)
            else { return }
            let originalDocuments = workspace.state(for: pane).documents
            let originalIDs = originalDocuments.map(\.id)
            let candidates = originalDocuments.filter {
                workspace.requiresConfirmationBeforeClosing($0.id, in: pane)
            }
            let autosaveSuspension = suspendAutosaveForCloseReview()
            defer { releaseAutosaveSuspension(autosaveSuspension) }
            guard let approvals = await reviewDocumentsForClose(candidates) else { return }
            let approvalsByID = Dictionary(
                uniqueKeysWithValues: approvals.map { ($0.id, $0) })
            let current = workspace.state(for: pane).documents
            guard current.map(\.id) == originalIDs,
                approvals.allSatisfy({ currentDocument($0.id) == $0 }),
                current.filter({
                    workspace.requiresConfirmationBeforeClosing($0.id, in: pane)
                }).allSatisfy({ approvalsByID[$0.id] == $0 })
            else { return }

            let outcome = workspace.closePane(pane)
            retirePaneIOTasks(pane)
            retireExternalIOTasks(for: outcome.documentIDsNoLongerOpen)
            externalConflicts.subtract(outcome.documentIDsNoLongerOpen)
            refreshVault()
            persistSession()
        }
    }

    private func retireExternalIOTasks(for documentIDs: Set<OpenDocument.ID>) {
        for documentID in documentIDs {
            let scope = WorkspaceIOLifecycle.Scope.externalDocument(documentID)
            workspaceIOLifecycle.invalidate(scope)
            workspaceIOTasks.cancel(scope)
        }
    }

    private func retirePaneIOTasks(_ pane: PaneID) {
        let scopes: [WorkspaceIOLifecycle.Scope] = [
            .documentOpen(pane),
            .documentBatch(pane),
            .editorDrop(pane),
            .createNote(pane),
        ]
        for scope in scopes {
            workspaceIOLifecycle.invalidate(scope)
            workspaceIOTasks.cancel(scope)
        }
    }

    /// Reviews every unique persistence risk before the window or app exits.
    /// Split views share document identities, so a note is never prompted for
    /// twice merely because it is visible in two panes.
    private func reviewClosingAll() async -> Bool {
        discardWindowCloseApproval(resumeAutosave: false)
        let autosaveSuspension = suspendAutosaveForCloseReview()
        var retainedSuspension = false
        defer {
            if !retainedSuspension { releaseAutosaveSuspension(autosaveSuspension) }
        }

        guard let documentApprovals = await reviewDocumentsForClose(
            workspace.documentsRequiringCloseReview),
            documentApprovalsAreCurrent(documentApprovals)
        else { return false }

        let terminalRisks = terminals.closeRisks
        guard await reviewTerminalRisks(terminalRisks, purpose: .closeWindow),
            documentApprovalsAreCurrent(documentApprovals)
        else { return false }

        windowCloseApproval = WindowCloseApproval(
            documents: allWorkspaceDocuments,
            terminals: terminals.closeRisks,
            autosaveSuspension: autosaveSuspension)
        guard windowCloseApprovalIsCurrent() else {
            windowCloseApproval = nil
            return false
        }
        retainedSuspension = true
        return true
    }

    private func windowCloseApprovalIsCurrent() -> Bool {
        guard let windowCloseApproval else { return false }
        return windowCloseApproval.documents == allWorkspaceDocuments
            && windowCloseApproval.terminals == terminals.closeRisks
    }

    private func cancelWindowCloseApproval() {
        discardWindowCloseApproval(resumeAutosave: true)
    }

    private func workspaceWindowWillClose() {
        discardWindowCloseApproval(resumeAutosave: false)
        closeReviews.cancelActivePrompt()
        transientPresentation.invalidateAll()
        _ = autosaveSuspensions.invalidateAll()
        autosaveTask?.cancel()
        autosaveTask = nil
        terminals.endAllHosts()
    }

    private func suspendAutosaveForCloseReview() -> AutosaveSuspensionGate.Token {
        let token = autosaveSuspensions.acquire()
        autosaveTask?.cancel()
        autosaveTask = nil
        return token
    }

    private func releaseAutosaveSuspension(_ token: AutosaveSuspensionGate.Token) {
        guard autosaveSuspensions.release(token) else { return }
        resumeAutosaveIfNeeded()
    }

    private func discardWindowCloseApproval(resumeAutosave: Bool) {
        guard let approval = windowCloseApproval else { return }
        windowCloseApproval = nil
        if resumeAutosave {
            releaseAutosaveSuspension(approval.autosaveSuspension)
        } else {
            _ = autosaveSuspensions.release(approval.autosaveSuspension)
        }
    }

    private func resumeAutosaveIfNeeded() {
        // Start from the complete persistence-risk set so close lifecycle code
        // never regresses to treating text dirtiness as the only risk. Only an
        // edited member needs the debounce timer; durability-only risk is
        // handled explicitly by the close review action matrix.
        if workspace.documentsRequiringCloseReview.contains(where: \.hasUnsavedChanges) {
            scheduleAutosave()
        }
    }

    private var allWorkspaceDocuments: [OpenDocument] {
        var seen: Set<OpenDocument.ID> = []
        return workspace.layout.panes.flatMap { workspace.state(for: $0).documents }
            .filter { seen.insert($0.id).inserted }
    }

    private func currentDocument(_ id: OpenDocument.ID) -> OpenDocument? {
        guard let pane = workspace.pane(containing: id) else { return nil }
        return workspace.state(for: pane).documents.first { $0.id == id }
    }

    private func reviewDocumentsForClose(
        _ documents: [OpenDocument]
    ) async -> [OpenDocument]? {
        guard documents.count <= Self.maximumDocumentsPerCloseReview else {
            errorMessage =
                "This close request contains too many documents to review safely. Close some panes or tabs and try again."
            return nil
        }
        var approvals: [OpenDocument] = []
        approvals.reserveCapacity(documents.count)
        for document in documents {
            guard let approved = await reviewDocumentForClose(document) else { return nil }
            approvals.append(approved)
        }
        return approvals
    }

    /// Returns the exact post-decision document state that may be destroyed.
    /// A later caller compares it again without an intervening `await`.
    private func reviewDocumentForClose(_ expected: OpenDocument) async -> OpenDocument? {
        guard currentDocument(expected.id) == expected else {
            errorMessage =
                "\(expected.title) changed before close review began. Nothing was closed."
            return nil
        }
        guard let presentation = DocumentPersistencePresentation(document: expected) else {
            return expected
        }

        let action = await closeReviews.requestDocument(presentation)
        if action == .cancel { return nil }
        guard currentDocument(expected.id) == expected else {
            errorMessage =
                "\(expected.title) changed while its close decision was open. Nothing was closed."
            return nil
        }

        switch action {
        case .closeAnyway:
            return expected
        case .save, .saveAgain:
            return await saveDocumentDurablyForClose(expected)
        case .retryDurability:
            return await retryDocumentDurabilityForClose(expected)
        case .cancel:
            return nil
        }
    }

    private func saveDocumentDurablyForClose(
        _ expected: OpenDocument
    ) async -> OpenDocument? {
        do {
            let outcome: WorkspaceSaveOutcome
            if expected.url != nil {
                outcome = try await workspace.saveWithOutcome(document: expected.id)
            } else {
                guard let authorization = try await closeSaveAuthorization(for: expected)
                else { return nil }
                guard currentDocument(expected.id) == expected else {
                    errorMessage =
                        "\(expected.title) changed while the save destination was open. Nothing was closed."
                    return nil
                }
                outcome = try await workspace.saveWithOutcome(
                    document: expected.id,
                    authorization: authorization)
            }

            if outcome.didSettleLiveDocument {
                NSDocumentController.shared.noteNewRecentDocumentURL(outcome.destination)
                refreshVault()
                persistSession()
            }
            guard outcome.didSettleLiveDocument else {
                errorMessage =
                    "The file was written, but the open document changed before the save result could be applied. Nothing was closed."
                return nil
            }
            guard outcome.isFullyDurable else {
                errorMessage =
                    "The file was written, but MarkDev could not confirm durable directory storage. Retry durability or save again before closing."
                return nil
            }
            guard let saved = currentDocument(expected.id), !saved.requiresCloseReview else {
                errorMessage =
                    "The document changed while it was being saved. Review the current version before closing."
                return nil
            }
            return saved
        } catch is CancellationError {
            return nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func retryDocumentDurabilityForClose(
        _ expected: OpenDocument
    ) async -> OpenDocument? {
        do {
            let result = try await workspace.confirmDurability(document: expected.id)
            switch result {
            case .confirmed, .notRequired:
                guard let confirmed = currentDocument(expected.id),
                    !confirmed.requiresCloseReview
                else {
                    errorMessage =
                        "The document changed while durability was being confirmed. Nothing was closed."
                    return nil
                }
                persistSession()
                return confirmed
            case .authorityUnavailable:
                errorMessage =
                    "The saved file’s retained durability authority is no longer available. Choose Save Again before closing."
                return nil
            case .stale:
                errorMessage =
                    "The document changed while durability was being confirmed. Nothing was closed."
                return nil
            }
        } catch is CancellationError {
            return nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func closeSaveAuthorization(
        for expected: OpenDocument
    ) async throws -> WorkspaceSaveAuthorization? {
        guard let window = surface.window else {
            errorMessage = "The Save sheet needs an open document window. Nothing was closed."
            return nil
        }
        guard await waitForAttachedSheetToDismiss(from: window) else {
            errorMessage =
                "Another sheet is still open for this window. Finish it, then try closing again."
            return nil
        }

        let panel = NSSavePanel()
        panel.identifier = NSUserInterfaceItemIdentifier("close-review.save-panel")
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Untitled.md"
        panel.prompt = "Save"
        let response = await panel.beginSheetModal(for: window)
        try Task.checkCancellation()
        guard response == .OK, let destination = panel.url else { return nil }
        guard currentDocument(expected.id) == expected else { return nil }
        // The save panel obtained explicit overwrite consent. Capture exact
        // destination authority off-main before any bytes are published.
        return try await workspace.authorizeSaveDestination(
            destination, overwrite: true)
    }

    private func waitForAttachedSheetToDismiss(from window: NSWindow) async -> Bool {
        for _ in 0..<40 {
            guard !Task.isCancelled else { return false }
            if window.attachedSheet == nil { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return window.attachedSheet == nil
    }

    private func documentApprovalsAreCurrent(_ approvals: [OpenDocument]) -> Bool {
        let byID = Dictionary(uniqueKeysWithValues: approvals.map { ($0.id, $0) })
        guard approvals.allSatisfy({ currentDocument($0.id) == $0 }) else { return false }
        return workspace.documentsRequiringCloseReview.allSatisfy { byID[$0.id] == $0 }
    }

    private func reviewTerminalRisks(
        _ risks: [TerminalCloseRisk],
        purpose: TerminalClosePurpose
    ) async -> Bool {
        guard let presentation = TerminalClosePresentation(risks: risks, purpose: purpose)
        else { return risks.isEmpty }
        let action = await closeReviews.requestTerminals(presentation)
        let expected: TerminalCloseReviewAction =
            purpose == .restartSession ? .stopAndRestart : .stopAndClose
        guard action == expected else { return false }
        let isCurrent: Bool
        switch purpose {
        case .closeWindow:
            isCurrent = terminals.areUnchangedOrExited(afterReviewing: risks)
        case .closeSessions, .restartSession:
            isCurrent = risks.allSatisfy {
                terminals.isUnchangedOrExited(afterReviewing: $0)
            }
        }
        guard isCurrent else {
            errorMessage =
                "A terminal started or restarted while its close decision was open. Nothing was stopped."
            return false
        }
        return true
    }
}

/// A toolbar button that shows whether the panel it controls is open.
///
/// Both panel toggles used to render identically whether their panel was
/// showing or not, so the only way to know what the button would do was to
/// press it and watch. Tinting the glass while the panel is open makes the
/// control read as a switch — the same treatment the current tab gets.
private struct ChromeToggle: View {
    let symbol: String
    let label: String
    let isOn: Bool
    let reduceMotion: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .foregroundStyle(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                // Inside the label: the whole glass circle is the target, not
                // just the glyph. See ``View/controlTarget(_:padding:)``.
                .controlTarget(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(
            isOn
                ? .regular.tint(.accentColor.opacity(0.22)).interactive()
                : .regular.interactive(),
            in: .circle
        )
        .scaleEffect(isHovering ? 1.06 : 1)
        .onHover { isHovering = $0 }
        .animation(
            GlassTheme.motion(GlassTheme.quickSpring, reduceMotion: reduceMotion),
            value: isHovering)
        .animation(
            GlassTheme.motion(GlassTheme.quickSpring, reduceMotion: reduceMotion),
            value: isOn)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}
