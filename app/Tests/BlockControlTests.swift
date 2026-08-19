//
//  BlockControlTests.swift
//  MarkDevKitTests
//
//  The two chips a block draws in its own corner: copy, for a listing, and
//  zoom, for a picture.
//
//  Three things have to hold, and the first two are what make a drawn control
//  different from a button:
//
//  1. **Drawn and clicked are the same rect.** Nothing in AppKit connects them
//     — the fragment paints, the text view hit-tests — so they share one
//     geometry or they silently disagree, and a control clicked an inch from
//     where it is drawn looks exactly like a control that does nothing.
//  2. **The action runs.** A hit test asserted on its own proves the pointer
//     found something, not that anything happened.
//  3. **What is copied is the code**, without the fence lines, without the
//     indentation the container put there, and without the blank lines the
//     delimiters leave behind.
//

import AppKit
import XCTest

@testable import MarkDevKit

// MARK: - Geometry

/// Placement on its own, with no TextKit involved — the same split
/// ``CheckboxGeometryTests`` makes, and for the same reason: where a chip lands
/// is arithmetic, and arithmetic can be asserted exactly.
final class BlockControlGeometryTests: XCTestCase {
    private let width = BlockControlLayout.width
    private let height = BlockControlLayout.height
    private let inset = BlockControlLayout.inset

    func testTheCopyChipSitsInsideThePanelsTrailingEdge() {
        let panel = CGRect(x: 0, y: 0, width: 480, height: 90)
        let chip = BlockControlLayout.copyRect(inPanel: panel, stripHeight: 19)

        XCTAssertEqual(chip.maxX, panel.maxX - inset, accuracy: 0.001)
        XCTAssertEqual(chip.width, width)
        XCTAssertEqual(chip.height, height)
        XCTAssertGreaterThanOrEqual(chip.minY, panel.minY)
    }

    func testTheCopyChipStaysInsideTheStripItIsCentredIn() {
        // The strip is the only space above the block's first line. A chip
        // taller than the room bought for it prints over the first line of
        // code, which is the failure the label had before it bought its own.
        let panel = CGRect(x: 0, y: 0, width: 300, height: 60)
        let strip: CGFloat = 19
        let chip = BlockControlLayout.copyRect(inPanel: panel, stripHeight: strip)

        XCTAssertLessThanOrEqual(chip.maxY, panel.minY + strip, "the chip reaches into the code")
    }

    func testTheZoomChipSitsAtTheBlocksTrailingEdgeLevelWithThePicture() {
        let panel = CGRect(x: 0, y: 0, width: 480, height: 340)
        let content = CGRect(x: 8, y: 27, width: 400, height: 300)
        let chip = BlockControlLayout.zoomRect(forContent: content, inPanel: panel)

        XCTAssertEqual(chip.maxX, panel.maxX - inset, accuracy: 0.001)
        XCTAssertEqual(chip.minY, content.minY + inset, accuracy: 0.001)
    }

    func testTheZoomChipLandsWhereTheCopyChipWouldRegardlessOfThePicture() {
        // One rule for both, so the reader finds a block's controls in the same
        // column whether the block is a listing or a picture — and so a chip's
        // place cannot depend on how much whitespace a diagram library left
        // around its own graph.
        let panel = CGRect(x: 0, y: 0, width: 480, height: 340)
        let copy = BlockControlLayout.copyRect(inPanel: panel, stripHeight: 19)

        for width in stride(from: 24.0, through: 460.0, by: 20.0) {
            let content = CGRect(x: 8, y: 27, width: width, height: 40)
            let chip = BlockControlLayout.zoomRect(forContent: content, inPanel: panel)
            XCTAssertEqual(chip.minX, copy.minX, accuracy: 0.001, "width \(width)")
            XCTAssertLessThanOrEqual(chip.maxX, panel.maxX, "width \(width): past the column")
        }
    }

    func testAChipNeverEscapesAPanelTooNarrowToHoldIt() {
        let panel = CGRect(x: 0, y: 0, width: 12, height: 60)
        let chip = BlockControlLayout.zoomRect(
            forContent: CGRect(x: 0, y: 0, width: 12, height: 40), inPanel: panel)
        XCTAssertGreaterThanOrEqual(chip.minX, panel.minX)
    }

    func testTheHitAreaContainsWhatIsDrawn() {
        let chip = CGRect(x: 100, y: 10, width: width, height: height)
        let hit = BlockControlLayout.hitArea(of: chip)
        XCTAssertTrue(hit.contains(chip), "a click on the chip itself has to count")
        XCTAssertGreaterThan(hit.width, chip.width)
    }
}

// MARK: - What copying yields

final class CodeBlockSourceTests: XCTestCase {
    private func copied(_ markdown: String, containing needle: String) throws -> String {
        let text = markdown as NSString
        let document = ParsedDocument.parse(markdown)
        let found = text.range(of: needle)
        let block = try XCTUnwrap(
            document.blocks
                .filter {
                    switch $0.kind {
                    case .codeBlock, .mermaidBlock, .mathBlock, .frontmatter: true
                    default: false
                    }
                }
                .filter { NSIntersectionRange($0.range, found).length > 0 }
                .min { $0.range.length < $1.range.length },
            "no code block holds \(needle)")
        return CodeBlockSource.copyText(of: block, in: document, text: text)
    }

    func testAFencedBlockCopiesItsCodeAndNothingElse() throws {
        let copied = try copied("```swift\nlet x = 1\nlet y = 2\n```\n", containing: "let x")
        XCTAssertEqual(copied, "let x = 1\nlet y = 2")
    }

    func testTheBlankLinesTheFencesLeaveBehindAreGone() throws {
        // A fence's marker covers ```` ```swift ```` but not the newline
        // ending it, so the body opens with one — and a pasted snippet that
        // starts with an empty line is a snippet somebody has to tidy.
        let copied = try copied("```\nplain\n```\n", containing: "plain")
        XCTAssertEqual(copied, "plain")
    }

    func testAFenceIndentedInsideAListItemIsDedented() throws {
        let source = """
            - step one:

                ```sh
                make build
                make test
                ```

            - step two
            """
        XCTAssertEqual(try copied(source, containing: "make build"), "make build\nmake test")
    }

    func testAnIndentedCodeBlockLosesItsIndentationAndNothingElse() throws {
        // The four columns *are* the syntax here, and the code's own
        // indentation is not: nesting inside the snippet has to survive.
        let source = "text\n\n    def f():\n        return 1\n\nafter\n"
        XCTAssertEqual(try copied(source, containing: "def f"), "def f():\n    return 1")
    }

    func testABlankLineInsideASnippetSurvives() throws {
        let source = "```py\na = 1\n\nb = 2\n```\n"
        XCTAssertEqual(try copied(source, containing: "a = 1"), "a = 1\n\nb = 2")
    }

    func testCarriageReturnsAreDropped() {
        // A note saved with CRLF endings should still paste into a shell as
        // lines rather than as one line with ^M in it.
        XCTAssertEqual(CodeBlockSource.dedented("one\r\ntwo\r\n"), "one\ntwo")
    }

    func testAnEmptyFenceHasNothingToCopy() throws {
        let source = "```\n```\n"
        let document = ParsedDocument.parse(source)
        let block = try XCTUnwrap(document.blocks.first { $0.kind == .codeBlock })
        XCTAssertEqual(
            CodeBlockSource.copyText(of: block, in: document, text: source as NSString), "")
    }

    func testTheHighlighterAndTheCopyControlAgreeOnWhatTheCodeIs() throws {
        // The highlighter colours a contiguous range and the copy control
        // builds a string, so they cannot share one implementation — but a
        // fenced block is exactly the case the highlighter runs on, and there
        // the two must describe the same characters. Otherwise the reader
        // copies something other than what they see coloured.
        let source = "```swift\nlet x = 1\nlet y = 2\n```\n"
        let text = source as NSString
        let document = ParsedDocument.parse(source)
        let block = try XCTUnwrap(document.blocks.first { $0.kind == .codeBlock })
        let body = try XCTUnwrap(CodeBlockSource.bodyRange(of: block, in: document, text: text))

        XCTAssertFalse(
            text.substring(with: body).contains("```"), "the fence lines are syntax, not code")
        XCTAssertEqual(
            text.substring(with: body).trimmingCharacters(in: .newlines),
            CodeBlockSource.copyText(of: block, in: document, text: text))
    }

    func testAFenceInsideABlockquoteLosesItsQuoteMarkers() throws {
        // The `> ` on every line is the quote's syntax, and it is marked as
        // such. Copied with it, the snippet is a quoted block rather than code.
        let source = "> ```sh\n> make build\n> make test\n> ```\n"
        XCTAssertEqual(try copied(source, containing: "make build"), "make build\nmake test")
    }

    func testABlockHasNoCodeWhenItHoldsNothingButBlankLines() throws {
        let source = "```\n\n\n```\n"
        let document = ParsedDocument.parse(source)
        let block = try XCTUnwrap(document.blocks.first { $0.kind == .codeBlock })
        XCTAssertFalse(CodeBlockSource.hasCode(of: block, in: document, text: source as NSString))
    }

    func testABlockWithCodeSaysSoWithoutBuildingIt() throws {
        let source = "```swift\nlet x = 1\n```\n"
        let document = ParsedDocument.parse(source)
        let block = try XCTUnwrap(document.blocks.first { $0.kind == .codeBlock })
        XCTAssertTrue(CodeBlockSource.hasCode(of: block, in: document, text: source as NSString))
    }
}

// MARK: - In a real text view

@MainActor
final class BlockControlViewTests: XCTestCase {
    private func view(
        _ markdown: String, mode: EditorMode = .reading, width: CGFloat = 520
    ) -> MarkdownTextView {
        let view = MarkdownTextView.make()
        view.mode = mode
        view.frame = NSRect(x: 0, y: 0, width: width, height: 700)
        view.setMarkdown(markdown)
        view.textLayoutManager?.ensureLayout(for: view.textLayoutManager!.documentRange)
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func fragments(_ view: MarkdownTextView) -> [MarkdownLayoutFragment] {
        guard let manager = view.textLayoutManager else { return [] }
        manager.ensureLayout(for: manager.documentRange)
        var found: [MarkdownLayoutFragment] = []
        manager.enumerateTextLayoutFragments(
            from: manager.documentRange.location, options: [.ensuresLayout]
        ) { fragment in
            if let fragment = fragment as? MarkdownLayoutFragment { found.append(fragment) }
            return true
        }
        return found
    }

    /// Where a fragment's chip is, in the view's own coordinates.
    private func onScreen(
        _ control: BlockControl, of fragment: MarkdownLayoutFragment, in view: MarkdownTextView
    ) throws -> CGPoint {
        let rect = try XCTUnwrap(
            fragment.controlRects.first { $0.control == control }?.rect,
            "the fragment draws no \(control) chip")
        let frame = fragment.layoutFragmentFrame
        let origin = view.textContainerOrigin
        return CGPoint(
            x: rect.midX + frame.minX + origin.x,
            y: rect.midY + frame.minY + origin.y)
    }

    func testOnlyTheHeadOfAFenceOffersTheCopyChip() {
        // One chip per block. A fence is one fragment per line, so a control
        // answered for every line would draw a column of them down the panel.
        let view = view("```swift\nlet x = 1\nlet y = 2\n```\n")
        XCTAssertEqual(fragments(view).filter(\.offersCopy).count, 1)
    }

    func testAnEmptyFenceOffersNoChip() {
        let view = view("```\n```\n")
        XCTAssertTrue(
            fragments(view).allSatisfy { !$0.offersCopy },
            "a control that can only ever do nothing is worse than no control")
    }

    func testProseOffersNoChipAtAll() {
        let view = view("Just a sentence, with `code` in it.\n")
        XCTAssertTrue(fragments(view).allSatisfy { !$0.offersCopy && !$0.offersZoom })
    }

    func testClickingWhereTheChipIsDrawnCopiesTheCode() throws {
        let view = view("```swift\nlet x = 1\nlet y = 2\n```\n")
        let head = try XCTUnwrap(fragments(view).first { $0.offersCopy })

        // Deliberately different from what the block holds, so a test that
        // fails to copy cannot pass on a pasteboard that already agreed.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("something else", forType: .string)

        let handled = view.handleControlClick(at: try onScreen(.copy, of: head, in: view))

        XCTAssertTrue(handled, "the click did not land on the chip that is drawn there")
        XCTAssertEqual(pasteboard.string(forType: .string), "let x = 1\nlet y = 2")
    }

    func testEachFenceCopiesItsOwnCode() throws {
        // The block a chip belongs to is found by binary search over an index,
        // and an off-by-one there would copy a neighbour's snippet — which is
        // exactly the failure a reader would not notice until they pasted it.
        let view = view(
            """
            ```sh
            first
            ```

            prose between

            ```sh
            second
            ```

            ```sh
            third
            ```
            """)
        let heads = fragments(view).filter(\.offersCopy)
        XCTAssertEqual(heads.count, 3)

        for (index, expected) in ["first", "second", "third"].enumerated() {
            NSPasteboard.general.clearContents()
            view.handleControlClick(at: try onScreen(.copy, of: heads[index], in: view))
            XCTAssertEqual(NSPasteboard.general.string(forType: .string), expected)
        }
    }

    func testAFenceIndentedInsideAListItemCopiesWhenItsChipIsClicked() throws {
        // Whether a chip is offered is decided by the block that *intersects*
        // the fragment's line; what it copies used to be looked up from a bare
        // offset. A container makes those two different questions — the line
        // begins at the two spaces that indent it, and the code block begins
        // after them — so this chip was drawn, was clickable, and copied
        // nothing at all.
        let view = view("- item\n\n  ```sh\n  nested\n  ```\n")
        let head = try XCTUnwrap(fragments(view).first { $0.offersCopy })

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("untouched", forType: .string)

        XCTAssertTrue(view.handleControlClick(at: try onScreen(.copy, of: head, in: view)))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "nested")
        XCTAssertTrue(head.copyConfirmed, "a copy that happened must confirm")
    }

    func testAClickBesideTheChipIsStillOrdinaryText() throws {
        let view = view("```swift\nlet x = 1\n```\n")
        let head = try XCTUnwrap(fragments(view).first { $0.offersCopy })
        var point = try onScreen(.copy, of: head, in: view)
        // Well clear of the chip and its padding, at the panel's leading end.
        point.x = view.textContainerOrigin.x + 4

        XCTAssertFalse(
            view.handleControlClick(at: point),
            "the chip must not swallow clicks on the rest of the panel")
    }

    func testCopyingConfirmsOnTheChipThatWasClicked() throws {
        let view = view("```swift\nlet x = 1\n```\n")
        let head = try XCTUnwrap(fragments(view).first { $0.offersCopy })
        XCTAssertFalse(head.copyConfirmed)

        view.handleControlClick(at: try onScreen(.copy, of: head, in: view))

        XCTAssertTrue(
            head.copyConfirmed,
            "copying leaves nothing on screen to see; without an answer the reader clicks again")
    }

    func testTheConfirmationSurvivesTheBlockBeingLaidOutAgain() throws {
        // The fragment is rebuilt on the next restyle, and a tick that vanished
        // because something else changed would read as the copy being undone.
        let view = view("```swift\nlet x = 1\n```\n")
        let head = try XCTUnwrap(fragments(view).first { $0.offersCopy })
        view.handleControlClick(at: try onScreen(.copy, of: head, in: view))

        view.textLayoutManager?.invalidateLayout(for: view.textLayoutManager!.documentRange)
        let rebuilt = try XCTUnwrap(fragments(view).first { $0.offersCopy })
        XCTAssertTrue(rebuilt.copyConfirmed)
    }

    func testCopyingASecondBlockTakesTheTickOffTheFirst() throws {
        // The confirmation is state on the *fragment*, and the only thing that
        // ever took it off was the timer started with it. Cancelling that timer
        // to start a new one therefore left the first chip ticked for as long
        // as its fragment lived: two chips both claiming to hold the
        // pasteboard, and only one of them telling the truth.
        let view = view("```sh\nfirst\n```\n\nprose\n\n```sh\nsecond\n```\n")
        let heads = fragments(view).filter(\.offersCopy)
        XCTAssertEqual(heads.count, 2)

        view.handleControlClick(at: try onScreen(.copy, of: heads[0], in: view))
        view.handleControlClick(at: try onScreen(.copy, of: heads[1], in: view))

        XCTAssertFalse(
            heads[0].copyConfirmed,
            "the first chip is still ticked, but its code is no longer on the pasteboard")
        XCTAssertTrue(heads[1].copyConfirmed)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "second")
    }

    func testANewDocumentDoesNotOpenWearingTheLastOnesTick() throws {
        // The confirmation names a *line*, and a fragment built later draws the
        // tick if its own range matches. Carried across a document that was
        // replaced, that match is a coincidence of offsets: the fence at the
        // same place in the new note opens ticked, for a copy nobody made and
        // holding code that is not on the pasteboard.
        let view = view("```swift\nlet x = 1\n```\n")
        let head = try XCTUnwrap(fragments(view).first { $0.offersCopy })
        view.handleControlClick(at: try onScreen(.copy, of: head, in: view))
        XCTAssertTrue(head.copyConfirmed)

        // A different note whose fence begins at the same offset.
        view.setMarkdown("```swift\nlet y = 2\n```\n")
        view.textLayoutManager?.ensureLayout(for: view.textLayoutManager!.documentRange)

        XCTAssertNil(view.confirmedCopyLine)
        XCTAssertTrue(
            fragments(view).allSatisfy { !$0.copyConfirmed },
            "the new document's chip is showing the previous document's confirmation")
    }

    func testScrollingRetestsWhatIsUnderThePointer() throws {
        // Scrolling moves the page under a stationary pointer and AppKit sends
        // no mouse event for it, so a chip scrolled out from under the pointer
        // stayed lit — and with it the arrow cursor, over ordinary text.
        let view = view("```swift\nlet x = 1\n```\n")
        let scroll = ScrollingTextView.scrollView(hosting: view)
        // Far outside any screen, so the real pointer — wherever it happens to
        // be during the run — cannot be inside this view's visible rect, and
        // the assertion below does not depend on where it is.
        let window = NSWindow(
            contentRect: NSRect(x: 20_000, y: 20_000, width: 520, height: 700),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scroll
        scroll.layoutSubtreeIfNeeded()

        let head = try XCTUnwrap(fragments(view).first { $0.offersCopy })
        view.updateHover(at: try onScreen(.copy, of: head, in: view))
        XCTAssertEqual(head.hoveredControl, .copy, "the chip should be lit to begin with")

        // What a scroll posts, which is the only signal this path gets.
        NotificationCenter.default.post(
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)

        XCTAssertNil(head.hoveredControl, "the chip is no longer under the pointer")
        XCTAssertNil(view.hoveredControl)
    }

    func testHoveringAChipLightsItAndLeavingPutsItOut() throws {
        let view = view("```swift\nlet x = 1\n```\n")
        let head = try XCTUnwrap(fragments(view).first { $0.offersCopy })

        view.updateHover(at: try onScreen(.copy, of: head, in: view))
        XCTAssertEqual(head.hoveredControl, .copy)

        view.updateHover(at: nil)
        XCTAssertNil(head.hoveredControl)
    }

    func testARenderedDiagramOffersTheZoomChipOnItsLeadingFragmentOnly() {
        let view = view("```mermaid\nflowchart TD\nA --> B\n```\n")
        let offering = fragments(view).filter(\.offersZoom)

        XCTAssertEqual(offering.count, 1, "one picture, one chip")
        XCTAssertTrue(
            offering.allSatisfy { $0.decoration.rendered != nil },
            "the chip belongs to the block that draws content")
    }

    func testAFenceShowingItsSourceOffersCopyRatherThanZoom() {
        // With the caret inside it, a mermaid fence is code on screen: there is
        // no picture to open, and there *is* something to copy.
        let source = "prose\n\n```mermaid\nflowchart TD\nA --> B\n```\n"
        let view = view(source, mode: .livePreview)
        view.setSelectedRange((source as NSString).range(of: "flowchart TD"))
        view.textLayoutManager?.ensureLayout(for: view.textLayoutManager!.documentRange)

        XCTAssertTrue(fragments(view).allSatisfy { !$0.offersZoom })
        XCTAssertEqual(fragments(view).filter(\.offersCopy).count, 1)
    }

    func testClickingTheZoomChipOpensTheViewer() throws {
        let view = view("```mermaid\nflowchart TD\nA --> B\n```\n")
        let picture = try XCTUnwrap(fragments(view).first { $0.offersZoom })
        ContentZoomViewer.shared.dismiss()

        let handled = view.handleControlClick(at: try onScreen(.zoom, of: picture, in: view))

        XCTAssertTrue(handled, "the click did not land on the chip that is drawn there")
        XCTAssertTrue(ContentZoomViewer.shared.isPresented)
        ContentZoomViewer.shared.dismiss()
    }

    func testACodeBlockKeepsItsStripWhicheverWayTheCaretMoves() throws {
        // The strip is bought by the chip as well as by the label, so it is
        // there whether or not the fence is labelled and whether or not the
        // caret is inside it. Were it not, moving the caret through a fence
        // would reflow every line below it.
        let source = "prose\n\n```\nlet x = 1\n```\n"
        let view = view(source, mode: .livePreview)
        let collapsed = try XCTUnwrap(fragments(view).first { $0.offersCopy }).topMargin

        view.setSelectedRange((source as NSString).range(of: "let x = 1"))
        view.textLayoutManager?.ensureLayout(for: view.textLayoutManager!.documentRange)
        let revealed = try XCTUnwrap(fragments(view).first { $0.offersCopy }).topMargin

        XCTAssertEqual(collapsed, revealed, accuracy: 0.001)
    }
}

// MARK: - Zooming

@MainActor
final class ContentZoomTests: XCTestCase {
    func testADiagramIsDrawnInMoreDetailThanItIsRead() throws {
        // A graph's layout size is the graph's, not the column's, so a small
        // diagram is already at its natural size in the editor: what a viewer
        // adds is *detail*. Asserting the drawn size here would assert nothing —
        // it is the same for both — and the picture would still be a magnified
        // reading-size bitmap.
        let source = "flowchart TD\nA[Start] --> B[Middle]\nB --> C[End]"
        let read = try XCTUnwrap(
            try? RichContentRenderer.shared.diagram(source, maxWidth: 400, dark: false).get())
        let zoomed = try XCTUnwrap(
            try? ZoomedContent.render(
                RenderedBlock(kind: .diagram, source: source),
                documentDirectory: nil, textColor: .labelColor, dark: false
            ).get())

        XCTAssertEqual(zoomed.size.width, read.size.width, accuracy: 0.5)
        XCTAssertGreaterThan(
            try XCTUnwrap(zoomed.cgImage).width, try XCTUnwrap(read.cgImage).width,
            "the viewer serves the same bitmap the editor cached")
    }

    func testAWideDiagramIsNotSqueezedIntoTheReadingColumn() throws {
        // The other half: a graph too wide for the column is scaled down to fit
        // it in the note, and opening it is how a reader gets it back.
        let source = "flowchart LR\n" + (0..<12).map { "N\($0)[Node \($0)] --> N\($0 + 1)" }
            .joined(separator: "\n")
        let read = try XCTUnwrap(
            try? RichContentRenderer.shared.diagram(source, maxWidth: 400, dark: false).get())
        let zoomed = try XCTUnwrap(
            try? ZoomedContent.render(
                RenderedBlock(kind: .diagram, source: source),
                documentDirectory: nil, textColor: .labelColor, dark: false
            ).get())

        XCTAssertEqual(read.size.width, 400, accuracy: 1, "the fixture is not wider than a column")
        XCTAssertGreaterThan(zoomed.size.width, read.size.width)
    }

    func testAFormulaIsTypesetAtViewingSize() throws {
        let latex = "\\frac{a}{b} = c"
        let read = try XCTUnwrap(
            try? RichContentRenderer.shared.math(
                latex, fontSize: 18, color: .labelColor, display: true
            ).get())
        let zoomed = try XCTUnwrap(
            try? ZoomedContent.render(
                RenderedBlock(kind: .math, source: latex),
                documentDirectory: nil, textColor: .labelColor, dark: false
            ).get())

        XCTAssertGreaterThan(zoomed.size.height, read.size.height)
    }

    func testAnImageOpensAtItsOwnSizeRatherThanTheColumnsWidth() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("markdev-zoom-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("wide.png")
        try Self.png(width: 900, height: 300).write(to: url)

        let zoomed = try XCTUnwrap(
            try? ZoomedContent.render(
                RenderedBlock(kind: .image(alt: "wide"), source: "wide.png"),
                documentDirectory: directory, textColor: .labelColor, dark: false
            ).get())

        XCTAssertEqual(zoomed.size.width, 900, accuracy: 1)
    }

    func testAVectorOpensLargerThanItIsRead() throws {
        // The other half of "the viewer re-renders, it does not magnify". A
        // raster opens at its own size because enlarging its pixels is not
        // detail; a vector has no pixels of its own, so opening one means
        // laying it out at viewing size — and a 72-point mark opened at 72
        // points is a viewer that did nothing.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("markdev-zoom-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try """
            <svg xmlns="http://www.w3.org/2000/svg" width="72" height="72" \
            viewBox="0 0 72 72"><circle cx="36" cy="36" r="35" fill="black"/></svg>
            """
            .write(
                to: directory.appendingPathComponent("mark.svg"), atomically: true,
                encoding: .utf8)

        let read = try XCTUnwrap(
            try? RichContentRenderer.shared.image(
                at: "mark.svg", relativeTo: directory, maxWidth: 600).get())
        let zoomed = try XCTUnwrap(
            try? ZoomedContent.render(
                RenderedBlock(kind: .image(alt: "mark"), source: "mark.svg"),
                documentDirectory: directory, textColor: .labelColor, dark: false
            ).get())

        XCTAssertEqual(read.size.width, 72, accuracy: 0.5, "in the note it is a 72-point mark")
        XCTAssertEqual(zoomed.size.width, ZoomedContent.vectorWidth, accuracy: 1)
        XCTAssertGreaterThan(
            try XCTUnwrap(zoomed.cgImage).width, try XCTUnwrap(read.cgImage).width * 10,
            "opened, it must be a bigger picture and not the same one stretched")
    }

    func testAWidthTheNoteAskedForDoesNotFollowAVectorIntoTheViewer() throws {
        // `<img width="72">` is a statement about the page. The viewer exists
        // to get past the page.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("markdev-zoom-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try """
            <svg xmlns="http://www.w3.org/2000/svg" width="400" height="400" \
            viewBox="0 0 400 400"><circle cx="200" cy="200" r="199" fill="black"/></svg>
            """
            .write(
                to: directory.appendingPathComponent("mark.svg"), atomically: true,
                encoding: .utf8)

        let zoomed = try XCTUnwrap(
            try? ZoomedContent.render(
                RenderedBlock(kind: .image(alt: ""), source: "mark.svg", width: 72),
                documentDirectory: directory, textColor: .labelColor, dark: false
            ).get())
        XCTAssertEqual(zoomed.size.width, ZoomedContent.vectorWidth, accuracy: 1)
    }

    func testAMissingImageReportsWhyRatherThanOpeningEmpty() {
        let result = ZoomedContent.render(
            RenderedBlock(kind: .image(alt: ""), source: "nothing-here.png"),
            documentDirectory: FileManager.default.temporaryDirectory,
            textColor: .labelColor, dark: false)

        guard case .failure(let failure) = result else {
            return XCTFail("a missing file must not come back as a picture")
        }
        XCTAssertTrue(failure.reason.contains("nothing-here.png"))
    }

    func testFittingNeverBlowsUpASmallPicture() {
        // Opening a 40-point icon should show a 40-point icon, not a wall.
        let magnification = ZoomedContent.fitMagnification(
            content: CGSize(width: 40, height: 40), viewport: CGSize(width: 800, height: 600))
        XCTAssertEqual(magnification, 1)
    }

    func testFittingBringsALargePictureInsideTheViewport() {
        let content = CGSize(width: 2000, height: 1200)
        let viewport = CGSize(width: 800, height: 600)
        let magnification = ZoomedContent.fitMagnification(content: content, viewport: viewport)

        XCTAssertLessThanOrEqual(content.width * magnification, viewport.width + 0.001)
        XCTAssertLessThanOrEqual(content.height * magnification, viewport.height + 0.001)
    }

    func testADegenerateSizeDoesNotProduceANonsenseMagnification() {
        // The content size comes from a render, and a render can come back
        // empty; a zero here would otherwise divide its way into the window.
        let magnification = ZoomedContent.fitMagnification(
            content: .zero, viewport: CGSize(width: 800, height: 600))
        XCTAssertEqual(magnification, 1)
    }

    func testTheWindowNeverCoversTheWholeScreen() {
        let screen = NSScreen.main
        let size = ContentZoomViewer.windowSize(
            for: CGSize(width: 9000, height: 9000), on: screen)
        let visible = (screen ?? NSScreen.main)?.visibleFrame.size
            ?? CGSize(width: 1440, height: 900)

        XCTAssertLessThanOrEqual(size.width, visible.width * 0.86)
        XCTAssertLessThanOrEqual(size.height, visible.height * 0.86)
    }

    func testTheViewerShowsAPictureAndCanBeDismissed() throws {
        let viewer = ContentZoomViewer()
        let shown = viewer.present(
            RenderedBlock(kind: .math, source: "x^2"),
            documentDirectory: nil, textColor: .labelColor, dark: false)

        XCTAssertTrue(shown)
        XCTAssertTrue(viewer.isPresented)
        viewer.dismiss()
        XCTAssertFalse(viewer.isPresented)
    }

    func testTheViewerExplainsItselfRatherThanOpeningBlank() throws {
        let viewer = ContentZoomViewer()
        let shown = viewer.present(
            RenderedBlock(kind: .image(alt: ""), source: "absent.png"),
            documentDirectory: FileManager.default.temporaryDirectory,
            textColor: .labelColor, dark: false)

        XCTAssertFalse(shown, "a failure must be reported as one")
        XCTAssertTrue(viewer.isPresented, "and still shown, or the click did nothing at all")
        viewer.dismiss()
    }

    /// A solid PNG of the given size.
    private static func png(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        return try XCTUnwrap(
            NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }
}
