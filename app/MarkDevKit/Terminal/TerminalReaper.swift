//
//  TerminalReaper.swift
//  MarkDevKit
//
//  Ending a shell, and everything it started.
//

import Darwin
import Foundation

/// Shuts a shell down for good.
///
/// # Why `terminate()` on its own is not enough
///
/// SwiftTerm's `terminate()` sends `SIGTERM` to the shell it forked and closes
/// the pty. That leaves two things behind.
///
/// The first is the shell's *children*. A terminal is opened to run things —
/// a dev server, a watcher, a long build — and those are separate processes.
/// Signalling only the shell leaves them running with their terminal gone,
/// reachable from nothing but Activity Monitor. `forkpty` makes the shell a
/// session and process-group leader, so its group is exactly "the shell and
/// everything it started": signalling the group reaches all of it.
///
/// The second is the zombie. `terminate()` cancels the monitor that would have
/// reaped the child, so the entry survives in the process table until the app
/// quits. One per terminal ever opened.
///
/// `SIGTERM` is a request, so a process that ignores it — or is wedged in an
/// uninterruptible state — gets `SIGKILL` after a grace period. Nothing here
/// blocks the caller: teardown runs during a view update, and a window must
/// not stall while a shell decides whether to die.
public enum TerminalReaper {
    /// How long a process is given to exit on `SIGTERM` before `SIGKILL`.
    public static let grace: TimeInterval = 2

    /// Ends the process group led by `pid`, then reaps it.
    ///
    /// - Parameter pid: the shell's own process id, which `forkpty` also makes
    ///   its process-group id.
    public static func end(processGroup pid: pid_t, grace: TimeInterval = grace) {
        // A pid of 0 addresses *our own* process group. Signalling that would
        // kill the app, and a stale or never-started session is exactly where
        // a zero comes from — so this guard is the difference between tidying
        // up and terminating MarkDev.
        guard pid > 0 else { return }

        signalGroup(pid, SIGTERM)

        // Polled, and abandoned the instant the child stops being ours.
        //
        // A pid is only safe to signal for as long as it is unreaped: a zombie
        // still owns its number, but the moment *anyone* reaps it the number
        // is free and the system may hand it to something else. SwiftTerm
        // reaps the same child from its own monitor, so a fixed delay before
        // escalating raced it — and the escalation could land on whatever
        // process inherited the pid. Seen as a shell in an unrelated test
        // reporting a clean exit it never made.
        DispatchQueue.global(qos: .utility).async {
            let deadline = Date().addingTimeInterval(grace)
            while Date() < deadline {
                switch collect(pid) {
                case .reaped, .notOurs:
                    // Either we cleared it or someone else did. In both cases
                    // the pid must not be signalled again.
                    return
                case .running:
                    Thread.sleep(forTimeInterval: 0.02)
                }
            }

            // Still ours, still alive, and out of patience.
            signalGroup(pid, SIGKILL)
            for _ in 0..<50 {
                if case .running = collect(pid) {
                    Thread.sleep(forTimeInterval: 0.02)
                } else {
                    return
                }
            }
        }
    }

    /// What one non-blocking `waitpid` found.
    private enum Collection {
        /// We reaped it; the pid is now free and must not be signalled.
        case reaped
        /// Someone else reaped it, or it was never ours. Same conclusion.
        case notOurs
        /// Still a live child of ours.
        case running
    }

    private static func collect(_ pid: pid_t) -> Collection {
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid { return .reaped }
        if result == -1 { return .notOurs }
        return .running
    }

    /// Signals a whole process group, falling back to the single process.
    ///
    /// `killpg` fails with `ESRCH` if the shell was not a group leader after
    /// all — different `fork` paths, a shell that called `setsid` — and in
    /// that case the leader alone is better than nothing.
    private static func signalGroup(_ pid: pid_t, _ signal: Int32) {
        if killpg(pid, signal) != 0 && errno == ESRCH {
            kill(pid, signal)
        }
    }

    /// Whether the process still exists, zombies included.
    ///
    /// Signal 0 performs the permission and existence checks without
    /// delivering anything, which is the documented way to ask.
    public static func isAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0
    }

    /// Clears the process-table entry, if the child is ours and has exited.
    ///
    /// Non-blocking: a child that has not exited yet is left alone rather than
    /// stalling the caller. Anything already reaped elsewhere returns `ECHILD`,
    /// which is a fine outcome and not an error worth reporting.
    @discardableResult
    public static func reap(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        var status: Int32 = 0
        return waitpid(pid, &status, WNOHANG) == pid
    }
}
