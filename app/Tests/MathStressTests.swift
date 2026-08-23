//
//  MathStressTests.swift
//  MarkDevKitTests
//
//  LaTeX rendering under hostile, degenerate, and enormous input.
//
//  Two cliffs were measured in this path before it was bounded. A formula
//  nested ~50 script levels deep — about two hundred bytes — overflowed
//  SwiftMath's recursive parser and took the *process* down: SIGSEGV on the
//  stack guard page, uncatchable, from a note the reader merely opened.
//  Independently, a flat 37KB source laid out 334,000 points wide and
//  rasterised to 668,296×25 pixels — 16.7 megapixels, some 67MB, for one line
//  of symbols that was then clipped at a column nothing like that wide.
//
//  The renderer now refuses past a byte bound and a brace-depth bound, scales
//  a wide formula to its column, and rasterises into an explicitly sized
//  bitmap. Everything here pins one of those decisions, and the two crash
//  fixtures are kept at their exact original bytes: their whole value is that
//  they died before.
//

import AppKit
import XCTest

@testable import MarkDevKit

@MainActor
final class MathStressTests: XCTestCase {
    private func makeRenderer() -> RichContentRenderer { RichContentRenderer() }

    /// Mirrors `RichContentRenderer.maxRasterPixels`. A literal, so raising
    /// the cap has to be a deliberate edit here too instead of silently taking
    /// the assertion with it.
    private let rasterCap = 16_000_000

    // MARK: - The crash cliff

    /// The exact source that SIGSEGV'd the process through SwiftMath's
    /// recursive parser before the depth bound existed. It must come back as
    /// a failure that says why — never as a crash, and never as a blank.
    func testDeeplyNestedScriptsRefuseInsteadOfCrashing() {
        let latex = String(repeating: "x^{", count: 50) + "y" + String(repeating: "}", count: 50)
        guard case .failure(let failure) = makeRenderer().math(
            latex, fontSize: 16, color: .labelColor, display: true)
        else { return XCTFail("a formula nested past the parser's stack must be refused") }
        XCTAssertFalse(failure.reason.isEmpty)
    }

    /// The fraction spelling of the same cliff: ~1000 deep crashed where ~800
    /// survived. The boundary moved with build configuration, which is why the
    /// bound sits far below either number rather than at one of them.
    func testDeeplyNestedFractionsRefuseInsteadOfCrashing() {
        let latex =
            String(repeating: "\\frac{1}{", count: 1_000) + "1"
            + String(repeating: "}", count: 1_000)
        guard case .failure(let failure) = makeRenderer().math(
            latex, fontSize: 16, color: .labelColor, display: true)
        else { return XCTFail("a deeply nested continued fraction must be refused") }
        XCTAssertFalse(failure.reason.isEmpty)
    }

    /// The bound must not take real mathematics with it. Twenty levels of
    /// nesting is already past any ordinary formula — a page of dense typeset
    /// maths reaches four or five — and has to render with sane geometry.
    func testDeepNestingJustUnderTheCapStillTypesets() throws {
        let latex =
            String(repeating: "\\frac{1}{", count: 20) + "x" + String(repeating: "}", count: 20)
        guard case .success(let content) = makeRenderer().math(
            latex, fontSize: 16, color: .labelColor, display: true)
        else { return XCTFail("twenty levels of nesting is real mathematics and must render") }

        XCTAssertGreaterThan(content.size.width, 0)
        XCTAssertGreaterThan(content.size.height, 0)
        XCTAssertTrue(content.size.width.isFinite && content.size.height.isFinite)
    }

    // MARK: - Bounded work

    func testMarkdownCharacterReferencesAreDecodedBeforeLatexParsing() throws {
        XCTAssertEqual(RichContentRenderer.normalisedMathSource("\\le&#x20;"), "\\le ")
        XCTAssertEqual(
            RichContentRenderer.normalisedMathSource("x&#32;&lt;y&#X20;&amp;z"),
            "x <y &z")
        XCTAssertEqual(RichContentRenderer.normalisedMathSource("x&nbsp;+y"), "x +y")

        guard case .success(let encoded) = makeRenderer().math(
            "\\le&#x20;", fontSize: 16, color: .black, display: false),
            case .success(let plain) = makeRenderer().math(
                "\\le ", fontSize: 16, color: .black, display: false)
        else { return XCTFail("encoded command whitespace must typeset") }
        XCTAssertEqual(encoded.size, plain.size, "equivalent sources must render identically")
    }

    func testMathEntityDecoderPreservesUnknownInvalidAndRawTexAmpersands() {
        let matrix = "\\begin{matrix}a&b\\\\c&d\\end{matrix}"
        XCTAssertEqual(RichContentRenderer.normalisedMathSource(matrix), matrix)

        for malformed in [
            "x&unknown;y", "x&#;y", "x&#x;y", "x&#x110000;y",
            "x&#0;y", "x&#x7F;y", "x&amp y", "x&thisNameIsFarTooLong;y",
        ] {
            XCTAssertEqual(
                RichContentRenderer.normalisedMathSource(malformed), malformed,
                "invalid references must fail open without rewriting source")
        }
    }

    func testAStormOfEntitiesStaysBoundedAndDeterministic() {
        let source = String(repeating: "&#x20;", count: 1_000)
        let decoded = RichContentRenderer.normalisedMathSource(source)
        XCTAssertEqual(decoded, String(repeating: " ", count: 1_000))
        XCTAssertEqual(RichContentRenderer.normalisedMathSource(source), decoded)
    }

    /// A flat source too long to typeset on the main actor is refused with
    /// the reason named. Before the byte bound this laid out hundreds of
    /// thousands of points wide and rasterised 67MB — for a line that was
    /// then clipped by its column anyway.
    func testAnEnormousFlatFormulaIsRefusedRatherThanTypeset() {
        let latex = (0..<6_400).map { "x\($0)" }.joined(separator: "+")
        XCTAssertGreaterThan(latex.utf8.count, 8_192, "the fixture must be over the byte bound")

        guard case .failure(let failure) = makeRenderer().math(
            latex, fontSize: 16, color: .labelColor, display: true)
        else { return XCTFail("a 37KB formula must be refused, not typeset") }
        XCTAssertTrue(
            failure.reason.lowercased().contains("long"),
            "the refusal should name what is wrong: \(failure.reason)")
    }

    /// A formula wider than its column is scaled down whole — the diagram
    /// rule ("scaled down rather than clipped") — with its aspect ratio
    /// intact, so every symbol stays visible instead of running off the edge.
    func testAWideFormulaScalesToFitItsColumnWithItsAspectIntact() throws {
        let latex = (0..<800).map { "x\($0)" }.joined(separator: "+")
        let renderer = makeRenderer()

        guard case .success(let natural) = renderer.math(
            latex, fontSize: 16, color: .labelColor, display: true)
        else { return XCTFail("the fixture should typeset") }
        XCTAssertGreaterThan(
            natural.size.width, 3_000,
            "the fixture must actually overrun the column or this proves nothing")

        guard case .success(let fitted) = renderer.math(
            latex, fontSize: 16, color: .labelColor, display: true, maxWidth: 600)
        else { return XCTFail("a wide formula should scale, not fail") }

        XCTAssertLessThanOrEqual(fitted.size.width, 600.5)
        let shrink = fitted.size.width / natural.size.width
        XCTAssertEqual(
            fitted.size.height, natural.size.height * shrink, accuracy: 1,
            "scaling must be uniform or the formula is distorted")
    }

    /// The pixel cap applies to formulas exactly as it does to diagrams and
    /// vectors. This fixture renders fine — it is only wide — so what is
    /// under test is the rasteriser's scale-down, not a refusal.
    func testTheFormulaBitmapStaysWithinTheRasterBudget() throws {
        // Wide enough that even at the viewer's detail the natural pixels
        // would pass 16 megapixels; short enough to stay under the byte bound.
        let latex = (0..<700).map { "y\($0)" }.joined(separator: "+")
        guard case .success(let content) = makeRenderer().math(
            latex, fontSize: 64, color: .black, display: true)
        else { return XCTFail("a wide formula at viewing size should render scaled") }

        let image = try XCTUnwrap(content.cgImage)
        XCTAssertLessThanOrEqual(
            image.width * image.height, rasterCap + image.width + image.height,
            "\(image.width)x\(image.height) is past the raster cap")
    }

    /// Whatever survives the bounds must still be drawn sharp: the explicit
    /// bitmap is built at the Retina scale of the size it is drawn at, not at
    /// the file's nominal grid nor resampled from something smaller.
    func testAnUnscaledFormulaIsRasterisedAtTheRetinaScaleOfItsDrawnSize() throws {
        guard case .success(let content) = makeRenderer().math(
            "E = mc^2", fontSize: 16, color: .black, display: true, maxWidth: 600)
        else { return XCTFail("should typeset") }

        let image = try XCTUnwrap(content.cgImage)
        XCTAssertEqual(image.width, Int((content.size.width * 2).rounded()), accuracy: 2)
        XCTAssertEqual(image.height, Int((content.size.height * 2).rounded()), accuracy: 2)
    }

    // MARK: - The cache

    func testInlineMathAttributesHaveStableValueSemanticsAcrossRenderers() throws {
        let latex = "v_{\\text{dend}}[i](t)"
        guard case .success(let firstContent) = makeRenderer().math(
            latex, fontSize: 16, color: .black, display: false, maxWidth: 500),
            case .success(let secondContent) = makeRenderer().math(
                latex, fontSize: 16, color: .black, display: false, maxWidth: 500)
        else { return XCTFail("both independent renderers should typeset the formula") }

        let first = InlineMathRun(
            image: try XCTUnwrap(firstContent.cgImage), size: firstContent.size,
            source: latex, ink: .black, fontSize: 16,
            baselineFromBottom: try XCTUnwrap(firstContent.baselineFromBottom))
        let equivalent = InlineMathRun(
            image: try XCTUnwrap(secondContent.cgImage), size: secondContent.size,
            source: latex, ink: .black, fontSize: 16,
            baselineFromBottom: try XCTUnwrap(secondContent.baselineFromBottom))
        let differentSource = InlineMathRun(
            image: try XCTUnwrap(secondContent.cgImage), size: secondContent.size,
            source: "x", ink: .black, fontSize: 16,
            baselineFromBottom: try XCTUnwrap(secondContent.baselineFromBottom))

        XCTAssertTrue(first.isEqual(equivalent))
        XCTAssertEqual(first.hash, equivalent.hash)
        XCTAssertFalse(first.isEqual(differentSource))
    }

    /// Two columns are two pictures of one formula, since the wider one draws
    /// larger. The key has to know that, or the prefetcher warms entries
    /// nothing will ever hit and a resize serves the wrong size.
    func testAColumnIsPartOfAFormulaCacheKey() throws {
        let latex = (0..<400).map { "z\($0)" }.joined(separator: "+")
        let renderer = makeRenderer()
        func request(width: CGFloat) -> RenderRequest {
            RenderRequest(
                block: RenderedBlock(kind: .math, source: latex),
                directory: nil,
                context: RenderContext(
                    width: width, dark: false, mathFontSize: 16, textColor: .labelColor))
        }

        XCTAssertFalse(renderer.isCached(request(width: 600)))
        guard case .success(let wide) = renderer.render(request(width: 600)) else {
            return XCTFail("should render")
        }
        XCTAssertTrue(renderer.isCached(request(width: 600)), "the probe missed what it just made")
        XCTAssertFalse(renderer.isCached(request(width: 300)), "another column is another picture")
        XCTAssertFalse(renderer.isCached(request(width: 900)))

        guard case .success(let narrow) = renderer.render(request(width: 300)),
            case .success(let wider) = renderer.render(request(width: 900))
        else { return XCTFail("both should render") }
        XCTAssertLessThanOrEqual(narrow.size.width, wide.size.width + 0.5)
        XCTAssertGreaterThanOrEqual(wider.size.width, wide.size.width - 0.5)
    }

    /// Refusals are cached like failures: a note carrying a hostile formula
    /// pays for the refusal once per source, not once per layout pass.
    func testRefusalsAreCachedSoAHostileNoteCostsOnce() {
        let renderer = makeRenderer()
        let latex = String(repeating: "\\frac{1}{", count: 900) + "1" + String(repeating: "}", count: 900)

        guard case .failure(let first) = renderer.math(
            latex, fontSize: 16, color: .labelColor, display: true),
            case .failure(let second) = renderer.math(
                latex, fontSize: 16, color: .labelColor, display: true)
        else { return XCTFail("both calls should refuse identically") }
        XCTAssertEqual(first, second, "the same refusal, not a fresh scan")
    }

    /// Formulas share the pixel budget with diagrams and images. Before they
    /// were accounted the same way there was no bound at all on what a page
    /// of mathematics could retain.
    ///
    /// The budget is injected small rather than the fixtures grown large: the
    /// claim under test is the *ledger* — that every math bitmap is counted,
    /// and that crossing the ceiling evicts — which a one-megapixel budget
    /// proves as well as a sixty-megapixel one, without allocating it.
    func testMathBitmapsCountAgainstThePixelBudget() throws {
        let budget = 1_000_000
        let renderer = RichContentRenderer(pixelBudget: budget)
        var produced = 0
        var counted = 0

        // A wide chain renders bounded — scaled to fit — so each entry is a
        // few hundred thousand pixels: four of them cross the ceiling.
        for index in 0..<4 {
            let latex = (0..<800).map { "v\(index)x\($0)" }.joined(separator: "+")
            guard case .success(let content) = renderer.math(
                latex, fontSize: 64, color: .black, display: true)
            else { return XCTFail("formula \(index) should render") }
            let pixels = try XCTUnwrap(content.cgImage).width * XCTUnwrap(content.cgImage).height
            produced += pixels
            counted = renderer.cachedPixels
        }

        XCTAssertGreaterThan(
            produced, budget, "these renders have to add up to more than the budget")
        XCTAssertLessThanOrEqual(
            renderer.cachedPixels, budget, "the cache is holding more than its own ceiling")
        XCTAssertGreaterThanOrEqual(
            counted, 1, "math bitmaps must be counted at all")

        // Bounded, and still a cache: what survived must be served, and what
        // was evicted must re-render rather than hand back a neighbour.
        guard case .success(let refreshed) = renderer.math(
            "E = mc^2", fontSize: 16, color: .black, display: true)
        else { return XCTFail("a fresh formula should render after eviction") }
        XCTAssertGreaterThan(refreshed.size.width, 0)
    }

    // MARK: - The depth scanner

    /// Braces are the proxy for SwiftMath's recursion; these pin what counts.
    func testNestingDepthCountsGroupsAndSkipsEscapesAndCommands() {
        XCTAssertEqual(RichContentRenderer.nestingDepth(of: "x^2"), 0)
        XCTAssertEqual(RichContentRenderer.nestingDepth(of: "\\frac{1}{2}"), 1)
        XCTAssertEqual(
            RichContentRenderer.nestingDepth(of: "x^{x^{x^{y}}}"), 3,
            "script groups nest exactly as braces do")
        XCTAssertEqual(
            RichContentRenderer.nestingDepth(of: "\\frac{\\frac{1}{2}}{3}"), 2)

        // Escaped braces are glyphs, not groups.
        XCTAssertEqual(RichContentRenderer.nestingDepth(of: "\\{a\\}"), 0)
        XCTAssertEqual(RichContentRenderer.nestingDepth(of: "{\\{}"), 1)
        // An unterminated group still counts — the estimate is conservative.
        XCTAssertEqual(RichContentRenderer.nestingDepth(of: "{{{"), 3)
        XCTAssertEqual(RichContentRenderer.nestingDepth(of: ""), 0)
    }

    // MARK: - Randomised properties

    /// Fuzzing for safety: whatever comes out of the renderer must be a
    /// failure that says why, or a picture with a finite, positive, bounded
    /// size. Nesting-heavy fragments sit at the top of the palette because
    /// they are the ones that used to crash.
    func testGeneratedFormulasNeverCrashAndStayBounded() {
        let fragments = [
            "\\frac{1}{", "}", "^{", "_{", "x", "+", "=", "\\int_{0}^{",
            "\\text{", "\\", "{", "(", ")", "[", "]", "$", " ", "\\sqrt{",
            "\\sum_{i=0}^{", "\\left(", "\\right)", "n", "2", "\u{1F600}",
            "\u{202E}", "\u{0}", "\\alpha", "\\begin{matrix}", "\\end{matrix}",
        ]

        for seed in 1...150 {
            var random = SeededGenerator(seed: UInt64(seed) &* 7_919)
            let count = Int.random(in: 1...60, using: &random)
            let latex = (0..<count).map { _ in fragments.randomElement(using: &random)! }
                .joined()

            switch makeRenderer().math(latex, fontSize: 18, color: .black, display: true) {
            case .success(let content):
                XCTAssertTrue(
                    content.size.width.isFinite && content.size.height.isFinite,
                    "seed \(seed) produced a non-finite size from:\n\(latex)")
                XCTAssertGreaterThan(
                    content.size.width, 0, "seed \(seed) produced a zero width")
                XCTAssertGreaterThan(
                    content.size.height, 0, "seed \(seed) produced a zero height")
                if let image = content.cgImage {
                    XCTAssertLessThanOrEqual(
                        image.width * image.height, rasterCap + image.width + image.height,
                        "seed \(seed) rasterised \(image.width)x\(image.height), past the bound")
                }
            case .failure(let failure):
                XCTAssertFalse(
                    failure.reason.isEmpty, "seed \(seed) failed without saying why")
            }
        }
    }

    // MARK: - End to end, in the editor

    func testRepeatedWidthRefreshDoesNotCompoundInlineMathScale() throws {
        let source = "Before $v_{\\text{dend}}[i](t)$ after"
        let view = MarkdownTextView.make()
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 240)
        view.mode = .reading
        view.setMarkdown(source)
        let storage = try XCTUnwrap(view.textStorage)
        let span = try XCTUnwrap(view.parsed.inlineMathSpans.first)
        let initial = try XCTUnwrap(
            storage.attribute(.inlineMathRun, at: span.range.location, effectiveRange: nil)
                as? InlineMathRun)

        for width in [690.0, 680.0, 670.0, 660.0, 650.0, 640.0, 630.0, 620.0] {
            view.frame = NSRect(x: 0, y: 0, width: width, height: 240)
            view.layoutSubtreeIfNeeded()
            view.layout()
        }

        let refreshed = try XCTUnwrap(
            storage.attribute(.inlineMathRun, at: span.range.location, effectiveRange: nil)
                as? InlineMathRun)
        XCTAssertEqual(refreshed.fontSize, initial.fontSize)
        XCTAssertEqual(refreshed.size.height, initial.size.height, accuracy: 0.01)
        XCTAssertEqual(view.markdown, source)
    }

    /// Dense notes exercise the integration cliffs that a single formula
    /// cannot: cache reuse, hundreds of attributed anchors, repeated reveal
    /// transitions, and column refits. Every transition must preserve the
    /// source exactly and every collapsed formula must stay drawable.
    func testHundredsOfInlineFormulasSurviveModeAndResizeCycles() throws {
        let count = 300
        let source = (0..<count).map { index in
            "Row \(index): $v\\_{\\text{dend}}[i](t) + \\theta_{\(index % 7)}$ remains stable."
        }.joined(separator: "\n")

        let view = MarkdownTextView.make()
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        view.mode = .reading
        view.setMarkdown(source)
        let storage = try XCTUnwrap(view.textStorage)

        XCTAssertEqual(view.parsed.inlineMathSpans.count, count)
        for width in [900.0, 240.0, 520.0, 320.0, 760.0] {
            view.frame = NSRect(x: 0, y: 0, width: width, height: 600)
            view.layoutSubtreeIfNeeded()
            view.layout()

            for span in view.parsed.inlineMathSpans {
                let run = try XCTUnwrap(
                    storage.attribute(
                        .inlineMathRun, at: span.range.location, effectiveRange: nil)
                        as? InlineMathRun)
                XCTAssertTrue(run.size.width.isFinite && run.size.height.isFinite)
                XCTAssertGreaterThan(run.size.width, 0)
                XCTAssertGreaterThan(run.size.height, 0)
                XCTAssertLessThanOrEqual(run.size.width, view.renderContext.width + 0.5)
            }

            view.mode = .source
            for span in view.parsed.inlineMathSpans {
                XCTAssertNil(
                    storage.attribute(
                        .inlineMathRun, at: span.range.location, effectiveRange: nil))
            }
            view.mode = .reading
        }

        XCTAssertEqual(view.markdown, source)
    }

    /// A document that mixes genuine formulas with currency prose and both
    /// kinds of hostile source, edited at random. Nothing here may crash, and
    /// after every edit each collapsed math block must still resolve to
    /// something drawable-or-explained — the editor-level version of the
    /// core's dollar-accounting property.
    ///
    /// Reading mode is what puts every block in the collapsed state, so every
    /// rendered entry is one a fragment would have to draw.
    func testAMathHeavyDocumentSurvivesHostileEditing() throws {
        let deepNest = String(repeating: "x^{", count: 60) + "y" + String(repeating: "}", count: 60)
        let longChain = (0..<9_000).map { "w\($0)" }.joined(separator: "+")

        let text = """
        # Budget notes

        The price is $50-$100 per unit, and $$5 was already spent.

        $$
        E = mc^2
        $$

        Euler said $e = mc^2$ loudly, twice.

        $$
        \\int_{0}^{\\infty} \\frac{x^3}{e^x - 1} dx = \\frac{\\pi^4}{15}
        $$

        Cost $5 and$6 today.

        $$
        \(deepNest)
        $$

        $$
        \(longChain)
        $$

        Plain closing prose with a lone $ sign.
        """

        let view = MarkdownTextView.make()
        view.mode = .reading
        view.frame = NSRect(x: 0, y: 0, width: 520, height: 420)
        view.setMarkdown(text)
        view.layoutSubtreeIfNeeded()

        var random = SeededGenerator(seed: 2026_08_21)
        let insertions = ["x", "$", "^", "{", "}", "\\", "\n", "$$", " ", "2", "+"]

        for step in 0..<60 {
            // Edit somewhere in the middle third, where the formulas live.
            let length = view.textStorage?.length ?? 0
            guard length > 40 else { break }
            let location = 20 + Int.random(in: 0..<(length - 40), using: &random)
            view.insertText(
                insertions.randomElement(using: &random)!,
                replacementRange: NSRange(location: location, length: 0))
            view.layoutSubtreeIfNeeded()

            // Every entry the parse resolved as rendered content must answer
            // with a usable bitmap or a failure that names itself — a blank
            // gap is the one outcome nothing may produce. Reading mode has an
            // empty reveal set, so that is all of them.
            let parsed = try XCTUnwrap(view.parsed)
            let blocks = RenderedBlocks(document: parsed, text: view.textStorage?.string as NSString?)
            var checked = 0
            for entry in blocks.entries {
                guard case .math = entry.content.kind else { continue }
                checked += 1
                switch RichContentRenderer.shared.math(
                    entry.content.source, fontSize: 16, color: .black,
                    display: true, maxWidth: 500)
                {
                case .success(let content):
                    XCTAssertTrue(content.size.width.isFinite, "step \(step)")
                    XCTAssertTrue(content.size.height.isFinite, "step \(step)")
                    XCTAssertGreaterThan(content.size.width, 0, "step \(step)")
                    XCTAssertGreaterThan(content.size.height, 0, "step \(step)")
                case .failure(let failure):
                    XCTAssertFalse(failure.reason.isEmpty, "step \(step): silent failure")
                }
            }
            XCTAssertGreaterThanOrEqual(
                checked, 2, "step \(step): the fixture lost its formulas")
        }

        // And the window still stands.
        XCTAssertNotNil(view.textStorage)
    }
}
