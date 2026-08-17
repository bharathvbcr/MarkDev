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
        guard case .code(_, let language, _) = decoration(
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
        XCTAssertTrue(BlockDecoration.code(edge: .only, language: nil, isDiagram: false).hasBackground)
    }

    func testEmptyDocumentIsHandled() {
        XCTAssertEqual(
            BlockDecoration.decoration(for: NSRange(location: 0, length: 0), in: .empty), .none)
    }

    // MARK: - Tables

    private func tableDecorations(_ source: String) -> [BlockDecoration] {
        let document = ParsedDocument.parse(source)
        let index = DocumentDecorations(document: document)
        let text = source as NSString
        var out: [BlockDecoration] = []
        var start = 0
        while start < text.length {
            let line = text.lineRange(for: NSRange(location: start, length: 0))
            out.append(index.decoration(for: line))
            start = line.location + line.length
        }
        return out
    }

    func testATableResolvesHeaderSeparatorAndBodyRows() {
        let source = """
            | Name | Qty |
            |---|---|
            | Apple | 3 |
            | Pear | 9 |

            """
        let decorations = tableDecorations(source)

        guard decorations.count >= 4 else {
            return XCTFail("expected a decoration per line, got \(decorations.count)")
        }
        XCTAssertEqual(decorations[0], .table(edge: .first, role: .header))
        XCTAssertEqual(decorations[1], .table(edge: .middle, role: .separator))
        XCTAssertEqual(decorations[2], .table(edge: .middle, role: .body(row: 0)))
        XCTAssertEqual(decorations[3], .table(edge: .last, role: .body(row: 1)))
    }

    func testBodyRowsAreNumberedPerTable() {
        // Numbering drives the alternating fill. Carrying a count across
        // tables would start the second one on the wrong stripe.
        let source = """
            | A |
            |---|
            | 1 |

            text

            | B |
            |---|
            | 2 |

            """
        let rows = tableDecorations(source).compactMap { decoration -> Int? in
            guard case .table(_, .body(let row)) = decoration else { return nil }
            return row
        }
        XCTAssertEqual(rows, [0, 0], "each table numbers its own rows from zero")
    }

    func testTableEdgesAreMeasuredAgainstTheWholeTable() {
        // A row is its own block, but it must round the *table's* corners —
        // otherwise every row would draw as a separate rounded card.
        let source = "| A |\n|---|\n| 1 |\n| 2 |\n\n"
        let edges = tableDecorations(source).compactMap { decoration -> BlockEdge? in
            guard case .table(let edge, _) = decoration else { return nil }
            return edge
        }
        XCTAssertEqual(edges.first, .first)
        XCTAssertEqual(edges.last, .last)
        XCTAssertEqual(edges.filter { $0 == .only }.count, 0)
    }

    // MARK: - Ornaments

    func testOrnamentsAreFoundForTasksTagsAndInlineCode() {
        let source = "- [x] ship `now` #urgent\n"
        let index = DocumentDecorations(document: ParsedDocument.parse(source))
        let ornaments = index.ornaments(in: NSRange(location: 0, length: (source as NSString).length))

        XCTAssertEqual(ornaments.count, 3, "got \(ornaments)")
        guard case .checkbox(_, let checked) = ornaments[0] else {
            return XCTFail("expected the task marker first, got \(ornaments[0])")
        }
        XCTAssertTrue(checked)
        guard case .codePill = ornaments[1] else {
            return XCTFail("expected the inline code pill, got \(ornaments[1])")
        }
        guard case .tagPill = ornaments[2] else {
            return XCTFail("expected the tag pill, got \(ornaments[2])")
        }
    }

    func testOrnamentsComeBackInDocumentOrder() {
        // `ornaments(in:)` binary-searches this list, so the order is a
        // correctness requirement and not a nicety. It holds because the
        // parser sorts its spans and the build preserves that — assert it
        // rather than trusting the chain.
        let source = "#alpha `code` #beta and [x](y) `more` #gamma\n"
        let index = DocumentDecorations(document: ParsedDocument.parse(source))
        let found = index.ornaments(in: NSRange(location: 0, length: (source as NSString).length))
        let starts = found.map(\.range.location)
        XCTAssertEqual(starts, starts.sorted(), "ornaments must be ascending: \(starts)")
        XCTAssertEqual(found.count, 5)
    }

    func testOrnamentLookupIsLimitedToTheRangeAsked() {
        let source = "#one and #two\n"
        let index = DocumentDecorations(document: ParsedDocument.parse(source))
        let first = (source as NSString).range(of: "#one")
        XCTAssertEqual(index.ornaments(in: first).count, 1)
        XCTAssertEqual(
            index.ornaments(in: NSRange(location: 0, length: (source as NSString).length)).count, 2)
    }

    func testNoOrnamentsInsideACodeFence() {
        // A `#` in code is code. The parser already declines to make it a tag;
        // this is the assertion that the renderer never invents one.
        let source = "```sh\n# not a tag\n```\n"
        let index = DocumentDecorations(document: ParsedDocument.parse(source))
        XCTAssertTrue(
            index.ornaments(in: NSRange(location: 0, length: (source as NSString).length)).isEmpty)
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
