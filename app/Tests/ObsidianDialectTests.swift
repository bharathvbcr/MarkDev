//
//  ObsidianDialectTests.swift
//  MarkDevKitTests
//
//  Obsidian syntax across the FFI and into what the editor draws. The parser
//  rules themselves are pinned in core/tests/obsidian_dialect.rs.
//

import XCTest

@testable import MarkDevKit

final class ObsidianDialectTests: XCTestCase {
    func testEveryObsidianCalloutTypeDecodes() {
        let cases: [(String, CalloutKind)] = [
            ("abstract", .abstract), ("summary", .abstract), ("info", .info),
            ("todo", .todo), ("hint", .tip), ("success", .success), ("done", .success),
            ("faq", .question), ("attention", .warning), ("fail", .failure),
            ("error", .danger), ("bug", .bug), ("example", .example), ("cite", .quote),
            ("my-custom", .note),
        ]
        for (name, expected) in cases {
            let doc = ParsedDocument.parse("> [!\(name)]\n> body")
            let callout = doc.blocks.first { $0.kind == .callout }
            XCTAssertEqual(callout?.calloutKind, expected, name)
        }
    }

    func testFoldStateDecodesWithoutDisturbingTheKind() {
        let folded = ParsedDocument.parse("> [!tip]- Later\n> body")
            .blocks.first { $0.kind == .callout }
        XCTAssertEqual(folded?.calloutKind, .tip)
        XCTAssertEqual(folded?.calloutFold, .collapsed)
        XCTAssertEqual(folded?.info, "Later")

        let open = ParsedDocument.parse("> [!bug]+\n> body").blocks.first { $0.kind == .callout }
        XCTAssertEqual(open?.calloutFold, .expanded)

        let fixed = ParsedDocument.parse("> [!NOTE]\n> body").blocks.first { $0.kind == .callout }
        XCTAssertEqual(fixed?.calloutFold, .fixed)
    }

    func testEveryCalloutKindHasATitleAndAnAccent() {
        let theme = EditorTheme.standard
        for kind in CalloutKind.allCases {
            XCTAssertFalse(kind.title.isEmpty)
            _ = theme.calloutAccent(kind)
        }
    }

    func testCommentsAndInlineFootnotesCrossTheBridge() {
        let doc = ParsedDocument.parse("Text %%hidden [[Link]]%% and a claim^[source].")
        XCTAssertEqual(doc.spans.filter { $0.kind == .comment }.count, 1)
        XCTAssertEqual(doc.spans.filter { $0.kind == .inlineFootnote }.count, 1)
        XCTAssertFalse(
            doc.spans.contains { $0.kind == .wikiLink },
            "a link inside a comment must not navigate")
    }

    func testNoteEmbedsAreWikiLinksAndPictureEmbedsAreImages() {
        let doc = ParsedDocument.parse("![[Project Plan]]\n\n![[photo.png|300]]")
        let wiki = doc.spans.first { $0.kind == .wikiLink }
        XCTAssertEqual(wiki.flatMap(doc.target(for:)), "Project Plan")
        let image = doc.spans.first { $0.kind == .image }
        XCTAssertEqual(image.flatMap(doc.target(for:)), "photo.png")
    }

    func testCustomTaskStatusesAreCheckedTasks() {
        let doc = ParsedDocument.parse("- [/] half\n- [ ] open")
        let markers = doc.spans.filter { $0.kind == .taskMarker }.map(\.data)
        XCTAssertEqual(markers, [1, 0])
    }

    func testStandaloneEmbedRendersAsASizedPicture() {
        let source = "![[photo.png|240]]"
        let parsed = ParsedDocument.parse(source)
        let rendered = RenderedBlocks(document: parsed, text: source as NSString)
        let content = rendered.entries.first?.content
        XCTAssertEqual(content?.source, "photo.png")
        XCTAssertEqual(content?.width, 240)
        XCTAssertEqual(content?.kind, .image(alt: "photo.png"))
    }

    func testMarkdownImageSizeSuffixIsAWidth() {
        let source = "![A cat|180](cat.png)"
        let parsed = ParsedDocument.parse(source)
        let rendered = RenderedBlocks(document: parsed, text: source as NSString)
        XCTAssertEqual(rendered.entries.first?.content.width, 180)
        XCTAssertEqual(rendered.entries.first?.content.kind, .image(alt: "A cat"))
    }

    func testSizeSuffixParsing() {
        XCTAssertEqual(RenderedBlocks.obsidianSize("300").width, 300)
        XCTAssertEqual(RenderedBlocks.obsidianSize("300x200").width, 300)
        XCTAssertEqual(RenderedBlocks.obsidianSize("A cat|250").alt, "A cat")
        XCTAssertNil(RenderedBlocks.obsidianSize("A caption").width)
        XCTAssertNil(RenderedBlocks.obsidianSize("a|b").width)
        XCTAssertNil(RenderedBlocks.obsidianSize("0").width)
    }

    func testFoldedCalloutHidesItsBodyUntilTheCaretEntersIt() {
        let source = "> [!tip]- Later\n> hidden body\n\nAfter"
        let text = source as NSString
        let parsed = ParsedDocument.parse(source)
        let away = HiddenRanges(
            document: parsed, selection: NSRange(location: text.length, length: 0),
            mode: .livePreview, text: text)
        let body = text.range(of: "hidden body")
        XCTAssertTrue(away.covers(body), "folded body collapses while the caret is away")
        XCTAssertFalse(away.covers(text.range(of: "After")))

        let inside = HiddenRanges(
            document: parsed, selection: NSRange(location: body.location, length: 0),
            mode: .livePreview, text: text)
        XCTAssertFalse(inside.covers(body), "caret inside unfolds it")

        let reading = HiddenRanges(
            document: parsed, selection: NSRange(location: 0, length: 0),
            mode: .reading, text: text)
        XCTAssertFalse(reading.covers(body), "reading mode has no caret to unfold with")
    }

    func testAttachmentFallbackFindsObsidianAttachmentFolders() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkDevVault-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = root.appendingPathComponent("Notes/Daily", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        let attachments = root.appendingPathComponent("attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        try Data([0x89]).write(to: attachments.appendingPathComponent("Pasted image.png"))

        let found = RichContentRenderer.attachmentFallback(
            for: "Pasted image.png", from: notes)
        XCTAssertEqual(found?.lastPathComponent, "Pasted image.png")
        XCTAssertNil(RichContentRenderer.attachmentFallback(for: "missing.png", from: notes))
    }
}
