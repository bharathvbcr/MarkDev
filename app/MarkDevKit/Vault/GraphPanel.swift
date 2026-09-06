//
//  GraphPanel.swift
//  MarkDevKit
//
//  The graph, and the controls that decide what it shows.
//

import Foundation
import SwiftUI

/// A floating panel showing the vault's link graph.
///
/// Floating rather than docked in the inspector: the inspector is 300pt wide
/// by design, because backlink context is prose, and a graph in a 300pt column
/// is a smear. The panel takes the window the way the command palette does.
public struct GraphPanel: View {
    public let vault: VaultIndex
    /// The note in front of the reader, highlighted and used as the focus of
    /// the local view.
    public let current: String?
    public var onOpen: (String) -> Void
    public var onDismiss: () -> Void

    @State private var graph: VaultGraph = .empty
    @State private var scope: Scope
    @State private var depth = 2
    @State private var tag: String?
    /// Solved graphs by ``rebuildKey``, so flipping scope or hopping depth —
    /// the two controls a reader actually works — answers from memory instead
    /// of re-running the force simulation they already watched finish.
    @State private var solved: [RebuildIdentity: VaultGraph] = [:]
    /// Insertion order for ``solved``'s eviction, which a dictionary cannot
    /// remember on its own.
    @State private var solvedOrder: [RebuildIdentity] = []
    @State private var isComputing = false
    /// Invalidates older asynchronous solves even when a newer request is
    /// fulfilled from cache before the older one returns.
    @State private var rebuildIdentityToken = UUID()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How much of the vault to draw.
    enum Scope: String, CaseIterable, Identifiable {
        /// Everything, so the shape of the vault is visible.
        case whole
        /// Only what is near the open note. The default: a whole-vault graph
        /// of a mature vault is a hairball, and the question someone actually
        /// has is "what is this note connected to".
        case local

        var id: String { rawValue }
        var label: String { self == .whole ? "Whole Vault" : "Around This Note" }
    }

    struct RebuildIdentity: Hashable {
        let scope: Scope
        let depth: Int
        let tag: String?
        let current: String?
        let contentVersion: VaultContentVersion
    }

    public init(
        vault: VaultIndex,
        current: String?,
        onOpen: @escaping (String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.vault = vault
        self.current = current
        self.onOpen = onOpen
        self.onDismiss = onDismiss
        self._scope = State(initialValue: Self.resolvedScope(.local, current: current))
    }

    public var body: some View {
        VStack(spacing: 0) {
            controls
            Divider().opacity(0.4)
            content
        }
        .frame(maxWidth: 900, maxHeight: 680)
        .glassPanel(radius: GlassTheme.Radius.large, padding: EdgeInsets())
        .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
        .padding(GlassTheme.Spacing.loose)
        // Rebuilt whenever anything it depends on changes, including the open
        // note: a local graph that kept pointing at the note you left is worse
        // than no graph. The rebuild awaits, so a slower scope change cancels
        // the layout of the faster one it replaced instead of racing it.
        .task(id: rebuildKey) { await rebuild() }
        .onChange(of: current) { _, newCurrent in
            if newCurrent == nil { scope = .whole }
        }
    }

    /// Everything the drawn graph depends on. Collapsed into one value so the
    /// rebuild is expressed once rather than as four `onChange` handlers that
    /// can fall out of step.
    private var rebuildKey: RebuildIdentity {
        Self.rebuildIdentity(
            scope: scope,
            depth: depth,
            tag: tag,
            current: current,
            contentVersion: vault.contentVersion)
    }

    static func resolvedScope(_ requested: Scope, current: String?) -> Scope {
        current == nil ? .whole : requested
    }

    static func rebuildIdentity(
        scope: Scope,
        depth: Int,
        tag: String?,
        current: String?,
        contentVersion: VaultContentVersion
    ) -> RebuildIdentity {
        let resolved = resolvedScope(scope, current: current)
        return RebuildIdentity(
            scope: resolved,
            depth: depth,
            tag: tag,
            current: resolved == .local ? current : nil,
            contentVersion: contentVersion)
    }

    static func graphAfterRebuild(previous _: VaultGraph, computed: VaultGraph) -> VaultGraph {
        computed
    }

    /// The single publish rule for asynchronous solves. Both identities are
    /// required: a cached newer request can replace the operation token
    /// without changing inputs, while a content edit can change the rebuild
    /// key before a view-state update installs another token.
    static func acceptsRebuildResult(
        request: RebuildIdentity,
        identityToken: UUID,
        current: RebuildIdentity,
        currentIdentityToken: UUID,
        isCancelled: Bool
    ) -> Bool {
        !isCancelled && identityToken == currentIdentityToken && request == current
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            regularControls
            compactControls
        }
        .padding(.horizontal, GlassTheme.Spacing.regular)
        .padding(.vertical, GlassTheme.Spacing.snug)
    }

    private var regularControls: some View {
        HStack(spacing: GlassTheme.Spacing.snug) {
            Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                .foregroundStyle(.secondary)
            Text("Graph")
                .font(.headline)

            Picker(
                "Scope",
                selection: Binding(
                    get: { Self.resolvedScope(scope, current: current) },
                    set: { scope = $0 })
            ) {
                ForEach(Scope.allCases) { scope in
                    Text(scope.label).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            // A local view of nothing is not a view; without an open note the
            // only honest scope is the whole vault.
            .disabled(current == nil)

            if Self.resolvedScope(scope, current: current) == .local {
                Stepper(value: $depth, in: 1...5) {
                    Text("\(depth) hop\(depth == 1 ? "" : "s")")
                        .font(.caption)
                        .monospacedDigit()
                }
                .fixedSize()
            }

            Spacer(minLength: GlassTheme.Spacing.snug)

            tagFilter

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .controlTarget(Circle(), padding: GlassTheme.Spacing.tight)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close graph")
        }
    }

    private var compactControls: some View {
        HStack(spacing: GlassTheme.Spacing.tight) {
            Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                .foregroundStyle(.secondary)

            Picker(
                "Scope",
                selection: Binding(
                    get: { Self.resolvedScope(scope, current: current) },
                    set: { scope = $0 })
            ) {
                ForEach(Scope.allCases) { scope in
                    Text(scope.label).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
            .disabled(current == nil)

            if Self.resolvedScope(scope, current: current) == .local {
                Stepper(value: $depth, in: 1...5) {
                    Text("\(depth)h")
                        .font(.caption)
                        .monospacedDigit()
                }
                .fixedSize()
            }

            Spacer(minLength: GlassTheme.Spacing.tight)

            tagFilter

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .controlTarget(Circle(), padding: GlassTheme.Spacing.tight)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close graph")
        }
    }

    private var tagFilter: some View {
        Menu {
            Button("All Tags") { tag = nil }
            Divider()
            ForEach(vault.tags()) { entry in
                Button("\(entry.tag) (\(entry.count))") { tag = entry.tag }
            }
        } label: {
            Label(tag ?? "All Tags", systemImage: "number")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder
    private var content: some View {
        if isComputing && graph.isEmpty {
            VStack(spacing: GlassTheme.Spacing.tight) {
                ProgressView()
                    .controlSize(.large)
                Text("Laying out \(vault.noteCount) notes…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(GlassTheme.Spacing.loose)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if graph.isEmpty {
            VStack(spacing: GlassTheme.Spacing.tight) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text(emptyReason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(GlassTheme.Spacing.loose)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GraphView(graph: graph, current: current, onOpen: onOpen)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(GlassTheme.Spacing.snug)
        }
    }

    /// Why the canvas is blank — never just a blank canvas.
    ///
    /// Empty means something different in each case, and the difference is
    /// exactly what tells the reader whether to change a filter, link a note,
    /// or open a vault.
    private var emptyReason: String {
        Self.emptyReason(hasOpenVault: vault.root != nil, noteCount: vault.noteCount, tag: tag)
    }

    static func emptyReason(hasOpenVault: Bool, noteCount: Int, tag: String?) -> String {
        guard hasOpenVault else { return "No vault open." }
        if noteCount == 0 { return "This vault has no notes yet." }
        if let tag { return "No notes tagged \(tag)." }
        return "Nothing linked yet — use [[wikilinks]] to connect notes."
    }

    private func rebuild() async {
        let key = rebuildKey
        let identityToken = UUID()
        rebuildIdentityToken = identityToken

        if let solved = solved[key] {
            graph = solved
            isComputing = false
            return
        }

        // Never show a graph for a previous filter or index revision while a
        // new solve is pending. An empty or failed solve must leave it empty.
        graph = .empty
        isComputing = true

        // Editing can advance the index on every keystroke. Debounce before
        // cloning so superseded requests do not fan out force simulations.
        do {
            try await Task.sleep(for: .milliseconds(150))
        } catch {
            return
        }
        guard Self.acceptsRebuildResult(
            request: key,
            identityToken: identityToken,
            current: rebuildKey,
            currentIdentityToken: rebuildIdentityToken,
            isCancelled: Task.isCancelled)
        else { return }

        let computed = await vault.graphOffMain(
            focus: key.scope == .local ? key.current : nil,
            depth: key.depth,
            tag: key.tag)

        // The key changed mid-flight: a newer rebuild owns the canvas now,
        // and assigning would flash this graph over theirs before that one
        // lands. Stale results are discarded rather than cached as current.
        guard Self.acceptsRebuildResult(
            request: key,
            identityToken: identityToken,
            current: rebuildKey,
            currentIdentityToken: rebuildIdentityToken,
            isCancelled: Task.isCancelled)
        else { return }
        isComputing = false
        graph = Self.graphAfterRebuild(previous: graph, computed: computed)
        guard !computed.isEmpty else { return }

        if solved[key] == nil { solvedOrder.append(key) }
        solved[key] = computed

        // A handful of solves at most: every scope × depth × tag combination
        // a session has actually shown, evicted least-recently-added once it
        // grows past what any reader will flip between.
        while solvedOrder.count > 12 {
            let stale = solvedOrder.removeFirst()
            solved.removeValue(forKey: stale)
        }
    }
}
