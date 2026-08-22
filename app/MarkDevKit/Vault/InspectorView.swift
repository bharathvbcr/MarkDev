//
//  InspectorView.swift
//  MarkDevKit
//
//  Outline, backlinks, and unlinked mentions for the current note.
//

import SwiftUI

/// What the inspector is showing.
public enum InspectorTab: String, CaseIterable, Sendable {
    case outline = "Outline"
    case links = "Links"
    case assist = "Assist"
    case terminal = "Terminal"

    var symbol: String {
        switch self {
        case .outline: "list.bullet.indent"
        case .links: "link"
        case .assist: "apple.intelligence"
        case .terminal: "apple.terminal"
        }
    }
}

/// The right-hand panel: where this note goes, and what points back at it.
public struct InspectorView: View {
    public let outline: [VaultHeading]
    public let backlinks: [Backlink]
    public let mentions: [UnlinkedMention]
    /// Where this note points *out*, each carrying its resolution — including
    /// the broken ones, which are shown rather than dropped: a note linking at
    /// something that does not exist yet is ordinary in a vault, and invisible
    /// breakage is how a link graph quietly rots.
    public let outgoing: [OutgoingLink]
    /// The window's writing-tools state, for the Assist tab.
    public let assistant: DocumentAssistant
    /// The local harness, shown beside it under the same tab.
    public let harness: HarnessAssistant
    /// The terminal, when the reader has parked it here rather than in the
    /// drawer. `nil` means it lives along the bottom, and the Terminal tab
    /// says so and offers to move it.
    public let terminal: AnyView?
    /// Moves the terminal into this panel.
    public let onMoveTerminalHere: () -> Void
    /// Called with a UTF-16 offset in the current document to scroll to.
    ///
    /// Shared by the outline and the proofreading list: "take me to this
    /// offset" is one behaviour, and giving each panel its own callback for it
    /// would be two names for the same seam.
    public let onReveal: (Int) -> Void
    /// Called with a vault-relative path and an offset to reveal.
    public let onOpenNote: (String, UInt32) -> Void

    @Binding private var tab: InspectorTab
    @Binding private var engine: AssistEngine
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        outline: [VaultHeading],
        backlinks: [Backlink],
        mentions: [UnlinkedMention],
        outgoing: [OutgoingLink] = [],
        assistant: DocumentAssistant,
        harness: HarnessAssistant,
        terminal: AnyView?,
        tab: Binding<InspectorTab>,
        engine: Binding<AssistEngine>,
        onReveal: @escaping (Int) -> Void,
        onOpenNote: @escaping (String, UInt32) -> Void,
        onMoveTerminalHere: @escaping () -> Void
    ) {
        self.outline = outline
        self.backlinks = backlinks
        self.mentions = mentions
        self.outgoing = outgoing
        self.assistant = assistant
        self.harness = harness
        self.terminal = terminal
        self._tab = tab
        self._engine = engine
        self.onReveal = onReveal
        self.onOpenNote = onOpenNote
        self.onMoveTerminalHere = onMoveTerminalHere
    }

    public var body: some View {
        VStack(spacing: GlassTheme.Spacing.snug) {
            picker
            // The terminal is not scrolled. It does its own scrolling, it
            // wants every point of height it can get, and a pty inside a
            // `ScrollView` fights the scroll wheel with the shell for it.
            if tab == .terminal {
                terminalSection
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: GlassTheme.Spacing.tight) {
                        switch tab {
                        case .outline: outlineSection
                        case .links: linksSection
                        case .assist:
                            AssistInspectorView(
                                assistant: assistant,
                                harness: harness,
                                engine: $engine,
                                onReveal: onReveal)
                        case .terminal: EmptyView()
                        }
                    }
                    .padding(.horizontal, GlassTheme.Spacing.tight)
                    .padding(.bottom, GlassTheme.Spacing.snug)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .padding(GlassTheme.Spacing.snug)
        .animation(
            GlassTheme.motion(GlassTheme.quickSpring, reduceMotion: reduceMotion), value: tab)
    }

    // MARK: - Terminal

    /// The shell, when this panel is where it lives.
    ///
    /// The terminal is one thing that can be drawn in one of two places, never
    /// two terminals — moving it re-parents the same `NSView`, so a running
    /// build survives the move. See ``TerminalProcessHost``. This tab therefore
    /// either holds it or offers to fetch it; it never forks a second one.
    @ViewBuilder
    private var terminalSection: some View {
        if let terminal {
            terminal
                .clipShape(RoundedRectangle(cornerRadius: GlassTheme.Radius.small))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: GlassTheme.Spacing.tight) {
                Image(systemName: "apple.terminal")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
                Text("The terminal is in the drawer")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("Move it here to keep a shell beside the note. Whatever is running keeps running.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                Button("Move It Here", action: onMoveTerminalHere)
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, GlassTheme.Spacing.loose)
            .padding(.horizontal, GlassTheme.Spacing.tight)
        }
    }

    private var picker: some View {
        // Icons alone. With four tabs there is no width for four words in a
        // panel that starts at 300 points and can be dragged to 220 — the
        // labels truncate to two characters each, which is less legible than
        // the symbol they sit beside. The name survives as the tooltip and as
        // the accessibility label, which is where a reader who needs it looks.
        Picker("", selection: $tab) {
            ForEach(InspectorTab.allCases, id: \.self) { tab in
                Image(systemName: tab.symbol)
                    .accessibilityLabel(tab.rawValue)
                    .help(tab.rawValue)
                    .tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    // MARK: - Outline

    @ViewBuilder
    private var outlineSection: some View {
        if outline.isEmpty {
            empty("No headings", symbol: "number", hint: "Add a heading to build an outline.")
        } else {
            ForEach(outline) { heading in
                Button {
                    onReveal(Int(heading.offset))
                } label: {
                    HStack(spacing: GlassTheme.Spacing.tight) {
                        // Indentation carries the level; a bare list of
                        // headings loses the document's shape.
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.35))
                            .frame(width: 2)
                            .opacity(heading.level > 1 ? 1 : 0)
                        Text(heading.text)
                            .font(heading.level == 1 ? .callout.weight(.semibold) : .callout)
                            .foregroundStyle(heading.level <= 2 ? Color.primary : Color.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, CGFloat(max(0, Int(heading.level) - 1)) * 10)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Links

    @ViewBuilder
    private var linksSection: some View {
        if backlinks.isEmpty && mentions.isEmpty && outgoing.isEmpty {
            empty(
                "No connections", symbol: "link",
                hint: "Link to this note with [[its name]] from anywhere in the vault.")
        } else {
            if !outgoing.isEmpty {
                sectionHeader("Outgoing links", count: outgoing.count)
                ForEach(outgoing) { link in
                    outgoingLink(link)
                }
            }

            if !backlinks.isEmpty {
                sectionHeader("Linked mentions", count: backlinks.count)
                    .padding(.top, GlassTheme.Spacing.snug)
                ForEach(backlinks) { backlink in
                    reference(
                        title: backlink.title,
                        context: backlink.context,
                        path: backlink.path,
                        emphasised: true
                    ) {
                        onOpenNote(backlink.path, backlink.offset)
                    }
                }
            }

            if !mentions.isEmpty {
                sectionHeader("Unlinked mentions", count: mentions.count)
                    .padding(.top, GlassTheme.Spacing.snug)
                ForEach(mentions) { mention in
                    reference(
                        title: mention.title,
                        context: mention.context,
                        path: mention.path,
                        emphasised: false
                    ) {
                        onOpenNote(mention.path, mention.offset)
                    }
                }
            }
        }
    }

    /// One outbound link. A resolved one opens its target; a broken one says
    /// so and offers nothing, because the only place to go is the text itself.
    @ViewBuilder
    private func outgoingLink(_ link: OutgoingLink) -> some View {
        if let path = link.path {
            Button {
                onOpenNote(path, link.offset)
            } label: {
                HStack(spacing: GlassTheme.Spacing.tight) {
                    Image(systemName: "arrow.turn.up.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(link.display)
                            .font(.callout)
                            .lineLimit(1)
                        Text(path)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: GlassTheme.Spacing.tight) {
                Image(systemName: "link.badge.plus")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(link.display)
                        .font(.callout)
                        .lineLimit(1)
                    Text("Broken — no note named \(link.target)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
        }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Text("\(count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    private func reference(
        title: String,
        context: String,
        path: String,
        emphasised: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: GlassTheme.Spacing.tight) {
                    Image(systemName: emphasised ? "arrow.turn.up.left" : "text.magnifyingglass")
                        .font(.caption2)
                        .foregroundStyle(emphasised ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    Text(title)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                if !context.isEmpty {
                    Text(context)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(GlassTheme.Spacing.tight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: GlassTheme.Radius.small)
                    .fill(Color.primary.opacity(0.05))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(path)
    }

    private func empty(_ title: String, symbol: String, hint: String) -> some View {
        VStack(spacing: GlassTheme.Spacing.tight) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(hint)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, GlassTheme.Spacing.loose)
    }
}
