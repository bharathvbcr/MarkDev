//
//  TerminalProcessTests.swift
//  MarkDevKitTests
//
//  That the drawer actually runs a shell.
//
//  ``TerminalSessionTests`` proves the *decisions* — which shell, which
//  directory. This proves the pty: SwiftTerm links, a child process starts
//  under it, and its exit reaches the delegate. Without this the drawer could
//  be a black rectangle and every other test would still pass.
//

import AppKit
import SwiftTerm
import XCTest

@testable import MarkDevKit

@MainActor
final class TerminalProcessTests: XCTestCase {
    /// Collects the delegate callbacks a launched process produces.
    private final class Recorder: NSObject, LocalProcessTerminalViewDelegate {
        var exitCode: Int32??
        var onExit: (() -> Void)?

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            self.exitCode = exitCode
            onExit?()
        }
    }

    private func run(_ executable: String, _ args: [String], timeout: TimeInterval = 10)
        -> TerminalExit
    {
        let view = LocalProcessTerminalView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let recorder = Recorder()
        view.processDelegate = recorder

        let finished = expectation(description: "process exits")
        recorder.onExit = { finished.fulfill() }

        view.startProcess(executable: executable, args: args)
        wait(for: [finished], timeout: timeout)
        return TerminalExit(waitStatus: recorder.exitCode ?? nil)
    }

    func testAShellRunsUnderAPtyAndItsExitIsReported() {
        // A real fork/exec through a pseudo-terminal. `exit 7` is chosen over
        // `exit 0` so a delegate that reports a hardcoded success cannot pass
        // — and because the raw status SwiftTerm hands over is 1792 for it,
        // which is exactly the decoding this asserts.
        XCTAssertEqual(run("/bin/sh", ["-c", "exit 7"]), .code(7))
    }

    func testASuccessfulCommandReportsZero() {
        XCTAssertEqual(run("/bin/sh", ["-c", "true"]), .code(0))
    }

    func testAKilledShellIsReportedAsSignalledNotAsAStatus() {
        // A shell killed by `^C` must not be shown as "exited (2)": the
        // difference between a command that failed and one that was
        // interrupted is the whole point of the readout.
        XCTAssertEqual(run("/bin/sh", ["-c", "kill -TERM $$"]), .signal(SIGTERM))
    }

    func testTheResolvedSessionShellItselfStarts() {
        // The shell the drawer would actually launch — not a hardcoded
        // /bin/sh — so a resolver that picks an unusable path fails here
        // rather than in front of the reader.
        let session = TerminalSession.resolve(document: nil, vault: nil)
        XCTAssertEqual(run(session.shell, ["-c", "exit 3"]), .code(3))
    }
}

final class TerminalExitTests: XCTestCase {
    func testAnExitCodeIsReadFromTheHighByte() {
        // `waitpid` packs the status: `exit 7` arrives as 7 << 8.
        XCTAssertEqual(TerminalExit(waitStatus: 1792), .code(7))
        XCTAssertEqual(TerminalExit(waitStatus: 0), .code(0))
        XCTAssertEqual(TerminalExit(waitStatus: 65280), .code(255))
    }

    func testASignalIsReadFromTheLowBits() {
        XCTAssertEqual(TerminalExit(waitStatus: SIGINT), .signal(SIGINT))
        XCTAssertEqual(TerminalExit(waitStatus: SIGKILL), .signal(SIGKILL))
    }

    func testAStoppedChildHasNotEndedAtAll() {
        // 0x7F in the low bits means stopped, not exited. Reporting it as an
        // exit would put a dead "exited" label on a shell that is still there.
        XCTAssertEqual(TerminalExit(waitStatus: 0x137F), .unknown)
    }

    func testANilStatusMeansThePtyFailedNotTheChild() {
        XCTAssertEqual(TerminalExit(waitStatus: nil), .unknown)
    }

    func testOnlyACleanExitReadsAsClean() {
        XCTAssertTrue(TerminalExit.code(0).isClean)
        XCTAssertFalse(TerminalExit.code(1).isClean)
        XCTAssertFalse(TerminalExit.signal(SIGINT).isClean)
        XCTAssertFalse(TerminalExit.unknown.isClean)
    }

    func testEachOutcomeReadsDifferently() {
        XCTAssertEqual(TerminalExit.code(0).summary, "exited")
        XCTAssertEqual(TerminalExit.code(7).summary, "exited (7)")
        XCTAssertEqual(TerminalExit.signal(9).summary, "killed (signal 9)")
        XCTAssertEqual(TerminalExit.unknown.summary, "ended")
    }
}
