//
//  PictureStressTests.swift
//  MarkDevKitTests
//
//  Pictures under storms: random tags, random edits, random widths.
//
//  The invariant every test here comes back to is the one a picture shares
//  with a table row — **a block whose source is collapsed must draw something
//  in its place**. Recognising an `<img>` tag is what hides it, so a
//  disagreement between "this is a picture" and "this draws a picture" is not
//  a bad-looking paragraph, it is a line of the reader's note that has
//  disappeared.
//

import AppKit
import XCTest

@testable import MarkDevKit

@MainActor
final class PictureStressTests: XCTestCase {

    // MARK: - Harness

    private func view(_ markdown: String, width: CGFloat = 520) -> MarkdownTextView {
        let view = MarkdownTextView.make()
        view.frame = NSRect(x: 0, y: 0, width: width, height: 900)
        view.setMarkdown(markdown)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        layout(view)
        return view
    }

    private func layout(_ view: MarkdownTextView) {
        guard let manager = view.textLayoutManager else { return }
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        manager.ensureLayout(for: manager.documentRange)
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
        }
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

    /// Everything that must be true of a document's pictures, whatever has
    /// just been done to it.
    private func assertPicturesAreCoherent(
        _ view: MarkdownTextView,
        _ what: @autoclosure () -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let text = view.markdown as NSString
        let rendered = view.renderedBlocks

        var previous = NSRange(location: 0, length: 0)
        for (index, entry) in rendered.entries.enumerated() {
            XCTAssertGreaterThan(entry.range.length, 0, what(), file: file, line: line)
            XCTAssertLessThanOrEqual(
                NSMaxRange(entry.range), text.length,
                "an entry reaches past the text: \(what())", file: file, line: line)
            if index > 0 {
                XCTAssertGreaterThanOrEqual(
                    entry.range.location, NSMaxRange(previous),
                    "entries overlap, so the binary search cannot hold: \(what())",
                    file: file, line: line)
            }
            previous = entry.range

            // The lookup the fragments use has to answer what a scan would.
            let scanned = rendered.entries.first {
                NSIntersectionRange($0.range, entry.range).length > 0
            }
            XCTAssertEqual(
                rendered.entry(overlapping: entry.range)?.range, scanned?.range,
                "lookup disagreed with a scan: \(what())", file: file, line: line)

            // A picture's source is either collapsed or on screen, and which
            // one has to agree with what the fragments draw.
            let collapsed = view.hiddenRanges.covers(entry.range)
            let drawn = fragments(view).contains {
                $0.decoration.rendered != nil
                    && NSIntersectionRange(self.range(of: $0, in: view), entry.range).length > 0
            }
            XCTAssertEqual(
                collapsed, drawn,
                "a block whose source is \(collapsed ? "hidden" : "shown") "
                    + "\(drawn ? "draws" : "draws nothing") in its place: \(what())",
                file: file, line: line)
        }

        // Nothing draws a picture that is not one of the entries.
        for fragment in fragments(view) where fragment.decoration.rendered != nil {
            let range = self.range(of: fragment, in: view)
            XCTAssertNotNil(
                rendered.entry(overlapping: range),
                "a fragment drew content for \(range), which is not a rendered block: \(what())",
                file: file, line: line)
        }
    }

    private func range(of fragment: MarkdownLayoutFragment, in view: MarkdownTextView) -> NSRange {
        guard let manager = view.textLayoutManager,
            let content = view.textContentStorage,
            let textRange = fragment.rangeInElement as NSTextRange?
        else { return NSRange(location: 0, length: 0) }
        _ = manager
        let start = content.offset(from: content.documentRange.location, to: textRange.location)
        let length = content.offset(from: textRange.location, to: textRange.endLocation)
        return NSRange(location: start, length: length)
    }

    // MARK: - The tag reader, under mutation

    func testMutatedTagsAreNeverAcceptedIntoSomethingUnusable() {
        // Fuzzed rather than enumerated because the refusals are the point and
        // there is no list of them: what matters is that whatever comes back
        // from a mangled tag is either nothing, or a picture with a source
        // worth resolving and a width worth drawing at.
        var generator = SeededGenerator(seed: 0x1_4A65_11A6)
        let seeds = [
            #"<img src="assets/mark.svg" alt="The mark" width="72">"#,
            "<img src=mark.svg>",
            #"<img src='a b.svg' alt="a &amp; b" width="100%"/>"#,
            #"<IMG SRC="M.SVG" ALIGN="left" HSPACE="12">"#,
            "<img\n  src=\"deep/path/mark.svg\"\n  width=\"48\"\n/>",
        ]
        let alphabet = Array(#"<>"'/= &;#imgsrcaltwidth\#u{00A0}\#u{1F600}0123456789.%"#)

        for step in 0..<20_000 {
            var characters = Array(seeds[Int.random(in: 0..<seeds.count, using: &generator)])
            for _ in 0..<Int.random(in: 1...14, using: &generator) {
                guard !characters.isEmpty else { break }
                let position = Int.random(in: 0..<characters.count, using: &generator)
                switch Int.random(in: 0..<3, using: &generator) {
                case 0: characters.remove(at: position)
                case 1:
                    characters.insert(
                        alphabet[Int.random(in: 0..<alphabet.count, using: &generator)],
                        at: position)
                default:
                    characters[position] =
                        alphabet[Int.random(in: 0..<alphabet.count, using: &generator)]
                }
            }
            let mangled = String(characters)

            guard let tag = HTMLImageTag.parse(mangled) else { continue }
            XCTAssertFalse(
                tag.source.isEmpty, "step \(step) accepted \(mangled.debugDescription)")
            XCTAssertFalse(
                tag.source.contains("\n"),
                "step \(step) took a source across a line: \(mangled.debugDescription)")
            if let width = tag.width {
                XCTAssertTrue(
                    width.isFinite && width >= 1,
                    "step \(step) accepted width \(width) from \(mangled.debugDescription)")
            }
        }
    }

    func testMutatedTagsInADocumentNeverHideWhatTheyCannotDraw() {
        // The failure the reader would actually see. Recognising a tag is what
        // *hides* it, so the property that matters is not "the parser is
        // strict" but "nothing is ever collapsed unless what was collapsed is
        // itself a picture" — and that the collapse stops at the tag, rather
        // than taking the paragraphs around it.
        //
        // This is the invariant the newline bug broke: `src="mark.svg` with
        // the closing quote gone ran on through the next two lines and came
        // back a valid tag, so three lines of the note were replaced by a
        // broken picture.
        var generator = SeededGenerator(seed: 0xD0C_5EED)
        let alphabet = Array(#"<>"'/= &;#imgsrcaltwidth0123456789.%\#u{000A}"#)

        // Both spellings, because they fail differently: the one-line tag can
        // only take what is on its line, while the tag written over several —
        // which is how anybody writes one with three attributes — can take the
        // lines below it the moment a quote goes missing.
        let seeds = [
            #"<img src="assets/mark.svg" alt="The mark" width="72">"#,
            "<img\n  src=\"assets/mark.svg\"\n  alt=\"The mark\"\n  width=\"72\"\n>",
        ]

        for step in 0..<3_000 {
            var characters = Array(seeds[step % seeds.count])
            for _ in 0..<Int.random(in: 1...8, using: &generator) {
                guard !characters.isEmpty else { break }
                let position = Int.random(in: 0..<characters.count, using: &generator)
                switch Int.random(in: 0..<3, using: &generator) {
                case 0: characters.remove(at: position)
                case 1:
                    characters.insert(
                        alphabet[Int.random(in: 0..<alphabet.count, using: &generator)],
                        at: position)
                default:
                    characters[position] =
                        alphabet[Int.random(in: 0..<alphabet.count, using: &generator)]
                }
            }

            let mangled = String(characters)
            let source = "keep this line\n\n\(mangled)\n\nand this one\n"
            let text = source as NSString
            let rendered = RenderedBlocks(document: ParsedDocument.parse(source), text: text)

            for entry in rendered.entries {
                let hidden = text.substring(with: entry.range)
                XCTAssertNotNil(
                    HTMLImageTag.parse(hidden),
                    "step \(step) hid \(hidden.debugDescription), which is not a picture")
                XCTAssertFalse(
                    hidden.contains("keep this line") || hidden.contains("and this one"),
                    "step \(step) hid the prose around \(mangled.debugDescription)")
                if let tag = HTMLImageTag.parse(hidden) {
                    XCTAssertFalse(
                        tag.source.contains("\n") || tag.alt.contains("\n"),
                        "step \(step) read \(tag.source.debugDescription) out of "
                            + "\(mangled.debugDescription): a value ran past its own line")
                }
            }
        }
    }

    func testAnAbsurdlyTallPictureStillLaysOut() throws {
        // The drawn size becomes a fragment's height, so an aspect ratio a
        // note can write in one line is an aspect ratio TextKit has to lay
        // out. What is asserted is only that it comes back at all, and bounded:
        // the point is that nothing here runs away.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevTall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try """
            <svg xmlns="http://www.w3.org/2000/svg" width="8" height="90000" \
            viewBox="0 0 8 90000"><rect width="8" height="90000" fill="black"/></svg>
            """
            .write(
                to: directory.appendingPathComponent("hair.svg"), atomically: true,
                encoding: .utf8)

        let view = MarkdownTextView.make()
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 900)
        view.documentDirectory = directory
        view.setMarkdown("Intro paragraph.\n\n<img src=\"hair.svg\" width=\"400\">\n")
        view.setSelectedRange(NSRange(location: 0, length: 0))
        layout(view)

        let drawing = fragments(view).first { $0.decoration.rendered != nil }
        let picture = try XCTUnwrap(drawing, "the picture should still be drawn")
        let content = try XCTUnwrap(picture.renderedContent, "and resolved to a bitmap")
        XCTAssertLessThanOrEqual(content.size.height, 20_000)
        XCTAssertTrue(picture.layoutFragmentFrame.height.isFinite)
        assertPicturesAreCoherent(view, "with a picture 90,000 points tall")
    }

    func testAbsurdTagsAreRefusedWithoutRunningAway() {
        // Every one of these has to return, and quickly: this runs on the
        // parse path, once per HTML block per keystroke.
        let absurd = [
            "<img " + String(repeating: "src=a.svg ", count: 100_000) + ">",
            "<img src=\"" + String(repeating: "&amp;", count: 100_000) + "\">",
            "<img" + String(repeating: " ", count: 500_000) + "src=a.svg>",
            "<img src=\"" + String(repeating: "../", count: 100_000) + "a.svg\">",
            String(repeating: "<img src=a.svg>", count: 50_000),
            "<img src=\"" + String(repeating: "\u{1F600}", count: 100_000) + ".svg\">",
        ]
        let clock = ContinuousClock()
        let started = clock.now
        for markup in absurd { _ = HTMLImageTag.parse(markup) }
        let taken = clock.now - started

        XCTAssertLessThan(
            taken, .milliseconds(250),
            "six absurd tags took \(taken); this is on the keystroke path")
    }

    // MARK: - Documents that keep changing

    func testRandomEditsAroundPicturesKeepEveryPictureCoherent() {
        var generator = SeededGenerator(seed: 0xB0A7_5EED)
        let pieces = [
            "![a](a.png)",
            #"<img src="mark.svg" alt="m" width="72">"#,
            "<img src=b.svg>",
            "text before",
            "```mermaid\ngraph TD;\nA-->B;\n```",
            "$$\nx^2\n$$",
            "<div>not a picture</div>",
            "- <img src=\"in-a-list.svg\">",
            "> <img src=\"quoted.svg\">",
        ]
        let insertions = ["x", "\n", "<", ">", "\"", "img", " ", "![", "](", ")", "width="]

        for seed in 0..<12 {
            var chosen: [String] = []
            for _ in 0..<Int.random(in: 2...6, using: &generator) {
                chosen.append(pieces[Int.random(in: 0..<pieces.count, using: &generator)])
            }
            let source = chosen.joined(separator: "\n\n") + "\n"
            let view = view(source)
            assertPicturesAreCoherent(view, "seed \(seed), as opened")

            for step in 0..<20 {
                let text = view.markdown as NSString
                guard text.length > 0 else { break }
                let location = Int.random(in: 0...text.length, using: &generator)

                if Bool.random(using: &generator), location < text.length {
                    let length = min(
                        Int.random(in: 1...6, using: &generator), text.length - location)
                    view.setSelectedRange(NSRange(location: location, length: length))
                    view.insertText("", replacementRange: view.selectedRange())
                } else {
                    view.setSelectedRange(NSRange(location: location, length: 0))
                    view.insertText(
                        insertions[Int.random(in: 0..<insertions.count, using: &generator)],
                        replacementRange: view.selectedRange())
                }
                layout(view)
                assertPicturesAreCoherent(view, "seed \(seed), step \(step)")
            }
        }
    }

    func testSweepingTheCaretThroughAPictureNeverLosesIt() {
        // The bargain live preview makes: the source comes back to be edited
        // and the picture comes back when the caret leaves. Every position,
        // because the ends are where a range test is wrong.
        let source = """
            before

            <img src="mark.svg" alt="m" width="72">

            between

            ![a](a.png)

            after
            """
        let view = view(source, width: 560)
        view.mode = .livePreview

        for location in 0...(source as NSString).length {
            view.setSelectedRange(NSRange(location: location, length: 0))
            layout(view)
            assertPicturesAreCoherent(view, "caret at \(location)")
        }
    }

    func testATagThatStopsBeingATagLeavesNothingHidden() {
        // The failure this guards is silent: if the picture stops being
        // recognised while its source stays collapsed, the line is simply gone
        // from the reader's note.
        let view = view("before\n\n<img src=\"mark.svg\" width=\"72\">\n\nafter\n")
        let tag = (view.markdown as NSString).range(of: "<img src=\"mark.svg\" width=\"72\">")
        XCTAssertEqual(view.renderedBlocks.entries.count, 1)

        // Take the closing bracket out: still HTML, no longer a picture.
        view.setSelectedRange(NSRange(location: NSMaxRange(tag) - 1, length: 1))
        view.insertText("", replacementRange: view.selectedRange())
        layout(view)

        XCTAssertTrue(view.renderedBlocks.entries.isEmpty, "it is not a picture any more")
        XCTAssertTrue(
            view.markdown.contains("<img src=\"mark.svg\" width=\"72\""),
            "and its source is still in the document")
        for location in 0..<(view.markdown as NSString).length {
            XCTAssertFalse(
                view.hiddenRanges.covers(NSRange(location: location, length: 1))
                    && !view.markdown.isEmpty && location >= tag.location
                    && location < NSMaxRange(tag) - 1,
                "the markup stayed collapsed with nothing drawn in its place")
        }
        assertPicturesAreCoherent(view, "after the tag was broken")
    }

    // MARK: - Many pictures

    func testADocumentFullOfTagsResolvesInLinearTime() {
        // `RenderedBlocks` is built per parse, on the keystroke path. The
        // quadratic shapes this codebase has paid for four times all looked
        // like this: a per-block question answered by a document-wide scan.
        func measure(_ count: Int) -> Duration {
            let source = (0..<count)
                .map { "<img src=\"m\($0).svg\" width=\"\($0 % 200 + 20)\">" }
                .joined(separator: "\n\n")
            let parsed = ParsedDocument.parse(source)
            let text = source as NSString
            let clock = ContinuousClock()
            let started = clock.now
            for _ in 0..<5 { _ = RenderedBlocks(document: parsed, text: text) }
            return clock.now - started
        }

        _ = measure(200)  // warm the allocator; the first run pays for it
        let small = measure(500)
        let large = measure(2_000)
        let ratio = Double(large.components.attoseconds) / Double(max(small.components.attoseconds, 1))

        XCTAssertLessThan(
            ratio, 8,
            "four times the tags cost \(String(format: "%.1f", ratio))x the time "
                + "(\(small) then \(large)) — that is not linear")
    }

    func testAParagraphOfHTMLThatIsNotAPictureIsCheapToRejectRepeatedly() {
        // Rejecting is the common case by far: a note with any raw HTML in it
        // asks this question of every block on every keystroke, and the answer
        // has to be reached without copying the block out.
        let block = "<div>" + String(repeating: "content ", count: 20_000) + "</div>"
        let source = (0..<50).map { _ in block }.joined(separator: "\n\n")
        let parsed = ParsedDocument.parse(source)
        let text = source as NSString

        let clock = ContinuousClock()
        let started = clock.now
        for _ in 0..<20 { _ = RenderedBlocks(document: parsed, text: text) }
        let taken = clock.now - started

        XCTAssertLessThan(
            taken, .milliseconds(200),
            "twenty passes over 8MB of raw HTML took \(taken): the blocks are being copied out")
    }

    // MARK: - Widths that keep changing

    func testResizingThroughManyWidthsStaysBoundedAndKeepsDrawing() throws {
        // A resize walks the column through every pixel between two sizes, and
        // every distinct render width is a fresh rasterisation of every
        // picture in the document. The cache has to stay bounded and the
        // pictures have to keep drawing.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevResize-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<6 {
            try """
                <svg xmlns="http://www.w3.org/2000/svg" width="\(200 + index * 50)" \
                height="\(120 + index * 20)" viewBox="0 0 \(200 + index * 50) \
                \(120 + index * 20)"><circle cx="60" cy="60" r="50" fill="#\(index)5\(index)f88"/>\
                </svg>
                """
                .write(
                    to: directory.appendingPathComponent("m\(index).svg"), atomically: true,
                    encoding: .utf8)
        }

        // A leading paragraph to park the caret in: live preview reveals the
        // block holding it, so without one the first picture would show its
        // source and this would be a test of that instead.
        let source = "Intro paragraph.\n\n"
            + (0..<6).map { "<img src=\"m\($0).svg\" width=\"\(120 + $0 * 40)\">" }
            .joined(separator: "\n\n")
        let view = MarkdownTextView.make()
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        view.documentDirectory = directory
        view.setMarkdown(source)
        view.setSelectedRange(NSRange(location: 0, length: 0))

        var widths: Set<CGFloat> = []
        for width in stride(from: 700.0, through: 380.0, by: -3) {
            view.frame = NSRect(x: 0, y: 0, width: width, height: 900)
            layout(view)
            widths.insert(view.renderContext.width)
            assertPicturesAreCoherent(view, "at a column of \(width)")
        }

        XCTAssertLessThanOrEqual(
            widths.count, 22,
            "320 points of resizing produced \(widths.count) distinct render widths")
        XCTAssertEqual(
            fragments(view).filter { $0.decoration.rendered != nil }.count, 6,
            "every picture still draws at the end of the resize")
        for fragment in fragments(view) where fragment.decoration.rendered != nil {
            XCTAssertTrue(
                fragment.renderedContent != nil || fragment.renderFailure != nil,
                "a fragment drew neither a picture nor a reason")
        }
    }

    func testHammeringTheRendererKeepsTheCacheWithinItsBounds() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevHammer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<20 {
            try """
                <svg xmlns="http://www.w3.org/2000/svg" width="300" height="200" \
                viewBox="0 0 300 200"><rect width="300" height="200" fill="#\(index % 10)\
                \(index % 7)\(index % 5)fff"/></svg>
                """
                .write(
                    to: directory.appendingPathComponent("h\(index).svg"), atomically: true,
                    encoding: .utf8)
        }

        let renderer = RichContentRenderer(pixelBudget: 4_000_000)
        var drawn = 0
        for width in stride(from: 120.0, through: 900.0, by: 30) {
            for index in 0..<20 {
                if case .success = renderer.image(
                    at: "h\(index).svg", relativeTo: directory, maxWidth: width, width: width)
                {
                    drawn += 1
                }
            }
            XCTAssertLessThanOrEqual(
                renderer.cachedPixels, renderer.pixelBudget,
                "the cache passed its own budget at a width of \(width)")
        }

        XCTAssertEqual(drawn, 27 * 20, "every request should have produced a picture")
        XCTAssertLessThanOrEqual(renderer.cachedPixels, renderer.pixelBudget)
    }
}
