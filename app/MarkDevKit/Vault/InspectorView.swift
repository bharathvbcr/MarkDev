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

    var symbol: String {
        switch self {
        case .outline: "list.bullet.indent"
        case .links: "link"
        case .assist: "apple.intelligence"
        }
    }
}

/// The right-hand panel: where this note goes, and what points back at it.
public struct InspectorView: View {
    public let outline: [VaultHeading]
    public let backlinks: [Backlink]
    public let mentions: [UnlinkedMention]
    /// The window's writing-tools state, for the Assist tab.
    public let assistant: DocumentAssistant
    /// Called with a UTF-16 offset in the current document to scroll to.
    ///
    /// Shared by the outline and the proofreading list: "take me to this
    /// offset" is one behaviour, and giving each panel its own callback for it
    /// would be two names for the same seam.
    public let onReveal: (Int) -> Void
    /// Called with a vault-relative path and an offset to reveal.
    public let onOpenNote: (String, UInt32) -> Void

    @Binding private var tab: InspectorTab
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        outline: [VaultHeading],
        backlinks: [Backlink],
        mentions: [UnlinkedMention],
        assistant: DocumentAssistant,
        tab: Binding<InspectorTab>,
        onReveal: @escaping (Int) -> Void,
        onOpenNote: @escaping (String, UInt32) -> Void
    ) {
        self.outline = outline
        self.backlinks = backlinks
        self.mentions = mentions
        self.assistant = assistant
        self._tab = tab
        self.onReveal = onReveal
        self.onOpenNote = onOpenNote
    }

    public var body: some View {
        VStack(spacing: GlassTheme.Spacing.snug) {
            picker
            ScrollView {
                LazyVStack(alignment: .leading, spacing: GlassTheme.Spacing.tight) {
                    switch tab {
                    case .outline: outlineSection
                    case .links: linksSection
                    case .assist:
                        AssistInspectorView(assistant: assistant, onReveal: onReveal)
                    }
                }
                .padding(.horizontal, GlassTheme.Spacing.tight)
                .padding(.bottom, GlassTheme.Spacing.snug)
            }
            .scrollContentBackground(.hidden)
        }
        .padding(GlassTheme.Spacing.snug)
        .animation(
            GlassTheme.motion(GlassTheme.quickSpring, reduceMotion: reduceMotion), value: tab)
    }

    private var picker: some View {
        Picker("", selection: $tab) {
            ForEach(InspectorTab.allCases, id: \.self) { tab in
                Label(tab.rawValue, systemImage: tab.symbol).tag(tab)
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
        if backlinks.isEmpty && mentions.isEmpty {
            empty(
                "No connections", symbol: "link",
                hint: "Link to this note with [[its name]] from anywhere in the vault.")
        } else {
            if !backlinks.isEmpty {
                sectionHeader("Linked mentions", count: backlinks.count)
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
                    .padding(.top, backlinks.isEmpty ? 0 : GlassTheme.Spacing.snug)
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
