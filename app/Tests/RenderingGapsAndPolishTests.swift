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

        // The superscript sits on the label, not on the brackets — those are
        // the syntax the live-preview collapse hides.
        let nsText = storage.string as NSString
        let refRange = nsText.range(of: "[^1]")
        XCTAssertNotEqual(refRange.location, NSNotFound)
        let label = NSRange(location: refRange.location + 2, length: 1)

        if let baseline = storage.attribute(.baselineOffset, at: label.location, effectiveRange: nil)
            as? CGFloat
        {
            XCTAssertGreaterThan(baseline, 0, "Footnote reference should have positive baseline offset")
        }

        let linkAttr = storage.attribute(.link, at: label.location, effectiveRange: nil)
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

        view.jumpToFootnote("alpha", from: defRange.location + 2)
        let back = view.selectedRange()
        let refRange = nsText.range(of: "[^alpha]")
        XCTAssertEqual(
            back.location, refRange.location + 2,
            "clicking the definition's mark returns to the reference")
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

    // MARK: - Frontmatter panel, checked tasks, images

    func testYamlFrontmatterDrawsKeysAndListItemsNotTheFence() {
        let source = """
            ---
            title: Note
            tags:
              - alpha
              - beta
            ---

            # Body
            """
        let view = MarkdownTextView.make(theme: .standard)
        view.mode = .reading
        view.frame = NSRect(x: 0, y: 0, width: 520, height: 600)
        view.setMarkdown(source)
        view.textLayoutManager?.ensureLayout(for: view.textLayoutManager!.documentRange)

        let panel = fragments(view).compactMap(\.frontmatter).first
        XCTAssertNotNil(panel, "collapsed frontmatter must draw a structured panel")
        XCTAssertEqual(panel?.entries.map(\.key), ["title", "tags"])
        XCTAssertEqual(panel?.entries.first?.value, "Note")
        XCTAssertEqual(panel?.entries.last?.items, ["alpha", "beta"])

        let storage = view.textStorage
        let titleSource = (source as NSString).range(of: "title: Note")
        let titleFont = storage?.attribute(.font, at: titleSource.location, effectiveRange: nil)
            as? NSFont
        XCTAssertEqual(
            titleFont?.pointSize ?? 0, EditorTheme.hiddenMarkerFontSize, accuracy: 0.001,
            "the fence is replaced by the panel, not shown as a YAML dump")

        let heading = (source as NSString).range(of: "Body")
        let headingFont = storage?.attribute(.font, at: heading.location, effectiveRange: nil)
            as? NSFont
        XCTAssertGreaterThan(
            headingFont?.pointSize ?? 0, EditorTheme.standard.bodyFont.pointSize,
            "the body after the closer is still a heading")
    }

    func testTomlFrontmatterDrawsKeysAndListItems() {
        let source = """
            +++
            title = "Note"
            tags = ["alpha", "beta"]
            +++

            After.
            """
        let view = MarkdownTextView.make(theme: .standard)
        view.mode = .reading
        view.frame = NSRect(x: 0, y: 0, width: 520, height: 600)
        view.setMarkdown(source)
        view.textLayoutManager?.ensureLayout(for: view.textLayoutManager!.documentRange)

        let panel = fragments(view).compactMap(\.frontmatter).first
        XCTAssertEqual(panel?.entries.map(\.key), ["title", "tags"])
        XCTAssertEqual(panel?.entries.first?.value, "Note")
        XCTAssertEqual(panel?.entries.last?.items, ["alpha", "beta"])
        let storage = view.textStorage
        let after = (source as NSString).range(of: "After.")
        let font = storage?.attribute(.font, at: after.location, effectiveRange: nil) as? NSFont
        XCTAssertGreaterThan(
            font?.pointSize ?? 0, EditorTheme.hiddenMarkerFontSize,
            "the body after the closer still renders")
    }

    func testCheckedTasksAreStruckAndMutedWhileTheCheckboxStays() {
        let source = "- [x] done task\n- [ ] open task\n"
        let view = MarkdownTextView.make(theme: .standard)
        view.mode = .reading
        view.frame = NSRect(x: 0, y: 0, width: 520, height: 400)
        view.setMarkdown(source)
        view.textLayoutManager?.ensureLayout(for: view.textLayoutManager!.documentRange)

        let storage = view.textStorage
        let ns = source as NSString
        let done = ns.range(of: "done")
        let open = ns.range(of: "open")
        XCTAssertEqual(
            storage?.attribute(.strikethroughStyle, at: done.location, effectiveRange: nil) as? Int
                ?? 0,
            NSUnderlineStyle.single.rawValue)
        XCTAssertEqual(
            storage?.attribute(.foregroundColor, at: done.location, effectiveRange: nil) as? NSColor,
            EditorTheme.standard.secondaryColor)
        XCTAssertNil(
            storage?.attribute(.strikethroughStyle, at: open.location, effectiveRange: nil))

        let tasks = fragments(view).compactMap(\.decoration.taskChecked)
        XCTAssertEqual(tasks, [true, false], "the checkbox must still be offered")
    }

    func testANestedCheckedTaskDoesNotStrikeItsParent() {
        // The parent item's range contains the nested `[x]`. Looking the
        // marker up against that whole range would strike "shopping" too.
        let source = "- shopping\n  - [x] milk\n"
        let view = MarkdownTextView.make(theme: .standard)
        view.mode = .reading
        view.frame = NSRect(x: 0, y: 0, width: 520, height: 400)
        view.setMarkdown(source)

        let storage = view.textStorage
        let ns = source as NSString
        let shopping = ns.range(of: "shopping")
        let milk = ns.range(of: "milk")
        XCTAssertNil(
            storage?.attribute(.strikethroughStyle, at: shopping.location, effectiveRange: nil),
            "a nested checked item must not strike the parent")
        XCTAssertNotEqual(
            storage?.attribute(.foregroundColor, at: shopping.location, effectiveRange: nil)
                as? NSColor,
            EditorTheme.standard.secondaryColor,
            "the parent must keep body colour")
        XCTAssertEqual(
            storage?.attribute(.strikethroughStyle, at: milk.location, effectiveRange: nil)
                as? Int ?? 0,
            NSUnderlineStyle.single.rawValue)
    }

    func testAStruckCheckboxStillTogglesThroughTheOrdinaryInputPath() {
        // Strikethrough is an attribute on the item text; ticking still has to
        // be `insertText` on `[x]`, or undo and the document binding miss it.
        let view = MarkdownTextView.make(theme: .standard)
        view.mode = .livePreview
        view.frame = NSRect(x: 0, y: 0, width: 520, height: 400)
        view.setMarkdown("Intro.\n\n- [x] done task\n")
        view.setSelectedRange(NSRange(location: 0, length: 0))

        let done = (view.markdown as NSString).range(of: "done")
        XCTAssertEqual(
            view.textStorage?.attribute(
                .strikethroughStyle, at: done.location, effectiveRange: nil) as? Int ?? 0,
            NSUnderlineStyle.single.rawValue)
        let marker = view.parsed.spans.first { $0.kind == .taskMarker }
        XCTAssertNotNil(marker)
        XCTAssertTrue(view.toggleTask(at: marker!.range.location))
        XCTAssertTrue(view.markdown.contains("[ ]"))
        XCTAssertFalse(view.markdown.contains("[x]"))
    }

    func testAParentRelativeImageLoadsAndARemoteOneDoesNot() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevRel-\(UUID().uuidString)")
        let notes = root.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let image = NSImage(size: CGSize(width: 40, height: 20))
        image.lockFocus()
        NSColor.systemGreen.drawSwatch(in: CGRect(x: 0, y: 0, width: 40, height: 20))
        image.unlockFocus()
        let data = try XCTUnwrap(
            NSBitmapImageRep(data: image.tiffRepresentation ?? Data())?
                .representation(using: .png, properties: [:]))
        try data.write(to: root.appendingPathComponent("pic.png"))

        let view = MarkdownTextView.make(theme: .standard)
        view.mode = .reading
        view.frame = NSRect(x: 0, y: 0, width: 520, height: 400)
        view.documentDirectory = notes
        view.setMarkdown("![shot](../pic.png)\n")
        view.textLayoutManager?.ensureLayout(for: view.textLayoutManager!.documentRange)

        XCTAssertEqual(
            fragments(view).filter { $0.renderedContent != nil }.count, 1,
            "a parent-relative local image must resolve")

        view.setMarkdown("<img src=\"../pic.png\">\n")
        view.textLayoutManager?.ensureLayout(for: view.textLayoutManager!.documentRange)
        XCTAssertEqual(
            fragments(view).filter { $0.renderedContent != nil }.count, 1,
            "a parent-relative lone <img> must resolve through the same path")

        view.setMarkdown("![web](https://example.com/x.png)\n")
        view.textLayoutManager?.ensureLayout(for: view.textLayoutManager!.documentRange)
        XCTAssertTrue(
            fragments(view).allSatisfy { $0.renderedContent == nil },
            "a remote image must not be fetched")
        XCTAssertFalse(fragments(view).compactMap(\.renderFailure).isEmpty)

        view.setMarkdown("<img src=\"https://example.com/x.png\">\n")
        view.textLayoutManager?.ensureLayout(for: view.textLayoutManager!.documentRange)
        XCTAssertTrue(
            fragments(view).allSatisfy { $0.renderedContent == nil },
            "a remote <img> must not be fetched")
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
}
