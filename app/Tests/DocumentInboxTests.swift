//
//  DocumentInboxTests.swift
//  MarkDevKitTests
//
//  Opening a file from Finder — including the ordering that broke it twice.
//

import XCTest

@testable import MarkDevKit

@MainActor
final class DocumentInboxTests: XCTestCase {
    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    // MARK: - Ordering

    func testAFileThatArrivesBeforeAnyWindowIsStillOpened() {
        // The case that made a double-click show an empty untitled window:
        // Launch Services delivers the open request *before*
        // `applicationDidFinishLaunching`, so before any workspace exists.
        let inbox = DocumentInbox()
        inbox.receive([url("/vault/Note.md")])

        var received: [URL] = []
        inbox.setHandler { received = $0.urls }

        XCTAssertEqual(received.map(\.path), ["/vault/Note.md"])
        XCTAssertTrue(inbox.pending.isEmpty, "the backlog is handed over, not kept")
    }

    func testAFileThatArrivesAfterAWindowGoesStraightThrough() {
        let inbox = DocumentInbox()
        var received: [URL] = []
        inbox.setHandler { received.append(contentsOf: $0.urls) }

        inbox.receive([url("/vault/A.md")])
        inbox.receive([url("/vault/B.md")])

        XCTAssertEqual(received.map(\.lastPathComponent), ["A.md", "B.md"])
    }

    func testUnregisteringStopsDeliveryAndTheNextWindowGetsTheBacklog() {
        // A closing window must stop being handed documents, and whatever
        // arrives before the next one opens must not be lost.
        let inbox = DocumentInbox()
        var first: [URL] = []
        inbox.setHandler { first.append(contentsOf: $0.urls) }
        inbox.setHandler(nil)

        inbox.receive([url("/vault/Later.md")])
        XCTAssertTrue(first.isEmpty)
        XCTAssertEqual(inbox.pending.count, 1, "held for whoever comes next")

        var second: [URL] = []
        inbox.setHandler { second = $0.urls }
        XCTAssertEqual(second.map(\.lastPathComponent), ["Later.md"])
    }

    func testRegisteringWithNothingWaitingDeliversNothing() {
        // The old bug in miniature: a window appearing to an empty queue must
        // not fire a handler with an empty batch, or every launch looks like
        // an open request.
        let inbox = DocumentInbox()
        var calls = 0
        inbox.setHandler { _ in calls += 1 }
        XCTAssertEqual(calls, 0)
    }

    // MARK: - Contents

    func testDuplicateRequestsForTheSameFileAreCollapsed() {
        // Launch Services can deliver the same document twice when asked in
        // quick succession; two tabs for one file is not what was meant.
        let inbox = DocumentInbox()
        inbox.receive([url("/vault/A.md"), url("/vault/A.md")])
        inbox.receive([url("/vault/A.md")])

        XCTAssertEqual(inbox.pending.count, 1)
    }

    func testPathsAreStandardisedOnTheWayIn() {
        let inbox = DocumentInbox()
        inbox.receive([url("/vault/folder/../A.md")])
        XCTAssertEqual(inbox.pending.first?.path, "/vault/A.md")
    }

    func testABatchIsBoundedAndSaysWhatItLeftOut() {
        // Selecting a folder's worth of notes and pressing Return is easy to
        // do by accident. Silently opening 32 of 60 would read as lost work.
        let inbox = DocumentInbox()
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
        let inbox = DocumentInbox()
        inbox.receive((0..<(DocumentInbox.limit + 3)).map { url("/vault/N\($0).md") })

        var delivered: DocumentOpenRequest?
        inbox.setHandler { delivered = $0 }

        XCTAssertEqual(delivered?.dropped, 3)
        XCTAssertNotNil(delivered?.truncationMessage)
    }

    func testAnUntruncatedBatchHasNothingToSay() {
        let request = DocumentOpenRequest(urls: [url("/a.md")])
        XCTAssertNil(request.truncationMessage)
    }

    func testDrainingLeavesTheInboxEmpty() {
        let inbox = DocumentInbox()
        inbox.receive([url("/a.md")])
        _ = inbox.drain()

        XCTAssertTrue(inbox.pending.isEmpty)
        XCTAssertEqual(inbox.dropped, 0)
        XCTAssertTrue(inbox.drain().isEmpty)
    }

    // MARK: - Randomised

    func testNoRequestIsEverLostOrDuplicated() {
        // Handlers coming and going while files arrive, which is what window
        // open and close actually look like. Every distinct file must be
        // delivered exactly once, or land in the queue still waiting.
        var generator = SeededGenerator(seed: 0xF11E_B0)
        let inbox = DocumentInbox()
        var delivered: [String] = []
        var sent: Set<String> = []
        var hasHandler = false

        for step in 0..<3000 {
            switch Int.random(in: 0..<4, using: &generator) {
            case 0:
                hasHandler = true
                inbox.setHandler { delivered.append(contentsOf: $0.urls.map(\.path)) }
            case 1:
                hasHandler = false
                inbox.setHandler(nil)
            default:
                let path = "/vault/N\(step).md"
                sent.insert(path)
                inbox.receive([url(path)])
            }

            // Nothing is held once someone is listening.
            if hasHandler {
                XCTAssertTrue(
                    inbox.pending.isEmpty, "a registered handler should have drained step \(step)")
            }
        }

        inbox.setHandler { delivered.append(contentsOf: $0.urls.map(\.path)) }

        XCTAssertEqual(
            Set(delivered).count, delivered.count, "a file was delivered twice")
        XCTAssertEqual(
            Set(delivered), sent, "every file sent should have been delivered exactly once")
    }
}
