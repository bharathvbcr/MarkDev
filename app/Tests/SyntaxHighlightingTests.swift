//
//  SyntaxHighlightingTests.swift
//  MarkDevKitTests
//

import AppKit
import XCTest

@testable import MarkDevKit

@MainActor
final class SyntaxHighlightingTests: XCTestCase {
    func testSwiftBridgeProducesUTF16SafeSpansAndCachesTheResult() throws {
        let highlighter = SyntaxHighlighter()
        let code = "let café = \"🎉\""

        XCTAssertTrue(highlighter.supports("rust"))
        let first = highlighter.spans(language: "rust", code: code)
        let second = highlighter.spans(language: "rust", code: code)

        XCTAssertEqual(first, second)
        XCTAssertFalse(first.isEmpty)
        let length = (code as NSString).length
        XCTAssertTrue(first.allSatisfy { NSMaxRange($0.range) <= length })
        let emoji = (code as NSString).range(of: "\"🎉\"")
        XCTAssertTrue(
            first.contains { $0.kind == .string && NSIntersectionRange($0.range, emoji) == emoji })
    }

    func testEditorAppliesTreeSitterColoursInsideAFencedBlock() throws {
        let source = "```rust\nfn main() { let value = 42; }\n```"
        let view = MarkdownTextView.make()
        view.setMarkdown(source)

        let fnRange = (source as NSString).range(of: "fn")
        let color = try XCTUnwrap(
            view.textStorage?.attribute(.foregroundColor, at: fnRange.location, effectiveRange: nil)
                as? NSColor)

        XCTAssertEqual(color, EditorTheme.standard.color(for: .keyword))
    }

    func testEditorInstallsItsBlockLayoutFragmentDelegate() {
        let view = MarkdownTextView.make()
        XCTAssertTrue(view.textLayoutManager?.delegate === view)
    }

    func testBlockDecorationsResolveKindsAndEdges() throws {
        let source = "```swift\nlet x = 1\n```"
        let document = ParsedDocument.parse(source)
        let block = try XCTUnwrap(document.blocks.first { $0.kind == .codeBlock })

        XCTAssertEqual(
            BlockDecoration.decoration(for: block.range, in: document),
            .code(edge: .only, language: "swift", isDiagram: false))
        XCTAssertEqual(
            BlockDecoration.edge(
                of: NSRange(location: block.range.location, length: 2), within: block.range),
            .first)
        XCTAssertEqual(
            BlockDecoration.edge(
                of: NSRange(location: NSMaxRange(block.range) - 2, length: 2), within: block.range),
            .last)
    }
}
