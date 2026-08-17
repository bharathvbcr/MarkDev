//
//  RenderingHardeningTests.swift
//  MarkDevKitTests
//
//  Tries to break the rendering layer, then holds it to its invariants.
//
//  The block renderer decides geometry from three things that can each be
//  degenerate: a parse, a set of collapsed ranges, and TextKit's own line
//  metrics. Every test here **draws** — a fragment that resolves correctly and
//  then divides by a zero-width line does nothing wrong until something asks
//  it to paint.
//
//  What is asserted, for every document:
//
//  1. Code is set in a panel, never tinted character by character.
//  2. A line that is nothing but collapsed syntax has no height left.
//  3. Every panel starts at its own frame and spans the text container.
//  4. Anything drawn outside the text is inside the surface the fragment claims.
//  5. No rect is empty, infinite, or NaN.
//  6. Styling is idempotent — a second pass changes nothing.
//  7. A block drawn as content — a diagram, a formula, a picture — is drawn
//     exactly once, and only while every character of the source it replaces is
//     collapsed.
//

import AppKit
import XCTest

@testable import MarkDevKit

@MainActor
final class RenderingHardeningTests: XCTestCase {

    // MARK: - Documents that have gone wrong before, or plausibly could

    private static let pathological: [(name: String, source: String)] = [
        ("empty", ""),
        ("one newline", "\n"),
        ("only a fence", "```"),
        ("unclosed fence", "```swift\nlet x = 1\n"),
        ("empty fence", "```\n```\n"),
        ("fence with only a language", "```swift\n```\n"),
        ("tilde fence", "~~~python\nprint(1)\n~~~\n"),
        ("indented code", "    let indented = 1\n    let more = 2\n"),
        ("fence inside a list", "- item\n\n  ```swift\n  let x = 1\n  ```\n"),
        ("fence inside a quote", "> ```swift\n> let x = 1\n> ```\n"),
        ("callout holding a fence", "> [!TIP]\n> ```swift\n> let x = 1\n> ```\n"),
        ("every callout kind", """
            > [!NOTE]
            > note

            > [!TIP]
            > tip

            > [!IMPORTANT]
            > important

            > [!WARNING]
            > warning

            > [!CAUTION]
            > caution
            """),
        ("crlf line endings", "# Title\r\n\r\n```swift\r\nlet x = 1\r\n```\r\n"),
        ("tabs for indentation", "-\titem\n\t- nested\n\n```\n\tcode\ttabbed\n```\n"),
        ("deeply nested list", (0..<12).map { String(repeating: "  ", count: $0) + "- item" }
            .joined(separator: "\n")),
        ("ordered list with big numbers", "998. a\n999. b\n1000. c\n"),
        ("ordered list with parens", "1) a\n2) b\n"),
        ("mixed bullets", "* star\n+ plus\n- dash\n"),
        ("list marker with no text", "-\n- \n-   \n"),
        ("task list", "- [ ] todo\n- [x] done\n- [X] shouting\n"),
        ("emoji and combining marks", "- 🧑‍🚀 astronaut é\u{0301}\n\n```\n🎉 fence 🎉\n```\n"),
        ("right to left", "- שלום עולם\n\n`עברית` inline\n"),
        ("inline code at every position", "`start` middle `end`\n\n`whole line`\n"),
        ("inline code in a heading", "# A `code` heading\n\n## `all code`\n"),
        ("inline code spanning a wrap", "text " + String(
            repeating: "`a very long inline code run that must wrap somewhere` ", count: 4)),
        ("empty inline code", "before `` after\n"),
        ("very long line", "```\n" + String(repeating: "x", count: 5000) + "\n```\n"),
        ("many blank lines", "para\n\n\n\n\n```\nx\n```\n\n\n\n\npara\n"),
        ("table with code cells", "| a | b |\n|---|---|\n| `x` | **y** |\n"),
        ("table inside a list", "- item\n\n  | a | b |\n  |---|---|\n  | 1 | 2 |\n"),
        ("rules everywhere", "---\n\ntext\n\n***\n\n___\n"),
        ("frontmatter", "---\ntitle: Note\n---\n\nBody\n"),
        ("math and mermaid", "$$\nE = mc^2\n$$\n\n```mermaid\ngraph TD;\nA-->B;\n```\n"),
        ("fence immediately after text", "text\n```swift\nlet x = 1\n```\ntext\n"),
        ("nothing but blank lines", "\n\n\n\n"),
        ("whitespace only line in a fence", "```\n   \n\t\n```\n"),
        // Blocks drawn as content, in every degenerate shape they come in. Each
        // of these decides whether a source is collapsed, drawn, or both.
        ("empty mermaid fence", "```mermaid\n```\n"),
        ("unclosed mermaid fence", "```mermaid\ngraph TD;\nA-->B;\n"),
        ("mermaid that cannot render", "```mermaid\nnot a diagram of any kind\n```\n"),
        ("blank mermaid body", "```mermaid\n\n\n```\n"),
        ("long mermaid", "```mermaid\ngraph TD;\n"
            + (0..<40).map { "  N\($0) --> N\($0 + 1);" }.joined(separator: "\n") + "\n```\n"),
        ("mermaid inside a list", "- item\n\n  ```mermaid\n  graph TD;\n  A-->B;\n  ```\n"),
        ("mermaid inside a quote", "> ```mermaid\n> graph TD;\n> A-->B;\n> ```\n"),
        ("two diagrams in a row", "```mermaid\ngraph TD;\nA-->B;\n```\n"
            + "```mermaid\ngraph LR;\nC-->D;\n```\n"),
        ("empty math", "$$\n$$\n"),
        ("invalid math", "$$\n\\frac{\n$$\n"),
        ("math inside a quote", "> $$\n> x^2\n> $$\n"),
        ("standalone image", "![A plan](plan.png)\n"),
        ("image with no alt", "![](plan.png)\n"),
        ("image with no target", "![alt]()\n"),
        ("two images in one paragraph", "![one](a.png) ![two](b.png)\n"),
        ("image in a sentence", "See ![icon](i.png) here.\n"),
        ("image in a list item", "- ![p](p.png)\n"),
        ("remote image", "![web](https://example.com/x.png)\n"),
        ("everything rendered at once", "![p](p.png)\n\n$$\nx^2\n$$\n\n"
            + "```mermaid\ngraph TD;\nA-->B;\n```\n\ntext\n"),
    ]

    // MARK: - The invariants

    /// Lays `source` out at `width`, draws it, and checks every invariant.
    private func check(
        _ source: String, name: String, mode: EditorMode = .reading, width: CGFloat = 520,
        caret: Int? = nil, file: StaticString = #filePath, line: UInt = #line
    ) {
        let view = MarkdownTextView.make()
        view.mode = mode
        view.frame = NSRect(x: 0, y: 0, width: width, height: 700)
        view.setMarkdown(source)
        if let caret {
            let length = (view.markdown as NSString).length
            view.setSelectedRange(NSRange(location: min(caret, length), length: 0))
        }

        guard let manager = view.textLayoutManager, let storage = view.textStorage else {
            return XCTFail("\(name): no TextKit stack", file: file, line: line)
        }
        manager.ensureLayout(for: manager.documentRange)

        assertNoCharacterTintInCode(view, name: name, file: file, line: line)
        assertCollapsedLinesHaveNoHeight(view, name: name, file: file, line: line)
        assertFragmentGeometry(view, name: name, file: file, line: line)
        assertRenderedContentStandsInForCollapsedSource(view, name: name, file: file, line: line)
        assertStylingIsIdempotent(view, name: name, file: file, line: line)

        // Drawing is where a degenerate rect finally matters.
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        XCTAssertEqual(
            view.markdown, source,
            "\(name): rendering must not touch the document", file: file, line: line)
        XCTAssertEqual(
            storage.length, (source as NSString).length,
            "\(name): storage length changed", file: file, line: line)
    }

    /// 1. A code block's characters carry no background of their own.
    private func assertNoCharacterTintInCode(
        _ view: MarkdownTextView, name: String, file: StaticString, line: UInt
    ) {
        guard let storage = view.textStorage else { return }
        for block in view.parsed.blocks
        where block.kind == .codeBlock || block.kind == .frontmatter {
            let range = NSIntersectionRange(
                block.range, NSRange(location: 0, length: storage.length))
            guard range.length > 0 else { continue }
            storage.enumerateAttribute(.backgroundColor, in: range) { value, sub, _ in
                XCTAssertNil(
                    value,
                    "\(name): code at \(sub) paints its own background, which stacks a "
                        + "ragged box on the panel",
                    file: file, line: line)
            }
        }
    }

    /// 2. A line of nothing but collapsed syntax keeps no leading.
    private func assertCollapsedLinesHaveNoHeight(
        _ view: MarkdownTextView, name: String, file: StaticString, line: UInt
    ) {
        guard let storage = view.textStorage else { return }
        let text = storage.string as NSString
        // The view's own answer, not a second computation of it. Recomputing it
        // here needs every input the view used — the reveal set, the focus, and
        // now the blocks drawn as content — and a copy that drifts turns this
        // into a test of the copy.
        let hidden = view.hiddenRanges

        var offset = 0
        while offset < text.length {
            let lineRange = text.lineRange(for: NSRange(location: offset, length: 0))
            offset = max(NSMaxRange(lineRange), offset + 1)
            guard hidden.hidesWholeLine(at: lineRange.location, in: text) else { continue }

            let style = storage.attribute(
                .paragraphStyle, at: lineRange.location, effectiveRange: nil) as? NSParagraphStyle
            XCTAssertEqual(
                style?.lineSpacing, 0,
                "\(name): collapsed line \(lineRange) still carries leading",
                file: file, line: line)
            storage.enumerateAttribute(.font, in: lineRange) { value, sub, _ in
                XCTAssertEqual(
                    (value as? NSFont)?.pointSize, EditorTheme.hiddenMarkerFontSize,
                    "\(name): collapsed line \(lineRange) is still set at full size at \(sub)",
                    file: file, line: line)
            }
        }
    }

    /// 3-5. Panels, gutters, and the rects everything is drawn into.
    private func assertFragmentGeometry(
        _ view: MarkdownTextView, name: String, file: StaticString, line: UInt
    ) {
        guard let manager = view.textLayoutManager else { return }
        let container = manager.textContainer
        let usable = (container?.size.width ?? 0) - (container?.lineFragmentPadding ?? 0) * 2

        manager.enumerateTextLayoutFragments(
            from: manager.documentRange.location, options: [.ensuresLayout]
        ) { fragment in
            guard let fragment = fragment as? MarkdownLayoutFragment else { return true }
            let rect = fragment.decorationRect
            let frame = fragment.layoutFragmentFrame

            XCTAssertTrue(
                rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite
                    && rect.height.isFinite,
                "\(name): decoration rect \(rect) is not a drawable rectangle",
                file: file, line: line)
            XCTAssertGreaterThanOrEqual(
                rect.height, 0, "\(name): negative decoration height", file: file, line: line)

            if fragment.decoration.hasBackground {
                XCTAssertEqual(
                    rect.minY, 0,
                    "\(name): a panel starting above its frame paints over the line above",
                    file: file, line: line)
                XCTAssertEqual(
                    rect.height, frame.height, accuracy: 0.01,
                    "\(name): a panel must cover its whole frame", file: file, line: line)
                if usable > 0 {
                    XCTAssertGreaterThanOrEqual(
                        rect.width, usable - 1,
                        "\(name): a panel must reach the container's edge",
                        file: file, line: line)
                }
            }

            if fragment.listMarker != nil {
                let x = MarkdownLayoutFragment.checkboxX(
                    textIndent: fragment.textIndent,
                    indentCarriedByFragment: fragment.indentCarriedByFragment,
                    gutter: MarkdownLayoutFragment.Metrics.listMarkerGutter,
                    inset: 0)
                XCTAssertTrue(x.isFinite, "\(name): marker x is not finite", file: file, line: line)
                XCTAssertLessThanOrEqual(
                    fragment.renderingSurfaceBounds.minX, x,
                    "\(name): the marker is drawn outside the surface, so it is clipped",
                    file: file, line: line)
            }
            return true
        }
    }

    /// 7. Content is drawn once, and only where the source it replaces has gone.
    ///
    /// Both directions have shipped broken, so both are asserted. Every fragment
    /// of a collapsed fence drew the whole block's diagram, which stacked one
    /// copy per line; and an image paragraph drew its picture without ever
    /// collapsing, so the reader saw the `![…](…)` *and* the image.
    private func assertRenderedContentStandsInForCollapsedSource(
        _ view: MarkdownTextView, name: String, file: StaticString, line: UInt
    ) {
        guard let manager = view.textLayoutManager else { return }
        let hidden = view.hiddenRanges
        let rendered = view.renderedBlocks

        var drawn: [Int: Int] = [:]

        manager.enumerateTextLayoutFragments(
            from: manager.documentRange.location, options: [.ensuresLayout]
        ) { fragment in
            guard let fragment = fragment as? MarkdownLayoutFragment,
                let element = fragment.rangeInElement as NSTextRange?
            else { return true }
            let start = manager.offset(from: manager.documentRange.location, to: element.location)
            let end = manager.offset(from: manager.documentRange.location, to: element.endLocation)
            guard start >= 0, end >= start else { return true }
            let range = NSRange(location: start, length: end - start)
            guard let entry = rendered.entry(overlapping: range) else {
                XCTAssertNil(
                    fragment.decoration.rendered,
                    "\(name): a fragment at \(range) draws content belonging to no block",
                    file: file, line: line)
                return true
            }

            guard let content = fragment.decoration.rendered else { return true }
            XCTAssertEqual(
                content, entry.content,
                "\(name): the fragment at \(range) draws content from another block",
                file: file, line: line)
            XCTAssertTrue(
                hidden.covers(entry.range),
                "\(name): content is drawn for \(entry.range) while its source is on screen — "
                    + "the reader sees the block written out *and* rendered over it",
                file: file, line: line)
            drawn[entry.block, default: 0] += 1
            return true
        }

        for (block, count) in drawn {
            XCTAssertEqual(
                count, 1,
                "\(name): block \(block) drew its content \(count) times; TextKit makes one "
                    + "fragment per line and only the first piece may draw",
                file: file, line: line)
        }

        // The height a block ends up occupying is asserted in
        // `RenderedBlockTests`, not here, and deliberately. It is the *symptom*
        // of drawing more than once, and stating it over arbitrary documents
        // means budgeting three costs that have nothing to do with this
        // invariant: a failure strip where nothing could render, the paragraph
        // spacing a collapsed last line deliberately keeps, and TextKit's extra
        // end-of-document line, which inside a list carries that list's indent.
        // `drawn == 1` is the cause, exactly, and it holds here over every
        // document, caret, width, and mode the sweeps below cover.
    }

    /// 6. Styling twice is styling once.
    ///
    /// On its own storage rather than the view's, because the view layers
    /// tree-sitter colours *on top of* the styler and the styler's first act is
    /// to reset them — running it again over a highlighted document is expected
    /// to differ, and would hide the drift this is looking for.
    ///
    /// The passes that measure what earlier passes wrote are the ones that can
    /// accumulate: table kerning rides on a cell's last character and measures
    /// the cell *including* it, and the collapse pass reads back a paragraph
    /// style to keep the spacing after a block.
    private func assertStylingIsIdempotent(
        _ view: MarkdownTextView, name: String, file: StaticString, line: UInt
    ) {
        let source = view.markdown
        guard !source.isEmpty else { return }

        let storage = NSTextStorage(attributedString: NSAttributedString(string: source))
        let parsed = ParsedDocument.parse(source)
        // With the rendered blocks, so the pass under test collapses whole
        // blocks as well as markers — the two shapes of hidden run behave
        // differently in the collapse pass, and only one of them was covered.
        let hidden = HiddenRanges(
            document: parsed, selection: view.selectedRange(), mode: view.mode,
            rendered: RenderedBlocks(document: parsed, text: source as NSString))

        MarkdownStyler.apply(document: parsed, hidden: hidden, to: storage)
        let once = NSAttributedString(attributedString: storage)
        MarkdownStyler.apply(document: parsed, hidden: hidden, to: storage)

        XCTAssertTrue(
            once.isEqual(to: storage),
            "\(name): a second styling pass changed the document's attributes",
            file: file, line: line)
    }

    // MARK: - Sweeps

    func testPathologicalDocumentsRenderWithinTheirInvariants() {
        for document in Self.pathological {
            check(document.source, name: document.name)
        }
    }

    func testTheSameDocumentsSurviveLivePreviewWithTheCaretInEveryBlock() {
        // Reveal changes what is collapsed, which changes what is drawn in its
        // place and how tall a line is. Every block gets a turn holding it.
        for document in Self.pathological {
            let length = (document.source as NSString).length
            guard length > 0 else { continue }
            for caret in stride(from: 0, through: length, by: max(1, length / 6)) {
                check(
                    document.source, name: "\(document.name) caret \(caret)",
                    mode: .livePreview, caret: caret)
            }
        }
    }

    func testTheSameDocumentsSurviveEveryWidthAndMode() {
        for document in Self.pathological {
            for width in [180.0, 320.0, 1600.0] as [CGFloat] {
                check(document.source, name: "\(document.name) at \(width)", width: width)
            }
            check(document.source, name: "\(document.name) source mode", mode: .source)
        }
    }

    // MARK: - Randomised documents

    private static let atoms: [String] = [
        "# Heading\n", "## Sub `code` heading\n", "para with **bold** and `code`\n",
        "- bullet\n", "  - nested bullet\n", "1. ordered\n", "7. seventh\n",
        "- [ ] task\n", "- [x] done\n", "> quote\n", "> [!WARNING]\n> careful\n",
        "```swift\nlet x = 1\n```\n", "```\nplain fence\n```\n", "~~~\ntilde\n~~~\n",
        "| a | b |\n|---|---|\n| 1 | 2 |\n", "---\n", "\n", "    indented code\n",
        "$$\nx^2\n$$\n", "text with a [[wikilink]] and #tag\n", "```unclosed\nbody\n",
        // Rendered blocks in the shuffle, so the random sweeps exercise the
        // collapse-whole-block path as well as the collapse-a-marker one.
        "```mermaid\ngraph TD;\nA-->B;\n```\n", "```mermaid\nnope\n```\n", "```mermaid\n```\n",
        "![p](p.png)\n", "$$\n$$\n", "$$\n\\frac{a}{b}\n$$\n",
    ]

    private func randomDocument(seed: UInt64, blocks: Int) -> String {
        var rng = SeededGenerator(seed: seed)
        return (0..<blocks)
            .map { _ in Self.atoms.randomElement(using: &rng)! }
            .joined()
    }

    func testRandomDocumentsHoldEveryInvariant() {
        for seed in (1...60) as ClosedRange<UInt64> {
            let source = randomDocument(seed: seed, blocks: 14)
            check(source, name: "seed \(seed)")
        }
    }

    func testRandomDocumentsHoldUpUnderRandomCarets() {
        for seed in (100...180) as ClosedRange<UInt64> {
            var rng = SeededGenerator(seed: seed)
            let source = randomDocument(seed: seed, blocks: 12)
            let length = (source as NSString).length
            guard length > 0 else { continue }
            for _ in 0..<4 {
                let caret = Int.random(in: 0...length, using: &rng)
                check(source, name: "seed \(seed) caret \(caret)", mode: .livePreview, caret: caret)
            }
        }
    }

    func testRandomEditsLeaveTheRendererConsistentWithAFreshParse() {
        // The oracle `EditorStressTests` uses, aimed at the constructs this
        // work touched: fences, alerts, and list markers, whose styling now
        // reaches whole lines and whose stand-ins depend on what is hidden.
        //
        // Sixty edits per seed of pure structural splicing — fences opening
        // and closing over their neighbours, items changing container — which
        // is what shook out the stale-parse restyle on the caret path.
        //
        // Widened from 16 seeds to 48 because it earned it: with diagrams,
        // formulas, and images in the corpus it caught a code fence losing its
        // token colours to an edit on the line below it — a scope one line
        // narrower than the range that had just been cleared. Seed 211 is the
        // one that found it; `SyntaxHighlightingTests` now pins that case
        // directly.
        for seed in (200...247) as ClosedRange<UInt64> {
            var rng = SeededGenerator(seed: seed)
            let source = randomDocument(seed: seed, blocks: 10)
            let view = MarkdownTextView.make()
            view.frame = NSRect(x: 0, y: 0, width: 520, height: 700)
            view.setMarkdown(source)

            for step in 0..<60 {
                let length = (view.markdown as NSString).length
                let start = length == 0 ? 0 : Int.random(in: 0...length, using: &rng)
                let run = length == 0 ? 0 : Int.random(in: 0...min(10, length - start), using: &rng)
                let target = (view.markdown as NSString).rangeOfComposedCharacterSequences(
                    for: NSRange(location: start, length: run))
                view.setSelectedRange(target)
                view.insertText(
                    Self.atoms.randomElement(using: &rng)!, replacementRange: view.selectedRange())

                let fresh = MarkdownTextView.make()
                fresh.frame = view.frame
                fresh.mode = view.mode
                fresh.setMarkdown(view.markdown)
                fresh.setSelectedRange(view.selectedRange())
                // A caret resting *at the edge* of a collapsed run is legal,
                // and the two views can settle on different sides of one —
                // the reveal set follows the caret, so comparing them then
                // compares two different questions. Put the edited view where
                // the fresh one landed and ask the one question that matters:
                // same text, same caret, same styling.
                view.setSelectedRange(fresh.selectedRange())

                guard let edited = view.textStorage, let expected = fresh.textStorage else {
                    return XCTFail("no storage")
                }
                if let drift = Self.firstDifference(between: edited, and: expected) {
                    XCTFail("seed \(seed) step \(step): \(drift)")
                    return
                }
            }
        }
    }

    /// Where two stylings of the same text stop agreeing, and on what.
    ///
    /// A description rather than a bare `false`: the interesting part of a
    /// drift is always *which* attribute moved and around what text.
    private static func firstDifference(
        between edited: NSTextStorage, and expected: NSTextStorage
    ) -> String? {
        guard edited.string == expected.string else {
            return "text differs:\n  \(edited.string.debugDescription)\n  "
                + "\(expected.string.debugDescription)"
        }
        let text = edited.string as NSString
        for offset in 0..<edited.length {
            let mine = edited.attributes(at: offset, effectiveRange: nil)
            let theirs = expected.attributes(at: offset, effectiveRange: nil)
            guard !NSDictionary(dictionary: mine).isEqual(to: theirs) else { continue }

            let context = NSRange(
                location: max(0, offset - 12), length: min(28, text.length - max(0, offset - 12)))
            var lines = [
                "styling differs at \(offset) "
                    + "(\(text.substring(with: context).debugDescription))"
            ]
            for key in Set(mine.keys).union(theirs.keys) {
                let a = String(describing: mine[key]).prefix(110)
                let b = String(describing: theirs[key]).prefix(110)
                if a != b { lines.append("  \(key.rawValue):\n    edited: \(a)\n    fresh:  \(b)") }
            }
            return lines.joined(separator: "\n")
        }
        return nil
    }

    // MARK: - Inline code pills

    func testAnInlineCodePillCoversTheTextItBelongsTo() throws {
        // Measured against TextKit's own answer for where those characters
        // are, because the pill is drawn in the line fragment's coordinates
        // and the fragment's origin does not always carry the paragraph's
        // indent — the trap the checkbox fell into.
        let source = "- an item with `code` in it\n"
        let view = MarkdownTextView.make()
        view.mode = .reading
        view.frame = NSRect(x: 0, y: 0, width: 520, height: 300)
        view.setMarkdown(source)

        let manager = try XCTUnwrap(view.textLayoutManager)
        manager.ensureLayout(for: manager.documentRange)

        let text = view.markdown as NSString
        let code = text.range(of: "code")
        let start = try XCTUnwrap(manager.location(manager.documentRange.location, offsetBy: code.location))
        let end = try XCTUnwrap(manager.location(start, offsetBy: code.length))
        var segment = CGRect.null
        manager.enumerateTextSegments(
            in: NSTextRange(location: start, end: end)!, type: .standard
        ) { _, rect, _, _ in
            segment = segment.union(rect)
            return true
        }
        XCTAssertFalse(segment.isNull, "TextKit should place the code run")

        var pill = CGRect.null
        manager.enumerateTextLayoutFragments(
            from: manager.documentRange.location, options: [.ensuresLayout]
        ) { fragment in
            guard let fragment = fragment as? MarkdownLayoutFragment else { return true }
            for rect in fragment.inlineCodeRects {
                pill = pill.union(rect.offsetBy(dx: fragment.layoutFragmentFrame.origin.x, dy: 0))
            }
            return true
        }
        XCTAssertFalse(pill.isNull, "the inline code run should be drawn a pill")

        // The pill hugs the run: it starts a hair before it and ends a hair
        // after, and never wanders a whole word away.
        XCTAssertEqual(
            pill.midX, segment.midX, accuracy: 2,
            "the pill has to sit on the text, not beside it")
        XCTAssertGreaterThan(pill.width, segment.width)
        XCTAssertLessThan(pill.width, segment.width + 12)
    }

    func testAPillIsShorterThanTheLineItSitsOn() throws {
        // A code word in a heading used to be given a slab the full height of
        // the line, which touched the paragraph beneath it.
        let view = MarkdownTextView.make()
        view.mode = .reading
        view.frame = NSRect(x: 0, y: 0, width: 520, height: 300)
        view.setMarkdown("# A `code` heading\n\nbody\n")

        let manager = try XCTUnwrap(view.textLayoutManager)
        manager.ensureLayout(for: manager.documentRange)

        var checked = false
        manager.enumerateTextLayoutFragments(
            from: manager.documentRange.location, options: [.ensuresLayout]
        ) { fragment in
            guard let fragment = fragment as? MarkdownLayoutFragment else { return true }
            for rect in fragment.inlineCodeRects {
                checked = true
                XCTAssertLessThan(
                    rect.height, fragment.layoutFragmentFrame.height,
                    "the pill is sized to the type, not to the leading")
                XCTAssertGreaterThan(rect.height, 8)
            }
            return true
        }
        XCTAssertTrue(checked, "the heading's inline code should have a pill")
    }
}
