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

    // MARK: - The grammar is CommonMark's

    func testMarkupTheCoreReadsAsTextIsNotATag() {
        // Every one of these is a paragraph of ordinary text to the core —
        // verified against it in `PictureStressTests`, not assumed here — so
        // accepting any of them hides a line the reader can see. They were all
        // accepted while this followed a browser's tokenizer instead, which
        // recovers from exactly the errors CommonMark refuses.
        let text: [(String, String)] = [
            ("a Unicode space where only ASCII is whitespace",
                "<img\u{00A0}src=\"x.svg\">"),
            ("an em space doing the same",
                "<img\u{2003}src=\"x.svg\">"),
            ("no gap between two attributes",
                #"<img src="a.svg"alt="b">"#),
            ("a backtick in an unquoted value",
                "<img src=a`b.svg>"),
            ("a quote in an unquoted value",
                #"<img src=a"b.svg>"#),
            ("an equals in an unquoted value",
                "<img src=a=b.svg>"),
            ("an attribute name opening with <",
                "<img src=x.svg <img src=y.svg>"),
            ("an attribute name opening with a digit",
                "<img src=x.svg 9a=b>"),
        ]
        for (why, markup) in text {
            XCTAssertNil(
                HTMLImageTag.parse(markup),
                "\(markup.debugDescription) is text to the core — \(why)")
        }
    }

    func testTheTrimIsTheGrammarsWhitespaceToo() {
        // `.whitespacesAndNewlines` strips U+200B, U+00A0 and U+2003, none of
        // which the grammar allows anywhere — and a leading one is enough to
        // make the line text rather than markup. Trimming with that set was
        // the last way a paragraph of text could still be read as a picture,
        // and it survived tightening the scanner because it runs before it.
        for scalar in ["\u{200B}", "\u{00A0}", "\u{2003}", "\u{FEFF}"] {
            XCTAssertNil(
                HTMLImageTag.parse(scalar + #"<img src="x.svg">"#),
                "a leading \(scalar.debugDescription) is not whitespace to the grammar")
        }
        // The six that are still come off either end.
        for scalar in [" ", "\t", "\n", "\u{0B}", "\u{0C}", "\r"] {
            XCTAssertNotNil(
                HTMLImageTag.parse(scalar + #"<img src="x.svg">"# + scalar),
                "\(scalar.debugDescription) is whitespace to the grammar")
        }
    }

    func testASlashOnlyClosesTheTagWhereTheGrammarPutsIt() {
        // `whitespace? "/"? ">"` — the slash sits immediately before the
        // bracket or it is not a slash. A browser recovers from both of these
        // and the core does not, so refusing them is what keeps the source on
        // the page.
        XCTAssertNil(HTMLImageTag.parse(#"<img src="x.svg" / >"#))
        XCTAssertNil(HTMLImageTag.parse(#"<img / src="x.svg">"#))
        XCTAssertNotNil(HTMLImageTag.parse(#"<img src="x.svg" />"#))
        // And inside an unquoted value a slash is just a character, which is
        // what the core reads too — so the source keeps it and the picture
        // fails to resolve, exactly as it does in a browser. Honest, and not
        // to be "fixed" by trimming it off: that would draw a picture where
        // every other renderer shows a broken one.
        XCTAssertEqual(try? XCTUnwrap(HTMLImageTag.parse("<img src=x.svg/>")).source, "x.svg/")
    }

    func testAControlCharacterInAValueIsRefused() {
        // The core is happy with these — a file name may hold a vertical tab —
        // but "a value never crosses a line" is enforced with
        // `Character.isNewline`, which covers U+000A through U+000D. Refusing
        // is the safe direction and shows the source; it is pinned so that
        // widening the rule stays a decision rather than an accident.
        for scalar in ["\u{0B}", "\u{0C}", "\r", "\n"] {
            XCTAssertNil(HTMLImageTag.parse("<img src=\"a\(scalar)b.svg\">"))
        }
    }

    // MARK: - Cost

    func testDecodingIsLinearInTheValue() {
        // Entity decoding used to look for the closing `;` anywhere in the
        // rest of the value, which is a walk to the end of the string per `&`
        // — and an unquoted `src` runs to the end of the tag. Measured before
        // the bound: **94ms** for one 4KB tag, against 8µs for an ordinary
        // one, on the parse path, once per keystroke per tag. Ten such blocks
        // in a note made every keystroke take a second.
        //
        // Asserted as a ratio against the same length of ordinary text, so a
        // loaded machine cannot fail it: what is being caught is a quadratic,
        // which shows up as a factor of thousands rather than of two.
        let ampersands = "<img src=" + String(repeating: "&", count: 4000) + ">"
        let ordinary = "<img src=x.svg alt=\"" + String(repeating: "a", count: 3980) + "\">"

        func cost(_ text: String) -> Double {
            var best = Double.infinity
            for _ in 0..<5 {
                let start = DispatchTime.now().uptimeNanoseconds
                for _ in 0..<10 { _ = HTMLImageTag.parse(text) }
                best = min(best, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            }
            return best
        }

        let quadratic = cost(ampersands)
        let linear = max(cost(ordinary), 0.001)
        XCTAssertLessThan(
            quadratic / linear, 50,
            "4,000 ampersands cost \(quadratic)ms against \(linear)ms for the same length "
                + "of ordinary text — the entity search is walking the whole value again")
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
