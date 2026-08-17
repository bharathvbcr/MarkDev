//
//  IntelligenceLiveTests.swift
//  MarkDevKitTests
//
//  The parts that only the real model can answer.
//

import FoundationModels
import XCTest

@testable import MarkDevKit

/// Exercises the on-device model itself.
///
/// # Why these skip instead of failing
///
/// Apple Intelligence is not present on every Mac, and a suite that goes red
/// on an ineligible machine trains people to ignore it. These **skip**, which
/// is the honest report: the check did not run. What must never happen is the
/// third option — passing quietly on a machine where no model was ever
/// consulted, so that "tests green" comes to mean "nobody looked".
///
/// # What is worth asserting against a language model
///
/// Not the wording. A model that returns a different sentence today has not
/// regressed. What these pin down is the *contract*: that the structured
/// schema in ``ProofreadingReport`` still decodes, that a rewrite comes back
/// as text rather than a refusal, and that the response cleanup leaves nothing
/// the editor would paste into a document verbatim.
@MainActor
final class IntelligenceLiveTests: XCTestCase {
    private func makeService() throws -> IntelligenceService {
        let service = IntelligenceService()
        try XCTSkipUnless(
            service.state.isReady,
            "Apple Intelligence is \(service.state) on this machine; the model was not consulted.")
        return service
    }

    /// The schema is the one thing a unit test cannot check: `@Generable`
    /// produces it at compile time, but whether the model can actually be
    /// constrained to it is a runtime fact.
    func testTheProofreadingSchemaRoundTrips() async throws {
        let service = try makeService()
        let report = try await service.proofread("The report are finished. Its ready to send.")

        for finding in report.findings {
            XCTAssertFalse(finding.original.isEmpty, "a finding with no quote cannot be located")
            XCTAssertNotEqual(
                finding.original, finding.replacement, "a finding must propose a change")
        }
    }

    /// A finding is only useful if it can be found. This is the assumption the
    /// whole underlining scheme rests on, and the only place it can be checked
    /// against real model output.
    func testFindingsCanBeLocatedInTheTextTheyCameFrom() async throws {
        let service = try makeService()
        let source = "We was ready. Their going to be late. Its a shame."
        let report = try await service.proofread(source)
        try XCTSkipIf(
            report.findings.isEmpty, "the model reported nothing on this sample; nothing to locate")

        let placed = ProofreadingIssues.locate(
            report.findings, in: source as NSString,
            within: NSRange(location: 0, length: (source as NSString).length))
        let issues = placed.issues
        XCTAssertEqual(
            placed.unplaced, 0,
            "\(placed.unplaced) of \(report.findings.count) findings could not be placed")
        XCTAssertFalse(
            issues.isEmpty,
            "none of \(report.findings.count) findings could be found in the source")
        for issue in issues.issues {
            XCTAssertEqual(
                (source as NSString).substring(with: issue.range), issue.original,
                "a located range must cover exactly the text it quoted")
        }
    }

    func testARewriteReturnsUsableText() async throws {
        let service = try makeService()
        let result = try await service.rewrite(
            task: .concise,
            text: "It is, in point of fact, the case that this sentence is really rather long "
                + "and could without much difficulty be made a good deal shorter.")

        XCTAssertFalse(result.isEmpty)
        // Rule 3 of the instructions, plus `WritingResponse.clean` behind it.
        XCTAssertFalse(result.hasPrefix("```"), "a fence would be pasted into the document")
        XCTAssertFalse(result.hasPrefix("\""), "so would a stray quotation mark")
    }

    func testStreamingReportsProgressBeforeItFinishes() async throws {
        let service = try makeService()
        var snapshots: [String] = []
        let result = try await service.rewrite(
            task: .professional,
            text: "hey so the thing we talked about is done, more or less, let me know"
        ) { partial in
            snapshots.append(partial)
        }

        XCTAssertFalse(snapshots.isEmpty, "the panel has nothing to show without partials")
        XCTAssertEqual(snapshots.last, result, "the last partial must be the final answer")
    }

    /// The reason ``SystemLanguageModel/Guardrails/permissiveContentTransformations``
    /// is used for rewrites: with the default guardrails, ordinary prose about
    /// unpleasant subjects is refused, and a Markdown editor that will not
    /// proofread a note about a diagnosis is not one anybody keeps.
    func testOrdinaryProseAboutADifficultSubjectIsNotRefused() async throws {
        let service = try makeService()
        let result = try await service.rewrite(
            task: .proofread,
            text: "The patient was diagnosed with an aggressive tumour, and the prognosis "
                + "were poor. The family were informed that evening.")
        XCTAssertFalse(result.isEmpty)
    }

    /// The whole grammar-detection path, end to end: plan the passes, ask the
    /// model, find the quotes in the document, underline them, and correct
    /// one. Every stage of this is unit-tested against fabricated findings;
    /// this is the only check that the stages fit together around *real* model
    /// output, which is the join that fabricated data cannot exercise.
    func testProofreadingRunsThroughTheEditorAndCorrectsTheText() async throws {
        let service = try makeService()
        let source = """
            # Notes

            We was ready for the meeting. Their going to send the deck later.

            ```swift
            let notAWord = 1
            ```
            """
        let view = MarkdownTextView.make()
        view.setMarkdown(source)

        let assistant = DocumentAssistant(service: service)
        assistant.attach(to: view)
        assistant.proofread()
        try await waitWhile { assistant.isReviewing }

        guard case .done(let checked, let total, let found, let unplaced) = assistant.review
        else {
            return XCTFail("the pass ended as \(assistant.review)")
        }
        XCTAssertEqual(checked, total, "a short note must be checked completely")
        XCTAssertEqual(
            unplaced, 0,
            "every finding on this sample should be placeable; \(unplaced) were not")
        XCTAssertGreaterThan(found, 0, "the model must catch at least one of two blatant errors")

        // Every underline must sit on the words it objected to, and never
        // inside the code fence.
        let text = view.markdown as NSString
        for issue in view.issues.issues {
            XCTAssertEqual(text.substring(with: issue.range), issue.original)
            XCTAssertFalse(
                issue.original.contains("notAWord"), "code must never be proofread")
            XCTAssertNotNil(
                view.textStorage?.attribute(
                    .underlineStyle, at: issue.range.location, effectiveRange: nil),
                "a located issue must be underlined")
        }

        let before = view.markdown
        assistant.fixAll()
        XCTAssertNotEqual(view.markdown, before, "Fix All must change the document")
        XCTAssertTrue(view.issues.isEmpty, "and clear the underlines it acted on")
        XCTAssertTrue(
            view.markdown.contains("let notAWord = 1"), "the code block must be untouched")
    }

    /// Polls rather than awaits: the assistants deliberately run their work in
    /// a detached, cancellable task so the panel stays responsive, which means
    /// there is no future for a test to await on — only observable state.
    private func waitWhile(
        _ isBusy: () -> Bool, timeout: Duration = .seconds(120)
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while isBusy() {
            if ContinuousClock.now > deadline { return XCTFail("timed out waiting for the model") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Cancelled *mid-stream*, once the model has actually started answering.
    ///
    /// Cancelling before the request leaves the starting line proves nothing —
    /// it only shows that an already-cancelled task does not run. Stopping a
    /// rewrite that is halfway through is what the panel's Stop button does,
    /// and the partial text it leaves behind is what the panel then offers.
    func testCancellingARewriteMidStreamStopsIt() async throws {
        let service = try makeService()
        var partials: [String] = []

        let task = Task { @MainActor in
            try await service.rewrite(
                task: .expand,
                text: "The printing press changed how knowledge moved through Europe."
            ) { partial in
                partials.append(partial)
            }
        }

        // Let the stream get going before pulling the plug.
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while partials.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let seenBeforeCancelling = partials.count
        task.cancel()

        do {
            _ = try await task.value
            // Finishing in the gap between the last poll and `cancel()` is
            // legitimate; what must not happen is a *different* error.
        } catch is CancellationError {
            XCTAssertGreaterThan(
                seenBeforeCancelling, 0, "the stream must have been running to have been stopped")
        } catch {
            XCTFail("cancellation must not surface as \(error)")
        }
    }
}
