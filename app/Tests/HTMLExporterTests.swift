import XCTest

@testable import MarkDevKit

final class HTMLExporterTests: XCTestCase {
    func testRendersMarkdownAndMakesRawHTMLInert() throws {
        let html = try HTMLExporter.render(
            markdown: "# Heading\n\nA **strong** idea.\n\n<script>owned()</script>",
            title: "<img src=x onerror=owned()>")

        XCTAssertTrue(html.contains("<h1 id=\"heading\">Heading"))
        XCTAssertTrue(html.contains("<strong>strong</strong>"))
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertFalse(html.contains("<img src=x"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertTrue(html.contains("default-src 'none'"))
    }

    func testWritingToAnUnavailableDestinationThrows() throws {
        let missingParent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevMissing-\(UUID().uuidString)", isDirectory: true)
        let destination = missingParent.appendingPathComponent("note.html")

        XCTAssertThrowsError(
            try HTMLExporter.write(markdown: "body", title: "Note", to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testRemoteAuthorityFileURLCannotAliasALocalExportDestination() throws {
        let localDestination = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevHostAuthority-\(UUID().uuidString).html")
        defer { try? FileManager.default.removeItem(at: localDestination) }

        var components = URLComponents()
        components.scheme = "file"
        components.host = "remote.example"
        components.percentEncodedPath = localDestination.path
        let remoteAuthority = try XCTUnwrap(components.url)
        XCTAssertTrue(
            remoteAuthority.isFileURL,
            "the regression requires Foundation's permissive file-URL classification")

        XCTAssertThrowsError(
            try HTMLExporter.write(markdown: "body", title: "Note", to: remoteAuthority)
        ) { error in
            XCTAssertEqual(
                error as? HTMLExporterError,
                .unsupportedLocation(remoteAuthority))
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: localDestination.path),
            "a remote-authority URL must not be collapsed into its local path")
    }

    func testUnicodeAndNulRoundTripWithoutTruncation() throws {
        let html = try HTMLExporter.render(markdown: "before\0after 🧪", title: "β\0title")

        XCTAssertTrue(html.contains("before�after 🧪"))
        XCTAssertTrue(html.contains("β�title"))
        XCTAssertFalse(html.utf8.contains(0))
    }

    func testOversizedTitleIsRefusedBeforeCrossingTheFFIBoundary() {
        let title = String(repeating: "t", count: HTMLExporter.maximumTitleBytes + 1)

        XCTAssertThrowsError(try HTMLExporter.render(markdown: "body", title: title)) { error in
            XCTAssertEqual(
                error as? HTMLExporterError,
                .titleTooLarge(maximumBytes: HTMLExporter.maximumTitleBytes))
        }
    }

    func testBaseDirectoryEmbedsLocalSVGForBrowsers() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevEmbed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="2" height="2"/>"#.utf8)
            .write(to: folder.appendingPathComponent("mark.svg"))

        let embedded = try HTMLExporter.render(
            markdown: "![Mark](mark.svg)", title: "Note", baseDirectory: folder)
        let plain = try HTMLExporter.render(markdown: "![Mark](mark.svg)", title: "Note")

        XCTAssertTrue(embedded.contains("src=\"data:image/svg+xml;base64,"))
        XCTAssertTrue(plain.contains("src=\"mark.svg\""))
    }

    func testBrowserPreviewIsWrittenToAPrivateUniqueFile() throws {
        let first = try HTMLExporter.writeBrowserPreview(
            markdown: "# Preview", title: "Same", baseDirectory: nil)
        let second = try HTMLExporter.writeBrowserPreview(
            markdown: "# Preview", title: "Same", baseDirectory: nil)
        defer {
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
        }

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.lastPathComponent, "Same.html")
        XCTAssertTrue(
            first.path.hasPrefix(HTMLExporter.browserPreviewDirectory.standardizedFileURL.path)
                || first.path.hasPrefix(HTMLExporter.browserPreviewDirectory.path))
        let html = try String(contentsOf: first, encoding: .utf8)
        XCTAssertTrue(html.contains("<h1 id=\"preview\">Preview"))
    }

    func testPreviewFileNamesAreSinglePathComponents() {
        XCTAssertEqual(HTMLExporter.previewFileName(for: "Plan"), "Plan.html")
        XCTAssertEqual(HTMLExporter.previewFileName(for: "a/b:c"), "a-b-c.html")
        XCTAssertEqual(HTMLExporter.previewFileName(for: "   "), "Document.html")
        XCTAssertEqual(HTMLExporter.previewFileName(for: ".hidden"), "Document.hidden.html")
        XCTAssertFalse(HTMLExporter.previewFileName(for: "../../etc").contains("/"))
    }

    func testExportLinksPointFromTheSavedPageAndPreviewsUseFileURLs() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevLinks-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = root.appendingPathComponent("Notes", isDirectory: true)
        let exports = root.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        try Data("# Other".utf8).write(to: notes.appendingPathComponent("Other.md"))

        let destination = exports.appendingPathComponent("Page.html")
        try HTMLExporter.write(
            markdown: "[[Other]]", title: "Page", baseDirectory: notes, to: destination)
        let saved = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(saved.contains("href=\"../Notes/Other.md\""))

        let preview = try HTMLExporter.writeBrowserPreview(
            markdown: "[[Other]]", title: "Page", baseDirectory: notes)
        defer { try? FileManager.default.removeItem(at: preview.deletingLastPathComponent()) }
        let previewed = try String(contentsOf: preview, encoding: .utf8)
        XCTAssertTrue(previewed.contains("href=\"file://"))
        XCTAssertTrue(previewed.contains("/Notes/Other.md\""))
    }
}
