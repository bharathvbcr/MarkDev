//
//  NavigatorView.swift
//  MarkDevKit
//
//  The vault sidebar.
//

import AppKit
import SwiftUI

/// Browsable file tree for the vault, with a fuzzy filter.
public struct NavigatorView: View {
    public let root: URL?
    /// Called when a file is chosen.
    public let onOpen: (URL) -> Void
    /// Called when the reader asks for a vault. The navigator raises the
    /// request rather than running the open panel itself: choosing a vault is
    /// a workspace-level decision, and the sidebar is only one of the places
    /// it can be made.
    public var onChooseVault: (() -> Void)?

    @State private var nodes: [FileNode] = []
    @State private var expanded: Set<URL> = []
    @State private var filter = ""
    @State private var selection: URL?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        root: URL?,
        onOpen: @escaping (URL) -> Void,
        onChooseVault: (() -> Void)? = nil
    ) {
        self.root = root
        self.onOpen = onOpen
        self.onChooseVault = onChooseVault
    }

    public var body: some View {
        VStack(spacing: GlassTheme.Spacing.snug) {
            if let root {
                vaultHeader(root)
                filterField
                list
            } else {
                emptyState
            }
        }
        .padding(GlassTheme.Spacing.snug)
        .task(id: root) { reload() }
    }

    /// Which vault is open, and a way out of it.
    ///
    /// Without this the sidebar shows a list of file names with no indication
    /// of where they came from — indistinguishable from the same folder names
    /// in a different vault.
    private func vaultHeader(_ root: URL) -> some View {
        HStack(spacing: GlassTheme.Spacing.tight) {
            Image(systemName: "shippingbox")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(root.lastPathComponent)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Menu {
                Button("Change Vault…") { onChooseVault?() }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([root])
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .controlTarget(Circle(), padding: GlassTheme.Spacing.tight)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Vault options")
        }
        .padding(.horizontal, 4)
        .help(root.path)
    }

    private var filterField: some View {
        HStack(spacing: GlassTheme.Spacing.tight) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("Filter", text: $filter)
                .textFieldStyle(.plain)
                .font(.callout)
            if !filter.isEmpty {
                Button {
                    filter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .controlTarget(Circle(), padding: GlassTheme.Spacing.tight)
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel("Clear filter")
            }
        }
        .animation(
            GlassTheme.motion(GlassTheme.quickSpring, reduceMotion: reduceMotion),
            value: filter.isEmpty)
        .glassPanel(
            radius: GlassTheme.Radius.small,
            padding: EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
    }

    /// Shown when there is no vault — with the action that resolves it.
    ///
    /// The empty state used to describe what to do and offer no way to do it,
    /// which left the command palette as the only route to a vault. An empty
    /// state that names a next step has to *be* the next step.
    private var emptyState: some View {
        VStack(spacing: GlassTheme.Spacing.snug) {
            Spacer()
            Image(systemName: "folder.badge.questionmark")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("No vault open")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Open a folder to browse and link notes.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            if let onChooseVault {
                Button("Open Vault…", action: onChooseVault)
                    .controlSize(.small)
                    .padding(.top, GlassTheme.Spacing.tight)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, GlassTheme.Spacing.snug)
    }

    @ViewBuilder
    private var list: some View {
        let rows = visibleRows
        if rows.isEmpty {
            VStack(spacing: GlassTheme.Spacing.tight) {
                Spacer()
                Text(filter.isEmpty ? "This vault has no notes yet" : "No matches")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !filter.isEmpty {
                    Text("for “\(filter)”")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(rows, id: \.node.id) { row in
                        NavigatorRow(
                            node: row.node,
                            depth: row.depth,
                            subtitle: row.subtitle,
                            isExpanded: expanded.contains(row.node.url),
                            isSelected: selection == row.node.url,
                            reduceMotion: reduceMotion
                        ) {
                            activate(row.node)
                        }
                        .contextMenu {
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([row.node.url])
                            }
                            Button("Copy Path") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(
                                    row.node.url.path, forType: .string)
                            }
                        }
                        // Children slide out from under their folder rather
                        // than appearing already in place, which is what
                        // shows they belong to the row that was clicked.
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(.vertical, GlassTheme.Spacing.tight)
            }
            .scrollContentBackground(.hidden)
            .animation(
                GlassTheme.motion(GlassTheme.quickSpring, reduceMotion: reduceMotion),
                value: expanded)
        }
    }

    // MARK: - Rows

    private struct Row {
        let node: FileNode
        let depth: Int
        /// Where the file lives. Carried only while filtering, where the row
        /// has no indentation left to say it.
        var subtitle: String?
    }

    /// Flattens the expanded tree into rows.
    ///
    /// While filtering, the hierarchy is dropped and matches are ranked flat.
    /// A filtered tree that still shows folder nesting hides the very results
    /// the filter was meant to surface — but a flat list of bare names cannot
    /// tell two `Index` notes apart, so each match carries its folder instead.
    private var visibleRows: [Row] {
        guard filter.isEmpty else {
            let matches = FuzzyMatch.rank(flattenAll(nodes), query: filter) { $0.displayName }
            return matches.map { Row(node: $0, depth: 0, subtitle: folder(of: $0)) }
        }
        return flattenExpanded(nodes, depth: 0)
    }

    /// The match's folder, relative to the vault root.
    private func folder(of node: FileNode) -> String? {
        guard let root else { return nil }
        let parent = node.url.deletingLastPathComponent().standardizedFileURL
        let base = root.standardizedFileURL
        guard parent != base else { return nil }

        let components = parent.pathComponents
        let baseComponents = base.pathComponents
        guard components.count > baseComponents.count,
            Array(components.prefix(baseComponents.count)) == baseComponents
        else {
            return parent.lastPathComponent
        }
        return components.dropFirst(baseComponents.count).joined(separator: "/")
    }

    private func flattenExpanded(_ nodes: [FileNode], depth: Int) -> [Row] {
        nodes.flatMap { node -> [Row] in
            var rows = [Row(node: node, depth: depth)]
            if node.isDirectory, expanded.contains(node.url), let children = node.children {
                rows += flattenExpanded(children, depth: depth + 1)
            }
            return rows
        }
    }

    /// Every loaded file, for filtering. Only expanded directories have been
    /// scanned, so this searches what is known rather than walking the disk
    /// on each keystroke.
    private func flattenAll(_ nodes: [FileNode]) -> [FileNode] {
        nodes.flatMap { node -> [FileNode] in
            if node.isDirectory {
                return node.children.map(flattenAll) ?? []
            }
            return [node]
        }
    }

    // MARK: - Actions

    private func activate(_ node: FileNode) {
        selection = node.url
        if node.isDirectory {
            toggle(node)
        } else {
            onOpen(node.url)
        }
    }

    private func toggle(_ node: FileNode) {
        if expanded.contains(node.url) {
            expanded.remove(node.url)
        } else {
            expanded.insert(node.url)
            loadChildren(of: node.url)
        }
    }

    private func reload() {
        expanded.removeAll()
        guard let root else {
            nodes = []
            return
        }
        nodes = FileTree.children(of: root)
    }

    /// Scans a directory the first time it is opened.
    private func loadChildren(of url: URL) {
        func fill(_ nodes: inout [FileNode]) -> Bool {
            for index in nodes.indices {
                if nodes[index].url == url {
                    if nodes[index].children == nil {
                        nodes[index].children = FileTree.children(of: url)
                    }
                    return true
                }
                if nodes[index].isDirectory, nodes[index].children != nil,
                    fill(&nodes[index].children!)
                {
                    return true
                }
            }
            return false
        }
        _ = fill(&nodes)
    }
}

/// One row of the navigator.
private struct NavigatorRow: View {
    let node: FileNode
    let depth: Int
    let subtitle: String?
    let isExpanded: Bool
    let isSelected: Bool
    let reduceMotion: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: GlassTheme.Spacing.tight) {
                if node.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 10)
                    // A folder glyph as well as the chevron: the chevron says
                    // "this opens", the folder says what it is, and with only
                    // the chevron an unexpanded folder and a file differ by
                    // ten points of indent.
                    Image(systemName: isExpanded ? "folder.fill" : "folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                        .contentTransition(.symbolEffect(.replace))
                } else {
                    Image(systemName: "doc.text")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(width: 12)
                        .padding(.leading, 10 + GlassTheme.Spacing.tight)
                }

                Text(node.displayName)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)

                Spacer(minLength: GlassTheme.Spacing.tight)

                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .layoutPriority(-1)
                }
            }
            .padding(.vertical, 4)
            .padding(.leading, CGFloat(depth) * 14 + 6)
            .padding(.trailing, 6)
            .background(
                RoundedRectangle(cornerRadius: GlassTheme.Radius.small)
                    .fill(background)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(
            GlassTheme.motion(GlassTheme.quickSpring, reduceMotion: reduceMotion),
            value: isExpanded)
        .animation(
            GlassTheme.motion(GlassTheme.quickSpring, reduceMotion: reduceMotion),
            value: isHovering)
        .animation(
            GlassTheme.motion(GlassTheme.quickSpring, reduceMotion: reduceMotion),
            value: isSelected)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var background: Color {
        if isSelected { return Color.accentColor.opacity(0.22) }
        if isHovering { return Color.primary.opacity(0.07) }
        return .clear
    }
}
