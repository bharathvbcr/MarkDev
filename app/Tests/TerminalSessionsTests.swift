//
//  TerminalSessionsTests.swift
//  MarkDevKitTests
//
//  The session list: its invariants, its bound, and a randomised hammering of
//  both.
//

import XCTest

@testable import MarkDevKit

@MainActor
final class TerminalSessionsTests: XCTestCase {
    private func config(_ directory: String) -> TerminalSession {
        TerminalSession(shell: "/bin/zsh", workingDirectory: directory, argv0: "-zsh")
    }

    private func makeSessions() -> TerminalSessions { TerminalSessions() }

    // MARK: - Opening

    func testOpeningSelectsTheNewSession() throws {
        let sessions = makeSessions()
        let first = try sessions.open(config("/a"))
        XCTAssertEqual(sessions.selection, first)

        let second = try sessions.open(config("/b"))
        XCTAssertEqual(sessions.selection, second, "a new shell is the one you want to see")
        XCTAssertEqual(sessions.sessions.count, 2)
    }

    func testOpeningTwiceInTheSameFolderForksTwoShells() throws {
        // `open` is the `+` button, and two shells in one folder is a normal
        // thing to want — one running a server, one for commands.
        let sessions = makeSessions()
        try sessions.open(config("/a"))
        try sessions.open(config("/a"))
        XCTAssertEqual(sessions.sessions.count, 2)
    }

    func testRevealingTwiceInTheSameFolderReusesTheShell() throws {
        // `reveal` is the sidebar, where clicking a folder twice must not pile
        // up duplicates nobody meant to open.
        let sessions = makeSessions()
        let first = try sessions.reveal(config("/a"))
        let again = try sessions.reveal(config("/a"))

        XCTAssertEqual(first, again)
        XCTAssertEqual(sessions.sessions.count, 1)
        XCTAssertEqual(sessions.selection, first)
    }

    func testRevealingADeadShellsFolderStartsAFreshOne() throws {
        // Reusing an exited session would "open a terminal" onto a dead one.
        let sessions = makeSessions()
        let first = try sessions.reveal(config("/a"))
        sessions.markExited(.code(0), for: first)

        let second = try sessions.reveal(config("/a"))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(sessions.sessions.count, 2)
    }

    func testRevealingADifferentFolderOpensASecondShell() throws {
        let sessions = makeSessions()
        try sessions.reveal(config("/a"))
        try sessions.reveal(config("/b"))
        XCTAssertEqual(Set(sessions.sessions.map(\.config.workingDirectory)), ["/a", "/b"])
    }

    // MARK: - The bound

    func testTheSessionCountIsBounded() throws {
        let sessions = makeSessions()
        for index in 0..<TerminalSessions.limit {
            try sessions.open(config("/dir\(index)"))
        }
        XCTAssertEqual(sessions.sessions.count, TerminalSessions.limit)

        // Every one of them is live, so there is nothing safe to reclaim.
        XCTAssertThrowsError(try sessions.open(config("/one-too-many"))) { error in
            let failure = error as? TerminalOpenFailure
            XCTAssertNotNil(failure)
            XCTAssertTrue(
                failure?.reason.contains("\(TerminalSessions.limit)") ?? false,
                "the refusal must say what the limit is")
        }
        XCTAssertEqual(sessions.sessions.count, TerminalSessions.limit, "and nothing was killed")
    }

    func testAnExitedSessionIsReclaimedBeforeRefusing() throws {
        // A dead shell holds nothing. Refusing to open a terminal because of
        // one would be the bound punishing the reader for the app's tidiness.
        let sessions = makeSessions()
        var ids: [TerminalSessionState.ID] = []
        for index in 0..<TerminalSessions.limit {
            ids.append(try sessions.open(config("/dir\(index)")))
        }
        sessions.markExited(.code(0), for: ids[0])

        let fresh = try sessions.open(config("/new"))
        XCTAssertEqual(sessions.sessions.count, TerminalSessions.limit)
        XCTAssertEqual(sessions.selection, fresh)
        XCTAssertFalse(
            sessions.sessions.contains { $0.id == ids[0] }, "the dead one was reclaimed")
        XCTAssertTrue(
            sessions.sessions.contains { $0.id == ids[1] }, "a live one was not")
    }

    // MARK: - Closing

    func testClosingTheSelectedSessionLandsOnTheNext() throws {
        let sessions = makeSessions()
        let a = try sessions.open(config("/a"))
        let b = try sessions.open(config("/b"))
        let c = try sessions.open(config("/c"))

        sessions.select(b)
        sessions.close(b)
        XCTAssertEqual(sessions.selection, c, "closing a tab should land on its neighbour")
        XCTAssertEqual(sessions.sessions.map(\.id), [a, c])
    }

    func testClosingTheLastSessionLandsOnThePrevious() throws {
        let sessions = makeSessions()
        let a = try sessions.open(config("/a"))
        let b = try sessions.open(config("/b"))

        sessions.select(b)
        sessions.close(b)
        XCTAssertEqual(sessions.selection, a)
    }

    func testClosingTheOnlySessionLeavesNothingSelected() throws {
        let sessions = makeSessions()
        let a = try sessions.open(config("/a"))
        sessions.close(a)

        XCTAssertNil(sessions.selection)
        XCTAssertTrue(sessions.isEmpty)
    }

    func testClosingAnUnselectedSessionDoesNotMoveTheSelection() throws {
        let sessions = makeSessions()
        let a = try sessions.open(config("/a"))
        let b = try sessions.open(config("/b"))

        sessions.select(b)
        sessions.close(a)
        XCTAssertEqual(sessions.selection, b, "closing a background tab must not steal focus")
    }

    func testClosingSomethingThatIsNotThereIsANoOp() throws {
        let sessions = makeSessions()
        let a = try sessions.open(config("/a"))
        sessions.close(UUID())

        XCTAssertEqual(sessions.sessions.count, 1)
        XCTAssertEqual(sessions.selection, a)
    }

    func testSelectingSomethingThatIsNotThereIsANoOp() throws {
        // Otherwise a stale id from a closed tab would blank the drawer.
        let sessions = makeSessions()
        let a = try sessions.open(config("/a"))
        sessions.select(UUID())
        XCTAssertEqual(sessions.selection, a)
    }

    // MARK: - Session state

    func testRestartingClearsTheExitAndBumpsTheGeneration() throws {
        let sessions = makeSessions()
        let a = try sessions.open(config("/a"))
        sessions.markExited(.code(3), for: a)

        let before = try XCTUnwrap(sessions.current?.generation)
        sessions.restart(a)

        XCTAssertNil(sessions.current?.exit, "a restarted shell is not a dead one")
        XCTAssertEqual(sessions.current?.generation, before + 1)
    }

    func testATitleDefaultsToTheFolderName() throws {
        let sessions = makeSessions()
        try sessions.open(config("/Users/someone/Notes"))
        XCTAssertEqual(sessions.current?.title, "Notes")
    }

    func testAnEmptyTitleIsIgnored() throws {
        // Shells emit an empty title escape on some prompts; taking it would
        // blank the tab.
        let sessions = makeSessions()
        let a = try sessions.open(config("/a"))
        sessions.setTitle("   ", for: a)
        XCTAssertEqual(sessions.current?.title, "a")
    }

    func testLiveExcludesExitedSessions() throws {
        let sessions = makeSessions()
        let a = try sessions.open(config("/a"))
        try sessions.open(config("/b"))
        sessions.markExited(.signal(SIGINT), for: a)

        XCTAssertEqual(sessions.live.count, 1)
        XCTAssertFalse(sessions.sessions.first { $0.id == a }?.isLive ?? true)
    }

    // MARK: - Randomised

    func testInvariantsHoldUnderARandomStormOfOperations() throws {
        // Every reachable state, not the handful a person thinks to write
        // down. The invariants below are what the drawer relies on: a
        // selection that names a session that exists, no duplicate ids, and a
        // list that never exceeds the bound.
        var generator = SeededGenerator(seed: 0x5EED_1234)
        let sessions = makeSessions()
        var refused = 0
        var opened = 0

        for step in 0..<4000 {
            switch Int.random(in: 0..<6, using: &generator) {
            case 0, 1:
                let directory = "/dir\(Int.random(in: 0..<5, using: &generator))"
                do {
                    _ = try sessions.open(config(directory))
                    opened += 1
                } catch { refused += 1 }
            case 2:
                let directory = "/dir\(Int.random(in: 0..<5, using: &generator))"
                do {
                    _ = try sessions.reveal(config(directory))
                    opened += 1
                } catch { refused += 1 }
            case 3:
                if let victim = sessions.sessions.randomElement(using: &generator) {
                    sessions.close(victim.id)
                }
            case 4:
                if let target = sessions.sessions.randomElement(using: &generator) {
                    sessions.select(target.id)
                }
            default:
                if let target = sessions.sessions.randomElement(using: &generator) {
                    if Bool.random(using: &generator) {
                        sessions.markExited(.code(Int32.random(in: 0...255, using: &generator)),
                            for: target.id)
                    } else {
                        sessions.restart(target.id)
                    }
                }
            }

            // Checked after *every* step, so a failure names the operation
            // that broke it rather than the end of the run.
            let ids = sessions.sessions.map(\.id)
            XCTAssertEqual(Set(ids).count, ids.count, "duplicate session at step \(step)")
            XCTAssertLessThanOrEqual(
                ids.count, TerminalSessions.limit, "bound exceeded at step \(step)")
            if let selection = sessions.selection {
                XCTAssertTrue(
                    ids.contains(selection), "selection dangles at step \(step)")
            } else {
                XCTAssertTrue(
                    sessions.sessions.isEmpty,
                    "nothing selected while \(ids.count) sessions exist, step \(step)")
            }
        }

        // The storm has to have exercised both paths, or it proved nothing.
        XCTAssertGreaterThan(opened, 100, "the run should have opened plenty")
        XCTAssertGreaterThan(refused, 0, "and pushed against the bound")
    }

    func testClosingEverythingOneByOneAlwaysEndsEmptyAndSelectionless() throws {
        var generator = SeededGenerator(seed: 0xC0FFEE)
        for _ in 0..<200 {
            let sessions = makeSessions()
            let count = Int.random(in: 1...TerminalSessions.limit, using: &generator)
            for index in 0..<count { try sessions.open(config("/dir\(index)")) }

            while let victim = sessions.sessions.randomElement(using: &generator) {
                sessions.close(victim.id)
                // The invariant that matters while tearing down: never a
                // selection pointing at something gone.
                if let selection = sessions.selection {
                    XCTAssertTrue(sessions.sessions.contains { $0.id == selection })
                }
            }
            XCTAssertTrue(sessions.isEmpty)
            XCTAssertNil(sessions.selection)
        }
    }
}

@MainActor
final class NavigatorTerminalTargetTests: XCTestCase {
    private func node(_ path: String, isDirectory: Bool) -> FileNode {
        FileNode(url: URL(fileURLWithPath: path), isDirectory: isDirectory)
    }

    func testAFolderOpensInItself() {
        let folder = node("/vault/Projects", isDirectory: true)
        XCTAssertEqual(
            NavigatorTerminalTarget.directory(for: folder).path, "/vault/Projects")
    }

    func testANoteOpensInTheFolderHoldingIt() {
        // A shell cannot start "in" a file. Getting this wrong is the
        // difference between a working command and a shell that starts
        // somewhere else for no visible reason.
        let file = node("/vault/Projects/Plan.md", isDirectory: false)
        XCTAssertEqual(
            NavigatorTerminalTarget.directory(for: file).path, "/vault/Projects")
    }

    func testAFolderNamedLikeANoteIsStillAFolder() {
        // `Archive.md` as a *directory* is legal, and the extension must not
        // be what decides.
        let folder = node("/vault/Archive.md", isDirectory: true)
        XCTAssertEqual(
            NavigatorTerminalTarget.directory(for: folder).path, "/vault/Archive.md")
    }

    func testAnAwkwardlyNamedFolderSurvivesIntact() {
        for name in ["with spaces", "ünïcödé", "emoji-🚀", "-dash", "a'b\"c"] {
            let folder = node("/vault/\(name)", isDirectory: true)
            XCTAssertEqual(
                NavigatorTerminalTarget.directory(for: folder).lastPathComponent, name)
        }
    }

    func testTheTargetOfEveryNodeIsSomethingASessionCanBeResolvedFor() {
        // The sidebar hands its answer straight to `TerminalSession.resolve`,
        // so whatever it produces has to survive that trip.
        let nodes = [
            node("/vault", isDirectory: true),
            node("/vault/Note.md", isDirectory: false),
            node("/vault/deep/nested/folder", isDirectory: true),
        ]
        for candidate in nodes {
            let directory = NavigatorTerminalTarget.directory(for: candidate)
            let session = TerminalSession.resolve(document: nil, vault: directory)
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: session.shell))
            XCTAssertTrue(
                TerminalSession.isUsableDirectory(session.workingDirectory),
                "\(directory.path) produced an unusable cwd")
        }
    }
}
