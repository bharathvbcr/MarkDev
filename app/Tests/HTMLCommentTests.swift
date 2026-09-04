//
//  HTMLCommentTests.swift
//  MarkDevKitTests
//
//  HTML comments are hidden. GitHub draws nothing for them; leftover text
//  around a comment is still text, and must stay on the page.
//

import XCTest

@testable import MarkDevKit

final class HTMLCommentTests: XCTestCase {

    func testAPlainCommentIsAComment() {
        XCTAssertTrue(HTMLComment.parse("<!-- ALL-CONTRIBUTORS-LIST:START -->"))
        XCTAssertTrue(HTMLComment.parse("  <!-- prettier-ignore-start -->\n"))
        XCTAssertTrue(HTMLComment.parse("<!--\n  multiline\n-->"))
    }

    func testAdjacentCommentsAreStillComments() {
        XCTAssertTrue(
            HTMLComment.parse("<!-- a --><!-- b -->"),
            "two comments on one line, nothing else")
        XCTAssertTrue(HTMLComment.parse("<!-- a -->\n<!-- b -->"))
    }

    func testLeftoverTextIsNotAComment() {
        XCTAssertFalse(HTMLComment.parse("<!-- a --> leftover"))
        XCTAssertFalse(HTMLComment.parse("see <!-- a -->"))
        XCTAssertFalse(HTMLComment.parse("<!-- a -->\nvisible"))
    }

    func testUnterminatedAndNonCommentsStayVisible() {
        XCTAssertFalse(HTMLComment.parse("<!-- open"))
        XCTAssertFalse(HTMLComment.parse("<!---- incomplete"))
        XCTAssertFalse(HTMLComment.parse("<div>raw</div>"))
        XCTAssertFalse(HTMLComment.parse("<!DOCTYPE html>"))
        XCTAssertFalse(HTMLComment.parse("<?php echo 1 ?>"))
        XCTAssertFalse(HTMLComment.parse(""))
    }

    func testACommentThatNamesAnImageIsStillAComment() {
        // The img tag is inside the comment. Hiding the comment does not
        // hide a picture the reader wrote — there is no picture.
        XCTAssertTrue(HTMLComment.parse("<!-- <img src=\"a.svg\"> -->"))
    }

    func testAnHtmlCommentBlockCollapses() {
        let source = """
            before

            <!-- ALL-CONTRIBUTORS-LIST:START - Do not remove or modify this section -->

            after
            """
        let text = source as NSString
        let parsed = ParsedDocument.parse(source)
        let rendered = RenderedBlocks(document: parsed, text: text)
        XCTAssertEqual(rendered.entries.count, 1)
        XCTAssertEqual(rendered.entries[0].content.kind, .htmlComment)

        let hidden = HiddenRanges(
            document: parsed, selection: NSRange(location: 0, length: 0), mode: .reading,
            rendered: rendered)
        XCTAssertTrue(hidden.covers(rendered.entries[0].range))
        XCTAssertTrue(hidden.hidesWholeLine(at: rendered.entries[0].range.location, in: text))
        XCTAssertFalse(hidden.covers(text.range(of: "before")))
        XCTAssertFalse(hidden.covers(text.range(of: "after")))
    }

    func testTheCaretBringsTheCommentBack() throws {
        let source = "before\n\n<!-- note -->\n\nafter\n"
        let parsed = ParsedDocument.parse(source)
        let rendered = RenderedBlocks(document: parsed, text: source as NSString)
        let comment = try XCTUnwrap(rendered.entries.first)
        let hidden = HiddenRanges(
            document: parsed,
            selection: NSRange(location: comment.range.location + 4, length: 0),
            rendered: rendered)
        XCTAssertFalse(
            hidden.covers(comment.range),
            "the comment has to come back to be edited")
    }

    func testAllContributorsMarkersCollapseAndTheProseDoesNot() {
        let source = """
            specification: **code is one kind of contribution among many** — documentation,
            design, bug reports, testing, reviews, and ideas are all recognised here.

            <!-- ALL-CONTRIBUTORS-LIST:START - Do not remove or modify this section -->
            <!-- prettier-ignore-start -->
            <!-- markdownlint-disable -->
            <!-- ALL-CONTRIBUTORS-LIST:END -->
            <!-- markdownlint-restore -->
            <!-- prettier-ignore-end -->

            To add someone (including yourself), comment on any issue or pull request.
            """
        let text = source as NSString
        let parsed = ParsedDocument.parse(source)
        let rendered = RenderedBlocks(document: parsed, text: text)
        let comments = rendered.entries.filter { $0.content.kind == .htmlComment }
        XCTAssertEqual(comments.count, 6, "each all-contributors marker is its own HTML block")

        let hidden = HiddenRanges(
            document: parsed, selection: NSRange(location: 0, length: 0), mode: .reading,
            rendered: rendered)
        for entry in comments {
            XCTAssertTrue(hidden.covers(entry.range), text.substring(with: entry.range))
            XCTAssertTrue(hidden.hidesWholeLine(at: entry.range.location, in: text))
        }
        XCTAssertFalse(hidden.covers(text.range(of: "specification")))
        XCTAssertFalse(hidden.covers(text.range(of: "To add someone")))
        XCTAssertTrue(
            rendered.entries.allSatisfy { $0.content.kind == .htmlComment },
            "the surrounding prose is not a rendered block")
    }
}
