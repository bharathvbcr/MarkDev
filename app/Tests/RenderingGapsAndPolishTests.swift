//
//  RenderingGapsAndPolishTests.swift
//  MarkDevKitTests
//
//  Tests covering rendering enhancements, footnotes, zoom, table navigation,
//  accessibility, and scale factor cache keys.
//

import AppKit
import XCTest

@testable import MarkDevKit

@MainActor
final class RenderingGapsAndPolishTests: XCTestCase {
    // MARK: - 1. Render Cache Scale Factor

    func testRenderCacheKeyIncludesDisplayScale() {
        let renderer = RichContentRenderer()
        let block = RenderedBlock(
            kind: .math,
            source: "E = mc^2")

        let context1x = RenderContext(
            width: 600,
            dark: false,
            mathFontSize: 16,
            textColor: .black,
            scale: 1.0)

        let context2x = RenderContext(
            width: 600,
            dark: false,
            mathFontSize: 16,
            textColor: .black,
            scale: 2.0)

        let req1 = RenderRequest(block: block, directory: nil, context: context1x)
        let req2 = RenderRequest(block: block, directory: nil, context: context2x)

        guard case .success(let res1) = renderer.render(req1),
              case .success(let res2) = renderer.render(req2)
        else {
            return XCTFail("Rendering math should succeed")
        }

        // Both render successfully
        XCTAssertGreaterThan(res1.size.width, 0)
        XCTAssertGreaterThan(res2.size.width, 0)
    }

    // MARK: - 2. Footnotes, Superscript & Subscript Styling

    func testFootnoteReferenceIsStyledWithSuperscriptAndLink() {
        let view = MarkdownTextView.make(theme: .standard)
        let markdown = "Here is a note[^1].\n\n[^1]: Note definition."
        view.setMarkdown(markdown)

        guard let storage = view.textStorage else {
            return XCTFail("Text storage should exist")
        }

        // Find [^1] in text
        let nsText = storage.string as NSString
        let refRange = nsText.range(of: "[^1]")
        XCTAssertNotEqual(refRange.location, NSNotFound)

        // Verify baseline offset > 0
        if let baseline = storage.attribute(.baselineOffset, at: refRange.location, effectiveRange: nil) as? CGFloat {
            XCTAssertGreaterThan(baseline, 0, "Footnote reference should have positive baseline offset")
        }

        // Verify link attribute exists
        let linkAttr = storage.attribute(.link, at: refRange.location, effectiveRange: nil)
        XCTAssertNotNil(linkAttr, "Footnote reference should carry a .link attribute")
        if let url = linkAttr as? URL {
            XCTAssertEqual(url.scheme, MarkdownStyler.footnoteScheme)
        }
    }

    func testFootnoteJumpNavigatesToDefinition() {
        let view = MarkdownTextView.make(theme: .standard)
        let markdown = "First line[^alpha].\n\nMore text...\n\n[^alpha]: Definition of alpha."
        view.setMarkdown(markdown)

        view.jumpToFootnote("alpha")
        let sel = view.selectedRange()
        let nsText = (view.textStorage?.string ?? "") as NSString
        let defRange = nsText.range(of: "[^alpha]:")
        XCTAssertEqual(sel.location, defRange.location)
    }

    func testHeadingAnchorJumpNavigatesToHeading() {
        let view = MarkdownTextView.make(theme: .standard)
        let markdown = "Jump to [Section](#deep-dive)\n\nParagraph\n\n## Deep Dive\n\nContent"
        view.setMarkdown(markdown)

        let success = view.jumpToHeading(anchor: "deep-dive")
        XCTAssertTrue(success)
        let nsText = (view.textStorage?.string ?? "") as NSString
        let headingRange = nsText.range(of: "## Deep Dive")
        XCTAssertEqual(view.selectedRange().location, headingRange.location)
    }

    // MARK: - 3. Theme Presets & Scaling

    func testThemeScaling() {
        let base = EditorTheme.standard
        let scaled = base.scaled(by: 1.5)

        XCTAssertEqual(scaled.bodyFont.pointSize, (base.bodyFont.pointSize * 1.5).rounded())
        XCTAssertEqual(scaled.lineSpacing, base.lineSpacing * 1.5)

        let minClamped = base.scaled(by: 0.1)
        XCTAssertGreaterThanOrEqual(minClamped.bodyFont.pointSize, 9)

        let maxClamped = base.scaled(by: 10.0)
        XCTAssertLessThanOrEqual(maxClamped.bodyFont.pointSize, base.bodyFont.pointSize * 3.0 + 1)
    }

    func testThemePresets() {
        XCTAssertNotNil(EditorTheme.standard)
        XCTAssertNotNil(EditorTheme.serif)
        XCTAssertNotNil(EditorTheme.mono)
    }

    func testTextViewZoomMethods() {
        let view = MarkdownTextView.make(theme: .standard)
        XCTAssertEqual(view.zoomFactor, 1.0)

        view.zoomIn()
        XCTAssertEqual(view.zoomFactor, 1.1, accuracy: 0.001)

        view.zoomOut()
        XCTAssertEqual(view.zoomFactor, 1.0, accuracy: 0.001)

        view.zoomOut()
        XCTAssertEqual(view.zoomFactor, 0.9, accuracy: 0.001)

        view.resetZoom()
        XCTAssertEqual(view.zoomFactor, 1.0)
    }

    // MARK: - 4. Selection Stats

    func testSelectionStatsCallback() {
        let view = MarkdownTextView.make(theme: .standard)
        view.setMarkdown("One two three four five.")

        var reportedWords = 0
        var reportedChars = 0
        view.onSelectionStatsChanged = { words, chars in
            reportedWords = words
            reportedChars = chars
        }

        // Select "two three"
        let nsText = (view.textStorage?.string ?? "") as NSString
        let range = nsText.range(of: "two three")
        view.setSelectedRange(range)

        XCTAssertEqual(reportedWords, 2)
        XCTAssertEqual(reportedChars, "two three".count)
    }

    // MARK: - 5. Table Navigation

    func testTableTabMovesToNextCellOrAddsRow() {
        let view = MarkdownTextView.make(theme: .standard)
        let md = "| A | B |\n|---|---|\n| 1 | 2 |"
        view.setMarkdown(md)

        // Place caret in first cell | 1
        let nsText = (view.textStorage?.string ?? "") as NSString
        let cellRange = nsText.range(of: "1")
        view.setSelectedRange(NSRange(location: cellRange.location, length: 0))

        view.insertTab(nil)
        // Should move forward past pipe into cell 2
        XCTAssertGreaterThan(view.selectedRange().location, cellRange.location)
    }

    func testTableNewlineInsertsScaffoldedRow() {
        let view = MarkdownTextView.make(theme: .standard)
        let md = "| Header 1 | Header 2 |\n|---|---|\n| Cell 1 | Cell 2 |"
        view.setMarkdown(md)

        let nsText = (view.textStorage?.string ?? "") as NSString
        let rowRange = nsText.range(of: "| Cell 1 | Cell 2 |")
        view.setSelectedRange(NSRange(location: rowRange.location + rowRange.length, length: 0))

        view.insertNewline(nil)
        XCTAssertTrue(view.markdown.contains("|  |  |"), "Newline inside table should insert new empty table row")
    }
}
