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

private final class ImageFileOpenCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func open(
        _ url: URL,
        maximumBytes: Int
    ) throws -> MarkDevKit.BoundedRegularFileLease {
        lock.lock()
        calls += 1
        lock.unlock()
        return try MarkDevKit.BoundedRegularFileReader.open(
            url,
            maximumBytes: maximumBytes,
            cancellationCheck: { false })
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func reset() {
        lock.lock()
        calls = 0
        lock.unlock()
    }
}

@MainActor
final class ContentPrefetcherTests: XCTestCase {
    private func context(width: CGFloat = 600, dark: Bool = false) -> RenderContext {
        RenderContext(width: width, dark: dark, mathFontSize: 16, textColor: .black)
    }

    private func math(_ latex: String) -> RenderedBlock {
        RenderedBlock(kind: .math, source: latex)
    }

    private func image(_ source: String) -> RenderedBlock {
        RenderedBlock(kind: .image(alt: ""), source: source)
    }

    private func imageDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevPrefetchImages-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func writeSVG(_ name: String, to directory: URL) throws {
        try """
            <svg xmlns="http://www.w3.org/2000/svg" width="32" height="16" \
            viewBox="0 0 32 16"><rect width="32" height="16" fill="black"/></svg>
            """.write(
                to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
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

    func testOneStepExaminesAtMostOneCachedImageRequest() throws {
        // An image cache probe opens and identifies a file generation. It is
        // therefore file I/O even on a hit, and a run of hits must not turn
        // one main-actor step into an unbounded directory walk.
        let directory = try imageDirectory()
        try writeSVG("first.svg", to: directory)
        try writeSVG("second.svg", to: directory)
        let first = image("first.svg")
        let second = image("second.svg")
        let fresh = math("not\\;warmed")
        let renderContext = context()
        let opens = ImageFileOpenCounter()
        let renderer = RichContentRenderer(imageFileOpener: opens.open)

        for block in [first, second] {
            guard case .success = renderer.render(
                RenderRequest(block: block, directory: directory, context: renderContext))
            else { return XCTFail("the image fixture should be cached before the warm") }
        }

        let prefetcher = ContentPrefetcher(renderer: renderer)
        prefetcher.warmDocument([first, second, fresh], in: directory, using: renderContext)
        opens.reset()

        XCTAssertTrue(prefetcher.step(), "the second image and formula should remain queued")
        XCTAssertEqual(opens.count, 1, "one cached-image step may open exactly one descriptor")
        XCTAssertEqual(prefetcher.warmed, 0)
        XCTAssertFalse(
            renderer.isCached(
                RenderRequest(block: fresh, directory: directory, context: renderContext)),
            "one step must not walk past a cached image to render later work")

        XCTAssertTrue(prefetcher.step(), "the formula should remain after the second image")
        XCTAssertEqual(opens.count, 2, "the second step may inspect only the second image")
        XCTAssertEqual(prefetcher.warmed, 0)
        XCTAssertFalse(prefetcher.step(), "the third step should render the final formula")
        XCTAssertEqual(opens.count, 2, "a dictionary-only formula must perform no file I/O")
        XCTAssertEqual(prefetcher.warmed, 1)
    }

    func testOneStepRendersOneFreshImageWithoutTouchingTheNextRequest() throws {
        let directory = try imageDirectory()
        try writeSVG("fresh.svg", to: directory)
        let freshImage = image("fresh.svg")
        let laterMath = math("later")
        let renderContext = context()
        let opens = ImageFileOpenCounter()
        let renderer = RichContentRenderer(imageFileOpener: opens.open)
        let prefetcher = ContentPrefetcher(renderer: renderer)

        prefetcher.warmDocument(
            [freshImage, laterMath], in: directory, using: renderContext)

        XCTAssertTrue(prefetcher.step(), "the formula must remain queued after one image render")
        XCTAssertEqual(prefetcher.warmed, 1)
        XCTAssertEqual(
            opens.count,
            2,
            "a fresh image performs one generation probe and one retained-descriptor render")
        XCTAssertFalse(
            renderer.isCached(
                RenderRequest(
                    block: laterMath,
                    directory: directory,
                    context: renderContext)),
            "the image step must not render the following request")

        XCTAssertFalse(prefetcher.step())
        XCTAssertEqual(prefetcher.warmed, 2)
        XCTAssertEqual(opens.count, 2)
    }

    func testOneStepBoundsCheapCacheProbesBeforeRenderingFreshWork() {
        // Dictionary probes are cheaper than image-generation probes, but a
        // document can still contain thousands. One main-actor turn must have
        // a finite inspection quantum rather than walking all of them.
        let cached = (0..<ContentPrefetcher.maximumInspectionsPerStep).map {
            math("cached_{\($0)}")
        }
        let fresh = math("fresh")
        let renderContext = context()
        let renderer = RichContentRenderer()
        for block in cached {
            guard case .success = renderer.render(
                RenderRequest(block: block, directory: nil, context: renderContext))
            else { return XCTFail("the math fixture should be cached before the warm") }
        }

        let prefetcher = ContentPrefetcher(renderer: renderer)
        prefetcher.warmDocument(cached + [fresh], in: nil, using: renderContext)

        XCTAssertTrue(
            prefetcher.step(),
            "the fresh tail must remain after one bounded cache-scan quantum")
        XCTAssertEqual(prefetcher.warmed, 0)
        XCTAssertFalse(
            renderer.isCached(
                RenderRequest(block: fresh, directory: nil, context: renderContext)))

        XCTAssertFalse(prefetcher.step(), "the next turn may render the fresh tail")
        XCTAssertEqual(prefetcher.warmed, 1)
        XCTAssertTrue(
            renderer.isCached(
                RenderRequest(block: fresh, directory: nil, context: renderContext)))
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

    func testSourceAdmissionRunsBeforeAnImageCacheProbe() {
        // `isCached` for an image opens a descriptor to bind the cache hit to a
        // file generation. An over-limit source is already declined, so doing
        // that I/O first defeats both the source bound and per-step work bound.
        let opens = ImageFileOpenCounter()
        let renderer = RichContentRenderer(imageFileOpener: opens.open)
        let prefetcher = ContentPrefetcher(renderer: renderer)
        let source = String(
            repeating: "a", count: ContentPrefetcher.maximumSourceLength + 1) + ".png"

        prefetcher.warmDocument([image(source)], in: URL(fileURLWithPath: "/tmp"), using: context())

        XCTAssertFalse(prefetcher.step())
        XCTAssertEqual(prefetcher.declined, 1)
        XCTAssertEqual(opens.count, 0, "a declined source must perform no file-system probe")
    }

    func testTheDocumentQueueIsBoundedAndDrainsExactlyItsAdmittedCap() {
        let renderer = RichContentRenderer()
        let prefetcher = ContentPrefetcher(renderer: renderer)
        let overflow = 37
        let blocks = (0..<(ContentPrefetcher.maximumDocumentQueue + overflow)).map {
            RenderedBlock(kind: .htmlComment, source: "hidden-\($0)")
        }

        prefetcher.warmDocument(blocks, in: nil, using: context())

        XCTAssertEqual(prefetcher.declined, overflow, "the rejected tail must be observable")
        for _ in 0..<ContentPrefetcher.maximumDocumentQueue {
            _ = prefetcher.step()
        }
        XCTAssertEqual(prefetcher.warmed, ContentPrefetcher.maximumDocumentQueue)
        XCTAssertFalse(prefetcher.hasWork, "only the admitted prefix may enter the queue")
    }

    func testQueueStorageDoesNotShiftAnArrayTailForEveryDequeue() throws {
        // This is a structural complexity contract. A wall-clock benchmark is
        // too machine-dependent to distinguish an indexed FIFO from Array's
        // quadratic repeated front-removal reliably.
        let production = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("MarkDevKit/Editor/ContentPrefetcher.swift")
        let source = try String(contentsOf: production, encoding: .utf8)
        XCTAssertNil(
            source.range(
                of: #"\bqueue\.removeFirst\s*\("#,
                options: .regularExpression),
            "front-removing Array shifts the remaining queue on every step")
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

    // MARK: - Multiple panes

    func testOneOwnerReplacingAndCancellingItsDocumentLeavesTheOtherOwnerQueued() {
        let renderer = RichContentRenderer()
        let prefetcher = ContentPrefetcher(renderer: renderer)
        let firstOwner = ContentPrefetcher.Owner()
        let secondOwner = ContentPrefetcher.Owner()
        let oldFirst = math("old_first")
        let newFirst = math("new_first")
        let second = math("second_survives")
        let renderContext = context()

        prefetcher.warmDocument(
            [oldFirst], owner: firstOwner, in: nil, using: renderContext)
        prefetcher.warmDocument(
            [second], owner: secondOwner, in: nil, using: renderContext)
        prefetcher.warmDocument(
            [newFirst], owner: firstOwner, in: nil, using: renderContext)
        prefetcher.cancel(owner: firstOwner)

        XCTAssertTrue(prefetcher.hasWork, "cancelling one pane must not strand another pane")
        drain(prefetcher)

        XCTAssertEqual(prefetcher.warmed, 1)
        XCTAssertTrue(
            renderer.isCached(
                RenderRequest(block: second, directory: nil, context: renderContext)))
        for cancelled in [oldFirst, newFirst] {
            XCTAssertFalse(
                renderer.isCached(
                    RenderRequest(block: cancelled, directory: nil, context: renderContext)))
        }
    }

    func testDocumentOwnersMakeFairProgressAtTheSamePriority() {
        let renderer = RichContentRenderer()
        let prefetcher = ContentPrefetcher(renderer: renderer)
        let firstOwner = ContentPrefetcher.Owner()
        let secondOwner = ContentPrefetcher.Owner()
        let first = (0..<8).map { math("first_{\($0)}") }
        let second = math("second_gets_a_turn")
        let renderContext = context()

        prefetcher.warmDocument(first, owner: firstOwner, in: nil, using: renderContext)
        prefetcher.warmDocument([second], owner: secondOwner, in: nil, using: renderContext)

        _ = prefetcher.step()
        _ = prefetcher.step()

        XCTAssertTrue(
            renderer.isCached(
                RenderRequest(block: second, directory: nil, context: renderContext)),
            "one pane must not monopolize document-priority turns")
        XCTAssertTrue(prefetcher.hasWork, "the first pane should retain its remaining work")
    }

    func testConnectedWarmUsesTheContextBelongingToItsOwner() {
        let renderer = RichContentRenderer()
        let prefetcher = ContentPrefetcher(renderer: renderer)
        let narrowOwner = ContentPrefetcher.Owner()
        let wideOwner = ContentPrefetcher.Owner()
        let narrowContext = context(width: 320, dark: false)
        let wideContext = context(width: 880, dark: true)
        let narrowBlock = math("narrow_connected")
        let wideBlock = math("wide_connected")
        let directory = URL(fileURLWithPath: "/tmp")

        prefetcher.warmDocument([], owner: narrowOwner, in: nil, using: narrowContext)
        prefetcher.warmDocument([], owner: wideOwner, in: nil, using: wideContext)
        prefetcher.warmConnected([narrowBlock], owner: narrowOwner, in: directory)
        prefetcher.warmConnected([wideBlock], owner: wideOwner, in: directory)
        drain(prefetcher)

        XCTAssertTrue(
            renderer.isCached(
                RenderRequest(block: narrowBlock, directory: directory, context: narrowContext)))
        XCTAssertTrue(
            renderer.isCached(
                RenderRequest(block: wideBlock, directory: directory, context: wideContext)))
        XCTAssertFalse(
            renderer.isCached(
                RenderRequest(block: narrowBlock, directory: directory, context: wideContext)),
            "a connected warm must not borrow another pane's width or appearance")
        XCTAssertFalse(
            renderer.isCached(
                RenderRequest(block: wideBlock, directory: directory, context: narrowContext)),
            "a connected warm must retain its own pane context")
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
