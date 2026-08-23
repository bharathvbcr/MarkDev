//
//  MarkdownPreviewTests.swift
//  MarkDevKitTests
//
//  The read-only surface behind Finder Quick Look and the in-app peek.
//

import AppKit
import XCTest

@testable import MarkDevKit

@MainActor
final class MarkdownPreviewTests: XCTestCase {
    private func makeController() -> MarkdownPreviewController {
        let controller = MarkdownPreviewController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 520, height: 420)
        return controller
    }

    private func textView(of controller: MarkdownPreviewController) throws -> MarkdownTextView {
        try XCTUnwrap(controller.view.documentView as? MarkdownTextView)
    }

    // MARK: - Reading mode

    func testThePreviewIsNotEditable() throws {
        let controller = makeController()
        controller.show("# Title", directory: nil)
        let view = try textView(of: controller)

        XCTAssertEqual(view.mode, .reading)
        XCTAssertFalse(view.isEditable, "a preview must never accept typing")
        XCTAssertTrue(view.isSelectable, "but text must still be selectable to copy")
    }

    func testEverySyntaxMarkerIsCollapsed() throws {
        // Reading mode has no caret to reveal a block, so nothing stays
        // visible — this is the property that separates preview from the
        // live-preview editor.
        let controller = makeController()
        controller.show("# Title\n\nSome **bold** and *italic* text.\n", directory: nil)
        let view = try textView(of: controller)
        let storage = try XCTUnwrap(view.textStorage)

        XCTAssertFalse(view.parsed.markers.isEmpty, "the fixture must have syntax to hide")
        for marker in view.parsed.markers {
            let font = storage.attribute(.font, at: marker.range.location, effectiveRange: nil)
            XCTAssertEqual(
                (font as? NSFont)?.pointSize ?? 0,
                EditorTheme.hiddenMarkerFontSize,
                accuracy: 0.001,
                "marker at \(marker.range) is still visible")
        }
    }

    func testTheSourceRoundTripsExactly() throws {
        // The old renderer *deleted* hidden syntax, so its output could not be
        // copied back out as Markdown. Collapsing keeps the buffer honest.
        let source = "# Title\n\n- [x] done\n\n| A | B |\n|---|---|\n| 1 | 2 |\n"
        let controller = makeController()
        controller.show(source, directory: nil)

        XCTAssertEqual(controller.markdown, source)
    }

    func testNonASCIIDoesNotDriftTheCollapsedRanges() throws {
        // UTF-16 offsets: an emoji is two code units, so a marker range
        // computed from Rust byte offsets would land one character late and
        // collapse the wrong text.
        let controller = makeController()
        controller.show("🎉 **bold** tail", directory: nil)
        let view = try textView(of: controller)
        let storage = try XCTUnwrap(view.textStorage)
        let text = storage.string as NSString

        for marker in view.parsed.markers {
            XCTAssertEqual(
                text.substring(with: marker.range), "**",
                "the collapsed run should be the asterisks, not text around them")
        }
    }

    func testBoldAndHeadingSizingSurvive() throws {
        let controller = makeController()
        controller.show("# Big *and italic*\n\n**bold**\n", directory: nil)
        let view = try textView(of: controller)
        let storage = try XCTUnwrap(view.textStorage)
        let text = storage.string as NSString

        let heading = text.range(of: "and italic")
        let headingFont = storage.attribute(.font, at: heading.location, effectiveRange: nil)
            as? NSFont
        XCTAssertGreaterThan(
            headingFont?.pointSize ?? 0, EditorTheme.standard.bodyFont.pointSize,
            "emphasis inside a heading must not reset it to body size")
        XCTAssertTrue(headingFont?.fontDescriptor.symbolicTraits.contains(.italic) ?? false)

        let bold = text.range(of: "bold")
        let boldFont = storage.attribute(.font, at: bold.location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(boldFont?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
    }

    func testScientificInlineMathTypesetsWithoutBreakingTheFollowingHeading() throws {
        // Regression fixture from a real note. Inline formulae used to stop at
        // the parser: their dollars collapsed, but the body was only coloured
        // monospace text. The horizontal rules and the heading that follow
        // make this an end-to-end boundary check rather than an isolated `$x$`.
        let source = """
            Each neuron consists of an adaptive somatic compartment $v(t)$, an adaptive somatic threshold $\\theta(t)$, and $K=4$ independent dendritic branches $v\\_{\\text{dend}}[i](t)$:

            - **Impulse Deposition:** Synapses deposit charge directly into target dendritic branches; supralinear dendritic coincidence is supported via $\\sum \\max(0, v\\_{\\text{dend}}[i])^2$.
            - **Spike Reset:** Somatic spikes reset only the soma ($v \\leftarrow 0.0, \\theta \\leftarrow \\theta + \\Delta\\theta$), preserving dendritic branch potentials across emission.

            ---

            ### B. Areas, Assemblies & $k$-WTA Lateral Inhibition (`binn-areas`)

            ## Neurons are partitioned into contiguous populations called **Areas**.
            """

        let controller = makeController()
        controller.show(source, directory: nil)
        let view = try textView(of: controller)
        let storage = try XCTUnwrap(view.textStorage)
        let math = view.parsed.spans.filter { $0.kind == .inlineMath }

        XCTAssertEqual(math.count, 7, "every scientific formula must reach the renderer")
        for span in math {
            XCTAssertNotNil(
                storage.attribute(.inlineMathRun, at: span.range.location, effectiveRange: nil),
                "inline formula at \(span.range) is still raw text")
        }

        let heading = (source as NSString).range(of: "Neurons are partitioned")
        let headingFont = storage.attribute(.font, at: heading.location, effectiveRange: nil)
            as? NSFont
        XCTAssertGreaterThan(
            headingFont?.pointSize ?? 0, EditorTheme.standard.bodyFont.pointSize,
            "the block following rich inline math must remain an H2")
        XCTAssertEqual(controller.markdown, source, "typesetting must not replace the Markdown source")
    }

    func testEncodedWhitespaceAndScientificMathRenderInsideATable() throws {
        // Regression fixture from a generated scientific comparison table.
        // HTML serializers commonly preserve the command-terminating space in
        // `\\le ` as `&#x20;`; that spelling is valid Markdown source but is
        // not LaTeX and must be decoded before SwiftMath sees it. The long
        // second cell and following rule exercise the two layout boundaries
        // that made the failure appear to consume more than one construct.
        let source = """
            | Bound | Learning rule |
            |---|---|
            | $\\le&#x20;$ | Online 3-factor plasticity ($\\Delta w = \\eta e M - \\lambda w$), STDP eligibility, DFA/e-prop/BPTT reference baselines |

            ---
            """

        let controller = makeController()
        controller.view.appearance = NSAppearance(named: .aqua)
        controller.show(source, directory: nil)
        let view = try textView(of: controller)
        let storage = try XCTUnwrap(view.textStorage)

        XCTAssertEqual(view.parsed.inlineMathSpans.count, 2)
        XCTAssertTrue(view.parsed.blocks.contains { $0.kind == .table })
        XCTAssertTrue(view.parsed.blocks.contains { $0.kind == .rule })
        let manager = try XCTUnwrap(view.textLayoutManager)
        manager.ensureLayout(for: manager.documentRange)
        var formulas: [TableCellDrawing.Formula] = []
        manager.enumerateTextLayoutFragments(from: manager.documentRange.location) { fragment in
            guard let row = (fragment as? MarkdownLayoutFragment)?.tableRow else { return true }
            formulas.append(contentsOf: row.cells.flatMap(\.formulas))
            return true
        }
        XCTAssertEqual(
            formulas.count, 2,
            "both formulas must reach the table grid's bitmap painter")
        let expectedInk = try XCTUnwrap(view.resolvedInk.usingColorSpace(.deviceRGB))
        for formula in formulas {
            XCTAssertTrue(
                formula.rect.origin.x.isFinite && formula.rect.origin.y.isFinite
                    && formula.rect.width.isFinite && formula.rect.height.isFinite)
            XCTAssertGreaterThan(formula.rect.width, 1)
            XCTAssertGreaterThan(formula.rect.height, 1)

            let rep = NSBitmapImageRep(cgImage: formula.image)
            var closestInkDistance = CGFloat.greatestFiniteMagnitude
            var paintedPixels = 0
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                    guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                        color.alphaComponent > 0.05
                    else { continue }
                    paintedPixels += 1
                    closestInkDistance = min(
                        closestInkDistance,
                        abs(color.redComponent - expectedInk.redComponent)
                            + abs(color.greenComponent - expectedInk.greenComponent)
                            + abs(color.blueComponent - expectedInk.blueComponent))
                }
            }
            XCTAssertGreaterThan(paintedPixels, 0, "formula bitmap contains no painted pixels")
            XCTAssertLessThan(
                closestInkDistance, 0.2,
                "formula bitmap ink does not match the view's resolved appearance")
        }
        for span in view.parsed.inlineMathSpans {
            XCTAssertNil(
                storage.attribute(.inlineMathFailure, at: span.range.location, effectiveRange: nil),
                "the hidden source row must not acquire a false font-size diagnostic")
        }
        XCTAssertEqual(controller.markdown, source, "entity decoding must never rewrite source")
    }

    func testInlineMathPaintsFiniteGeometryAndUsesHeadingScale() throws {
        let controller = makeController()
        controller.show("Body $k$ here.\n\n## Heading $k$ here.\n", directory: nil)
        let view = try textView(of: controller)
        let storage = try XCTUnwrap(view.textStorage)
        let spans = view.parsed.inlineMathSpans
        XCTAssertEqual(spans.count, 2)

        let body = try XCTUnwrap(
            storage.attribute(.inlineMathRun, at: spans[0].range.location, effectiveRange: nil)
                as? InlineMathRun)
        let heading = try XCTUnwrap(
            storage.attribute(.inlineMathRun, at: spans[1].range.location, effectiveRange: nil)
                as? InlineMathRun)
        XCTAssertGreaterThan(heading.size.height, body.size.height)

        let manager = try XCTUnwrap(view.textLayoutManager)
        manager.ensureLayout(for: manager.documentRange)
        let rects = inlineMathRects(in: view)
        XCTAssertEqual(
            rects.count, spans.count,
            "each formula needs exactly one current visual-line owner")
        for rect in rects {
            XCTAssertTrue(
                rect.origin.x.isFinite && rect.origin.y.isFinite
                    && rect.width.isFinite && rect.height.isFinite)
            XCTAssertGreaterThan(rect.width, 1)
            XCTAssertGreaterThan(rect.height, 1)
        }
    }

    func testInlineMathSharesTheSurroundingProseBaseline() throws {
        let controller = makeController()
        controller.show("Before $x$ after", directory: nil)
        let view = try textView(of: controller)
        let manager = try XCTUnwrap(view.textLayoutManager)
        manager.ensureLayout(for: manager.documentRange)

        var placement: (run: InlineMathRun, rect: CGRect, proseBaseline: CGFloat)?
        manager.enumerateTextLayoutFragments(from: manager.documentRange.location) { fragment in
            guard let fragment = fragment as? MarkdownLayoutFragment,
                let line = fragment.textLineFragments.first,
                let math = fragment.inlineMathRects.first
            else { return true }
            placement = (
                math.run, math.rect,
                line.typographicBounds.origin.y + line.glyphOrigin.y)
            return false
        }

        let aligned = try XCTUnwrap(placement)
        XCTAssertEqual(
            aligned.rect.maxY - aligned.run.baselineFromBottom,
            aligned.proseBaseline, accuracy: 0.25,
            "the formula's real baseline must coincide with the prose baseline")
    }

    func testInlineMathRevealsSourceAndRoundTripsAcrossModes() throws {
        let source = "Before $\\sum_{i=0}^{n} i$ after"
        let view = MarkdownTextView.make()
        view.frame = NSRect(x: 0, y: 0, width: 520, height: 240)
        view.mode = .reading
        view.setMarkdown(source)
        let span = try XCTUnwrap(view.parsed.inlineMathSpans.first)
        let storage = try XCTUnwrap(view.textStorage)
        XCTAssertNotNil(storage.attribute(.inlineMathRun, at: span.range.location, effectiveRange: nil))

        view.mode = .source
        XCTAssertNil(storage.attribute(.inlineMathRun, at: span.range.location, effectiveRange: nil))
        let sourceFont = try XCTUnwrap(
            storage.attribute(.font, at: span.range.location, effectiveRange: nil) as? NSFont)
        XCTAssertGreaterThan(sourceFont.pointSize, EditorTheme.hiddenMarkerFontSize)

        view.mode = .reading
        XCTAssertNotNil(storage.attribute(.inlineMathRun, at: span.range.location, effectiveRange: nil))
        XCTAssertEqual(view.markdown, source)
    }

    func testMalformedInlineMathTheParserCannotOwnStaysLiteral() throws {
        let source = "bad $\\frac{1$ formula"
        let controller = makeController()
        controller.show(source, directory: nil)
        let view = try textView(of: controller)

        XCTAssertTrue(view.parsed.inlineMathSpans.isEmpty)
        XCTAssertEqual(controller.markdown, source)
    }

    func testOversizedInlineMathFailsOpenWithAReason() throws {
        let tooLong = (0..<2_000).map { "x\($0)" }.joined(separator: "+")
        let source = "long $\(tooLong)$ formula"
        let controller = makeController()
        controller.show(source, directory: nil)
        let view = try textView(of: controller)
        let storage = try XCTUnwrap(view.textStorage)
        let span = try XCTUnwrap(view.parsed.inlineMathSpans.first)

        XCTAssertNil(
            storage.attribute(.inlineMathRun, at: span.range.location, effectiveRange: nil),
            "failed LaTeX must remain source rather than become a blank")
        XCTAssertNotNil(
            storage.attribute(.toolTip, at: span.range.location, effectiveRange: nil),
            "the refusal must explain itself")
        let font = storage.attribute(.font, at: span.range.location, effectiveRange: nil)
            as? NSFont
        XCTAssertGreaterThan(font?.pointSize ?? 0, EditorTheme.hiddenMarkerFontSize)
        XCTAssertEqual(controller.markdown, source)
    }

    func testCurrencyAndEscapedDollarsNeverAcquireFormulaRuns() throws {
        let source = "Price $50-$100; US$5; escaped \\$x$; real $x^2$."
        let controller = makeController()
        controller.show(source, directory: nil)
        let view = try textView(of: controller)
        let storage = try XCTUnwrap(view.textStorage)

        XCTAssertEqual(view.parsed.inlineMathSpans.count, 1)
        let real = try XCTUnwrap(view.parsed.inlineMathSpans.first)
        XCTAssertEqual((source as NSString).substring(with: real.range), "x^2")
        XCTAssertNotNil(storage.attribute(.inlineMathRun, at: real.range.location, effectiveRange: nil))
        XCTAssertEqual(controller.markdown, source)
    }

    func testInlineMathRefitsWhenThePreviewNarrows() throws {
        let formula = (0..<120).map { "x_\($0)" }.joined(separator: "+")
        let controller = makeController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 720, height: 300)
        controller.show("$\(formula)$", directory: nil)
        let view = try textView(of: controller)
        let storage = try XCTUnwrap(view.textStorage)
        let span = try XCTUnwrap(view.parsed.inlineMathSpans.first)
        let wide = try XCTUnwrap(
            storage.attribute(.inlineMathRun, at: span.range.location, effectiveRange: nil)
                as? InlineMathRun)

        controller.view.frame = NSRect(x: 0, y: 0, width: 240, height: 300)
        view.frame = controller.view.contentView.bounds
        view.layoutSubtreeIfNeeded()
        view.layout()
        let narrow = try XCTUnwrap(
            storage.attribute(.inlineMathRun, at: span.range.location, effectiveRange: nil)
                as? InlineMathRun)

        XCTAssertLessThanOrEqual(narrow.size.width, wide.size.width)
        XCTAssertLessThanOrEqual(narrow.size.width, view.renderContext.width + 0.5)
        XCTAssertEqual(controller.markdown, "$\(formula)$")
    }

    func testInlineMathContributesPaintedInk() throws {
        // Attribute and geometry checks alone can pass while a custom layout
        // fragment forgets to composite its bitmap. Keep the surrounding text
        // identical and prove the formula adds visible pixels to the preview.
        let plain = "Before     after"
        let typeset = "Before $\\sum_{i=0}^{n} i$ after"

        XCTAssertGreaterThan(
            try inkedPixels(rendering: typeset),
            try inkedPixels(rendering: plain),
            "the inline formula reserved space but painted no bitmap")
    }

    func testWrappedInlineMathPaintsEachFormulaExactlyOnce() throws {
        let source = """
            Prefix text long enough to wrap near the end of this narrow line $\\theta(t)$, and more prose.

            Another moderately long line puts $v \\leftarrow 0.0, \\theta \\leftarrow \\theta + \\Delta\\theta$ before trailing prose that wraps.
            """
        let view = MarkdownTextView.make()
        view.appearance = NSAppearance(named: .aqua)
        view.frame = NSRect(x: 0, y: 0, width: 520, height: 300)
        view.mode = .reading
        view.setMarkdown(source)
        let manager = try XCTUnwrap(view.textLayoutManager)
        manager.ensureLayout(for: manager.documentRange)

        XCTAssertEqual(view.parsed.inlineMathSpans.count, 2)
        XCTAssertEqual(
            inlineMathRects(in: view).count, 2,
            "wrapped paragraph attributes must not repaint a formula on every visual line")
    }

    private func inlineMathRects(in view: MarkdownTextView) -> [CGRect] {
        guard let manager = view.textLayoutManager else { return [] }
        var rects: [CGRect] = []
        manager.enumerateTextLayoutFragments(from: manager.documentRange.location) { fragment in
            if let fragment = fragment as? MarkdownLayoutFragment {
                rects.append(contentsOf: fragment.inlineMathRects.map(\.rect))
            }
            return true
        }
        return rects
    }

    // MARK: - What the deleted renderer lost

    func testConstructsMadeEntirelyOfSyntaxStillPaint() throws {
        // The regression that justified deleting `PreviewRenderer`: a rule, a
        // checkbox, and a table's separators are *all* syntax. A renderer that
        // strips syntax and draws nothing in its place turns them into blank
        // lines and run-together words. Here they must add ink.
        let bare = "Alpha\n\nBravo\n"
        let rich = """
            Alpha

            ---

            - [x] done

            | Name | Age |
            |---|---|
            | Ada | 36 |

            Bravo
            """

        let plainInk = try inkedPixels(rendering: bare)
        let richInk = try inkedPixels(rendering: rich)

        XCTAssertGreaterThan(
            richInk, plainInk,
            "rules, checkboxes, and tables must draw something in place of their syntax")
    }

    /// Lays a document out in a real preview and counts painted pixels.
    private func inkedPixels(rendering markdown: String) throws -> Int {
        let controller = makeController()
        controller.show(markdown, directory: nil)
        let view = try textView(of: controller)
        view.frame = NSRect(x: 0, y: 0, width: 520, height: 420)

        // TextKit 2 lays out lazily; without this the viewport is empty.
        let manager = try XCTUnwrap(view.textLayoutManager)
        manager.ensureLayout(for: manager.documentRange)
        view.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)

        guard let background = rep.colorAt(x: 2, y: 2)?.usingColorSpace(.deviceRGB) else {
            return 0
        }
        var count = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let sample = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
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

    // MARK: - Loading

    func testLoadingAFileResolvesItsDirectoryForImages() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevPreview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let note = directory.appendingPathComponent("Note.md")
        try "![shot](shot.png)\n".write(to: note, atomically: true, encoding: .utf8)

        let controller = makeController()
        try controller.load(contentsOf: note)
        let view = try textView(of: controller)

        XCTAssertEqual(controller.markdown, "![shot](shot.png)\n")
        // Compared by path, not by URL: `deletingLastPathComponent()` leaves a
        // trailing slash that `appendingPathComponent` does not, so two URLs
        // naming the same folder are not equal.
        XCTAssertEqual(
            view.documentDirectory?.standardizedFileURL.path, directory.standardizedFileURL.path,
            "a relative image can only resolve if the note's own folder is known")
    }

    func testANonUTF8FileStillPreviews() throws {
        // A blank Quick Look panel explains nothing. Latin-1 is the common
        // case for notes written by older tools.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevPreview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let note = directory.appendingPathComponent("Latin.md")
        // 0xE9 is `é` in Latin-1 and invalid on its own in UTF-8.
        try Data([0x63, 0x61, 0x66, 0xE9]).write(to: note)

        let controller = makeController()
        try controller.load(contentsOf: note)
        XCTAssertEqual(controller.markdown, "café")
    }

    func testShowingASecondDocumentReplacesTheFirst() throws {
        // Quick Look reuses a preview controller across files when the user
        // arrows through a Finder selection.
        let controller = makeController()
        controller.show("# First", directory: nil)
        controller.show("# Second", directory: nil)

        XCTAssertEqual(controller.markdown, "# Second")
    }
}
