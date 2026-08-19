//
//  HarnessEvent.swift
//  MarkDevKit
//
//  One line of MANVI's NDJSON stream, as MarkDev reads it.
//

import Foundation

/// What a MANVI event says happened.
///
/// The harness's own vocabulary, not a translation of it: these are the values
/// of `kind` on the wire. Cases MarkDev has no use for are still listed, so an
/// event is either something this app understands or something it can say it
/// does not — an `unknown` that swallows three named kinds is how a panel comes
/// to report a refused tool call as ordinary output.
public enum HarnessEventKind: String, Sendable, Equatable {
    case sessionStart = "session.start"
    case turnStart = "turn.start"
    case text = "assistant.text"
    case reasoning = "assistant.reasoning"
    case toolStart = "tool.start"
    case toolResult = "tool.result"
    case approvalRequest = "approval.request"
    case approvalDecided = "approval.decided"
    case policy = "policy.decision"
    case lease = "lease.change"
    case usage = "turn.usage"
    case turnEnd = "turn.end"
    case report = "run.report"
    case error = "error"
    case notice = "notice"
}

/// One line of `manvi run --json`.
///
/// Decoded leniently on purpose. The harness and this app are versioned and
/// shipped separately, and MANVI's own protocol note makes the same promise in
/// the other direction: unknown fields are ignored rather than refused. A new
/// field on an event must not turn a working run into a parse failure halfway
/// through, so every field here is optional and an unrecognised `kind` leaves
/// ``kind`` `nil` rather than throwing.
public struct HarnessEvent: Sendable, Equatable {
    public var rawKind: String
    public var kind: HarnessEventKind?
    public var text: String
    public var detail: String
    public var tool: String
    public var isError: Bool
    public var rule: String
    public var severity: String
    public var path: String
    public var model: String
    public var posture: String
    public var inputTokens: Int
    public var outputTokens: Int

    public init(
        rawKind: String,
        text: String = "",
        detail: String = "",
        tool: String = "",
        isError: Bool = false,
        rule: String = "",
        severity: String = "",
        path: String = "",
        model: String = "",
        posture: String = "",
        inputTokens: Int = 0,
        outputTokens: Int = 0
    ) {
        self.rawKind = rawKind
        self.kind = HarnessEventKind(rawValue: rawKind)
        self.text = text
        self.detail = detail
        self.tool = tool
        self.isError = isError
        self.rule = rule
        self.severity = severity
        self.path = path
        self.model = model
        self.posture = posture
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    /// Reads one NDJSON line, or `nil` if it is not one.
    ///
    /// A line that is not JSON is *not* an error worth failing a run over: the
    /// harness writes its notes to stderr, but a Go runtime warning, a shell
    /// profile's stray `echo`, or a `dyld` note can still land on stdout ahead
    /// of the stream. Dropping those and reading the rest is the difference
    /// between a run that works on this machine and one that works everywhere.
    public static func decode(line: String) -> HarnessEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { return nil }
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawKind = object["kind"] as? String
        else { return nil }

        return HarnessEvent(
            rawKind: rawKind,
            text: string(object["text"]),
            detail: string(object["detail"]),
            tool: string(object["tool"]),
            isError: object["is_error"] as? Bool ?? false,
            rule: string(object["rule"]),
            severity: string(object["severity"]),
            path: string(object["path"]),
            model: string(object["model"]),
            posture: string(object["posture"]),
            inputTokens: integer(object["input_tokens"]),
            outputTokens: integer(object["output_tokens"]))
    }

    private static func string(_ value: Any?) -> String { value as? String ?? "" }
    private static func integer(_ value: Any?) -> Int {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        return 0
    }
}

/// How a run ended.
///
/// MANVI's exit statuses are not a success/failure pair and must not be folded
/// into one: `manvi run` exits 0 when the turn finished on its own, 1 when it
/// failed, **2 when the step ceiling ended it** — work that is not complete —
/// and 3 when the output cap cut the final answer off mid-sentence. A caller
/// that cannot tell those apart shows a half-finished rewrite as a finished
/// one, which is the whole reason the harness separates them.
public enum HarnessOutcome: Sendable, Equatable {
    /// The turn finished on its own.
    case finished
    /// The run failed. The string is what the harness said on stderr.
    case failed(String)
    /// The step ceiling ended the turn; the work is not complete.
    case stepsExhausted
    /// The output cap cut the answer off mid-sentence.
    case outputCapped
    /// The reader stopped it.
    case cancelled
    /// MarkDev's own backstop fired — the harness outlived even its own
    /// `--timeout`, which means it is wedged rather than slow.
    case timedOut

    public init(exitStatus: Int32, notes: String) {
        switch exitStatus {
        case 0: self = .finished
        case 2: self = .stepsExhausted
        case 3: self = .outputCapped
        default:
            self = .failed(HarnessOutcome.headline(from: notes))
        }
    }

    /// Whether the answer can be taken as complete.
    public var isComplete: Bool { self == .finished }

    /// One line for the panel. Never "done" for anything but ``finished``.
    public var summary: String {
        switch self {
        case .finished: "Finished."
        case .failed(let detail):
            detail.isEmpty ? "The run failed." : detail
        case .stepsExhausted:
            "Stopped at the step ceiling — this answer is unfinished. Raise the step limit or "
                + "narrow the request."
        case .outputCapped:
            "The answer was cut off at the model's output limit. Raise "
                + "llm.local.max_output_tokens, or ask for less."
        case .cancelled: "Stopped."
        case .timedOut: "MANVI didn’t answer in time and was ended."
        }
    }

    /// The most useful line of the harness's own notes.
    ///
    /// Its diagnostics are written to stderr as `manvi: …` lines and the last
    /// one is the one that says why — the earlier ones are the session id and
    /// progress. Falling back to the whole text rather than to nothing: an
    /// unrecognised failure is still better read than summarised away.
    static func headline(from notes: String) -> String {
        let lines =
            notes
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let last = lines.last(where: { $0.hasPrefix("manvi: ") }) ?? lines.last else {
            return ""
        }
        return String(last.hasPrefix("manvi: ") ? last.dropFirst("manvi: ".count) : last[...])
    }
}
