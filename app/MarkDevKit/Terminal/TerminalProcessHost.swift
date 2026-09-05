//
//  TerminalProcessHost.swift
//  MarkDevKit
//
//  The pty, and who owns it — which is no longer the view.
//

import AppKit
import Darwin
import Foundation
import SwiftTerm

/// Recovers the real child status when SwiftTerm's non-blocking wait ran too
/// early after its process-exit notification.
///
/// SwiftTerm 1.20.0 initializes the status to zero, calls `waitpid` with
/// `WNOHANG`, and forwards the status without checking the return value. A
/// child that is not waitable in that instant therefore looks like a clean
/// exit. Nonzero statuses are already authoritative; zero is collected again
/// for a short, bounded interval on a background task.
enum TerminalExitStatusResolver {
    enum WaitObservation: Equatable {
        case exited(Int32)
        case stillRunning
        case interrupted
        case alreadyCollected
        case failed
    }

    private static let maximumPolls = 250
    private static let pollDelay: useconds_t = 1_000

    static func resolve(pid: pid_t, reportedStatus: Int32?) -> Int32? {
        guard reportedStatus == 0 else { return reportedStatus }
        guard pid > 0 else { return nil }
        return resolve(
            reportedStatus: reportedStatus,
            maxPolls: maximumPolls,
            poll: {
                var status: Int32 = 0
                let result = waitpid(pid, &status, WNOHANG)
                if result == pid { return .exited(status) }
                if result == 0 { return .stillRunning }
                if errno == EINTR { return .interrupted }
                if errno == ECHILD { return .alreadyCollected }
                return .failed
            },
            pause: { usleep(pollDelay) })
    }

    /// Pure polling policy, injectable so the early-`WNOHANG` race and its
    /// timeout can be exercised deterministically without forking a child.
    static func resolve(
        reportedStatus: Int32?,
        maxPolls: Int,
        poll: () -> WaitObservation,
        pause: () -> Void
    ) -> Int32? {
        guard reportedStatus == 0 else { return reportedStatus }
        guard maxPolls > 0 else { return nil }

        for attempt in 0..<maxPolls {
            switch poll() {
            case .exited(let status):
                return status
            case .alreadyCollected:
                // SwiftTerm won the waitpid race and the value it supplied is
                // the only status still available.
                return reportedStatus
            case .failed:
                return nil
            case .interrupted:
                continue
            case .stillRunning:
                if attempt + 1 < maxPolls { pause() }
            }
        }
        // A process-exit event that never became collectable is contradictory.
        // Report unknown instead of turning that uncertainty into success.
        return nil
    }
}

/// The one SwiftTerm view MarkDev uses for child processes.
///
/// Recovery happens before SwiftTerm forwards the callback to its public
/// process delegate, keeping every app consumer on the same reliable seam.
@MainActor
final class MarkDevTerminalView: LocalProcessTerminalView {
    /// The process whose callback is being forwarded to the public delegate.
    /// The delegate otherwise receives only this reusable view, which is not
    /// enough to distinguish a late exit from the generation Restart replaced.
    fileprivate private(set) var forwardingTerminationPID: pid_t?

    override func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        let pid = source.shellPid
        guard exitCode == 0 else {
            forwardTermination(source, exitCode: exitCode)
            return
        }
        guard pid > 0 else {
            forwardTermination(source, exitCode: nil)
            return
        }

        Task { @MainActor [weak self, weak source] in
            let resolved = await Task.detached(priority: .utility) {
                TerminalExitStatusResolver.resolve(pid: pid, reportedStatus: exitCode)
            }.value
            guard let self, let source,
                self.process === source,
                source.shellPid == pid
            else { return }
            forwardTermination(source, exitCode: resolved)
        }
    }

    private func forwardTermination(_ source: LocalProcess, exitCode: Int32?) {
        forwardingTerminationPID = source.shellPid
        defer { forwardingTerminationPID = nil }
        super.processTerminated(source, exitCode: exitCode)
    }
}

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
///
/// SwiftTerm creates this view's `LocalProcess` on its default main dispatch
/// queue, so its UI delegate callbacks belong on the main actor as well. The
/// isolated conformance states that guarantee to Swift rather than allowing a
/// nonisolated protocol witness to reach actor-owned session state.
@MainActor
public final class TerminalProcessHost: NSObject, @MainActor LocalProcessTerminalViewDelegate {
    /// The session this host belongs to. Held so a late callback from a dying
    /// pty can be routed to the right tab, or dropped.
    public let id: UUID

    /// The view SwiftUI shows. Built once, re-parented as often as needed.
    public private(set) var view: LocalProcessTerminalView

    /// What was launched most recently, so a restart can be told from a move.
    public private(set) var generation: Int

    /// The pid paired with ``generation`` at launch. Looking through the view
    /// during an exit callback is too late: Restart may already have installed
    /// its successor in the same reusable view.
    private var launchedProcessIdentifier: pid_t = 0

    /// Set once ``end()`` has run, so nothing relaunches into a dead host and
    /// no callback from the dying pty is reported as this tab exiting.
    public private(set) var isEnded = false

    /// Reported when the shell sets a title or its directory changes.
    var onTitleChange: (String, Int) -> Void
    /// Reported once, when the shell ends on its own.
    var onExit: (TerminalExit, Int) -> Void
    /// Reported when a typed startup action loses its executable authority
    /// before the shell is forked. No path or shell source crosses this seam.
    var onLaunchFailure: (TerminalLaunchFailure, Int) -> Void

    init(
        id: UUID,
        session: TerminalSession,
        generation: Int,
        onTitleChange: @escaping (String, Int) -> Void,
        onExit: @escaping (TerminalExit, Int) -> Void,
        onLaunchFailure: @escaping (TerminalLaunchFailure, Int) -> Void
    ) {
        self.id = id
        self.generation = generation
        self.onTitleChange = onTitleChange
        self.onExit = onExit
        self.onLaunchFailure = onLaunchFailure
        view = MarkDevTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 220))
        super.init()
        view.processDelegate = self
        apply(theme: .standard)
        launch(session)
    }

    /// The shell's pid, or zero before a process was successfully forked.
    /// SwiftTerm may retain the numeric id after the child has ended.
    public var processIdentifier: pid_t { view.process?.shellPid ?? 0 }

    /// Relaunches only when `generation` has moved forward.
    ///
    /// The distinction is the whole point of the generation counter: a view
    /// update that arrives because the panel moved, resized, or changed
    /// appearance must not disturb a running command, while a deliberate
    /// restart must.
    func relaunchIfNeeded(_ session: TerminalSession, generation: Int) {
        // An outgoing representable may deliver one final update after its
        // replacement has already installed the successor. Accepting any
        // unequal value would interpret that stale lower generation as a new
        // restart, kill the successor, and roll identity backward.
        guard !isEnded, generation > self.generation else { return }
        let previous = launchedProcessIdentifier
        let replacedView = view
        // Each process generation owns a distinct parser/view. SwiftTerm's
        // metadata callbacks identify only that view, not the LocalProcess
        // that produced the bytes; reusing it would let buffered title/CWD
        // output from the old process masquerade as the new generation.
        replacedView.processDelegate = nil
        replacedView.terminate()
        replacedView.removeFromSuperview()
        // The old shell's children are not the new shell's. Reaped through the
        // same path a close goes through, or a restart leaks everything the
        // previous shell started.
        LiveShells.shared.end(previous)
        self.generation = generation
        let replacement = MarkDevTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 220))
        replacement.processDelegate = self
        view = replacement
        apply(theme: .standard)
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
        let pid = launchedProcessIdentifier
        view.processDelegate = nil
        view.terminate()
        LiveShells.shared.end(pid)
    }

    private func launch(_ session: TerminalSession) {
        // Re-resolved at launch, not reused from when the tab was opened: a
        // vault can be renamed or a folder deleted in between, and launching
        // into a directory that is gone fails inside the shell where the
        // reader can neither see the cause nor act on it.
        let live: TerminalSession
        var environment = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        do {
            live = try session.revalidated()
            if let action = live.startupAction {
                environment = try action.launchEnvironment(base: environment)
            }
        } catch let failure as TerminalLaunchFailure {
            isEnded = true
            onLaunchFailure(failure, generation)
            return
        } catch {
            isEnded = true
            onLaunchFailure(
                TerminalLaunchFailure(
                    reason: "The requested terminal action could not be validated."),
                generation)
            return
        }
        view.startProcess(
            executable: live.shell,
            args: [],
            environment: environment,
            execName: live.argv0,
            currentDirectory: live.workingDirectory)
        launchedProcessIdentifier = processIdentifier
        LiveShells.shared.register(launchedProcessIdentifier)
        onTitleChange((live.workingDirectory as NSString).lastPathComponent, generation)

        // The fixed source expands one quoted environment value. Shell syntax
        // in a pathname is therefore never parsed, while the session remains
        // an interactive login shell and survives after the executable exits.
        if let action = live.startupAction {
            do {
                try action.validateImmediatelyBeforeSend()
                view.send(txt: action.shellSource + "\n")
            } catch let failure as TerminalLaunchFailure {
                refuseLaunchedShell(failure)
            } catch {
                refuseLaunchedShell(
                    TerminalLaunchFailure(
                        reason: "The requested terminal action could not be validated."))
            }
        }
    }

    private func refuseLaunchedShell(_ failure: TerminalLaunchFailure) {
        let pid = launchedProcessIdentifier
        isEnded = true
        view.processDelegate = nil
        view.terminate()
        LiveShells.shared.end(pid)
        onLaunchFailure(failure, generation)
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
        guard !isEnded, source === view, !title.isEmpty else { return }
        onTitleChange(title, generation)
    }

    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard !isEnded, source === view, let directory, !directory.isEmpty else { return }
        onTitleChange((directory as NSString).lastPathComponent, generation)
    }

    /// - Parameter exitCode: named that way by SwiftTerm, but it is the raw
    ///   `waitpid` status. See ``TerminalExit``.
    public func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard !isEnded, source === view else { return }
        let reportedPID = (source as? MarkDevTerminalView)?.forwardingTerminationPID
        guard reportedPID == launchedProcessIdentifier else {
            // A replaced generation ended after its successor launched. Drop
            // the stale callback, but retire that exact old pid if the reaper
            // did not already do so.
            if let reportedPID { LiveShells.shared.forget(reportedPID) }
            return
        }
        LiveShells.shared.forget(launchedProcessIdentifier)
        onExit(TerminalExit(waitStatus: exitCode), generation)
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
