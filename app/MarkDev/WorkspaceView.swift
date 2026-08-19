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
    @State private var workspace = Workspace()
    @State private var showPalette = false
    @State private var dropTargetPane: PaneID?

    // Shell preferences outlive the window. Resizing the navigator or picking
    // a writing mode is a decision about how someone works, not about the
    // document in front of them, and making them re-make it at every launch
    // is the whole reason chrome settings feel disposable.
    @AppStorage("shell.showSidebar") private var showSidebar = true
    @AppStorage("shell.showInspector") private var showInspector = true
    @AppStorage("shell.editorMode") private var mode: EditorMode = .livePreview
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

    /// Derived editor state, keyed by document identity so tabs and split
    /// views share it without recomputing.
    @State private var documentStats: [OpenDocument.ID: DocumentStats] = [:]
    @State private var documentOutlines: [OpenDocument.ID: [VaultHeading]] = [:]
    @State private var statsTasks: [OpenDocument.ID: Task<Void, Never>] = [:]

    /// Apple Intelligence for this window.
    @State private var writingTools = WritingTools()

    /// The vault's link graph. Owned here so every pane shares one index.
    @State private var vault = VaultIndex()

    /// Reads ahead along the focused note's links. Owned beside the index it
    /// asks, and for the same reason: one window, one read-ahead.
    @State private var warmer = ConnectedNoteWarmer()
    @State private var outline: [VaultHeading] = []
    @State private var backlinks: [Backlink] = []
    @State private var mentions: [UnlinkedMention] = []

    /// Surfaced rather than swallowed: opening and saving can fail for
    /// reasons the user can act on, and a silent no-op reads as a broken app.
    @State private var errorMessage: String?

    /// Pending scroll-to-offset per pane, from the outline and from links.
    @State private var reveals: [PaneID: RevealRequest] = [:]

    /// The note under the held Space bar, if any.
    @State private var peek: URL?

    /// The window this workspace is in, and how ready it is to be shown a
    /// document opened from Finder. Filled in by ``HostWindowReader``.
    @State private var surface = DocumentSurface()

    /// This workspace's registration with ``DocumentInbox``, withdrawn when it
    /// goes away. Held so *this* registration is withdrawn and no other:
    /// SwiftUI builds a throwaway workspace for every incoming file open, and
    /// clearing a shared handler would let the throwaway's departure silence
    /// the window on screen.
    @State private var inboxRegistration: DocumentSurfaceToken?

    /// Whether the link graph is up.
    @State private var showGraph = false

    /// Where MANVI is, or `nil` if it could not be found. See the note on
    /// ``findHarness()``.
    @State private var harnessBinary: URL?

    /// Every open shell. Owned here, not by the drawer, so hiding the drawer
    /// does not kill a running build — see ``TerminalSessions``.
    @State private var terminals = TerminalSessions()
    /// Whether the drawer has ever been opened in this window.
    ///
    /// Once it has, it stays mounted — collapsed to nothing when hidden — so
    /// the shells inside it survive ⌘J. Until then it is not built at all, so
    /// an app whose terminal is never opened never forks one.
    @State private var terminalMounted = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glass

    /// Vertical space the floating toolbar occupies, so content can clear it.
    private static let toolbarHeight: CGFloat = 52

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

    var body: some View {
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
        .background(.background)
        // Dropping files on a window is how a Mac editor is expected to accept
        // work, and it is the only route into MarkDev that needs neither the
        // menu bar nor prior knowledge of ⌘K. A dropped folder opens as a
        // vault, which is the only sensible reading of a folder here.
        .dropDestination(for: URL.self) { urls, _ in
            open(dropped: urls)
        }
        .background(WindowCloseGuard { confirmClosingAll() })
        .background(HostWindowReader(surface: surface))
        .focusedSceneValue(
            \.workspaceCommandHandler,
            WorkspaceCommandHandler { run($0) })
        .alert(
            "Couldn’t Complete Action",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .animation(GlassTheme.motion(GlassTheme.spring, reduceMotion: reduceMotion), value: showSidebar)
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

                    CommandPalette(isPresented: $showPalette, commands: commands) { run($0) }
                        .padding(.top, 90)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .scale(scale: 0.94, anchor: .top)
                                    .combined(with: .opacity)
                                    .combined(with: .offset(y: -14)))
                }
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
                        openFile(target)
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
                        openFile(url)
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
        .coordinateSpace(.named(Self.workspaceSpace))
        // Keeps the last real measurement rather than clearing it. Collapsing
        // removes the header, which publishes zero; resetting on that would
        // send the rule back to its fallback and make it visibly slide into
        // place on every re-open. Only the first open ever uses the fallback.
        .onPreferenceChange(SidebarHeaderBottomKey.self) { bottom in
            if bottom > 0 { sidebarHeaderBottom = bottom }
        }
        .onChange(of: workspace.layout) { _, _ in pruneOrphanedState() }
        .onChange(of: workspace.focusedPane) { _, _ in refreshVault() }
        .onOpenURL(perform: openFile)
        // Files from Finder, the Dock, or `open`. Registered rather than
        // drained: a double-click that launches the app delivers its request
        // before this view exists, and SwiftUI builds a throwaway workspace
        // for each request besides — so the inbox picks the surface with a
        // window on screen instead of trusting whoever asked last.
        .onAppear {
            findHarness()
            if let inboxRegistration { DocumentInbox.shared.unregister(inboxRegistration) }
            inboxRegistration = DocumentInbox.shared.register(
                readiness: { surface.readiness },
                deliver: { takeFromInbox($0) })
        }
        .animation(
            GlassTheme.motion(GlassTheme.spring, reduceMotion: reduceMotion),
            value: showInspector)
        .animation(
            GlassTheme.motion(GlassTheme.spring, reduceMotion: reduceMotion),
            value: showTerminal)
        .onDisappear {
            if let inboxRegistration {
                DocumentInbox.shared.unregister(inboxRegistration)
            }
            inboxRegistration = nil
            for task in statsTasks.values { task.cancel() }
            // The shells are owned by ``TerminalSessions`` now, not by the
            // views, which is what lets the terminal be moved between panels
            // without restarting. The cost is that a window going away no
            // longer ends them by itself, so it has to be said here — and
            // again in ``LiveShells`` for the case a window never closes,
            // which is Quit.
            terminals.endAllHosts()
        }
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
            onMove: { setTerminalPlacement(placement.other) },
            onOpenHarness: harnessBinary == nil ? nil : { openHarnessTerminal() },
            onError: { errorMessage = $0 }
        )
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

    /// Where MANVI is, looked up once for the window.
    ///
    /// Held rather than computed. It decides whether the terminal's `+` offers
    /// to run the harness, so it is read while a view is being built — and
    /// `body` is re-evaluated on every keystroke, which would make the lookup a
    /// handful of filesystem probes per character typed. Looking it up once
    /// also buys the *full* search, login shell included, which is the only way
    /// to see a `PATH` set by a version manager.

    /// Opens a shell already running the harness, rooted at the note's folder.
    ///
    /// The command is typed into an interactive login shell rather than being
    /// the shell — see ``TerminalSession/initialCommand``. Rooted at the note
    /// rather than at the vault because that is what the reader is working on,
    /// and MANVI resolves everything it reads from where it was started.
    private func findHarness() {
        let configured = writingTools.harness.settings.binaryPath
        Task {
            harnessBinary = await HarnessLocator.locate(configured: configured)?.url
        }
    }

    private func openHarnessTerminal() {
        guard let binary = harnessBinary else {
            errorMessage =
                "MarkDev couldn’t find MANVI. Set its path under MANVI settings in the Assist "
                + "panel."
            return
        }
        let directory =
            workspace.document(in: workspace.focusedPane)?.url?.deletingLastPathComponent()
            ?? workspace.vaultRoot
        let config = TerminalSession.resolve(
            document: nil,
            vault: directory,
            initialCommand: binary.path.contains(" ") ? "\"\(binary.path)\"" : binary.path)
        do {
            try terminals.reveal(config)
            setTerminal(visible: true)
        } catch let failure as TerminalOpenFailure {
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
            HStack(spacing: 0) {
                HStack(spacing: GlassTheme.Spacing.snug) {
                    if showSidebar {
                        brandChip
                            .transition(.move(edge: .leading).combined(with: .opacity))
                        Spacer(minLength: GlassTheme.Spacing.snug)
                    }
                    sidebarToggle
                }
                // The panel below insets itself by `snug` on every side, so
                // the same inset here puts the brand exactly on its top-left
                // corner and the toggle exactly on its top-right. The spacer
                // between them is what holds the two to the corners instead
                // of letting the toggle float mid-column.
                //
                // Collapsed, both the spacer and the trailing inset go with
                // the panel, and the toggle falls back to the leading edge.
                .padding(.leading, GlassTheme.Spacing.snug)
                .padding(.trailing, showSidebar ? GlassTheme.Spacing.snug : 0)
                .frame(width: showSidebar ? sidebarWidth : nil, alignment: .leading)
                // Publishes where this row ends so the panel below can put its
                // rule there. Only while the sidebar is open: collapsed, the
                // row is a lone floating toggle over the canvas and there is
                // no panel to underline.
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
                // The same inset the pane tab bars use, so the search capsule
                // aligns with the first tab and the picker with the pane's
                // trailing controls.
                .padding(.horizontal, GlassTheme.Spacing.snug)
            }
        }
        .padding(.top, GlassTheme.Spacing.snug)
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

    private var modePicker: some View {
        ModeSwitcher(mode: $mode)
            .padding(.horizontal, GlassTheme.Spacing.tight)
            .padding(.vertical, 3)
            .glassEffect(.regular.interactive(), in: .capsule)
            .glassEffectID("mode", in: glass)
    }

    /// Save is a menu rather than a button because "Save As…" has to live
    /// somewhere reachable without the menu bar.
    private var saveMenu: some View {
        Menu {
            Button("Save") { _ = saveDocument() }
            Button("Save As…") { _ = saveDocumentAs() }
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
                onOpen: { openFile($0) },
                onChooseVault: { openVault() },
                onPeek: { peek = $0 },
                onOpenTerminal: { openTerminal(in: $0) }
            )
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
                isSplit: isSplit,
                onSelect: {
                    workspace.select($0, in: pane)
                    if pane == workspace.focusedPane { refreshVault() }
                },
                onClose: { closeDocument($0, in: pane) },
                onSplit: { workspace.split(pane, edge: $0) },
                onClosePane: { closePane(pane) }
            )

            MarkdownEditorView(
                text: Binding(
                    get: { workspace.document(in: pane)?.text ?? "" },
                    set: {
                        workspace.updateText($0, in: pane)
                        if pane == workspace.focusedPane { refreshVault() }
                    }
                ),
                mode: mode,
                documentDirectory: workspace.document(in: pane)?.url?
                    .deletingLastPathComponent(),
                reveal: reveals[pane],
                onParse: { parsed in
                    guard let current = workspace.document(in: pane) else { return }
                    handleParse(parsed, text: current.text, document: current.id, pane: pane)
                },
                onFollowWikiLink: { followWikiLink($0) },
                onSurface: { surface in
                    // Whichever editor holds the keyboard is the one the
                    // writing tools act on, so the pane that reports a
                    // surface is also the focused pane by definition.
                    workspace.focusedPane = pane
                    writingTools.attach(to: surface)
                }
            )
            .onTapGesture { workspace.focusedPane = pane }

            StatusBar(
                location: statusLocation(for: document),
                hasUnsavedChanges: document?.hasUnsavedChanges ?? false,
                stats: document.flatMap { documentStats[$0.id] } ?? .empty)
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
                openFile(url)
                reveals[workspace.focusedPane] = RevealRequest(offset: Int(offset))
            },
            onMoveTerminalHere: { setTerminalPlacement(.inspector) }
        )
        .padding(.top, Self.toolbarHeight)
        .glassPanel(radius: GlassTheme.Radius.large, padding: EdgeInsets())
        .padding(GlassTheme.Spacing.snug)
    }

    // MARK: - Vault

    /// Opens a file, surfacing any failure rather than silently doing nothing.
    private func openFile(_ url: URL) {
        do {
            try workspace.open(url, in: workspace.focusedPane)
            refreshVault()
        } catch {
            errorMessage = error.localizedDescription
        }
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
                DocumentInbox.shared.receive(request.urls)
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

        let truncation = request.truncationMessage
        _ = open(dropped: request.urls)
        // After opening, so a genuine open failure wins the alert: that names
        // one file the reader can act on, while truncation is only a count.
        if errorMessage == nil, let truncation { errorMessage = truncation }
    }

    /// Opens dropped files, and treats a dropped folder as a vault.
    ///
    /// Reports success if *anything* was usable rather than requiring the whole
    /// drop to be: a selection dragged out of Finder routinely carries an
    /// image or a PDF alongside the notes, and rejecting the entire drop for
    /// one of them reads as the app refusing a drag it plainly understood.
    /// Whatever could not be opened still surfaces through the usual alert.
    @discardableResult
    private func open(dropped urls: [URL]) -> Bool {
        var openedAnything = false
        for url in urls {
            let isDirectory =
                (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                openVaultRoot(url)
                openedAnything = true
            } else {
                openFile(url)
                openedAnything = openedAnything || errorMessage == nil
            }
        }
        return openedAnything
    }

    /// Opens Markdown dropped directly on an editor in one new trailing pane.
    /// Additional Markdown files from the same drag become tabs in that pane.
    /// Unsupported items are not claimed by this pane target.
    @discardableResult
    private func openDroppedMarkdown(_ urls: [URL], beside pane: PaneID) -> Bool {
        let markdown = urls.filter(MarkdownDropPolicy.accepts)
        guard !markdown.isEmpty else { return false }

        var destination: PaneID?
        for url in markdown {
            do {
                if let destination {
                    try workspace.open(url, in: destination)
                } else {
                    destination = try workspace.open(url, beside: pane, edge: .trailing)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        dropTargetPane = nil
        guard let destination else { return false }
        workspace.focusedPane = destination
        refreshVault()
        return true
    }

    private func openVaultRoot(_ url: URL) {
        workspace.vaultRoot = url
        vault.open(url)
        refreshVault()
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
            warmer.cancel()
            return
        }

        vault.update(path: path, text: document.text)
        backlinks = vault.backlinks(for: path)
        mentions = vault.unlinkedMentions(for: path)
        // After the update, so a link typed a moment ago is one this can see.
        // Debounced inside the warmer: this runs on every keystroke.
        warmer.warm(from: url, in: vault)
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
    }

    /// Follows a `[[wikilink]]` from the editor.
    private func followWikiLink(_ raw: String) {
        let (target, anchor) = Self.splitAnchor(raw)
        guard let resolution = vault.resolve(target: target, anchor: anchor),
            let url = vault.url(for: resolution.path)
        else {
            // A link to a note that does not exist yet is normal in a vault;
            // saying so beats doing nothing.
            errorMessage = "No note named “\(target)” in this vault."
            return
        }
        openFile(url)
        if let offset = resolution.offset {
            reveals[workspace.focusedPane] = RevealRequest(offset: Int(offset))
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

    private var commands: [Command] {
        var list: [Command] = [
            Command(
                title: "New Document", symbol: "doc.badge.plus",
                kind: .action(.newDocument), shortcut: "⌘N"),
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
                kind: .action(.toggleGraph), shortcut: "⇧⌘G"),
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
            for document in workspace.state(for: pane).documents {
                guard let url = document.url, seen.insert(url).inserted else { continue }
                list.append(
                    Command(
                        title: document.title,
                        subtitle: url.deletingLastPathComponent().path,
                        symbol: "doc.text",
                        kind: .file(url)))
            }
        }
        return list
    }

    private func run(_ command: Command) {
        switch command.kind {
        case .file(let url):
            openFile(url)
        case .action(let action):
            run(action)
        }
    }

    private func run(_ action: CommandAction) {
        switch action {
        case .newDocument:
            workspace.newDocument(in: workspace.focusedPane)
            refreshVault()
        case .toggleCommandPalette: showPalette.toggle()
        case .openFile: openFilePanel()
        case .openVault: openVault()
        case .save: _ = saveDocument()
        case .saveAs: _ = saveDocumentAs()
        case .toggleSidebar: showSidebar.toggle()
        case .toggleInspector: showInspector.toggle()
        case .toggleTerminal: setTerminal(visible: !isTerminalVisible)
        case .toggleGraph: showGraph.toggle()
        case .splitRight: workspace.split(workspace.focusedPane, edge: .trailing)
        case .splitDown: workspace.split(workspace.focusedPane, edge: .bottom)
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
        }
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
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Vault"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openVaultRoot(url)
    }

    // MARK: - Document lifecycle

    private func openFilePanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Open"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { openFile(url) }
    }

    @discardableResult
    private func saveDocument(in pane: PaneID? = nil) -> Bool {
        let pane = pane ?? workspace.focusedPane
        guard workspace.document(in: pane)?.url != nil else {
            return saveDocumentAs(in: pane)
        }
        do {
            try workspace.save(in: pane)
            refreshVault()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    private func saveDocumentAs(in pane: PaneID? = nil) -> Bool {
        let pane = pane ?? workspace.focusedPane
        guard let document = workspace.document(in: pane) else { return false }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = document.url?.lastPathComponent ?? "Untitled.md"
        panel.prompt = "Save"
        guard panel.runModal() == .OK, let url = panel.url else { return false }

        do {
            // NSSavePanel has already obtained explicit overwrite consent.
            try workspace.save(in: pane, to: url, overwrite: true)
            refreshVault()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func closeDocument(_ document: OpenDocument.ID, in pane: PaneID) {
        guard confirmClosing(document, in: pane) else { return }
        workspace.close(document, in: pane)
        if pane == workspace.focusedPane { refreshVault() }
    }

    private func closePane(_ pane: PaneID) {
        // The layout refuses to remove the last pane, so asking about its
        // unsaved work first would prompt for a close that cannot happen.
        // The tab bar hides its close control here; the ⌃⌘W menu item and the
        // palette command reach the same code without that gate.
        guard workspace.layout.paneCount > 1 else { return }
        let documents = workspace.state(for: pane).documents
        guard documents.allSatisfy({ confirmClosing($0.id, in: pane) }) else { return }
        workspace.closePane(pane)
        refreshVault()
    }

    private func confirmClosing(_ documentID: OpenDocument.ID, in pane: PaneID) -> Bool {
        guard workspace.requiresConfirmationBeforeClosing(documentID, in: pane),
              let document = workspace.state(for: pane).documents.first(where: { $0.id == documentID })
        else {
            return true
        }

        return reviewClosing(document, in: pane)
    }

    /// Reviews every unique dirty document before the window or app exits.
    /// Split views share document identities, so a note is never prompted for
    /// twice merely because it is visible in two panes.
    private func confirmClosingAll() -> Bool {
        for document in workspace.documentsWithUnsavedChanges {
            guard let pane = workspace.pane(containing: document.id),
                  reviewClosing(document, in: pane)
            else {
                return false
            }
        }
        return true
    }

    private func reviewClosing(_ document: OpenDocument, in pane: PaneID) -> Bool {

        let alert = NSAlert()
        alert.messageText = "Save changes to \(document.title)?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return saveDocument(in: pane)
        case .alertThirdButtonReturn:
            return true
        default:
            return false
        }
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
