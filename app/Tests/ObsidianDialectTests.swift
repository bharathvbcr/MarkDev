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
        let markers = doc.spans.filter { $0.kind == .taskMarker }
        XCTAssertEqual(markers.map { $0.data & 1 }, [1, 0])
        XCTAssertEqual(markers.first.map { $0.data >> 8 }, UInt32(("/" as Unicode.Scalar).value))
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
        XCTAssertTrue(reading.covers(body), "reading mode folds too")

        let clickedOpen = HiddenRanges(
            document: parsed, selection: NSRange(location: 0, length: 0),
            mode: .reading, text: text, calloutToggles: [0])
        XCTAssertFalse(clickedOpen.covers(body), "a click on the title unfolds it")
    }

    func testAnExpandedFoldableCalloutFoldsWhenToggled() {
        let source = "> [!bug]+ Open\n> shown body\n\nAfter"
        let text = source as NSString
        let parsed = ParsedDocument.parse(source)
        let body = text.range(of: "shown body")
        let away = NSRange(location: text.length, length: 0)
        XCTAssertFalse(
            HiddenRanges(document: parsed, selection: away, mode: .reading, text: text)
                .covers(body))
        XCTAssertTrue(
            HiddenRanges(
                document: parsed, selection: away, mode: .reading, text: text,
                calloutToggles: [0]
            ).covers(body))
    }

    func testCalloutLabelsCarryASymbolAndAPlainTitle() {
        XCTAssertTrue(CalloutKind.allCases.allSatisfy { $0.symbol.hasSuffix("\u{FE0E}") })
        XCTAssertEqual(Set(CalloutKind.allCases.map(\.symbol)).count, CalloutKind.allCases.count)
        XCTAssertEqual(CalloutKind.plainTitle("**Why** [[Plan|this]] ==now=="), "Why this now")
        XCTAssertEqual(CalloutKind.plainTitle("See [docs](https://x.y) and `code`"), "See docs and code")
        XCTAssertEqual(CalloutKind.plainTitle("snake_case stays"), "snake_case stays")
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

    func testObsidianAttachmentFolderSettingIsHonoured() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkDevSetting-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = root.appendingPathComponent("Notes", isDirectory: true)
        let configured = root.appendingPathComponent("Files/Images", isDirectory: true)
        let obsidian = root.appendingPathComponent(".obsidian", isDirectory: true)
        for folder in [notes, configured, obsidian] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data(#"{"attachmentFolderPath": "Files/Images"}"#.utf8)
            .write(to: obsidian.appendingPathComponent("app.json"))
        try Data([0x89]).write(to: configured.appendingPathComponent("shot.png"))

        XCTAssertEqual(
            RichContentRenderer.configuredAttachmentFolder(from: notes)?.standardizedFileURL.path,
            configured.standardizedFileURL.path)
        XCTAssertEqual(
            RichContentRenderer.attachmentFallback(for: "shot.png", from: notes)?
                .lastPathComponent, "shot.png")
    }

    func testPicturesAreFoundAnywhereInTheVaultByName() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkDevIndex-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = root.appendingPathComponent("Journal/2026", isDirectory: true)
        let deep = root.appendingPathComponent("Projects/Alpha/Screens", isDirectory: true)
        for folder in [notes, deep, root.appendingPathComponent(".obsidian")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data([0x89]).write(to: deep.appendingPathComponent("Pasted image 1.png"))

        let found = RichContentRenderer.attachmentFallback(
            for: "Pasted image 1.png", from: notes)
        XCTAssertEqual(found?.standardizedFileURL.path,
            deep.appendingPathComponent("Pasted image 1.png").standardizedFileURL.path)
        XCTAssertEqual(
            VaultFileIndex.shared.find("screens/pasted IMAGE 1.png", in: root)?.lastPathComponent,
            "Pasted image 1.png")
        XCTAssertNil(VaultFileIndex.shared.find("../escape.png", in: root))
    }

    func testStandaloneNoteEmbedBecomesAnEmbedCard() {
        let source = "Intro\n\n![[Project Plan#Goals|Our goals]]\n\nText with ![[Inline]] embed."
        let parsed = ParsedDocument.parse(source)
        let rendered = RenderedBlocks(document: parsed, text: source as NSString)
        XCTAssertEqual(rendered.entries.count, 1, "only the standalone embed becomes a card")
        XCTAssertEqual(rendered.entries.first?.content.kind, .noteEmbed(title: "Our goals"))
        XCTAssertEqual(rendered.entries.first?.content.source, "Project Plan#Goals")
    }

    func testNoteExcerptsFollowTheEmbedAnchor() {
        let note = """
            ---
            tags: [x]
            ---
            # Plan

            Intro. %%private%%

            ## Goals

            Ship it. ^ship

            ## Later

            Not now.
            """
        let whole = RichContentRenderer.noteExcerpt(note, anchor: nil)
        XCTAssertTrue(whole.hasPrefix("Plan"))
        XCTAssertFalse(whole.contains("tags:"))
        XCTAssertFalse(whole.contains("private"))
        XCTAssertFalse(whole.contains("^ship"))

        let goals = RichContentRenderer.noteExcerpt(note, anchor: "Goals")
        XCTAssertTrue(goals.contains("Ship it."))
        XCTAssertFalse(goals.contains("Not now."))
        XCTAssertEqual(RichContentRenderer.noteExcerpt(note, anchor: "Plan#Goals"), goals)

        XCTAssertEqual(RichContentRenderer.noteExcerpt(note, anchor: "^ship"), "Ship it.")
        XCTAssertEqual(RichContentRenderer.noteExcerpt(note, anchor: "Missing"), "")
    }
}
