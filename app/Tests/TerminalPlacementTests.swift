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

    private func homeSession(startupAction: TerminalStartupAction? = nil) -> TerminalSession {
        TerminalSession.resolve(document: nil, vault: nil, startupAction: startupAction)
    }

    private func makeExecutable(named name: String, body: String = "exit 0") throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevTerminal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\n").write(
            to: executable,
            atomically: true,
            encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path)
        return executable
    }

    private func startupAction(for executable: URL) throws -> TerminalStartupAction {
        let location = try XCTUnwrap(
            HarnessLocator.locateSynchronously(
                configured: executable.path,
                environment: [:]))
        return .runExecutable(location)
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

    /// A representable from the outgoing placement can deliver one final
    /// update after Restart has already installed its successor. Its stale
    /// generation must be ignored, never interpreted as another restart.
    func testStaleGenerationUpdateCannotRollAHostBackward() throws {
        let sessions = makeSessions()
        let id = try sessions.open(homeSession())
        let host = try XCTUnwrap(sessions.host(for: id))
        defer { sessions.closeAll() }
        let config = try XCTUnwrap(sessions.sessions.first).config

        host.relaunchIfNeeded(config, generation: 1)
        let successorPID = host.processIdentifier
        let successorView = host.view
        XCTAssertGreaterThan(successorPID, 0)

        host.relaunchIfNeeded(config, generation: 0)

        XCTAssertEqual(host.generation, 1)
        XCTAssertEqual(host.processIdentifier, successorPID)
        XCTAssertTrue(host.view === successorView)
        XCTAssertTrue(TerminalReaper.isAlive(successorPID))
    }

    func testRestartRejectsMetadataCallbacksFromTheReplacedGeneration() throws {
        let sessions = makeSessions()
        let id = try sessions.open(homeSession())
        let host = try XCTUnwrap(sessions.host(for: id))
        defer { sessions.closeAll() }
        let oldView = host.view
        let config = try XCTUnwrap(sessions.sessions.first).config

        XCTAssertTrue(sessions.restart(id))
        host.relaunchIfNeeded(config, generation: 1)
        let replacement = host.view
        XCTAssertFalse(oldView === replacement)

        host.setTerminalTitle(source: oldView, title: "stale-title")
        host.hostCurrentDirectoryUpdate(source: oldView, directory: "/tmp/stale-cwd")
        XCTAssertNotEqual(sessions.current?.title, "stale-title")
        XCTAssertNotEqual(sessions.current?.title, "stale-cwd")

        host.setTerminalTitle(source: replacement, title: "current-title")
        XCTAssertEqual(sessions.current?.title, "current-title")
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

    // MARK: - The typed action a session starts with

    func testAStartupActionSurvivesRevalidation() throws {
        let executable = try makeExecutable(named: "manvi")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let action = try startupAction(for: executable)
        let session = homeSession(startupAction: action)

        XCTAssertEqual(try session.revalidated().startupAction, action)
    }

    func testStartupActionFailsClosedWhenItsWorkingDirectoryDisappears() throws {
        let executable = try makeExecutable(named: "manvi")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let action = try startupAction(for: executable)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkDev-Gone-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let session = TerminalSession.resolve(
            document: nil,
            vault: directory,
            startupAction: action)
        try FileManager.default.removeItem(at: directory)

        XCTAssertThrowsError(try session.revalidated()) { error in
            let failure = error as? TerminalLaunchFailure
            XCTAssertEqual(failure?.code, .workingDirectoryUnavailable)
            XCTAssertFalse(failure?.reason.contains(directory.path) ?? true)
        }
    }

    func testStartupActionNeverForgetsAnAlreadyMissingRequestedDirectory() throws {
        let executable = try makeExecutable(named: "manvi")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let action = try startupAction(for: executable)
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkDev-Never-There-\(UUID().uuidString)", isDirectory: true)

        let session = TerminalSession.resolve(
            document: nil,
            vault: missing,
            startupAction: action)

        XCTAssertEqual(session.workingDirectory, missing.standardizedFileURL.path)
        XCTAssertNotEqual(session.workingDirectory, NSHomeDirectory())
        XCTAssertThrowsError(try session.revalidated()) { error in
            XCTAssertEqual(
                (error as? TerminalLaunchFailure)?.code,
                .workingDirectoryUnavailable)
        }
    }

    func testStartupActionRefusesRemoteFileAuthorityBeforeLaunch() throws {
        let executable = try makeExecutable(named: "manvi")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let action = try startupAction(for: executable)
        let localDirectory = FileManager.default.temporaryDirectory
        let hostileDirectory = try XCTUnwrap(
            URL(string: "file://remote.example\(localDirectory.path)/"))

        let session = TerminalSession.resolve(
            document: nil,
            vault: hostileDirectory,
            startupAction: action)

        XCTAssertTrue(session.workingDirectory.isEmpty)
        XCTAssertThrowsError(try session.revalidated()) { error in
            XCTAssertEqual(
                (error as? TerminalLaunchFailure)?.code,
                .workingDirectoryUnavailable)
        }
    }

    func testHostNeverForksMANVIInHomeWhenRequestedDirectoryDisappears() throws {
        let executable = try makeExecutable(named: "manvi")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let action = try startupAction(for: executable)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkDev-Gone-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let session = TerminalSession.resolve(
            document: nil,
            vault: directory,
            startupAction: action)
        let sessions = makeSessions()
        let id = try sessions.open(session)
        try FileManager.default.removeItem(at: directory)

        let host = try XCTUnwrap(sessions.host(for: id))

        XCTAssertTrue(host.isEnded)
        XCTAssertEqual(host.processIdentifier, 0, "no fallback shell may be forked")
        XCTAssertEqual(
            sessions.sessions.first(where: { $0.id == id })?.launchFailure?.code,
            .workingDirectoryUnavailable)
    }

    /// A shell opened to run an agent and a shell opened to type in are two
    /// different things in one folder. Folding them together would answer "run
    /// MANVI here" by selecting a plain prompt that is not running it.
    func testRevealDistinguishesSessionsByTheirStartupAction() throws {
        let executable = try makeExecutable(named: "manvi")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let action = try startupAction(for: executable)
        let sessions = makeSessions()
        let plain = try sessions.reveal(homeSession())
        let harness = try sessions.reveal(homeSession(startupAction: action))
        XCTAssertNotEqual(plain, harness)
        XCTAssertEqual(sessions.sessions.count, 2)

        // And asking for the same one again still brings it forward rather than
        // forking a third.
        XCTAssertEqual(try sessions.reveal(homeSession(startupAction: action)), harness)
        XCTAssertEqual(sessions.sessions.count, 2)
    }

    func testStartupActionReplacesAnInheritedReservedEnvironmentValue() throws {
        let executable = try makeExecutable(named: "manvi")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let action = try startupAction(for: executable)
        let poisoned = [
            "\(TerminalStartupAction.executableEnvironmentKey)=/tmp/attacker",
            "\(TerminalStartupAction.executableEnvironmentKey)=/tmp/duplicate",
            "MARKDEV_UNRELATED=preserved",
        ]

        let environment = try action.launchEnvironment(base: poisoned)
        let reservedPrefix = TerminalStartupAction.executableEnvironmentKey + "="
        guard case .runExecutable(let location) = action else {
            return XCTFail("the fixture must resolve one typed executable action")
        }

        XCTAssertEqual(
            environment.filter { $0.hasPrefix(reservedPrefix) },
            [reservedPrefix + location.url.path],
            "launch must use the same physical path whose identity was revalidated")
        XCTAssertTrue(environment.contains("MARKDEV_UNRELATED=preserved"))
        XCTAssertEqual(
            action.shellSource,
            TerminalStartupAction.runExecutableShellSource)
        XCTAssertFalse(action.shellSource.contains(executable.path))
    }

    func testStartupActionExecutesHostileFilenamesAsOneShellWord() throws {
        let names = [
            "manvi $(touch injected-dollar)",
            "manvi `touch injected-backtick`",
            "manvi\"; touch injected-quote; echo \"",
            "manvi ' & | >",
            "manvi\nnewline",
            "manvi-λ-🧪",
        ]

        for (index, name) in names.enumerated() {
            let executable = try makeExecutable(
                named: name,
                body: "printf exact > \"$MARKDEV_TEST_MARKER\"")
            let directory = executable.deletingLastPathComponent()
            defer { try? FileManager.default.removeItem(at: directory) }
            let marker = directory.appendingPathComponent("executed-\(index)")
            let action = try startupAction(for: executable)
            let entries = try action.launchEnvironment(base: [
                "MARKDEV_TEST_MARKER=\(marker.path)",
                "PATH=/usr/bin:/bin",
            ])
            let environment = Dictionary(
                uniqueKeysWithValues: entries.compactMap { entry -> (String, String)? in
                    let parts = entry.split(
                        separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    guard parts.count == 2 else { return nil }
                    return (String(parts[0]), String(parts[1]))
                })

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-f", "-c", action.shellSource]
            process.environment = environment
            process.currentDirectoryURL = directory
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let terminated = expectation(description: "hostile executable \(index) terminated")
            process.terminationHandler = { _ in terminated.fulfill() }

            try process.run()
            wait(for: [terminated], timeout: 2)
            if process.isRunning {
                process.terminate()
                XCTFail("hostile executable \(index) did not terminate")
            }

            XCTAssertEqual(process.terminationReason, .exit, "fixture \(index)")
            XCTAssertEqual(process.terminationStatus, 0, "fixture \(index)")
            XCTAssertEqual(
                try String(contentsOf: marker, encoding: .utf8),
                "exact",
                "fixture \(index)")
            for injected in ["injected-dollar", "injected-backtick", "injected-quote"] {
                XCTAssertFalse(
                    FileManager.default.fileExists(
                        atPath: directory.appendingPathComponent(injected).path),
                    "shell syntax executed for fixture \(index)")
            }
        }
    }

    func testHostRefusesAnExecutableThatChangedAfterDiscovery() throws {
        let executable = try makeExecutable(named: "manvi", body: "exit 0")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let action = try startupAction(for: executable)
        try "#!/bin/sh\nexit 7\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path)
        let sessions = makeSessions()
        let id = try sessions.open(homeSession(startupAction: action))

        let host = try XCTUnwrap(sessions.host(for: id))

        XCTAssertTrue(host.isEnded)
        XCTAssertEqual(host.processIdentifier, 0)
        XCTAssertEqual(
            sessions.sessions.first(where: { $0.id == id })?.launchFailure?.reason,
            "The MANVI executable changed before the terminal could start.")
        XCTAssertFalse(sessions.sessions.first(where: { $0.id == id })?.isLive ?? true)
    }

    func testStartupActionRevokesTrustWhenAnAncestorBecomesWritable() throws {
        let executable = try makeExecutable(named: "manvi", body: "exit 0")
        let directory = executable.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let action = try startupAction(for: executable)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o777], ofItemAtPath: directory.path)

        XCTAssertThrowsError(try action.launchEnvironment(base: [])) { error in
            let failure = error as? TerminalLaunchFailure
            XCTAssertEqual(failure?.code, .executableTrustRevoked)
            XCTAssertFalse(failure?.reason.contains(executable.path) ?? true)
        }
    }

    func testHostReportsAPathFreeTrustCategoryForALaunchTimeSwap() throws {
        let executable = try makeExecutable(named: "manvi", body: "exit 0")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let action = try startupAction(for: executable)
        try "#!/bin/sh\nexit 7\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let sessions = makeSessions()
        let id = try sessions.open(homeSession(startupAction: action))

        _ = try XCTUnwrap(sessions.host(for: id))
        let failure = try XCTUnwrap(
            sessions.sessions.first(where: { $0.id == id })?.launchFailure)
        XCTAssertEqual(failure.code, .executableTrustRevoked)
        XCTAssertEqual(failure.code.rawValue, "executable-trust-revoked")
        XCTAssertFalse(failure.reason.contains(executable.path))
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
