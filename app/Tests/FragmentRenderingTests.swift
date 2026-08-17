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
}
