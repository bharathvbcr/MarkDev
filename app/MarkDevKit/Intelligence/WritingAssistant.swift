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


    public enum ResultProvenance: Equatable, Sendable {
        case complete
        case stoppedPartial
    }

    public enum ApplicationRefusal: Equatable, Sendable {
        case sourceChanged(String)
        case editorRefused

        public var message: String {
            switch self {
            case .sourceChanged(let message): message
            case .editorRefused:
                "The editor refused that change. The generated result is still available to copy."
            }
        }
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
    public private(set) var resultProvenance: ResultProvenance?
    public private(set) var applicationRefusal: ApplicationRefusal?
    public private(set) var acceptedPartialResult = false
    /// The text the panel is working on, for the "replacing…" line.
    public private(set) var sourceText = ""
    /// A typed instruction, bound by the panel's field.
    public var customInstruction = ""

    public let service: IntelligenceService

    @ObservationIgnored public weak var surface: MarkdownTextView?
    @ObservationIgnored private var sourceRange = NSRange(location: 0, length: 0)
    @ObservationIgnored private var source: AssistedEditSource?
    @ObservationIgnored private let request = IntelligenceRequest()
    @ObservationIgnored private var popover: NSPopover?
    /// Exact authority for callbacks belonging to the active rewrite. A fresh
    /// UUID cannot wrap back onto a callback retained from an earlier run.
    @ObservationIgnored private var operationIdentity = UUID()

    public init(service: IntelligenceService) {
        self.service = service
    }

    /// Whether a rewrite is on screen and the editor will take it.
    public var canApply: Bool {
        guard case .finished = phase else { return false }
        guard resultProvenance != .stoppedPartial || acceptedPartialResult else { return false }
        return !output.isEmpty && source?.validate(attachedTo: surface) == .current
    }

    public var isRunning: Bool { phase == .running }

    /// Whether the result stands alone rather than replacing the passage.
    public var resultIsDerived: Bool { activeTask?.output == .derived }

    public var partialResultNeedsConfirmation: Bool {
        resultProvenance == .stoppedPartial && !acceptedPartialResult
    }

    public var visibleApplicationRefusal: String? {
        if let applicationRefusal { return applicationRefusal.message }
        guard case .finished = phase,
            let validation = source?.validate(attachedTo: surface), validation != .current
        else { return nil }
        return validation.message ?? "The source changed, so this result can’t be applied."
    }

    // MARK: - Presentation

    /// Opens the panel for the editor's current selection.
    ///
    /// Opens even when there is nothing to work on. A keyboard shortcut that
    /// silently does nothing is indistinguishable from one that is broken, so
    /// the reason — no selection, a code block, Apple Intelligence switched
    /// off — is shown in the panel where the action was expected.
    public func open() {
        guard let surface else { return }
        replaceOperationIdentity()
        request.cancel()
        service.refreshAvailability()
        service.prewarm()

        output = ""
        resultProvenance = nil
        applicationRefusal = nil
        acceptedPartialResult = false
        customInstruction = ""
        activeTask = nil
        source = nil

        let text = surface.markdown as NSString
        let scope = AssistScope.resolve(
            selection: surface.selectedRange(), in: surface.parsed, text: text)

        if !service.state.isReady {
            phase = .blocked(service.state.guidance)
            sourceRange = NSRange(location: surface.selectedRange().location, length: 0)
            sourceText = ""
        } else if let range = scope.range {
            if !captureSource(range, in: surface) {
                phase = .blocked("That passage can’t be used by the writing tools.")
            }
        } else {
            sourceRange = NSRange(location: surface.selectedRange().location, length: 0)
            sourceText = ""
            phase = .blocked(scope.explanation)
        }

        present()
    }

    /// Captures one already-resolved passage as the sole source a result may
    /// later replace.
    ///
    /// This is the state-transition seam shared by the popover and the editor
    /// contract tests. It validates before `substring(with:)`, so neither a
    /// malformed range nor a caller bypassing `AssistScope` can allocate or
    /// store an unbounded source snapshot.
    @discardableResult
    func captureSource(_ range: NSRange, in surface: MarkdownTextView) -> Bool {
        let text = surface.markdown as NSString
        guard range.length <= AssistScope.maximumLength,
            let end = CheckedTextRange.end(of: range), end <= text.length
        else { return false }
        self.surface = surface
        sourceRange = range
        sourceText = text.substring(with: range)
        source = AssistedEditSource(surface)
        phase = .ready
        return true
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
        replaceOperationIdentity()
        request.cancel()
        popover?.performClose(nil)
    }

    public func popoverDidClose(_ notification: Notification) {
        // Reached by Escape and by clicking away as well as by ``close()``,
        // so the cancellation has to live here rather than only there.
        replaceOperationIdentity()
        request.cancel()
        phase = .ready
        output = ""
        activeTask = nil
        source = nil
        resultProvenance = nil
        applicationRefusal = nil
        acceptedPartialResult = false
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
        guard let task = WritingTask.custom(customInstruction) else {
            replaceOperationIdentity()
            request.cancel()
            phase = .failed(IntelligenceFailure.invalidInstruction.localizedDescription)
            return
        }
        start(task)
    }

    private func start(_ task: WritingTask) {
        let operationIdentity = replaceOperationIdentity()
        request.cancel()
        guard !sourceText.isEmpty else {
            phase = .blocked(AssistScope.empty.explanation)
            return
        }
        guard source?.validate(attachedTo: surface, requiresEditing: false) == .current else {
            phase = .failed(
                source?.validate(attachedTo: surface, requiresEditing: false).message
                    ?? "The source document is no longer available.")
            return
        }
        guard !task.directive.isEmpty,
            BoundedText.fitsUTF8(
                task.directive, maximum: WritingTask.maximumCustomInstructionBytes)
        else {
            phase = .failed(IntelligenceFailure.invalidInstruction.localizedDescription)
            return
        }

        output = ""
        activeTask = task
        resultProvenance = nil
        applicationRefusal = nil
        acceptedPartialResult = false
        phase = .running

        let text = sourceText
        request.start { [weak self] in
            guard let self else { return }
            do {
                let final = try await self.service.rewrite(task: task, text: text) { partial in
                    guard self.operationIdentity == operationIdentity else { return }
                    self.output = partial
                }
                try Task.checkCancellation()
                guard self.operationIdentity == operationIdentity else { return }
                self.publishFinishedResult(final, for: task, provenance: .complete)
            } catch is CancellationError {
                guard self.operationIdentity == operationIdentity else { return }
                self.phase = self.request.didTimeOut
                    ? .failed(IntelligenceFailure.timedOut.localizedDescription)
                    : .ready
            } catch {
                guard self.operationIdentity == operationIdentity else { return }
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
        replaceOperationIdentity()
        request.cancel()
        guard !output.isEmpty, let activeTask else {
            resultProvenance = nil
            acceptedPartialResult = false
            phase = .ready
            return
        }
        publishFinishedResult(output, for: activeTask, provenance: .stoppedPartial)
    }

    /// Invalidates every callback holding the previous identity and returns
    /// the sole token a newly started operation may use to publish.
    @discardableResult
    private func replaceOperationIdentity() -> UUID {
        let identity = UUID()
        operationIdentity = identity
        return identity
    }

    /// Publishes a terminal model result only after the shared output boundary
    /// admits it. Both natural completion and Stop flow through here, so an
    /// incomplete stream cannot accidentally acquire complete provenance.
    @discardableResult
    func publishFinishedResult(
        _ result: String, for task: WritingTask, provenance: ResultProvenance
    ) -> Bool {
        guard let admitted = WritingResponse.admit(result) else {
            output = ""
            activeTask = task
            resultProvenance = nil
            acceptedPartialResult = false
            phase = .failed(IntelligenceFailure.invalidResponse.localizedDescription)
            return false
        }
        guard !admitted.isEmpty else {
            output = ""
            activeTask = task
            resultProvenance = nil
            acceptedPartialResult = false
            phase = .failed("Apple Intelligence returned nothing for that.")
            return false
        }
        output = admitted
        activeTask = task
        resultProvenance = provenance
        applicationRefusal = nil
        acceptedPartialResult = false
        phase = .finished
        return true
    }

    /// Acknowledges that a stopped stream is incomplete before destructive use.
    public func acceptPartialResult() {
        guard resultProvenance == .stoppedPartial, !output.isEmpty else { return }
        acceptedPartialResult = true
    }

    // MARK: - Applying

    /// Replaces the passage with the rewrite.
    public func replaceSource() {
        guard canApply, let surface else { return }
        guard let range = verifiedSourceRange(in: surface) else { return }
        guard surface.applyAssistedEdit(
            range: range, replacement: output, actionName: "Rewrite with Apple Intelligence")
        else {
            applicationRefusal = .editorRefused
            return
        }
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
        guard let end = CheckedTextRange.end(of: range) else {
            applicationRefusal = .sourceChanged("The source range is invalid, so it wasn’t changed.")
            return
        }
        let insertion = NSRange(location: end, length: 0)
        guard surface.applyAssistedEdit(
            range: insertion,
            replacement: "\n\n" + output,
            actionName: "Insert Apple Intelligence Result")
        else {
            applicationRefusal = .editorRefused
            return
        }
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
        let validation = source?.validate(attachedTo: surface) ?? .unavailable
        guard validation == .current else {
            applicationRefusal = .sourceChanged(
                validation.message ?? "That result can’t be applied.")
            return nil
        }
        let text = surface.markdown as NSString
        guard let end = CheckedTextRange.end(of: sourceRange), end <= text.length,
            text.substring(with: sourceRange) == sourceText
        else {
            applicationRefusal = .sourceChanged(
                "The document changed while that was running, so it wasn’t applied.")
            return nil
        }
        return sourceRange
    }
}
