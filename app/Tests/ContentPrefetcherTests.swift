//
//  ContentPrefetcherTests.swift
//  MarkDevKitTests
//
//  Warming the render cache: that it fills the cache the drawing path reads,
//  and that it stops before it can evict what is on screen.
//

import AppKit
import XCTest

@testable import MarkDevKit

@MainActor
final class ContentPrefetcherTests: XCTestCase {
    private func context(width: CGFloat = 600) -> RenderContext {
        RenderContext(width: width, dark: false, mathFontSize: 16, textColor: .black)
    }

    private func math(_ latex: String) -> RenderedBlock {
        RenderedBlock(kind: .math, source: latex)
    }

    /// Drains a warm without waiting on a clock.
    ///
    /// Bounded: a `step()` that returned "more work" forever would otherwise
    /// hang the suite rather than fail it.
    @discardableResult
    private func drain(_ prefetcher: ContentPrefetcher, limit: Int = 200) -> Int {
        var steps = 0
        while prefetcher.step() {
            steps += 1
            if steps >= limit { XCTFail("a warm did not finish"); break }
        }
        return steps
    }

    // MARK: - What a warm produces

    func testWarmingRendersBlocksTheReaderHasNotReached() {
        let renderer = RichContentRenderer()
        let prefetcher = ContentPrefetcher(renderer: renderer)
        let blocks = [math("a^2"), math("b^2"), math("c^2")]

        for block in blocks {
            XCTAssertFalse(
                renderer.isCached(RenderRequest(block: block, directory: nil, context: context())),
                "nothing should be cached before the warm")
        }

        prefetcher.warmDocument(blocks, in: nil, using: context())
        drain(prefetcher)

        XCTAssertEqual(prefetcher.warmed, 3)
        for block in blocks {
            XCTAssertTrue(
                renderer.isCached(RenderRequest(block: block, directory: nil, context: context())),
                "a warmed block must be a cache hit when the fragment asks")
        }
    }

    func testAWarmedBlockIsTheEntryTheDrawingPathAsksFor() {
        // The whole design rests on this: the warm is not a second store that
        // has to be kept in step with the renderer's, it *is* the renderer's.
        let renderer = RichContentRenderer()
        let prefetcher = ContentPrefetcher(renderer: renderer)
        let block = math("\\frac{1}{2}")

        prefetcher.warmDocument([block], in: nil, using: context())
        drain(prefetcher)
        let afterWarm = renderer.cachedPixels

        let request = RenderRequest(block: block, directory: nil, context: context())
        guard case .success = renderer.render(request) else {
            return XCTFail("the fragment path should be served the warmed bitmap")
        }
        XCTAssertEqual(
            renderer.cachedPixels, afterWarm,
            "drawing a warmed block must add nothing: it was already there")
    }

    func testABlockAlreadyCachedCostsNoStep() {
        // A re-warm after a keystroke re-states the whole document. On a note
        // the reader has scrolled through, nearly every entry is already
        // there, and paying a runloop hop each would make the warm the stall.
        let renderer = RichContentRenderer()
        let prefetcher = ContentPrefetcher(renderer: renderer)
        let seen = math("x + 1")
        let fresh = math("y + 1")
        _ = renderer.render(RenderRequest(block: seen, directory: nil, context: context()))

        prefetcher.warmDocument([seen, fresh], in: nil, using: context())

        XCTAssertFalse(prefetcher.step(), "one step should exhaust a queue of one uncached block")
        XCTAssertEqual(prefetcher.warmed, 1)
    }

    // MARK: - Order

    func testTheOpenDocumentIsWarmedBeforeTheNotesItLinksTo() {
        let renderer = RichContentRenderer()
        let prefetcher = ContentPrefetcher(renderer: renderer)
        let linked = math("\\alpha")
        let open = math("\\beta")

        // Queued in the wrong order on purpose: priority, not arrival, decides.
        prefetcher.warmDocument([open], in: nil, using: context())
        prefetcher.warmConnected([linked], in: URL(fileURLWithPath: "/tmp"))
        prefetcher.step()

        XCTAssertTrue(
            renderer.isCached(RenderRequest(block: open, directory: nil, context: context())),
            "the document on screen comes first")
        XCTAssertFalse(
            renderer.isCached(
                RenderRequest(
                    block: linked, directory: URL(fileURLWithPath: "/tmp"), context: context())),
            "a linked note waits until the open one is done")
    }

    func testConnectedNotesAreNotWarmedBeforeADocumentHasSaidHowItRenders() {
        // Guessing a width would fill the cache with entries that miss: the
        // key includes it, so a bitmap made at the wrong one is never read.
        let prefetcher = ContentPrefetcher(renderer: RichContentRenderer())
        prefetcher.warmConnected([math("\\gamma")], in: URL(fileURLWithPath: "/tmp"))

        XCTAssertFalse(prefetcher.hasWork)
        XCTAssertFalse(prefetcher.step())
    }

    // MARK: - Bounds

    func testAFullCacheStopsTheWarmRatherThanEvictingWhatIsOnScreen() {
        // The renderer evicts oldest-first, so a warm that ignored the budget
        // would push out exactly the bitmaps being drawn to make room for ones
        // that are not.
        let renderer = RichContentRenderer(pixelBudget: 1)
        let prefetcher = ContentPrefetcher(renderer: renderer)
        // One rendered block puts the cache over a one-pixel budget.
        _ = renderer.render(RenderRequest(block: math("z"), directory: nil, context: context()))
        XCTAssertGreaterThan(renderer.cachedPixels, prefetcher.ceiling(for: .document))

        prefetcher.warmDocument([math("p"), math("q")], in: nil, using: context())
        drain(prefetcher)

        XCTAssertEqual(prefetcher.warmed, 0, "nothing should be warmed over the ceiling")
        XCTAssertEqual(prefetcher.declined, 2, "and the whole queue is dropped, not retried")
        XCTAssertFalse(
            renderer.isCached(RenderRequest(block: math("p"), directory: nil, context: context())))
    }

    func testConnectedNotesGetASmallerShareThanTheOpenDocument() {
        let prefetcher = ContentPrefetcher(renderer: RichContentRenderer())
        XCTAssertLessThan(
            prefetcher.ceiling(for: .connected), prefetcher.ceiling(for: .document),
            "a guess about the next note must not crowd out the one being read")
    }

    func testAPathologicalSourceIsLeftToTheOnDemandPath() {
        // The cache bounds a bitmap's size; nothing bounds how long a diagram
        // takes to lay out. A warm declines the outliers — where the reader
        // has not asked for the picture — and the on-demand path still draws
        // them where they have.
        let renderer = RichContentRenderer()
        let prefetcher = ContentPrefetcher(renderer: renderer)
        let huge = RenderedBlock(
            kind: .diagram,
            source: "graph TD\n" + String(repeating: "A-->B\n", count: 8_000))
        XCTAssertGreaterThan(huge.source.utf16.count, ContentPrefetcher.maximumSourceLength)

        prefetcher.warmDocument([huge], in: nil, using: context())
        drain(prefetcher)

        XCTAssertEqual(prefetcher.warmed, 0)
        XCTAssertEqual(prefetcher.declined, 1)
    }

    func testTheConnectedQueueIsBounded() {
        // Connected batches accumulate — one per linked note — where a
        // document batch replaces. Without a ceiling, one note holding a
        // thousand diagrams would leave the queue trailing the reader for the
        // rest of the session.
        let prefetcher = ContentPrefetcher(renderer: RichContentRenderer())
        prefetcher.warmDocument([], in: nil, using: context())
        let many = (0..<(ContentPrefetcher.maximumConnectedQueue + 50)).map {
            math("q_{\($0)}")
        }

        prefetcher.warmConnected(many, in: URL(fileURLWithPath: "/tmp"))

        XCTAssertEqual(prefetcher.declined, 50, "and it says what it dropped")
        var steps = 0
        while prefetcher.step() { steps += 1 }
        XCTAssertLessThanOrEqual(
            prefetcher.warmed, ContentPrefetcher.maximumConnectedQueue)
    }

    // MARK: - Lifetime

    func testCancellingDropsEverythingQueued() {
        let prefetcher = ContentPrefetcher(renderer: RichContentRenderer())
        prefetcher.warmDocument([math("1"), math("2"), math("3")], in: nil, using: context())
        XCTAssertTrue(prefetcher.hasWork)

        prefetcher.cancel()

        XCTAssertFalse(prefetcher.hasWork)
        XCTAssertFalse(prefetcher.step())
    }

    func testASecondDocumentReplacesTheFirstQueueRatherThanAddingToIt() {
        // The caller re-states its whole list whenever the parse, the column
        // or the appearance changes; the superseded list describes a document
        // or a geometry that no longer applies.
        let renderer = RichContentRenderer()
        let prefetcher = ContentPrefetcher(renderer: renderer)
        prefetcher.warmDocument([math("old")], in: nil, using: context())
        prefetcher.warmDocument([math("new")], in: nil, using: context())
        drain(prefetcher)

        XCTAssertEqual(prefetcher.warmed, 1)
        XCTAssertFalse(
            renderer.isCached(
                RenderRequest(block: math("old"), directory: nil, context: context())))
    }

    func testAWarmDrivesItselfToCompletion() async throws {
        // The step-by-step tests drive `step()` by hand. This one proves the
        // driver actually runs: without it the queue would simply sit there.
        let renderer = RichContentRenderer()
        let prefetcher = ContentPrefetcher(renderer: renderer)
        let block = math("\\sqrt{2}")

        prefetcher.warmDocument([block], in: nil, using: context())
        let deadline = Date().addingTimeInterval(5)
        while prefetcher.hasWork, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertFalse(prefetcher.hasWork, "the driver should have drained the queue")
        XCTAssertTrue(
            renderer.isCached(RenderRequest(block: block, directory: nil, context: context())))
    }
}
