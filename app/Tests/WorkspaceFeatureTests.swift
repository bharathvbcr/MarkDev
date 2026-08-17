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
        let range = PanelWidthRange(preferred: 260, minimum: 180, maximum: 420)
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
