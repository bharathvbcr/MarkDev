//
//  NoteBriefTests.swift
//  MarkDevKitTests
//
//  The structured reading of a note, and the packaging the model gets wrong.
//

import AppKit
import XCTest

@testable import MarkDevKit

final class NoteBriefTests: XCTestCase {
    private func brief(
        summary: String = "", keyPoints: [String] = [], title: String = "", tags: [String] = []
    ) -> NoteBrief {
        NoteBrief(summary: summary, keyPoints: keyPoints, title: title, tags: tags)
    }

    // MARK: - Packaging the model gets wrong

    /// It is told to leave the `#` off and does not always.
    func testATitleLosesItsHeadingMarkerAndItsQuotes() {
        XCTAssertEqual(brief(title: "# Quarterly Plan").normalized.title, "Quarterly Plan")
        XCTAssertEqual(brief(title: "\"Quarterly Plan\"").normalized.title, "Quarterly Plan")
        XCTAssertEqual(brief(title: "“Quarterly Plan”").normalized.title, "Quarterly Plan")
        XCTAssertEqual(brief(title: "Quarterly Plan.").normalized.title, "Quarterly Plan")
    }

    /// It is told not to bullet a key point and does.
    func testAKeyPointLosesAListMarkerItCameWith() {
        let points = ["- First", "* Second", "• Third", "1. Fourth", "Fifth"]
        XCTAssertEqual(
            brief(keyPoints: points).normalized.keyPoints,
            ["First", "Second", "Third", "Fourth", "Fifth"])
    }

    /// It is told not to prefix a tag with `#` and does.
    func testATagIsReducedToWhatMayFollowAHash() {
        XCTAssertEqual(brief(tags: ["#Planning"]).normalized.tags, ["planning"])
        XCTAssertEqual(brief(tags: ["Project Planning"]).normalized.tags, ["project-planning"])
        XCTAssertEqual(brief(tags: ["work/2026"]).normalized.tags, ["work/2026"])
    }

    /// A stray comma turns the rest of the line into part of the tag.
    func testPunctuationIsDroppedFromATag() {
        XCTAssertEqual(brief(tags: ["planning, notes"]).normalized.tags, ["planning-notes"])
        XCTAssertEqual(brief(tags: ["(draft)"]).normalized.tags, ["draft"])
    }

    /// A field asked for as one sentence occasionally comes back as two lines,
    /// and a summary carrying a line break inserted into a note silently
    /// becomes two paragraphs.
    func testNewlinesAreCollapsedRatherThanCarriedIntoTheDocument() {
        let summary = brief(summary: "A plan for Q3.\nIt covers hiring.").normalized.summary
        XCTAssertEqual(summary, "A plan for Q3. It covers hiring.")
        XCTAssertFalse(summary.contains("\n"))
    }

    /// Normalising must not invent content. A brief that came back without tags
    /// cannot be shown as one that has them.
    func testAnEmptyFieldStaysEmpty() {
        let normalized = brief(summary: "", keyPoints: ["", "  "], title: "#", tags: ["", "!!"])
            .normalized
        XCTAssertTrue(normalized.summary.isEmpty)
        XCTAssertTrue(normalized.keyPoints.isEmpty, "blank points are dropped, not kept as blanks")
        XCTAssertTrue(normalized.title.isEmpty)
        XCTAssertTrue(normalized.tags.isEmpty)
        XCTAssertTrue(normalized.isEmpty)
    }

    // MARK: - What gets inserted

    func testTheTagLineIsWhatWouldBeTyped() {
        XCTAssertEqual(brief(tags: ["planning", "q3"]).tagLine, "#planning #q3")
    }

    func testKeyPointsBecomeAMarkdownList() {
        XCTAssertEqual(brief(keyPoints: ["One", "Two"]).keyPointList, "- One\n- Two")
    }

    // MARK: - Where a title goes

    /// Only a `#` heading on the very first line counts, so a note that opens
    /// with frontmatter or a paragraph gets an insertion rather than having its
    /// first line rewritten.
    func testALeadingHeadingIsFoundOnlyWhenTheNoteOpensWithOne() {
        XCTAssertEqual(
            DocumentAssistant.leadingHeadingRange(in: "# Old\n\nBody"),
            NSRange(location: 0, length: 5))
        XCTAssertNil(DocumentAssistant.leadingHeadingRange(in: "Body\n\n# Later"))
        XCTAssertNil(DocumentAssistant.leadingHeadingRange(in: "---\ntitle: x\n---\n"))
        XCTAssertNil(DocumentAssistant.leadingHeadingRange(in: "## Second level\n"))
        XCTAssertNil(DocumentAssistant.leadingHeadingRange(in: ""))
    }

    /// The newline is deliberately outside the range: replacing it would join
    /// the heading to whatever follows.
    func testTheHeadingRangeStopsBeforeTheNewline() throws {
        let markdown = "# Old\nBody"
        let range = try XCTUnwrap(DocumentAssistant.leadingHeadingRange(in: markdown))
        XCTAssertEqual((markdown as NSString).substring(with: range), "# Old")
    }
}

@MainActor
final class NoteBriefEditTests: XCTestCase {
    private func makeAssistant(_ markdown: String) -> (DocumentAssistant, MarkdownTextView) {
        let view = MarkdownTextView.make()
        view.setMarkdown(markdown)
        let assistant = DocumentAssistant(service: IntelligenceService())
        assistant.attach(to: view)
        return (assistant, view)
    }

    /// A note with two H1s is a note whose outline is now wrong, which is what
    /// an unconditional insert at the top produces.
    func testApplyingATitleReplacesAnExistingHeadingRatherThanStackingOne() throws {
        let (assistant, view) = makeAssistant("# Old Title\n\nBody text.\n")
        assistant.brief = NoteBrief(summary: "", keyPoints: [], title: "New Title", tags: [])

        XCTAssertTrue(assistant.applyTitle())
        XCTAssertEqual(view.markdown, "# New Title\n\nBody text.\n")
    }

    func testApplyingATitleToANoteWithoutOneInsertsIt() {
        let (assistant, view) = makeAssistant("Body text.\n")
        assistant.brief = NoteBrief(summary: "", keyPoints: [], title: "New Title", tags: [])

        XCTAssertTrue(assistant.applyTitle())
        XCTAssertEqual(view.markdown, "# New Title\n\nBody text.\n")
    }

    func testNothingIsAppliedFromAnEmptyBrief() {
        let (assistant, view) = makeAssistant("Body.\n")
        XCTAssertFalse(assistant.applyTitle())
        XCTAssertFalse(assistant.insertTags())
        XCTAssertFalse(assistant.insertKeyPoints())
        XCTAssertFalse(assistant.insertSummary())
        XCTAssertEqual(view.markdown, "Body.\n", "an empty brief must not touch the document")
    }

    func testTagsAndKeyPointsGoInAtTheCaret() {
        let (assistant, view) = makeAssistant("Body.\n")
        assistant.brief = NoteBrief(
            summary: "", keyPoints: ["One", "Two"], title: "", tags: ["a", "b"])

        view.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertTrue(assistant.insertTags())
        XCTAssertTrue(view.markdown.hasPrefix("#a #b"))

        view.setSelectedRange(NSRange(location: (view.markdown as NSString).length, length: 0))
        XCTAssertTrue(assistant.insertKeyPoints())
        XCTAssertTrue(view.markdown.hasSuffix("- One\n- Two"))
    }
}
