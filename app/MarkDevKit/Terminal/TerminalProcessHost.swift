//
//  TerminalProcessHost.swift
//  MarkDevKit
//
//  The pty, and who owns it — which is no longer the view.
//

import AppKit
import Foundation
import SwiftTerm

/// One shell's terminal view, owned above SwiftUI.
///
/// # Why the view cannot own the pty any more
///
/// It used to: `TerminalHostView.makeNSView` forked the shell and
/// `dismantleNSView` ended it. That is correct while a terminal is drawn in
/// exactly one place, and it stops being correct the moment it can be drawn in
/// two — the drawer along the bottom, or the inspector down the right-hand
/// side. Moving it means SwiftUI tears the old representable down and builds a
/// new one, and with the pty owned by the view that is a *restart*: the build
/// that was running, the agent turn halfway through its tools, gone because
/// somebody moved a panel.
///
/// So the process moves up to where the sessions already live — the same
/// argument ``TerminalSessions`` makes for itself, one layer further in. The
/// representable becomes a window onto a view this object holds, and
/// re-parenting an `NSView` is what AppKit does when it is added somewhere
/// else: the pty never notices.
///
/// The consequence to keep in mind is that **nothing in the view hierarchy
/// ends a shell any more**. Teardown is explicit — ``end()``, called from
/// ``TerminalSessions/close(_:)`` and ``TerminalSessions/closeAll()`` — plus
/// the process-wide backstop in ``LiveShells``, because a window closing is
/// not a view being dismantled and app termination is not either.
@MainActor
public final class TerminalProcessHost: NSObject, LocalProcessTerminalViewDelegate {
    /// The session this host belongs to. Held so a late callback from a dying
    /// pty can be routed to the right tab, or dropped.
    public let id: UUID

    /// The view SwiftUI shows. Built once, re-parented as often as needed.
    public let view: LocalProcessTerminalView

    /// What was launched most recently, so a restart can be told from a move.
    private var generation: Int

    /// Set once ``end()`` has run, so nothing relaunches into a dead host and
    /// no callback from the dying pty is reported as this tab exiting.
    public private(set) var isEnded = false

    /// Reported when the shell sets a title or its directory changes.
    var onTitleChange: (String) -> Void
    /// Reported once, when the shell ends on its own.
    var onExit: (TerminalExit) -> Void

    init(
        id: UUID,
        session: TerminalSession,
        generation: Int,
        onTitleChange: @escaping (String) -> Void,
        onExit: @escaping (TerminalExit) -> Void
    ) {
        self.id = id
        self.generation = generation
        self.onTitleChange = onTitleChange
        self.onExit = onExit
        view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 220))
        super.init()
        view.processDelegate = self
        apply(theme: .standard)
        launch(session)
    }

    /// The shell's pid, or zero once it has ended.
    public var processIdentifier: pid_t { view.process?.shellPid ?? 0 }

    /// Relaunches when `generation` has moved, and does nothing when it has
    /// not.
    ///
    /// The distinction is the whole point of the generation counter: a view
    /// update that arrives because the panel moved, resized, or changed
    /// appearance must not disturb a running command, while a deliberate
    /// restart must.
    func relaunchIfNeeded(_ session: TerminalSession, generation: Int) {
        guard !isEnded, self.generation != generation else { return }
        self.generation = generation
        let previous = processIdentifier
        view.terminate()
        // The old shell's children are not the new shell's. Reaped through the
        // same path a close goes through, or a restart leaks everything the
        // previous shell started.
        LiveShells.shared.end(previous)
        launch(session)
    }

    /// Ends the shell, everything it started, and this host's claim on it.
    ///
    /// Safe to call more than once: the second call finds no pid and does
    /// nothing, which matters because a close and a window teardown can both
    /// reach the same session.
    public func end() {
        guard !isEnded else { return }
        isEnded = true
        let pid = processIdentifier
        view.processDelegate = nil
        view.terminate()
        LiveShells.shared.end(pid)
    }

    private func launch(_ session: TerminalSession) {
        // Re-resolved at launch, not reused from when the tab was opened: a
        // vault can be renamed or a folder deleted in between, and launching
        // into a directory that is gone fails inside the shell where the
        // reader can neither see the cause nor act on it.
        let live = session.revalidated()
        view.startProcess(
            executable: live.shell,
            args: [],
            environment: Terminal.getEnvironmentVariables(termName: "xterm-256color"),
            execName: live.argv0,
            currentDirectory: live.workingDirectory)
        LiveShells.shared.register(processIdentifier)
        onTitleChange((live.workingDirectory as NSString).lastPathComponent)

        // Typed into the shell rather than passed as `-c`, so the session stays
        // an interactive login shell — which is what puts Homebrew, mise and
        // nvm on `PATH`, and therefore what makes a coding CLI resolvable at
        // all. It also leaves the command visible in the scrollback, so the
        // reader can see what was run and re-run it.
        if let command = live.initialCommand {
            view.send(txt: command + "\n")
        }
    }

    /// Matches the terminal to the editor's own palette.
    ///
    /// The terminal is content, not chrome, so it takes the editor theme's
    /// colours rather than glass — a shell rendered on a translucent surface
    /// is unreadable the moment anything scrolls behind it.
    func apply(theme: EditorTheme) {
        view.font = theme.monoFont
        view.nativeForegroundColor = theme.textColor
        view.nativeBackgroundColor = theme.codeBackground
        view.installColors(SwiftTerm.Color.paleColors)
    }

    // MARK: LocalProcessTerminalViewDelegate

    public func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    public func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        guard !isEnded, !title.isEmpty else { return }
        onTitleChange(title)
    }

    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard !isEnded, let directory, !directory.isEmpty else { return }
        onTitleChange((directory as NSString).lastPathComponent)
    }

    /// - Parameter exitCode: named that way by SwiftTerm, but it is the raw
    ///   `waitpid` status. See ``TerminalExit``.
    public func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard !isEnded else { return }
        LiveShells.shared.forget(processIdentifier)
        onExit(TerminalExit(waitStatus: exitCode))
    }
}

/// Every shell this process has forked and not yet ended.
///
/// # Why a registry at all
///
/// With the pty owned by a view, teardown rode on `dismantleNSView`, which
/// SwiftUI calls when a window goes away. Owning it above the view buys the
/// ability to move a terminal, and costs that hook — so the guarantee has to
/// be restated somewhere that a window closing and the app quitting both
/// reach.
///
/// This is that place, and it is deliberately the smallest thing that can be:
/// a set of process-group ids behind a lock. It holds no views and no session
/// state, so it can be swept from ``NSApplication`` teardown without touching
/// anything that must be on the main actor first. What it protects against is
/// the failure that has already been paid for once here — a `sleep 100000`, a
/// dev server holding a port, a watcher, left running with no terminal
/// attached and nothing but Activity Monitor to find it with.
public final class LiveShells: @unchecked Sendable {
    public static let shared = LiveShells()

    private let lock = NSLock()
    private var pids: Set<pid_t> = []

    private init() {}

    /// Records a freshly forked shell. A zero is ignored: it means the fork
    /// never happened, and zero addresses *our own* process group.
    public func register(_ pid: pid_t) {
        guard pid > 0 else { return }
        lock.lock()
        pids.insert(pid)
        lock.unlock()
    }

    /// Drops a pid without signalling it — for a shell that ended on its own.
    public func forget(_ pid: pid_t) {
        guard pid > 0 else { return }
        lock.lock()
        pids.remove(pid)
        lock.unlock()
    }

    /// Ends one shell's process group and forgets it.
    public func end(_ pid: pid_t) {
        guard pid > 0 else { return }
        lock.lock()
        let known = pids.remove(pid) != nil
        lock.unlock()
        guard known else { return }
        TerminalReaper.end(processGroup: pid)
    }

    /// Ends everything still running. Called when the app is quitting.
    public func endAll() {
        lock.lock()
        let remaining = pids
        pids.removeAll()
        lock.unlock()
        for pid in remaining { TerminalReaper.end(processGroup: pid) }
    }

    /// How many shells are still recorded. For tests and diagnostics.
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return pids.count
    }
}
