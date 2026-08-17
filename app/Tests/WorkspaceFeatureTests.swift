//
//  WorkspaceFeatureTests.swift
//  MarkDevKitTests
//

import XCTest

@testable import MarkDevKit

final class WorkspaceFeatureTests: XCTestCase {
    func testDocumentStatsCountReaderVisibleUnits() {
        let stats = DocumentStats("**Hello**, state-of-the-art café 🎉\nNext line\n")

        XCTAssertEqual(stats.words, 5)
        XCTAssertEqual(stats.characters, 45)
        XCTAssertEqual(stats.lines, 3)
    }

    func testDocumentStatsIgnorePunctuationOnlyMarkdown() {
        XCTAssertEqual(DocumentStats("## --- | ** -").words, 0)
        XCTAssertEqual(DocumentStats("").lines, 0)
        XCTAssertEqual(DocumentStats("one").lines, 1)
    }

    func testReadingTimeRoundsUpAndNeverReportsZeroForProse() {
        XCTAssertEqual(DocumentStats("one word").readingMinutes, 1)
        let long = Array(repeating: "word", count: 221).joined(separator: " ")
        XCTAssertEqual(DocumentStats(long).readingMinutes, 2)
    }

    func testPanelWidthsClampBoundariesAndNonFiniteValues() {
        let range = PanelSizeRange(preferred: 260, minimum: 180, maximum: 420)
        XCTAssertEqual(range.clamping(100), 180)
        XCTAssertEqual(range.clamping(500), 420)
        XCTAssertEqual(range.clamping(.nan), 260)
        XCTAssertEqual(range.clamping(.infinity), 260)
    }

    func testMinimumWindowFitsTwoReadableEditorsAndBothPanels() {
        let chrome =
            GlassTheme.sidebar.preferred + GlassTheme.inspector.preferred
            + (GlassTheme.dividerHitWidth * 3)
        let editors = GlassTheme.minimumEditorPaneWidth * 2

        XCTAssertEqual(GlassTheme.minimumTwoPaneWindowWidth, chrome + editors)
        XCTAssertEqual(GlassTheme.minimumTwoPaneWindowWidth, 1_270)
    }

    // MARK: - Writing modes

    // The switcher shows the selected mode's label and nothing but glyphs for
    // the rest, so these strings are the whole of what distinguishes a mode in
    // the toolbar, the palette, the menu bar, and VoiceOver.

    func testEveryModeIsNamedAndDrawnDistinctly() {
        let modes = EditorMode.allCases
        XCTAssertEqual(Set(modes.map(\.title)).count, modes.count)
        XCTAssertEqual(Set(modes.map(\.commandTitle)).count, modes.count)
        XCTAssertEqual(Set(modes.map(\.symbol)).count, modes.count)
        XCTAssertEqual(Set(modes.map(\.summary)).count, modes.count)
        XCTAssertTrue(
            modes.allSatisfy { !$0.title.isEmpty && !$0.summary.isEmpty },
            "an icon-only segment has nothing but its tooltip to explain it")
    }

    func testReadingModeIsLabelledReadAndDrawnAsABook() {
        XCTAssertEqual(EditorMode.reading.title, "Read")
        XCTAssertEqual(EditorMode.reading.symbol, "book")
        XCTAssertEqual(EditorMode.reading.commandTitle, "Reading Mode")
    }

    /// The menu and the palette number the modes by their position in
    /// `allCases` (⌃1, ⌃2, ⌃3), and the switcher lays them out in the same
    /// order. Reordering the enum silently reassigns those shortcuts.
    func testModeOrderIsTheOrderTheShortcutsAreNumberedIn() {
        XCTAssertEqual(EditorMode.allCases, [.livePreview, .source, .reading])
    }

    func testSettingAModeIsOneActionRatherThanOnePerMode() {
        XCTAssertEqual(
            Command(title: "Lesen", symbol: "book", kind: .action(.setMode(.reading))).kind,
            .action(.setMode(.reading)))
        XCTAssertNotEqual(CommandAction.setMode(.reading), .setMode(.source))
    }

    // MARK: - Split controls

    // The pane's split buttons are glyphs in a capsule, so the tooltip is the
    // only text a pointer user ever sees for them.

    func testEverySplitDirectionHasItsOwnNameAndTooltip() {
        let edges: [SplitEdge] = [.leading, .trailing, .top, .bottom]
        XCTAssertEqual(Set(edges.map(\.commandTitle)).count, edges.count)
        XCTAssertEqual(Set(edges.map(\.controlHelp)).count, edges.count)
        XCTAssertTrue(
            edges.allSatisfy { !$0.controlHelp.isEmpty },
            "a glyph-only control with no tooltip cannot be explained at all")
    }

    func testSplitGlyphsMatchTheAxisTheyDivideAlong() {
        XCTAssertEqual(SplitEdge.leading.symbol, SplitEdge.trailing.symbol)
        XCTAssertEqual(SplitEdge.top.symbol, SplitEdge.bottom.symbol)
        XCTAssertNotEqual(SplitEdge.trailing.symbol, SplitEdge.bottom.symbol)
    }

    /// The tooltip, the menu item, and the palette row are the same control
    /// seen three ways; they must not drift into three different names.
    func testSplitControlsAreNamedTheSameEverywhere() {
        XCTAssertEqual(SplitEdge.trailing.commandTitle, "Split Right")
        XCTAssertEqual(SplitEdge.bottom.commandTitle, "Split Down")
        XCTAssertTrue(SplitEdge.trailing.controlHelp.hasPrefix("Split right"))
        XCTAssertTrue(SplitEdge.bottom.controlHelp.hasPrefix("Split down"))
    }

    func testOutlineComesFromTheCurrentParseWithoutAVault() {
        let source = "Intro\n=====\n\n## Café ##\n\nBody"
        let headings = DocumentOutline.headings(
            in: ParsedDocument.parse(source), text: source)

        XCTAssertEqual(headings.map(\.text), ["Intro", "Café"])
        XCTAssertEqual(headings.map(\.level), [1, 2])
        XCTAssertEqual(headings.map(\.line), [1, 4])
        XCTAssertEqual(headings.map(\.offset), [0, 13])
    }
}
