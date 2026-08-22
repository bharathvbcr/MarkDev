//
//  VaultWatcherTests.swift
//  MarkDevKitTests
//
//  The file-system watch that makes external changes visible.
//

import XCTest

@testable import MarkDevKit

@MainActor
final class VaultWatcherTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevWatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A file created after the watch began must be reported. This is the one
    /// property everything downstream depends on; a silent stream would leave
    /// every consumer believing nothing changed.
    func testReportsAFileCreatedAfterWatchingStarted() async throws {
        let watcher = VaultWatcher()
        watcher.start(at: directory)
        defer { watcher.stop() }

        let seen = expectation(description: "created-later.md was reported")
        watcher.onEvents = { paths in
            if paths.contains(where: { $0.hasSuffix("created-later.md") }) {
                seen.fulfill()
            }
        }

        try "# fresh".write(
            to: directory.appendingPathComponent("created-later.md"),
            atomically: true, encoding: .utf8)

        await fulfillment(of: [seen], timeout: 15)
    }

    /// Events arrive on the main actor — the contract every consumer leans on.
    func testEventsArriveOnTheMainActor() async throws {
        let watcher = VaultWatcher()
        watcher.start(at: directory)
        defer { watcher.stop() }

        let seen = expectation(description: "the event arrived on the main actor")
        watcher.onEvents = { _ in
            XCTAssertTrue(Thread.isMainThread, "consumers assume main-actor delivery")
            seen.fulfill()
        }

        try "x".write(to: directory.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        await fulfillment(of: [seen], timeout: 15)
    }

    func testStopIsIdempotentAndClearsTheWatchedRoot() throws {
        let watcher = VaultWatcher()
        XCTAssertNil(watcher.watchedRoot)

        watcher.start(at: directory)
        XCTAssertEqual(watcher.watchedRoot?.standardizedFileURL, directory.standardizedFileURL)

        watcher.stop()
        XCTAssertNil(watcher.watchedRoot)

        // A second stop over an ended stream must not crash or resurrect.
        watcher.stop()
        XCTAssertNil(watcher.watchedRoot)
    }

    func testStartingTwiceMovesTheWatchRatherThanLeakingAStream() throws {
        let watcher = VaultWatcher()
        defer { watcher.stop() }

        watcher.start(at: directory)
        let other = directory.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        watcher.start(at: other)

        XCTAssertEqual(watcher.watchedRoot?.standardizedFileURL, other.standardizedFileURL)
    }
}
