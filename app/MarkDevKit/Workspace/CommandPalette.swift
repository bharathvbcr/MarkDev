//
//  CommandPalette.swift
//  MarkDevKit
//
//  ⌘K: files and actions in one fuzzy-matched list.
//

import SwiftUI

/// Stable command identity, independent of the user-facing title.
public enum CommandAction: Sendable, Equatable {
    case newDocument
    /// A second window. The palette offers it because ⌘K is where a reader
    /// looks for "open something", and the menu's New Window sits one level
    /// deeper than that habit.
    case newWindow
    case toggleCommandPalette
    case openFile
    case openVault
    case saveVault
    case showSavedVaults
    case save
    case saveAs
    case toggleSidebar
    case toggleInspector
    case toggleTerminal
    case toggleGraph
    case splitRight
    case splitDown
    case closePane
    case focusNextPane
    case focusPreviousPane
    /// One case for every writing mode, rather than one case per mode.
    /// ``EditorMode`` already enumerates them, and a fourth mode should not
    /// need a matching action, a matching menu item, and a matching palette
    /// row hand-written beside it.
    case setMode(EditorMode)
    /// Open the inline writing panel on the selection.
    case writingTools
    /// Proofread the whole document and underline what it finds.
    case proofreadDocument
    /// Remove the proofreading underlines.
    case clearProofreading
    /// Read the note and fill in the Assist panel's structured brief.
    case analyzeNote
    /// Open the Assist panel on the local harness.
    case askHarness
    /// Open a terminal already running the harness.
    case openHarnessTerminal
    /// Swap the terminal between the drawer and the inspector.
    case moveTerminal
    /// Zooms text in.
    case zoomIn
    /// Zooms text out.
    case zoomOut
    /// Resets text zoom to 100%.
    case resetZoom
    /// Exports the current document as HTML.
    case exportHTML
    /// Renders the current document as HTML and opens it in the default
    /// browser.
    case previewInBrowser
    /// Prints or exports the current document as PDF.
    case printDocument
}

/// One pure answer to whether workspace commands can act on current state.
///
/// Native menus, the command palette, and pane chrome all consume this value.
/// Keeping the decision out of those renderers prevents an action from being
/// enabled in one surface while another correctly refuses it. The booleans
/// distinguish a document model, a mounted native editor, and the editor that
/// writing tools are actually attached to: those states briefly differ while
/// SwiftUI mounts a restored or newly split pane.
public struct CommandAvailability: Equatable, Sendable {
    public let hasFocusedPane: Bool
    public let paneCount: Int
    public let maximumPaneCount: Int
    public let hasDocument: Bool
    public let hasEditorSurface: Bool
    public let hasAttachedWritingSurface: Bool
    public let hasTextSelection: Bool
    public let hasProofreadingMarks: Bool
    public let canRevealHarnessTerminal: Bool
    public let isPerformingDestructiveOperation: Bool
    public let canSaveVault: Bool

    public init(
        hasFocusedPane: Bool,
        paneCount: Int,
        maximumPaneCount: Int = SplitLayout.maximumPanes,
        hasDocument: Bool,
        hasEditorSurface: Bool,
        hasAttachedWritingSurface: Bool,
        hasTextSelection: Bool,
        hasProofreadingMarks: Bool,
        canRevealHarnessTerminal: Bool,
        isPerformingDestructiveOperation: Bool,
        canSaveVault: Bool = false
    ) {
        self.hasFocusedPane = hasFocusedPane
        self.paneCount = max(0, paneCount)
        self.maximumPaneCount = max(1, maximumPaneCount)
        self.hasDocument = hasDocument
        self.hasEditorSurface = hasEditorSurface
        self.hasAttachedWritingSurface = hasAttachedWritingSurface
        self.hasTextSelection = hasTextSelection
        self.hasProofreadingMarks = hasProofreadingMarks
        self.canRevealHarnessTerminal = canRevealHarnessTerminal
        self.isPerformingDestructiveOperation = isPerformingDestructiveOperation
        self.canSaveVault = canSaveVault
    }

    /// Whether invoking `action` now can reach its canonical handler.
    ///
    /// `writingTools` intentionally remains available at a caret: its panel
    /// explains that a selection is required. This is a real, documented
    /// action rather than a silent no-op, while a missing or stale editor
    /// attachment is not. A new window is process-scoped and remains possible
    /// while another window finishes a destructive operation.
    public func allows(_ action: CommandAction) -> Bool {
        if action == .newWindow { return true }
        guard !isPerformingDestructiveOperation else { return false }

        switch action {
        case .newWindow:
            return true
        case .newDocument:
            return hasFocusedPane
        case .toggleCommandPalette, .openFile, .openVault, .showSavedVaults,
            .toggleSidebar, .toggleInspector, .toggleTerminal, .toggleGraph,
            .setMode, .moveTerminal:
            return true
        case .save, .saveAs, .exportHTML, .previewInBrowser:
            return hasDocument
        case .saveVault:
            return canSaveVault
        case .splitRight, .splitDown:
            return hasFocusedPane && paneCount < maximumPaneCount
        case .closePane, .focusNextPane, .focusPreviousPane:
            return hasFocusedPane && paneCount > 1
        case .writingTools, .proofreadDocument, .analyzeNote, .askHarness:
            return hasDocument && hasAttachedWritingSurface
        case .clearProofreading:
            return hasDocument && hasAttachedWritingSurface && hasProofreadingMarks
        case .openHarnessTerminal:
            return canRevealHarnessTerminal
        case .zoomIn, .zoomOut, .resetZoom:
            return hasEditorSurface
        case .printDocument:
            return hasDocument && hasEditorSurface
        }
    }
}

/// Something the palette can run.
public struct Command: Identifiable, Sendable {
    public enum Kind: Sendable, Equatable {
        case action(CommandAction)
        case file(URL)
        /// A note found because of what is *inside* it. Opens the file and
        /// scrolls to `line`, which the search index reports 1-based.
        case searchResult(URL, line: UInt32)
    }

    public let id: UUID
    public let title: String
    public let subtitle: String?
    public let symbol: String
    public let kind: Kind
    /// Shown right-aligned, e.g. `⌘\`.
    public let shortcut: String?

    /// UTF-16 offset of the start of `line`, 1-based as the vault index
    /// numbers lines.
    ///
    /// Exposed rather than inlined in a handler so the arithmetic can be
    /// asserted against: an off-by-one here scrolls to the wrong paragraph,
    /// which looks exactly like search being broken.
    public static func offset(ofLine line: UInt32, in text: String) -> Int {
        guard line > 1 else { return 0 }
        let target = Int(line) - 1
        var offset = 0
        var newlines = 0
        for scalar in text.utf16 {
            if newlines == target { return offset }
            if scalar == UInt16(UnicodeScalar("\n").value) { newlines += 1 }
            offset += 1
        }
        return offset
    }

    public init(
        id: UUID = UUID(),
        title: String,
        subtitle: String? = nil,
        symbol: String,
        kind: Kind,
        shortcut: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.kind = kind
        self.shortcut = shortcut
    }
}

extension CommandAvailability {
    /// Palette counterpart to ``allows(_:)``. File and content-search rows
    /// remain available unless the workspace is inside the one state that
    /// rejects all filesystem/UI interaction.
    public func allows(_ kind: Command.Kind) -> Bool {
        switch kind {
        case .action(let action):
            allows(action)
        case .file, .searchResult:
            !isPerformingDestructiveOperation
        }
    }
}

/// Identity of one content-search request.
///
/// The index revision is part of the identity even when the visible query is
/// unchanged. Without it, an edit that adds or removes a match leaves the
/// palette showing the previous index snapshot until the reader types again.
struct CommandPaletteSearchRequest: Hashable, Sendable {
    let query: String
    let contentRevision: UInt64
    let shouldSearch: Bool
}

/// Bounded content-search state whose reads are side-effect free.
///
/// SwiftUI may evaluate a view's computed properties repeatedly and in no
/// promised order. Keeping mutations in the request task, rather than in
/// `results`, makes rendering idempotent. The generation rejects an old task
/// even if requests cycle from A to B and back to A before A finishes.
struct CommandPaletteSearchState {
    private(set) var generation = UUID()
    private(set) var request: CommandPaletteSearchRequest?
    private var storedHits: [Command] = []
    private var loading = false

    @discardableResult
    mutating func begin(_ request: CommandPaletteSearchRequest) -> UUID {
        generation = UUID()
        self.request = request
        storedHits = []
        loading = true
        return generation
    }

    @discardableResult
    mutating func complete(
        _ hits: [Command],
        for request: CommandPaletteSearchRequest,
        generation: UUID,
        limit: Int
    ) -> Bool {
        guard self.request == request, self.generation == generation else { return false }
        storedHits = Array(hits.prefix(max(0, limit)))
        loading = false
        return true
    }

    mutating func reset() {
        generation = UUID()
        request = nil
        storedHits = []
        loading = false
    }

    func hits(for request: CommandPaletteSearchRequest) -> [Command] {
        guard self.request == request, !loading else { return [] }
        return storedHits
    }

    func isLoading(_ request: CommandPaletteSearchRequest) -> Bool {
        self.request == request && loading
    }

    /// Includes the first render before `.task(id:)` has begun the request.
    func isPending(_ request: CommandPaletteSearchRequest) -> Bool {
        request.shouldSearch && (self.request != request || loading)
    }
}

/// Fuzzy-matched launcher for files and actions.
///
/// Files and actions share one list on purpose. Splitting them makes the user
/// decide *which* palette to open before they can type, which is the decision
/// the palette exists to avoid.
public struct CommandPalette: View {
    @Binding public var isPresented: Bool
    public let commands: [Command]
    public let availability: CommandAvailability
    /// Full-text search over note contents, asked once per eligible
    /// query/index-revision pair after a short typing debounce.
    ///
    /// Filenames answer "which note was that"; this answers "where did I
    /// write that", which is the other half of why a palette exists. `nil` in
    /// a context with no vault — the palette still lists actions and open
    /// tabs there.
    public let contentSearch: ((String) async -> [Command])?
    /// Revision of the content index searched by ``contentSearch``.
    public let contentRevision: UInt64
    public let onRun: (Command) -> Void

    /// What last moved the highlight.
    ///
    /// Only the keyboard scrolls the list to follow it. Centring a row the
    /// pointer merely passed over slides the *next* row under a stationary
    /// cursor, which hovers, which scrolls again — the list walks itself
    /// while the mouse is only crossing it. The reader scrolls the results;
    /// the results never scroll themselves under the reader.
    private enum HighlightSource { case keyboard, pointer }

    @State private var query = ""
    @State private var highlighted = 0
    @State private var highlightSource: HighlightSource = .keyboard
    /// Where the pointer was when it last took the highlight, in the list's
    /// own coordinate space — which does not move when the content scrolls.
    /// A hover arriving at an unchanged point is the list having moved, not
    /// the pointer, and must not steal the highlight from the keyboard.
    @State private var pointerLocation: CGPoint?
    @State private var contentState = CommandPaletteSearchState()
    @FocusState private var isFieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let listSpace = "CommandPalette.results"

    public init(
        isPresented: Binding<Bool>,
        commands: [Command],
        availability: CommandAvailability,
        contentSearch: ((String) async -> [Command])? = nil,
        contentRevision: UInt64 = 0,
        onRun: @escaping (Command) -> Void
    ) {
        self._isPresented = isPresented
        self.commands = commands
        self.availability = availability
        self.contentSearch = contentSearch
        self.contentRevision = contentRevision
        self.onRun = onRun
    }

    private var titleResults: [Command] {
        let availableCommands = commands.filter { availability.allows($0.kind) }
        return Array(FuzzyMatch.rank(availableCommands, query: query) { command in
            // Match on the subtitle too, so a file can be found by its folder.
            [command.title, command.subtitle ?? ""].joined(separator: " ")
        }.prefix(40))
    }

    private var searchRequest: CommandPaletteSearchRequest {
        let matched = titleResults
        return CommandPaletteSearchRequest(
            query: query,
            contentRevision: contentRevision,
            shouldSearch: contentSearch != nil
                && query.count >= 2
                && matched.count < Self.contentThreshold)
    }

    private var results: [Command] {
        let matched = titleResults
        let request = searchRequest

        // Content hits join only once the query could plausibly be a word,
        // and never crowd out what a filename match already answers. A note
        // already surfaced by its title is not offered twice below by its
        // contents — the same file appearing in two shapes reads as a glitch.
        guard request.shouldSearch else { return matched }

        var seenURLs = Set(matched.compactMap { command -> URL? in
            switch command.kind {
            case .file(let url): url
            case .searchResult(let url, _): url
            case .action: nil
            }
        })
        return matched + contentState.hits(for: request).filter { command in
            guard availability.allows(command.kind) else { return false }
            switch command.kind {
            case .file(let url), .searchResult(let url, _):
                return seenURLs.insert(url).inserted
            case .action:
                return true
            }
        }
    }

    /// Below this many title matches, contents get a say; above it, the
    /// reader is clearly narrowing a filename and hits would be noise.
    private static let contentThreshold = 5
    private static let maximumContentHits = 8

    public var body: some View {
        let visibleResults = results
        let request = searchRequest
        VStack(spacing: 0) {
            field
            if !visibleResults.isEmpty {
                Divider().opacity(0.4)
                resultList(visibleResults)
                if contentState.isPending(request) {
                    Divider().opacity(0.4)
                    searchProgress
                }
            } else if contentState.isPending(request) {
                Divider().opacity(0.4)
                searchProgress
            } else if !query.isEmpty {
                Text("No matches")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(GlassTheme.Spacing.loose)
            }
        }
        .containerRelativeFrame(.horizontal) { availableWidth, _ in
            CommandPaletteLayout.width(availableWidth: availableWidth)
        }
        .glassPanel(radius: GlassTheme.Radius.large, padding: EdgeInsets())
        .shadow(color: .black.opacity(0.28), radius: 30, y: 12)
        .onAppear { resetHighlight() }
        .onChange(of: availability) { _, _ in resetHighlight() }
        .task {
            // Focus has to be claimed *after* the field is in the window.
            // Setting it in `onAppear` runs too early: the assignment is
            // dropped and keystrokes keep going to whatever was focused
            // before — for MarkDev, the sidebar filter — so the palette
            // looks broken the moment it opens.
            await Task.yield()
            isFieldFocused = true
        }
        .onChange(of: query) { _, _ in resetHighlight() }
        .task(id: request) {
            await refreshContent(for: request)
        }
        .onKeyPress(.upArrow) {
            moveHighlight(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveHighlight(by: 1)
            return .handled
        }
        .onKeyPress(.escape) {
            isPresented = false
            query = ""
            return .handled
        }
    }

    private var field: some View {
        HStack(spacing: GlassTheme.Spacing.snug) {
            Image(systemName: "command")
                .foregroundStyle(.secondary)
            TextField("Search files and commands", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($isFieldFocused)
                .onSubmit(runHighlighted)
            Button {
                isPresented = false
            } label: {
                Text("esc")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .controlTarget(Capsule(), padding: GlassTheme.Spacing.tight)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close palette")
        }
        .padding(.horizontal, GlassTheme.Spacing.loose)
        .padding(.vertical, GlassTheme.Spacing.regular)
    }

    private func resultList(_ results: [Command]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, command in
                        CommandRow(command: command, isHighlighted: index == highlighted) {
                            run(command)
                        }
                        .id(index)
                        .onTapGesture { run(command) }
                        .onContinuousHover(coordinateSpace: .named(Self.listSpace)) { phase in
                            guard case .active(let location) = phase else { return }
                            pointerMoved(to: location, highlighting: index)
                        }
                    }
                }
                .padding(GlassTheme.Spacing.tight)
            }
            .frame(maxHeight: 380)
            .coordinateSpace(.named(Self.listSpace))
            .onChange(of: highlighted) { _, new in
                guard highlightSource == .keyboard else { return }
                withAnimation(GlassTheme.motion(GlassTheme.quickSpring, reduceMotion: reduceMotion)) {
                    proxy.scrollTo(new, anchor: .center)
                }
            }
        }
    }

    private var searchProgress: some View {
        HStack(spacing: GlassTheme.Spacing.tight) {
            ProgressView()
                .controlSize(.small)
            Text("Searching note contents…")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, GlassTheme.Spacing.loose)
        .padding(.vertical, GlassTheme.Spacing.snug)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Searching note contents")
    }

    /// Executes outside body evaluation and publishes only the latest result.
    /// A short debounce gives rapid typing a real cancellation window before
    /// entering the bounded index query.
    @MainActor
    private func refreshContent(for request: CommandPaletteSearchRequest) async {
        guard request.shouldSearch, let contentSearch else {
            contentState.reset()
            return
        }
        let generation = contentState.begin(request)
        do {
            try await Task.sleep(for: .milliseconds(80))
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        let hits = await contentSearch(request.query)
        guard !Task.isCancelled,
            contentState.complete(
                hits,
                for: request,
                generation: generation,
                limit: Self.maximumContentHits)
        else { return }

        let count = results.count
        if count == 0 {
            highlighted = 0
        } else if highlighted >= count {
            highlighted = count - 1
        }
    }

    /// A new result set is a keyboard-driven jump back to the top: the list
    /// scrolls there even if the pointer happens to be resting on a row.
    private func resetHighlight() {
        highlightSource = .keyboard
        pointerLocation = nil
        highlighted = 0
    }

    // MARK: - Pointer

    /// Take the highlight for a row the pointer is over — but only if the
    /// pointer is what moved.
    private func pointerMoved(to location: CGPoint, highlighting index: Int) {
        guard Self.pointerMoved(from: pointerLocation, to: location) else { return }
        pointerLocation = location
        highlightSource = .pointer
        highlighted = index
    }

    /// Whether a hover at `location` came from the pointer moving rather than
    /// from the list scrolling beneath a pointer that did not.
    ///
    /// The tolerance absorbs float noise only; a mouse moves in whole points.
    nonisolated static func pointerMoved(from previous: CGPoint?, to location: CGPoint) -> Bool {
        guard let previous else { return true }
        return abs(location.x - previous.x) > 0.5 || abs(location.y - previous.y) > 0.5
    }

    // MARK: - Keyboard

    /// Arrow keys move the highlight; Return runs it.
    ///
    /// Wrapping at both ends means holding a key never dead-ends, which is
    /// how every other launcher behaves.
    public func moveHighlight(by offset: Int) {
        guard let next = Self.movedHighlight(
            highlighted, by: offset, resultCount: results.count)
        else { return }
        highlightSource = .keyboard
        highlighted = next
    }

    /// Pure selection arithmetic shared by keyboard handling and tests.
    nonisolated static func movedHighlight(
        _ current: Int, by offset: Int, resultCount: Int
    ) -> Int? {
        guard resultCount > 0 else { return nil }
        let normalized = current % resultCount
        return (normalized + (offset % resultCount) + resultCount) % resultCount
    }

    private func runHighlighted() {
        guard results.indices.contains(highlighted) else { return }
        run(results[highlighted])
    }

    private func run(_ command: Command) {
        isPresented = false
        query = ""
        onRun(command)
    }
}

/// Keeps the palette at its comfortable desktop width without exceeding the
/// window that owns it. Non-finite proposals fail back to the bounded ideal;
/// SwiftUI can transiently produce one during detached layout measurement.
enum CommandPaletteLayout {
    static let preferredWidth: CGFloat = 560

    static func width(availableWidth: CGFloat) -> CGFloat {
        guard availableWidth.isFinite, availableWidth > 0 else { return preferredWidth }
        return min(availableWidth, preferredWidth)
    }
}

private struct CommandRow: View {
    let command: Command
    let isHighlighted: Bool
    let onActivate: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: GlassTheme.Spacing.snug) {
            Image(systemName: command.symbol)
                .frame(width: 18)
                .foregroundStyle(isHighlighted ? Color.accentColor : .secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(command.title)
                    .font(.callout)
                    .lineLimit(1)
                if let subtitle = command.subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            Spacer(minLength: GlassTheme.Spacing.snug)

            if let shortcut = command.shortcut {
                Text(shortcut)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, GlassTheme.Spacing.regular)
        .padding(.vertical, GlassTheme.Spacing.snug)
        .background(
            RoundedRectangle(cornerRadius: GlassTheme.Radius.small)
                .fill(isHighlighted ? Color.accentColor.opacity(0.20) : .clear)
        )
        .contentShape(Rectangle())
        // Held keys walk the list faster than a spring settles, so the
        // highlight cross-fades rather than following a curve it would never
        // finish.
        .animation(
            GlassTheme.motion(.easeOut(duration: 0.12), reduceMotion: reduceMotion),
            value: isHighlighted)
        // One element, one button: without the trait the rows are plain text
        // VoiceOver cannot activate, and the palette becomes keyboard-only.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isHighlighted ? [.isButton, .isSelected] : [.isButton])
        .accessibilityAction { onActivate() }
    }
}
