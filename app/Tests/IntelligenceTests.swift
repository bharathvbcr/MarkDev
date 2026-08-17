//
//  IntelligenceTests.swift
//  MarkDevKitTests
//
//  The parts of the writing tools that can be decided without the model:
//  what runs, on which characters, and what a failure is called.
//

import FoundationModels
import XCTest

@testable import MarkDevKit

final class IntelligenceAvailabilityTests: XCTestCase {
    /// Each reason has to survive as itself. Folding two of them together is
    /// how someone with the feature switched off is told to wait for a
    /// download that is not happening.
    func testEveryUnavailableReasonKeepsItsOwnState() {
        XCTAssertEqual(
            IntelligenceAvailability.state(
                of: .unavailable(.deviceNotEligible), supportsLocale: true),
            .deviceNotEligible)
        XCTAssertEqual(
            IntelligenceAvailability.state(
                of: .unavailable(.appleIntelligenceNotEnabled), supportsLocale: true),
            .notEnabled)
        XCTAssertEqual(
            IntelligenceAvailability.state(of: .unavailable(.modelNotReady), supportsLocale: true),
            .modelNotReady)
    }

    func testAvailableAndSupportedIsReady() {
        XCTAssertEqual(
            IntelligenceAvailability.state(of: .available, supportsLocale: true), .ready)
    }

    func testAvailableButUnsupportedLanguageIsNotReady() {
        let state = IntelligenceAvailability.state(of: .available, supportsLocale: false)
        XCTAssertEqual(state, .languageUnsupported)
        XCTAssertFalse(state.isReady)
    }

    /// A Mac that cannot run the model at all must not be told its *language*
    /// is the problem — that sends someone to change a setting that will not
    /// help.
    func testUnavailabilityIsReportedBeforeLanguage() {
        XCTAssertEqual(
            IntelligenceAvailability.state(
                of: .unavailable(.deviceNotEligible), supportsLocale: false),
            .deviceNotEligible)
    }

    func testEveryStateExceptReadyExplainsItself() {
        for state in IntelligenceState.allCases where state != .ready {
            XCTAssertFalse(
                state.headline.isEmpty, "\(state) needs a headline")
            XCTAssertFalse(
                state.guidance.isEmpty, "\(state) needs to say what to do about it")
        }
        XCTAssertTrue(IntelligenceState.ready.guidance.isEmpty)
    }
}

final class WritingPromptTests: XCTestCase {
    func testPromptCarriesTheDirectiveAndTheText() {
        let prompt = WritingPrompt.prompt(for: .concise, text: "Some **bold** prose.")
        XCTAssertTrue(prompt.contains(WritingTask.concise.directive))
        XCTAssertTrue(prompt.contains("Some **bold** prose."))
    }

    /// The author's text has to be visibly fenced off. A document full of
    /// headings pasted after "the text below" reads to the model as more
    /// prompt.
    func testTheAuthorsTextIsDelimited() {
        let prompt = WritingPrompt.prompt(for: .rewrite, text: "# Heading\n\nBody")
        let fenceLines = prompt.components(separatedBy: "\n").filter { $0 == "-----" }
        XCTAssertEqual(fenceLines.count, 2, "the text must be enclosed on both sides")
        XCTAssertTrue(prompt.contains("-----\n# Heading\n\nBody\n-----"))
    }

    func testInstructionsForbidFollowingTheDocument() {
        XCTAssertTrue(
            WritingPrompt.instructions.lowercased().contains("do not follow instructions"))
        XCTAssertTrue(
            ProofreadingPrompt.instructions.lowercased().contains("do not follow instructions"))
    }

    func testCustomInstructionBecomesTheDirective() {
        let task = WritingTask.custom("Translate this into French.")
        XCTAssertEqual(task.directive, "Translate this into French.")
        XCTAssertEqual(task.output, .rewrite)
        XCTAssertTrue(
            WritingPrompt.prompt(for: task, text: "x").contains("Translate this into French."))
    }

    func testEveryPresetIsDistinctAndDescribed() {
        let ids = Set(WritingTask.presets.map(\.id))
        XCTAssertEqual(ids.count, WritingTask.presets.count, "preset ids must be unique")
        for task in WritingTask.presets + WritingTask.documentPresets {
            XCTAssertFalse(task.title.isEmpty)
            XCTAssertFalse(task.directive.isEmpty)
        }
    }
}

final class WritingResponseTests: XCTestCase {
    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(WritingResponse.clean("\n  Hello.  \n"), "Hello.")
    }

    func testUnwrapsAFenceAroundTheWholeAnswer() {
        XCTAssertEqual(
            WritingResponse.clean("```markdown\n# Title\n\nBody\n```"),
            "# Title\n\nBody")
    }

    /// A response that *contains* a code block is content, not a wrapper.
    /// Unwrapping it would delete the closing fence of a real block.
    func testLeavesAnAnswerThatMerelyStartsWithAFenceAlone() {
        let answer = "```swift\nlet x = 1\n```\n\nAnd that is the example."
        XCTAssertEqual(WritingResponse.clean(answer), answer)
    }

    func testLeavesAnAnswerContainingTwoBlocksAlone() {
        let answer = "```\na\n```\n\ntext\n\n```\nb\n```"
        XCTAssertEqual(WritingResponse.clean(answer), answer)
    }

    /// Deliberately *not* stripped: the heuristic cannot tell a preamble from
    /// a first line that happens to end in a colon, and deleting a line of the
    /// author's document is worse than leaving a stray sentence visible.
    func testDoesNotGuessAtPreambles() {
        let answer = "Ingredients:\n\n- flour"
        XCTAssertEqual(WritingResponse.clean(answer), answer)
    }
}

final class AssistScopeTests: XCTestCase {
    private func scope(
        _ markdown: String, selection: NSRange, limit: Int = AssistScope.maximumLength
    ) -> AssistScope {
        AssistScope.resolve(
            selection: selection,
            in: ParsedDocument.parse(markdown),
            text: markdown as NSString,
            limit: limit)
    }

    func testARangedSelectionIsUsedAsGiven() {
        let text = "One two three."
        let selection = NSRange(location: 4, length: 3)
        XCTAssertEqual(scope(text, selection: selection), .resolved(selection))
    }

    /// The whole point of putting the caret in a paragraph and pressing a
    /// button: no drag required.
    func testABareCaretExpandsToItsParagraph() {
        let text = "First paragraph.\n\nSecond paragraph.\n\nThird."
        let caret = (text as NSString).range(of: "Second").location + 2
        guard case .resolved(let range) = scope(text, selection: NSRange(location: caret, length: 0))
        else { return XCTFail("a caret in prose must resolve") }
        XCTAssertEqual((text as NSString).substring(with: range), "Second paragraph.")
    }

    /// Nested blocks: an item is inside the list, and only the innermost one
    /// is what the caret is in — rewriting one bullet must not hand the model
    /// the whole list.
    ///
    /// The item's range includes its `- ` marker, which is correct: the marker
    /// is Markdown the rewrite has to preserve, so it has to be visible to the
    /// model rather than silently stripped and pasted back on.
    func testACaretInAListResolvesToTheItemNotTheWholeList() {
        let text = "- alpha\n- beta\n- gamma\n"
        let caret = (text as NSString).range(of: "beta").location
        guard case .resolved(let range) = scope(text, selection: NSRange(location: caret, length: 0))
        else { return XCTFail("a caret in a list must resolve") }
        XCTAssertEqual((text as NSString).substring(with: range), "- beta")
    }

    func testACaretInsideACodeFenceIsRefused() {
        let text = "Prose.\n\n```swift\nlet x = 1\n```\n"
        let caret = (text as NSString).range(of: "let x").location
        XCTAssertEqual(scope(text, selection: NSRange(location: caret, length: 0)), .verbatim)
    }

    func testASelectionInsideFrontmatterIsRefused() {
        let text = "---\ntitle: Notes\n---\n\nProse.\n"
        let selection = (text as NSString).range(of: "title: Notes")
        XCTAssertEqual(scope(text, selection: selection), .verbatim)
    }

    /// A drag that starts in prose and runs past a fence is an ordinary thing
    /// to do, and refusing it would be more annoying than useful — the model
    /// is told to leave code alone.
    func testASelectionSpanningProseAndCodeIsAllowed() {
        let text = "Prose above.\n\n```\ncode\n```\n\nProse below.\n"
        let selection = NSRange(location: 0, length: (text as NSString).length)
        XCTAssertNotNil(scope(text, selection: selection).range)
    }

    func testAnEmptyDocumentHasNothingToWorkOn() {
        XCTAssertEqual(scope("", selection: NSRange(location: 0, length: 0)), .empty)
    }

    func testASelectionOfOnlyWhitespaceHasNothingToWorkOn() {
        let text = "Word.\n\n\n\nWord."
        XCTAssertEqual(scope(text, selection: NSRange(location: 5, length: 4)), .empty)
    }

    /// The trailing newline a double-click drags in would otherwise be sent to
    /// the model as a blank line to preserve.
    func testTrailingWhitespaceIsTrimmedFromTheSelection() {
        let text = "Hello there.\n\n"
        guard case .resolved(let range) = scope(
            text, selection: NSRange(location: 0, length: (text as NSString).length))
        else { return XCTFail("prose must resolve") }
        XCTAssertEqual((text as NSString).substring(with: range), "Hello there.")
    }

    func testAnOversizedSelectionIsRefusedWithItsLength() {
        let text = String(repeating: "word ", count: 40)
        let selection = NSRange(location: 0, length: (text as NSString).length)
        XCTAssertEqual(scope(text, selection: selection, limit: 20), .tooLong(199))
    }

    func testEveryRefusalExplainsItself() {
        for scope in [AssistScope.empty, .verbatim, .tooLong(9_000)] {
            XCTAssertFalse(scope.explanation.isEmpty, "\(scope) must say why")
            XCTAssertNil(scope.range)
        }
        XCTAssertTrue(AssistScope.resolved(NSRange(location: 0, length: 1)).explanation.isEmpty)
    }
}

final class ProofreadingPlanTests: XCTestCase {
    private func chunks(_ markdown: String, limit: Int = AssistScope.maximumLength) -> [String] {
        let text = markdown as NSString
        return ProofreadingPlan.chunks(of: ParsedDocument.parse(markdown), text: text, limit: limit)
            .map { text.substring(with: $0) }
    }

    func testShortDocumentsAreOnePass() {
        let text = "# Title\n\nA paragraph.\n\nAnother one.\n"
        XCTAssertEqual(chunks(text).count, 1)
    }

    func testCodeBlocksAreNeverChecked() {
        let text = "Before.\n\n```swift\nlet notAWord = 1\n```\n\nAfter.\n"
        let passes = chunks(text)
        XCTAssertFalse(passes.contains { $0.contains("notAWord") })
        // The fence interrupts the run, so the prose either side of it is not
        // pasted together into one passage.
        XCTAssertEqual(passes.count, 2)
    }

    /// Nothing may be dropped. A pass that silently skipped a long paragraph
    /// and then reported "no mistakes" would be claiming coverage it did not
    /// have.
    func testAnOversizedBlockIsSplitRatherThanSkipped() {
        let long = (1...40).map { "Sentence number \($0) in one long block." }
            .joined(separator: "\n")
        let passes = chunks(long, limit: 120)
        XCTAssertGreaterThan(passes.count, 1)
        for sentence in ["number 1 ", "number 20 ", "number 40 "] {
            XCTAssertTrue(
                passes.contains { $0.contains(sentence) }, "\(sentence) must be checked")
        }
    }

    func testEveryPassStaysInsideItsBudget() {
        let text = (1...30).map { "Paragraph \($0) with a few words in it." }
            .joined(separator: "\n\n")
        for pass in chunks(text, limit: 200) {
            XCTAssertLessThanOrEqual((pass as NSString).length, 200)
        }
    }

    func testProseOnlyDocumentsAreCoveredCompletely() {
        let text = (1...12).map { "Paragraph \($0)." }.joined(separator: "\n\n")
        let joined = chunks(text, limit: 40).joined(separator: " ")
        for index in 1...12 {
            XCTAssertTrue(joined.contains("Paragraph \(index)."), "paragraph \(index) was skipped")
        }
    }

    func testADocumentOfOnlyCodeHasNothingToCheck() {
        XCTAssertTrue(chunks("```\nlet x = 1\n```\n").isEmpty)
    }
}

final class ProofreadingIssuesTests: XCTestCase {
    private func finding(
        _ original: String, _ replacement: String, kind: ProofreadingKind = .grammar
    ) -> ProofreadingFinding {
        ProofreadingFinding(
            original: original, replacement: replacement, kind: kind, explanation: "because")
    }

    private func locate(_ findings: [ProofreadingFinding], in text: String) -> ProofreadingIssues {
        placement(findings, in: text).issues
    }

    private func placement(
        _ findings: [ProofreadingFinding], in text: String
    ) -> (issues: ProofreadingIssues, unplaced: Int) {
        ProofreadingIssues.locate(
            findings, in: text as NSString,
            within: NSRange(location: 0, length: (text as NSString).length))
    }

    func testAFindingIsPlacedWhereItsTextActuallyIs() {
        let text = "We was ready."
        let issues = locate([finding("We was", "We were")], in: text)
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.issues[0].range, NSRange(location: 0, length: 6))
    }

    /// The model does paraphrase what it quotes. There is no safe way to guess
    /// where an approximate quote belongs, and an underline in the wrong place
    /// is a wrong answer where a missing one is only an incomplete one.
    func testAQuoteThatIsNotInTheTextIsDropped() {
        let placed = placement([finding("nowhere in here", "x")], in: "We was ready.")
        XCTAssertTrue(placed.issues.isEmpty)
        XCTAssertEqual(placed.unplaced, 1, "a dropped suggestion has to be counted")
    }

    /// Observed from the real model: asked for "the incorrect text" it would
    /// quote a whole passage back with the newlines flattened into spaces.
    /// Applying one of those would collapse a heading into the paragraph
    /// beneath it, so they are refused outright — and counted, so the panel
    /// cannot report a clean bill after discarding them.
    func testAQuoteSpanningALineBreakIsRefused() {
        let text = "# Notes\n\nWe was ready."
        let placed = placement(
            [finding("# Notes We was ready.", "# Notes We were ready.")], in: text)
        XCTAssertTrue(placed.issues.isEmpty)
        XCTAssertEqual(placed.unplaced, 1)
    }

    func testAQuoteTooLongToBeACorrectionIsRefused() {
        let sentence = String(repeating: "word ", count: 60)
        let placed = placement([finding(sentence, sentence + "!")], in: sentence)
        XCTAssertTrue(placed.issues.isEmpty)
        XCTAssertEqual(placed.unplaced, 1)
    }

    /// A finding that changes nothing is noise, not discarded work — the model
    /// emits a few on clean prose. Counting them would put "3 suggestions were
    /// skipped" under every correct paragraph.
    func testANoOpFindingIsNotCountedAsDiscarded() {
        let placed = placement([finding("ready", "ready")], in: "We are ready.")
        XCTAssertTrue(placed.issues.isEmpty)
        XCTAssertEqual(placed.unplaced, 0)
    }

    func testARepeatedPhraseResolvesToSuccessiveOccurrences() {
        let text = "we was here and we was there"
        let issues = locate(
            [finding("we was", "we were"), finding("we was", "we were")], in: text)
        XCTAssertEqual(issues.count, 2)
        XCTAssertEqual(issues.issues[0].range.location, 0)
        XCTAssertEqual(issues.issues[1].range.location, 16)
    }

    func testLocatedIssuesNeverOverlap() {
        let text = "the the the"
        let issues = locate(
            [finding("the the", "the"), finding("the", "a"), finding("the", "a")], in: text)
        for (earlier, later) in zip(issues.issues, issues.issues.dropFirst()) {
            XCTAssertLessThanOrEqual(
                NSMaxRange(earlier.range), later.range.location, "issues must not overlap")
        }
    }

    func testAFindingThatChangesNothingIsDropped() {
        XCTAssertTrue(locate([finding("ready", "ready")], in: "We are ready.").isEmpty)
    }

    func testFindingsAreLocatedRelativeToTheirChunk() {
        let text = "First we was here. Then we was there."
        let second = (text as NSString).range(of: "Then we was there.")
        let issues = ProofreadingIssues.locate(
            [finding("we was", "we were")], in: text as NSString, within: second).issues
        XCTAssertEqual(issues.count, 1)
        XCTAssertGreaterThan(issues.issues[0].range.location, second.location)
    }

    // MARK: - Surviving edits

    /// Stored, not computed: every `ProofreadingIssue` mints a fresh id, so a
    /// computed property would hand each access a different set and the
    /// identity assertions below would be comparing two unrelated lists.
    private let sample = ProofreadingIssues(issues: [
        ProofreadingIssue(
            range: NSRange(location: 10, length: 5), original: "a", replacement: "b",
            kind: .spelling, explanation: ""),
        ProofreadingIssue(
            range: NSRange(location: 40, length: 4), original: "c", replacement: "d",
            kind: .grammar, explanation: ""),
    ])

    func testAnEditAfterAnIssueLeavesItAlone() {
        let moved = sample.applying(
            edit: NSRange(location: 60, length: 0), replacementLength: 12)
        XCTAssertEqual(moved.issues[0].range.location, 10)
        XCTAssertEqual(moved.issues[1].range.location, 40)
    }

    func testAnEditBeforeAnIssueSlidesIt() {
        let moved = sample.applying(edit: NSRange(location: 0, length: 0), replacementLength: 3)
        XCTAssertEqual(moved.issues[0].range.location, 13)
        XCTAssertEqual(moved.issues[1].range.location, 43)
    }

    func testADeletionBeforeAnIssueSlidesItBack() {
        let moved = sample.applying(edit: NSRange(location: 0, length: 4), replacementLength: 0)
        XCTAssertEqual(moved.issues[0].range.location, 6)
        XCTAssertEqual(moved.issues[1].range.location, 36)
    }

    /// The whole reason the set is carried through an edit rather than thrown
    /// away: fixing one mistake must not erase the other underlines.
    func testFixingOneIssueKeepsTheOthers() {
        let moved = sample.applying(
            edit: NSRange(location: 10, length: 5), replacementLength: 7)
        XCTAssertEqual(moved.count, 1)
        XCTAssertEqual(moved.issues[0].range.location, 42)
    }

    func testAnEditThroughAnIssueDiscardsIt() {
        let moved = sample.applying(
            edit: NSRange(location: 12, length: 20), replacementLength: 0)
        XCTAssertEqual(moved.count, 1, "the straddled issue must go, the later one must stay")
        XCTAssertEqual(moved.issues[0].original, "c")
    }

    func testAnEditTouchingAnIssuesEdgeDoesNotDiscardIt() {
        let before = sample.applying(edit: NSRange(location: 15, length: 2), replacementLength: 0)
        XCTAssertEqual(before.issues[0].range, NSRange(location: 10, length: 5))
    }

    func testShiftingKeepsIdentitySoTheListDoesNotFlicker() {
        let moved = sample.applying(edit: NSRange(location: 0, length: 0), replacementLength: 1)
        XCTAssertEqual(moved.issues.map(\.id), sample.issues.map(\.id))
    }

    // MARK: - Accumulating and clamping

    func testMergingKeepsDocumentOrder() {
        let later = ProofreadingIssues(issues: [
            ProofreadingIssue(
                range: NSRange(location: 25, length: 2), original: "e", replacement: "f",
                kind: .punctuation, explanation: "")
        ])
        let merged = sample.merging(later)
        XCTAssertEqual(merged.issues.map(\.range.location), [10, 25, 40])
    }

    /// Two passes reporting the same sentence would otherwise produce two
    /// buttons that undo each other's correction.
    func testMergingRejectsAnOverlappingDuplicate() {
        let duplicate = ProofreadingIssues(issues: [
            ProofreadingIssue(
                range: NSRange(location: 12, length: 2), original: "a", replacement: "b",
                kind: .spelling, explanation: "")
        ])
        XCTAssertEqual(sample.merging(duplicate).count, 2)
    }

    func testClampingDropsIssuesPastTheEndOfTheDocument() {
        let clamped = sample.clamped(toLength: 30)
        XCTAssertEqual(clamped.count, 1)
        XCTAssertEqual(clamped.issues[0].range.location, 10)
    }

    func testIssueLookupByOffset() {
        XCTAssertEqual(sample.issue(at: 12)?.original, "a")
        XCTAssertNil(sample.issue(at: 15), "the range is half-open")
        XCTAssertNil(sample.issue(at: 0))
    }

    func testRemovingByIdentity() {
        let id = sample.issues[0].id
        XCTAssertEqual(sample.removing(id).issues.map(\.original), ["c"])
    }
}

final class IntelligenceFailureTests: XCTestCase {
    private func context(_ text: String = "test")
        -> LanguageModelSession.GenerationError.Context
    {
        .init(debugDescription: text)
    }

    func testContextOverflowIsReportedAsTooMuchText() {
        let described = IntelligenceService.describe(
            LanguageModelSession.GenerationError.exceededContextWindowSize(context()))
        XCTAssertEqual(described as? IntelligenceFailure, .tooMuchText)
    }

    func testGuardrailViolationIsReportedAsARefusal() {
        XCTAssertEqual(
            IntelligenceService.describe(
                LanguageModelSession.GenerationError.guardrailViolation(context()))
                as? IntelligenceFailure,
            .refused)
    }

    func testRateLimitingAndConcurrencyBothReadAsBusy() {
        XCTAssertEqual(
            IntelligenceService.describe(
                LanguageModelSession.GenerationError.rateLimited(context()))
                as? IntelligenceFailure, .busy)
        XCTAssertEqual(
            IntelligenceService.describe(
                LanguageModelSession.GenerationError.concurrentRequests(context()))
                as? IntelligenceFailure, .busy)
    }

    func testMissingAssetsPointAtTheDownload() {
        XCTAssertEqual(
            IntelligenceService.describe(
                LanguageModelSession.GenerationError.assetsUnavailable(context()))
                as? IntelligenceFailure,
            .unavailable(.modelNotReady))
    }

    /// Cancellation is the reader pressing Stop. Dressing it up as a failure
    /// would put an error message on screen for something that worked.
    func testCancellationPassesThroughUntouched() {
        XCTAssertTrue(IntelligenceService.describe(CancellationError()) is CancellationError)
    }

    func testEveryFailureHasSomethingToShow() {
        let failures: [IntelligenceFailure] = [
            .unavailable(.notEnabled), .tooMuchText, .refused, .unsupportedLanguage,
            .busy, .timedOut, .failed("detail"),
        ]
        for failure in failures {
            XCTAssertFalse(failure.localizedDescription.isEmpty, "\(failure) needs a message")
        }
    }
}

final class IntelligenceBudgetTests: XCTestCase {
    /// Unbounded generation on a rewrite is how a two-line note comes back as
    /// six paragraphs.
    func testTheResponseBudgetStaysInsideItsBounds() {
        for length in [0, 1, 500, 4_000, 1_000_000] {
            let budget = IntelligenceService.responseTokenBudget(
                for: .rewrite, inputLength: length)
            XCTAssertGreaterThanOrEqual(budget, 256)
            XCTAssertLessThanOrEqual(budget, 2_048)
        }
    }

    func testALongerPassageIsGivenMoreRoom() {
        XCTAssertGreaterThan(
            IntelligenceService.responseTokenBudget(for: .rewrite, inputLength: 3_000),
            IntelligenceService.responseTokenBudget(for: .rewrite, inputLength: 200))
    }

    /// A rewrite of the same paragraph twice should not come back differently
    /// for no reason; a task that authors new prose needs the freedom.
    func testRewritesRunColderThanCreations() {
        let rewrite = IntelligenceService.options(for: .concise, inputLength: 100)
        let creation = IntelligenceService.options(for: .summarize, inputLength: 100)
        XCTAssertLessThan(rewrite.temperature ?? 1, creation.temperature ?? 0)
    }
}

final class DocumentAssistantSourceTests: XCTestCase {
    func testAShortDocumentIsUsedWhole() {
        let (text, truncated) = DocumentAssistant.source(from: "  Hello.  ")
        XCTAssertEqual(text, "Hello.")
        XCTAssertFalse(truncated)
    }

    /// A summary of the opening of a document, presented as a summary of the
    /// document, is a claim the app cannot support.
    func testTruncationIsReportedRatherThanHidden() {
        let (text, truncated) = DocumentAssistant.source(
            from: String(repeating: "a", count: 500), limit: 100)
        XCTAssertEqual(text.count, 100)
        XCTAssertTrue(truncated)
    }
}

final class ReviewSummaryTests: XCTestCase {
    func testACompletePassWithNoMistakesSaysSo() {
        XCTAssertEqual(
            AssistInspectorView.summary(checked: 4, total: 4, found: 0, unplaced: 0),
            "No mistakes found.")
    }

    func testACompletePassCountsWhatItFound() {
        XCTAssertEqual(
            AssistInspectorView.summary(checked: 4, total: 4, found: 1, unplaced: 0),
            "1 mistake found.")
        XCTAssertEqual(
            AssistInspectorView.summary(checked: 4, total: 4, found: 3, unplaced: 0),
            "3 mistakes found.")
    }

    /// "No mistakes found" after reading a quarter of the document is a claim
    /// about text nobody looked at.
    func testAPartialPassNeverClaimsToHaveReadItAll() {
        let summary = AssistInspectorView.summary(checked: 12, total: 40, found: 0, unplaced: 0)
        XCTAssertTrue(summary.contains("first 12 of 40"))
        XCTAssertTrue(summary.contains("again"), "it has to say the rest is unchecked")
    }

    /// The failure this guards against: the model reports three mistakes, none
    /// of them can be matched to the text, and the panel says "No mistakes
    /// found" — a check that did not run, reported as a check that passed.
    func testDiscardedSuggestionsAreAdmittedTo() {
        let summary = AssistInspectorView.summary(checked: 4, total: 4, found: 0, unplaced: 3)
        XCTAssertTrue(summary.contains("3 further suggestions"))
        XCTAssertTrue(summary.contains("skipped"))
    }

    func testOneDiscardedSuggestionReadsAsSingular() {
        let summary = AssistInspectorView.summary(checked: 1, total: 1, found: 2, unplaced: 1)
        XCTAssertTrue(summary.contains("1 further suggestion "))
        XCTAssertTrue(summary.contains("was skipped"))
    }

    func testNothingToCheckIsItsOwnSentence() {
        XCTAssertEqual(
            AssistInspectorView.summary(checked: 0, total: 0, found: 0, unplaced: 0),
            "Nothing to check.")
    }
}
