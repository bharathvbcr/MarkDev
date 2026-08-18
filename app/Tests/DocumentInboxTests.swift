//
//  DocumentInboxTests.swift
//  MarkDevKitTests
//
//  Opening a file from Finder — including the ordering that broke it three
//  times.
//

import AppKit
import XCTest

@testable import MarkDevKit

/// A surface under a test's control: it answers a readiness the test sets, and
/// records what it was handed.
@MainActor
private final class FakeSurface {
    var readiness: DocumentSurfaceReadiness
    /// Whether it accepts what it is offered. A window that has gone between
    /// being chosen and being handed the files refuses.
    var accepts = true
    private(set) var received: [URL] = []
    private(set) var batches = 0
    var token: DocumentSurfaceToken?

    init(readiness: DocumentSurfaceReadiness = .frontmost) {
        self.readiness = readiness
    }

    func register(with inbox: DocumentInbox) {
        token = inbox.register(
            readiness: { [weak self] in self?.readiness ?? .gone },
            deliver: { [weak self] request in
                guard let self, self.accepts else { return false }
                self.received.append(contentsOf: request.urls)
                self.batches += 1
                return true
            })
    }

    func unregister(from inbox: DocumentInbox) {
        guard let token else { return }
        inbox.unregister(token)
        self.token = nil
    }

    var names: [String] { received.map(\.lastPathComponent) }
}

/// Runs scheduled work only when the test says so.
@MainActor
private final class ManualClock {
    private var work: [@MainActor @Sendable () -> Void] = []
    var pendingCount: Int { work.count }

    /// Captured strongly: the inbox outlives the local this clock is bound to
    /// in tests that never name it.
    var scheduler: DocumentInbox.Scheduler {
        { [self] _, body in self.work.append(body) }
    }

    /// Fires everything scheduled so far, once.
    func fire() {
        let due = work
        work.removeAll()
        for body in due { body() }
    }
}

@MainActor
final class DocumentInboxTests: XCTestCase {
    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    private func makeInbox() -> (DocumentInbox, ManualClock) {
        let clock = ManualClock()
        return (DocumentInbox(schedule: clock.scheduler), clock)
    }

    // MARK: - Ordering

    func testAFileThatArrivesBeforeAnyWindowIsStillOpened() {
        // The case that made a double-click show an empty untitled window:
        // Launch Services delivers the open request *before*
        // `applicationDidFinishLaunching`, so before any workspace exists.
        let (inbox, _) = makeInbox()
        inbox.receive([url("/vault/Note.md")])

        let window = FakeSurface()
        window.register(with: inbox)

        XCTAssertEqual(window.received.map(\.path), ["/vault/Note.md"])
        XCTAssertTrue(inbox.pending.isEmpty, "the backlog is handed over, not kept")
    }

    func testAFileThatArrivesAfterAWindowGoesStraightThrough() {
        let (inbox, _) = makeInbox()
        let window = FakeSurface()
        window.register(with: inbox)

        inbox.receive([url("/vault/A.md")])
        inbox.receive([url("/vault/B.md")])

        XCTAssertEqual(window.names, ["A.md", "B.md"])
    }

    func testUnregisteringStopsDeliveryAndTheNextWindowGetsTheBacklog() {
        // A closing window must stop being handed documents, and whatever
        // arrives before the next one opens must not be lost.
        let (inbox, _) = makeInbox()
        let first = FakeSurface()
        first.register(with: inbox)
        first.unregister(from: inbox)

        inbox.receive([url("/vault/Later.md")])
        XCTAssertTrue(first.received.isEmpty)
        XCTAssertEqual(inbox.pending.count, 1, "held for whoever comes next")

        let second = FakeSurface()
        second.register(with: inbox)
        XCTAssertEqual(second.names, ["Later.md"])
    }

    func testRegisteringWithNothingWaitingDeliversNothing() {
        // The old bug in miniature: a window appearing to an empty queue must
        // not fire a handler with an empty batch, or every launch looks like
        // an open request.
        let (inbox, _) = makeInbox()
        let window = FakeSurface()
        window.register(with: inbox)
        XCTAssertEqual(window.batches, 0)
    }

    // MARK: - Which surface takes it

    func testAThrowawaySurfaceDoesNotStealTheDocumentFromTheWindowOnScreen() {
        // Traced from a running build: SwiftUI answers every Launch Services
        // file open by building a throwaway workspace, which appears,
        // registers, and disappears again *before* `application(_:open:)` is
        // delivered. Registering last must not mean receiving.
        let (inbox, _) = makeInbox()
        let onScreen = FakeSurface(readiness: .frontmost)
        onScreen.register(with: inbox)

        let throwaway = FakeSurface(readiness: .preparing)
        throwaway.register(with: inbox)
        throwaway.unregister(from: inbox)

        inbox.receive([url("/vault/Note.md")])

        XCTAssertEqual(onScreen.names, ["Note.md"])
        XCTAssertTrue(throwaway.received.isEmpty, "a discarded surface must not take documents")
    }

    func testASurfaceThatNeverWithdrawsIsStillPassedOverOnceItsWindowIsGone() {
        // The second line of defence. Withdrawal is the mechanism; a surface
        // that fails to withdraw — a view SwiftUI drops without calling
        // `onDisappear` — must still not be handed anything.
        let (inbox, _) = makeInbox()
        let closed = FakeSurface(readiness: .frontmost)
        closed.register(with: inbox)
        let onScreen = FakeSurface(readiness: .background)
        onScreen.register(with: inbox)

        closed.readiness = .gone
        inbox.receive([url("/vault/Note.md")])

        XCTAssertTrue(closed.received.isEmpty)
        XCTAssertEqual(onScreen.names, ["Note.md"])
    }

    func testTheKeyWindowIsPreferredOverOneBehindIt() {
        let (inbox, _) = makeInbox()
        let behind = FakeSurface(readiness: .background)
        behind.register(with: inbox)
        let key = FakeSurface(readiness: .frontmost)
        key.register(with: inbox)

        inbox.receive([url("/vault/Note.md")])

        XCTAssertEqual(key.names, ["Note.md"])
        XCTAssertTrue(behind.received.isEmpty)
    }

    func testTheNewestWindowWinsWhenTwoAreEquallyReady() {
        let (inbox, _) = makeInbox()
        let older = FakeSurface(readiness: .background)
        older.register(with: inbox)
        let newer = FakeSurface(readiness: .background)
        newer.register(with: inbox)

        inbox.receive([url("/vault/Note.md")])

        XCTAssertEqual(newer.names, ["Note.md"])
        XCTAssertTrue(older.received.isEmpty)
    }

    func testARefusedRequestFallsThroughToTheNextSurfaceUntouched() {
        // Chosen and delivered are two moments: a window can close in between.
        // What it refuses must reach the next window whole and in order.
        let (inbox, _) = makeInbox()
        let fallback = FakeSurface(readiness: .background)
        fallback.register(with: inbox)
        let closing = FakeSurface(readiness: .frontmost)
        closing.accepts = false
        closing.register(with: inbox)

        inbox.receive([url("/vault/A.md"), url("/vault/B.md")])

        XCTAssertEqual(fallback.names, ["A.md", "B.md"])
        XCTAssertTrue(inbox.pending.isEmpty)
    }

    func testARequestRefusedByEveryoneIsKeptInOrder() {
        let (inbox, _) = makeInbox()
        let closing = FakeSurface(readiness: .frontmost)
        closing.accepts = false
        closing.register(with: inbox)

        inbox.receive([url("/vault/A.md"), url("/vault/B.md")])

        XCTAssertEqual(inbox.pending.map(\.lastPathComponent), ["A.md", "B.md"])
    }

    func testTheTruncationCountSurvivesARefusal() {
        // A refusal that quietly forgot the count would report a full batch
        // after having dropped half of it.
        let (inbox, _) = makeInbox()
        let closing = FakeSurface(readiness: .frontmost)
        closing.accepts = false
        closing.register(with: inbox)

        inbox.receive((0..<(DocumentInbox.limit + 4)).map { url("/vault/N\($0).md") })
        XCTAssertEqual(inbox.dropped, 4)

        let taking = FakeSurface(readiness: .frontmost)
        taking.register(with: inbox)
        XCTAssertEqual(taking.received.count, DocumentInbox.limit)
    }

    // MARK: - Asking for a window

    func testAFileArrivingWithNoWindowAsksForOne() {
        // A Mac app runs on with every window closed, and Finder goes on
        // delivering documents to it. Queuing them for a window that will
        // never come is the app bouncing in the Dock and showing nothing.
        let (inbox, _) = makeInbox()
        var requests = 0
        inbox.windowProvider = { requests += 1 }

        inbox.receive([url("/vault/Note.md")])

        XCTAssertEqual(requests, 1)
        XCTAssertEqual(inbox.pending.count, 1, "kept for the window being opened")
    }

    func testABurstOfRequestsOpensOneWindow() {
        let (inbox, _) = makeInbox()
        var requests = 0
        inbox.windowProvider = { requests += 1 }

        inbox.receive([url("/vault/A.md")])
        inbox.receive([url("/vault/B.md")])
        inbox.receive([url("/vault/C.md")])

        XCTAssertEqual(requests, 1)
    }

    func testTheWindowThatAnswersGetsEverythingThatWasWaiting() {
        let (inbox, _) = makeInbox()
        var requests = 0
        inbox.windowProvider = { requests += 1 }
        inbox.receive([url("/vault/A.md"), url("/vault/B.md")])

        let opened = FakeSurface()
        opened.register(with: inbox)

        XCTAssertEqual(opened.names, ["A.md", "B.md"])
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(inbox.pending.isEmpty)
    }

    func testASecondDeadEndAsksAgainOnceAWindowHasAnswered() {
        let (inbox, _) = makeInbox()
        var requests = 0
        inbox.windowProvider = { requests += 1 }

        inbox.receive([url("/vault/A.md")])
        let window = FakeSurface()
        window.register(with: inbox)
        window.unregister(from: inbox)
        inbox.receive([url("/vault/B.md")])

        XCTAssertEqual(requests, 2, "the second file must not wait on the first request")
    }

    func testAWindowOnItsWayIsWaitedForRatherThanOpeningASecond() {
        // `onAppear` runs while the window still reports itself invisible. A
        // request landing in that instant must not conclude there is no window
        // and open another beside the one arriving.
        let (inbox, _) = makeInbox()
        var requests = 0
        inbox.windowProvider = { requests += 1 }

        let arriving = FakeSurface(readiness: .preparing)
        arriving.register(with: inbox)
        inbox.receive([url("/vault/Note.md")])

        XCTAssertEqual(requests, 0, "a window is already on its way")
        XCTAssertEqual(inbox.pending.count, 1)

        arriving.readiness = .frontmost
        inbox.refresh()

        XCTAssertEqual(arriving.names, ["Note.md"])
        XCTAssertEqual(requests, 0)
    }

    func testAWindowThatNeverArrivesCannotStrandTheDocument() {
        // The bound on the rule above. A surface that registers, never shows a
        // window and never withdraws would otherwise hold the queue for the
        // life of the process.
        let (inbox, clock) = makeInbox()
        var requests = 0
        inbox.windowProvider = { requests += 1 }

        let stuck = FakeSurface(readiness: .preparing)
        stuck.register(with: inbox)
        inbox.receive([url("/vault/Note.md")])
        XCTAssertEqual(requests, 0)

        clock.fire()

        XCTAssertEqual(requests, 1, "the grace period must expire")
        XCTAssertEqual(inbox.pending.count, 1, "and the file must still be waiting")
    }

    func testTheGraceIsSpentOnceRatherThanReArmingForEver() {
        // The hold re-arming itself on every expiry keeps the queue turning
        // over for the life of the process, for a window that is not coming.
        let (inbox, clock) = makeInbox()
        var requests = 0
        inbox.windowProvider = { requests += 1 }
        let stuck = FakeSurface(readiness: .preparing)
        stuck.register(with: inbox)
        inbox.receive([url("/vault/Note.md")])

        clock.fire()
        XCTAssertEqual(clock.pendingCount, 0, "the hold must not re-arm itself")
        XCTAssertEqual(requests, 1)

        inbox.refresh()
        XCTAssertEqual(clock.pendingCount, 0)
        XCTAssertEqual(requests, 1, "and must not ask for a second window")
    }

    func testTheWindowThatWasAskedForIsWaitedForInItsTurn() {
        // The reset side of the rule above: the window opened *because* of the
        // dead end registers before it is on screen, and must be waited for
        // rather than counted as another dead end.
        let (inbox, clock) = makeInbox()
        var requests = 0
        inbox.windowProvider = { requests += 1 }
        let stuck = FakeSurface(readiness: .preparing)
        stuck.register(with: inbox)
        inbox.receive([url("/vault/Note.md")])
        clock.fire()
        XCTAssertEqual(requests, 1)

        let opened = FakeSurface(readiness: .preparing)
        opened.register(with: inbox)
        XCTAssertEqual(requests, 1, "the window asked for is still on its way")

        opened.readiness = .frontmost
        inbox.refresh()
        XCTAssertEqual(opened.names, ["Note.md"])
        XCTAssertEqual(requests, 1)
    }

    func testTheGracePeriodIsArmedOnceRatherThanPerFile() {
        let (inbox, clock) = makeInbox()
        inbox.windowProvider = {}
        let arriving = FakeSurface(readiness: .preparing)
        arriving.register(with: inbox)

        inbox.receive([url("/vault/A.md")])
        inbox.receive([url("/vault/B.md")])
        inbox.receive([url("/vault/C.md")])

        XCTAssertEqual(clock.pendingCount, 1)
    }

    func testNoWindowIsAskedForWhenNothingIsWaiting() {
        let (inbox, _) = makeInbox()
        var requests = 0
        inbox.windowProvider = { requests += 1 }

        inbox.refresh()
        let window = FakeSurface()
        window.register(with: inbox)
        window.unregister(from: inbox)

        XCTAssertEqual(requests, 0)
    }

    // MARK: - Contents

    func testDuplicateRequestsForTheSameFileAreCollapsed() {
        // Launch Services can deliver the same document twice when asked in
        // quick succession; two tabs for one file is not what was meant.
        let (inbox, _) = makeInbox()
        inbox.receive([url("/vault/A.md"), url("/vault/A.md")])
        inbox.receive([url("/vault/A.md")])

        XCTAssertEqual(inbox.pending.count, 1)
    }

    func testPathsAreStandardisedOnTheWayIn() {
        let (inbox, _) = makeInbox()
        inbox.receive([url("/vault/folder/../A.md")])
        XCTAssertEqual(inbox.pending.first?.path, "/vault/A.md")
    }

    func testALocationThatIsNotAFileIsNotADocumentOpen() {
        // `application(_:open:)` carries whatever Launch Services was given.
        // A remote URL read as a file is a synchronous network fetch on the
        // main actor, which opening a note must never become.
        let (inbox, _) = makeInbox()
        inbox.receive([
            URL(string: "https://example.com/note.md")!,
            URL(string: "markdev://open?path=/etc/passwd")!,
            url("/vault/Real.md"),
        ])

        XCTAssertEqual(inbox.pending.map(\.lastPathComponent), ["Real.md"])
    }

    func testABatchIsBoundedAndSaysWhatItLeftOut() {
        // Selecting a folder's worth of notes and pressing Return is easy to
        // do by accident. Silently opening 32 of 60 would read as lost work.
        let (inbox, _) = makeInbox()
        let files = (0..<(DocumentInbox.limit + 12)).map { url("/vault/Note\($0).md") }
        inbox.receive(files)

        let request = inbox.drain()
        XCTAssertEqual(request.urls.count, DocumentInbox.limit)
        XCTAssertEqual(request.dropped, 12)
        XCTAssertEqual(
            request.truncationMessage,
            "Opened \(DocumentInbox.limit) files; 12 more were not opened.")
    }

    func testTheDroppedCountSurvivesBeingHandedOver() {
        // The count used to be cleared by the same call that handed over the
        // files, so the caller always read zero and never mentioned it.
        let (inbox, _) = makeInbox()
        inbox.receive((0..<(DocumentInbox.limit + 3)).map { url("/vault/N\($0).md") })

        var delivered: DocumentOpenRequest?
        inbox.register(readiness: { .frontmost }, deliver: { delivered = $0; return true })

        XCTAssertEqual(delivered?.dropped, 3)
        XCTAssertNotNil(delivered?.truncationMessage)
    }

    func testAnUntruncatedBatchHasNothingToSay() {
        let request = DocumentOpenRequest(urls: [url("/a.md")])
        XCTAssertNil(request.truncationMessage)
    }

    func testDrainingLeavesTheInboxEmpty() {
        let (inbox, _) = makeInbox()
        inbox.receive([url("/a.md")])
        _ = inbox.drain()

        XCTAssertTrue(inbox.pending.isEmpty)
        XCTAssertEqual(inbox.dropped, 0)
        XCTAssertTrue(inbox.drain().isEmpty)
    }

    // MARK: - Bounds

    func testRegistrationsThatNeverWithdrawCannotGrowWithoutBound() {
        let (inbox, _) = makeInbox()
        let leaked = (0..<(DocumentInbox.maximumSurfaces * 2)).map {
            _ in FakeSurface(readiness: .preparing)
        }
        for surface in leaked { surface.register(with: inbox) }

        XCTAssertLessThanOrEqual(inbox.surfaceCount, DocumentInbox.maximumSurfaces)
    }

    func testAWindowOnScreenIsNeverEvictedByLeakedRegistrations() {
        let (inbox, _) = makeInbox()
        let onScreen = FakeSurface(readiness: .frontmost)
        onScreen.register(with: inbox)
        let leaked = (0..<(DocumentInbox.maximumSurfaces * 2)).map {
            _ in FakeSurface(readiness: .preparing)
        }
        for surface in leaked { surface.register(with: inbox) }

        inbox.receive([url("/vault/Note.md")])
        XCTAssertEqual(onScreen.names, ["Note.md"])
    }

    // MARK: - Randomised

    func testNoRequestIsEverLostOrDuplicated() {
        // Windows opening, closing, going behind one another and being
        // discarded while files arrive. Every distinct file must be delivered
        // exactly once, or still be in the queue waiting for a window.
        var generator = SeededGenerator(seed: 0xF11E_B0)
        let (inbox, clock) = makeInbox()
        inbox.windowProvider = {}

        var delivered: [String] = []
        var sent: Set<String> = []
        var live: [FakeSurface] = []

        func makeSurface(_ readiness: DocumentSurfaceReadiness) -> FakeSurface {
            let surface = FakeSurface(readiness: readiness)
            surface.token = inbox.register(
                readiness: { [weak surface] in surface?.readiness ?? .gone },
                deliver: { [weak surface] request in
                    guard let surface, surface.accepts, surface.readiness >= .background
                    else { return false }
                    delivered.append(contentsOf: request.urls.map(\.path))
                    return true
                })
            return surface
        }

        for step in 0..<3000 {
            switch Int.random(in: 0..<8, using: &generator) {
            case 0:
                live.append(makeSurface(.frontmost))
            case 1:
                live.append(makeSurface(.preparing))
            case 2 where !live.isEmpty:
                let victim = live.removeFirst()
                victim.unregister(from: inbox)
            case 3 where !live.isEmpty:
                // A window closing without withdrawing.
                live[Int.random(in: 0..<live.count, using: &generator)].readiness = .gone
            case 4 where !live.isEmpty:
                let index = Int.random(in: 0..<live.count, using: &generator)
                live[index].readiness = Bool.random(using: &generator) ? .background : .frontmost
            case 5:
                clock.fire()
            default:
                let path = "/vault/N\(step).md"
                sent.insert(path)
                inbox.receive([url(path)])
            }
        }

        // Whatever is still queued goes to a window that is definitely there.
        for surface in live { surface.unregister(from: inbox) }
        let final = FakeSurface()
        final.token = inbox.register(
            readiness: { .frontmost },
            deliver: { request in
                delivered.append(contentsOf: request.urls.map(\.path))
                return true
            })

        XCTAssertTrue(inbox.pending.isEmpty, "nothing may be left stranded")
        XCTAssertEqual(Set(delivered).count, delivered.count, "a file was delivered twice")
        XCTAssertEqual(
            Set(delivered), sent, "every file sent should have been delivered exactly once")
    }
}

// MARK: - Readiness

@MainActor
final class DocumentSurfaceTests: XCTestCase {
    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        // `close()` on a window created this way otherwise deallocates it out
        // from under the test's own reference.
        window.isReleasedWhenClosed = false
        return window
    }

    func testASurfaceWithNoWindowYetIsWorthWaitingFor() {
        let surface = DocumentSurface()
        XCTAssertEqual(surface.readiness, .preparing)
        XCTAssertFalse(surface.canShowDocument)
    }

    func testAWindowThatHasNotBeenShownYetIsStillPreparing() {
        // What `onAppear` sees: the window exists and is not on screen. Read
        // as `gone`, this drops the registration of the window that is about
        // to appear — and the document then opens a second window beside it.
        let surface = DocumentSurface()
        surface.attach(makeWindow())
        XCTAssertEqual(surface.readiness, .preparing)
    }

    func testAVisibleWindowCanShowADocument() {
        let window = makeWindow()
        let surface = DocumentSurface()
        surface.attach(window)
        window.orderFront(nil)

        XCTAssertTrue(surface.canShowDocument)
        XCTAssertGreaterThanOrEqual(surface.readiness, .background)
    }

    func testAWindowThatHasBeenShownAndIsClosedIsGone() {
        // The failure this guards: a closed window read as "still on its way"
        // holds a document back forever, waiting for something already gone.
        let window = makeWindow()
        let surface = DocumentSurface()
        surface.attach(window)
        window.orderFront(nil)
        XCTAssertGreaterThanOrEqual(surface.readiness, .background)

        window.close()
        XCTAssertEqual(surface.readiness, .gone)
        XCTAssertFalse(surface.canShowDocument)
    }

    func testAMiniaturisedWindowIsNotGone() throws {
        // Not visible, and not lost either: it answers to being ordered front.
        // Read as gone, minimising the only window would open a second one on
        // the next double-click in Finder.
        let window = makeWindow()
        let surface = DocumentSurface()
        surface.attach(window)
        window.orderFront(nil)
        window.miniaturize(nil)

        guard window.isMiniaturized else {
            throw XCTSkip("the window server did not miniaturise the window")
        }
        XCTAssertEqual(surface.readiness, .background)
    }

    func testLeavingAWindowThatWasOnScreenIsGoneRatherThanPreparing() {
        let window = makeWindow()
        let surface = DocumentSurface()
        surface.attach(window)
        window.orderFront(nil)
        XCTAssertGreaterThanOrEqual(surface.readiness, .background)

        surface.attach(nil)
        XCTAssertEqual(surface.readiness, .gone)
    }

    func testAWindowClosedWithoutAnyoneLookingIsStillGone() {
        // Visibility is only sampled when the surface is asked. A window shown
        // and closed with no question in between must not report itself as a
        // window still on its way.
        let window = makeWindow()
        let surface = DocumentSurface()
        surface.attach(window)
        window.orderFront(nil)
        window.close()

        XCTAssertEqual(surface.readiness, .gone)
    }

    func testASurfaceDoesNotKeepItsWindowAlive() {
        // Weak on purpose: a registration naming a window must not be the
        // reason that window is still around.
        let surface = DocumentSurface()
        autoreleasepool {
            let window = makeWindow()
            surface.attach(window)
        }
        XCTAssertNil(surface.window)
        XCTAssertFalse(surface.canShowDocument)
    }

    func testBringingForwardAnAbsentWindowSaysSoRatherThanPretending() {
        let surface = DocumentSurface()
        XCTAssertFalse(surface.bringToFront())
    }
}
