//
//  TerminalDrawer.swift
//  MarkDevKit
//
//  A shell under the editor, for running coding CLIs against the vault.
//

import AppKit
import SwiftTerm
import SwiftUI

/// The terminal, and the chrome around it.
///
/// # Why one drawer rather than a terminal per pane
///
/// The plan sketched a terminal as another thing a split leaf could hold.
/// Built that way it fights the pane model: a leaf holds `OpenDocument`s, and
/// a shell has no document identity — no URL, no dirty state, nothing for
/// save, close-confirmation, or the vault index to mean. Every method on
/// ``Workspace`` would grow a branch for a tab that is not a document, which
/// is the special case for a state that should not exist.
///
/// So the drawer sits under the whole split tree and holds *several* shells as
/// tabs, which is what "open a terminal in this folder" needs: a shell's
/// working directory is fixed for its life, so a second folder means a second
/// session, not a relocated one.
///
/// The sessions themselves live in ``TerminalSessions``, above this view —
/// see that type for why.
public struct TerminalDrawer: View {
    @Bindable public var sessions: TerminalSessions
    /// Where a newly forked shell should start, when the reader presses `+`
    /// rather than picking a folder in the sidebar.
    public let document: URL?
    public let vault: URL?
    /// Which panel is drawing this. Only the chrome differs — the sessions,
    /// and the processes behind them, are the same either way.
    public var placement: TerminalPlacement = .drawer
    public var onClose: (() -> Void)?
    /// Moves the terminal to the other panel.
    public var onMove: (() -> Void)?
    /// Opens a shell already running the local harness. `nil` hides the option
    /// rather than offering one that cannot work — see ``HarnessLocator``.
    public var onOpenHarness: (() -> Void)?
    /// Surfaced rather than swallowed: refusing to open the ninth terminal is
    /// a decision the reader has to be told about.
    public var onError: ((String) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        sessions: TerminalSessions,
        document: URL?,
        vault: URL?,
        placement: TerminalPlacement = .drawer,
        onClose: (() -> Void)? = nil,
        onMove: (() -> Void)? = nil,
        onOpenHarness: (() -> Void)? = nil,
        onError: ((String) -> Void)? = nil
    ) {
        self.sessions = sessions
        self.document = document
        self.vault = vault
        self.placement = placement
        self.onClose = onClose
        self.onMove = onMove
        self.onOpenHarness = onOpenHarness
        self.onError = onError
    }

    public var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider().opacity(0.4)
            content
        }
        .background(.background)
        .onAppear {
            // A drawer opened with nothing in it is a black rectangle. The
            // first shell is created here rather than eagerly at launch, so an
            // app whose terminal is never opened never forks one.
            if sessions.isEmpty { openNewSession() }
        }
    }

    // MARK: - Chrome

    private var tabBar: some View {
        HStack(spacing: GlassTheme.Spacing.tight) {
            Image(systemName: "apple.terminal")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView(.horizontal) {
                HStack(spacing: GlassTheme.Spacing.hairline) {
                    ForEach(sessions.sessions) { session in
                        TerminalTab(
                            session: session,
                            isSelected: session.id == sessions.selection,
                            onSelect: { sessions.select(session.id) },
                            onClose: { sessions.close(session.id) })
                    }
                }
            }
            .scrollIndicators(.never)

            Spacer(minLength: 0)

            // A menu rather than a button once there is more than one kind of
            // shell to open. The harness entry is absent, not disabled, when
            // MANVI could not be found: a dead control is worse than no
            // control, which is the same rule the zoom chip follows in a Quick
            // Look preview.
            if let onOpenHarness {
                Menu {
                    Button("New Shell", action: openNewSession)
                    Button("Run MANVI Here", action: onOpenHarness)
                } label: {
                    Image(systemName: "plus")
                } primaryAction: {
                    openNewSession()
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("New terminal")
                .accessibilityLabel("New terminal")
            } else {
                Button(action: openNewSession) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help("New terminal")
                .accessibilityLabel("New terminal")
            }

            if let onMove {
                Button(action: onMove) {
                    Image(systemName: placement.moveSymbol)
                }
                .buttonStyle(.plain)
                .help(placement.moveHelp)
                .accessibilityLabel(placement.moveHelp)
            }

            if let current = sessions.current {
                Button { sessions.restart(current.id) } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Restart this shell")
                .accessibilityLabel("Restart this shell")
            }

            if let onClose {
                Button(action: onClose) {
                    Image(systemName: placement.hideSymbol)
                }
                .buttonStyle(.plain)
                .help("Hide the terminal")
                .accessibilityLabel("Hide the terminal")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, GlassTheme.Spacing.snug)
        .padding(.vertical, GlassTheme.Spacing.tight)
    }

    /// Every session, stacked, with only the selected one visible.
    ///
    /// Stacked rather than swapped: a `ForEach` that rendered only the current
    /// session would tear down every other host view, and tearing down a host
    /// kills its shell. Switching tabs must not end a running command.
    @ViewBuilder
    private var content: some View {
        ZStack {
            if sessions.isEmpty {
                // Closing the last tab leaves a black rectangle otherwise,
                // with the only way out being a `+` in the strip above it.
                VStack(spacing: GlassTheme.Spacing.tight) {
                    Text("No terminal open")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("New Terminal", action: openNewSession)
                        .controlSize(.small)
                }
            }

            ForEach(sessions.sessions) { session in
                TerminalHostView(
                    sessions: sessions,
                    id: session.id,
                    config: session.config,
                    generation: session.generation
                )
                .opacity(session.id == sessions.selection ? 1 : 0)
                // A hidden shell must not take clicks or keystrokes meant for
                // the visible one, nor be reachable by VoiceOver.
                .allowsHitTesting(session.id == sessions.selection)
                .accessibilityHidden(session.id != sessions.selection)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomTrailing) { exitBadge }
    }

    /// Shown when the selected shell has ended.
    ///
    /// Without it the drawer is a dead rectangle that swallows keystrokes,
    /// which reads as the terminal having broken rather than having exited.
    @ViewBuilder
    private var exitBadge: some View {
        if let current = sessions.current, let exit = current.exit {
            HStack(spacing: GlassTheme.Spacing.tight) {
                Text(exit.summary)
                    .foregroundStyle(exit.isClean ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                Button("Restart") { sessions.restart(current.id) }
                    .controlSize(.mini)
            }
            .font(.caption2)
            .padding(.horizontal, GlassTheme.Spacing.snug)
            .padding(.vertical, GlassTheme.Spacing.tight)
            .glassPanel(radius: GlassTheme.Radius.small, padding: EdgeInsets())
            .padding(GlassTheme.Spacing.snug)
        }
    }

    private func openNewSession() {
        do {
            try sessions.open(TerminalSession.resolve(document: document, vault: vault))
        } catch let failure as TerminalOpenFailure {
            onError?(failure.reason)
        } catch {
            onError?(error.localizedDescription)
        }
    }
}

/// One tab in the drawer's strip.
private struct TerminalTab: View {
    let session: TerminalSessionState
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: GlassTheme.Spacing.hairline) {
            // A dead shell has to look dead in the strip, or the reader picks
            // the wrong tab and types into nothing.
            if !session.isLive {
                Image(systemName: "circle.slash")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
            Text(session.title)
                .lineLimit(1)
                .truncationMode(.middle)
            if isHovering || isSelected {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close \(session.title)")
            }
        }
        .font(.caption)
        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
        .padding(.horizontal, GlassTheme.Spacing.tight)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: GlassTheme.Radius.small)
                .fill(isSelected ? Color.primary.opacity(0.12) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .help(session.config.workingDirectory)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// Shows the terminal a session already owns.
///
/// Deliberately almost empty. Everything that used to be here — forking the
/// shell, holding the delegate, ending the process on teardown — moved to
/// ``TerminalProcessHost`` so that the terminal could be drawn in the drawer
/// *or* in the inspector without moving it being a restart. What is left is
/// the one thing a representable is for: putting an existing `NSView` on
/// screen.
///
/// Note what is **not** here: no `dismantleNSView`. A dismantle now means "this
/// panel stopped drawing the terminal", which happens every time the reader
/// moves it, and ending the shell there is precisely the bug this split exists
/// to remove. Teardown is explicit — ``TerminalSessions/close(_:)``,
/// ``TerminalSessions/endAllHosts()``, and ``LiveShells/endAll()`` when the app
/// quits.
struct TerminalHostView: NSViewRepresentable {
    @Bindable var sessions: TerminalSessions
    let id: TerminalSessionState.ID
    let config: TerminalSession
    /// Changing this relaunches the shell in place.
    let generation: Int

    func makeNSView(context: Context) -> NSView {
        // A container rather than the terminal itself. `makeNSView` may run
        // while the previous panel still holds the same terminal view, and an
        // `NSView` has one superview: returning it directly would have SwiftUI
        // re-parent a view the outgoing hierarchy is still tearing down, which
        // is an ordering this code does not control. Owning a wrapper means
        // the move is a `addSubview` we perform ourselves, after both sides
        // have settled.
        let container = PassthroughView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        attach(to: container)
        sessions.host(for: id)?.relaunchIfNeeded(config, generation: generation)
    }

    private func attach(to container: NSView) {
        guard let terminal = sessions.host(for: id)?.view else { return }
        guard terminal.superview !== container else { return }
        terminal.removeFromSuperview()
        terminal.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: container.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    /// A container that never intercepts a click meant for the terminal.
    final class PassthroughView: NSView {
        override var acceptsFirstResponder: Bool { false }
    }
}
