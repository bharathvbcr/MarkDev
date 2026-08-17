//
//  TerminalSessionTests.swift
//  MarkDevKitTests
//
//  Which shell the drawer runs, and where it starts.
//

import XCTest

@testable import MarkDevKit

final class TerminalSessionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevTerminal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Shell

    func testThePreferredShellIsTheOneTheUserActuallyUses() {
        // Running /bin/sh when someone has chosen fish or zsh gives them a
        // terminal without their aliases, prompt, or PATH.
        let shell = TerminalSession.resolveShell(environment: ["SHELL": "/bin/zsh"])
        XCTAssertEqual(shell, "/bin/zsh")
    }

    func testAShellThatNoLongerExistsFallsBack() {
        // An environment inherited from a stale login session can name a shell
        // that has since been uninstalled. Launching it yields a drawer that
        // opens empty and explains nothing.
        let shell = TerminalSession.resolveShell(
            environment: ["SHELL": "/opt/homebrew/bin/removed-shell"])
        XCTAssertNotEqual(shell, "/opt/homebrew/bin/removed-shell")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: shell))
    }

    func testARelativeShellPathIsRejected() {
        // `SHELL=zsh` would be resolved against the working directory, which
        // is attacker-influenced in a vault of files from elsewhere.
        let shell = TerminalSession.resolveShell(environment: ["SHELL": "zsh"])
        XCTAssertTrue(shell.hasPrefix("/"))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: shell))
    }

    func testAnEmptyEnvironmentStillProducesAWorkingShell() {
        let shell = TerminalSession.resolveShell(environment: [:])
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: shell))
    }

    // MARK: - Working directory

    func testTheShellStartsBesideTheOpenNote() throws {
        let note = directory.appendingPathComponent("Note.md")
        try "hello".write(to: note, atomically: true, encoding: .utf8)

        let cwd = TerminalSession.resolveWorkingDirectory(
            document: note, vault: URL(fileURLWithPath: NSHomeDirectory()))
        XCTAssertEqual(cwd, directory.standardizedFileURL.path)
    }

    func testAnUnsavedDocumentFallsBackToTheVault() {
        let cwd = TerminalSession.resolveWorkingDirectory(document: nil, vault: directory)
        XCTAssertEqual(cwd, directory.standardizedFileURL.path)
    }

    func testAVaultThatHasBeenRemovedFallsBackToHome() {
        // A vault can be renamed or unmounted while the window is open.
        // Launching a shell into a directory that is not there fails in a way
        // the reader cannot act on.
        let gone = directory.appendingPathComponent("not-here")
        let cwd = TerminalSession.resolveWorkingDirectory(document: nil, vault: gone)
        XCTAssertEqual(cwd, NSHomeDirectory())
    }

    func testAFileMasqueradingAsADirectoryIsSkipped() throws {
        // `vault` is whatever the workspace holds; it must be checked to be a
        // directory, not merely to exist.
        let file = directory.appendingPathComponent("NotAFolder")
        try "x".write(to: file, atomically: true, encoding: .utf8)

        let cwd = TerminalSession.resolveWorkingDirectory(document: nil, vault: file)
        XCTAssertEqual(cwd, NSHomeDirectory())
    }

    func testWithNothingKnownTheShellStartsAtHome() {
        XCTAssertEqual(
            TerminalSession.resolveWorkingDirectory(document: nil, vault: nil), NSHomeDirectory())
    }

    // MARK: - Login shell

    func testTheShellIsLaunchedAsALoginShell() throws {
        // The leading dash is how a Unix shell is told it is a login shell,
        // which is what makes it read the profile that puts Homebrew, mise, or
        // nvm on PATH. Without it a coding CLI is simply "command not found",
        // which reads as MarkDev's terminal being broken.
        let note = directory.appendingPathComponent("Note.md")
        try "hello".write(to: note, atomically: true, encoding: .utf8)

        let session = TerminalSession.resolve(
            document: note, vault: nil, environment: ["SHELL": "/bin/zsh"])
        XCTAssertEqual(session.argv0, "-zsh")
        XCTAssertEqual(session.shell, "/bin/zsh")
        XCTAssertEqual(session.workingDirectory, directory.standardizedFileURL.path)
    }

    func testTheLoginNameFollowsTheResolvedShellNotTheRequestedOne() {
        // If the requested shell was rejected, argv[0] has to name the shell
        // that actually runs — a bash process told it is `-fish` reads the
        // wrong profile.
        let session = TerminalSession.resolve(
            document: nil, vault: nil, environment: ["SHELL": "/nope/fish"])
        XCTAssertEqual(session.argv0, "-" + (session.shell as NSString).lastPathComponent)
    }
}
