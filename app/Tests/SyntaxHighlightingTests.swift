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

    func testAnEditUnderAFenceLeavesTheCodeAboveItColoured() throws {
        // The three attribute layers have to write over the same ground.
        //
        // `MarkdownStyler.apply` grows the scope it is handed to whole lines
        // *plus one line either side*, and its first act is `setAttributes`,
        // which drops every colour in that range. Highlighting was then
        // reapplied over the scope as **asked for**, and the guard it uses is
        // `NSIntersectionRange(block, scope).length > 0` — so a scope that
        // begins exactly at a code block's end abuts the block without
        // overlapping it, and the block is skipped. Traced on the case below:
        //
        //     asked   = {41, 10}   ← the code block is {0, 41}: no overlap
        //     written = {9, 42}    ← grew back a line, *into* the fence
        //
        // The fence's body was therefore cleared and never re-coloured, and
        // nothing repaired it until an unrelated change forced a whole-document
        // pass. Found by the random-edit oracle in `RenderingHardeningTests`
        // once documents holding rendered blocks joined its corpus, then reduced
        // to this one edit.
        let source = "```swift\nlet value = [1]\n```\n| 1 | 2 --"
        let view = MarkdownTextView.make()
        view.frame = NSRect(x: 0, y: 0, width: 520, height: 400)
        view.setMarkdown(source)

        let bracket = (source as NSString).range(of: "[")
        let punctuation = EditorTheme.standard.color(for: .punctuation)
        XCTAssertEqual(
            view.textStorage?.attribute(
                .foregroundColor, at: bracket.location, effectiveRange: nil) as? NSColor,
            punctuation, "the fence should start out highlighted")

        // Replacing the line *after* the closing fence, with text that changes
        // the block structure there.
        let tail = (view.markdown as NSString).range(of: "| 1 | 2 --")
        view.setSelectedRange(tail)
        view.insertText("- bullet\n", replacementRange: view.selectedRange())

        XCTAssertEqual(
            view.textStorage?.attribute(
                .foregroundColor, at: bracket.location, effectiveRange: nil) as? NSColor,
            punctuation,
            "an edit under a fence must not strip the code above it of its colours")
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
            .code(edge: .only, language: "swift"))
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
