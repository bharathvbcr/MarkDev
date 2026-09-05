import XCTest

@testable import MarkDevKit

final class HTMLExporterTests: XCTestCase {
    func testRendersMarkdownAndMakesRawHTMLInert() throws {
        let html = try HTMLExporter.render(
            markdown: "# Heading\n\nA **strong** idea.\n\n<script>owned()</script>",
            title: "<img src=x onerror=owned()>")

        XCTAssertTrue(html.contains("<h1>Heading</h1>"))
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
}
