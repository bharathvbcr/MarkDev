//
//  HarnessAssistant.swift
//  MarkDevKit
//
//  The Assist panel's MANVI half: one run, and what it produced.
//

import AppKit
import Foundation
import Observation

/// One line of what a run did.
///
/// The panel shows these instead of the raw stream, and that is the whole
/// point. A turn against a local model emits hundreds of events — every word
/// of the answer arrives as its own `assistant.text` — and rendering them is a
/// wall of text nobody reads. What a reader needs to know is which files were
/// touched, what was refused, and what came back; each of those is one row.
public struct HarnessActivity: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A tool the harness ran. `detail` is its most useful argument.
        case tool(name: String, detail: String)
        /// The gate refused something. Never folded into ``tool``: a refused
        /// write and a completed one must not look the same in a list, or the
        /// panel reports work that did not happen.
        case refused(rule: String, target: String)
        /// Something the harness said about the run itself.
        case note(String)
        /// An error the harness reported mid-run.
        case failure(String)
    }

    public let id: Int
    public let kind: Kind
    /// Whether the tool this row describes has come back yet.
    public var isFinished: Bool
    /// Whether it came back as an error.
    public var isError: Bool

    public init(id: Int, kind: Kind, isFinished: Bool = false, isError: Bool = false) {
        self.id = id
        self.kind = kind
        self.isFinished = isFinished
        self.isError = isError
    }

    public var title: String {
        switch kind {
        case .tool(let name, _): HarnessActivity.readable(tool: name)
        case .refused(_, let target): "Refused: \(target)"
        case .note(let text): text
        case .failure(let text): text
        }
    }

    public var detail: String {
        switch kind {
        case .tool(_, let detail): detail
        case .refused(let rule, _): rule
        case .note, .failure: ""
        }
    }

    public var symbol: String {
        switch kind {
        case .tool: isError ? "exclamationmark.triangle" : "wrench.and.screwdriver"
        case .refused: "hand.raised"
        case .note: "info.circle"
        case .failure: "exclamationmark.triangle"
        }
    }

    /// The harness's tool names with their namespace taken off.
    ///
    /// `devcouncil_read_file` is what the wire says and is not what a reader of
    /// a notes app needs to see. The prefix is stripped and the underscores
    /// opened out; anything that does not match is shown as it came, because a
    /// tool this code has never heard of is still better named by the harness
    /// than by a guess here.
    static func readable(tool name: String) -> String {
        let bare =
            name.hasPrefix("devcouncil_")
            ? String(name.dropFirst("devcouncil_".count)) : name
        guard !bare.isEmpty else { return name }
        let words = bare.split(separator: "_").map(String.init)
        guard let first = words.first else { return bare }
        return ([first.capitalized] + words.dropFirst()).joined(separator: " ")
    }
}

/// Runs MANVI against the open note and holds what came back.
///
/// # What this is for, next to Apple Intelligence
///
/// They are not two spellings of one feature. The on-device model gets four
/// thousand characters and no tools — it is for the paragraph in front of you.
/// MANVI drives whatever model this machine is serving, with a real agent loop
/// and read access to the whole vault, so the questions it can answer are the
/// ones the other cannot be asked: *reconcile this note with the rest of the
/// vault*, *finish these TODOs from what I have already written*.
///
/// The cost is time. A turn is minutes, not seconds, so everything here is
/// built for a run the reader watches rather than waits blindly on: activity
/// arrives as it happens, the answer streams, and stopping is always available.
@MainActor
@Observable
public final class HarnessAssistant {
    /// How the run is going.
    public enum State: Equatable {
        case idle
        case running(HarnessTask)
        /// Finished, with the outcome that finished it. Never a bare "done":
        /// MANVI distinguishes a turn that completed from one the step ceiling
        /// ended, and folding them together presents unfinished work as
        /// finished.
        case finished(HarnessTask, HarnessOutcome, truncatedNote: Bool)
        case failed(String)
    }

    /// Whether the harness could be found.
    public enum Availability: Equatable {
        case unknown
        case searching
        case found(HarnessLocation)
        case missing(String)

        public var isReady: Bool {
            if case .found = self { return true }
            return false
        }
    }

    public let settings: HarnessSettings

    public private(set) var availability: Availability = .unknown
    public private(set) var state: State = .idle
    /// The answer so far, deltas already joined.
    public private(set) var answer = ""
    /// What the run has done, newest last.
    public private(set) var activity: [HarnessActivity] = []
    /// The model the harness reported for this run, once it has said.
    public private(set) var model = ""
    public private(set) var inputTokens = 0
    public private(set) var outputTokens = 0
    /// Set when MarkDev stopped recording the stream. See ``HarnessRun``.
    public private(set) var transcriptTruncated = false

    /// What the reader typed, for a custom task.
    public var instruction = ""

    /// The editor the panel is pointed at. Weak for the reason
    /// ``DocumentAssistant``'s is: the panel outlives any one pane.
    @ObservationIgnored public private(set) weak var surface: MarkdownTextView?
    /// The note's own file, when it has one.
    @ObservationIgnored public var documentURL: URL?
    /// The vault, so the harness can read the notes around this one.
    @ObservationIgnored public var vaultURL: URL?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var nextActivityID = 0
    /// Which availability search is the newest; see ``refreshAvailability()``.
    @ObservationIgnored private var searchSerial = 0
    /// Tool rows still waiting for a result, oldest first.
    ///
    /// A result is matched to the *newest* of them rather than by name, because
    /// the wire does not carry a call id on `tool.result` — only `tool.start`
    /// names the tool. The harness runs one tool at a time within a step, so
    /// newest-first is right; if it ever stops doing that, this is the thing
    /// that has to change, and the symptom will be a row that never stops
    /// spinning.
    @ObservationIgnored private var openToolRows: [Int] = []

    public init(settings: HarnessSettings = HarnessSettings()) {
        self.settings = settings
    }

    public func attach(to surface: MarkdownTextView) {
        self.surface = surface
    }

    public var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    /// The task whose answer is on screen, if any.
    public var finishedTask: HarnessTask? {
        if case .finished(let task, _, _) = state { return task }
        return nil
    }

    // MARK: - Finding the harness

    /// Looks for the binary, reporting what it found.
    ///
    /// Worth calling when the panel appears: a reader who has just installed
    /// MANVI, or corrected the path, should not have to relaunch MarkDev to be
    /// believed.
    public func refreshAvailability() {
        // Two overlapping searches must not race last-writer-wins: a stale
        // `.found` answering after a fresh `.missing` (or the reverse) would
        // make the panel claim whatever finished last rather than whatever
        // was asked for most recently. Each search carries its number, and
        // only the newest may speak.
        searchSerial += 1
        let serial = searchSerial

        availability = .searching
        let configured = settings.binaryPath
        Task { [weak self] in
            let found = await HarnessLocator.locate(configured: configured)
            guard let self else { return }
            guard serial == self.searchSerial else { return }
            if let found {
                self.availability = .found(found)
            } else if !configured.trimmingCharacters(in: .whitespaces).isEmpty {
                self.availability = .missing(
                    "There is no executable at \(configured). Correct the path, or clear it to "
                        + "let MarkDev search.")
            } else {
                self.availability = .missing(
                    "MarkDev couldn’t find `manvi` on your PATH or in the usual install "
                        + "directories. Set its path below.")
            }
        }
    }

    // MARK: - Running

    /// Runs `task` against the open note.
    public func run(_ task: HarnessTask) {
        guard let surface else {
            state = .failed("There is no document open.")
            return
        }
        guard case .found(let location) = availability else {
            state = .failed("MANVI isn’t available. Check its path below.")
            refreshAvailability()
            return
        }

        let note = surface.markdown
        guard !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state = .failed("This document is empty.")
            return
        }

        // The directory the harness runs in. The note's own folder first, so
        // reading a sibling note is a relative path; the vault second, for an
        // unsaved document that has no folder of its own.
        let directory =
            documentURL?.deletingLastPathComponent() ?? vaultURL
            ?? URL(fileURLWithPath: NSHomeDirectory())

        let (prompt, noteTruncated) = HarnessPrompt.prompt(
            for: task,
            note: note,
            documentPath: documentURL?.lastPathComponent,
            vaultPath: vaultURL?.path)

        let request = HarnessRunRequest(
            binary: location.url,
            prompt: prompt,
            workingDirectory: directory,
            maxSteps: HarnessSettings.clampSteps(settings.maxSteps),
            timeout: .seconds(HarnessSettings.clampMinutes(settings.timeoutMinutes) * 60),
            environment: settings.environment())

        reset()
        state = .running(task)

        self.task?.cancel()
        self.task = Task { [weak self] in
            let result = await HarnessRun.run(request) { event in
                self?.absorb(event)
            }
            guard let self, !Task.isCancelled else { return }
            self.answer = HarnessAnswer.clean(result.answer)
            self.transcriptTruncated = result.truncated
            switch result.outcome {
            case .cancelled:
                self.state = .idle
            case .failed(let detail) where self.answer.isEmpty:
                self.state = .failed(detail.isEmpty ? "The run failed." : detail)
            default:
                self.state = .finished(task, result.outcome, truncatedNote: noteTruncated)
            }
        }
    }

    /// Runs whatever the reader typed.
    public func runCustom() {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        run(.custom(text))
    }

    public func stop() {
        task?.cancel()
        task = nil
        if isRunning { state = .idle }
    }

    private func reset() {
        answer = ""
        activity = []
        openToolRows = []
        model = ""
        inputTokens = 0
        outputTokens = 0
        transcriptTruncated = false
    }

    /// Folds one event into what the panel shows.
    ///
    /// Deliberately lossy, and every drop is a decision. Text deltas become the
    /// answer rather than rows; reasoning is dropped entirely, because it is
    /// the model talking to itself and showing it is exactly the verbosity this
    /// panel exists to avoid. A policy decision that *allowed* is dropped too —
    /// a list of everything that was permitted is noise — while one that
    /// refused is kept, because that is the run not doing what it was asked.
    func absorb(_ event: HarnessEvent) {
        switch event.kind {
        case .text:
            answer += event.text

        case .sessionStart:
            if !event.model.isEmpty { model = event.model }

        case .toolStart:
            let row = HarnessActivity(
                id: nextID(),
                kind: .tool(name: event.tool, detail: HarnessAssistant.detail(for: event)))
            activity.append(row)
            openToolRows.append(row.id)

        case .toolResult:
            finishNewestTool(isError: event.isError)

        case .policy:
            guard event.isRefusal else { return }
            activity.append(
                HarnessActivity(
                    id: nextID(),
                    kind: .refused(
                        rule: event.rule.isEmpty ? "refused by the gate" : event.rule,
                        target: HarnessActivity.readable(tool: event.tool)),
                    isFinished: true,
                    isError: true))

        case .error:
            activity.append(
                HarnessActivity(
                    id: nextID(), kind: .failure(event.text), isFinished: true, isError: true))

        case .report, .notice:
            guard !event.text.isEmpty else { return }
            activity.append(
                HarnessActivity(id: nextID(), kind: .note(event.text), isFinished: true))

        case .usage:
            inputTokens += event.inputTokens
            outputTokens += event.outputTokens

        case .reasoning, .turnStart, .turnEnd, .approvalRequest, .approvalDecided, .lease, .none:
            return
        }
    }

    private func finishNewestTool(isError: Bool) {
        guard let id = openToolRows.popLast(),
            let index = activity.firstIndex(where: { $0.id == id })
        else { return }
        activity[index].isFinished = true
        activity[index].isError = isError
    }

    private func nextID() -> Int {
        nextActivityID += 1
        return nextActivityID
    }

    /// The one argument worth showing beside a tool's name.
    ///
    /// A path when there is one, because that is what a reader wants to know a
    /// tool touched. Everything else is left off rather than summarised: the
    /// arguments are not carried on this side of the wire, and inventing a
    /// description from the tool name would be a caption that can be wrong.
    static func detail(for event: HarnessEvent) -> String {
        if !event.path.isEmpty { return event.path }
        return event.detail
    }

    // MARK: - Applying

    /// Deliberately **not** gated on `outcome.isComplete`: a run stopped by
    /// the step ceiling or the output cap still produced real text, and
    /// taking a partial rewrite is often exactly what the reader wants. The
    /// truncation is shown as a warning beside the button rather than hidden
    /// behind a disabled one — unfinished work offered honestly, per this
    /// codebase's standing rule that a cap must be *reported*, not enforced.
    public var canApply: Bool {
        guard let task = finishedTask, let surface, surface.acceptsAssistedEdits else {
            return false
        }
        return task.output == .rewrite && !answer.isEmpty
    }

    public var canInsert: Bool {
        guard let task = finishedTask, let surface, surface.acceptsAssistedEdits else {
            return false
        }
        return task.output != .answer && !answer.isEmpty
    }

    /// Replaces the whole note with the answer, as one undoable action.
    ///
    /// The whole note, because that is what the task was given — a rewrite
    /// asked of the document is an answer about the document, and applying it
    /// to anything narrower would put it in the wrong place. Undoable through
    /// the editor's own path, so ⌘Z takes it back like any other edit.
    @discardableResult
    public func apply() -> Bool {
        guard canApply, let surface else { return false }
        let length = (surface.markdown as NSString).length
        return surface.applyAssistedEdit(
            range: NSRange(location: 0, length: length),
            replacement: answer.hasSuffix("\n") ? answer : answer + "\n",
            actionName: "Apply MANVI Result")
    }

    /// Puts the answer in at the caret.
    @discardableResult
    public func insertAtCaret() -> Bool {
        guard canInsert, let surface else { return false }
        let caret = surface.selectedRange()
        return surface.applyAssistedEdit(
            range: caret,
            replacement: answer,
            actionName: "Insert MANVI Result")
    }

    public func copyAnswer() {
        guard !answer.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(answer, forType: .string)
    }
}

extension HarnessEvent {
    /// Whether this policy decision stopped something.
    ///
    /// Read off the harness's own JSON body rather than guessed from the rule
    /// name: the event carries the decision as text, and `"action":"deny"` is
    /// what it says when a call was stopped. A rule firing is not the same as a
    /// call being refused — the gate reports the rule on a qualified *pass*
    /// too, which is the distinction the harness is at pains to keep.
    var isRefusal: Bool {
        text.contains("\"action\":\"deny\"") || text.contains("\"allowed\":false")
    }
}

/// Tidies an answer before it is shown or applied.
public enum HarnessAnswer {
    /// Strips an enclosing ``` fence and surrounding whitespace, and nothing
    /// else.
    ///
    /// The same conservatism ``WritingResponse`` settled on, and for the same
    /// reason: a heuristic that also stripped a suspected "Here is your text:"
    /// preamble cannot tell one from a first line that happens to end in a
    /// colon, and deleting a real line of the author's note is far worse than
    /// leaving a stray sentence they can see and remove.
    public static func clean(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }

        let lines = trimmed.components(separatedBy: "\n")
        guard lines.count >= 2,
            lines[lines.count - 1].trimmingCharacters(in: .whitespaces) == "```"
        else { return trimmed }
        let inner = lines.dropFirst().dropLast()
        guard !inner.contains(where: { $0.hasPrefix("```") }) else { return trimmed }
        return inner.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
