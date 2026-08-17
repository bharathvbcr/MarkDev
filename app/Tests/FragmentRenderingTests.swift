//
//  FragmentRenderingTests.swift
//  MarkDevKitTests
//
//  Proves the custom layout fragments actually paint.
//
//  Asserting on decoration *values* only shows the right thing was decided.
//  These render the view and sample pixels, which is the only way to catch a
//  fragment that resolves correctly but draws nothing — a clipped
//  `renderingSurfaceBounds`, say, or a `draw` override never reached.
//

import AppKit
import XCTest

@testable import MarkDevKit

@MainActor
final class FragmentRenderingTests: XCTestCase {
    /// Lays out `markdown` in a real view and returns its rendered pixels.
    private func render(_ markdown: String, height: CGFloat = 420) throws -> NSBitmapImageRep {
        let view = MarkdownTextView.make()
        view.frame = NSRect(x: 0, y: 0, width: 520, height: height)
        view.setMarkdown(markdown)

        // TextKit 2 lays out lazily; without this the viewport is empty.
        view.textLayoutManager?.ensureLayout(for: view.textLayoutManager!.documentRange)
        view.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// The most saturated pixel anywhere in the image.
    ///
    /// Scans the whole surface rather than one row: a callout's accent bar is
    /// three points wide and its tint is faint, so sampling a fixed column
    /// finds neither.
    private func dominantColor(_ rep: NSBitmapImageRep) -> NSColor? {
        var best: NSColor?
        var bestSaturation: CGFloat = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let color = rep.colorAt(x: x, y: y)?
                    .usingColorSpace(.deviceRGB) else { continue }
                var hue: CGFloat = 0, saturation: CGFloat = 0
                var brightness: CGFloat = 0, alpha: CGFloat = 0
                color.getHue(
                    &hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
                if saturation > bestSaturation {
                    bestSaturation = saturation
                    best = color
                }
            }
        }
        return bestSaturation > 0.2 ? best : nil
    }

    /// How many sampled pixels differ from the view's flat background.
    ///
    /// A count over the whole surface, rather than a probe at fixed
    /// coordinates: where a fragment paints depends on font metrics and line
    /// breaking, so a fixed sample point can fail for reasons unrelated to
    /// the drawing being correct.
    private func inkedPixels(_ rep: NSBitmapImageRep) -> Int {
        guard let background = rep.colorAt(x: 2, y: 2)?.usingColorSpace(.deviceRGB) else {
            return 0
        }
        var count = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let sample = rep.colorAt(x: x, y: y)?
                    .usingColorSpace(.deviceRGB) else { continue }
                if abs(sample.redComponent - background.redComponent) > 0.01
                    || abs(sample.greenComponent - background.greenComponent) > 0.01
                    || abs(sample.blueComponent - background.blueComponent) > 0.01
                {
                    count += 1
                }
            }
        }
        return count
    }

    /// Rows where any pixel differs from the view's flat background.
    private func decoratedRows(_ rep: NSBitmapImageRep) -> [Int] {
        guard let background = rep.colorAt(x: 2, y: 2)?.usingColorSpace(.deviceRGB) else {
            return []
        }
        var rows: [Int] = []
        // Block panels fill the text container, not the NSTextView's outer
        // inset. Sample just inside that container while still staying well
        // past the short test strings.
        let sampleX = max(
            2, rep.pixelsWide - Int(EditorTheme.standard.insets.width) - 8)
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            // Sample near the content edge, past where text usually reaches, so
            // a hit means background decoration rather than glyphs.
            guard let sample = rep.colorAt(x: sampleX, y: y)?
                .usingColorSpace(.deviceRGB) else { continue }
            if abs(sample.redComponent - background.redComponent) > 0.01
                || abs(sample.greenComponent - background.greenComponent) > 0.01
                || abs(sample.blueComponent - background.blueComponent) > 0.01
            {
                rows.append(y)
            }
        }
        return rows
    }

    func testACodeBlockPaintsABackgroundBehindItsText() throws {
        // The same words, once as prose and once fenced. The fenced version
        // must cover far more of the surface, because it fills a panel behind
        // the text rather than only drawing glyphs.
        let plain = try render("let value = 42\n")
        let fenced = try render("```swift\nlet value = 42\n```\n")

        let plainInk = inkedPixels(plain)
        let fencedInk = inkedPixels(fenced)

        XCTAssertGreaterThan(
            fencedInk, plainInk * 2,
            "a fenced block should paint a background, not just its glyphs "
                + "(plain \(plainInk), fenced \(fencedInk))")
    }

    func testTextKitBuildsDecoratedCustomFragments() throws {
        let view = MarkdownTextView.make()
        view.frame = NSRect(x: 0, y: 0, width: 520, height: 420)
        view.setMarkdown("```swift\nlet value = 42\n```\n")
        let manager = try XCTUnwrap(view.textLayoutManager)
        manager.ensureLayout(for: manager.documentRange)

        var custom: [MarkdownLayoutFragment] = []
        manager.enumerateTextLayoutFragments(
            from: manager.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            if let fragment = fragment as? MarkdownLayoutFragment { custom.append(fragment) }
            return true
        }

        XCTAssertFalse(custom.isEmpty, "the editor delegate must supply custom fragments")
        XCTAssertTrue(
            custom.contains { $0.decoration.hasBackground },
            "at least one fragment must carry the parsed code-block decoration")
    }

    /// Hue of a colour, in 0…1.
    private func hue(of colour: NSColor) -> CGFloat {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        colour.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return hue
    }

    func testACalloutPaintsItsAccentColour() throws {
        // Each alert kind is tinted differently; if the accent were not drawn,
        // every callout would look identical.
        let warning = try render("> [!WARNING]\n> careful here\n")
        let colour = try XCTUnwrap(
            dominantColor(warning), "a warning callout should paint a visible accent")

        // Warm — orange through yellow. Blending the accent over a dark
        // background shifts the hue, so the assertion covers the band rather
        // than one exact value.
        let warningHue = hue(of: colour)
        XCTAssertTrue(
            warningHue < 0.20 || warningHue > 0.92,
            "a warning callout should read as warm, got hue \(warningHue)")
    }

    func testDifferentCalloutKindsPaintDifferentColours() throws {
        let note = try XCTUnwrap(dominantColor(try render("> [!NOTE]\n> blue please\n")))
        let caution = try XCTUnwrap(dominantColor(try render("> [!CAUTION]\n> red please\n")))

        let noteHue = hue(of: note)
        let cautionHue = hue(of: caution)

        XCTAssertNotEqual(
            noteHue, cautionHue, accuracy: 0.02,
            "a note and a caution must not render the same colour")
    }

    func testKeywordsAreColouredInsideAFence() throws {
        // The end-to-end highlighting path: Rust tree-sitter through the FFI,
        // onto the screen.
        let view = MarkdownTextView.make()
        view.setMarkdown("```rust\nfn main() { let x = 1; }\n```")

        let range = (view.markdown as NSString).range(of: "fn")
        let colour = view.textStorage?.attribute(
            .foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
        XCTAssertEqual(colour, EditorTheme.standard.color(for: .keyword))

        // And the text after the fence must not inherit code colouring.
        let after = view.markdown as NSString
        if after.length > 0 {
            let tail = after.length - 1
            let tailColour = view.textStorage?.attribute(
                .foregroundColor, at: tail, effectiveRange: nil) as? NSColor
            XCTAssertNotEqual(tailColour, EditorTheme.standard.color(for: .keyword))
        }
    }

    func testACodeBlockPanelHasAConsistentWidthAcrossItsLines() throws {
        // A layout fragment is only as wide as its own line, so sizing the
        // panel from it paints a ragged stack of boxes — each stopping where
        // its text happens to end. The panel must instead reach the text
        // container's edge on every line.
        let rep = try render(
            """
            ```swift
            let a = 1
            let somewhatLongerLine = 2
            let b = 3
            ```
            """)

        guard let background = rep.colorAt(x: 2, y: 2)?.usingColorSpace(.deviceRGB) else {
            return XCTFail("no background sample")
        }

        /// Rightmost pixel on `y` that differs from the background.
        func rightEdge(_ y: Int) -> Int? {
            for x in stride(from: rep.pixelsWide - 1, through: 0, by: -1) {
                guard let sample = rep.colorAt(x: x, y: y)?
                    .usingColorSpace(.deviceRGB) else { continue }
                if abs(sample.redComponent - background.redComponent) > 0.01
                    || abs(sample.greenComponent - background.greenComponent) > 0.01
                    || abs(sample.blueComponent - background.blueComponent) > 0.01
                {
                    return x
                }
            }
            return nil
        }

        let edges = stride(from: 0, to: rep.pixelsHigh, by: 2).compactMap(rightEdge)
        guard let widest = edges.max(), widest > 0 else {
            return XCTFail("the code block painted nothing")
        }

        // Every painted row of the panel should reach the same right edge.
        // Lines of very different text lengths would otherwise disagree.
        let atFullWidth = edges.filter { $0 >= widest - 2 }.count
        XCTAssertGreaterThanOrEqual(
            atFullWidth, 6,
            "the panel should reach the same edge on every line, not track "
                + "each line's text width (edges: \(Set(edges).sorted().suffix(8)))")
    }

    func testRenderingIsStableForAnEmptyDocument() throws {
        XCTAssertNoThrow(try render(""))
    }

    // MARK: - Checkboxes

    func testACheckedTaskPaintsAFilledCheckbox() throws {
        // The literal `[x]` is painted clear and a checkbox drawn over it, so
        // the only colour on the line can be the checkbox's own accent fill.
        let ticked = try render("- [x] done\n")
        XCTAssertNotNil(
            dominantColor(ticked),
            "a ticked task should paint a filled checkbox, not just its text")
    }

    func testAnUncheckedTaskDrawsAnOutlineRatherThanAFill() throws {
        // The contrast with the test above is the point: if both painted the
        // same, the checkbox would not be reporting state.
        XCTAssertNil(
            dominantColor(try render("- [ ] todo\n")),
            "an empty checkbox should be an outline, with no accent fill")
    }

    func testACheckboxIsNotClippedByTheFragmentSurface() throws {
        // A drawn ornament sits slightly proud of the glyphs it covers. If
        // `renderingSurfaceBounds` is sized to the glyphs alone the box loses
        // its edges, which reads as a broken checkbox rather than a clipped one.
        let view = MarkdownTextView.make()
        view.frame = NSRect(x: 0, y: 0, width: 520, height: 200)
        view.setMarkdown("- [x] done\n")
        let manager = try XCTUnwrap(view.textLayoutManager)
        manager.ensureLayout(for: manager.documentRange)

        var checked = false
        manager.enumerateTextLayoutFragments(from: manager.documentRange.location) { fragment in
            guard let fragment = fragment as? MarkdownLayoutFragment,
                fragment.ornaments.contains(where: {
                    if case .checkbox = $0 { return true } else { return false }
                })
            else { return true }
            checked = true
            XCTAssertGreaterThanOrEqual(
                fragment.renderingSurfaceBounds.height,
                fragment.layoutFragmentFrame.height,
                "the surface must be at least as tall as the line it decorates")
            return false
        }
        XCTAssertTrue(checked, "the task line should carry a checkbox ornament")
    }

    // MARK: - Code panels

    func testCodeTextCarriesNoBackgroundAttribute() {
        // `.backgroundColor` paints a box exactly as wide as each line's
        // glyphs. Stacked behind the panel the fragment already draws to the
        // container's edge, that is a ragged staircase over a clean card.
        let view = MarkdownTextView.make()
        view.setMarkdown("```swift\nlet value = 42\n```\n")
        let range = (view.markdown as NSString).range(of: "let value = 42")
        XCTAssertNil(
            view.textStorage?.attribute(.backgroundColor, at: range.location, effectiveRange: nil),
            "the code panel is drawn by the fragment, not set as a text attribute")
    }

    func testInlineCodeCarriesNoBackgroundAttribute() {
        let view = MarkdownTextView.make()
        view.setMarkdown("Call `render()` first.\n")
        let range = (view.markdown as NSString).range(of: "render()")
        XCTAssertNil(
            view.textStorage?.attribute(.backgroundColor, at: range.location, effectiveRange: nil),
            "inline code gets a drawn pill, not a square attribute background")
    }

    func testAFencedBlockOffersAPopOutControlOnlyOnItsFirstLine() throws {
        let view = MarkdownTextView.make()
        view.frame = NSRect(x: 0, y: 0, width: 520, height: 320)
        view.setMarkdown("```mermaid\ngraph TD\nA-->B\n```\n")
        let manager = try XCTUnwrap(view.textLayoutManager)
        manager.ensureLayout(for: manager.documentRange)

        var controls = 0
        manager.enumerateTextLayoutFragments(from: manager.documentRange.location) { fragment in
            if let fragment = fragment as? MarkdownLayoutFragment,
                fragment.expandControlRect != nil
            {
                controls += 1
            }
            return true
        }
        XCTAssertEqual(
            controls, 1,
            "the panel has one top-right corner however many lines it spans")
    }

    // MARK: - Tables

    /// The x range a document range occupies on screen.
    private func segment(of range: NSRange, in view: MarkdownTextView) throws -> CGRect {
        let manager = try XCTUnwrap(view.textLayoutManager)
        let start = try XCTUnwrap(
            manager.location(manager.documentRange.location, offsetBy: range.location))
        let end = try XCTUnwrap(manager.location(start, offsetBy: range.length))
        let textRange = try XCTUnwrap(NSTextRange(location: start, end: end))

        var found: CGRect?
        manager.enumerateTextSegments(in: textRange, type: .standard, options: []) {
            _, rect, _, _ in
            found = rect
            return false
        }
        return try XCTUnwrap(found, "no layout segment for \(range)")
    }

    /// Lays out a table with the caret parked in a trailing paragraph.
    ///
    /// A table reveals as a unit, so a caret anywhere inside it puts the whole
    /// grid into source form on purpose — which is the wrong state to measure
    /// column layout in.
    private func table(_ source: String) throws -> MarkdownTextView {
        let view = MarkdownTextView.make()
        view.frame = NSRect(x: 0, y: 0, width: 560, height: 380)
        view.setMarkdown(source + "\n\nafter\n")
        view.setSelectedRange(
            NSRange(location: (view.markdown as NSString).length, length: 0))
        let manager = try XCTUnwrap(view.textLayoutManager)
        manager.ensureLayout(for: manager.documentRange)
        return view
    }

    func testTableColumnsLineUpAcrossRows() throws {
        // Live preview hides every `|`, so without column layout this renders
        // as "NameQty / Apple3 / Watermelon12" — the cells run together and
        // the second column starts at a different x on every row.
        let source = """
            | Name | Qty |
            |---|---|
            | Apple | 3 |
            | Watermelon | 12 |
            """
        let view = try table(source)
        let text = source as NSString

        let heading = try segment(of: text.range(of: "Qty"), in: view)
        let first = try segment(of: text.range(of: "3"), in: view)
        let second = try segment(of: text.range(of: "12"), in: view)

        XCTAssertEqual(
            heading.minX, first.minX, accuracy: 1.0,
            "the second column must start at one x, not wherever its row's first cell ended")
        XCTAssertEqual(heading.minX, second.minX, accuracy: 1.0)
        XCTAssertGreaterThan(
            first.minX, 60,
            "the second column should clear the widest first-column cell")
    }

    func testARightAlignedColumnEndsAtOneEdge() throws {
        let source = """
            | Item | Cost |
            |---|---:|
            | Tea | 4 |
            | Coffee | 250 |
            """
        let view = try table(source)
        let text = source as NSString

        let short = try segment(of: text.range(of: "4"), in: view)
        let long = try segment(of: text.range(of: "250"), in: view)

        XCTAssertEqual(
            short.maxX, long.maxX, accuracy: 1.0,
            "`---:` should right-align the column, so its cells share a right edge")
        XCTAssertLessThan(
            long.minX, short.minX,
            "the wider value should start further left, being flush right")
    }

    func testTableLayoutIsIdempotentAcrossRestyles() throws {
        // Column widths are added as kerning. Measuring a table that already
        // carries kerning from the last pass would compound it, so every
        // keystroke inside a table would push its columns further apart.
        let source = """
            | Name | Qty |
            |---|---|
            | Apple | 3 |
            """
        let view = try table(source)
        let text = source as NSString
        let before = try segment(of: text.range(of: "Qty"), in: view)

        for _ in 0..<3 {
            view.theme = .standard
            view.textLayoutManager?.ensureLayout(
                for: view.textLayoutManager!.documentRange)
        }
        let after = try segment(of: text.range(of: "Qty"), in: view)

        XCTAssertEqual(
            before.minX, after.minX, accuracy: 0.5,
            "restyling must not widen a table it has already laid out")
    }

    func testACaretInOneRowRevealsTheWholeTable() throws {
        // Revealing row by row would show the caret's row as raw `| … |`
        // while its neighbours stayed laid out — and the row would jump
        // sideways out of the grid as the caret arrived, because its own
        // pipes suddenly take up space.
        let source = """
            | Name | Qty |
            |---|---|
            | Apple | 3 |
            | Pear | 9 |
            """
        let document = ParsedDocument.parse(source)
        let inLastRow = (source as NSString).range(of: "Pear").location
        let hidden = HiddenRanges(
            document: document, selection: NSRange(location: inLastRow, length: 0))

        for pipe in ["| Name", "| Apple", "| Pear"] {
            let location = (source as NSString).range(of: pipe).location
            XCTAssertFalse(
                hidden.covers(NSRange(location: location, length: 1)),
                "every row's pipes should be revealed together, not just \(pipe)")
        }
    }

    func testATableAwayFromTheCaretHidesEveryPipe() throws {
        let source = "| Name | Qty |\n|---|---|\n| Apple | 3 |\n\nafter\n"
        let document = ParsedDocument.parse(source)
        let hidden = HiddenRanges(
            document: document,
            selection: NSRange(location: (source as NSString).range(of: "after").location, length: 0))

        for pipe in ["| Name", "| Apple"] {
            let location = (source as NSString).range(of: pipe).location
            XCTAssertTrue(
                hidden.covers(NSRange(location: location, length: 1)),
                "\(pipe) should collapse once the caret leaves the table")
        }
    }

    func testSourceModeLeavesTableColumnsAlone() throws {
        // Source mode shows the characters as written. Padding between them
        // would be the editor editing the reader's view of their own file.
        let source = """
            | Name | Qty |
            |---|---|
            | Apple | 3 |
            """
        let view = try table(source)
        view.mode = .source
        view.textLayoutManager?.ensureLayout(for: view.textLayoutManager!.documentRange)

        let range = (source as NSString).range(of: "Qty")
        XCTAssertNil(
            view.textStorage?.attribute(.kern, at: range.location - 1, effectiveRange: nil),
            "source mode must strip the column padding live preview added")
    }

    func testATablePaintsAGridBehindItsRows() throws {
        let plain = try render("Name Qty\nApple 3\n")
        let gridded = try render("| Name | Qty |\n|---|---|\n| Apple | 3 |\n")
        XCTAssertGreaterThan(
            inkedPixels(gridded), inkedPixels(plain),
            "a table should paint a header fill and a border, not only its words")
    }
}
