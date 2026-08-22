//
//  AppearanceTests.swift
//  MarkDevKitTests
//
//  What a light↔dark flip is allowed to leave behind.
//
//  Every fragment-drawn colour and every rendered bitmap must answer to the
//  view's *effective* appearance — never to the ambient `NSAppearance.current`
//  (which during layout passes is whatever AppKit last set, at launch often
//  nothing), and never to the appearance the fragment was built under. The
//  invariants here were written after measuring which of those held: palettes
//  already flipped correctly; formula ink did neither.
//

import AppKit
import XCTest

@testable import MarkDevKit

@MainActor
final class AppearanceTests: XCTestCase {

    // MARK: - Harness

    private func makeView(
        _ markdown: String, appearance: NSAppearance.Name? = nil
    ) -> MarkdownTextView {
        let view = MarkdownTextView.make()
        if let appearance {
            // Loudly, not by silent skip: assigning a failed lookup would
            // leave the view on whatever the ambient snapshot resolved to.
            guard let resolved = NSAppearance(named: appearance) else {
                XCTFail("no such appearance: \(appearance.rawValue)")
                return view
            }
            view.appearance = resolved
        }
        view.frame = NSRect(x: 0, y: 0, width: 520, height: 900)
        view.setMarkdown(markdown)
        // Live preview reveals the block holding the caret, so park it clear
        // of anything this test inspects.
        view.setSelectedRange(NSRange(location: 0, length: 0))
        layout(view)
        return view
    }

    private func layout(_ view: MarkdownTextView) {
        guard let manager = view.textLayoutManager else { return }
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        manager.invalidateLayout(for: manager.documentRange)
        manager.ensureLayout(for: manager.documentRange)
    }

    private func allFragments(_ view: MarkdownTextView) -> [MarkdownLayoutFragment] {
        guard let manager = view.textLayoutManager,
            let start = manager.documentRange.location as NSTextLocation?
        else { return [] }
        var found: [MarkdownLayoutFragment] = []
        manager.enumerateTextLayoutFragments(
            from: start, options: [.ensuresLayout]
        ) { fragment in
            if let f = fragment as? MarkdownLayoutFragment { found.append(f) }
            return true
        }
        return found
    }

    /// Mean luminance of opaque pixels — what the ink reads as.
    private func inkLuminance(_ image: CGImage) -> Double {
        guard let data = image.dataProvider?.data,
            let bytes = CFDataGetBytePtr(data), image.bitsPerPixel >= 32
        else { return -1 }
        let bpr = image.bytesPerRow, bpp = image.bitsPerPixel / 8
        var total = 0.0, count = 0.0
        for y in stride(from: 0, to: image.height, by: 2) {
            for x in stride(from: 0, to: image.width, by: 2) {
                let offset = y * bpr + x * bpp
                let alpha = Double(bytes[offset + 3]) / 255
                guard alpha > 0.5 else { continue }
                // Premultiplied: un-apply before averaging.
                let r = Double(bytes[offset]) / 255 / alpha
                let g = Double(bytes[offset + 1]) / 255 / alpha
                let b = Double(bytes[offset + 2]) / 255 / alpha
                total += (r + g + b) / 3
                count += 1
            }
        }
        return count == 0 ? -1 : total / count
    }

    /// Fraction of sampled pixels darker than 8% luminance — black ink on a
    /// dark page.
    private func fractionOfDarkPixels(_ rep: NSBitmapImageRep) -> Double {
        var dark = 0, total = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                let lum = (c.redComponent + c.greenComponent + c.blueComponent) / 3
                total += 1
                if lum < 0.08 { dark += 1 }
            }
        }
        return total == 0 ? -1 : Double(dark) / Double(total)
    }

    /// Paints a page colour into a capture first, because the text view draws
    /// no background of its own and an unfilled bitmap is transparent black.
    private func fill(_ rep: NSBitmapImageRep, _ colour: NSColor) {
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        colour.setFill()
        NSBezierPath(rect: NSRect(
            x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func formulaInk(_ view: MarkdownTextView) -> Double? {
        for f in allFragments(view) where f.renderedContent?.cgImage != nil {
            return inkLuminance(f.renderedContent!.cgImage!)
        }
        return nil
    }

    private func secondaryOf(_ palette: BlockDecorationPalette) -> (rgb: [CGFloat], alpha: CGFloat) {
        let components = palette.secondaryColor.converted(
            to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil)?
            .components ?? []
        return (Array(components.prefix(3)), components.count > 3 ? components[3] : 1)
    }

    /// Whether `secondary` is the light-appearance value (near-black).
    private func isLightInk(_ palette: BlockDecorationPalette) -> Bool {
        let s = secondaryOf(palette)
        return (s.rgb.max() ?? 1) < 0.5
    }

    override func tearDown() {
        NSAppearance.current = nil
        super.tearDown()
    }

    // MARK: - Ink follows the view, not the ambient appearance

    /// A dark view laid out while the ambient appearance is pinned Aqua must
    /// still typeset light ink.
    ///
    /// This failed: the renderer resolved the theme's dynamic label colour
    /// against `NSAppearance.current` — during a layout pass that is whatever
    /// AppKit last set, and before any window has drawn it is the runner's own
    /// default. The bitmap was baked with ink from the wrong side, and the
    /// cache key recorded the same wrong value, so nothing ever corrected it.
    func testFormulaInkFollowsTheViewNotTheAmbientAppearance() throws {
        NSAppearance.current = NSAppearance(named: .aqua)
        let view = makeView("$$2 + 2$$\n", appearance: .darkAqua)
        view.mode = .reading
        layout(view)

        let ink = try XCTUnwrap(
            formulaInk(view), "the formula resolved to a bitmap")
        XCTAssertGreaterThan(
            ink, 0.6,
            "a formula in a dark view must be typeset in light ink; got \(ink)")
    }

    /// The mirror case: a light view with the ambient pinned dark.
    func testFormulaInkStaysDarkWhenTheViewIsLight() throws {
        NSAppearance.current = NSAppearance(named: .darkAqua)
        let view = makeView("$$2 + 2$$\n", appearance: .aqua)
        view.mode = .reading
        layout(view)

        let ink = try XCTUnwrap(formulaInk(view))
        XCTAssertLessThan(
            ink, 0.4,
            "a formula in a light view must be typeset in dark ink; got \(ink)")
    }

    // MARK: - Bitmaps survive an appearance flip only by being replaced

    /// Flipping the view's appearance must re-resolve rendered content on the
    /// fragments already holding bitmaps — TextKit reuses the same fragment
    /// objects across an appearance change, so nothing else will ask again.
    func testFormulaReResolvesWhenTheAppearanceFlips() throws {
        let view = makeView("$$x + y$$\n", appearance: .aqua)
        view.mode = .reading
        layout(view)

        let before = try XCTUnwrap(formulaInk(view), "light pass produced a bitmap")
        XCTAssertLessThan(before, 0.4)

        view.appearance = NSAppearance(named: .darkAqua)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        layout(view)

        let after = try XCTUnwrap(formulaInk(view), "dark pass produced a bitmap")
        XCTAssertGreaterThan(
            after, 0.6,
            "after flipping to dark the formula must be re-rendered in light "
                + "ink; still \(after)")
    }

    // MARK: - Palettes

    /// After a flip, every fragment — including ones far below the fold — must
    /// read colours through the same snapshot the view just captured.
    ///
    /// Pins the distribution mechanism itself: today the hand-out walk happens
    /// to reach everything, and this test is where a macOS change that breaks
    /// that would be noticed first.
    func testEveryFragmentReadsTheCurrentPaletteAfterAFlip() {
        let body = (1...120).map { "Paragraph \($0) of prose." }.joined(separator: "\n\n")
        let view = makeView("- one\n- two\n" + body, appearance: .aqua)

        view.appearance = NSAppearance(named: .darkAqua)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let fragments = allFragments(view)
        XCTAssertGreaterThan(fragments.count, 50, "harness: the document is tall")
        for fragment in fragments {
            XCTAssertFalse(
                isLightInk(fragment.requirePalette()),
                "a fragment below the fold kept the light palette")
        }

        view.appearance = NSAppearance(named: .aqua)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        for fragment in allFragments(view) {
            XCTAssertTrue(isLightInk(fragment.requirePalette()), "flipping back missed one")
        }
    }

    /// A theme change must reach fragments already laid out.
    ///
    /// Marker fonts are captured per palette (`listMarkerFont` is sized from
    /// `bodyFont`), and TextKit reuses fragments across a restyle, so a bigger
    /// body font used to leave bullets drawn at the old size until each
    /// fragment happened to be rebuilt.
    func testThemeChangeReachesExistingFragments() throws {
        let view = makeView("- one\n- two\n", appearance: .aqua)
        let before = try XCTUnwrap(allFragments(view).first)?
            .requirePalette().listMarkerFont

        var bigger = EditorTheme.standard
        bigger.bodyFont = .systemFont(ofSize: EditorTheme.standard.bodyFont.pointSize * 2)
        view.theme = bigger
        layout(view)

        let after = try XCTUnwrap(allFragments(view).first)?.requirePalette().listMarkerFont
        XCTAssertNotEqual(
            CTFontGetSize(before!), CTFontGetSize(after!),
            "an existing fragment kept the previous theme's marker font")
    }

    // MARK: - The reader's symptom, end to end

    /// A real window flips; what lands in the bitmap must contain no black
    /// ink on a dark page.
    ///
    /// This is the reported symptom stated as pixels — bullets, numbers,
    /// labels, rules, chips and panels drawn from a stale light palette are
    /// exactly "black text in dark mode". The document deliberately holds one
    /// of every drawn decoration, and no rendered bitmap (those carry their
    /// own ink and are covered by the formula tests above).
    func testInWindowFlipLeavesNoBlackInkOnADarkPage() throws {
        let doc = """
            - alpha item
            - beta item

            3. third numbered
            4. fourth numbered

            > a quote worth quoting

            ---

            ```swift
            let x = 1
            ```

            | first | second |
            |-------|--------|
            | a     | b      |

            - [ ] an open task
            - [x] a done task

            [!NOTE]
            Something the reader should know.
            """
        let view = makeView(doc)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 900),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.appearance = NSAppearance(named: .aqua)
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        layout(view)

        window.appearance = NSAppearance(named: .darkAqua)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(
            view.effectiveAppearance.name, .darkAqua, "harness: must inherit")
        layout(view)

        let capture = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        fill(capture, NSColor(calibratedWhite: 0.12, alpha: 1))
        view.cacheDisplay(in: view.bounds, to: capture)

        let blackInk = fractionOfDarkPixels(capture)
        XCTAssertLessThan(
            blackInk, 0.005,
            "black ink survived the flip to dark — some surface is still drawn "
                + "in the light palette (\(String(format: "%.2f%%", blackInk * 100)))")
    }

    // MARK: - Stress

    private static let richDocument = """
        # Appearances

        - bullets survive anything
          - nested deeper
        7. seventh
        8. eighth

        > quoted once

        $$e^{i\\pi} + 1 = 0$$

        ```sh
        echo hello
        ```

        | h1 | h2 |
        |----|----|
        | a  | b  |

        - [ ] open
        - [x] closed

        ---

        [!TIP]
        A callout.
        """

    /// Every fragment reads the store's palette, and any fragment holding a
    /// bitmap was resolved against the generation now current.
    private func assertEverythingCurrent(
        _ view: MarkdownTextView, _ stage: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let store = view.paletteStore
        for fragment in allFragments(view) {
            if fragment.paletteStore !== store {
                XCTFail("\(stage): a fragment carries another view's store",
                    file: file, line: line)
                return
            }
            if fragment.renderedContent != nil || fragment.renderFailure != nil {
                XCTAssertEqual(
                    fragment.stampedGeneration, store.generation,
                    "\(stage): a bitmap outlived the appearance it was made for",
                    file: file, line: line)
            }
        }
    }

    private func assertInkMatchesAppearance(
        _ view: MarkdownTextView, _ stage: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        guard let ink = formulaInk(view) else { return }
        let dark = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        if dark {
            XCTAssertGreaterThan(ink, 0.6, "\(stage): dark page, dark formula ink",
                file: file, line: line)
        } else {
            XCTAssertLessThan(ink, 0.4, "\(stage): light page, light formula ink",
                file: file, line: line)
        }
    }

    /// A seeded storm: flips interleaved with edits, mode changes and scrolls.
    ///
    /// The point is the interleaving — a flip that lands between an edit and
    /// its reparse, or while the caret sits inside a formula's source — which
    /// is where a hand-out walk would have missed something.
    func testFlipStormAcrossEditsModesAndScrolls() throws {
        try runFlipStorm(seed: 0x9E3779B97F4A7C15, rounds: 24)
    }

    /// The same storm across more seeds: each seed is a different interleaving
    /// of flips against reparses, reveals and layout passes.
    func testFlipStormSurvivesManySeeds() throws {
        for seed in UInt64(1)...8 {
            try runFlipStorm(seed: seed &* 0x9E37_79B9_7F4A_7C15, rounds: 14)
        }
    }

    private func runFlipStorm(seed: UInt64, rounds: Int) throws {
        let view = makeView(Self.richDocument, appearance: .aqua)
        var seed = seed
        func next(_ modulus: UInt64) -> UInt64 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return (seed >> 33) % modulus
        }

        let appearances: [NSAppearance.Name] = [.aqua, .darkAqua]
        let modes: [EditorMode] = [.livePreview, .reading, .source]

        for round in 0..<rounds {
            switch next(3) {
            case 0:
                view.appearance = NSAppearance(named: appearances[Int(next(2))])
            case 1:
                view.mode = modes[Int(next(UInt64(modes.count)))]
            default:
                // Typing at the parked caret: an ordinary keystroke, which
                // reparses, restyles, and must not disturb what a flip fixed.
                // Only where it can commit — reading mode is read-only by
                // design, and a silent no-op here would make this round's
                // "edit" vacuous rather than adversarial.
                if view.isEditable { view.insertText("x") }
            }
            // Scroll sometimes: TextKit lays out new regions, whose fragments
            // were created under whatever generation was current.
            if next(2) == 0, let storage = view.textStorage {
                view.scrollRangeToVisible(
                    NSRange(location: Int(next(UInt64(storage.length))), length: 1))
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            layout(view)
            assertEverythingCurrent(view, "round \(round)")
            try assertInkMatchesAppearance(view, "round \(round)")

            // And end every even round back on the starting side, so the test
            // also proves the flip path is traversable in both directions
            // repeatedly rather than only away from where it started.
            if round % 2 == 1 {
                view.appearance = NSAppearance(named: .aqua)
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                layout(view)
                try assertInkMatchesAppearance(view, "round \(round) reset")
            }
        }
    }

    /// A flip landing between an edit and its catch-up reparse.
    ///
    /// Typing schedules its reparse for the next runloop turn; the appearance
    /// hook can fire inside that window, when `parsed` still describes the
    /// pre-keystroke document. Nothing here may style from that parse or
    /// corrupt what the catch-up finds.
    ///
    /// Live preview, deliberately: reading mode is read-only by design, and
    /// typing into it is a silent no-op — the harness must not mistake that
    /// for an edit the flip destroyed.
    func testFlipDuringPendingEditKeepsEverythingConsistent() throws {
        let view = makeView("- one\n\n$$x + y$$\n", appearance: .aqua)
        layout(view)

        let length = try XCTUnwrap(view.textStorage?.length)
        view.insertText("typed ")
        XCTAssertEqual(
            view.textStorage?.length, length + "typed ".count,
            "harness: the keystroke must have committed before the flip")
        // No pump: the keystroke's catch-up has not run. Flip inside that gap.
        view.appearance = NSAppearance(named: .darkAqua)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        layout(view)

        XCTAssertEqual(
            view.textStorage?.length, length + "typed ".count,
            "the edit survived the flip")
        XCTAssertTrue(
            view.markdown.contains("typed "),
            "the document still holds what was typed")
        assertEverythingCurrent(view, "flip during pending edit")
        try assertInkMatchesAppearance(view, "flip during pending edit")
    }

    /// The caret sits *inside* a formula's source when the system flips.
    ///
    /// The block is revealed — its source is on screen and no bitmap exists —
    /// so there is nothing to re-resolve, and nothing may crash trying. When
    /// the reader leaves, the block must render in whatever generation is
    /// current by then.
    func testFlipWhileCaretIsInsideFormulaSource() throws {
        let view = makeView("before\n\n$$x + y$$\n", appearance: .aqua)
        let dollar = try XCTUnwrap((view.textStorage?.string as NSString?)?
            .range(of: "$$"))
        view.setSelectedRange(NSRange(location: dollar.location + 1, length: 0))
        layout(view)
        XCTAssertNil(
            formulaInk(view),
            "harness: the caret should have revealed the formula's source")

        view.appearance = NSAppearance(named: .darkAqua)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        layout(view)
        assertEverythingCurrent(view, "caret inside revealed formula")

        // Leaving the block collapses it again, and the bitmap that appears
        // belongs to the appearance flipped to, not the one it was typed in.
        view.setSelectedRange(NSRange(location: 0, length: 0))
        layout(view)
        let ink = try XCTUnwrap(formulaInk(view), "leaving the block renders it")
        XCTAssertGreaterThan(ink, 0.6, "dark page needs light ink")
    }

    /// A table row is revealed (grid absent) across a flip, then collapsed.
    func testFlipWithRevealedTableRow() {
        let view = makeView("| a | b |\n|---|---|\n| 1 | 2 |\n", appearance: .aqua)
        view.setSelectedRange(NSRange(location: 4, length: 0))
        layout(view)

        view.appearance = NSAppearance(named: .darkAqua)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        layout(view)
        assertEverythingCurrent(view, "revealed table")

        view.setSelectedRange(NSRange(location: 0, length: 0))
        layout(view)
        let rows = allFragments(view).filter { fragment in
            if case .tableRow = fragment.decoration { return true }
            return false
        }
        XCTAssertFalse(rows.isEmpty, "collapsing again restores the grid")
    }

    /// Two flips inside one runloop turn: the store advances two generations,
    /// and anything resolved lazily must land on the *final* one.
    func testDoubleFlipWithinOneRunloopTurn() throws {
        let view = makeView("$$x$$\n", appearance: .aqua)
        view.mode = .reading
        layout(view)

        view.appearance = NSAppearance(named: .darkAqua)
        view.appearance = NSAppearance(named: .aqua)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        layout(view)

        assertEverythingCurrent(view, "double flip")
        let ink = try XCTUnwrap(formulaInk(view))
        XCTAssertLessThan(ink, 0.4, "back on aqua, ink must be dark again")
    }

    /// Many views flipping independently — split panes, the peek panel, a
    /// preview: each has its own store, and none may leak into another.
    func testIndependentViewsFlipIndependently() throws {
        let light = makeView(Self.richDocument, appearance: .aqua)
        let dark = makeView(Self.richDocument, appearance: .darkAqua)

        for _ in 0..<6 {
            light.appearance = NSAppearance(named: .darkAqua)
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            try assertInkMatchesAppearance(dark, "dark pane during light's flip")
            light.appearance = NSAppearance(named: .aqua)
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            try assertInkMatchesAppearance(light, "light pane after flip back")
        }
        try assertInkMatchesAppearance(dark, "dark pane untouched")
    }

    // MARK: - The zoom viewer under an open window

    /// A picture opened large re-renders when the system flips beneath it.
    ///
    /// The viewer's background is `textBackgroundColor`, which follows the
    /// appearance; its bitmap does not follow anything by itself. Without the
    /// re-render, a formula opened in light mode is black ink on a dark
    /// window after the flip — the reader's report, one surface over.
    func testZoomViewerRerendersWhenTheSystemFlipsUnderneath() throws {
        // The runner's own appearance is dark, so flipping the app *to dark*
        // would be no change and fire nothing. Start from light explicitly,
        // and put it back — NSApp appearance outlives this test otherwise.
        let originalAppAppearance = NSApp?.appearance
        defer { NSApp?.appearance = originalAppAppearance }
        NSApp?.appearance = NSAppearance(named: .aqua)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let viewer = ContentZoomViewer()
        defer { viewer.dismiss() }
        var dark = false
        XCTAssertTrue(
            viewer.present(
                RenderedBlock(kind: .math, source: "x + y"),
                documentDirectory: nil
            ) { (dark ? NSColor.white : NSColor.black, dark) },
            "the formula rendered at viewing size")
        XCTAssertTrue(viewer.isPresented, "harness: the window opened")
        let before = try XCTUnwrap(viewer.shownImageForTesting)

        dark = true
        NSApp?.appearance = NSAppearance(named: .darkAqua)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(
            viewer.effectiveAppearanceForTesting?.name, .darkAqua,
            "harness: the window followed the app")
        let afterDark = try XCTUnwrap(viewer.shownImageForTesting)
        XCTAssertFalse(
            afterDark === before,
            "the bitmap must have been rendered again for the new appearance")

        dark = false
        NSApp?.appearance = NSAppearance(named: .aqua)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let afterLight = try XCTUnwrap(viewer.shownImageForTesting)
        XCTAssertFalse(afterLight === afterDark, "and again on flipping back")
    }

    // MARK: - Contrast floors

    private struct RGBA {
        var r = 0.0, g = 0.0, b = 0.0, a = 1.0
        init(_ colour: CGColor) {
            if let c = colour.converted(
                to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil)?
                .components
            {
                r = Double(c[0]); g = Double(c[1]); b = Double(c[2])
                a = c.count > 3 ? Double(c[3]) : 1
            }
        }
        /// Composited over `backdrop` (also RGBA), channel-wise.
        func over(_ backdrop: RGBA) -> RGBA {
            RGBA(
                r: a * r + (1 - a) * backdrop.r,
                g: a * g + (1 - a) * backdrop.g,
                b: a * b + (1 - a) * backdrop.b, a: 1)
        }
        var luminanceIsDark: Bool { (r + g + b) / 3 < 0.5 }
        /// What `CGColor.copy(alpha:)` does at the draw sites — replaces, not
        /// multiplies — stated once here so the pins measure what ships.
        func copyAlpha(_ alpha: Double) -> RGBA {
            RGBA(r: r, g: g, b: b, a: alpha)
        }
        private init(r: Double, g: Double, b: Double, a: Double) {
            self.r = r; self.g = g; self.b = b; self.a = a
        }
    }

    /// WCAG relative luminance.
    private func luminance(_ c: RGBA) -> Double {
        func linear(_ v: Double) -> Double {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
    }

    private func contrastRatio(_ front: RGBA, _ back: RGBA) -> Double {
        let l1 = luminance(front), l2 = luminance(back)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    /// The language label must read on its own code panel in either
    /// appearance — WCAG's non-text floor of 3:1.
    ///
    /// Measured against the shipped values: `secondary × 0.75` lands near
    /// 8:1 in both appearances, and these pins exist so a future restyle
    /// cannot quietly take the smallest text the editor draws below the
    /// floor.
    func testCodeLabelReadsOnItsOwnPanel() throws {
        // macOS window backgrounds; the editor draws no background of its own.
        let darkPage = RGBA(CGColor(red: 0.118, green: 0.118, blue: 0.118, alpha: 1))
        let lightPage = RGBA(CGColor(red: 1, green: 1, blue: 1, alpha: 1))

        // The real constants, never strings spelled out by hand:
        // `NSAppearance.aqua.rawValue` is "NSAppearanceNameAqua", and
        // `NSAppearance(named:)` answers nil for the short spelling — which
        // would silently leave this test reading whatever snapshot was
        // current when the view was built.
        for (appearanceName, isDark, background) in [
            (NSAppearance.Name.aqua, false, lightPage),
            (NSAppearance.Name.darkAqua, true, darkPage),
        ] {
            let view = makeView("```sh\nx\n```\n", appearance: appearanceName)
            // Effective-appearance propagation for a windowless view lands
            // on a later runloop pass; every reader of the store pumps first.
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            let palette = view.paletteStore.current

            let panel = RGBA(palette.codeBackground).over(background)
            let label = RGBA(palette.secondaryColor).copyAlpha(0.75).over(panel)
            let ratio = contrastRatio(label, panel)
            XCTAssertGreaterThan(
                ratio, 3.0,
                "\(appearanceName.rawValue): the language label reads at "
                    + "\(String(format: "%.2f", ratio)):1 on its own code panel")

            // And it adapts: dimmed decoration ink must sit on the page's own
            // side of grey — lighter than a dark page, darker than a light one.
            let strokeOverPage = RGBA(palette.secondaryColor)
                .copyAlpha(0.55).over(background)
            XCTAssertEqual(
                strokeOverPage.luminanceIsDark, !isDark,
                "\(appearanceName.rawValue): decoration ink resolved on the wrong side")
        }
    }

    /// An unticked checkbox must keep an edge against the page.
    func testUntickedCheckboxKeepsAnEdge() throws {
        let darkPage = RGBA(CGColor(red: 0.118, green: 0.118, blue: 0.118, alpha: 1))
        let lightPage = RGBA(CGColor(red: 1, green: 1, blue: 1, alpha: 1))

        for (appearanceName, background) in [
            (NSAppearance.Name.aqua, lightPage), (NSAppearance.Name.darkAqua, darkPage),
        ] {
            let view = makeView("- [ ] open\n", appearance: appearanceName)
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            let stroke = RGBA(view.paletteStore.current.secondaryColor)
                .copyAlpha(0.55).over(background)
            let ratio = contrastRatio(stroke, background)
            XCTAssertGreaterThanOrEqual(
                ratio, 4.5,
                "\(appearanceName.rawValue): an open task's box reads at "
                    + "\(String(format: "%.2f", ratio)):1 against the page")
        }
    }
}

@MainActor
extension MarkdownLayoutFragment {
    /// Tests read the palette through the store; a fragment without one was
    /// never handed it by the delegate, which is its own failure.
    func requirePalette(file: StaticString = #filePath, line: UInt = #line)
        -> BlockDecorationPalette
    {
        guard let store = paletteStore else {
            XCTFail("fragment has no palette store", file: file, line: line)
            return BlockDecorationPalette(theme: .standard)
        }
        return store.current
    }
}
