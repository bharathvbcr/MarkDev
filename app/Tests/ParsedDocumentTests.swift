//
//  ParsedDocumentTests.swift
//  MarkDevKitTests
//
//  Verifies the Rust bridge across the FFI, not the parser itself — the
//  parser has its own suite in core/tests.
//

import XCTest

@testable import MarkDevKit

final class ParsedDocumentTests: XCTestCase {
    func testABIMatches() {
        // A mismatch means libmarkdev.a is stale; every other test in this
        // file would then be testing garbage.
        XCTAssertTrue(
            MarkDevCore.isABICompatible,
            "libmarkdev ABI \(MarkDevCore.actualABIVersion) != expected \(MarkDevCore.expectedABIVersion)"
        )
    }

    func testEmptySourceParsesToEmpty() {
        XCTAssertEqual(ParsedDocument.parse(""), .empty)
    }

    func testHeadingProducesBlockAndSpan() {
        let doc = ParsedDocument.parse("# Title")
        XCTAssertTrue(doc.blocks.contains { $0.kind == .heading && $0.headingLevel == 1 })
        XCTAssertTrue(doc.spans.contains { $0.kind == .heading })
        XCTAssertFalse(doc.markers.isEmpty, "`# ` should be a hidden marker")
    }

    func testCodeFenceLanguageCrossesTheStringTable() {
        let doc = ParsedDocument.parse("```swift\nlet x = 1\n```")
        let fence = doc.blocks.first { $0.kind == .codeBlock }
        XCTAssertEqual(fence?.info, "swift")
    }

    func testMermaidFenceIsItsOwnKind() {
        let doc = ParsedDocument.parse("```mermaid\ngraph TD;\n```")
        XCTAssertTrue(doc.blocks.contains { $0.kind == .mermaidBlock })
    }

    func testCalloutKindDecodes() {
        let doc = ParsedDocument.parse("> [!WARNING]\n> careful")
        let callout = doc.blocks.first { $0.kind == .callout }
        XCTAssertEqual(callout?.calloutKind, .warning)
    }

    func testWikiLinkIsDistinctFromLink() {
        let doc = ParsedDocument.parse("[[Note]] and [text](https://example.com)")
        XCTAssertTrue(doc.spans.contains { $0.kind == .wikiLink })
        XCTAssertTrue(doc.spans.contains { $0.kind == .link })
    }

    func testCurrencyProseNeverBecomesMathAcrossTheFFI() {
        // The contract the reader sees: a sentence of prices reaches the page
        // exactly as written — no hidden dollars (the gap), no math styling.
        // Enforced in core/tests/math.rs; this pins it across the bridge, so
        // a stale libmarkdev.a cannot quietly bring the bug back.
        for source in [
            "Price $50-$100 per unit",
            "US$5 or A$10 shipped",
            "price$5 each",
            "Cost $5 and$6 today",
            "He gave me $$5 and I gave him $$10 back",
            "![chart $5](pic$a.png)",
            // The doubled-dollar spelling of the mangled image once produced
            // a formula block — a typeset bitmap over the sentence's debris.
            "![chart $$5](pic$$a.png)",
        ] {
            let doc = ParsedDocument.parse(source)
            XCTAssertTrue(
                doc.spans.filter { $0.kind == .inlineMath }.isEmpty,
                "\(source) must produce no inline math"
            )
            XCTAssertTrue(
                doc.blocks.filter { $0.kind == .mathBlock }.isEmpty,
                "\(source) must produce no formula block"
            )
            XCTAssertTrue(
                doc.markers.isEmpty,
                "\(source) must hide nothing — hidden dollars are the gap"
            )
        }
    }

    func testSubscriptThenCallNotationCrossesTheFFIAsMath() {
        // `$v_{\text{dend}}[i](t)$` from the reported note is ordinary
        // scientific spelling: its `]` matches a `[` inside the pair, so it
        // must arrive as inline math with both delimiters hidden — not as
        // the literal text a blanket `](` refusal once left behind.
        for (source, hiddenMarkers) in [
            ("branches $v_{\\text{dend}}[i](t)$:", 2),
            ("$A[i][j]$ and $M[x](y)$", 4),
            // Two math delimiters plus the link's label/destination syntax.
            ("[read $v[i](t)$ details](reference.md)", 4),
        ] {
            let doc = ParsedDocument.parse(source)
            XCTAssertFalse(
                doc.spans.filter { $0.kind == .inlineMath }.isEmpty,
                "\(source) must produce inline math"
            )
            XCTAssertEqual(
                doc.markers.count, hiddenMarkers,
                "\(source) must hide exactly its math and surrounding Markdown markers"
            )
        }
        XCTAssertTrue(
            ParsedDocument.parse("$$A[1](b) = c$$").blocks.contains { $0.kind == .mathBlock },
            "display bracketed indexing must still render"
        )
    }

    func testComparisonsNeverBecomeHighlightsAcrossTheFFI() {
        // The `==highlight==` scanner had no adjacency rules at all and ate
        // comparisons, base64 URL padding, and `=` runs. Same bargain as the
        // dollar contract above.
        for source in [
            "x == y == z",
            "if a == b and c == d",
            "a ==== b",
            "see https://x.com/?t=dGVzdA== and https://y.com/?t=cGFzcw==",
        ] {
            let doc = ParsedDocument.parse(source)
            XCTAssertTrue(
                doc.spans.filter { $0.kind == .highlight }.isEmpty,
                "\(source) must produce no highlight"
            )
            XCTAssertTrue(doc.markers.isEmpty, "\(source) must hide nothing")
        }
    }

    func testCJKMathAndHighlightCrossTheFFI() {
        // CJK carries no spaces, so glued delimiters are normal spelling
        // there; the adjacency rules are ASCII-only precisely so this works.
        let math = ParsedDocument.parse("其中$x$是变量")
        XCTAssertEqual(math.spans.filter { $0.kind == .inlineMath }.count, 1)
        let highlight = ParsedDocument.parse("这是==重点==内容")
        XCTAssertEqual(highlight.spans.filter { $0.kind == .highlight }.count, 1)
    }

    func testGenuineMathStillCrossesTheFFI() {
        let doc = ParsedDocument.parse("Euler said $e = mc^2$ loudly")
        XCTAssertEqual(doc.spans.filter { $0.kind == .inlineMath }.count, 1)
        XCTAssertEqual(doc.markers.count, 2, "both `$` delimiters hide")
        XCTAssertTrue(
            ParsedDocument.parse("$$\na = b\n$$").blocks.contains { $0.kind == .mathBlock }
        )
    }

    func testRangesStayInsideTheDocument() {
        // Out-of-bounds ranges would crash NSTextStorage rather than
        // misrender, so this is a hard invariant of the bridge.
        let sources = [
            "🎉 **bold** with `code` and [[link]]",
            "café ~~struck~~",
            "𝄞 $x^2$",
            "**unclosed",
            "> quote\n\n- [ ] task\n\n| a |\n|---|",
        ]
        for source in sources {
            let length = (source as NSString).length
            let doc = ParsedDocument.parse(source)
            for span in doc.spans {
                XCTAssertLessThanOrEqual(
                    span.range.location + span.range.length, length,
                    "span past end of \(source)")
            }
            for marker in doc.markers {
                XCTAssertLessThanOrEqual(
                    marker.range.location + marker.range.length, length,
                    "marker past end of \(source)")
            }
            for block in doc.blocks {
                XCTAssertLessThanOrEqual(
                    block.range.location + block.range.length, length,
                    "block past end of \(source)")
            }
        }
    }

    func testNonASCIIOffsetsAlignWithNSString() {
        // The Rust side maps byte offsets to UTF-16; if that were wrong, the
        // emoji here would shift every following range by one unit.
        let source = "🎉 **bold**"
        let doc = ParsedDocument.parse(source)
        let ns = source as NSString
        guard let strong = doc.spans.first(where: { $0.kind == .strong }) else {
            return XCTFail("expected a strong span")
        }
        XCTAssertEqual(ns.substring(with: strong.range), "bold")
    }
}
