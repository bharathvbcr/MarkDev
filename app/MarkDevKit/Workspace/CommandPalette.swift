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
    case toggleCommandPalette
    case openFile
    case openVault
    case save
    case saveAs
    case toggleSidebar
    case toggleInspector
    case splitRight
    case splitDown
    case livePreview
    case sourceMode
    case readingMode
    /// Open the inline writing panel on the selection.
    case writingTools
    /// Proofread the whole document and underline what it finds.
    case proofreadDocument
    /// Remove the proofreading underlines.
    case clearProofreading
    case summarizeDocument
    case suggestTitle
    case suggestTags
}

/// Something the palette can run.
public struct Command: Identifiable, Sendable {
    public enum Kind: Sendable, Equatable {
        case action(CommandAction)
        case file(URL)
    }

    public let id: UUID
    public let title: String
    public let subtitle: String?
    public let symbol: String
    public let kind: Kind
    /// Shown right-aligned, e.g. `⌘\`.
    public let shortcut: String?

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
    public let onRun: (Command) -> Void

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var isFieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(isPresented: Binding<Bool>, commands: [Command], onRun: @escaping (Command) -> Void) {
        self._isPresented = isPresented
        self.commands = commands
        self.onRun = onRun
    }

    private var results: [Command] {
        Array(FuzzyMatch.rank(commands, query: query) { command in
            // Match on the subtitle too, so a file can be found by its folder.
            [command.title, command.subtitle ?? ""].joined(separator: " ")
        }.prefix(40))
    }

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
        .onAppear { highlighted = 0 }
        .task {
            // Focus has to be claimed *after* the field is in the window.
            // Setting it in `onAppear` runs too early: the assignment is
            // dropped and keystrokes keep going to whatever was focused
            // before — for MarkDev, the sidebar filter — so the palette
            // looks broken the moment it opens.
            await Task.yield()
            isFieldFocused = true
        }
        .onChange(of: query) { _, _ in highlighted = 0 }
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
                Text("esc").font(.caption2).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, GlassTheme.Spacing.loose)
        .padding(.vertical, GlassTheme.Spacing.regular)
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, command in
                        CommandRow(command: command, isHighlighted: index == highlighted)
                            .id(index)
                            .onTapGesture { run(command) }
                            .onHover { if $0 { highlighted = index } }
                    }
                }
                .padding(GlassTheme.Spacing.tight)
            }
            .frame(maxHeight: 380)
            .onChange(of: highlighted) { _, new in
                withAnimation(GlassTheme.motion(GlassTheme.quickSpring, reduceMotion: reduceMotion)) {
                    proxy.scrollTo(new, anchor: .center)
                }
            }
        }
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
        .accessibilityAddTraits(isHighlighted ? [.isSelected] : [])
    }
}
