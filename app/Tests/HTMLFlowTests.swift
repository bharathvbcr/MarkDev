//
//  HTMLFlowTests.swift
//  MarkDevKitTests
//
//  GitHub README HTML is a fragment, not a browser. These tests pin what
//  that fragment accepts — centred badge rows, taglines, hero images —
//  and, more importantly, what it refuses. Recognising a fragment means
//  hiding it.
//

import XCTest

@testable import MarkDevKit

final class HTMLFlowTests: XCTestCase {

    func testMinimalWrappersParse() {
        XCTAssertNotNil(HTMLFlow.parse("<p>hi</p>"), "text in p")
        XCTAssertNotNil(HTMLImageTag.parse(#"<img src="mark.svg" alt="M">"#), "lone img tag")
        XCTAssertNotNil(HTMLFlow.parse(#"<img src="mark.svg" alt="M">"#), "unwrapped img")
        XCTAssertNotNil(HTMLFlow.parse(#"<p><img src="mark.svg" alt="M"></p>"#), "img in p")
        XCTAssertNotNil(HTMLFlow.parse(#"<div><img src="mark.svg" alt="M"></div>"#), "img in div")
        XCTAssertNotNil(
            HTMLFlow.parse(#"<p align="center"><img src="mark.svg" alt="M"></p>"#),
            "aligned p")
        XCTAssertNotNil(
            HTMLFlow.parse(#"<div align="center"><img src="mark.svg" alt="M"></div>"#),
            "aligned div")
    }

    func testACenteredImageIsAFragment() throws {
        let flow = try XCTUnwrap(
            HTMLFlow.parse(
                """
                <p align="center">
                  <img src="docs/hero.png" alt="Hero" width="100%">
                </p>
                """))
        XCTAssertEqual(flow.alignment, .center)
        XCTAssertEqual(flow.images.count, 1)
        XCTAssertEqual(flow.images[0].source, "docs/hero.png")
        XCTAssertEqual(flow.images[0].alt, "Hero")
        XCTAssertTrue(flow.images[0].fillsColumn)
    }

    func testABadgeRowReadsEveryLinkedImage() throws {
        let flow = try XCTUnwrap(
            HTMLFlow.parse(
                """
                <p align="center">
                  <a href="https://example.com/"><img src="https://img.shields.io/badge/ci-passing-green" alt="CI"></a>
                  <a href="https://example.com/license"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License: MIT"></a>
                </p>
                """))
        XCTAssertEqual(flow.alignment, .center)
        XCTAssertEqual(flow.images.map(\.alt), ["CI", "License: MIT"])
        XCTAssertEqual(flow.images[0].href, "https://example.com/")
        XCTAssertEqual(flow.images[1].href, "https://example.com/license")
    }

    func testATaglineKeepsBoldBreaksAndEntities() throws {
        let flow = try XCTUnwrap(
            HTMLFlow.parse(
                """
                <p align="center">
                  <strong>High-performance client.</strong><br>
                  Engineered with Rust &amp; Svelte.<br>
                  <a href="https://example.com/"><strong>Explore the showcase &rarr;</strong></a>
                </p>
                """))
        XCTAssertEqual(flow.alignment, .center)
        var texts: [String] = []
        var bolds: [Bool] = []
        var hrefs: [String?] = []
        var breaks = 0
        for item in flow.items {
            switch item {
            case .run(let run):
                texts.append(run.text)
                bolds.append(run.bold)
                hrefs.append(run.href)
            case .lineBreak:
                breaks += 1
            case .image:
                XCTFail("tagline should not hold a picture")
            }
        }
        XCTAssertEqual(breaks, 2)
        XCTAssertEqual(texts, ["High-performance client.", "Engineered with Rust & Svelte.", "Explore the showcase →"])
        XCTAssertEqual(bolds, [true, false, true])
        XCTAssertEqual(hrefs, [nil, nil, "https://example.com/"])
    }

    func testADivWrapperIsTheSameAsAParagraph() throws {
        let flow = try XCTUnwrap(HTMLFlow.parse(#"<div align="center"><img src="mark.svg" alt="M"></div>"#))
        XCTAssertEqual(flow.alignment, .center)
        XCTAssertEqual(flow.images[0].source, "mark.svg")
    }

    func testAnUnwrappedImageRowIsStillAFragment() throws {
        // No `<p>`: a README that writes the tags as an HTML block of imgs.
        let flow = try XCTUnwrap(
            HTMLFlow.parse(#"<img src="a.svg" alt="A"> <img src="b.svg" alt="B">"#))
        XCTAssertEqual(flow.images.map(\.alt), ["A", "B"])
    }

    func testUnknownTagsKeepTheirSource() {
        for markup in [
            "<video src=\"x.mp4\"></video>",
            "<script>alert(1)</script>",
            "<!-- comment -->",
            "<p><canvas id=\"c\"></canvas></p>",
            "<p align=\"center\"><iframe src=\"x\"></iframe></p>",
            "<form><input type=\"text\"></form>",
        ] {
            XCTAssertNil(HTMLFlow.parse(markup), markup)
        }
    }

    func testSupportedReadmeHTMLParses() throws {
        let table = try XCTUnwrap(HTMLFlow.parse("<table><tr><td>x</td></tr></table>"))
        XCTAssertEqual(table.rows?.count, 1)

        let span = try XCTUnwrap(HTMLFlow.parse("<p><span>x</span></p>"))
        XCTAssertEqual(span.items, [.run(HTMLFlow.Run(text: "x", bold: false, italic: false, mono: false, href: nil))])

        let heading = try XCTUnwrap(HTMLFlow.parse("<h1 align=\"center\">Title</h1>"))
        XCTAssertEqual(heading.headingLevel, 1)
        XCTAssertEqual(heading.alignment, .center)
    }

    func testUnclosedEmphasisIsRefused() {
        XCTAssertNil(HTMLFlow.parse("<p><strong>open"))
        XCTAssertNil(HTMLFlow.parse("<a href=\"x\"><img src=\"a.svg\">"))
    }

    func testLeftoverAfterTheCloserIsRefused() {
        XCTAssertNil(HTMLFlow.parse(#"<p><img src="a.svg"></p> trailing"#))
    }

    func testAnEmptyParagraphIsNotAFragment() {
        XCTAssertNil(HTMLFlow.parse("<p align=\"center\"></p>"))
        XCTAssertNil(HTMLFlow.parse("<p><br></p>"))
    }

    func testAFragmentPastTheLengthBoundIsRefused() {
        let img = #"<img src="a.svg">"#
        var markup = "<p>"
        while markup.utf8.count <= HTMLFlow.maximumLength {
            markup += img
        }
        markup += "</p>"
        XCTAssertNil(HTMLFlow.parse(markup))
    }

    func testACenteredParagraphIsAnHTMLBlockToTheCore() {
        let source = """
            <p align="center">
              <img src="a.png">
            </p>
            """
        let parsed = ParsedDocument.parse(source)
        XCTAssertTrue(
            parsed.blocks.contains { $0.kind == .htmlBlock },
            "the wrapper has to be an html block or RenderedBlocks never sees it")
    }

    func testRenderedBlocksHidesACenteredHeroAndABadgeRow() {
        let source = """
            <p align="center">
              <a href="https://example.com/"><img src="https://img.shields.io/badge/ci-ok-green" alt="CI"></a>
            </p>

            <p align="center">
              <img src="docs/hero.png" alt="Hero" width="100%">
            </p>
            """
        let rendered = RenderedBlocks(
            document: ParsedDocument.parse(source), text: source as NSString)
        XCTAssertEqual(rendered.entries.count, 2)
        guard case .htmlFlow(let badges) = rendered.entries[0].content.kind else {
            return XCTFail("badge row should be an html flow")
        }
        XCTAssertEqual(badges.images.map(\.alt), ["CI"])
        guard case .htmlFlow(let hero) = rendered.entries[1].content.kind else {
            return XCTFail("hero should be an html flow")
        }
        XCTAssertTrue(hero.images[0].fillsColumn)
    }
}
