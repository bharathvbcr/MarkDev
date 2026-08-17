//
//  TerminalStressTests.swift
//  MarkDevKitTests
//
//  Real ptys, many of them, and paths chosen to be awkward.
//
//  The unit tests prove one shell behaves. These push on what a terminal
//  actually gets used for: dozens of sessions over a working day, commands
//  that emit floods of output, a folder deleted while its tab is open, a
//  restart hammered because something hung.
//

import AppKit
import SwiftTerm
import XCTest

@testable import MarkDevKit

@MainActor
final class TerminalProcessStressTests: XCTestCase {
    /// Collects a launched process's termination.
    private final class Recorder: NSObject, LocalProcessTerminalViewDelegate {
        var status: Int32??
        var onExit: (() -> Void)?
        var titles: [String] = []

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
            titles.append(title)
        }
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) {
            status = exitCode
            onExit?()
        }
    }

    private func makeView() -> LocalProcessTerminalView {
        LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    }

    /// Runs one command to completion and returns how it ended.
    private func run(
        _ script: String,
        in directory: String? = nil,
        timeout: TimeInterval = 20
    ) -> TerminalExit {
        let view = makeView()
        let recorder = Recorder()
        view.processDelegate = recorder

        let finished = expectation(description: "exit: \(script)")
        recorder.onExit = { finished.fulfill() }

        view.startProcess(
            executable: "/bin/sh", args: ["-c", script], currentDirectory: directory)
        wait(for: [finished], timeout: timeout)
        return TerminalExit(waitStatus: recorder.status ?? nil)
    }

    // MARK: - Volume

    func testManySequentialShellsAllReportTheirOwnExitCode() {
        // A working day of opening and closing terminals, compressed. A leaked
        // pty or a delegate wired to the wrong session shows up here as a
        // mismatched code rather than as a mysterious hang much later.
        for code in stride(from: 0, through: 60, by: 3) {
            XCTAssertEqual(
                run("exit \(code)"), .code(Int32(code)),
                "shell exiting \(code) reported the wrong status")
        }
    }

    func testConcurrentShellsDoNotCrossTheirResults() {
        // Every session has its own delegate; if any of that were shared, the
        // codes would come back attached to the wrong view.
        let count = 8
        var views: [LocalProcessTerminalView] = []
        var recorders: [Recorder] = []
        var expectations: [XCTestExpectation] = []

        for index in 0..<count {
            let view = makeView()
            let recorder = Recorder()
            let finished = expectation(description: "exit \(index)")
            recorder.onExit = { finished.fulfill() }
            view.processDelegate = recorder

            views.append(view)
            recorders.append(recorder)
            expectations.append(finished)
        }

        // Started only once all are wired, so they genuinely overlap.
        for (index, view) in views.enumerated() {
            view.startProcess(executable: "/bin/sh", args: ["-c", "exit \(index + 1)"])
        }
        wait(for: expectations, timeout: 30)

        for (index, recorder) in recorders.enumerated() {
            XCTAssertEqual(
                TerminalExit(waitStatus: recorder.status ?? nil), .code(Int32(index + 1)),
                "session \(index) got another session's exit code")
        }
    }

    func testAFloodOfOutputDoesNotStallTheShell() {
        // A build log or a `find /` is tens of thousands of lines. If the read
        // side ever blocked, this would time out rather than fail.
        XCTAssertEqual(
            run("for i in $(seq 1 20000); do echo \"line $i of output padding\"; done; exit 0"),
            .code(0))
    }

    func testAShellEmittingControlSequencesStillExitsCleanly() {
        // Colour, cursor moves, a bell, and an alternate-screen switch: the
        // things a TUI does. A parser that trips on one of these hangs the
        // drawer rather than failing visibly.
        let script = """
            printf '\\033[31mred\\033[0m\\n'
            printf '\\033[2J\\033[H'
            printf '\\007'
            printf '\\033[?1049h'; printf 'alt screen'; printf '\\033[?1049l'
            printf '\\033]0;a title\\007'
            exit 0
            """
        XCTAssertEqual(run(script), .code(0))
    }

    func testInvalidUTF8InOutputDoesNotKillTheSession() {
        // A stray binary byte from `cat`-ing the wrong file must not take the
        // terminal down with it.
        XCTAssertEqual(run("printf '\\377\\376 still here\\n'; exit 0"), .code(0))
    }

    // MARK: - Signals and failure

    func testSignalledShellsAreReportedAsSignalled() {
        for signal in [SIGTERM, SIGINT, SIGKILL, SIGQUIT] {
            XCTAssertEqual(
                run("kill -\(signal) $$"), .signal(signal),
                "signal \(signal) should not read as an exit status")
        }
    }

    func testAMissingExecutableTerminatesRatherThanHanging() {
        // A resolver bug that hands over a path that is not there must surface
        // as a dead session, not as a terminal that never prompts.
        //
        // Only *that* is asserted. The reported status is not trustworthy for
        // this path: SwiftTerm's `processTerminated` declares `var n: Int32 = 0`
        // and passes it on after a `waitpid(..., WNOHANG)` whose result it does
        // not check, so when the child has already gone the status stays zero
        // and a failed launch reports a clean exit. Asserting a non-zero code
        // here failed roughly one run in three. See the note in CLAUDE.md.
        let view = makeView()
        let recorder = Recorder()
        view.processDelegate = recorder
        let finished = expectation(description: "exit")
        recorder.onExit = { finished.fulfill() }

        view.startProcess(executable: "/nonexistent/shell", args: [])
        wait(for: [finished], timeout: 20)
        XCTAssertNotNil(recorder.status, "termination must be reported at all")
    }

    func testLaunchingIntoADeletedDirectoryStillProducesAWorkingShell() throws {
        // The tab outlives the folder: a vault renamed, a worktree removed.
        // `revalidated` is what turns that into starting at home.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevGone-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let session = TerminalSession.resolve(document: nil, vault: directory)
        XCTAssertEqual(session.workingDirectory, directory.standardizedFileURL.path)

        try FileManager.default.removeItem(at: directory)
        let live = session.revalidated()
        XCTAssertEqual(live.workingDirectory, NSHomeDirectory(), "a gone folder falls back")
        XCTAssertEqual(run("exit 0", in: live.workingDirectory), .code(0))
    }

    // MARK: - Teardown

    func testTerminatingWithoutStartingIsHarmless() {
        // The drawer dismantles every host it built, including one whose
        // process never launched.
        let view = makeView()
        view.terminate()
        view.terminate()
    }

    func testTerminatingTwiceAfterExitIsHarmless() {
        let view = makeView()
        let recorder = Recorder()
        view.processDelegate = recorder
        let finished = expectation(description: "exit")
        recorder.onExit = { finished.fulfill() }

        view.startProcess(executable: "/bin/sh", args: ["-c", "exit 0"])
        wait(for: [finished], timeout: 20)

        view.terminate()
        view.terminate()
    }

    func testALongRunningShellIsActuallyKilledOnTeardown() {
        // The gap this closes: without teardown the process outlived its view,
        // its tab, and the window, surviving until the app quit.
        //
        // Asserted on the process, not on a delegate callback: SwiftTerm's
        // `terminate` cancels the monitor that would report the exit, so
        // waiting for one times out even though the shell died. That is what
        // the first version of this test got wrong.
        let view = makeView()
        view.startProcess(executable: "/bin/sh", args: ["-c", "sleep 600"])
        let pid = view.process.shellPid
        XCTAssertGreaterThan(pid, 0, "the shell should have started")

        view.terminate()
        TerminalReaper.end(processGroup: pid, grace: 0.2)

        XCTAssertTrue(waitForDeath(of: pid), "the shell outlived its terminal")
    }

    func testEverythingTheShellStartedDiesWithIt() throws {
        // The reason the whole process group is signalled rather than the
        // shell alone. A terminal is opened to run things; a `npm run dev`
        // left alive with its terminal gone is unreachable except through
        // Activity Monitor, and still holding its port.
        // Unique per run: a fixed name reads back a pid from a *previous*
        // run, whose process is long dead, and the test fails claiming the
        // child never started.
        let pidFile = root.appendingPathComponent("child-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let view = makeView()
        view.startProcess(
            executable: "/bin/sh",
            args: ["-c", "sleep 600 & echo $! > \(pidFile.path); wait"])

        let shell = view.process.shellPid
        XCTAssertGreaterThan(shell, 0)

        // The background child writes its pid; give it a moment to appear.
        var child: pid_t = 0
        for _ in 0..<100 where child == 0 {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8),
                let value = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                child = value
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        try XCTSkipIf(child == 0, "the background child never reported its pid")
        XCTAssertTrue(TerminalReaper.isAlive(child), "the child should be running")

        view.terminate()
        TerminalReaper.end(processGroup: shell, grace: 0.2)

        XCTAssertTrue(waitForDeath(of: shell), "the shell outlived its terminal")
        XCTAssertTrue(waitForDeath(of: child), "the shell's child outlived the terminal")
    }

    func testRapidRestartCyclesLeaveNoOrphansBehind() {
        // Someone leaning on the restart button because something hung. Each
        // cycle must end the previous process, or the drawer quietly
        // accumulates shells behind the one terminal that is visible.
        let view = makeView()
        var previous: [pid_t] = []

        for _ in 0..<15 {
            if view.process?.shellPid ?? 0 > 0 {
                let pid = view.process.shellPid
                view.terminate()
                TerminalReaper.end(processGroup: pid, grace: 0.2)
                previous.append(pid)
            }
            view.startProcess(executable: "/bin/sh", args: ["-c", "sleep 300"])
        }

        let last = view.process.shellPid
        for pid in previous {
            XCTAssertTrue(waitForDeath(of: pid), "restart left \(pid) running")
        }
        XCTAssertTrue(TerminalReaper.isAlive(last), "the newest shell should still be running")

        view.terminate()
        TerminalReaper.end(processGroup: last, grace: 0.2)
        XCTAssertTrue(waitForDeath(of: last))
    }

    func testReapingRefusesToSignalOurOwnProcessGroup() {
        // A pid of 0 addresses the *caller's* group. A stale or never-started
        // session is exactly where a zero comes from, so this guard is the
        // difference between tidying up and terminating MarkDev.
        TerminalReaper.end(processGroup: 0)
        TerminalReaper.end(processGroup: -1)
        XCTAssertFalse(TerminalReaper.isAlive(0))
        XCTAssertFalse(TerminalReaper.isAlive(-1))
        // Still here, which is the assertion.
        XCTAssertTrue(TerminalReaper.isAlive(getpid()))
    }

    func testReapingAShellThatAlreadyExitedIsHarmless() {
        let view = makeView()
        let recorder = Recorder()
        view.processDelegate = recorder
        let finished = expectation(description: "exit")
        recorder.onExit = { finished.fulfill() }

        view.startProcess(executable: "/bin/sh", args: ["-c", "exit 0"])
        let pid = view.process.shellPid
        wait(for: [finished], timeout: 20)

        TerminalReaper.end(processGroup: pid, grace: 0.1)
        TerminalReaper.end(processGroup: pid, grace: 0.1)
        XCTAssertTrue(waitForDeath(of: pid))
    }

    /// Spins the run loop until `pid` is gone, or gives up.
    ///
    /// Polled rather than awaited: the process is signalled asynchronously and
    /// reaped on a background queue, so there is no callback to hang a single
    /// expectation on.
    private func waitForDeath(of pid: pid_t, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !TerminalReaper.isAlive(pid) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return !TerminalReaper.isAlive(pid)
    }

    private var root: URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevReaper")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

@MainActor
final class TerminalPathStressTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevPaths-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func directory(named name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Awkward names

    func testAwkwardDirectoryNamesResolveToThemselves() throws {
        // Every one of these has broken a shell integration somewhere: spaces,
        // quotes, a leading dash that looks like a flag, non-ASCII, an emoji,
        // and a name that is only punctuation.
        let names = [
            "with spaces",
            "with'single'quotes",
            "with\"double\"quotes",
            "-leading-dash",
            "ünïcödé-náme",
            "emoji-🚀-folder",
            "dots...and...more",
            "a(b)c[d]e{f}",
            "tab\tseparated",
            "semi;colon&ampersand",
            "$dollar`backtick",
        ]

        for name in names {
            let url = try directory(named: name)
            let resolved = TerminalSession.resolveWorkingDirectory(document: nil, vault: url)
            XCTAssertEqual(
                resolved, url.standardizedFileURL.path,
                "\(name) should resolve to itself, not to a fallback")
            XCTAssertTrue(TerminalSession.isUsableDirectory(resolved))
        }
    }

    func testAVeryDeepPathStillResolves() throws {
        var url = root!
        for depth in 0..<60 {
            url = url.appendingPathComponent("level\(depth)")
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        XCTAssertEqual(
            TerminalSession.resolveWorkingDirectory(document: nil, vault: url),
            url.standardizedFileURL.path)
    }

    func testARelativeComponentCannotEscapeIntoNonsense() throws {
        // `..` in a stored vault path is standardised away rather than passed
        // to the shell, which would resolve it against a different cwd.
        let inner = try directory(named: "inner")
        let dodgy = inner.appendingPathComponent("../inner")

        XCTAssertEqual(
            TerminalSession.resolveWorkingDirectory(document: nil, vault: dodgy),
            inner.standardizedFileURL.path)
    }

    // MARK: - Things that are not usable directories

    func testUnusableCandidatesAlwaysFallBackToSomethingReal() throws {
        let file = root.appendingPathComponent("a-file.md")
        try "x".write(to: file, atomically: true, encoding: .utf8)

        let unreadable = try directory(named: "no-entry")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: unreadable.path)
        }

        let candidates: [URL?] = [
            nil,
            root.appendingPathComponent("does-not-exist"),
            file,
            unreadable,
            URL(fileURLWithPath: "/dev/null"),
        ]

        for candidate in candidates {
            let resolved = TerminalSession.resolveWorkingDirectory(
                document: nil, vault: candidate)
            XCTAssertTrue(
                TerminalSession.isUsableDirectory(resolved),
                "\(candidate?.path ?? "nil") resolved to \(resolved), which is not enterable")
        }
    }

    func testADocumentInsideAnUnusableFolderFallsThroughToTheVault() throws {
        // The fallback chain has to keep walking rather than stop at the first
        // candidate that merely *exists*.
        let vault = try directory(named: "vault")
        let missingNote = root
            .appendingPathComponent("gone")
            .appendingPathComponent("Note.md")

        XCTAssertEqual(
            TerminalSession.resolveWorkingDirectory(document: missingNote, vault: vault),
            vault.standardizedFileURL.path)
    }

    // MARK: - Randomised

    func testResolutionAlwaysYieldsAnEnterableDirectory() throws {
        // Whatever combination of present, missing, file, and nil arrives, a
        // shell must have somewhere real to start. This is the one property
        // the terminal cannot be allowed to violate: a bad cwd means the shell
        // either fails to launch or lands somewhere unexplained.
        var generator = SeededGenerator(seed: 0xDEAD_BEEF)

        let present = try directory(named: "present")
        let alsoPresent = try directory(named: "also present 🌱")
        let file = root.appendingPathComponent("note.md")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let missing = root.appendingPathComponent("missing-\(UUID().uuidString)")

        let pool: [URL?] = [
            nil, present, alsoPresent, file, missing,
            root.appendingPathComponent("missing/deeper"),
            URL(fileURLWithPath: "/"),
            URL(fileURLWithPath: "/private/var/root"),
        ]

        for step in 0..<600 {
            let document = pool.randomElement(using: &generator) ?? nil
            let vault = pool.randomElement(using: &generator) ?? nil
            let resolved = TerminalSession.resolveWorkingDirectory(
                document: document, vault: vault)

            XCTAssertTrue(
                TerminalSession.isUsableDirectory(resolved),
                "step \(step): document \(document?.path ?? "nil"), "
                    + "vault \(vault?.path ?? "nil") gave \(resolved)")

            // And the full session must be launchable as well as resolvable.
            let session = TerminalSession.resolve(document: document, vault: vault)
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: session.shell))
            XCTAssertTrue(session.argv0.hasPrefix("-"), "login shells only")
        }
    }

    func testRevalidationIsIdempotentAndNeverWorsensASession() throws {
        let present = try directory(named: "present")
        let session = TerminalSession.resolve(document: nil, vault: present)

        let once = session.revalidated()
        let twice = once.revalidated()
        XCTAssertEqual(once, twice, "revalidating a good session must change nothing")
        XCTAssertEqual(once, session)
    }
}
