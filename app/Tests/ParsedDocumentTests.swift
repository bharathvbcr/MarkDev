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

final class PreviewRendererTests: XCTestCase {
    func testSyntaxIsRemovedFromReadingOutput() {
        let rendered = PreviewRenderer.attributedString(for: "# Title\n\n**bold**")
        XCTAssertFalse(rendered.string.contains("#"))
        XCTAssertFalse(rendered.string.contains("**"))
        XCTAssertTrue(rendered.string.contains("Title"))
        XCTAssertTrue(rendered.string.contains("bold"))
    }

    func testPlainTextIsUnchanged() {
        let plain = "Nothing to see here."
        XCTAssertEqual(PreviewRenderer.attributedString(for: plain).string, plain)
    }

    func testBoldTextIsActuallyBold() {
        let rendered = PreviewRenderer.attributedString(for: "**bold**")
        let range = (rendered.string as NSString).range(of: "bold")
        let font = rendered.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(
            font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false,
            "strong spans must render bold")
    }

    func testEmphasisInsideAHeadingKeepsHeadingSize() {
        // Applying a trait must not reset the font, or nested emphasis would
        // silently shrink headings back to body size.
        let rendered = PreviewRenderer.attributedString(for: "# Big *and italic*")
        let range = (rendered.string as NSString).range(of: "and italic")
        let font = rendered.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        XCTAssertGreaterThan(font?.pointSize ?? 0, PreviewRenderer.Theme.standard.bodySize)
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.italic) ?? false)
    }

    func testNonASCIIRendersWithoutRangeDrift() {
        let rendered = PreviewRenderer.attributedString(for: "🎉 **bold** tail")
        XCTAssertEqual(rendered.string, "🎉 bold tail")
    }

    func testChecklistsKeepTheirBoxes() {
        // This path deletes hidden syntax rather than drawing over it, and a
        // `- [x]` is entirely syntax — dropped outright, a checklist arrives
        // in Quick Look as an unmarked list with its state gone.
        let rendered = PreviewRenderer.attributedString(for: "- [x] done\n- [ ] todo\n")
        XCTAssertTrue(rendered.string.contains("☑"), "a ticked box, got \(rendered.string.debugDescription)")
        XCTAssertTrue(rendered.string.contains("☐"), "an empty box, got \(rendered.string.debugDescription)")
        XCTAssertTrue(rendered.string.contains("done"))
        XCTAssertTrue(rendered.string.contains("todo"))
    }

    func testThematicBreaksLeaveAVisibleBreak() {
        let rendered = PreviewRenderer.attributedString(for: "before\n\n---\n\nafter")
        XCTAssertTrue(
            rendered.string.contains("─"),
            "a section break must not render as a blank line: \(rendered.string.debugDescription)")
    }

    func testSubstitutionsDoNotDisturbLaterText() {
        // Insertions run back to front. Front to back, each one would shift
        // every offset still to come and the later boxes would land inside
        // the words they belong beside.
        let rendered = PreviewRenderer.attributedString(
            for: "- [ ] alpha\n- [x] beta\n- [ ] gamma\n")
        let text = rendered.string
        for word in ["alpha", "beta", "gamma"] {
            XCTAssertTrue(text.contains(word), "\(word) survived intact in \(text.debugDescription)")
        }
        XCTAssertEqual(text.filter { $0 == "☐" }.count, 2)
        XCTAssertEqual(text.filter { $0 == "☑" }.count, 1)
    }
}

final class BlockExcerptTests: XCTestCase {
    func testAnExcerptReportsItsShape() {
        // The header shows these so the reader can tell at a glance whether
        // the block was ever going to fit the writing column.
        let excerpt = BlockExcerpt(
            language: "mermaid", isDiagram: true, content: "graph TD\n  A-->B\n  B-->C")
        XCTAssertEqual(excerpt.title, "Diagram")
        XCTAssertEqual(excerpt.lineCount, 3)
        // "graph TD" is the longest of the three at eight characters.
        XCTAssertEqual(excerpt.widestLine, 8)
    }

    func testAnUnlabelledFenceStillHasATitle() {
        XCTAssertEqual(
            BlockExcerpt(language: nil, isDiagram: false, content: "x").title, "Code Block")
        XCTAssertEqual(
            BlockExcerpt(language: "swift", isDiagram: false, content: "x").title, "SWIFT")
    }

    func testAnEmptyBlockHasNoLines() {
        let excerpt = BlockExcerpt(language: nil, isDiagram: false, content: "")
        XCTAssertEqual(excerpt.lineCount, 0)
        XCTAssertEqual(excerpt.widestLine, 0)
    }
}
