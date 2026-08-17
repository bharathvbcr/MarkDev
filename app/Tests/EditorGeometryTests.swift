//
//  EditorGeometryTests.swift
//  MarkDevKitTests
//
//  The width half of the sizing contract, in the arrangement the app actually
//  uses: a text view inside a scroll view inside a window that changes size.
//
//  ``ScrollingTextView`` documents the height half — a document view that
//  cannot grow never scrolls. This covers the other axis, where the failure is
//  just as quiet: a text container that does not follow its view lays the
//  document out at the width it had when it was built, and a window opened
//  narrow and then widened renders its text down one side.
//

import AppKit
import XCTest

@testable import MarkDevKit

@MainActor
final class EditorGeometryTests: XCTestCase {
    /// The editor as the app builds it: text view, scroll view, window.
    private func hostedEditor(width: CGFloat) -> (MarkdownTextView, NSScrollView, NSWindow) {
        let view = MarkdownTextView.make()
        let scrollView = ScrollingTextView.scrollView(hosting: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 400),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        scrollView.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        scrollView.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(scrollView)
        return (view, scrollView, window)
    }

    private func layout(_ view: MarkdownTextView, _ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        view.textLayoutManager?.textViewportLayoutController.layoutViewport()
        view.textLayoutManager.map { $0.ensureLayout(for: $0.documentRange) }
    }

    /// The rightmost edge any line of text reaches.
    private func widestLine(_ view: MarkdownTextView) -> CGFloat {
        var widest: CGFloat = 0
        view.textLayoutManager?.enumerateTextLayoutFragments(
            from: view.textLayoutManager?.documentRange.location, options: [.ensuresLayout]
        ) { fragment in
            for line in fragment.textLineFragments {
                widest = max(widest, line.typographicBounds.maxX)
            }
            return true
        }
        return widest
    }

    private static let paragraph = String(
        repeating: "The quick brown fox jumps over the lazy dog. ", count: 40)

    func testTheTextContainerFollowsTheViewWhenTheWindowIsWidened() throws {
        let (view, _, window) = hostedEditor(width: 600)
        view.setMarkdown(Self.paragraph)
        layout(view, window)

        let narrow = try XCTUnwrap(view.textContainer?.size.width)
        window.setContentSize(NSSize(width: 1400, height: 400))
        layout(view, window)
        let wide = try XCTUnwrap(view.textContainer?.size.width)

        XCTAssertGreaterThan(
            wide, narrow + 400,
            "the container has to follow the view, or a widened window lays the "
                + "document out at the width it was opened with")
        // The container is the view minus its inset on both sides.
        XCTAssertEqual(
            wide, view.frame.width - EditorTheme.standard.insets.width * 2, accuracy: 1)
    }

    func testTextIsLaidOutAcrossTheWholeWidthAfterAResize() throws {
        let (view, _, window) = hostedEditor(width: 600)
        view.setMarkdown(Self.paragraph)
        layout(view, window)

        window.setContentSize(NSSize(width: 1400, height: 400))
        layout(view, window)

        let inset = EditorTheme.standard.insets.width
        let padding = view.textContainer?.lineFragmentPadding ?? 0
        let usable = view.frame.width - inset * 2 - padding * 2
        // Wrapped prose fills its measure to within a word of the edge.
        XCTAssertGreaterThan(
            widestLine(view), usable * 0.75,
            "text laid out down one side of the window is the symptom this guards")
    }

    func testNarrowingRewrapsRatherThanClippingTheText() throws {
        let (view, _, window) = hostedEditor(width: 1400)
        view.setMarkdown(Self.paragraph)
        layout(view, window)

        window.setContentSize(NSSize(width: 500, height: 400))
        layout(view, window)

        XCTAssertLessThanOrEqual(
            widestLine(view), view.frame.width,
            "lines must rewrap into the narrower view, not run past its edge")
    }

    func testAPanelSpansTheContainerAtEveryWidth() throws {
        // The panel is sized from the text container, not from the fragment's
        // own line, so it has to keep reaching the edge as the window changes.
        for width in [420.0, 900.0, 1600.0] as [CGFloat] {
            let (view, _, window) = hostedEditor(width: width)
            view.setMarkdown("```swift\nlet x = 1\nlet somewhatLongerLine = 2\n```\n")
            layout(view, window)

            var panels: [CGRect] = []
            view.textLayoutManager?.enumerateTextLayoutFragments(
                from: view.textLayoutManager?.documentRange.location, options: [.ensuresLayout]
            ) { fragment in
                if let fragment = fragment as? MarkdownLayoutFragment,
                    fragment.decoration.hasBackground
                {
                    panels.append(fragment.decorationRect)
                }
                return true
            }

            XCTAssertFalse(panels.isEmpty, "no panel at width \(width)")
            let widths = Set(panels.map { $0.width.rounded() })
            XCTAssertEqual(
                widths.count, 1,
                "every line of one block draws the same panel width (got \(widths))")
            let expected = view.frame.width - EditorTheme.standard.insets.width * 2
                - (view.textContainer?.lineFragmentPadding ?? 0) * 2
            XCTAssertEqual(
                panels[0].width, expected, accuracy: 2,
                "the panel spans the text container at width \(width)")
        }
    }
}
