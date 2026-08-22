//
//  GraphPanel.swift
//  MarkDevKit
//
//  The graph, and the controls that decide what it shows.
//

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
    @State private var scope: Scope = .local
    @State private var depth = 2
    @State private var tag: String?
    /// Solved graphs by ``rebuildKey``, so flipping scope or hopping depth —
    /// the two controls a reader actually works — answers from memory instead
    /// of re-running the force simulation they already watched finish.
    @State private var solved: [String: VaultGraph] = [:]
    /// Insertion order for ``solved``'s eviction, which a dictionary cannot
    /// remember on its own.
    @State private var solvedOrder: [String] = []
    @State private var isComputing = false
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
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
    }

    /// Everything the drawn graph depends on. Collapsed into one value so the
    /// rebuild is expressed once rather than as four `onChange` handlers that
    /// can fall out of step.
    private var rebuildKey: String {
        "\(scope.rawValue)|\(depth)|\(tag ?? "")|\(current ?? "")|\(vault.noteCount)"
    }

    private var controls: some View {
        HStack(spacing: GlassTheme.Spacing.snug) {
            Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                .foregroundStyle(.secondary)
            Text("Graph")
                .font(.headline)

            Picker("Scope", selection: $scope) {
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

            if scope == .local, current != nil {
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
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close graph")
        }
        .padding(.horizontal, GlassTheme.Spacing.regular)
        .padding(.vertical, GlassTheme.Spacing.snug)
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
        if vault.noteCount == 0 { return "No vault open." }
        if tag != nil { return "No notes tagged \(tag ?? "")." }
        if scope == .local, current == nil { return "Open a note to see what it connects to." }
        return "Nothing linked yet — use [[wikilinks]] to connect notes."
    }

    private func rebuild() async {
        let key = rebuildKey
        if let solved = solved[key] {
            graph = solved
            return
        }

        isComputing = true
        defer { isComputing = false }

        let focus = scope == .local ? current : nil
        let computed = await vault.graphOffMain(focus: focus, depth: depth, tag: tag)
        guard !computed.isEmpty else { return }

        // The key changed mid-flight: a newer rebuild owns the canvas now,
        // and assigning would flash this graph over theirs before that one
        // lands. The solve is still cached under its own key either way.
        if !Task.isCancelled { graph = computed }
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
