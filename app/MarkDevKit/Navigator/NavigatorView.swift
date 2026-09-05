//
//  NavigatorView.swift
//  MarkDevKit
//
//  The vault sidebar.
//

import AppKit
import SwiftUI

struct NavigatorTreeSnapshot {
    let nodes: [FileNode]
    let expanded: Set<URL>
    let hitEntryLimit: Bool
    let hitDepthLimit: Bool
    let hadReadError: Bool

    var incompleteMessage: String? {
        if hitEntryLimit || hitDepthLimit {
            return "Navigator stopped at its display limit. Some items are hidden."
        }
        if hadReadError {
            return "Some folders could not be read. The navigator may be incomplete."
        }
        return nil
    }
}

/// Rebuilds the lazy tree while retaining only directories still reachable
/// through the vault's own visibility rules.
enum NavigatorTreeReloader {
    /// A sidebar cannot usefully expose an unbounded number of rows. This cap
    /// also bounds validation work when many expanded paths survive a reload.
    static let maximumEntries = 20_000
    static let maximumDepth = 48

    static func rebuild(
        root: URL?,
        previousRoot: URL?,
        expanded: Set<URL>,
        maxEntries: Int = maximumEntries
    ) -> NavigatorTreeSnapshot {
        guard let root else {
            return NavigatorTreeSnapshot(
                nodes: [],
                expanded: [],
                hitEntryLimit: false,
                hitDepthLimit: false,
                hadReadError: false)
        }
        // Validate before standardization: Foundation removes the host from
        // `file://remote.example/local/path`, after which an ordinary
        // enumerator would inventory the matching local directory.
        guard BoundedRegularFileReader.hasLocalFileAuthority(root) else {
            return NavigatorTreeSnapshot(
                nodes: [],
                expanded: [],
                hitEntryLimit: false,
                hitDepthLimit: false,
                hadReadError: true)
        }
        let normalizedRoot = root.standardizedFileURL
        let sameRoot = previousRoot.flatMap {
            BoundedRegularFileReader.hasLocalFileAuthority($0)
                ? $0.standardizedFileURL
                : nil
        } == normalizedRoot
        var budget = TreeBudget(remainingEntries: max(0, maxEntries))
        var cache: [URL: [FileNode]] = [:]
        var nodes = cachedChildren(of: normalizedRoot, cache: &cache, budget: &budget)
        guard sameRoot else {
            return NavigatorTreeSnapshot(
                nodes: nodes,
                expanded: [],
                hitEntryLimit: budget.hitEntryLimit,
                hitDepthLimit: budget.hitDepthLimit,
                hadReadError: budget.hadReadError)
        }

        // Expansion is only created from displayed rows, whose total is
        // capped above. Sorting makes pruning deterministic if an older view
        // somehow hands us more state than the current bound permits.
        let candidates = expanded.compactMap {
            BoundedRegularFileReader.hasLocalFileAuthority($0)
                ? $0.standardizedFileURL
                : nil
        }.sorted { $0.path < $1.path }
        if candidates.count > maxEntries { budget.hitEntryLimit = true }
        let retained = Set(candidates.prefix(max(0, maxEntries)).compactMap {
            candidate -> URL? in
            isReachableDirectory(
                candidate, under: normalizedRoot, cache: &cache, budget: &budget)
                ? candidate : nil
        })
        hydrate(&nodes, depth: 0, expanded: retained, cache: &cache, budget: &budget)
        return NavigatorTreeSnapshot(
            nodes: nodes,
            expanded: retained,
            hitEntryLimit: budget.hitEntryLimit,
            hitDepthLimit: budget.hitDepthLimit,
            hadReadError: budget.hadReadError)
    }

    private static func hydrate(
        _ nodes: inout [FileNode],
        depth: Int,
        expanded: Set<URL>,
        cache: inout [URL: [FileNode]],
        budget: inout TreeBudget
    ) {
        for index in nodes.indices where nodes[index].isDirectory {
            let url = nodes[index].url.standardizedFileURL
            guard expanded.contains(url) else { continue }
            guard depth < maximumDepth else {
                budget.hitDepthLimit = true
                continue
            }
            nodes[index].children = cachedChildren(of: url, cache: &cache, budget: &budget)
            hydrate(
                &nodes[index].children!,
                depth: depth + 1,
                expanded: expanded,
                cache: &cache,
                budget: &budget)
        }
    }

    private static func isReachableDirectory(
        _ candidate: URL,
        under root: URL,
        cache: inout [URL: [FileNode]],
        budget: inout TreeBudget
    ) -> Bool {
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count > rootComponents.count,
            candidateComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
        else { return false }
        guard candidateComponents.count - rootComponents.count <= maximumDepth else {
            budget.hitDepthLimit = true
            return false
        }

        var parent = root
        for component in candidateComponents.dropFirst(rootComponents.count) {
            guard
                let directory = cachedChildren(
                    of: parent, cache: &cache, budget: &budget
                ).first(where: {
                    $0.isDirectory && $0.url.lastPathComponent == component
                })
            else { return false }
            parent = directory.url.standardizedFileURL
        }
        return parent == candidate
    }

    private static func cachedChildren(
        of directory: URL,
        cache: inout [URL: [FileNode]],
        budget: inout TreeBudget
    ) -> [FileNode] {
        let directory = directory.standardizedFileURL
        if let children = cache[directory] { return children }
        let children = boundedChildren(of: directory, budget: &budget)
        cache[directory] = children
        return children
    }

    /// One-level, lazy directory inventory with the same visibility contract
    /// as `FileTree.children`, but charged against a cross-rebuild budget.
    private static func boundedChildren(
        of directory: URL, budget: inout TreeBudget
    ) -> [FileNode] {
        guard BoundedRegularFileReader.hasLocalFileAuthority(directory) else {
            budget.hadReadError = true
            return []
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey, .isSymbolicLinkKey]
        guard
            let directoryValues = try? directory.resourceValues(forKeys: Set(keys)),
            directoryValues.isDirectory == true,
            directoryValues.isSymbolicLink != true
        else {
            budget.hadReadError = true
            return []
        }
        var enumerationFailed = false
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: keys,
                options: [
                    .skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants,
                ],
                errorHandler: { _, _ in
                    enumerationFailed = true
                    return false
                })
        else {
            budget.hadReadError = true
            return []
        }

        var nodes: [FileNode] = []
        while budget.remainingEntries > 0, let entry = enumerator.nextObject() as? URL {
            budget.remainingEntries -= 1
            guard let values = try? entry.resourceValues(forKeys: Set(keys)) else {
                budget.hadReadError = true
                continue
            }
            guard values.isSymbolicLink != true else { continue }
            let isDirectory = values.isDirectory ?? false
            if isDirectory {
                guard !FileTree.ignoredDirectories.contains(entry.lastPathComponent) else {
                    continue
                }
                nodes.append(FileNode(url: entry.standardizedFileURL, isDirectory: true))
            } else {
                guard FileTree.markdownExtensions.contains(entry.pathExtension.lowercased()) else {
                    continue
                }
                nodes.append(FileNode(url: entry.standardizedFileURL, isDirectory: false))
            }
        }
        if budget.remainingEntries == 0, enumerator.nextObject() != nil {
            budget.hitEntryLimit = true
        }
        if enumerationFailed { budget.hadReadError = true }
        return nodes.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private struct TreeBudget {
        var remainingEntries: Int
        var hitEntryLimit = false
        var hitDepthLimit = false
        var hadReadError = false
    }
}

struct NavigatorTreeRequest: Hashable, Sendable {
    let root: URL?
    let revision: Int
    let expanded: [URL]

    init(root: URL?, revision: Int, expanded: Set<URL>) {
        self.root = root.flatMap {
            BoundedRegularFileReader.hasLocalFileAuthority($0)
                ? $0.standardizedFileURL
                : nil
        }
        self.revision = revision
        self.expanded = expanded.compactMap {
            BoundedRegularFileReader.hasLocalFileAuthority($0)
                ? $0.standardizedFileURL
                : nil
        }.sorted { $0.path < $1.path }
    }
}

struct NavigatorTreeReloadState {
    private(set) var generation: UInt64 = 0
    private var request: NavigatorTreeRequest?
    private var loading = false

    @discardableResult
    mutating func begin(_ request: NavigatorTreeRequest) -> UInt64 {
        generation &+= 1
        self.request = request
        loading = true
        return generation
    }

    @discardableResult
    mutating func complete(_ request: NavigatorTreeRequest, generation: UInt64) -> Bool {
        guard self.request == request, self.generation == generation else { return false }
        loading = false
        return true
    }

    func isPending(_ request: NavigatorTreeRequest) -> Bool {
        self.request != request || loading
    }
}

struct NavigatorFilterRequest: Hashable, Sendable {
    let root: URL
    let revision: Int
    let query: String

    init(root: URL, revision: Int, query: String) {
        // Keep a refused authority intact so FileTree's boundary can reject
        // it. Standardizing it here would turn the later secure check into a
        // check of a newly manufactured local URL.
        self.root = BoundedRegularFileReader.hasLocalFileAuthority(root)
            ? root.standardizedFileURL
            : root
        self.revision = revision
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The bounded result published to SwiftUI after a vault-wide background rank.
struct NavigatorFilterSnapshot: Sendable, Equatable {
    let matches: [FileNode]
    let scan: FileTree.ScanResult
    let totalMatches: Int

    var didLimitMatches: Bool { totalMatches > matches.count }
}

/// Serial background owner for navigator inventories.
///
/// The scanner itself is synchronous, so launching one detached task per
/// revision would let cancelled scans keep competing for disk. An actor keeps
/// at most one bounded walk running; superseded requests queued behind it see
/// cancellation before touching the filesystem.
actor NavigatorFilesystemScanner {
    static let shared = NavigatorFilesystemScanner()

    private struct FilterInventoryKey: Equatable {
        let root: URL
        let revision: Int
    }

    /// One bounded inventory is reused while someone types within the same
    /// vault revision. Query ranking is still redone off the main actor, while
    /// rapid keystrokes do not each trigger another filesystem walk.
    private var filterInventoryKey: FilterInventoryKey?
    private var filterInventory: FileTree.ScanResult?

    func rebuildTree(
        _ request: NavigatorTreeRequest, previousRoot: URL?
    ) -> NavigatorTreeSnapshot? {
        guard !Task.isCancelled else { return nil }
        let snapshot = NavigatorTreeReloader.rebuild(
            root: request.root,
            previousRoot: previousRoot,
            expanded: Set(request.expanded))
        guard !Task.isCancelled else { return nil }
        return snapshot
    }

    func scanFilter(_ request: NavigatorFilterRequest) -> NavigatorFilterSnapshot? {
        guard !Task.isCancelled else { return nil }
        let key = FilterInventoryKey(root: request.root, revision: request.revision)
        let scan: FileTree.ScanResult
        if filterInventoryKey == key, let filterInventory {
            scan = filterInventory
        } else {
            let fresh = FileTree.scanMarkdownFiles(under: request.root, limits: .standard)
            filterInventoryKey = key
            filterInventory = fresh
            scan = fresh
        }
        guard !Task.isCancelled else { return nil }
        return NavigatorFilterResults.rankedSnapshot(in: scan, query: request.query)
    }
}

/// Latest-wins state for a bounded background inventory.
struct NavigatorFilterSearchState {
    private(set) var generation: UInt64 = 0
    private var request: NavigatorFilterRequest?
    private var snapshot: NavigatorFilterSnapshot?
    private var loading = false

    @discardableResult
    mutating func begin(_ request: NavigatorFilterRequest) -> UInt64 {
        generation &+= 1
        self.request = request
        snapshot = nil
        loading = true
        return generation
    }

    @discardableResult
    mutating func complete(
        _ snapshot: NavigatorFilterSnapshot,
        for request: NavigatorFilterRequest,
        generation: UInt64
    ) -> Bool {
        guard self.request == request, self.generation == generation else { return false }
        self.snapshot = snapshot
        loading = false
        return true
    }

    mutating func reset() {
        generation &+= 1
        request = nil
        snapshot = nil
        loading = false
    }

    func result(for request: NavigatorFilterRequest) -> NavigatorFilterSnapshot? {
        guard self.request == request, !loading else { return nil }
        return snapshot
    }

    func isLoading(_ request: NavigatorFilterRequest) -> Bool {
        self.request == request && loading
    }

    func isPending(_ request: NavigatorFilterRequest) -> Bool {
        self.request != request || loading
    }
}

enum NavigatorFilterResults {
    static let maximumMatches = 200

    /// Ranks off the main actor and keeps only the best `limit` rows in memory.
    /// Cancellation is sampled during the CPU-bound pass so a superseded query
    /// cannot monopolise the scanner actor until all 100,000 candidates finish.
    static func rankedSnapshot(
        in scan: FileTree.ScanResult,
        query: String,
        limit: Int = maximumMatches,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) -> NavigatorFilterSnapshot? {
        struct ScoredNode {
            let node: FileNode
            let score: Int
        }

        let limit = max(0, limit)
        var top: [ScoredNode] = []
        top.reserveCapacity(limit)
        var totalMatches = 0

        for (index, url) in scan.files.enumerated() {
            if index.isMultiple(of: 64), isCancelled() { return nil }
            let node = FileNode(url: url, isDirectory: false)
            guard let score = FuzzyMatch.score(node.displayName, query: query) else { continue }
            totalMatches += 1
            guard limit > 0 else { continue }

            let candidate = ScoredNode(node: node, score: score)
            let insertion = top.firstIndex { existing in
                candidate.score > existing.score
                    || (candidate.score == existing.score
                        && candidate.node.url.path < existing.node.url.path)
            }
            if let insertion {
                top.insert(candidate, at: insertion)
            } else if top.count < limit {
                top.append(candidate)
            }
            if top.count > limit { top.removeLast() }
        }
        guard !isCancelled() else { return nil }
        return NavigatorFilterSnapshot(
            matches: top.map(\.node),
            scan: scan,
            totalMatches: totalMatches)
    }

    static func incompleteMessage(for scan: FileTree.ScanResult) -> String? {
        guard !scan.isComplete else { return nil }
        if scan.hitDepthLimit || scan.hitEntryLimit {
            return "Search stopped at the vault scan limit. Results are incomplete."
        }
        if scan.unreadableDirectories > 0 || scan.unreadableEntries > 0 {
            return "Some vault items could not be read. Results are incomplete."
        }
        return "Oversized notes were not searched. Results are incomplete."
    }

    static func incompleteMessage(for snapshot: NavigatorFilterSnapshot) -> String? {
        let scanMessage = incompleteMessage(for: snapshot.scan)
        let limitMessage = snapshot.didLimitMatches
            ? "Showing the top \(snapshot.matches.count) of \(snapshot.totalMatches) matching notes."
            : nil
        switch (scanMessage, limitMessage) {
        case (let scan?, let limit?): return scan + " " + limit
        case (let scan?, nil): return scan
        case (nil, let limit?): return limit
        case (nil, nil): return nil
        }
    }
}

/// Browsable file tree for the vault, with a fuzzy filter.
public struct NavigatorView: View {
    public let root: URL?
    /// Bumped whenever something outside this window may have changed the
    /// vault's contents — a file-system event most of all.
    ///
    /// The tree loads once per ``root`` otherwise, which made every note
    /// another tool created invisible until the vault was reopened. An
    /// integer rather than a callback keeps the navigator dumb about *why*
    /// it should re-scan; SwiftUI delivers the change wherever this value
    /// flows.
    public var revision: Int = 0
    /// Called when a file is chosen.
    public let onOpen: (URL) -> Void
    /// Called when the reader asks for a vault. The navigator raises the
    /// request rather than running the open panel itself: choosing a vault is
    /// a workspace-level decision, and the sidebar is only one of the places
    /// it can be made.
    public var onChooseVault: (() -> Void)?
    /// Called with the highlighted file while Space is held, and with `nil`
    /// when it is released. The navigator does not present the peek itself:
    /// the panel floats over the whole workspace, which the sidebar is only a
    /// corner of.
    public var onPeek: ((URL?) -> Void)?
    /// Called with a *directory* to open a shell in. A file resolves to the
    /// folder holding it, since that is what a shell can be started in and
    /// what someone means by "a terminal here" while pointing at a note.
    public var onOpenTerminal: ((URL) -> Void)?
    /// Called with the folder a new note should be created in. A file row
    /// resolves to its own folder, like ``onOpenTerminal``.
    public var onCreateNote: ((URL) -> Void)?
    /// Called with the file to rename. The navigator raises the request; the
    /// workspace owns naming, disk effects, and link rewriting together.
    public var onRename: ((URL) -> Void)?
    /// Called with the file or folder to move to the Trash.
    public var onDelete: ((URL) -> Void)?
    /// Called with note URLs dropped on a *folder*: a move within the vault,
    /// which is a rename to the core and so rewrites every link that
    /// pointed through the old path.
    public var onDropNotes: (([URL], URL) -> Void)?

    @State private var nodes: [FileNode] = []
    @State private var expanded: Set<URL> = []
    @State private var filter = ""
    @State private var selection: URL?
    @State private var loadedRoot: URL?
    @State private var treeReload = NavigatorTreeReloadState()
    @State private var treeIncompleteMessage: String?
    @State private var filterSearch = NavigatorFilterSearchState()
    @FocusState private var listFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        root: URL?,
        revision: Int = 0,
        onOpen: @escaping (URL) -> Void,
        onChooseVault: (() -> Void)? = nil,
        onPeek: ((URL?) -> Void)? = nil,
        onOpenTerminal: ((URL) -> Void)? = nil,
        onCreateNote: ((URL) -> Void)? = nil,
        onRename: ((URL) -> Void)? = nil,
        onDelete: ((URL) -> Void)? = nil,
        onDropNotes: (([URL], URL) -> Void)? = nil
    ) {
        self.root = root.flatMap {
            BoundedRegularFileReader.hasLocalFileAuthority($0)
                ? $0.standardizedFileURL
                : nil
        }
        self.revision = revision
        self.onOpen = onOpen
        self.onChooseVault = onChooseVault
        self.onPeek = onPeek
        self.onOpenTerminal = onOpenTerminal
        self.onCreateNote = onCreateNote
        self.onRename = onRename
        self.onDelete = onDelete
        self.onDropNotes = onDropNotes
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
        .task(id: treeRequest) {
            await reload(for: treeRequest)
        }
        .task(id: filterRequest) {
            await refreshFilter(for: filterRequest)
        }
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
            if let onOpenTerminal {
                // A button, not only a menu item: opening a shell at the vault
                // root is the common case, and burying the common case one
                // click deeper than "Reveal in Finder" makes the terminal feel
                // like a thing the app has rather than a thing it offers.
                Button { onOpenTerminal(root) } label: {
                    Image(systemName: "apple.terminal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Open a terminal in \(root.lastPathComponent)")
                .accessibilityLabel("Open a terminal in the vault")
            }
            Menu {
                Button("Change Vault…") { onChooseVault?() }
                if let onOpenTerminal {
                    Button("Open Terminal Here") { onOpenTerminal(root) }
                }
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
        let request = filterRequest
        VStack(spacing: 0) {
            if let message = navigatorCoverageMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, GlassTheme.Spacing.tight)
                    .padding(.vertical, GlassTheme.Spacing.tight)
                    .accessibilityLabel(message)
            }
            if filterQuery.isEmpty, treeReload.isPending(treeRequest), !nodes.isEmpty {
                HStack(spacing: GlassTheme.Spacing.tight) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Updating navigator…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, GlassTheme.Spacing.tight)
                .padding(.vertical, GlassTheme.Spacing.tight)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Updating navigator")
            }
            if let request, filterSearch.isPending(request) {
                VStack(spacing: GlassTheme.Spacing.tight) {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Text("Searching all notes…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Searching all notes")
            } else if filterQuery.isEmpty, treeReload.isPending(treeRequest), rows.isEmpty {
                VStack(spacing: GlassTheme.Spacing.tight) {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading vault…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Loading vault")
            } else if rows.isEmpty {
                VStack(spacing: GlassTheme.Spacing.tight) {
                    Spacer()
                    Text(filterQuery.isEmpty ? "This vault has no notes yet" : emptyFilterTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if filterQuery.isEmpty, let root, let onCreateNote {
                        Button("New Note…") { onCreateNote(root) }
                            .controlSize(.small)
                            .accessibilityIdentifier("navigator.empty.new-note")
                    } else if !filterQuery.isEmpty {
                        Text("for “\(filter)”")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { scroller in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(rows, id: \.node.id) { row in
                                NavigatorRow(
                                    node: row.node,
                                    root: root,
                                    depth: row.depth,
                                    subtitle: row.subtitle,
                                    isExpanded: expanded.contains(row.node.url),
                                    isSelected: selection == row.node.url,
                                    reduceMotion: reduceMotion,
                                    onDropNotes: onDropNotes
                                ) {
                                    listFocused = true
                                    activate(row.node)
                                }
                                .id(row.node.url)
                                .contextMenu {
                                    if let onCreateNote {
                                        Button("New Note…") {
                                            onCreateNote(
                                                NavigatorTerminalTarget.directory(for: row.node))
                                        }
                                    }
                                    if row.node.isDirectory || onRename != nil {
                                        Divider()
                                    }
                                    if !row.node.isDirectory, let onRename {
                                        Button("Rename…") { onRename(row.node.url) }
                                    }
                                    if let onDelete {
                                        Button("Move to Trash", role: .destructive) {
                                            onDelete(row.node.url)
                                        }
                                    }
                                    if let onOpenTerminal {
                                        Divider()
                                        Button("Open Terminal Here") {
                                            onOpenTerminal(
                                                NavigatorTerminalTarget.directory(for: row.node))
                                        }
                                    }
                                    Divider()
                                    Button("Reveal in Finder") {
                                        NSWorkspace.shared.activateFileViewerSelecting([row.node.url])
                                    }
                                    Button("Copy Path") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(
                                            row.node.url.path, forType: .string)
                                    }
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
                        .padding(.vertical, GlassTheme.Spacing.tight)
                    }
                    .scrollContentBackground(.hidden)
                    .onChange(of: selection) { _, new in
                        guard let new else { return }
                        scroller.scrollTo(new, anchor: .center)
                    }
                }
                .focusable()
                .focused($listFocused)
                .focusEffectDisabled()
                .onKeyPress(.downArrow) { moveSelection(by: 1, in: rows) }
                .onKeyPress(.upArrow) { moveSelection(by: -1, in: rows) }
                .onKeyPress(.rightArrow) { setExpansion(true) }
                .onKeyPress(.leftArrow) { setExpansion(false) }
                .onKeyPress(.return) { openSelection() }
                // Hold Space to peek, release to dismiss — the Finder gesture.
                // Both phases are requested and key repeat is not, so holding the
                // key down does not fire a stream of open-and-close requests.
                .onKeyPress(.space, phases: [.down, .up]) { press in
                    onPeek?(press.phase == .down ? peekTarget : nil)
                    return .handled
                }
                // Releasing Space after focus has moved elsewhere would otherwise
                // leave the panel stuck open with no key to dismiss it.
                .onChange(of: listFocused) { _, focused in
                    if !focused { onPeek?(nil) }
                }
                .scrollContentBackground(.hidden)
                .animation(
                    GlassTheme.motion(GlassTheme.quickSpring, reduceMotion: reduceMotion),
                    value: expanded)
            }
        }
    }

    // MARK: - Keyboard

    /// The file the peek panel should show: directories have nothing to
    /// preview, so Space over one is a no-op rather than an empty panel.
    private var peekTarget: URL? {
        guard let selection,
            let node = visibleRows.first(where: { $0.node.url == selection })?.node,
            !node.isDirectory
        else { return nil }
        return selection
    }

    private func moveSelection(by offset: Int, in rows: [Row]) -> KeyPress.Result {
        let urls = rows.map(\.node.url)
        guard let next = NavigatorKeyboard.move(selection, by: offset, in: urls) else {
            return .ignored
        }
        selection = next
        return .handled
    }

    /// Expands or collapses the selected directory.
    ///
    /// Collapsing an already-collapsed row steps to its parent, which is what
    /// makes left-arrow feel like "out" rather than dead.
    private func setExpansion(_ expand: Bool) -> KeyPress.Result {
        guard let selection,
            let node = visibleRows.first(where: { $0.node.url == selection })?.node
        else { return .ignored }

        if expand {
            guard node.isDirectory, !expanded.contains(node.url) else { return .ignored }
            expanded.insert(node.url)
            return .handled
        }

        if node.isDirectory, expanded.contains(node.url) {
            expanded.remove(node.url)
            return .handled
        }
        let parent = node.url.deletingLastPathComponent()
        guard parent != root, visibleRows.contains(where: { $0.node.url == parent }) else {
            return .ignored
        }
        self.selection = parent
        return .handled
    }

    private func openSelection() -> KeyPress.Result {
        guard let selection,
            let node = visibleRows.first(where: { $0.node.url == selection })?.node
        else { return .ignored }
        activate(node)
        return .handled
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
        guard !filterQuery.isEmpty else {
            return flattenExpanded(nodes, depth: 0)
        }
        guard let request = filterRequest, let snapshot = filterSearch.result(for: request) else {
            return []
        }
        return snapshot.matches.map { Row(node: $0, depth: 0, subtitle: folder(of: $0)) }
    }

    private var filterQuery: String {
        filter.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Query text participates in task identity because ranking now happens on
    /// the scanner actor. The actor caches the root/revision inventory, so a
    /// rapid edit cancels stale ranking without repeating the filesystem walk.
    private var filterRequest: NavigatorFilterRequest? {
        guard let root, !filterQuery.isEmpty else { return nil }
        return NavigatorFilterRequest(root: root, revision: revision, query: filterQuery)
    }

    private var filterCoverageMessage: String? {
        guard let request = filterRequest, let snapshot = filterSearch.result(for: request) else {
            return nil
        }
        return NavigatorFilterResults.incompleteMessage(for: snapshot)
    }

    private var navigatorCoverageMessage: String? {
        filterQuery.isEmpty ? treeIncompleteMessage : filterCoverageMessage
    }

    private var emptyFilterTitle: String {
        filterCoverageMessage == nil ? "No matches" : "No matches in scanned notes"
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
        }
    }

    private var treeRequest: NavigatorTreeRequest {
        NavigatorTreeRequest(root: root, revision: revision, expanded: expanded)
    }

    @MainActor
    private func reload(for request: NavigatorTreeRequest) async {
        let normalizedRoot = request.root
        let previousRoot = loadedRoot
        if loadedRoot != normalizedRoot {
            loadedRoot = normalizedRoot
            nodes = []
            expanded = []
            treeIncompleteMessage = nil
            selection = nil
            onPeek?(nil)
            // Clearing old-root expansion changes the request identity. Let
            // the replacement task own the new root rather than publishing a
            // snapshot built from stale intent.
            guard request == treeRequest else { return }
        }
        let generation = treeReload.begin(request)
        guard
            let snapshot = await NavigatorFilesystemScanner.shared.rebuildTree(
                request, previousRoot: previousRoot),
            !Task.isCancelled,
            treeReload.complete(request, generation: generation)
        else { return }
        nodes = snapshot.nodes
        expanded = snapshot.expanded
        treeIncompleteMessage = snapshot.incompleteMessage
    }

    @MainActor
    private func refreshFilter(for request: NavigatorFilterRequest?) async {
        guard let request else {
            filterSearch.reset()
            return
        }
        let generation = filterSearch.begin(request)
        guard let snapshot = await NavigatorFilesystemScanner.shared.scanFilter(request),
            !Task.isCancelled
        else { return }
        _ = filterSearch.complete(snapshot, for: request, generation: generation)
    }
}

/// Which directory a sidebar row means when asked for a terminal.
///
/// Pure, and separate from the view, because the rule is the whole feature: a
/// shell cannot start "in" a note. Pointing at `Notes/Index.md` and asking for
/// a terminal means `Notes/`, and getting that wrong is the difference between
/// a working command and a shell that starts at home for no visible reason.
enum NavigatorTerminalTarget {
    static func directory(for node: FileNode) -> URL {
        node.isDirectory ? node.url : node.url.deletingLastPathComponent()
    }
}

/// Where the arrow keys move the navigator's selection.
///
/// A pure function over the flattened row list, for the same reason
/// ``SplitLayout`` is a value type: "arrowing past the end stays put" and
/// "the first press with nothing selected lands on an end" are then tested
/// properties of the model, rather than behaviour that needs a window, a
/// focused view, and a synthesised key event to observe.
enum NavigatorKeyboard {
    /// The row `offset` steps from `selection`, or `nil` if nothing moves.
    ///
    /// Returning `nil` rather than the unchanged selection is what lets the
    /// view report the key as unhandled, so a press at the end of the list
    /// falls through to AppKit instead of being swallowed.
    static func move(_ selection: URL?, by offset: Int, in rows: [URL]) -> URL? {
        guard !rows.isEmpty else { return nil }
        guard let selection, let current = rows.firstIndex(of: selection) else {
            // Nothing selected yet: step in from whichever end the key implies.
            return offset >= 0 ? rows.first : rows.last
        }
        let next = current + offset
        guard rows.indices.contains(next), next != current else { return nil }
        return rows[next]
    }
}

/// Bounded hierarchy context for one flattened navigator row.
///
/// SwiftUI exposes the custom tree as buttons rather than a native outline,
/// so indentation alone never reaches VoiceOver. The spoken location retains
/// only the nearest ancestors and clips hostile or accidental long names: an
/// accessibility improvement must not turn a deeply nested vault into an
/// unbounded announcement.
enum NavigatorRowAccessibility {
    static let maximumContextComponents = 3
    static let maximumComponentCharacters = 48
    static let maximumLevel = NavigatorTreeReloader.maximumDepth + 1

    static func level(for depth: Int) -> Int {
        guard depth > 0 else { return 1 }
        return depth >= maximumLevel - 1 ? maximumLevel : depth + 1
    }

    static func location(root: URL?, node: URL, filteredFolder: String?) -> String {
        let components: [String]
        if let filteredFolder, !filteredFolder.isEmpty {
            components = filteredFolder.split(separator: "/").map(String.init)
        } else if let root {
            let rootComponents = root.standardizedFileURL.pathComponents
            let parentComponents = node.deletingLastPathComponent().standardizedFileURL.pathComponents
            if parentComponents.count >= rootComponents.count,
                parentComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
            {
                components = Array(parentComponents.dropFirst(rootComponents.count))
            } else {
                components = [node.deletingLastPathComponent().lastPathComponent]
            }
        } else {
            components = [node.deletingLastPathComponent().lastPathComponent]
        }

        let nonEmpty = components.filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else { return "Vault root" }
        let retained = nonEmpty.suffix(maximumContextComponents).map(clippedComponent)
        let prefix = nonEmpty.count > retained.count ? "… / " : ""
        return prefix + retained.joined(separator: " / ")
    }

    static func value(
        root: URL?,
        node: URL,
        depth: Int,
        filteredFolder: String?,
        isDirectory: Bool,
        isExpanded: Bool
    ) -> String {
        var parts = [
            "Level \(level(for: depth))",
            location(root: root, node: node, filteredFolder: filteredFolder),
        ]
        if isDirectory { parts.append(isExpanded ? "expanded" : "collapsed") }
        return parts.joined(separator: ", ")
    }

    private static func clippedComponent(_ component: String) -> String {
        guard component.count > maximumComponentCharacters else { return component }
        return String(component.prefix(maximumComponentCharacters - 1)) + "…"
    }
}

/// One row of the navigator.
private struct NavigatorRow: View {
    let node: FileNode
    let root: URL?
    let depth: Int
    let subtitle: String?
    let isExpanded: Bool
    let isSelected: Bool
    let reduceMotion: Bool
    /// Called with notes dropped on this row, when it is a folder. `nil`
    /// leaves the row neither draggable nor a drop target.
    var onDropNotes: (([URL], URL) -> Void)?

    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        let accessibilityLocation = NavigatorRowAccessibility.location(
            root: root, node: node.url, filteredFolder: subtitle)
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
        .modifier(NoteDragAndDrop(node: node, onDropNotes: onDropNotes))
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(node.displayName)
        // A folder's open state exists only as a chevron rotation otherwise;
        // spoken here so a screen-reader reader can tell an expanded folder
        // from a collapsed one or from a file.
        .accessibilityValue(
            NavigatorRowAccessibility.value(
                root: root,
                node: node.url,
                depth: depth,
                filteredFolder: subtitle,
                isDirectory: node.isDirectory,
                isExpanded: isExpanded))
        .accessibilityCustomContent("Outline level", "\(NavigatorRowAccessibility.level(for: depth))")
        .accessibilityCustomContent("Location", accessibilityLocation)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    }

    private var background: Color {
        if isSelected { return Color.accentColor.opacity(0.22) }
        if isHovering { return Color.primary.opacity(0.07) }
        return .clear
    }
}


/// Drag source for note rows, drop target for folder rows — one modifier so
/// the two sides of a move cannot drift apart.
///
/// A drop is a rename to the core (`renameNote` rewrites every link that
/// resolved through the old path), which is what makes dragging a note into
/// a folder behave exactly like renaming it in place.
struct NoteDragAndDrop: ViewModifier {
    let node: FileNode
    let onDropNotes: (([URL], URL) -> Void)?

    func body(content: Content) -> some View {
        content
            .modifier(NoteDragSource(node: node))
            .modifier(NoteDropTarget(node: node, onDropNotes: onDropNotes))
    }
}

/// Notes are draggable; folders and anything unreadable are not.
struct NoteDragSource: ViewModifier {
    let node: FileNode

    func body(content: Content) -> some View {
        if node.isDirectory {
            content
        } else {
            content.draggable(node.url)
        }
    }
}

/// Folders accept note URLs. The handler decides vault membership, same-name
/// collisions, and everything else; the row only recognises the gesture.
struct NoteDropTarget: ViewModifier {
    let node: FileNode
    let onDropNotes: (([URL], URL) -> Void)?

    @State private var isTargeted = false

    func body(content: Content) -> some View {
        if node.isDirectory, let onDropNotes {
            content
                .dropDestination(for: URL.self) { urls, _ in
                    onDropNotes(urls, node.url)
                    return true
                } isTargeted: { targeted in
                    isTargeted = targeted
                }
                .background {
                    RoundedRectangle(cornerRadius: GlassTheme.Radius.small)
                        .fill(Color.accentColor.opacity(isTargeted ? 0.16 : 0))
                }
        } else {
            content
        }
    }
}
