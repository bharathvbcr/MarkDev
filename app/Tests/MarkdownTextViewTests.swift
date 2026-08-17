//
//  MarkdownTextViewTests.swift
//  MarkDevKitTests
//
//  The behaviours that make a from-scratch live-preview editor feel wrong
//  when they are subtly off: caret traversal, copy fidelity, and typing
//  next to collapsed syntax.
//

import AppKit
import XCTest

@testable import MarkDevKit

@MainActor
final class MarkdownTextViewTests: XCTestCase {
    private func makeView(_ markdown: String) -> MarkdownTextView {
        let view = MarkdownTextView.make()
        view.setMarkdown(markdown)
        return view
    }

    // MARK: - Storage fidelity

    func testStorageKeepsSyntaxSoCopyRoundTrips() {
        // The decisive reason markers shrink instead of being deleted: the
        // pasteboard must receive real Markdown.
        let source = "# Title\n\nSome **bold** text."
        let view = makeView(source)
        XCTAssertEqual(view.markdown, source)
    }

    func testEditingPreservesFullSource() {
        let view = makeView("**bold**")
        view.setSelectedRange(NSRange(location: 8, length: 0))
        view.insertText(" tail", replacementRange: view.selectedRange())
        XCTAssertEqual(view.markdown, "**bold** tail")
    }

    // MARK: - Collapsing

    func testMarkersOutsideTheCaretsBlockAreCollapsed() {
        let view = makeView("# Title\n\n**bold**")
        // Caret in the heading; the `**` below belongs to another block.
        view.setSelectedRange(NSRange(location: 2, length: 0))

        guard let storage = view.textStorage else { return XCTFail("no storage") }
        let asterisks = (view.markdown as NSString).range(of: "**")
        let font = storage.attribute(.font, at: asterisks.location, effectiveRange: nil) as? NSFont
        XCTAssertEqual(
            font?.pointSize, EditorTheme.hiddenMarkerFontSize,
            "syntax outside the caret's block should be collapsed")
    }

    func testMarkersInTheCaretsBlockAreVisible() {
        let view = makeView("# Title\n\n**bold**")
        let asterisks = (view.markdown as NSString).range(of: "**")
        view.setSelectedRange(NSRange(location: asterisks.location + 3, length: 0))

        guard let storage = view.textStorage else { return XCTFail("no storage") }
        let font = storage.attribute(.font, at: asterisks.location, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(font)
        XCTAssertGreaterThan(
            font!.pointSize, EditorTheme.hiddenMarkerFontSize,
            "the caret's own block must show its syntax so it can be edited")
    }

    func testSourceModeShowsEverything() {
        let view = makeView("# Title\n\n**bold**")
        view.mode = .source
        view.setSelectedRange(NSRange(location: 0, length: 0))

        guard let storage = view.textStorage else { return XCTFail("no storage") }
        let asterisks = (view.markdown as NSString).range(of: "**")
        let font = storage.attribute(.font, at: asterisks.location, effectiveRange: nil) as? NSFont
        XCTAssertGreaterThan(font?.pointSize ?? 0, EditorTheme.hiddenMarkerFontSize)
    }

    // MARK: - Caret traversal

    func testCaretDoesNotRestInsideCollapsedSyntax() {
        // Arrow-keying past invisible `**` must not appear to hang.
        let view = makeView("# Title\n\n**bold**")
        view.setSelectedRange(NSRange(location: 0, length: 0))

        let ns = view.markdown as NSString
        let asterisks = ns.range(of: "**")
        // Aim the caret at the middle of the collapsed run.
        view.setSelectedRange(NSRange(location: asterisks.location + 1, length: 0))

        let landed = view.selectedRange().location
        XCTAssertNotEqual(
            landed, asterisks.location + 1,
            "the caret should be pushed clear of collapsed syntax")
    }

    func testForwardMotionExitsPastCollapsedSyntax() {
        // Travelling forward from another block, the caret should land beyond
        // the collapsed run rather than bouncing back to its start.
        let view = makeView("# Title\n\n**bold**")
        let ns = view.markdown as NSString
        let asterisks = ns.range(of: "**")

        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.setSelectedRange(NSRange(location: asterisks.location + 1, length: 0))

        XCTAssertEqual(
            view.selectedRange().location, asterisks.location + asterisks.length,
            "forward motion should exit past the run")
    }

    func testRevealedSyntaxIsEditableByTheCaret() {
        // The counterpart to skipping: once the caret is inside a block, its
        // syntax is revealed, and the caret must be able to sit within the
        // `**` — otherwise the markers could never be edited or deleted.
        let view = makeView("# Title\n\n**bold**")
        let ns = view.markdown as NSString
        let asterisks = ns.range(of: "**")

        // Put the caret in the bold block first, revealing its syntax.
        view.setSelectedRange(NSRange(location: asterisks.location + 4, length: 0))
        // Now step back into the marker run.
        view.setSelectedRange(NSRange(location: asterisks.location + 1, length: 0))

        XCTAssertEqual(
            view.selectedRange().location, asterisks.location + 1,
            "revealed syntax must be reachable so it can be edited")
    }

    func testRangedSelectionStillCoversHiddenSyntax() {
        // A selection that spans collapsed syntax must include it, or copy
        // would silently drop formatting.
        let view = makeView("# Title\n\n**bold**")
        let ns = view.markdown as NSString
        let all = NSRange(location: 0, length: ns.length)
        view.setSelectedRange(all)
        XCTAssertEqual(view.selectedRange(), all)

        let copied = ns.substring(with: view.selectedRange())
        XCTAssertTrue(copied.contains("**"), "copied text must be real Markdown")
    }

    // MARK: - Typing attributes

    func testTypingNearCollapsedSyntaxIsNotInvisible() {
        // If typing inherited the 0.01pt marker font, new characters would
        // be invisible — indistinguishable from dropped keystrokes.
        let view = makeView("# Title\n\n**bold**")
        let ns = view.markdown as NSString
        view.setSelectedRange(NSRange(location: ns.length, length: 0))
        view.insertText("X", replacementRange: view.selectedRange())

        guard let storage = view.textStorage else { return XCTFail("no storage") }
        let inserted = (view.markdown as NSString).range(of: "X")
        let font = storage.attribute(.font, at: inserted.location, effectiveRange: nil) as? NSFont
        XCTAssertGreaterThan(
            font?.pointSize ?? 0, EditorTheme.hiddenMarkerFontSize,
            "typed text must be visible")
    }

    // MARK: - Incremental restyle correctness

    func testStructuralEditRestylesTextAfterIt() {
        // Typing an opening fence changes how everything below it parses.
        // A restyle scoped to the edited line would leave the rest of the
        // document styled as prose — the failure mode incremental styling
        // must not have.
        let view = makeView("para\n\nx\n\n# Heading below\n")
        let ns0 = view.markdown as NSString
        view.setSelectedRange(NSRange(location: ns0.range(of: "x").location, length: 1))
        view.insertText("```", replacementRange: view.selectedRange())

        guard let storage = view.textStorage else { return XCTFail("no storage") }
        let ns = view.markdown as NSString
        let heading = ns.range(of: "# Heading below")
        XCTAssertNotEqual(heading.location, NSNotFound)

        // Inside a fence now, so it must be monospaced code, not a heading.
        let font = storage.attribute(.font, at: heading.location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(
            view.parsed.blocks.contains { $0.kind == .codeBlock },
            "the fence should have opened a code block")
        XCTAssertTrue(
            font?.fontDescriptor.postscriptName?.lowercased().contains("mono") ?? false
                || font?.pointSize == EditorTheme.standard.monoFont.pointSize,
            "text after a new fence must be restyled as code")
    }

    func testOrdinaryTypingKeepsDistantStylingIntact() {
        // The complement: an edit that does not change structure must leave
        // far-away styling correct, since attributes shift with the text.
        let view = makeView("# Heading\n\npara one\n\n**bold**")
        let ns = view.markdown as NSString
        view.setSelectedRange(NSRange(location: ns.range(of: "para one").location, length: 0))
        view.insertText("Z", replacementRange: view.selectedRange())

        guard let storage = view.textStorage else { return XCTFail("no storage") }
        let updated = view.markdown as NSString
        let bold = updated.range(of: "bold")
        let font = storage.attribute(.font, at: bold.location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(
            font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false,
            "distant bold styling must survive an unrelated edit")
    }

    // MARK: - Modes

    func testReadingModeIsReadOnly() {
        // The mode's whole promise is a reading surface; leaving it editable
        // also stops a plain click from following a wikilink, because an
        // editable view treats the click as caret placement.
        let view = makeView("# Title\n\n[[Somewhere]]")
        XCTAssertTrue(view.isEditable, "live preview must stay editable")

        view.mode = .reading
        XCTAssertFalse(view.isEditable)

        view.mode = .livePreview
        XCTAssertTrue(view.isEditable, "leaving reading mode restores editing")
    }

    func testWikiLinksCarryTheirTargetAsALinkAttribute() {
        // The target rides in a `.link` attribute so AppKit supplies the
        // pointing-hand cursor and click routing.
        let view = makeView("See [[Target|shown]] here.")
        guard let storage = view.textStorage else { return XCTFail("no storage") }
        let range = (view.markdown as NSString).range(of: "shown")

        let link = storage.attribute(.link, at: range.location, effectiveRange: nil) as? URL
        XCTAssertEqual(link?.scheme, MarkdownStyler.wikiLinkScheme)
        XCTAssertEqual(
            link?.host(percentEncoded: false), "Target",
            "the attribute must carry the target, not the alias shown to the reader")
    }

    // MARK: - Robustness

    func testEmptyDocumentDoesNotCrash() {
        let view = makeView("")
        XCTAssertEqual(view.markdown, "")
        XCTAssertEqual(view.parsed, .empty)
    }

    func testNonASCIIStylesTheRightCharacters() {
        let view = makeView("🎉 **bold** tail")
        guard let storage = view.textStorage else { return XCTFail("no storage") }
        let ns = view.markdown as NSString
        let bold = ns.range(of: "bold")
        let font = storage.attribute(.font, at: bold.location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(
            font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false,
            "emoji earlier in the line must not shift styling")
    }

    func testParseIsPublishedToObservers() {
        let view = MarkdownTextView.make()
        var received: ParsedDocument?
        view.onParse = { received = $0 }
        view.setMarkdown("# Title")
        XCTAssertEqual(received?.blocks.contains { $0.kind == .heading }, true)
    }

    func testTextKit2StackIsActive() {
        // TextKit 1 would silently work for plain styling but has none of the
        // fragment machinery later phases depend on.
        let view = makeView("# Title")
        XCTAssertNotNil(view.textLayoutManager, "editor must be backed by TextKit 2")
    }

    // MARK: - Scoped restyling

    /// A document long enough that a stale block would have to be *found*
    /// rather than noticed, with every construct that styles differently.
    private static func mixedDocument(sections: Int) -> String {
        (0..<sections)
            .map { i in
                """
                ## Section \(i)

                Body with **bold**, *italic*, `code`, and [[Wiki Link \(i)]].
                Tagged #section\(i) and ==highlighted== for good measure.

                - [ ] task \(i)
                - item with [a link](https://example.com/\(i))

                ```swift
                let value\(i) = \(i)
                ```

                > [!NOTE]
                > A callout in section \(i).
                """
            }
            .joined(separator: "\n\n")
    }

    /// Replaces `range` with `replacement` and asserts the result is styled
    /// exactly as a freshly opened document of the same text would be.
    ///
    /// This is what makes it safe to restyle less than the whole buffer: the
    /// scope may shrink as far as it likes provided the attributes it leaves
    /// behind are indistinguishable from a full pass.
    private func assertEditMatchesAFreshParse(
        of source: String,
        replacing range: NSRange,
        with replacement: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let edited = MarkdownTextView.make()
        edited.setMarkdown(source)
        edited.setSelectedRange(range)
        edited.insertText(replacement, replacementRange: range)

        let caret = edited.selectedRange()
        let fresh = MarkdownTextView.make()
        fresh.setMarkdown(edited.markdown)
        // Reveal depends on where the caret is, so the reference document has
        // to be looked at from the same place.
        fresh.setSelectedRange(caret)

        guard let actual = edited.textStorage, let expected = fresh.textStorage else {
            return XCTFail("no storage", file: file, line: line)
        }
        XCTAssertEqual(actual.string, expected.string, file: file, line: line)

        var offset = 0
        while offset < expected.length {
            var actualRange = NSRange(location: 0, length: 0)
            var expectedRange = NSRange(location: 0, length: 0)
            let actualAttributes = actual.attributes(at: offset, effectiveRange: &actualRange)
            let expectedAttributes = expected.attributes(at: offset, effectiveRange: &expectedRange)
            // Step to whichever run ends first. Skipping to the end of the
            // *expected* run walks straight past a difference that sits inside
            // it — which is exactly how a stale `[foo]` went unnoticed here.
            let step = min(NSMaxRange(actualRange), NSMaxRange(expectedRange))
            if actualAttributes as NSDictionary != expectedAttributes as NSDictionary {
                let context = (expected.string as NSString).substring(
                    with: NSRange(
                        location: expectedRange.location,
                        length: min(expectedRange.length, 40)))
                XCTFail(
                    """
                    styling differs at \(offset) (\(context.debugDescription)) after \
                    replacing \(NSStringFromRange(range)) with \
                    \(replacement.debugDescription):
                    edited:   \(actualAttributes)
                    expected: \(expectedAttributes)
                    """,
                    file: file, line: line)
                return
            }
            offset = max(offset + 1, step)
        }
    }

    func testEditThatDemotesAHeadingStillStylesTheRestOfTheDocument() {
        // Typing in front of `## Section 0` turns a heading into a paragraph,
        // which changes the sequence of block kinds. That used to force a
        // whole-document restyle; scoping it to the block that actually
        // changed must not leave anything below styled from the old parse.
        assertEditMatchesAFreshParse(
            of: Self.mixedDocument(sections: 12),
            replacing: NSRange(location: 0, length: 0),
            with: "x")
    }

    func testOpeningAFenceRestylesTheTextItSwallows() {
        // The opposite case: an edit whose effect reaches to the end of the
        // file. Everything after the new fence is now code, and no amount of
        // attribute-shifting makes that right on its own.
        let source = Self.mixedDocument(sections: 12)
        let anchor = (source as NSString).range(of: "Tagged #section3")
        XCTAssertNotEqual(anchor.location, NSNotFound)
        assertEditMatchesAFreshParse(
            of: source,
            replacing: NSRange(location: anchor.location, length: 0),
            with: "```\n")
    }

    func testDeletingAcrossABlockBoundaryRestylesTheJoin() {
        // A deletion moves every later offset *backwards*, so a scope computed
        // with the wrong sign would land somewhere else entirely.
        let source = Self.mixedDocument(sections: 12)
        let anchor = (source as NSString).range(of: "## Section 4")
        XCTAssertNotEqual(anchor.location, NSNotFound)
        // Swallows the blank line above the heading and its `## `, merging the
        // heading into the callout that precedes it.
        assertEditMatchesAFreshParse(
            of: source,
            replacing: NSRange(location: anchor.location - 1, length: 4),
            with: "")
    }

    func testAddingALinkReferenceDefinitionRestylesTheLinkItResolves() {
        // The case block structure cannot see. `[foo]` is literal text until a
        // definition for it appears — which can be at the foot of the file,
        // inside a block of its own, changing nothing about the blocks above.
        // Only the spans move, so only comparing the spans catches it.
        let source = """
            See [foo] for the details.

            Another paragraph entirely.
            """
        let addition = "\n\n[foo]: https://example.test/foo"
        assertEditMatchesAFreshParse(
            of: source,
            replacing: NSRange(location: (source as NSString).length, length: 0),
            with: addition)

        // And the styling it should have arrived at, stated outright rather
        // than only by comparison — a fresh parse that failed to make it a
        // link would satisfy the comparison above.
        let view = MarkdownTextView.make()
        view.setMarkdown(source)
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        view.insertText(addition, replacementRange: view.selectedRange())

        guard let storage = view.textStorage else { return XCTFail("no storage") }
        let label = (view.markdown as NSString).range(of: "foo")
        XCTAssertNotEqual(label.location, NSNotFound)
        XCTAssertNotNil(
            storage.attribute(.underlineStyle, at: label.location, effectiveRange: nil),
            "the definition should have turned [foo] above it into a link")
    }

    func testRemovingALinkReferenceDefinitionRestylesTheLinkItBreaks() {
        // The same edit backwards: the link stops resolving and has to lose
        // its styling, from a block far below the text that changes.
        let source = """
            See [foo] for the details.

            Another paragraph entirely.

            [foo]: https://example.test/foo
            """
        let definition = (source as NSString).range(of: "\n\n[foo]: https://example.test/foo")
        XCTAssertNotEqual(definition.location, NSNotFound)
        assertEditMatchesAFreshParse(of: source, replacing: definition, with: "")
    }

    func testTypingOverASelectionOfTheSameLengthRestyles() {
        // The one case where nothing shifts: an equal-length replacement. The
        // block list is then identical on both sides of the edit, so a scope
        // derived only from moved offsets would restyle nothing at all.
        let source = Self.mixedDocument(sections: 12)
        let anchor = (source as NSString).range(of: "**bold**")
        XCTAssertNotEqual(anchor.location, NSNotFound)
        assertEditMatchesAFreshParse(of: source, replacing: anchor, with: "__bold__")
    }
}
