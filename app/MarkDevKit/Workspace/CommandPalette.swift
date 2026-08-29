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
    /// Prints or exports the current document as PDF.
    case printDocument
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

/// Fuzzy-matched launcher for files and actions.
///
/// Files and actions share one list on purpose. Splitting them makes the user
/// decide *which* palette to open before they can type, which is the decision
/// the palette exists to avoid.
public struct CommandPalette: View {
    @Binding public var isPresented: Bool
    public let commands: [Command]
    /// Full-text search over note contents, asked once per query change.
    ///
    /// Filenames answer "which note was that"; this answers "where did I
    /// write that", which is the other half of why a palette exists. `nil` in
    /// a context with no vault — the palette still lists actions and open
    /// tabs there.
    public let contentSearch: ((String) -> [Command])?
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
    @FocusState private var isFieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let listSpace = "CommandPalette.results"

    public init(
        isPresented: Binding<Bool>,
        commands: [Command],
        contentSearch: ((String) -> [Command])? = nil,
        onRun: @escaping (Command) -> Void
    ) {
        self._isPresented = isPresented
        self.commands = commands
        self.contentSearch = contentSearch
        self.onRun = onRun
    }

    /// The expensive half of ``results``, asked at most once per query.
    ///
    /// `results` is computed several times per body evaluation, and every
    /// call used to re-run the vault's full-text search — an FFI round trip
    /// under the index lock — for the same query. One memo keyed on the
    /// query turns the repeats into dictionary hits; a new query replaces
    /// it. Bounded to one entry by construction.
    @State private var contentMemo: (query: String, hits: [Command])?

    private func contentHits(for query: String) -> [Command] {
        if let contentMemo, contentMemo.query == query { return contentMemo.hits }
        let hits = Array(contentSearch?(query).prefix(Self.maximumContentHits) ?? [])
        contentMemo = (query, hits)
        return hits
    }

    private var results: [Command] {
        let matched = Array(FuzzyMatch.rank(commands, query: query) { command in
            // Match on the subtitle too, so a file can be found by its folder.
            [command.title, command.subtitle ?? ""].joined(separator: " ")
        }.prefix(40))

        // Content hits join only once the query could plausibly be a word,
        // and never crowd out what a filename match already answers. A note
        // already surfaced by its title is not offered twice below by its
        // contents — the same file appearing in two shapes reads as a glitch.
        guard let contentSearch, query.count >= 2, matched.count < Self.contentThreshold
        else { return matched }

        var seenURLs = Set(matched.compactMap { command -> URL? in
            switch command.kind {
            case .file(let url): url
            case .searchResult(let url, _): url
            case .action: nil
            }
        })
        return matched + contentHits(for: query).filter { command in
            switch command.kind {
            case .file(let url), .searchResult(let url, _):
                seenURLs.insert(url).inserted
            case .action:
                true
            }
        }
    }

    /// Below this many title matches, contents get a say; above it, the
    /// reader is clearly narrowing a filename and hits would be noise.
    private static let contentThreshold = 5
    private static let maximumContentHits = 8

    public var body: some View {
        VStack(spacing: 0) {
            field
            if !results.isEmpty {
                Divider().opacity(0.4)
                resultList
            } else if !query.isEmpty {
                Text("No matches")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(GlassTheme.Spacing.loose)
            }
        }
        .frame(width: 560)
        .glassPanel(radius: GlassTheme.Radius.large, padding: EdgeInsets())
        .shadow(color: .black.opacity(0.28), radius: 30, y: 12)
        .onAppear { resetHighlight() }
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

    private var resultList: some View {
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
