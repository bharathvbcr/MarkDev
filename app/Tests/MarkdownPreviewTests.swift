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
