//
//  IntelligenceEditorTests.swift
//  MarkDevKitTests
//
//  Where the writing tools meet the editor: underlines that survive typing,
//  and assisted edits that behave like edits.
//

import AppKit
import SwiftUI
import XCTest

@testable import MarkDevKit

/// Renders the new panels.
///
/// A SwiftUI `body` is only partly checked by the compiler: an unsatisfiable
/// layout, a `ForEach` over unstable identity, or a `switch` that produces no
/// content all compile and then misbehave at runtime. Laying each panel out
/// and asking for its fitting size is the cheapest thing that actually runs
/// the body.
@MainActor
final class IntelligencePanelTests: XCTestCase {
    private func fittingSize<V: View>(of view: V) -> NSSize {
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    func testTheInlinePanelLaysOut() {
        let size = fittingSize(of: WritingAssistPanel(assistant: WritingAssistant(service: IntelligenceService())))
        XCTAssertEqual(size.width, 400, accuracy: 1, "the popover fixes its own width")
        XCTAssertGreaterThan(size.height, 100, "the task list has to take up room")
    }

    /// `NSPopover.show(relativeTo:of:preferredEdge:)` raises an exception
    /// rather than returning an error when the anchor view is not in a window,
    /// which takes the app down with it. A surface can be windowless for
    /// perfectly ordinary reasons — the reference outliving a closed pane, or
    /// the editor existing for a moment before SwiftUI installs it.
    func testOpeningOnAWindowlessEditorDoesNotRaise() {
        let assistant = WritingAssistant(service: IntelligenceService())
        assistant.surface = MarkdownTextView.make()
        assistant.open()
        // Still in a state the panel can render, had there been anywhere to
        // put it.
        XCTAssertGreaterThan(fittingSize(of: WritingAssistPanel(assistant: assistant)).height, 0)
    }

    /// The state a reader hits first when Apple Intelligence is off, and the
    /// easiest one to leave rendering as an empty box.
    func testTheBlockedPanelStillSaysSomething() {
        let assistant = WritingAssistant(service: IntelligenceService())
        let view = MarkdownTextView.make()
        view.setMarkdown("```\nlet x = 1\n```")
        view.setSelectedRange(NSRange(location: 5, length: 0))
        assistant.surface = view
        assistant.open()

        guard case .blocked(let reason) = assistant.phase else {
            return XCTFail("a caret in code must block, got \(assistant.phase)")
        }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertGreaterThan(fittingSize(of: WritingAssistPanel(assistant: assistant)).height, 0)
    }

    func testTheInspectorPanelLaysOut() {
        let assistant = DocumentAssistant(service: IntelligenceService())
        let view = MarkdownTextView.make()
        view.setMarkdown("We was ready.")
        assistant.attach(to: view)
        view.issues = ProofreadingIssues(issues: [
            ProofreadingIssue(
                range: NSRange(location: 0, length: 6), original: "We was",
                replacement: "We were", kind: .grammar, explanation: "Verb agreement.")
        ])

        let size = fittingSize(of: AssistInspectorView(assistant: assistant) { _ in })
        XCTAssertGreaterThan(size.height, 100, "an issue row and both sections must be laid out")
    }
}

@MainActor
final class IntelligenceEditorTests: XCTestCase {
    private func makeView(_ markdown: String) -> MarkdownTextView {
        let view = MarkdownTextView.make()
        view.setMarkdown(markdown)
        return view
    }

    /// A text view in a window, which is what it takes to test undo.
    ///
    /// `NSTextView` has no undo manager of its own — it asks up the responder
    /// chain, and a detached view's chain ends at nothing. A test on a bare
    /// view would find `undo()` doing nothing and could not tell that apart
    /// from an edit that failed to register.
    private func makeHostedView(_ markdown: String) -> (MarkdownTextView, NSWindow) {
        let view = MarkdownTextView.make()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        // ARC already owns the window. Leaving this at its default of `true`
        // makes `close()` release it a second time, and the test process dies
        // in `objc_release` at the next autorelease-pool pop.
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeFirstResponder(view)
        view.setMarkdown(markdown)
        return (view, window)
    }

    private func issue(
        _ view: MarkdownTextView, of substring: String, replacement: String,
        kind: ProofreadingKind = .grammar
    ) -> ProofreadingIssue {
        ProofreadingIssue(
            range: (view.markdown as NSString).range(of: substring),
            original: substring,
            replacement: replacement,
            kind: kind,
            explanation: "")
    }

    // MARK: - Underlines

    func testAnIssueIsUnderlinedInTheEditor() throws {
        let view = makeView("We was ready for it.")
        view.issues = ProofreadingIssues(issues: [issue(view, of: "We was", replacement: "We were")])

        let style = try XCTUnwrap(
            view.textStorage?.attribute(.underlineStyle, at: 1, effectiveRange: nil) as? Int)
        XCTAssertTrue(NSUnderlineStyle(rawValue: style).contains(.patternDot))

        let colour =
            view.textStorage?.attribute(.underlineColor, at: 1, effectiveRange: nil) as? NSColor
        XCTAssertEqual(colour, ProofreadingKind.grammar.tint)
    }

    /// The styler's first act is `setAttributes`, which drops everything
    /// already in range. An underline applied before it simply is not there
    /// afterwards — the same ordering rule the syntax highlighting follows.
    func testUnderlinesSurviveARestyle() throws {
        let view = makeView("We was ready for it.")
        view.issues = ProofreadingIssues(issues: [issue(view, of: "We was", replacement: "We were")])

        // Moving the caret restyles; the underline has to still be there.
        view.setSelectedRange(NSRange(location: 12, length: 0))

        XCTAssertNotNil(
            view.textStorage?.attribute(.underlineStyle, at: 1, effectiveRange: nil))
    }

    func testUnrelatedTextIsNotUnderlined() {
        let view = makeView("We was ready for it.")
        view.issues = ProofreadingIssues(issues: [issue(view, of: "We was", replacement: "We were")])
        let tail = (view.markdown as NSString).range(of: "ready").location
        XCTAssertNil(view.textStorage?.attribute(.underlineStyle, at: tail, effectiveRange: nil))
    }

    /// Offsets from another document would land on arbitrary words here.
    func testIssuesFromADifferentDocumentAreRefused() {
        let view = makeView("Short.")
        view.issues = ProofreadingIssues(issues: [
            ProofreadingIssue(
                range: NSRange(location: 400, length: 5), original: "x", replacement: "y",
                kind: .spelling, explanation: "")
        ])
        XCTAssertTrue(view.issues.isEmpty)
    }

    func testReplacingTheDocumentDropsItsIssues() {
        let view = makeView("We was ready.")
        view.issues = ProofreadingIssues(issues: [issue(view, of: "We was", replacement: "We were")])
        XCTAssertFalse(view.issues.isEmpty)

        view.setMarkdown("An entirely different note.")
        XCTAssertTrue(view.issues.isEmpty, "issues belong to the document they were found in")
    }

    // MARK: - Surviving typing

    func testTypingAheadOfAnIssueMovesTheUnderlineWithIt() throws {
        let view = makeView("Alpha. We was ready.")
        let original = issue(view, of: "We was", replacement: "We were")
        view.issues = ProofreadingIssues(issues: [original])

        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.insertText("Zero. ", replacementRange: view.selectedRange())

        let moved = try XCTUnwrap(view.issues.issues.first)
        XCTAssertEqual(moved.range.location, original.range.location + 6)
        XCTAssertEqual(
            (view.markdown as NSString).substring(with: moved.range), "We was",
            "the underline must still cover the words it objected to")
    }

    func testTypingThroughAnIssueRemovesIt() {
        let view = makeView("Alpha. We was ready.")
        view.issues = ProofreadingIssues(issues: [issue(view, of: "We was", replacement: "We were")])

        let target = (view.markdown as NSString).range(of: "was")
        view.setSelectedRange(target)
        view.insertText("were", replacementRange: target)

        XCTAssertTrue(view.issues.isEmpty, "the objection no longer applies to this text")
    }

    func testObserversHearAboutIssuesThatMoved() {
        let view = makeView("Alpha. We was ready.")
        var reported: [Int] = []
        view.onIssues = { reported.append($0.count) }

        view.issues = ProofreadingIssues(issues: [issue(view, of: "We was", replacement: "We were")])
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.insertText("Zero. ", replacementRange: view.selectedRange())

        XCTAssertEqual(reported, [1, 1], "set once, then reported again after the edit shifted it")
    }

    // MARK: - Assisted edits

    func testAnAssistedEditChangesTheDocumentAndReparses() {
        let view = makeView("A plain paragraph.")
        let range = NSRange(location: 0, length: (view.markdown as NSString).length)

        XCTAssertTrue(
            view.applyAssistedEdit(
                range: range, replacement: "# A heading now", actionName: "Rewrite"))

        XCTAssertEqual(view.markdown, "# A heading now")
        XCTAssertTrue(
            view.parsed.blocks.contains { $0.kind == .heading },
            "the parse must follow the edit, or styling and the outline go stale")
    }

    /// Routed through `shouldChangeText`/`didChangeText` precisely so that it
    /// is an ordinary undoable edit rather than a silent write to storage.
    func testAnAssistedEditCanBeUndone() throws {
        let (view, window) = makeHostedView("We was ready.")
        defer { window.orderOut(nil) }

        let undo = try XCTUnwrap(view.undoManager, "a hosted text view must have an undo manager")
        let target = (view.markdown as NSString).range(of: "We was")
        view.applyAssistedEdit(range: target, replacement: "We were", actionName: "Correct Grammar")
        XCTAssertEqual(view.markdown, "We were ready.")
        XCTAssertEqual(undo.undoActionName, "Correct Grammar")

        undo.undo()
        XCTAssertEqual(view.markdown, "We was ready.")
    }

    /// Fix All has to collapse into one undo. Reverting a thirty-correction
    /// pass one comma at a time is not an undo anybody can use.
    func testFixAllUndoesAsASingleAction() throws {
        let (view, window) = makeHostedView("We was ready and they was too.")
        defer { window.orderOut(nil) }
        let undo = try XCTUnwrap(view.undoManager)

        let assistant = DocumentAssistant(service: IntelligenceService())
        assistant.attach(to: view)
        view.issues = ProofreadingIssues(issues: [
            issue(view, of: "We was", replacement: "We were"),
            issue(view, of: "they was", replacement: "they were"),
        ])

        assistant.fixAll()
        XCTAssertEqual(view.markdown, "We were ready and they were too.")
        XCTAssertEqual(
            undo.undoActionName, "Correct All",
            "the group must be named after the pass, not after its last correction")

        undo.undo()
        XCTAssertEqual(view.markdown, "We was ready and they was too.")
    }

    func testAnAssistedEditSelectsWhatItInserted() {
        let view = makeView("one two three")
        let target = (view.markdown as NSString).range(of: "two")
        view.applyAssistedEdit(range: target, replacement: "SECOND", actionName: "Rewrite")
        XCTAssertEqual(
            (view.markdown as NSString).substring(with: view.selectedRange()), "SECOND")
    }

    func testAnAssistedEditOutsideTheDocumentIsRefused() {
        let view = makeView("short")
        XCTAssertFalse(
            view.applyAssistedEdit(
                range: NSRange(location: 100, length: 5), replacement: "x", actionName: "Rewrite"))
        XCTAssertEqual(view.markdown, "short")
    }

    /// Reading mode is genuinely read-only; a Replace button there would be a
    /// button that quietly does nothing.
    func testReadingModeRefusesAssistedEdits() {
        let view = makeView("We was ready.")
        view.mode = .reading
        XCTAssertFalse(view.acceptsAssistedEdits)
        XCTAssertFalse(
            view.applyAssistedEdit(
                range: NSRange(location: 0, length: 6), replacement: "We were",
                actionName: "Rewrite"))
        XCTAssertEqual(view.markdown, "We was ready.")
    }

    // MARK: - The assistant driving the editor

    func testFixAppliesTheCorrection() throws {
        let view = makeView("We was ready.")
        let assistant = DocumentAssistant(service: IntelligenceService())
        assistant.attach(to: view)
        view.issues = ProofreadingIssues(issues: [issue(view, of: "We was", replacement: "We were")])

        XCTAssertTrue(assistant.fix(try XCTUnwrap(view.issues.issues.first)))
        XCTAssertEqual(view.markdown, "We were ready.")
        XCTAssertTrue(view.issues.isEmpty)
    }

    /// The text at the recorded range is compared with the text the model
    /// objected to before anything is replaced. The cost of getting this wrong
    /// is silently corrupting a sentence nobody asked about.
    func testFixRefusesWhenTheTextNoLongerMatches() {
        let view = makeView("We was ready.")
        let assistant = DocumentAssistant(service: IntelligenceService())
        assistant.attach(to: view)

        let stale = ProofreadingIssue(
            range: NSRange(location: 0, length: 6), original: "Nothing like this",
            replacement: "ruin", kind: .grammar, explanation: "")
        view.issues = ProofreadingIssues(issues: [stale])

        XCTAssertFalse(assistant.fix(stale))
        XCTAssertEqual(view.markdown, "We was ready.", "a mismatch must never rewrite the text")
        XCTAssertTrue(view.issues.isEmpty, "and the misleading underline must go")
    }

    /// Back to front, so each replacement leaves the offsets of the ones not
    /// yet applied untouched.
    func testFixAllCorrectsEveryIssue() {
        let view = makeView("We was ready and they was too.")
        let assistant = DocumentAssistant(service: IntelligenceService())
        assistant.attach(to: view)
        view.issues = ProofreadingIssues(issues: [
            issue(view, of: "We was", replacement: "We were"),
            issue(view, of: "they was", replacement: "they were"),
        ])

        assistant.fixAll()
        XCTAssertEqual(view.markdown, "We were ready and they were too.")
        XCTAssertTrue(view.issues.isEmpty)
    }

    func testTheAssistantMirrorsWhateverTheEditorHolds() {
        let view = makeView("We was ready.")
        let assistant = DocumentAssistant(service: IntelligenceService())
        assistant.attach(to: view)

        view.issues = ProofreadingIssues(issues: [issue(view, of: "We was", replacement: "We were")])
        XCTAssertEqual(assistant.issues.count, 1)

        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.insertText("Well. ", replacementRange: view.selectedRange())
        XCTAssertEqual(assistant.issues.issues.first?.range.location, 6)
    }

    /// A background pane's edits must not rewrite the list the reader is
    /// looking at.
    func testTheAssistantIgnoresAnEditorItIsNoLongerAttachedTo() {
        let first = makeView("We was ready.")
        let second = makeView("They was too.")
        let assistant = DocumentAssistant(service: IntelligenceService())

        assistant.attach(to: first)
        first.issues = ProofreadingIssues(issues: [
            issue(first, of: "We was", replacement: "We were")
        ])
        assistant.attach(to: second)
        XCTAssertTrue(assistant.issues.isEmpty, "attaching adopts the new editor's issues")

        first.setSelectedRange(NSRange(location: 0, length: 0))
        first.insertText("x", replacementRange: first.selectedRange())
        XCTAssertTrue(assistant.issues.isEmpty, "the detached editor must not report in")
    }
}
