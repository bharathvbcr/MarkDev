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

    /// The state of the structured reading of the note.
    ///
    /// Carries `truncated` on the way out rather than only in the panel: a
    /// brief of the first four thousand characters of a long note is useful,
    /// and a brief presented as covering a document it only saw the opening of
    /// is misleading. The state is what says which one is on screen.
    public enum Reading: Equatable {
        case idle
        case running
        case ready(truncated: Bool)
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
    public private(set) var reading: Reading = .idle
    /// What the last reading found. Empty until one has finished.
    ///
    /// Settable within the framework rather than through a test-only method:
    /// the apply actions below are the part worth testing and they need a brief
    /// to apply, and a `setBriefForTesting` shipped in the app would be a seam
    /// nothing else uses.
    public internal(set) var brief = NoteBrief(summary: "", keyPoints: [], title: "", tags: [])
    /// The mistakes marked in the attached editor. See the note above: this
    /// follows the editor, never the other way round.
    public private(set) var issues: ProofreadingIssues = .none

    @ObservationIgnored private let reviewRequest = IntelligenceRequest()
    @ObservationIgnored private let readingRequest = IntelligenceRequest()

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

    public var isReading: Bool {
        reading == .running
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

    // MARK: - Reading the note

    /// Reads the note and fills in ``brief``.
    ///
    /// One request, not four. The panel used to offer Summarize, Key Points,
    /// Suggest a Title and Suggest Tags as separate buttons returning free text
    /// into a shared box; each was a round trip to the same model about the
    /// same document, and none of the four answers could be *applied* to
    /// anything, because an opaque string affords nothing but Copy. See
    /// ``NoteBrief``.
    public func analyze() {
        guard let surface else { return }
        service.refreshAvailability()
        guard service.state.isReady else {
            reading = .failed(service.state.guidance)
            return
        }

        let (text, truncated) = Self.source(from: surface.markdown)
        guard !text.isEmpty else {
            reading = .failed("This document is empty.")
            return
        }

        reading = .running
        readingRequest.start { [weak self] in
            guard let self else { return }
            do {
                let found = try await self.service.brief(text)
                try Task.checkCancellation()
                self.brief = found
                self.reading =
                    found.isEmpty
                    ? .failed("Apple Intelligence returned nothing for that.")
                    : .ready(truncated: truncated)
            } catch is CancellationError {
                self.reading = self.readingRequest.didTimeOut
                    ? .failed(IntelligenceFailure.timedOut.localizedDescription)
                    : .idle
            } catch {
                self.reading = .failed(error.localizedDescription)
            }
        }
    }

    public func stopReading() {
        readingRequest.cancel()
        reading = .idle
    }

    /// Copies one piece of the brief.
    public func copy(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Puts the suggested title in as the note's first heading.
    ///
    /// Replaces an existing leading `# ` heading rather than stacking a second
    /// one on top of it, which is what an unconditional insert at the top would
    /// do — and a note with two H1s is a note whose outline is now wrong.
    @discardableResult
    public func applyTitle() -> Bool {
        guard let surface, surface.acceptsAssistedEdits, !brief.title.isEmpty else { return false }
        let existing = Self.leadingHeadingRange(in: surface.markdown)
        return surface.applyAssistedEdit(
            range: existing ?? NSRange(location: 0, length: 0),
            replacement: existing == nil ? "# \(brief.title)\n\n" : "# \(brief.title)",
            actionName: existing == nil ? "Insert Title" : "Replace Title")
    }

    /// Inserts the tags as a line at the caret.
    @discardableResult
    public func insertTags() -> Bool {
        guard let surface, surface.acceptsAssistedEdits, !brief.tags.isEmpty else { return false }
        return surface.applyAssistedEdit(
            range: surface.selectedRange(),
            replacement: brief.tagLine,
            actionName: "Insert Tags")
    }

    /// Inserts the key points as a bullet list at the caret.
    @discardableResult
    public func insertKeyPoints() -> Bool {
        guard let surface, surface.acceptsAssistedEdits, !brief.keyPoints.isEmpty else {
            return false
        }
        return surface.applyAssistedEdit(
            range: surface.selectedRange(),
            replacement: brief.keyPointList,
            actionName: "Insert Key Points")
    }

    /// Inserts the summary at the caret.
    @discardableResult
    public func insertSummary() -> Bool {
        guard let surface, surface.acceptsAssistedEdits, !brief.summary.isEmpty else {
            return false
        }
        return surface.applyAssistedEdit(
            range: surface.selectedRange(),
            replacement: brief.summary,
            actionName: "Insert Summary")
    }

    /// The range of a leading ATX heading, if the note opens with one.
    ///
    /// Read off the text rather than off the parse, because this runs while the
    /// panel is open and the parse belongs to the editor. It is deliberately
    /// strict: only a `#` heading on the very first line counts, so a note that
    /// opens with frontmatter or a paragraph gets an insertion rather than
    /// having its first line rewritten.
    nonisolated static func leadingHeadingRange(in markdown: String) -> NSRange? {
        let text = markdown as NSString
        guard text.length > 0 else { return nil }
        let firstLine = text.lineRange(for: NSRange(location: 0, length: 0))
        let line = text.substring(with: firstLine)
        guard line.hasPrefix("# ") else { return nil }
        // The newline is left out: replacing it would join the heading to
        // whatever follows.
        let trimmed = line.hasSuffix("\n") ? firstLine.length - 1 : firstLine.length
        return NSRange(location: 0, length: trimmed)
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
