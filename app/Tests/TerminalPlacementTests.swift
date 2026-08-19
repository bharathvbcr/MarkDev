//
//  TerminalPlacementTests.swift
//  MarkDevKitTests
//
//  Moving the terminal between the drawer and the sidebar, without restarting
//  what it is running.
//
//  The property under test is not cosmetic. Before ``TerminalProcessHost``, a
//  terminal's pty was created in `makeNSView` and killed in `dismantleNSView`,
//  so drawing it somewhere else was a *restart* — the build, the agent turn,
//  whatever was running, gone because a panel moved. These tests hold the new
//  ownership to that: the same view object, the same process, across a move.
//

import AppKit
import SwiftTerm
import XCTest

@testable import MarkDevKit

@MainActor
final class TerminalPlacementTests: XCTestCase {
    private func waitForDeath(of pid: pid_t, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !TerminalReaper.isAlive(pid) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return !TerminalReaper.isAlive(pid)
    }

    private func makeSessions() -> TerminalSessions { TerminalSessions() }

    private func homeSession(command: String? = nil) -> TerminalSession {
        TerminalSession.resolve(document: nil, vault: nil, initialCommand: command)
    }

    // MARK: - The placement value

    func testAPlacementHasAnOtherAndItIsNotItself() {
        XCTAssertEqual(TerminalPlacement.drawer.other, .inspector)
        XCTAssertEqual(TerminalPlacement.inspector.other, .drawer)
        for placement in TerminalPlacement.allCases {
            XCTAssertNotEqual(placement, placement.other)
            XCTAssertFalse(placement.moveHelp.isEmpty)
        }
    }

    // MARK: - Sessions own the process

    /// A session that nothing has drawn holds no process. This is what keeps
    /// the model tests — and every `TerminalSessions` in the suite — from
    /// forking shells.
    func testOpeningASessionDoesNotForkAnything() throws {
        let sessions = makeSessions()
        let id = try sessions.open(homeSession())
        XCTAssertFalse(sessions.hasHost(for: id), "the process is created when it is drawn")
    }

    func testAHostIsCreatedOnceAndReused() throws {
        let sessions = makeSessions()
        let id = try sessions.open(homeSession())
        let first = try XCTUnwrap(sessions.host(for: id))
        defer { sessions.closeAll() }

        XCTAssertTrue(sessions.hasHost(for: id))
        XCTAssertTrue(first === sessions.host(for: id), "asking twice must not fork twice")
        XCTAssertGreaterThan(first.processIdentifier, 0, "the shell should have started")
    }

    /// The lookup is by session, so a view left over from a closed tab cannot
    /// bring its shell back.
    func testAClosedSessionHasNoHostToAskFor() throws {
        let sessions = makeSessions()
        let id = try sessions.open(homeSession())
        _ = sessions.host(for: id)
        sessions.close(id)

        XCTAssertNil(sessions.host(for: id))
        XCTAssertFalse(sessions.hasHost(for: id))
    }

    /// Nothing in the view hierarchy ends a shell any more, so closing a tab
    /// has to — and the whole process group with it.
    func testClosingASessionEndsItsShell() throws {
        let sessions = makeSessions()
        let id = try sessions.open(homeSession())
        let host = try XCTUnwrap(sessions.host(for: id))
        let pid = host.processIdentifier
        XCTAssertGreaterThan(pid, 0)

        sessions.close(id)
        XCTAssertTrue(host.isEnded)
        XCTAssertTrue(waitForDeath(of: pid), "closing a tab must end its shell")
    }

    /// What a closing window calls. The sessions go with the window; the
    /// processes would not.
    func testEndingEveryHostKillsEveryShell() throws {
        let sessions = makeSessions()
        var pids: [pid_t] = []
        for _ in 0..<3 {
            let id = try sessions.open(homeSession())
            pids.append(try XCTUnwrap(sessions.host(for: id)).processIdentifier)
        }
        XCTAssertEqual(pids.filter { $0 > 0 }.count, 3)

        sessions.endAllHosts()
        for pid in pids {
            XCTAssertTrue(waitForDeath(of: pid), "shell \(pid) outlived the window")
        }
        // The sessions themselves are untouched: the window is going away with
        // them, and a list that emptied itself here would make the teardown
        // observable as a UI change on the way out.
        XCTAssertEqual(sessions.sessions.count, 3)
    }

    func testEndingAHostTwiceIsHarmless() throws {
        let sessions = makeSessions()
        let id = try sessions.open(homeSession())
        let host = try XCTUnwrap(sessions.host(for: id))
        host.end()
        host.end()
        XCTAssertTrue(host.isEnded)
    }

    // MARK: - Moving it

    /// The whole point. A shell drawn in the drawer and then in the inspector
    /// is one shell in two places, never two.
    func testMovingTheTerminalKeepsTheSameProcessAndTheSameView() throws {
        let sessions = makeSessions()
        let id = try sessions.open(homeSession())
        let host = try XCTUnwrap(sessions.host(for: id))
        defer { sessions.closeAll() }

        let pid = host.processIdentifier
        let terminal = host.view
        XCTAssertGreaterThan(pid, 0)

        // Two hosting containers, standing in for the drawer and the inspector.
        let drawer = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        let inspector = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
        drawer.addSubview(terminal)
        XCTAssertTrue(terminal.superview === drawer)

        inspector.addSubview(terminal)
        XCTAssertTrue(terminal.superview === inspector, "the view moved")
        XCTAssertTrue(sessions.host(for: id)?.view === terminal, "and it is the same view")
        XCTAssertEqual(host.processIdentifier, pid, "and the same shell")
        XCTAssertTrue(TerminalReaper.isAlive(pid), "which is still running")
    }

    /// A view update that arrives because the panel moved must not disturb a
    /// running command; one that arrives because the reader pressed Restart
    /// must.
    func testOnlyAGenerationChangeRelaunches() throws {
        let sessions = makeSessions()
        let id = try sessions.open(homeSession())
        let host = try XCTUnwrap(sessions.host(for: id))
        defer { sessions.closeAll() }

        let pid = host.processIdentifier
        let config = try XCTUnwrap(sessions.sessions.first).config

        host.relaunchIfNeeded(config, generation: 0)
        XCTAssertEqual(host.processIdentifier, pid, "the same generation must not relaunch")

        host.relaunchIfNeeded(config, generation: 1)
        XCTAssertNotEqual(host.processIdentifier, pid, "a restart is a new shell")
        XCTAssertTrue(waitForDeath(of: pid), "and the old one is not left behind")
    }

    /// A stale view update reaching a host whose tab has been closed must not
    /// bring the shell back.
    ///
    /// Asserted on the pid rather than on `processIdentifier == 0`: SwiftTerm's
    /// `terminate()` does *not* clear the process it forked, so an ended host
    /// goes on reporting the id of the shell it used to have. What matters is
    /// that no *new* one appears — the first version of this test asked for
    /// zero, and the number it got back was the dead shell's.
    func testAnEndedHostDoesNotRelaunch() throws {
        let sessions = makeSessions()
        let id = try sessions.open(homeSession())
        let host = try XCTUnwrap(sessions.host(for: id))
        let config = try XCTUnwrap(sessions.sessions.first).config
        let pid = host.processIdentifier
        host.end()
        XCTAssertTrue(waitForDeath(of: pid))

        host.relaunchIfNeeded(config, generation: 99)
        XCTAssertEqual(host.processIdentifier, pid, "a closed tab must not fork a shell")
        XCTAssertFalse(TerminalReaper.isAlive(pid), "and nothing is alive under that id")
    }

    // MARK: - The command a session starts with

    func testAnInitialCommandSurvivesRevalidation() {
        let session = homeSession(command: "manvi")
        XCTAssertEqual(session.revalidated().initialCommand, "manvi")
    }

    /// A shell opened to run an agent and a shell opened to type in are two
    /// different things in one folder. Folding them together would answer "run
    /// MANVI here" by selecting a plain prompt that is not running it.
    func testRevealDistinguishesSessionsByTheirCommand() throws {
        let sessions = makeSessions()
        let plain = try sessions.reveal(homeSession())
        let harness = try sessions.reveal(homeSession(command: "manvi"))
        XCTAssertNotEqual(plain, harness)
        XCTAssertEqual(sessions.sessions.count, 2)

        // And asking for the same one again still brings it forward rather than
        // forking a third.
        XCTAssertEqual(try sessions.reveal(homeSession(command: "manvi")), harness)
        XCTAssertEqual(sessions.sessions.count, 2)
    }
}

/// The process-wide backstop.
///
/// Window teardown covers a window; this covers Quit, which is how a Mac app
/// usually ends. Tested on the registry alone rather than by forking: what it
/// has to get right is bookkeeping — never signalling a pid it does not own,
/// and never signalling zero, which addresses the app's own process group.
final class LiveShellsTests: XCTestCase {
    func testAZeroPidIsNeverRecorded() {
        let before = LiveShells.shared.count
        LiveShells.shared.register(0)
        LiveShells.shared.register(-1)
        XCTAssertEqual(LiveShells.shared.count, before, "zero is our own process group")
    }

    /// A shell that ended on its own is forgotten rather than signalled: once
    /// anyone has reaped a pid the number is free, and the system may hand it
    /// to something else.
    func testForgettingAShellRemovesItWithoutSignallingIt() {
        let before = LiveShells.shared.count
        // A pid that is ours and long gone: this process's own id is alive, so
        // a plainly impossible one is used instead.
        let pid: pid_t = 999_999
        LiveShells.shared.register(pid)
        XCTAssertEqual(LiveShells.shared.count, before + 1)
        LiveShells.shared.forget(pid)
        XCTAssertEqual(LiveShells.shared.count, before)

        // Ending something it no longer knows about must do nothing at all.
        LiveShells.shared.end(pid)
        XCTAssertEqual(LiveShells.shared.count, before)
    }
}
