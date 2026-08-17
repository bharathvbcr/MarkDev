//
//  EditorScrollingTests.swift
//  MarkDevKitTests
//
//  Whether the editor scrolls at all, and whether it keeps scrolling once the
//  document or the window changes size under it.
//
//  Every assertion here is about geometry rather than about a scrolling call
//  returning: the failure this suite exists for is silent. When `maxSize` is
//  left at its zero-height default, `scrollRangeToVisible` succeeds, the
//  scroll view is correctly wired, the text lays out — and the document view
//  is simply never taller than the window, so nothing moves.
//

import AppKit
import SwiftUI
import XCTest

@testable import MarkDevKit

@MainActor
final class EditorScrollingTests: XCTestCase {

    // MARK: - Harness

    /// A text view in a scroll view in a window, laid out for real.
    ///
    /// The window is required, not incidental: a document view outside one
    /// never gets the layout pass that would expose a sizing bug.
    @MainActor
    private final class Harness {
        let textView: ScrollingTextView
        let scrollView: NSScrollView
        let window: NSWindow

        init(_ textView: ScrollingTextView, width: CGFloat = 600, height: CGFloat = 400) {
            self.textView = textView
            self.scrollView = ScrollingTextView.scrollView(hosting: textView)
            self.window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                styleMask: [.titled, .resizable],
                backing: .buffered,
                defer: false)
            window.contentView = scrollView
            settle()
        }

        /// Forces the layout the assertions read, including the full text
        /// layout TextKit 2 would otherwise defer to the visible viewport.
        ///
        /// The view hierarchy is laid out *first*: the text view takes its
        /// width from the clip view, so laying the text out before that
        /// happens measures it against the wrong column and reports a height
        /// for a wrap that is about to be thrown away.
        func settle() {
            window.layoutIfNeeded()
            if let manager = textView.textLayoutManager {
                manager.ensureLayout(for: manager.documentRange)
            }
            window.layoutIfNeeded()
        }

        func resize(width: CGFloat, height: CGFloat = 400) {
            window.setContentSize(NSSize(width: width, height: height))
            window.layoutIfNeeded()
            settle()
        }

        var viewportHeight: CGFloat { scrollView.contentView.bounds.height }
        var documentHeight: CGFloat { textView.frame.height }
        var scrollY: CGFloat { scrollView.documentVisibleRect.origin.y }
        var isScrollable: Bool { documentHeight > viewportHeight }

        func scrollToEnd() {
            let length = (textView.string as NSString).length
            textView.scrollRangeToVisible(NSRange(location: length, length: 0))
            settle()
        }
    }

    /// Comfortably longer than any viewport these tests use.
    private func longMarkdown(lines: Int = 600) -> String {
        (0..<lines)
            .map { "Paragraph \($0) with enough words in it to wrap at a narrow width.\n" }
            .joined(separator: "\n")
    }

    private func editor(_ markdown: String) -> MarkdownTextView {
        let view = MarkdownTextView.make()
        view.setMarkdown(markdown)
        return view
    }

    // MARK: - The contract itself

    func testTheWritingSurfaceIsAllowedToGrowBeyondItsInitialFrame() {
        // `NSTextView(frame:textContainer:)` takes `maxSize` from the frame it
        // is given. Built at `.zero` — the only sensible frame for a view
        // sized by its superview — that caps the document at zero height, and
        // `isVerticallyResizable` has nothing left to resize into.
        let view = MarkdownTextView.make()
        XCTAssertGreaterThan(
            view.maxSize.height, 1_000_000,
            "a zero-height maxSize pins the document to the viewport, so nothing can ever scroll")
        XCTAssertGreaterThan(view.maxSize.width, 1_000_000)
        XCTAssertTrue(view.isVerticallyResizable)
    }

    func testALongDocumentIsTallerThanItsViewport() {
        // The decisive symptom. Everything else about scrolling can be right
        // and the editor still will not move if this is false.
        let harness = Harness(editor(longMarkdown()))
        XCTAssertTrue(
            harness.isScrollable,
            """
            600 paragraphs laid out to \(harness.documentHeight)pt inside a \
            \(harness.viewportHeight)pt viewport — there is nothing to scroll
            """)
    }

    func testALongDocumentShowsAScroller() {
        let harness = Harness(editor(longMarkdown()))
        let scroller = harness.scrollView.verticalScroller
        XCTAssertNotNil(scroller)
        XCTAssertLessThan(
            scroller?.knobProportion ?? 1, 1,
            "a full-length knob means the scroll view believes the document fits")
    }

    func testScrollingToTheEndOfALongDocumentMovesTheViewport() {
        let harness = Harness(editor(longMarkdown()))
        XCTAssertEqual(harness.scrollY, 0, accuracy: 0.5, "should start at the top")

        harness.scrollToEnd()
        XCTAssertGreaterThan(
            harness.scrollY, harness.viewportHeight,
            "scrolling to the end of a 600-paragraph document must travel further than one screen")
    }

    func testRevealPutsTheRequestedOffsetOnScreen() {
        // The outline, backlinks, and wikilinks all arrive through `reveal`.
        // It reports nothing when it fails; the target simply stays off
        // screen.
        let markdown = longMarkdown() + "\n# The Last Heading\n"
        let view = editor(markdown)
        let harness = Harness(view)

        let target = (markdown as NSString).range(of: "# The Last Heading")
        XCTAssertNotEqual(target.location, NSNotFound)
        view.reveal(offset: target.location)
        harness.settle()

        XCTAssertTrue(
            isOnScreen(offset: target.location, in: harness),
            "revealing a heading near the end of the document must scroll it into view")
    }

    func testRevealClampsAnOffsetPastTheEndOfTheDocument() {
        // Offsets come from an index that may be a keystroke behind the text.
        let view = editor("# Short\n\nbody")
        let harness = Harness(view)
        view.reveal(offset: 10_000)
        harness.settle()
        XCTAssertEqual(view.selectedRange().location, (view.markdown as NSString).length)
        XCTAssertEqual(harness.scrollY, 0, accuracy: 0.5)
    }

    // MARK: - The surface fills its viewport

    func testAShortDocumentStillCoversItsViewport() {
        // Otherwise there is a dead strip below the last line where a click
        // lands on the clip view and the caret does not move.
        let harness = Harness(editor("# Title\n\nOne short paragraph.\n"))
        XCTAssertGreaterThanOrEqual(
            harness.documentHeight, harness.viewportHeight,
            "the writing surface must reach the bottom of the viewport")
        XCTAssertFalse(harness.isScrollable, "and must not invent scrollable space doing it")
    }

    func testAnEmptyDocumentCoversItsViewportWithoutScrolling() {
        let harness = Harness(editor(""))
        XCTAssertEqual(harness.documentHeight, harness.viewportHeight, accuracy: 0.5)
        XCTAssertEqual(harness.scrollY, 0, accuracy: 0.5)
    }

    // MARK: - The viewport stays inside the document

    func testReplacingALongDocumentWithAShortOneReturnsToTheTop() {
        // Switching tabs, following a wikilink, or an external edit all push a
        // new document through `setMarkdown` while the viewport is wherever
        // the reader left it. A viewport stranded past the new end paints an
        // empty editor holding a document that is plainly not empty.
        let view = editor(longMarkdown())
        let harness = Harness(view)
        harness.scrollToEnd()
        XCTAssertGreaterThan(harness.scrollY, 0, "precondition: scrolled away from the top")

        view.setMarkdown("# Short\n\nJust a couple of lines.\n")
        harness.settle()

        XCTAssertLessThanOrEqual(
            harness.scrollY, 0.5,
            "the viewport is showing \(harness.scrollY)pt of space the document no longer occupies")
    }

    func testDeletingMostOfADocumentDoesNotStrandTheViewport() {
        // The same shrink, reached by editing rather than by replacement —
        // select-all-and-delete, or undoing a large paste.
        let markdown = longMarkdown()
        let view = editor(markdown)
        let harness = Harness(view)
        harness.scrollToEnd()

        let length = (markdown as NSString).length
        view.setSelectedRange(NSRange(location: 20, length: length - 20))
        view.insertText("", replacementRange: view.selectedRange())
        harness.settle()

        XCTAssertLessThanOrEqual(harness.scrollY, 0.5)
        XCTAssertLessThanOrEqual(
            harness.scrollView.documentVisibleRect.maxY, harness.documentHeight + 0.5,
            "the viewport must not extend past the end of the document")
    }

    func testWideningTheWindowNeverLeavesTheViewportPastTheDocument() {
        // A wider window wraps fewer lines, so the document gets shorter while
        // the viewport stays where it was.
        let harness = Harness(editor(longMarkdown()), width: 400)
        harness.scrollToEnd()
        harness.resize(width: 1400)

        XCTAssertLessThanOrEqual(
            harness.scrollView.documentVisibleRect.maxY, harness.documentHeight + 0.5,
            "widening the window scrolled the viewport off the end of the document")
    }

    func testShrinkingTheWindowKeepsTheViewportInsideTheDocument() {
        let harness = Harness(editor(longMarkdown()), width: 1400)
        harness.scrollToEnd()
        harness.resize(width: 400)

        XCTAssertLessThanOrEqual(
            harness.scrollView.documentVisibleRect.maxY, harness.documentHeight + 0.5)
        XCTAssertGreaterThanOrEqual(harness.scrollY, 0)
    }

    // MARK: - Width tracks the viewport

    func testNarrowingTheViewportRewrapsRatherThanScrollingSideways() {
        let harness = Harness(editor(longMarkdown()), width: 900)
        let wideHeight = harness.documentHeight
        harness.resize(width: 400)

        XCTAssertEqual(
            harness.textView.frame.width, 400, accuracy: 1,
            "the document view must follow the viewport's width")
        XCTAssertEqual(
            harness.textView.textContainer?.size.width ?? 0,
            400 - harness.textView.textContainerInset.width * 2,
            accuracy: 1,
            "the text container must follow the view, or lines keep their old wrap points")
        XCTAssertGreaterThan(
            harness.documentHeight, wideHeight,
            "a narrower column wraps more lines and must therefore be taller")
        XCTAssertFalse(harness.textView.isHorizontallyResizable)
    }

    // MARK: - Shared by every surface

    func testThePlainScrollingSurfaceSharesTheSameContract() {
        // The Quick Look extension builds one of these directly rather than
        // pulling in the editing machinery, so the contract has to hold for
        // the bare initialiser too.
        let view = ScrollingTextView()
        view.textContainerInset = NSSize(width: 24, height: 24)
        let harness = Harness(view)
        view.textStorage?.setAttributedString(
            NSAttributedString(
                string: longMarkdown(), attributes: [.font: NSFont.systemFont(ofSize: 14)]))
        harness.settle()

        XCTAssertGreaterThan(view.maxSize.height, 1_000_000)
        XCTAssertTrue(harness.isScrollable)
        XCTAssertEqual(
            view.autoresizingMask, [.width],
            "a preview panel is resizable, so its text must rewrap with it")

        harness.resize(width: 300)
        XCTAssertEqual(view.frame.width, 300, accuracy: 1)
    }

    // MARK: - Robustness

    func testClampingWithNoScrollViewIsHarmless() {
        // How the view exists under test and during the Quick Look
        // extension's first layout pass.
        let view = editor("# Detached")
        view.clampViewportIntoDocument()
        XCTAssertNil(view.enclosingScrollView)
    }

    func testADegenerateViewportDoesNotWedgeLayout() {
        let harness = Harness(editor(longMarkdown()), width: 0, height: 0)
        XCTAssertGreaterThan(
            harness.documentHeight, 0,
            "a collapsed pane must still lay its document out, or restoring it shows nothing")
    }

    func testClampingLeavesAValidViewportAlone() {
        // The complement to clamping: it corrects a viewport that is past the
        // end of the document and touches nothing else. A clamp that fired on
        // every layout would drag the reader back up the page.
        let view = editor(longMarkdown())
        let harness = Harness(view)
        harness.scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: 500))
        harness.scrollView.reflectScrolledClipView(harness.scrollView.contentView)
        let before = harness.scrollY
        XCTAssertEqual(before, 500, accuracy: 0.5, "precondition: parked mid-document")

        view.clampViewportIntoDocument()

        XCTAssertEqual(harness.scrollY, before, accuracy: 0.5, "a valid viewport must not move")
    }

    // MARK: - Through the SwiftUI layer

    func testTheHostedEditorScrollsAndIsNotCoveredByChrome() throws {
        // Correct geometry still scrolls nothing if something in the chrome
        // above the editor is eating the event. `WorkspaceView` layers a tap
        // gesture over each pane and floats a toolbar across the top, so the
        // hosted representable is exercised here the way the pane builds it.
        var text = longMarkdown()
        let editor = MarkdownEditorView(
            text: Binding(get: { text }, set: { text = $0 })
        )
        .onTapGesture {}

        let hosting = NSHostingView(rootView: editor)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.layoutIfNeeded()

        let scrollView = try XCTUnwrap(
            Self.firstScrollView(in: hosting), "the editor must host an NSScrollView")
        let textView = try XCTUnwrap(scrollView.documentView as? MarkdownTextView)
        if let manager = textView.textLayoutManager {
            manager.ensureLayout(for: manager.documentRange)
        }
        window.layoutIfNeeded()

        XCTAssertGreaterThan(
            textView.frame.height, scrollView.contentView.bounds.height,
            "precondition: the hosted document is longer than its viewport")

        // A point in the middle of the editor, in the window's coordinates.
        let middle = hosting.convert(
            NSPoint(x: hosting.bounds.midX, y: hosting.bounds.midY), to: nil)
        let hit = try XCTUnwrap(
            window.contentView?.hitTest(middle), "nothing is hit-testable mid-editor")
        XCTAssertTrue(
            hit === textView || hit.isDescendant(of: scrollView),
            """
            a pointer in the middle of the editor lands on \(type(of: hit)), not the \
            scroll view — chrome above the editor is intercepting the event
            """)

        // The viewport moves, through the hosted hierarchy rather than against
        // a text view assembled by the test.
        //
        // Scrolling is driven here rather than by a synthesized wheel event on
        // purpose: an `NSEvent` built from a `CGEvent` carries no window and a
        // screen-space location, and a stock `NSScrollView` with none of this
        // code in it ignores one just the same. Asserting on it would be
        // asserting that event synthesis works headlessly, not that the editor
        // scrolls.
        let before = scrollView.documentVisibleRect.origin.y
        textView.scrollRangeToVisible(
            NSRange(location: (textView.markdown as NSString).length, length: 0))
        window.layoutIfNeeded()

        XCTAssertGreaterThan(
            scrollView.documentVisibleRect.origin.y, before,
            "the hosted editor's viewport must move down the document")
    }

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview) { return found }
        }
        return nil
    }

    // MARK: - Helpers

    /// Whether the fragment holding `offset` intersects what is on screen.
    private func isOnScreen(offset: Int, in harness: Harness) -> Bool {
        guard let manager = harness.textView.textLayoutManager,
            let content = manager.textContentManager,
            let location = content.location(content.documentRange.location, offsetBy: offset),
            let fragment = manager.textLayoutFragment(for: location)
        else { return false }
        return harness.scrollView.documentVisibleRect.intersects(fragment.layoutFragmentFrame)
    }
}
