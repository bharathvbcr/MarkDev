//
//  BridgeAgreementStressTests.swift
//  MarkDevKitTests
//
//  The core and its Swift bridge must agree about what a document is.
//
//  # Why this suite exists
//
//  `MarkdownBridge.decode` re-validates everything the core hands across the
//  FFI before trusting it — counts, ranges, string indices, ordering. That is
//  right: the boundary is where a stale `libmarkdev.a` or a corrupted payload
//  has to be caught. But a validator is only correct if it accepts everything
//  the core legitimately produces, and *nothing tested that half*.
//
//  It was wrong, and expensively so. Blocks are emitted in pre-order, so a
//  container precedes its contents and, at a shared start, outlives them; the
//  bridge held them to the `(start, end)` ordering that only spans and markers
//  are sorted by. Every nested construct in the language failed — an ordered
//  list, a table, a task list, a two-item bullet list — `decode` returned nil,
//  and the editor drew a blank page. A one-item list passed by coincidence.
//
//  Both suites were individually defensible. `core/tests` proved the parser
//  correct and the Swift suites proved the editor correct *given* a parse; the
//  invariant that spans them — **the bridge accepts what the core produces** —
//  belonged to neither, so nothing owned it and nothing caught it.
//
//  That is what this file owns. It asserts one thing over a large, adversarial
//  corpus: a document the core can parse is a document the editor can open.
//

import Foundation
import XCTest

@testable import MarkDevKit

final class BridgeAgreementStressTests: XCTestCase {

    /// A document within the parser's contract must decode.
    ///
    /// Every rejection the FFI is entitled to make is a property of the
    /// *input*, not of its structure: too many bytes, or a byte that is not
    /// text. A source that is neither is one the core parses, so a `.rejected`
    /// here is the bridge and the core disagreeing — which the reader sees as
    /// a note that opens empty.
    private func assertOpens(_ source: String, _ what: String, line: UInt = #line) {
        guard source.utf8.count <= MarkdownReadLimits.maximumDocumentBytes,
            !source.utf8.contains(0)
        else { return }

        guard case .parsed = ParsedDocument.parseChecked(source) else {
            return XCTFail(
                "the bridge refused a document the core accepts (\(what)): "
                    + "\(truncated(source)) — this is a blank page in the editor",
                file: #filePath, line: line)
        }
    }

    private func truncated(_ source: String) -> String {
        source.count <= 120 ? source.debugDescription
            : (String(source.prefix(120)) + "…").debugDescription
    }

    // MARK: - The pieces documents are built from

    /// Fragments chosen for structure, not prose: every one of them either
    /// nests, carries a payload in `data`, or interns a string — the three
    /// things the bridge validates separately.
    private static let fragments: [String] = [
        "# Heading\n", "## Deeper\n", "Setext\n=====\n", "plain paragraph\n",
        "- one\n- two\n- three\n", "1. one\n2. two\n", "998. big\n999. bigger\n",
        "1) paren\n2) paren\n", "- [ ] todo\n- [x] done\n- [X] shouting\n",
        "- outer\n  - inner\n    - deeper\n      - deepest\n",
        "| a | b |\n|---|---|\n| 1 | 2 |\n", "| l | c | r |\n|:--|:-:|--:|\n| 1 | 2 | 3 |\n",
        "> quoted\n> more\n", "> [!NOTE]\n> body\n", "> [!WARNING]\n> careful\n",
        "> [!TIP]\n>\n> | a | b |\n> |---|---|\n> | 1 | 2 |\n",
        "```swift\nlet x = 1\n```\n", "```\nplain fence\n```\n",
        "```mermaid\ngraph TD;\nA-->B;\n```\n", "    indented code\n",
        "$$\nE = mc^2\n$$\n", "inline $x^2$ math\n", "text $$display$$ inline\n",
        "![alt](pic.png)\n", "![](empty.png)\n", "[link](https://example.test)\n",
        "[[Wiki]] and [[Other|alias]]\n", "See[^1].\n\n[^1]: The note.\n",
        "[ref][key]\n\n[key]: https://example.test\n",
        "---\n", "***\n", "___\n", "---\ntitle: Note\n---\n\nBody\n",
        "+++\ntitle = \"Note\"\n+++\n\nBody\n",
        "**bold** _em_ `code` ==mark== ~~strike~~\n",
        "Term\n: definition\n", "line  \nbreak\n", "line\\\nbreak\n",
        "<img src=\"m.svg\" width=\"72\">\n", "<p align=\"center\"><img src=\"a.png\"></p>\n",
        "\n", "\n\n", "   \n", "\t\n", "é 🎉 שלום 中文\n",
        "- item\n\n  ```sh\n  echo hi\n  ```\n",
        "- item\n\n  | a | b |\n  |---|---|\n  | 1 | 2 |\n",
        "- item\n\n  $$\n  x^2\n  $$\n",
    ]

    // MARK: - The sweeps

    func testEveryFragmentOpensOnItsOwn() {
        for fragment in Self.fragments {
            assertOpens(fragment, "lone fragment")
        }
    }

    /// Adjacency changes structure: a fence after a paragraph, a list absorbing
    /// the line below it, a rule becoming a setext underline.
    func testEveryOrderedPairOfFragmentsOpens() {
        for first in Self.fragments {
            for second in Self.fragments {
                assertOpens(first + second, "pair")
                assertOpens(first + "\n" + second, "pair separated by a blank line")
            }
        }
    }

    func testLongRandomDocumentsOpen() {
        for seed in UInt64(1)...60 {
            var generator = SeededGenerator(seed: seed)
            var source = ""
            for _ in 0..<40 {
                source += Self.fragments.randomElement(using: &generator) ?? ""
                if Bool.random(using: &generator) { source += "\n" }
            }
            assertOpens(source, "random document, seed \(seed)")
        }
    }

    /// Nesting is where the ordering the bridge checks actually bites, and it
    /// deepens without bound in real notes — a quote inside a list inside a
    /// quote is an ordinary way to paste a conversation.
    func testDeeplyNestedContainersOpen() {
        for depth in 1...24 {
            let listIndent = String(repeating: "  ", count: depth - 1)
            assertOpens(listIndent + "- item\n", "list indented \(depth) levels")

            let quote = String(repeating: "> ", count: depth)
            assertOpens(quote + "quoted\n", "quote nested \(depth) deep")
            assertOpens(quote + "- item\n", "list inside \(depth) quotes")
            assertOpens(
                quote + "| a | b |\n" + quote + "|---|---|\n" + quote + "| 1 | 2 |\n",
                "table inside \(depth) quotes")
        }
    }

    /// Wide, not deep: the other way a document grows.
    func testManySiblingsOpen() {
        for count in [1, 2, 3, 8, 64, 512] {
            assertOpens(
                (0..<count).map { "- item \($0)\n" }.joined(), "\(count) list items")
            assertOpens(
                (0..<count).map { "\($0 + 1). item\n" }.joined(), "\(count) ordered items")
            let rows = (0..<count).map { "| \($0) | b |\n" }.joined()
            assertOpens("| a | b |\n|---|---|\n" + rows, "table of \(count) rows")
        }
    }

    /// Truncation is how a real file arrives when a write is interrupted, and
    /// every prefix of a valid document is a document somebody may open.
    func testEveryPrefixOfACompositeDocumentOpens() {
        let composite = Self.fragments.joined()
        let scalars = Array(composite.unicodeScalars)
        var index = 0
        while index < scalars.count {
            assertOpens(String(String.UnicodeScalarView(scalars[0..<index])), "prefix \(index)")
            index += 7
        }
    }

    /// Unterminated constructs: the state a document is in while it is typed.
    func testUnclosedConstructsOpen() {
        for unclosed in [
            "```swift\nlet x = 1\n", "```mermaid\ngraph TD;\n", "$$\nx^2\n",
            "| a | b |\n|---|---|\n| 1 |", "> [!NOTE]\n", "[link](", "![alt](",
            "[[Wiki", "**bold", "==mark", "~~strike", "`code", "---\ntitle: x\n",
            "<img src=\"a.png\"", "See[^1].\n", "[ref][key]\n",
        ] {
            assertOpens(unclosed, "unclosed construct")
            assertOpens(unclosed + "\n\ntrailing paragraph\n", "unclosed then more")
        }
    }
}
