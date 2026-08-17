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
    public var onClose: (() -> Void)?
    /// Surfaced rather than swallowed: refusing to open the ninth terminal is
    /// a decision the reader has to be told about.
    public var onError: ((String) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        sessions: TerminalSessions,
        document: URL?,
        vault: URL?,
        onClose: (() -> Void)? = nil,
        onError: ((String) -> Void)? = nil
    ) {
        self.sessions = sessions
        self.document = document
        self.vault = vault
        self.onClose = onClose
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

            Button(action: openNewSession) {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .help("New terminal")
            .accessibilityLabel("New terminal")

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
                    Image(systemName: "chevron.down")
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
                    session: session.config,
                    generation: session.generation,
                    onTitleChange: { sessions.setTitle($0, for: session.id) },
                    onExit: { sessions.markExited($0, for: session.id) }
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

/// Hosts SwiftTerm's local-process terminal.
struct TerminalHostView: NSViewRepresentable {
    let session: TerminalSession
    /// Changing this tears the shell down and launches a new one.
    let generation: Int
    let onTitleChange: (String) -> Void
    let onExit: (TerminalExit) -> Void

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 220))
        view.processDelegate = context.coordinator
        context.coordinator.apply(theme: .standard, to: view)
        context.coordinator.launch(session, in: view)
        return view
    }

    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {
        context.coordinator.onTitleChange = onTitleChange
        context.coordinator.onExit = onExit

        // A running shell is never relocated. The reader may be halfway
        // through a command, and moving the working directory under it —
        // or worse, restarting it — because they clicked another tab would
        // destroy work. New directories reach the shell when it is restarted,
        // which is an explicit act, or by opening a second session.
        guard context.coordinator.generation != generation else { return }
        context.coordinator.generation = generation
        view.terminate()
        context.coordinator.launch(session, in: view)
    }

    /// Ends the shell when its view goes away.
    ///
    /// Without this the process outlives every trace of it: closing a tab or
    /// the window left a shell — and anything it was running — alive with no
    /// terminal attached and no way to reach it again. It survived until the
    /// app quit, and a `sleep 100000` or a dev server survived that.
    static func dismantleNSView(_ view: LocalProcessTerminalView, coordinator: Coordinator) {
        // The delegate first, so a callback from the dying pty cannot mark an
        // unrelated tab dead.
        coordinator.isDismantled = true
        view.processDelegate = nil

        // Captured before `terminate`, which clears the process state.
        let pid = view.process?.shellPid ?? 0
        view.terminate()
        // `terminate` signals only the shell and reaps nothing. Anything the
        // shell started — a dev server, a watcher — survives it, and the
        // shell itself lingers as a zombie. See ``TerminalReaper``.
        TerminalReaper.end(processGroup: pid)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            generation: generation, onTitleChange: onTitleChange, onExit: onExit)
    }

    @MainActor
    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        var generation: Int
        var onTitleChange: (String) -> Void
        var onExit: (TerminalExit) -> Void
        /// Set once the view is torn down, so a late callback from the dying
        /// pty cannot write into state that has moved on.
        var isDismantled = false

        init(
            generation: Int,
            onTitleChange: @escaping (String) -> Void,
            onExit: @escaping (TerminalExit) -> Void
        ) {
            self.generation = generation
            self.onTitleChange = onTitleChange
            self.onExit = onExit
        }

        func launch(_ session: TerminalSession, in view: LocalProcessTerminalView) {
            // Re-resolved at launch, not reused from when the session was
            // created: a vault can be renamed or a folder deleted between
            // opening a tab and restarting it, and launching into a directory
            // that is gone fails in a way the reader cannot act on.
            let live = session.revalidated()
            view.startProcess(
                executable: live.shell,
                args: [],
                environment: Terminal.getEnvironmentVariables(termName: "xterm-256color"),
                execName: live.argv0,
                currentDirectory: live.workingDirectory)
            onTitleChange((live.workingDirectory as NSString).lastPathComponent)
        }

        /// Matches the terminal to the editor's own palette.
        ///
        /// The drawer is content, not chrome, so it takes the editor theme's
        /// colours rather than glass — a shell rendered on a translucent
        /// surface is unreadable the moment anything scrolls behind it.
        func apply(theme: EditorTheme, to view: LocalProcessTerminalView) {
            view.font = theme.monoFont
            view.nativeForegroundColor = theme.textColor
            view.nativeBackgroundColor = theme.codeBackground
            view.installColors(SwiftTerm.Color.paleColors)
        }

        // MARK: LocalProcessTerminalViewDelegate

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
            guard !isDismantled, !title.isEmpty else { return }
            onTitleChange(title)
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            guard !isDismantled, let directory, !directory.isEmpty else { return }
            onTitleChange((directory as NSString).lastPathComponent)
        }

        /// - Parameter exitCode: named that way by SwiftTerm, but it is the
        ///   raw `waitpid` status. See ``TerminalExit``.
        func processTerminated(source: TerminalView, exitCode: Int32?) {
            guard !isDismantled else { return }
            onExit(TerminalExit(waitStatus: exitCode))
        }
    }
}
