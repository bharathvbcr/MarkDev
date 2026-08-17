//
//  DocumentAssistant.swift
//  MarkDevKit
//
//  Whole-document work: the proofreading pass, and what the note is about.
//

import AppKit
import Foundation

/// Runs the writing tools that apply to a document rather than a selection.
///
/// # Where the issues actually live
///
/// In the editor. It is the one place that sees every edit, so it is the only
/// place that can keep a mistake's offsets true as the document changes —
/// which is why ``ProofreadingIssues`` moves through
/// `MarkdownTextView.shouldChangeText` and not through here.
///
/// ``issues`` on this object is a *mirror*, not a second answer: it exists
/// because SwiftUI cannot observe an AppKit property, and it has exactly one
/// writer — the text view's own callback, wired up in ``attach(to:)``. Anything
/// that wants to change where a mistake is changes it in the editor and lets
/// the mirror follow.
@MainActor
@Observable
public final class DocumentAssistant {
    /// How the proofreading pass is going.
    public enum Review: Equatable {
        case idle
        case running(checked: Int, total: Int)
        /// Finished. `checked` may be fewer than `total`; see
        /// ``DocumentAssistant/maximumPasses``. `unplaced` counts suggestions
        /// the model made that could not be turned into a correction, so a
        /// pass that discarded everything never reads as a clean bill.
        case done(checked: Int, total: Int, found: Int, unplaced: Int)
        case failed(String)
    }

    /// A whole-document question and its answer.
    public enum Insight: Equatable {
        case idle
        case running(WritingTask)
        case ready(WritingTask, truncated: Bool)
        case failed(String)
    }

    /// The most passages one proofreading pass will check.
    ///
    /// Each is a separate round trip of a second or two, so an unbounded pass
    /// over a long note is a progress bar that never visibly moves. The limit
    /// is reported rather than hidden: ``Review/done(checked:total:found:)``
    /// carries both numbers so the panel can say "the first 12 of 40
    /// sections" instead of implying the whole document was read.
    public static let maximumPasses = 12

    public let service: IntelligenceService
    @ObservationIgnored public private(set) weak var surface: MarkdownTextView?

    public private(set) var review: Review = .idle
    public private(set) var insight: Insight = .idle
    public private(set) var insightText = ""
    /// The mistakes marked in the attached editor. See the note above: this
    /// follows the editor, never the other way round.
    public private(set) var issues: ProofreadingIssues = .none

    @ObservationIgnored private let reviewRequest = IntelligenceRequest()
    @ObservationIgnored private let insightRequest = IntelligenceRequest()

    public init(service: IntelligenceService) {
        self.service = service
    }

    /// Points the assistant at the editor the reader is working in.
    ///
    /// Also takes over that editor's issue callback, which is what keeps
    /// ``issues`` in step as the text is typed. Attaching to a second editor
    /// leaves the first one's callback in place but pointed at this same
    /// object; the surface check in the closure is what stops a background
    /// pane's edits rewriting the mirror for the foreground one.
    public func attach(to surface: MarkdownTextView) {
        guard self.surface !== surface else { return }
        self.surface = surface
        issues = surface.issues
        surface.onIssues = { [weak self, weak surface] updated in
            guard let self, let surface, self.surface === surface else { return }
            self.issues = updated
        }
    }

    public var isReviewing: Bool {
        if case .running = review { return true }
        return false
    }

    public var isThinking: Bool {
        if case .running = insight { return true }
        return false
    }

    // MARK: - Proofreading

    /// Checks the document and underlines what it finds.
    ///
    /// Passages are checked one at a time rather than together. Sequential is
    /// the point: the model is a single local resource, and firing a dozen
    /// requests at it at once trades a predictable minute for an unpredictable
    /// one, plus `rateLimited` errors on half of them.
    public func proofread() {
        guard let surface else { return }
        service.refreshAvailability()
        guard service.state.isReady else {
            review = .failed(service.state.guidance)
            return
        }

        let text = surface.markdown as NSString
        let snapshot = surface.markdown
        let planned = ProofreadingPlan.chunks(of: surface.parsed, text: text)
        guard !planned.isEmpty else {
            review = .done(checked: 0, total: 0, found: 0, unplaced: 0)
            surface.issues = .none
            return
        }

        let chunks = Array(planned.prefix(Self.maximumPasses))
        surface.issues = .none
        review = .running(checked: 0, total: planned.count)

        reviewRequest.start { [weak self] in
            guard let self else { return }
            var found = ProofreadingIssues.none
            var unplaced = 0

            for (index, chunk) in chunks.enumerated() {
                guard let surface = self.surface else { return }
                // The offsets in `found` are only meaningful against the text
                // they were located in. Rather than try to carry them across
                // an edit made mid-pass, stop and say so — a half-shifted set
                // of underlines is worse than an interrupted check.
                guard surface.markdown == snapshot else {
                    self.review = .failed(
                        "The document changed while it was being checked. Run the check again.")
                    return
                }

                do {
                    let report = try await self.service.proofread(text.substring(with: chunk))
                    try Task.checkCancellation()
                    let placed = ProofreadingIssues.locate(
                        report.findings, in: text, within: chunk)
                    found = found.merging(placed.issues)
                    unplaced += placed.unplaced
                    // Published as it goes, so underlines appear from the top
                    // of the document down instead of all at the end.
                    surface.issues = found
                    self.review = .running(checked: index + 1, total: planned.count)
                } catch is CancellationError {
                    self.review = .done(
                        checked: index, total: planned.count, found: found.count,
                        unplaced: unplaced)
                    return
                } catch {
                    self.review = .failed(error.localizedDescription)
                    return
                }
            }

            self.review = .done(
                checked: chunks.count, total: planned.count, found: found.count,
                unplaced: unplaced)
        }
    }

    public func stopReview() {
        reviewRequest.cancel()
        if case .running(let checked, let total) = review {
            review = .done(checked: checked, total: total, found: issues.count, unplaced: 0)
        }
    }

    /// Clears the underlines without touching the text.
    public func clearIssues() {
        surface?.issues = .none
        review = .idle
    }

    /// Applies one correction.
    ///
    /// The text at the recorded range is compared with the text the model
    /// objected to before anything is replaced. The range arithmetic is
    /// tested and the check has never yet fired — which is the point: the
    /// cost of being wrong here is silently corrupting a sentence the reader
    /// did not ask about.
    @discardableResult
    public func fix(_ issue: ProofreadingIssue) -> Bool {
        guard let surface, surface.acceptsAssistedEdits else { return false }
        let text = surface.markdown as NSString
        guard issue.range.location + issue.range.length <= text.length,
            text.substring(with: issue.range) == issue.original
        else {
            // Stale: drop the underline rather than leave a button that
            // would rewrite the wrong words.
            surface.issues = surface.issues.removing(issue.id)
            return false
        }
        return surface.applyAssistedEdit(
            range: issue.range,
            replacement: issue.replacement,
            actionName: "Correct \(issue.kind.label)")
    }

    /// Applies every correction as one undoable action.
    ///
    /// Back to front, so each replacement leaves the offsets of the ones not
    /// yet applied untouched. Front to back would need every later range
    /// shifted after every fix — the same arithmetic, done by hand, in a loop
    /// where one mistake corrupts the document.
    public func fixAll() {
        guard let surface, surface.acceptsAssistedEdits else { return }
        let pending = surface.issues.issues
        guard !pending.isEmpty else { return }

        surface.undoManager?.beginUndoGrouping()
        for issue in pending.reversed() { fix(issue) }
        // Named before the group is closed: each `fix` sets its own action
        // name as it goes, and after `endUndoGrouping` the name would attach
        // to whatever comes next instead of to this group.
        surface.undoManager?.setActionName("Correct All")
        surface.undoManager?.endUndoGrouping()
    }

    // MARK: - Insights

    /// Answers a whole-document question — a summary, a title, some tags.
    public func generate(_ task: WritingTask) {
        guard let surface else { return }
        service.refreshAvailability()
        guard service.state.isReady else {
            insight = .failed(service.state.guidance)
            return
        }

        let (text, truncated) = Self.source(from: surface.markdown)
        guard !text.isEmpty else {
            insight = .failed("This document is empty.")
            return
        }

        insightText = ""
        insight = .running(task)

        insightRequest.start { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.service.rewrite(task: task, text: text) { partial in
                    self.insightText = partial
                }
                try Task.checkCancellation()
                self.insightText = result
                self.insight = result.isEmpty
                    ? .failed("Apple Intelligence returned nothing for that.")
                    : .ready(task, truncated: truncated)
            } catch is CancellationError {
                self.insight = self.insightRequest.didTimeOut
                    ? .failed(IntelligenceFailure.timedOut.localizedDescription)
                    : .idle
            } catch {
                self.insight = .failed(error.localizedDescription)
            }
        }
    }

    public func stopThinking() {
        insightRequest.cancel()
        insight = .idle
    }

    public func copyInsight() {
        guard !insightText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(insightText, forType: .string)
    }

    /// Puts the result at the top of the document.
    public func insertInsightAtTop() {
        guard let surface, surface.acceptsAssistedEdits, !insightText.isEmpty else { return }
        surface.applyAssistedEdit(
            range: NSRange(location: 0, length: 0),
            replacement: insightText + "\n\n",
            actionName: "Insert Apple Intelligence Result")
    }

    /// As much of the document as one request may carry, and whether that was
    /// all of it.
    ///
    /// Truncation is returned rather than swallowed. A summary of the first
    /// four thousand characters of a long note is useful; a summary presented
    /// as covering a document it only saw the opening of is misleading, and
    /// the panel says which one it is holding.
    nonisolated static func source(from markdown: String, limit: Int = AssistScope.maximumLength)
        -> (text: String, truncated: Bool)
    {
        let text = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > limit else { return (text, false) }
        return (String(text.prefix(limit)), true)
    }
}
