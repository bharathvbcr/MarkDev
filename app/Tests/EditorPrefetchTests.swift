//
//  EditorPrefetchTests.swift
//  MarkDevKitTests
//
//  What the editor asks to have warmed, and when it asks again.
//

import AppKit
import XCTest

@testable import MarkDevKit

@MainActor
final class EditorPrefetchTests: XCTestCase {
    /// A view with its own renderer and prefetcher.
    ///
    /// Separate from the shared ones on purpose: an entry in *this* renderer
    /// can only have got there through the warm, since the view's own drawing
    /// path fills ``RichContentRenderer/shared``. That is what makes "warmed
    /// without being drawn" an assertion rather than a hope.
    private func hostedEditor(width: CGFloat = 600) -> (
        MarkdownTextView, NSWindow, ContentPrefetcher, RichContentRenderer
    ) {
        let renderer = RichContentRenderer()
        let prefetcher = ContentPrefetcher(renderer: renderer)
        let view = MarkdownTextView.make()
        view.contentPrefetcher = prefetcher
        let scrollView = ScrollingTextView.scrollView(hosting: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 300),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        scrollView.frame = NSRect(x: 0, y: 0, width: width, height: 300)
        scrollView.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(scrollView)
        return (view, window, prefetcher, renderer)
    }

    private func layout(_ view: MarkdownTextView, _ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        view.textLayoutManager?.textViewportLayoutController.layoutViewport()
    }

    private func drain(_ prefetcher: ContentPrefetcher, limit: Int = 200) {
        var steps = 0
        while prefetcher.step() {
            steps += 1
            if steps >= limit { return XCTFail("a warm did not finish") }
        }
    }

    /// A document far taller than the viewport, with a formula every few
    /// paragraphs. TextKit lays out only what is visible, so the ones at the
    /// foot of it are never resolved by the drawing path.
    private func documentWithFormulas(_ count: Int) -> String {
        var text = "Opening paragraph, so the caret does not sit in a formula.\n\n"
        for index in 0..<count {
            text += String(repeating: "Filler paragraph text.\n\n", count: 6)
            text += "$$\nx_{\(index)} = \\frac{\(index)}{2}\n$$\n\n"
        }
        return text
    }

    private func formula(_ index: Int) -> RenderedBlock {
        RenderedBlock(kind: .math, source: "x_{\(index)} = \\frac{\(index)}{2}")
    }

    // MARK: - What is warmed

    func testOpeningADocumentWarmsPicturesThatAreNotOnScreen() {
        let (view, window, prefetcher, renderer) = hostedEditor()
        view.setMarkdown(documentWithFormulas(6))
        layout(view, window)

        drain(prefetcher)

        let last = RenderRequest(block: formula(5), directory: nil, context: view.renderContext)
        XCTAssertTrue(
            renderer.isCached(last),
            "the formula at the foot of the document should be drawn before it is reached")
        XCTAssertEqual(prefetcher.warmed, 6, "every formula, not only the visible ones")
    }

    func testTheWarmUsesTheSameContextTheFragmentsWillAskWith() {
        // The cache is keyed on width, appearance and ink. A warm built from a
        // second, subtly different derivation would not draw anything wrong —
        // it would quietly make every warmed entry a miss.
        let (view, window, prefetcher, renderer) = hostedEditor()
        view.setMarkdown(documentWithFormulas(2))
        layout(view, window)
        drain(prefetcher)

        XCTAssertEqual(prefetcher.documentContext, view.renderContext)
        XCTAssertTrue(
            renderer.isCached(
                RenderRequest(block: formula(0), directory: nil, context: view.renderContext)))
    }

    // MARK: - When it asks again

    func testAnUnchangedDocumentIsNotWarmedTwice() {
        // `prefetchRenderedContent` hangs off `viewWillDraw`, which runs on
        // every frame of a scroll. Rebuilding the request list there would put
        // an O(document) walk on the scroll path.
        let (view, window, prefetcher, _) = hostedEditor()
        view.setMarkdown(documentWithFormulas(3))
        layout(view, window)
        drain(prefetcher)
        let afterFirst = prefetcher.warmed

        view.viewWillDraw()
        view.layout()
        drain(prefetcher)

        XCTAssertEqual(prefetcher.warmed, afterFirst, "nothing changed, so nothing to warm")
        XCTAssertFalse(prefetcher.hasWork)
    }

    func testAWiderColumnIsWarmedAgain() {
        // Not busywork: the render cache is keyed on the width, so after a
        // resize every entry warmed at the old one is a miss.
        let (view, window, prefetcher, renderer) = hostedEditor(width: 500)
        view.setMarkdown("Opening line.\n\n```mermaid\ngraph TD\nA-->B\n```\n")
        layout(view, window)
        drain(prefetcher)
        let narrow = view.renderContext

        window.setContentSize(NSSize(width: 900, height: 300))
        layout(view, window)
        drain(prefetcher)

        XCTAssertNotEqual(view.renderContext.width, narrow.width, "the column really changed")
        let diagram = RenderedBlock(kind: .diagram, source: "graph TD\nA-->B")
        XCTAssertTrue(
            renderer.isCached(
                RenderRequest(block: diagram, directory: nil, context: view.renderContext)),
            "the wider column has its own bitmap, and it should be warmed too")
    }

    func testReplacingTheDocumentDropsTheWarmForTheOldOne() {
        let (view, window, prefetcher, renderer) = hostedEditor()
        view.setMarkdown(documentWithFormulas(8))
        layout(view, window)
        prefetcher.step()

        view.setMarkdown("A note with nothing to draw in it.\n")
        layout(view, window)

        XCTAssertFalse(
            prefetcher.hasWork,
            "the queue described a document that is no longer open")
        XCTAssertFalse(
            renderer.isCached(
                RenderRequest(block: formula(7), directory: nil, context: view.renderContext)))
    }

    func testEditingWarmsWhatTheEditIntroduced() {
        let (view, window, prefetcher, renderer) = hostedEditor()
        view.setMarkdown("Opening line.\n\n")
        layout(view, window)
        drain(prefetcher)

        view.setMarkdown("Opening line.\n\n$$\na + b\n$$\n")
        layout(view, window)
        drain(prefetcher)

        XCTAssertTrue(
            renderer.isCached(
                RenderRequest(
                    block: RenderedBlock(kind: .math, source: "a + b"),
                    directory: nil, context: view.renderContext)))
    }

    // MARK: - Where it declines

    func testAViewWithNoWindowDoesNotSpendTheBudget() {
        // A view built to measure something has no reader whose scroll needs
        // smoothing, and the cache's budget belongs to the windows that do.
        let renderer = RichContentRenderer()
        let prefetcher = ContentPrefetcher(renderer: renderer)
        let view = MarkdownTextView.make()
        view.contentPrefetcher = prefetcher

        view.setMarkdown(documentWithFormulas(4))

        XCTAssertFalse(prefetcher.hasWork)
        XCTAssertEqual(prefetcher.warmed, 0)
    }

    func testADocumentThatStopsHavingPicturesClearsTheQueue() {
        // The queue would otherwise go on warming what the reader has just
        // deleted — and, worse, would hold the view's record of what it warmed
        // at a set the document no longer contains.
        let (view, window, prefetcher, _) = hostedEditor()
        view.setMarkdown(documentWithFormulas(6))
        layout(view, window)
        prefetcher.step()
        XCTAssertTrue(prefetcher.hasWork)

        // An edit, not a replacement: `setMarkdown` cancels the queue outright,
        // which would prove nothing about the path a reader actually takes.
        view.setSelectedRange(NSRange(location: 0, length: (view.markdown as NSString).length))
        view.insertText("Opening paragraph, and nothing else.\n", replacementRange: view.selectedRange())
        layout(view, window)

        XCTAssertFalse(prefetcher.hasWork)
    }

    func testADocumentWithNoPicturesQueuesNothing() {
        let (view, window, prefetcher, _) = hostedEditor()
        view.setMarkdown("# Prose\n\nJust words, a `code span`, and a [link](x.md).\n")
        layout(view, window)

        XCTAssertFalse(prefetcher.hasWork)
    }
}
