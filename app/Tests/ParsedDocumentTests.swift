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
