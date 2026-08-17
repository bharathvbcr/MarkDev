//
//  WritingAssistant.swift
//  MarkDevKit
//
//  The inline writing panel: what it is working on, and what it produced.
//

import AppKit
import Foundation
import SwiftUI

/// Drives the panel that appears next to the selection.
///
/// # Why this owns an `NSPopover` rather than being a SwiftUI overlay
///
/// The panel has to sit beside a run of text inside a scroll view, stay there
/// while the reader types into it, and get out of the way when they click
/// elsewhere. `NSPopover` already does all three, including flipping to the
/// other side of the line near the bottom of the screen. Rebuilding that in
/// SwiftUI means reimplementing anchor geometry against a text container that
/// scrolls — and getting it subtly wrong at the window edge, which is exactly
/// where a panel that covers the text it is rewriting is most annoying.
///
/// The *contents* are SwiftUI. This is the seam, in the same place
/// ``MarkdownEditorView`` puts it.
@MainActor
@Observable
public final class WritingAssistant: NSObject, NSPopoverDelegate {
    /// Where the panel is in its cycle.
    public enum Phase: Equatable {
        /// Waiting for a task to be chosen.
        case ready
        /// Nothing can be run, and why — no selection, code, model off.
        case blocked(String)
        case running
        case finished
        case failed(String)
    }

    public private(set) var phase: Phase = .ready
    /// The task that produced, or is producing, ``output``.
    ///
    /// Held beside the phase rather than inside it because the panel needs it
    /// after the run ends: whether the result is offered as a replacement or
    /// only as an insertion is a property of the task, not of the phase.
    public private(set) var activeTask: WritingTask?
    /// The rewrite so far. Grows while a task runs.
    public private(set) var output = ""
    /// The text the panel is working on, for the "replacing…" line.
    public private(set) var sourceText = ""
    /// A typed instruction, bound by the panel's field.
    public var customInstruction = ""

    public let service: IntelligenceService

    @ObservationIgnored public weak var surface: MarkdownTextView?
    @ObservationIgnored private var sourceRange = NSRange(location: 0, length: 0)
    @ObservationIgnored private let request = IntelligenceRequest()
    @ObservationIgnored private var popover: NSPopover?

    public init(service: IntelligenceService) {
        self.service = service
    }

    /// Whether a rewrite is on screen and the editor will take it.
    public var canApply: Bool {
        guard case .finished = phase else { return false }
        return !output.isEmpty && (surface?.acceptsAssistedEdits ?? false)
    }

    public var isRunning: Bool { phase == .running }

    /// Whether the result stands alone rather than replacing the passage.
    public var resultIsDerived: Bool { activeTask?.output == .derived }

    // MARK: - Presentation

    /// Opens the panel for the editor's current selection.
    ///
    /// Opens even when there is nothing to work on. A keyboard shortcut that
    /// silently does nothing is indistinguishable from one that is broken, so
    /// the reason — no selection, a code block, Apple Intelligence switched
    /// off — is shown in the panel where the action was expected.
    public func open() {
        guard let surface else { return }
        service.refreshAvailability()
        service.prewarm()

        output = ""
        customInstruction = ""
        activeTask = nil

        let text = surface.markdown as NSString
        let scope = AssistScope.resolve(
            selection: surface.selectedRange(), in: surface.parsed, text: text)

        if !service.state.isReady {
            phase = .blocked(service.state.guidance)
            sourceRange = NSRange(location: surface.selectedRange().location, length: 0)
            sourceText = ""
        } else if let range = scope.range {
            sourceRange = range
            sourceText = text.substring(with: range)
            phase = .ready
        } else {
            sourceRange = NSRange(location: surface.selectedRange().location, length: 0)
            sourceText = ""
            phase = .blocked(scope.explanation)
        }

        present()
    }

    private func present() {
        // `show(relativeTo:of:preferredEdge:)` raises an `NSInvalidArgument`
        // exception — not an error, an exception — when the anchor view is not
        // in a window, which takes the whole app down. A surface can be
        // windowless legitimately: the reference outlives a closed pane, and
        // the editor exists briefly before SwiftUI installs it.
        guard let surface, surface.window != nil else { return }

        let popover = self.popover ?? NSPopover()
        if self.popover == nil {
            popover.behavior = .transient
            popover.delegate = self
            let host = NSHostingController(rootView: WritingAssistPanel(assistant: self))
            // Lets the panel grow as the rewrite streams in instead of
            // clipping the answer to whatever height it opened at.
            host.sizingOptions = [.preferredContentSize]
            popover.contentViewController = host
            self.popover = popover
        }

        guard !popover.isShown else { return }
        popover.show(
            relativeTo: surface.anchorRect(for: sourceRange),
            of: surface,
            preferredEdge: .maxY)
    }

    /// Closes the panel and abandons anything in flight.
    public func close() {
        request.cancel()
        popover?.performClose(nil)
    }

    public func popoverDidClose(_ notification: Notification) {
        // Reached by Escape and by clicking away as well as by ``close()``,
        // so the cancellation has to live here rather than only there.
        request.cancel()
        phase = .ready
        output = ""
        activeTask = nil
    }

    // MARK: - Running

    /// Runs `task` against the captured passage.
    public func run(_ task: WritingTask) {
        // A blocked panel has no passage to work on. The buttons are disabled
        // in that state; this is the belt to that pair of braces.
        if case .blocked = phase { return }
        start(task)
    }

    /// Runs the instruction the reader typed.
    public func runCustomInstruction() {
        let instruction = customInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }
        start(.custom(instruction))
    }

    private func start(_ task: WritingTask) {
        guard !sourceText.isEmpty else {
            phase = .blocked(AssistScope.empty.explanation)
            return
        }

        output = ""
        activeTask = task
        phase = .running

        let text = sourceText
        request.start { [weak self] in
            guard let self else { return }
            do {
                let final = try await self.service.rewrite(task: task, text: text) { partial in
                    self.output = partial
                }
                try Task.checkCancellation()
                self.output = final
                self.phase = final.isEmpty
                    ? .failed("Apple Intelligence returned nothing for that.")
                    : .finished
            } catch is CancellationError {
                self.phase = self.request.didTimeOut
                    ? .failed(IntelligenceFailure.timedOut.localizedDescription)
                    : .ready
            } catch {
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Stops a running task, leaving whatever arrived on screen.
    ///
    /// A part-finished rewrite is still offered: a `Concise` pass that was
    /// stopped two sentences in is often exactly what was wanted, and throwing
    /// it away would make the stop button feel like a punishment.
    public func stop() {
        request.cancel()
        phase = output.isEmpty ? .ready : .finished
    }

    // MARK: - Applying

    /// Replaces the passage with the rewrite.
    public func replaceSource() {
        guard canApply, let surface else { return }
        guard let range = verifiedSourceRange(in: surface) else { return }
        surface.applyAssistedEdit(
            range: range, replacement: output, actionName: "Rewrite with Apple Intelligence")
        close()
    }

    /// Adds the result as a new paragraph after the passage.
    ///
    /// The only offer for a ``WritingTask/Output/derived`` task. Replacing a
    /// section with its own summary destroys the section, and nobody presses
    /// Summarize meaning to do that.
    public func insertBelow() {
        guard canApply, let surface else { return }
        guard let range = verifiedSourceRange(in: surface) else { return }
        let insertion = NSRange(location: range.location + range.length, length: 0)
        surface.applyAssistedEdit(
            range: insertion,
            replacement: "\n\n" + output,
            actionName: "Insert Apple Intelligence Result")
        close()
    }

    public func copyOutput() {
        guard !output.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output, forType: .string)
    }

    /// The captured range, but only if it still holds the captured text.
    ///
    /// The panel is transient, so the document normally cannot change beneath
    /// it — but "normally" is not a guarantee, and the failure it protects
    /// against is overwriting the wrong paragraph. Checked rather than
    /// assumed, and refused loudly when it does not hold.
    private func verifiedSourceRange(in surface: MarkdownTextView) -> NSRange? {
        let text = surface.markdown as NSString
        guard sourceRange.location >= 0,
            sourceRange.location + sourceRange.length <= text.length,
            text.substring(with: sourceRange) == sourceText
        else {
            phase = .failed("The document changed while that was running, so it wasn’t applied.")
            return nil
        }
        return sourceRange
    }
}
