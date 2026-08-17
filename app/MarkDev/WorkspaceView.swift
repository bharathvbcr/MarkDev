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
    @State private var outline: [VaultHeading] = []
    @State private var backlinks: [Backlink] = []
    @State private var mentions: [UnlinkedMention] = []

    /// Surfaced rather than swallowed: opening and saving can fail for
    /// reasons the user can act on, and a silent no-op reads as a broken app.
    @State private var errorMessage: String?

    /// Pending scroll-to-offset per pane, from the outline and from links.
    @State private var reveals: [PaneID: RevealRequest] = [:]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glass

    /// Vertical space the floating toolbar occupies, so content can clear it.
    private static let toolbarHeight: CGFloat = 52

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

                SplitTreeView(layout: workspace.layoutBinding) { pane in
                    paneView(pane)
                }
                // Cleared from the floating toolbar once, at the container,
                // rather than per pane: padding each pane individually pushes
                // every pane in a vertical split down, and leaves the tab bars
                // colliding with the toolbar the moment a split appears.
                .padding(.top, Self.toolbarHeight)
                // Content still runs under the chrome's edges, giving the
                // glass something to refract instead of a flat panel.
                .backgroundExtensionEffect()

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
        .overlay(alignment: .top) {
            if showPalette {
                CommandPalette(isPresented: $showPalette, commands: commands) { run($0) }
                    .padding(.top, 90)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .animation(
            GlassTheme.motion(GlassTheme.quickSpring, reduceMotion: reduceMotion),
            value: showPalette
        )
        .onChange(of: workspace.layout) { _, _ in pruneOrphanedState() }
        .onChange(of: workspace.focusedPane) { _, _ in refreshVault() }
        .onOpenURL(perform: openFile)
        .animation(
            GlassTheme.motion(GlassTheme.spring, reduceMotion: reduceMotion),
            value: showInspector)
        .onDisappear {
            for task in statsTasks.values { task.cancel() }
        }
    }

    // MARK: - Chrome

    /// The floating chrome, split into two clusters that line up with the two
    /// columns beneath it.
    ///
    /// The brand and sidebar toggle belong to the **sidebar column** and are
    /// held to its exact width; search and the mode picker belong to the
    /// **content column**. Laying the toolbar out as one continuous row
    /// instead lets its items drift out of step with the panels below — adding
    /// the brand chip pushed the search capsule across the sidebar's edge, so
    /// the chrome no longer agreed with the layout it sat on.
    private var toolbar: some View {
        GlassEffectContainer(spacing: GlassTheme.Spacing.snug) {
            HStack(spacing: 0) {
                HStack(spacing: GlassTheme.Spacing.snug) {
                    brandChip
                    sidebarToggle
                    Spacer(minLength: 0)
                }
                // Matches the sidebar panel's own inset, so the brand's left
                // edge sits exactly above the panel's.
                .padding(.leading, GlassTheme.Spacing.snug)
                .frame(width: showSidebar ? sidebarWidth : nil, alignment: .leading)

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
        .padding(.horizontal, GlassTheme.Spacing.snug)
        .padding(.vertical, GlassTheme.Spacing.tight)
        .glassEffect(.regular, in: .capsule)
        .glassEffectID("brand", in: glass)
    }

    private var sidebarToggle: some View {
        Button {
            showSidebar.toggle()
        } label: {
            Image(systemName: "sidebar.leading")
        }
        .buttonStyle(.plain)
        .padding(GlassTheme.Spacing.snug)
        .glassEffect(.regular.interactive(), in: .circle)
        .glassEffectID("sidebar", in: glass)
        .help("Toggle sidebar")
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
        }
        .buttonStyle(.plain)
        .padding(.horizontal, GlassTheme.Spacing.regular)
        .padding(.vertical, GlassTheme.Spacing.snug)
        .glassEffect(.regular.interactive(), in: .capsule)
        .glassEffectID("palette", in: glass)
    }

    private var modePicker: some View {
        Picker("Mode", selection: $mode) {
            Text("Live").tag(EditorMode.livePreview)
            Text("Source").tag(EditorMode.source)
            Text("Read").tag(EditorMode.reading)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 190)
        .padding(.horizontal, GlassTheme.Spacing.tight)
        .padding(.vertical, 5)
        .glassEffect(.regular.interactive(), in: .capsule)
        .glassEffectID("mode", in: glass)
    }

    private var saveMenu: some View {
        Menu {
            Button("Save") { _ = saveDocument() }
            Button("Save As…") { _ = saveDocumentAs() }
        } label: {
            Image(systemName: "square.and.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Save")
    }

    private var inspectorToggle: some View {
        Button {
            showInspector.toggle()
        } label: {
            Image(systemName: "sidebar.trailing")
        }
        .buttonStyle(.plain)
        .padding(GlassTheme.Spacing.snug)
        .glassEffect(.regular.interactive(), in: .circle)
        .glassEffectID("inspector", in: glass)
        .help("Toggle inspector")
    }

    private var sidebar: some View {
        NavigatorView(
            root: workspace.vaultRoot,
            onOpen: { openFile($0) },
            onChooseVault: { openVault() }
        )
        .padding(.top, Self.toolbarHeight)
        .glassPanel(radius: GlassTheme.Radius.large, padding: EdgeInsets())
        .padding(GlassTheme.Spacing.snug)
    }

    // MARK: - Panes

    @ViewBuilder
    private func paneView(_ pane: PaneID) -> some View {
        let state = workspace.state(for: pane)
        let document = state.current

        VStack(spacing: 0) {
            PaneTabBar(
                state: state,
                isFocused: workspace.focusedPane == pane,
                canClosePane: workspace.layout.paneCount > 1,
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
    }

    private var inspector: some View {
        InspectorView(
            outline: outline,
            backlinks: backlinks,
            mentions: mentions,
            assistant: writingTools.document,
            tab: $inspectorTab,
            onReveal: { offset in
                reveals[workspace.focusedPane] = RevealRequest(offset: offset)
            },
            onOpenNote: { path, offset in
                guard let url = vault.url(for: path) else { return }
                openFile(url)
                reveals[workspace.focusedPane] = RevealRequest(offset: Int(offset))
            }
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
            return
        }

        // The editor parse owns the outline, so it works for unsaved and
        // standalone files as well as notes inside a vault.
        outline = documentOutlines[document.id] ?? []

        guard let url = document.url, let path = vault.relativePath(for: url) else {
            backlinks = []
            mentions = []
            return
        }

        vault.update(path: path, text: document.text)
        backlinks = vault.backlinks(for: path)
        mentions = vault.unlinkedMentions(for: path)
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
                title: "Split Right", symbol: "rectangle.split.2x1",
                kind: .action(.splitRight)),
            Command(
                title: "Split Down", symbol: "rectangle.split.1x2",
                kind: .action(.splitDown)),
            Command(title: "Live Preview", symbol: "eye", kind: .action(.livePreview)),
            Command(
                title: "Source Mode", symbol: "chevron.left.forwardslash.chevron.right",
                kind: .action(.sourceMode)),
            Command(title: "Reading Mode", symbol: "book", kind: .action(.readingMode)),
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
                title: "Summarize Document", symbol: WritingTask.summarize.symbol,
                kind: .action(.summarizeDocument)),
            Command(
                title: "Suggest a Title", symbol: WritingTask.suggestTitle.symbol,
                kind: .action(.suggestTitle)),
            Command(
                title: "Suggest Tags", symbol: WritingTask.suggestTags.symbol,
                kind: .action(.suggestTags)),
        ]

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
        case .splitRight: workspace.split(workspace.focusedPane, edge: .trailing)
        case .splitDown: workspace.split(workspace.focusedPane, edge: .bottom)
        case .livePreview: mode = .livePreview
        case .sourceMode: mode = .source
        case .readingMode: mode = .reading
        case .writingTools: writingTools.inline.open()
        case .proofreadDocument: runProofreading()
        case .clearProofreading: writingTools.document.clearIssues()
        case .summarizeDocument: runDocumentTask(.summarize)
        case .suggestTitle: runDocumentTask(.suggestTitle)
        case .suggestTags: runDocumentTask(.suggestTags)
        }
    }

    /// Starts a proofreading pass and shows where its results will appear.
    ///
    /// Revealing the panel is part of the action, not a nicety: a pass whose
    /// findings land in a hidden tab reads as a menu item that did nothing
    /// except draw some underlines with no way to act on them.
    private func runProofreading() {
        showInspector = true
        inspectorTab = .assist
        writingTools.document.proofread()
    }

    private func runDocumentTask(_ task: WritingTask) {
        showInspector = true
        inspectorTab = .assist
        writingTools.document.generate(task)
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
