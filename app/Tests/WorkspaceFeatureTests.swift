//
//  WorkspaceFeatureTests.swift
//  MarkDevKitTests
//

import XCTest

@testable import MarkDevKit

final class WorkspaceFeatureTests: XCTestCase {
    func testRenameBatchAdmissionIsBoundedStableAndDeduplicated() {
        let first = URL(fileURLWithPath: "/vault/A.md")
        let second = URL(fileURLWithPath: "/vault/B.md")
        let tail = (0..<40).map { URL(fileURLWithPath: "/vault/\($0).md") }

        let request = WorkspaceRenameBatchRequest.bounded(
            [first, first, second] + tail,
            limit: 3)

        XCTAssertEqual(request.urls, [first, second])
        XCTAssertEqual(request.dropped, 41, "duplicate and over-budget items remain visible")
        XCTAssertNotNil(request.truncationMessage)
    }

    func testRenameBatchDoesNotLaunderRemoteFileAuthorityIntoALocalPath() throws {
        let hostile = try XCTUnwrap(
            URL(string: "file://remote.example/vault/Private.md"))

        let request = WorkspaceRenameBatchRequest.bounded([hostile])

        XCTAssertTrue(request.urls.isEmpty)
        XCTAssertEqual(request.dropped, 1)
    }

    func testRenameBatchOutcomeKeepsMovedPartialAndFailedItemsDistinct() {
        var outcome = WorkspaceRenameBatchOutcome()
        let moved = URL(fileURLWithPath: "/vault/Moved.md")
        let partial = URL(fileURLWithPath: "/vault/Partial.md")
        let failed = URL(fileURLWithPath: "/vault/Failed.md")

        outcome.record(.moved, item: moved)
        outcome.record(.movedWithIssue("two links were not rewritten"), item: partial)
        outcome.record(.failed("destination already exists"), item: failed)

        XCTAssertEqual(outcome.movedCount, 2)
        XCTAssertEqual(outcome.issues.map(\.displayName), ["Partial.md", "Failed.md"])
        XCTAssertTrue(outcome.issueMessage?.contains("2 note moves need attention") == true)
    }

    // MARK: - Palette content search

    func testLineOffsetsResolveToUTF16LocationsForReveal() {
        let text = "first\nsecond\nthird with Target\n"
        XCTAssertEqual(Command.offset(ofLine: 1, in: text), 0)
        XCTAssertEqual(Command.offset(ofLine: 2, in: text), 6)
        // "first\nsecond\n" is 13 UTF-16 units; the third line starts there.
        XCTAssertEqual(Command.offset(ofLine: 3, in: text), 13)
        // A line past the document lands at the end rather than crashing.
        XCTAssertEqual(Command.offset(ofLine: 99, in: text), text.utf16.count)
    }

    func testSearchResultCommandsCarryTheirLine() {
        let url = URL(fileURLWithPath: "/vault/Note.md")
        let command = Command(
            title: "Note", subtitle: "…mentions it here",
            symbol: "magnifyingglass", kind: .searchResult(url, line: 7))
        guard case .searchResult(_, let line) = command.kind else {
            return XCTFail("expected a search result")
        }
        XCTAssertEqual(line, 7)
    }
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

    func testWindowGeometryTracksHorizontalPanesAndVisiblePanels() {
        let first = PaneID()
        let second = PaneID()
        let single = SplitLayout(pane: first)
        let horizontal = SplitLayout(
            root: .split(
                SplitNodeGroup(
                    axis: .horizontal,
                    children: [.leaf(first), .leaf(second)],
                    fractions: [0.5, 0.5])))
        let vertical = SplitLayout(
            root: .split(
                SplitNodeGroup(
                    axis: .vertical,
                    children: [.leaf(first), .leaf(second)],
                    fractions: [0.5, 0.5])))

        XCTAssertEqual(
            WorkspaceWindowGeometry(
                layout: single, showsSidebar: false, showsInspector: false
            ).desiredMinimumWidth,
            360)
        XCTAssertEqual(
            WorkspaceWindowGeometry(
                layout: single, showsSidebar: true, showsInspector: true
            ).desiredMinimumWidth,
            680)
        XCTAssertEqual(
            WorkspaceWindowGeometry(
                layout: horizontal, showsSidebar: true, showsInspector: true
            ).desiredMinimumWidth,
            950)
        XCTAssertEqual(
            WorkspaceWindowGeometry(
                layout: vertical, showsSidebar: true, showsInspector: true
            ).desiredMinimumWidth,
            680,
            "vertical splits consume height rather than another editor column")
    }

    func testWindowGeometryHonoursNarrowScreenAndInvalidProposals() {
        let geometry = WorkspaceWindowGeometry(
            layout: SplitLayout(pane: PaneID()),
            showsSidebar: true,
            showsInspector: true)

        XCTAssertEqual(geometry.minimumWidth(maximumAvailableWidth: 540), 540)
        XCTAssertEqual(geometry.minimumWidth(maximumAvailableWidth: 2_000), 680)
        XCTAssertEqual(geometry.minimumWidth(maximumAvailableWidth: nil), 680)
        XCTAssertEqual(geometry.minimumWidth(maximumAvailableWidth: .nan), 680)
        XCTAssertEqual(geometry.minimumWidth(maximumAvailableWidth: -1), 680)
    }

    func testCloseReviewSheetUsesCompactWidthAndStacksAccessibilityActions() {
        XCTAssertEqual(CloseReviewSheetLayout.width(availableWidth: nil), 510)
        XCTAssertEqual(CloseReviewSheetLayout.width(availableWidth: 360), 360)
        XCTAssertEqual(CloseReviewSheetLayout.width(availableWidth: 900), 620)
        XCTAssertEqual(CloseReviewSheetLayout.width(availableWidth: .nan), 510)

        XCTAssertEqual(
            CloseReviewSheetLayout.actionAxis(
                availableContentWidth: 470,
                buttonWidths: [70, 105, 90, 65],
                spacing: 10),
            .horizontal)
        XCTAssertEqual(
            CloseReviewSheetLayout.actionAxis(
                availableContentWidth: 470,
                buttonWidths: [125, 185, 155, 110],
                spacing: 10),
            .vertical,
            "large accessibility labels must stack before any action clips")
        XCTAssertEqual(
            CloseReviewSheetLayout.actionAxis(
                availableContentWidth: 260,
                buttonWidths: [70, 105, 90, 65],
                spacing: 10),
            .vertical)
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
