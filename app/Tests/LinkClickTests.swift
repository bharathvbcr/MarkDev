//
//  LinkClickTests.swift
//  MarkDevTests
//

import XCTest

@testable import MarkDevKit

@MainActor
final class LinkClickTests: XCTestCase {
    func testSchemeLessRelativePathIsADocumentLink() {
        let url = URL(string: "./CODE_OF_CONDUCT.md".addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed)!)!
        XCTAssertEqual(
            LinkClick.classify(url),
            .document("./CODE_OF_CONDUCT.md"))
    }

    func testFragmentOnlyIsAHeadingJump() {
        XCTAssertEqual(
            LinkClick.classify(URL(string: "#Parsing")!),
            .heading("Parsing"))
    }

    func testHTTPSIsExternal() {
        XCTAssertEqual(
            LinkClick.classify(URL(string: "https://example.com/note")!),
            .external)
    }

    func testProtocolRelativeIsExternal() {
        XCTAssertEqual(
            LinkClick.classify(URL(string: "//example.com/x")!),
            .external)
    }

    func testFileURLIsADocumentLink() {
        let url = URL(fileURLWithPath: "/tmp/vault/Note.md")
        guard case .document(let destination) = LinkClick.classify(url) else {
            return XCTFail("expected document")
        }
        XCTAssertTrue(destination.hasSuffix("/tmp/vault/Note.md") || destination == "/tmp/vault/Note.md")
    }

    func testPercentEncodedHashSurvivesAsDocumentDestination() {
        // The styler encodes `#` with urlPathAllowed, so the click sees `%23`.
        let encoded = "Guide.md%23Heading"
        let url = URL(string: encoded)!
        XCTAssertEqual(
            LinkClick.classify(url),
            .document("Guide.md#Heading"))
    }

    func testWikiAndFootnoteSchemes() {
        let wiki = URL(string: "\(MarkdownStyler.wikiLinkScheme)://Note")!
        XCTAssertEqual(LinkClick.classify(wiki), .wiki("Note"))

        let footnote = URL(string: "\(MarkdownStyler.footnoteScheme)://ref")!
        XCTAssertEqual(LinkClick.classify(footnote), .footnote("ref"))
    }

    func testClickedRelativeLinkInvokesDocumentHandler() {
        let view = MarkdownTextView.make(theme: .standard)
        var received: String?
        view.onFollowDocumentLink = { received = $0 }

        let encoded = "./CODE_OF_CONDUCT.md".addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed)!
        view.clicked(onLink: URL(string: encoded)!, at: 0)

        XCTAssertEqual(received, "./CODE_OF_CONDUCT.md")
    }

    func testClickedHTTPSDoesNotInvokeDocumentHandler() {
        let view = MarkdownTextView.make(theme: .standard)
        var documentCalls = 0
        view.onFollowDocumentLink = { _ in documentCalls += 1 }

        view.clicked(onLink: URL(string: "https://example.com")!, at: 0)

        XCTAssertEqual(documentCalls, 0)
    }

    func testNilDocumentHandlerStillSwallowsRelativeClicks() {
        // Peek / Quick Look leave the handler nil; returning is what prevents -50.
        let view = MarkdownTextView.make(theme: .standard)
        view.onFollowDocumentLink = nil
        let encoded = "./LICENSE".addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed)!
        view.clicked(onLink: URL(string: encoded)!, at: 0)
        // No assertion beyond "did not crash / throw" — the return is the contract.
    }

    func testDocumentLinkOpenKindClassifiesNoteDirectoryAndOtherFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("markdev-link-kind-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let note = root.appendingPathComponent("Note.md")
        let license = root.appendingPathComponent("LICENSE")
        let folder = root.appendingPathComponent("docs", isDirectory: true)
        try "# Note\n".write(to: note, atomically: true, encoding: .utf8)
        try "MIT\n".write(to: license, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        XCTAssertEqual(
            DocumentLinkOpenKind.classify(
                isDirectory: false, isRegularFile: true, isMarkdown: FileTree.isMarkdown(note)),
            .markdownNote)
        XCTAssertEqual(
            DocumentLinkOpenKind.classify(
                isDirectory: false, isRegularFile: true, isMarkdown: FileTree.isMarkdown(license)),
            .otherFile)
        XCTAssertEqual(
            DocumentLinkOpenKind.classify(
                isDirectory: true, isRegularFile: false, isMarkdown: false),
            .directory)
        XCTAssertEqual(
            DocumentLinkOpenKind.classify(
                isDirectory: false, isRegularFile: false, isMarkdown: false),
            .missing)
    }
}
