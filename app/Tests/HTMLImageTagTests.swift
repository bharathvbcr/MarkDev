//
//  HTMLImageTagTests.swift
//  MarkDevKitTests
//
//  Reading a lone `<img>` tag out of a note.
//
//  What is being tested is mostly the *refusals*. Recognising the tag means
//  hiding the markup it was written as, so anything this admits by mistake is
//  text the reader can no longer see — and a paragraph holding two pictures,
//  or a picture and a sentence, is a paragraph.
//

import XCTest

@testable import MarkDevKit

final class HTMLImageTagTests: XCTestCase {

    // MARK: - What it reads

    func testAPlainTagIsRead() throws {
        let tag = try XCTUnwrap(
            HTMLImageTag.parse(
                #"<img src="assets/mark.svg" alt="The mark" width="72">"#))
        XCTAssertEqual(tag.source, "assets/mark.svg")
        XCTAssertEqual(tag.alt, "The mark")
        XCTAssertEqual(tag.width, 72)
    }

    func testTheSpellingsAHandWrittenTagActuallyUses() throws {
        // Single quotes, no quotes, self-closing, uppercase, attributes
        // running over several lines: all of these are one picture.
        let spellings = [
            "<img src='mark.svg'>",
            "<img src=mark.svg>",
            #"<img src="mark.svg"/>"#,
            #"<IMG SRC="mark.svg" />"#,
            "<img\n  src=\"mark.svg\"\n  alt=\"\"\n>",
            #"  <img src="mark.svg">  "#,
        ]
        for spelling in spellings {
            let tag = try XCTUnwrap(
                HTMLImageTag.parse(spelling), "should read \(spelling.debugDescription)")
            XCTAssertEqual(tag.source, "mark.svg", spelling.debugDescription)
        }
    }

    func testLayoutAttributesAreIgnoredRatherThanRefused() throws {
        // `align`, `hspace` and `vspace` ask for text to flow around the
        // picture, which a block drawn in place of a whole paragraph cannot
        // do. Refusing the tag over them would show the reader markup instead
        // of the picture it names, which is worse than ignoring them.
        let tag = try XCTUnwrap(
            HTMLImageTag.parse(
                #"<img src="mark.svg" alt="M" width="72" align="left" hspace="12" vspace="4">"#))
        XCTAssertEqual(tag.source, "mark.svg")
        XCTAssertEqual(tag.width, 72)
    }

    func testAnAmpersandInAFileNameSurvives() throws {
        // The name on disk has the `&`, not the entity, and resolving the
        // entity against the document's directory looks for a file nobody has.
        let tag = try XCTUnwrap(HTMLImageTag.parse(#"<img src="a&amp;b.svg" alt="a&#39;s">"#))
        XCTAssertEqual(tag.source, "a&b.svg")
        XCTAssertEqual(tag.alt, "a's")
    }

    func testAnUnknownEntityIsLeftAsItIs() throws {
        let tag = try XCTUnwrap(HTMLImageTag.parse(#"<img src="a&nope;b.svg">"#))
        XCTAssertEqual(tag.source, "a&nope;b.svg")
    }

    func testAMissingAltIsEmptyRatherThanAbsent() throws {
        XCTAssertEqual(try XCTUnwrap(HTMLImageTag.parse("<img src=x.svg>")).alt, "")
    }

    // MARK: - Widths

    func testWidthsThatCannotMeanAnything() throws {
        // A percentage is a fraction of a containing box this layout does not
        // have; resolving it against the column would make `width="100%"`
        // mean two different sizes in two split panes. Dropped, rather than
        // guessed — the picture still draws at its own size.
        for width in ["100%", "0", "-40", "auto", "", "abc"] {
            let tag = try XCTUnwrap(
                HTMLImageTag.parse(#"<img src="x.svg" width="\#(width)">"#),
                "the tag itself is still a picture")
            XCTAssertNil(tag.width, "width=\(width.debugDescription) should be dropped")
        }
    }

    func testAWidthWithAUnitIsStillAWidth() throws {
        XCTAssertEqual(try XCTUnwrap(HTMLImageTag.parse(#"<img src="x.svg" width="72px">"#)).width, 72)
    }

    // MARK: - What it refuses

    func testTwoTagsAreNotOnePicture() {
        XCTAssertNil(HTMLImageTag.parse(#"<img src="a.svg"><img src="b.svg">"#))
    }

    func testATagWithTextAroundItIsProse() {
        XCTAssertNil(HTMLImageTag.parse(#"see <img src="a.svg">"#))
        XCTAssertNil(HTMLImageTag.parse(#"<img src="a.svg"> and more"#))
    }

    func testOtherMarkupIsNotAnImage() {
        for markup in [
            "<div>hello</div>", #"<image src="a.svg">"#, "<img", "<img>", "<img alt=\"a\">",
            #"<img src="">"#, #"<img src="a.svg"#, #"<img src="a.svg>"#, "", "not html at all",
        ] {
            XCTAssertNil(HTMLImageTag.parse(markup), "\(markup.debugDescription) is not a picture")
        }
    }

    func testAGreaterThanInsideAValueDoesNotEndTheTag() throws {
        let tag = try XCTUnwrap(HTMLImageTag.parse(#"<img src="a.svg" alt="a > b">"#))
        XCTAssertEqual(tag.alt, "a > b")
    }

    func testARepeatedAttributeTakesTheFirstAsABrowserDoes() throws {
        let tag = try XCTUnwrap(HTMLImageTag.parse(#"<img src="a.svg" src="b.svg">"#))
        XCTAssertEqual(tag.source, "a.svg")
    }

    func testNothingHangsOnAwkwardInput() {
        // Every one of these has to *return*: the parser runs on the parse
        // path, once per html block per keystroke.
        for markup in [
            "<img " + String(repeating: "a", count: 5_000),
            "<img src=" + String(repeating: "&", count: 2_000) + ">",
            "<img src=\"" + String(repeating: "&amp;", count: 1_000) + "\">",
            "<img" + String(repeating: " ", count: 5_000) + ">",
            "<img src=x " + String(repeating: "=", count: 100) + ">",
        ] {
            _ = HTMLImageTag.parse(markup)
        }
    }
}
