//
//  ParsedDocumentTests.swift
//  MarkDevKitTests
//
//  Verifies the Rust bridge across the FFI, not the parser itself — the
//  parser has its own suite in core/tests.
//

import XCTest

@testable import MarkDevKit

#if canImport(CMarkDev)
    import CMarkDev
#endif

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

    func testCheckedParseDistinguishesAValidEmptyDocumentFromRefusal() {
        XCTAssertEqual(ParsedDocument.parseChecked(""), .parsed(.empty))
        XCTAssertEqual(ParsedDocument.parseChecked("before\0after"), .rejected)
    }

    func testCheckedParseAcceptsTheExactByteLimitAndRejectsPlusOne() {
        let exact = String(repeating: "x", count: MarkdownReadLimits.maximumDocumentBytes)
        guard case .parsed = ParsedDocument.parseChecked(exact) else {
            return XCTFail("the exact parser limit must remain usable")
        }
        XCTAssertEqual(ParsedDocument.parseChecked(exact + "x"), .rejected)
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

    func testParenAndBracketMathCrossTheFFI() {
        XCTAssertFalse(
            ParsedDocument.parse("\\(a + b\\)").spans.filter { $0.kind == .inlineMath }.isEmpty)
        XCTAssertTrue(
            ParsedDocument.parse("\\[a = b\\]").blocks.contains { $0.kind == .mathBlock })
        XCTAssertFalse(
            ParsedDocument.parse("\\\\(a + b\\\\)").spans.filter { $0.kind == .inlineMath }.isEmpty)
        XCTAssertTrue(
            ParsedDocument.parse("```math\nx\n```").blocks.contains { $0.kind == .mathBlock })
        XCTAssertTrue(
            ParsedDocument.parse("`\\(x\\)`").spans.filter { $0.kind == .inlineMath }.isEmpty)
        XCTAssertTrue(
            ParsedDocument.parse("[\\[4\\]](https://example.com/p4)").blocks.filter {
                $0.kind == .mathBlock
            }.isEmpty)
    }

    func testCalloutCustomTitleCrossesTheStringTable() {
        let doc = ParsedDocument.parse("> [!NOTE] Custom\n> body")
        let callout = doc.blocks.first { $0.kind == .callout }
        XCTAssertEqual(callout?.calloutKind, .note)
        XCTAssertEqual(callout?.info, "Custom")
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

    func testSpanOverlapIndexFindsAnEarlierLongOuterSpan() {
        let document = ParsedDocument(
            spans: [
                StyleSpan(
                    range: NSRange(location: 0, length: 100), kind: .link, depth: 0, data: 0),
                StyleSpan(
                    range: NSRange(location: 10, length: 1), kind: .strong, depth: 1, data: 0),
                StyleSpan(
                    range: NSRange(location: 70, length: 10), kind: .emphasis, depth: 1, data: 0),
            ],
            markers: [],
            blocks: [],
            strings: ["destination"])

        XCTAssertEqual(
            document.spanIndices(overlapping: NSRange(location: 75, length: 1)),
            0..<3,
            "a short nested span must not hide an earlier outer overlap")
    }

    func testOverlapIndexesRejectOverflowingQueriesWithoutTrapping() {
        let document = ParsedDocument(
            spans: [
                StyleSpan(
                    range: NSRange(location: 0, length: 1), kind: .strong, depth: 0, data: 0)
            ],
            markers: [SyntaxMarker(range: NSRange(location: 0, length: 1), block: 0)],
            blocks: [
                BlockDescriptor(
                    range: NSRange(location: 0, length: 1), kind: .paragraph, depth: 0,
                    data: 0, info: nil)
            ])
        let overflowing = NSRange(location: Int.max, length: 1)

        XCTAssertEqual(document.spanIndices(overlapping: overflowing), 0..<0)
        XCTAssertEqual(document.markerIndices(overlapping: overflowing), 0..<0)
    }

    // MARK: - Nested blocks survive the bridge

    /// Every nested construct in the language must decode.
    ///
    /// The bridge validates the core's arrays before trusting them, and its
    /// ordering check was written once for all three. Spans and markers *are*
    /// sorted by `(start, end)` — `core/src/md/parse.rs` sorts them explicitly
    /// — but `blocks` is never sorted at all: a descriptor is pushed when its
    /// construct opens, so a container precedes its contents and, at a shared
    /// start, ends *later* than the child that follows it.
    ///
    /// Holding blocks to the span rule therefore rejected the whole parse of
    /// any nested construct. `decode` returned nil, `setMarkdown` refused the
    /// document, and the editor showed an **empty page** for an ordinary note
    /// — an ordered list, a table, a task list, a display formula. Nothing
    /// reported an error; the text simply never arrived.
    func testEveryNestedConstructDecodesRatherThanRejectingTheWholeParse() {
        let nested: [(String, String)] = [
            ("ordered list", "998. a\n999. b\n1000. c\n"),
            ("ordered list with parens", "1) a\n2) b\n"),
            ("bullet list", "- one\n- two\n"),
            ("nested list", "- outer\n  - inner\n    - deeper\n"),
            ("task list", "- [ ] todo\n- [x] done\n"),
            ("table", "| a | b |\n|---|---|\n| 1 | 2 |\n"),
            ("table in a list", "- item\n\n  | a | b |\n  |---|---|\n  | 1 | 2 |\n"),
            ("display math", "$$\nx^2\n$$\n"),
            ("blockquote", "> quoted\n> more\n"),
            ("callout", "> [!NOTE]\n> body\n"),
            ("list holding a fence", "- item\n\n  ```swift\n  let x = 1\n  ```\n"),
            ("footnote definition", "See[^1].\n\n[^1]: The note.\n"),
        ]

        for (name, source) in nested {
            guard case .parsed(let document) = ParsedDocument.parseChecked(source) else {
                XCTFail("\(name) was refused by the bridge; the editor renders that as a blank page")
                continue
            }
            XCTAssertFalse(
                document.blocks.isEmpty, "\(name) decoded to no blocks at all")
        }
    }

    /// The fixture above must actually contain the shape it exists to cover.
    ///
    /// A container that happens to end exactly where its only child does
    /// satisfies the span rule by coincidence — a one-item list did, which is
    /// why the bug looked like it only touched *some* documents. Without this,
    /// a future parser change could quietly stop producing the overlapping
    /// pair and leave the test above passing while covering nothing.
    func testTheNestedFixtureReallyContainsAContainerOutlivingItsFirstChild() {
        guard case .parsed(let document) = ParsedDocument.parseChecked("998. a\n999. b\n1000. c\n")
        else { return XCTFail("the multi-item list must parse") }

        let pairs = zip(document.blocks, document.blocks.dropFirst())
        XCTAssertTrue(
            pairs.contains { outer, inner in
                outer.range.location == inner.range.location
                    && NSMaxRange(outer.range) > NSMaxRange(inner.range)
            },
            "no block is followed by one starting at the same offset and ending sooner — "
                + "the ordering this guards is no longer exercised")
    }

    /// What the bridge does require of blocks, and all it requires.
    ///
    /// `overlapWindow` binary-searches on start location alone;
    /// `prefixMaximumEnds` exists precisely because the ends do not rise with
    /// them. Starts going backwards would silently truncate that window.
    func testBlockStartsNeverGoBackwardsAcrossNestedConstructs() {
        for source in [
            "- outer\n  - inner\n    - deeper\n",
            "| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\n",
            "> [!NOTE]\n> - item\n>\n> | a | b |\n> |---|---|\n> | 1 | 2 |\n",
        ] {
            guard case .parsed(let document) = ParsedDocument.parseChecked(source) else {
                XCTFail("\(source.debugDescription) must parse")
                continue
            }
            for (left, right) in zip(document.blocks, document.blocks.dropFirst()) {
                XCTAssertLessThanOrEqual(
                    left.range.location, right.range.location,
                    "block starts went backwards in \(source.debugDescription)")
            }
        }
    }

    // MARK: - Constants Swift keeps its own copy of

    /// `TableAlignment` hand-writes the packing the core defines.
    ///
    /// `MarkdownModel.swift` is deliberately pure Foundation — it is the one
    /// model file that does not import the C header — so it restates `bits`
    /// as a literal rather than reading `MDTABLE_ALIGNMENT_BITS`. That keeps
    /// the file portable and makes the two copies free to drift: widening the
    /// field in Rust would leave Swift shifting by the old width, and every
    /// table cell would decode a wrong column index with nothing failing.
    ///
    /// `MDTABLE_ALIGNMENT_MASK` cannot be read from Swift at all — it is
    /// `((1 << MDTABLE_ALIGNMENT_BITS) - 1)`, outside the importable macro
    /// grammar `core/tests/header_contract.rs` describes — so the mask is
    /// re-derived here from the width rather than compared directly.
    func testTableAlignmentPackingMatchesTheCore() {
        #if canImport(CMarkDev)
            XCTAssertEqual(
                TableAlignment.bits, UInt32(MDTABLE_ALIGNMENT_BITS),
                "Swift and the core disagree about the width of the alignment field")
            XCTAssertEqual(
                TableAlignment.mask, (1 << UInt32(MDTABLE_ALIGNMENT_BITS)) - 1,
                "the derived mask no longer covers the core's alignment field")
            XCTAssertTrue(
                TableAlignment.allCases.allSatisfy { $0.rawValue <= TableAlignment.mask },
                "an alignment case does not fit the field it is packed into")
        #endif
    }
}
