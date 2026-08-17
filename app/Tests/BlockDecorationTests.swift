//
//  BlockDecorationTests.swift
//  MarkDevKitTests
//

import XCTest

@testable import MarkDevKit

final class BlockDecorationTests: XCTestCase {
    private func decoration(_ source: String, at range: NSRange) -> BlockDecoration {
        BlockDecoration.decoration(for: range, in: ParsedDocument.parse(source))
    }

    private func range(of substring: String, in source: String) -> NSRange {
        (source as NSString).range(of: substring)
    }

    // MARK: - Kinds

    func testPlainParagraphsGetNoDecoration() {
        let source = "Just a sentence."
        XCTAssertEqual(decoration(source, at: range(of: "Just", in: source)), .none)
    }

    func testFencedCodeGetsCodeDecorationWithItsLanguage() {
        let source = "```swift\nlet x = 1\n```"
        guard case .code(_, let language) = decoration(
            source, at: range(of: "let x = 1", in: source))
        else { return XCTFail("expected code decoration") }
        XCTAssertEqual(language, "swift")
    }

    func testCalloutsCarryTheirKind() {
        let source = "> [!WARNING]\n> careful"
        guard case .callout(let kind, _) = decoration(
            source, at: range(of: "careful", in: source))
        else { return XCTFail("expected callout decoration") }
        XCTAssertEqual(kind, .warning)
    }

    func testPlainBlockquotesAreQuotes() {
        let source = "> just a quote"
        guard case .quote = decoration(source, at: range(of: "just a quote", in: source)) else {
            return XCTFail("expected quote decoration")
        }
    }

    func testThematicBreaksAreRules() {
        let source = "before\n\n---\n\nafter"
        XCTAssertEqual(decoration(source, at: range(of: "---", in: source)), .rule)
    }

    func testInnermostBlockWins() {
        // A fence inside a callout should draw as code, not as the callout it
        // happens to sit in.
        let source = "> [!NOTE]\n> ```swift\n> let x = 1\n> ```"
        let decoration = decoration(source, at: range(of: "let x = 1", in: source))
        guard case .code = decoration else {
            return XCTFail("expected the inner code block to win, got \(decoration)")
        }
    }

    // MARK: - Edges

    func testASingleLineBlockIsTheOnlyEdge() {
        XCTAssertEqual(
            BlockDecoration.edge(
                of: NSRange(location: 0, length: 10), within: NSRange(location: 0, length: 10)),
            .only)
    }

    func testMultiLineBlocksReportFirstMiddleAndLast() {
        let block = NSRange(location: 0, length: 30)
        XCTAssertEqual(
            BlockDecoration.edge(of: NSRange(location: 0, length: 10), within: block), .first)
        XCTAssertEqual(
            BlockDecoration.edge(of: NSRange(location: 10, length: 10), within: block), .middle)
        XCTAssertEqual(
            BlockDecoration.edge(of: NSRange(location: 20, length: 10), within: block), .last)
    }

    func testOnlyTheOuterEdgesRoundTheirCorners() {
        // Middle fragments must draw square, or consecutive lines of a code
        // block show a seam where the rounded corners meet.
        XCTAssertTrue(BlockEdge.only.roundsTop && BlockEdge.only.roundsBottom)
        XCTAssertTrue(BlockEdge.first.roundsTop)
        XCTAssertFalse(BlockEdge.first.roundsBottom)
        XCTAssertFalse(BlockEdge.middle.roundsTop || BlockEdge.middle.roundsBottom)
        XCTAssertTrue(BlockEdge.last.roundsBottom)
        XCTAssertFalse(BlockEdge.last.roundsTop)
    }

    func testRulesDrawNoBackground() {
        XCTAssertFalse(BlockDecoration.rule.hasBackground)
        XCTAssertFalse(BlockDecoration.none.hasBackground)
        XCTAssertTrue(BlockDecoration.code(edge: .only, language: nil).hasBackground)
    }

    func testEmptyDocumentIsHandled() {
        XCTAssertEqual(
            BlockDecoration.decoration(for: NSRange(location: 0, length: 0), in: .empty), .none)
    }
}

@MainActor
final class SyntaxHighlighterTests: XCTestCase {
    func testKnownLanguagesAreSupported() {
        let highlighter = SyntaxHighlighter()
        XCTAssertTrue(highlighter.supports("rust"))
        XCTAssertTrue(highlighter.supports("swift"))
        XCTAssertFalse(highlighter.supports("klingon"))
    }

    func testSwiftCodeIsHighlighted() {
        let highlighter = SyntaxHighlighter()
        let code = "let editor = MarkdownTextView.make()"
        let spans = highlighter.spans(language: "swift", code: code)

        XCTAssertFalse(spans.isEmpty)
        let keyword = spans.first { $0.kind == .keyword }
        XCTAssertNotNil(keyword, "`let` should be a keyword")
        if let keyword {
            XCTAssertEqual((code as NSString).substring(with: keyword.range), "let")
        }
    }

    func testUnknownLanguagesAndEmptyInputYieldNothing() {
        let highlighter = SyntaxHighlighter()
        XCTAssertTrue(highlighter.spans(language: "klingon", code: "fn main() {}").isEmpty)
        XCTAssertTrue(highlighter.spans(language: nil, code: "fn main() {}").isEmpty)
        XCTAssertTrue(highlighter.spans(language: "rust", code: "").isEmpty)
    }

    func testSpansStayInsideTheCode() {
        // An out-of-range span would crash NSTextStorage rather than mis-colour.
        let highlighter = SyntaxHighlighter()
        let code = "// 🎉\nfn main() { let x = 1; }"
        let length = (code as NSString).length

        for span in highlighter.spans(language: "rust", code: code) {
            XCTAssertGreaterThan(span.range.length, 0)
            XCTAssertLessThanOrEqual(span.range.location + span.range.length, length)
        }
    }

    func testResultsAreCached() {
        // Highlighting is pure, and it runs on the keystroke path.
        let highlighter = SyntaxHighlighter()
        let code = "fn main() { let x = 1; }"
        let first = highlighter.spans(language: "rust", code: code)
        let second = highlighter.spans(language: "rust", code: code)
        XCTAssertEqual(first, second)
    }
}
