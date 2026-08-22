//
//  MiddleClickAndWatchTests.swift
//  MarkDevKitTests
//
//  The shared middle-click dispatcher and the vault watch coordinator: the
//  two pieces of process-wide state added when per-instance handlers became
//  strip-wide / folder-wide ones.
//

import XCTest

@testable import MarkDevKit

// MARK: - Middle-click dispatcher

@MainActor
final class MiddleClickDispatcherTests: XCTestCase {
    private var window: NSWindow!
    private var views: [MiddleClickView] = []

    override func setUp() {
        // Borderless, off-screen, never closed — a window built in code is
        // released by close(), and a test holding it afterwards over-releases
        // (see the suite's own notes on that trap).
        window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: 400, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
    }

    override func tearDown() {
        for view in views {
            view.removeFromSuperview()
            MiddleClickDispatcher.shared.unregister(view)
        }
        views.removeAll()
        MiddleClickDispatcher.shared.removeAllForTesting()
        window = nil
        super.tearDown()
    }

    @discardableResult
    private func chip(frame: NSRect, action: @escaping () -> Void) -> MiddleClickView {
        let view = MiddleClickView(action: action)
        view.frame = frame
        window.contentView?.addSubview(view)
        MiddleClickDispatcher.shared.register(view, action: action)
        views.append(view)
        return view
    }

    func testDispatchClaimsOnlyTheChipUnderThePointer() {
        var hitLeft = false
        var hitRight = false
        chip(frame: NSRect(x: 0, y: 0, width: 50, height: 20)) { hitLeft = true }
        chip(frame: NSRect(x: 60, y: 0, width: 50, height: 20)) { hitRight = true }

        XCTAssertTrue(
            MiddleClickDispatcher.shared.dispatch(
                locationInWindow: NSPoint(x: 10, y: 10), window: window))
        XCTAssertTrue(hitLeft)
        XCTAssertFalse(hitRight)

        hitLeft = false
        XCTAssertTrue(
            MiddleClickDispatcher.shared.dispatch(
                locationInWindow: NSPoint(x: 70, y: 10), window: window))
        XCTAssertFalse(hitLeft)
        XCTAssertTrue(hitRight)
    }

    func testDispatchOutsideEveryTargetPassesThrough() {
        chip(frame: NSRect(x: 0, y: 0, width: 50, height: 20)) {}

        XCTAssertFalse(
            MiddleClickDispatcher.shared.dispatch(
                locationInWindow: NSPoint(x: 300, y: 80), window: window),
            "empty space must not be consumed")
    }

    func testDispatchIgnoresAnotherWindowsPoints() {
        chip(frame: NSRect(x: 0, y: 0, width: 50, height: 20)) {}
        XCTAssertFalse(
            MiddleClickDispatcher.shared.dispatch(
                locationInWindow: NSPoint(x: 10, y: 10), window: nil))
    }

    /// Overlapping regions resolve deterministically rather than firing both
    /// actions or whichever the dictionary iteration happens to offer.
    func testOverlappingTargetsResolveTheSameWayTwice() {
        var firstHit = false
        var secondHit = false
        chip(frame: NSRect(x: 0, y: 0, width: 60, height: 20)) { firstHit = true }
        chip(frame: NSRect(x: 30, y: 0, width: 60, height: 20)) { secondHit = true }

        for _ in 0..<5 {
            firstHit = false
            secondHit = false
            XCTAssertTrue(
                MiddleClickDispatcher.shared.dispatch(
                    locationInWindow: NSPoint(x: 40, y: 10), window: window))
            XCTAssertTrue(firstHit != secondHit, "exactly one claimant may win")
        }
    }

    /// A view removed from its window stops being dispatched to even if the
    /// object itself is still alive — the tab-strip teardown case.
    func testRemovedViewIsNoLongerClaimed() {
        var hits = 0
        let view = chip(frame: NSRect(x: 0, y: 0, width: 50, height: 20)) { hits += 1 }
        XCTAssertEqual(MiddleClickDispatcher.shared.targetCount, 1)

        view.removeFromSuperview()
        MiddleClickDispatcher.shared.unregister(view)

        XCTAssertFalse(
            MiddleClickDispatcher.shared.dispatch(
                locationInWindow: NSPoint(x: 10, y: 10), window: window))
        XCTAssertEqual(hits, 0)
        XCTAssertEqual(MiddleClickDispatcher.shared.targetCount, 0)
    }
}

// MARK: - Vault watch coordinator

@MainActor
final class VaultWatchCoordinatorTests: XCTestCase {
    private var rootA: URL!
    private var rootB: URL!

    override func setUpWithError() throws {
        // Refcounting and fan-out need no daemon: fseventsd throttles a
        // process that births many streams, so these run against the
        // bookkeeping-only mode and every live-delivery question is answered
        // by the watcher canaries, which spend their births deliberately.
        VaultWatchCoordinator.startsRealStreamsForTesting = false
        rootA = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevWatchCoord-A-\(UUID().uuidString)")
        rootB = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevWatchCoord-B-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        VaultWatchCoordinator.startsRealStreamsForTesting = true
        try? FileManager.default.removeItem(at: rootA)
        try? FileManager.default.removeItem(at: rootB)
    }

    func testTwoSubscribersOnOneRootShareOneStream() {
        let coordinator = VaultWatchCoordinator.shared
        let first = coordinator.subscribe(to: rootA) { _ in }
        let second = coordinator.subscribe(to: rootA) { _ in }
        defer {
            coordinator.unsubscribe(first, root: rootA)
            coordinator.unsubscribe(second, root: rootA)
        }

        XCTAssertEqual(coordinator.activeStreamCount(forTestingRoot: rootA), 1)
        XCTAssertNotEqual(first, second, "tokens must be distinguishable")
    }

    func testEventsFanOutToEverySubscriber() {
        let coordinator = VaultWatchCoordinator.shared
        var gotFirst: [String] = []
        var gotSecond: [String] = []
        let tokenA = coordinator.subscribe(to: rootA) { gotFirst.append(contentsOf: $0) }
        let tokenB = coordinator.subscribe(to: rootA) { gotSecond.append(contentsOf: $0) }
        defer {
            coordinator.unsubscribe(tokenA, root: rootA)
            coordinator.unsubscribe(tokenB, root: rootA)
        }

        coordinator.emit(root: rootA, paths: ["/x/note.md"])

        XCTAssertEqual(gotFirst, ["/x/note.md"])
        XCTAssertEqual(gotSecond, ["/x/note.md"])
    }

    func testUnsubscribeStopsTheStreamAtZeroButNotBefore() {
        let coordinator = VaultWatchCoordinator.shared
        let first = coordinator.subscribe(to: rootA) { _ in }
        let second = coordinator.subscribe(to: rootA) { _ in }

        coordinator.unsubscribe(first, root: rootA)
        XCTAssertEqual(coordinator.activeStreamCount(forTestingRoot: rootA), 1)

        coordinator.unsubscribe(second, root: rootA)
        XCTAssertEqual(coordinator.activeStreamCount(forTestingRoot: rootA), 0)

        // Unsubscribing twice must be harmless.
        coordinator.unsubscribe(second, root: rootA)
        XCTAssertEqual(coordinator.activeStreamCount(forTestingRoot: rootA), 0)
    }

    func testDifferentRootsDoNotShareStreamsOrEvents() {
        let coordinator = VaultWatchCoordinator.shared
        var eventsForB: [String] = []
        let tokenA = coordinator.subscribe(to: rootA) { _ in }
        let tokenB = coordinator.subscribe(to: rootB) { eventsForB.append(contentsOf: $0) }
        defer {
            coordinator.unsubscribe(tokenA, root: rootA)
            coordinator.unsubscribe(tokenB, root: rootB)
        }

        coordinator.emit(root: rootA, paths: ["/a/only.md"])
        XCTAssertTrue(eventsForB.isEmpty, "root A's event leaked into root B's subscriber")
        XCTAssertEqual(coordinator.activeStreamCount(forTestingRoot: rootA), 1)
        XCTAssertEqual(coordinator.activeStreamCount(forTestingRoot: rootB), 1)
    }

    /// Subscribe/unsubscribe churn: the shape of windows opening and closing
    /// repeatedly on one vault. The stream count must never grow past one,
    /// and every subscriber still standing at the end keeps receiving.
    func testSubscriptionChurnKeepsExactlyOneLiveStream() {
        let coordinator = VaultWatchCoordinator.shared
        var tokens: [UUID] = []
        var survivorHits = 0

        let survivor = coordinator.subscribe(to: rootA) { _ in survivorHits += 1 }

        for round in 0..<60 {
            tokens.append(coordinator.subscribe(to: rootA) { _ in })
            if round % 3 == 0, !tokens.isEmpty {
                coordinator.unsubscribe(tokens.removeFirst(), root: rootA)
            }
        }
        for token in tokens { coordinator.unsubscribe(token, root: rootA) }
        tokens.removeAll()

        coordinator.emit(root: rootA, paths: ["churn"])
        XCTAssertEqual(survivorHits, 1, "the surviving subscription went deaf")
        XCTAssertEqual(coordinator.activeStreamCount(forTestingRoot: rootA), 1)
        coordinator.unsubscribe(survivor, root: rootA)
        XCTAssertEqual(coordinator.activeStreamCount(forTestingRoot: rootA), 0)
    }
}
