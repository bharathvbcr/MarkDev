//
//  HarnessRun.swift
//  MarkDevKit
//
//  Driving one `manvi run --json` turn from inside the app.
//

import Foundation

/// One turn to ask the harness for.
public struct HarnessRunRequest: Sendable {
    public var binary: URL
    public var prompt: String
    /// The directory the harness runs in. Everything it can read is resolved
    /// from here, and under ``HarnessAuthority/editing`` everything it may
    /// write is bounded by it.
    public var workingDirectory: URL
    public var maxSteps: Int
    public var timeout: Duration
    public var environment: [String: String]

    public init(
        binary: URL,
        prompt: String,
        workingDirectory: URL,
        maxSteps: Int,
        timeout: Duration,
        environment: [String: String]
    ) {
        self.binary = binary
        self.prompt = prompt
        self.workingDirectory = workingDirectory
        self.maxSteps = maxSteps
        self.timeout = timeout
        self.environment = environment
    }
}

/// What a finished run produced.
public struct HarnessRunResult: Sendable {
    public var outcome: HarnessOutcome
    /// The model's visible answer, with the deltas joined back together.
    public var answer: String
    /// Everything the harness reported, in order.
    public var events: [HarnessEvent]
    /// The harness's own diagnostics, from stderr.
    public var notes: String
    /// Set when a bound stopped MarkDev recording the whole stream. Reported
    /// rather than swallowed: a truncated transcript presented as the full one
    /// is a record that cannot be trusted for the one case it exists to serve.
    public var truncated: Bool

    public init(
        outcome: HarnessOutcome,
        answer: String,
        events: [HarnessEvent],
        notes: String,
        truncated: Bool
    ) {
        self.outcome = outcome
        self.answer = answer
        self.events = events
        self.notes = notes
        self.truncated = truncated
    }
}

/// A child process, owned on the main actor.
///
/// `Process` is not `Sendable`, and the two things that have to be able to end
/// a run — task cancellation and the backstop timer — both arrive from
/// somewhere else. Wrapping it in a main-actor class is what makes it safe to
/// hand to them: a `@MainActor` class *is* `Sendable`, so they can hold this
/// and hop to the actor to act on it, rather than capturing a pid and
/// signalling a number that may by then belong to something else.
///
/// It also keeps the main actor unblocked. `waitUntilExit()` is a blocking
/// call, and waiting on a local 27B for ten minutes with it would freeze the
/// window; ``waitForExit()`` suspends on `terminationHandler` instead.
/// Single-use writer for the run's stdin pipe.
///
/// `FileHandle` is not `Sendable`, and this is the honest way past that: the
/// handle has exactly one writer, which writes once and closes, and never
/// touches anything else. The wrapper exists to say so in types rather than
/// in a comment nobody can enforce.
private struct StdinWriter: @unchecked Sendable {
    let handle: FileHandle

    func write(_ data: Data) {
        try? handle.write(contentsOf: data)
        try? handle.close()
    }
}

@MainActor
final class HarnessProcess {
    private let process = Process()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var hasExited = false
    /// Set when MarkDev ended the process rather than the process ending.
    private(set) var wasEndedByUs = false

    func start(_ request: HarnessRunRequest, input: Pipe, output: Pipe, errors: Pipe) throws {
        process.executableURL = request.binary
        process.arguments = [
            "run",
            "--json",
            "--max-steps", String(request.maxSteps),
            "--timeout", HarnessRun.durationArgument(request.timeout),
        ]
        process.currentDirectoryURL = request.workingDirectory
        process.environment = request.environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        process.terminationHandler = { _ in
            Task { @MainActor [weak self] in self?.markExited() }
        }
        try process.run()
    }

    func waitForExit() async {
        if hasExited { return }
        await withCheckedContinuation { continuation in
            if hasExited {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    /// Ends the run. Safe once the process has exited: nothing is signalled.
    func terminateIfRunning() {
        guard !hasExited, process.isRunning else { return }
        wasEndedByUs = true
        process.terminate()
    }

    var isRunning: Bool { !hasExited && process.isRunning }
    var status: Int32 { hasExited ? process.terminationStatus : 0 }
    var endedBySignal: Bool { hasExited && process.terminationReason == .uncaughtSignal }

    private func markExited() {
        guard !hasExited else { return }
        hasExited = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending { continuation.resume() }
    }
}

/// Runs the harness and reads its stream.
///
/// # Why a subprocess and not the stdio server
///
/// MANVI does expose a host plane — `manvi serve`, NDJSON over stdio — and it
/// is the right seam for a host that drives its own model requests. It is
/// explicitly *advisory*: its chat plane plans compaction and reads a finished
/// reply, and the host makes the HTTP call, dispatches the tools, and owns the
/// agent loop. Using it would mean MarkDev reimplementing the loop, the tool
/// surface, and the policy ladder that are the whole reason to want MANVI.
///
/// `manvi run` is that loop, already assembled, with the same gate and the same
/// session log the TUI uses — and `--json` is the event stream both faces
/// consume, so nothing here reads a second-class version of what the terminal
/// shows.
///
/// # What is bounded, and why each bound is here
///
/// The step ceiling and the wall clock are the harness's own and are passed to
/// it. MarkDev adds three more, because a bound the child enforces is no bound
/// at all once the child is the thing that is wedged: a backstop timer past the
/// harness's own, a cap on the bytes kept from stdout, and a cap on the events
/// kept. The last two are memory — an agent that loops over a large file emits
/// tool results without limit, and a panel that grows with them takes the
/// window down long before the run ends.
public enum HarnessRun {
    /// The most stdout bytes kept. Beyond it the stream is still *read* — a
    /// pipe nobody drains blocks the child — but nothing more is recorded.
    public static let maximumTranscriptBytes = 4 * 1024 * 1024
    /// The most events kept.
    public static let maximumEvents = 20_000
    /// The most stderr bytes kept. Diagnostics are a few lines; anything past
    /// this is a stuck loop printing.
    public static let maximumNoteBytes = 128 * 1024
    /// How far past the harness's own `--timeout` MarkDev waits before ending
    /// the process itself.
    public static let backstopGrace: Duration = .seconds(30)

    /// Runs one turn, reporting events as they arrive.
    ///
    /// - Parameter onEvent: called on the main actor for every event, so a
    ///   panel can show tool calls and text as they happen rather than only at
    ///   the end. A run against a local model takes minutes; a spinner with
    ///   nothing behind it for that long is indistinguishable from a hang.
    @MainActor
    public static func run(
        _ request: HarnessRunRequest,
        onEvent: @MainActor @escaping (HarnessEvent) -> Void
    ) async -> HarnessRunResult {
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        let chunks = Self.stream(from: output.fileHandleForReading)
        let noteChunks = Self.stream(from: errors.fileHandleForReading)

        let child = HarnessProcess()
        do {
            try child.start(request, input: input, output: output, errors: errors)
        } catch {
            return HarnessRunResult(
                outcome: .failed(
                    "Couldn’t start \(request.binary.path): \(error.localizedDescription)"),
                answer: "", events: [], notes: "", truncated: false)
        }

        // The prompt goes in on stdin rather than as an argument. A note is the
        // prompt here, and a long one would run into the argument-length limit
        // — and every quoting question disappears with it. The handle is closed
        // straight away: `manvi run` reads stdin to EOF when no `-p` is given,
        // so leaving it open is a run that never starts.
        // Written off the main actor: a prompt up to the cap is several
        // times a pipe buffer, so this write blocks until the child drains —
        // which a slow-starting binary turns into a beachball before the run
        // even begins. Awaiting keeps the ordering (stdin closed before the
        // read loop cares) without holding the actor hostage.
        let writer = StdinWriter(handle: input.fileHandleForWriting)
        let payload = Data(request.prompt.utf8)
        await Task.detached(priority: .userInitiated) {
            writer.write(payload)
        }.value

        // Drained on its own task so stderr is emptied while stdout is read.
        // Two pipes and one reader is a deadlock waiting for a verbose run: the
        // child blocks writing to the pipe nobody is emptying, and the panel
        // shows a run that has simply stopped.
        let noteCollector = Task<String, Never> {
            var text = ""
            var bytes = 0
            for await chunk in noteChunks {
                bytes += chunk.count
                guard bytes <= maximumNoteBytes else { continue }
                text += String(decoding: chunk, as: UTF8.self)
            }
            return text
        }

        let backstop = Task { @MainActor in
            try? await Task.sleep(for: request.timeout + backstopGrace)
            guard !Task.isCancelled else { return }
            child.terminateIfRunning()
        }

        var events: [HarnessEvent] = []
        var answer = ""
        var pending = Data()
        var transcriptBytes = 0
        var truncated = false

        await withTaskCancellationHandler {
            for await chunk in chunks {
                transcriptBytes += chunk.count
                if transcriptBytes > maximumTranscriptBytes || events.count >= maximumEvents {
                    truncated = true
                    continue
                }
                pending.append(chunk)
                // Split on newlines, keeping whatever follows the last one for
                // the next chunk — a JSON object is regularly delivered in two
                // reads, and a half-decoded line dropped here is a tool call
                // the panel never shows.
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = pending[pending.startIndex..<newline]
                    pending = pending[pending.index(after: newline)...]
                    guard
                        let event = HarnessEvent.decode(
                            line: String(decoding: line, as: UTF8.self))
                    else { continue }
                    // `assistant.text` arrives as deltas, not as the answer so
                    // far — measured against a real run, where "The note
                    // mentions apples" came back as seven events. Joined here
                    // so every consumer sees one answer.
                    if event.kind == .text { answer += event.text }
                    events.append(event)
                    onEvent(event)
                }
            }
        } onCancel: {
            Task { @MainActor in child.terminateIfRunning() }
        }

        backstop.cancel()
        await child.waitForExit()
        let notes = await noteCollector.value

        let outcome: HarnessOutcome
        if Task.isCancelled {
            outcome = .cancelled
        } else if child.wasEndedByUs && child.endedBySignal {
            // The only signal MarkDev sends is the backstop's, and the
            // backstop only fires past the harness's own timeout. Reported as
            // the timeout it is rather than as a generic failure: one says
            // "the model is slow, give it longer", the other says nothing.
            //
            // Both halves matter. Intent alone (`wasEndedByUs`) could be
            // stale — `markExited` reaches the main actor one hop behind the
            // child's real exit, and a backstop firing in that gap would
            // brand an on-time, complete run as timed out. Requiring the
            // signal to have actually landed ties the verdict to what
            // happened, not to what we asked for.
            outcome = .timedOut
        } else {
            outcome = HarnessOutcome(exitStatus: child.status, notes: notes)
        }

        return HarnessRunResult(
            outcome: outcome,
            answer: answer,
            events: events,
            notes: notes,
            truncated: truncated)
    }

    /// Bridges a pipe to an async sequence of chunks.
    ///
    /// `readabilityHandler` rather than `FileHandle.bytes`: the handler is
    /// called on a queue of the system's choosing and hands over whole reads,
    /// which is what makes draining two pipes at once cheap. The empty read is
    /// end of file, and it is the only thing that finishes the stream — a
    /// consumer that stopped at process exit instead would lose whatever the
    /// child wrote in its last moments, which for `manvi run` is the run
    /// report.
    static func stream(from handle: FileHandle) -> AsyncStream<Data> {
        AsyncStream { continuation in
            handle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    continuation.finish()
                } else {
                    continuation.yield(data)
                }
            }
            continuation.onTermination = { _ in
                handle.readabilityHandler = nil
            }
        }
    }

    /// A `Duration` in the spelling Go's `time.ParseDuration` accepts.
    ///
    /// Seconds, always. Writing minutes would read more tidily and is where
    /// this would go wrong: a sub-minute bound — which every test here uses —
    /// rounds to `0m`, and a zero timeout is refused by the harness.
    static func durationArgument(_ duration: Duration) -> String {
        let seconds = max(1, Int(duration.components.seconds))
        return "\(seconds)s"
    }
}
