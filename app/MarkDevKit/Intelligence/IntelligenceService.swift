//
//  IntelligenceService.swift
//  MarkDevKit
//
//  The only place MarkDev talks to the on-device model.
//

import FoundationModels
import Foundation

/// A model request that failed in a way worth saying out loud.
///
/// `GenerationError` is thorough and unreadable — its descriptions talk about
/// context windows and guardrails. This is the same information in the two or
/// three sentences a writer can act on, and it is a plain enum so the mapping
/// from framework error to sentence is a pure function with a test.
public enum IntelligenceFailure: Error, Equatable, LocalizedError {
    case unavailable(IntelligenceState)
    case tooMuchText
    case refused
    case unsupportedLanguage
    case busy
    case timedOut
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let state):
            state.guidance.isEmpty ? state.headline : state.guidance
        case .tooMuchText:
            "That’s more text than the on-device model can hold at once. Try a smaller selection."
        case .refused:
            "Apple Intelligence declined to work on this text."
        case .unsupportedLanguage:
            "Apple Intelligence doesn’t support this text’s language yet."
        case .busy:
            "Apple Intelligence is handling too many requests right now. Try again in a moment."
        case .timedOut:
            "Apple Intelligence didn’t answer in time."
        case .failed(let detail):
            detail
        }
    }
}

/// MarkDev's access to the on-device language model.
///
/// # Why a session per request
///
/// `LanguageModelSession` accumulates a transcript, and the transcript shares
/// the context window with the text being worked on. Reusing one session
/// across a writing session would mean the tenth rewrite has a fraction of the
/// room the first one had, failing with a context-window error that has
/// nothing to do with the paragraph in front of the user. Every request here
/// is independent, so every request gets its own session and the whole window.
///
/// # Why two models
///
/// Rewriting the author's own prose is a content transformation, and the
/// default guardrails are tuned for generated content rather than for text the
/// user already has: a note about a medical diagnosis or a crime novel draft
/// is refused outright. `permissiveContentTransformations` exists for exactly
/// this and is used for anything that transforms text the author supplied.
/// Tasks that ask the model to *write* something new keep the default
/// guardrails, because there the model is the author.
@MainActor
@Observable
public final class IntelligenceService {
    /// Whether the model can run, refreshed on demand.
    public private(set) var state: IntelligenceState

    /// How long any single request may take before it is abandoned.
    ///
    /// Generation is local, so this is not a network timeout — it is a
    /// backstop against a wedged request leaving a spinner on screen with no
    /// way back. Generous enough that a slow first run, which has to page the
    /// model in, is not cut off.
    public static let requestTimeout: Duration = .seconds(90)

    @ObservationIgnored private let transforming: SystemLanguageModel
    @ObservationIgnored private let authoring: SystemLanguageModel
    /// Held only to keep the model's assets resident after ``prewarm()``.
    @ObservationIgnored private var warmed: LanguageModelSession?

    public init() {
        transforming = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        authoring = SystemLanguageModel()
        state = IntelligenceAvailability.current()
    }

    /// Re-reads availability.
    ///
    /// Worth calling when a panel appears: the model finishes downloading, or
    /// the user turns Apple Intelligence on, without the app being relaunched.
    public func refreshAvailability() {
        state = IntelligenceAvailability.current()
    }

    /// Loads the model's assets so the first request is not also the first
    /// page-in. Cheap to call more than once.
    public func prewarm() {
        guard state.isReady, warmed == nil else { return }
        let session = LanguageModelSession(
            model: transforming, instructions: WritingPrompt.instructions)
        session.prewarm()
        warmed = session
    }

    // MARK: - Requests

    /// Rewrites `text` for `task`, reporting the answer as it arrives.
    ///
    /// `onPartial` receives the whole answer so far, not a delta — that is the
    /// shape the framework streams in, and re-deriving deltas only to
    /// reassemble them in the view would be work for its own sake.
    @discardableResult
    public func rewrite(
        task: WritingTask,
        text: String,
        onPartial: (String) -> Void = { _ in }
    ) async throws -> String {
        try requireReady()
        let session = LanguageModelSession(
            model: task.output == .derived ? authoring : transforming,
            instructions: WritingPrompt.instructions)

        var latest = ""
        do {
            let stream = session.streamResponse(
                to: WritingPrompt.prompt(for: task, text: text),
                options: Self.options(for: task, inputLength: text.count))
            for try await snapshot in stream {
                try Task.checkCancellation()
                latest = snapshot.content
                onPartial(WritingResponse.clean(latest))
            }
        } catch {
            throw Self.describe(error)
        }
        return WritingResponse.clean(latest)
    }

    /// Proofreads one passage.
    ///
    /// Structured output rather than prose: a list of findings the editor can
    /// locate and act on is a different thing from a paragraph describing
    /// them, and only the first can put an underline in the right place.
    public func proofread(_ text: String) async throws -> ProofreadingReport {
        try requireReady()
        let session = LanguageModelSession(
            model: transforming, instructions: ProofreadingPrompt.instructions)
        do {
            let response = try await session.respond(
                to: ProofreadingPrompt.prompt(for: text),
                generating: ProofreadingReport.self,
                options: GenerationOptions(temperature: 0.1))
            return response.content
        } catch {
            throw Self.describe(error)
        }
    }

    /// Reads a whole note and reports on it as fields.
    ///
    /// Structured output, and authored rather than transformed: the summary and
    /// the title are the model's own sentences about the note, so this keeps
    /// the default guardrails rather than the permissive ones — the permissive
    /// set exists for text the *author* wrote and this request produces none of
    /// the author's text back.
    ///
    /// Cold rather than creative. A title suggested twice for the same note
    /// coming back differently reads as the feature being unreliable, which is
    /// worse than it reading as unimaginative.
    public func brief(_ text: String) async throws -> NoteBrief {
        try requireReady()
        let session = LanguageModelSession(
            model: authoring, instructions: NoteBriefPrompt.instructions)
        do {
            let response = try await session.respond(
                to: NoteBriefPrompt.prompt(for: text),
                generating: NoteBrief.self,
                options: GenerationOptions(temperature: 0.2))
            return response.content.normalized
        } catch {
            throw Self.describe(error)
        }
    }

    private func requireReady() throws {
        // Re-read rather than trust the cached value: the model can finish
        // downloading between the panel opening and a button being pressed,
        // and reporting "still preparing" for a model that is now ready is a
        // worse failure than the extra check costs.
        refreshAvailability()
        guard state.isReady else { throw IntelligenceFailure.unavailable(state) }
    }

    // MARK: - Options

    /// Sampling and length bounds for `task`.
    ///
    /// Rewrites run cold — the same paragraph rewritten twice should not come
    /// back differently for no reason — while tasks that author new text get
    /// enough freedom to write a readable sentence.
    nonisolated static func options(for task: WritingTask, inputLength: Int) -> GenerationOptions {
        GenerationOptions(
            temperature: task.output == .derived ? 0.6 : 0.2,
            maximumResponseTokens: responseTokenBudget(for: task, inputLength: inputLength))
    }

    /// A ceiling on the answer's length.
    ///
    /// Unbounded generation on a rewrite is how a two-line note comes back as
    /// six paragraphs of the model talking to itself. The budget is derived
    /// from the input because a rewrite is about as long as its source, with
    /// enough headroom for `Expand` to be worth pressing.
    nonisolated static func responseTokenBudget(for task: WritingTask, inputLength: Int) -> Int {
        // Four characters to a token is the usual rough figure for English;
        // doubling it leaves room for a longer rewrite without inviting an
        // essay.
        let proportional = max(1, inputLength / 4) * 2
        return min(2_048, max(256, proportional))
    }

    // MARK: - Errors

    /// Turns anything thrown by a request into something worth showing.
    nonisolated static func describe(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let failure = error as? IntelligenceFailure { return failure }

        guard let generation = error as? LanguageModelSession.GenerationError else {
            return IntelligenceFailure.failed(error.localizedDescription)
        }
        switch generation {
        case .exceededContextWindowSize:
            return IntelligenceFailure.tooMuchText
        case .guardrailViolation, .refusal:
            return IntelligenceFailure.refused
        case .unsupportedLanguageOrLocale:
            return IntelligenceFailure.unsupportedLanguage
        case .rateLimited, .concurrentRequests:
            return IntelligenceFailure.busy
        case .assetsUnavailable:
            return IntelligenceFailure.unavailable(.modelNotReady)
        case .decodingFailure, .unsupportedGuide:
            // The model produced something that did not fit the schema. Not
            // actionable, but saying so beats an empty result that looks like
            // "your document is perfect".
            return IntelligenceFailure.failed(
                "Apple Intelligence returned a result MarkDev couldn’t read. Try again.")
        @unknown default:
            return IntelligenceFailure.failed(
                generation.errorDescription ?? "Apple Intelligence couldn’t complete that.")
        }
    }
}

/// A single in-flight model request, with a watchdog.
///
/// Every call site needs the same three things — hold the task so it can be
/// cancelled, replace it when a new request starts, and give up if it never
/// returns — and getting the third one wrong leaves a spinner that spins
/// forever. Keeping them together means no caller has to remember all three.
@MainActor
public final class IntelligenceRequest {
    // Mutated only from the main actor, but `deinit` runs wherever the last
    // reference is dropped and has to be able to cancel a run that outlived
    // its owner. `nonisolated(unsafe)` is what lets the teardown path reach
    // them; every other access in this file is on the main actor.
    private nonisolated(unsafe) var task: Task<Void, Never>?
    private nonisolated(unsafe) var watchdog: Task<Void, Never>?
    /// Identifies the current run, so a watchdog that wakes after its own run
    /// has been replaced does not cancel the new one.
    private var generation = 0

    /// Whether the last run was stopped by the watchdog rather than by the
    /// reader or by finishing on its own.
    public private(set) var didTimeOut = false

    public init() {}

    public var isRunning: Bool { task != nil }

    /// Starts `operation`, cancelling whatever was running before it.
    ///
    /// A timeout surfaces to `operation` as ordinary cancellation; the caller
    /// tells the two apart with ``didTimeOut``.
    public func start(
        timeout: Duration = IntelligenceService.requestTimeout,
        operation: @escaping @MainActor () async -> Void
    ) {
        cancel()
        didTimeOut = false
        generation += 1
        let id = generation

        task = Task { @MainActor [weak self] in
            await operation()
            guard let self, self.generation == id else { return }
            self.finish()
        }

        watchdog = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return  // Replaced or finished; nothing to police.
            }
            guard let self, self.generation == id, let running = self.task else { return }
            self.didTimeOut = true
            running.cancel()
            self.task = nil
            self.watchdog = nil
        }
    }

    /// Marks the current run finished, so the watchdog stops watching it.
    public func finish() {
        watchdog?.cancel()
        watchdog = nil
        task = nil
    }

    public func cancel() {
        watchdog?.cancel()
        watchdog = nil
        task?.cancel()
        task = nil
    }

    deinit {
        watchdog?.cancel()
        task?.cancel()
    }
}
