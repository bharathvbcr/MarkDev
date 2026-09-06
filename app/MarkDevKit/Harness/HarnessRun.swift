//
//  HarnessRun.swift
//  MarkDevKit
//
//  Driving one `manvi run --json` turn from inside the app.
//

import Darwin
import Dispatch
import Foundation

/// One turn to ask the harness for.
public struct HarnessRunRequest: Sendable {
    public var binary: URL
    public var prompt: String
    /// The directory the harness runs in, supplied as task context and as the
    /// base for relative paths. It is not a security boundary: authority is
    /// enforced by the separately configured harness posture and policy gate.
    public var workingDirectory: URL
    public var maxSteps: Int
    public var timeout: Duration
    public var environment: [String: String]
    /// The app's production path carries the executable authority discovered
    /// by `HarnessLocator`. The public URL initializer remains available for
    /// low-level embedders and process-contract tests that explicitly own
    /// their launch policy.
    var executableAuthority: HarnessLocation?

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
        executableAuthority = nil
    }

    init(
        trustedBinary location: HarnessLocation,
        prompt: String,
        workingDirectory: URL,
        maxSteps: Int,
        timeout: Duration,
        environment: [String: String]
    ) {
        binary = location.url
        self.prompt = prompt
        self.workingDirectory = workingDirectory
        self.maxSteps = maxSteps
        self.timeout = timeout
        self.environment = environment
        executableAuthority = location
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

/// Single-use writer for the run's stdin pipe.
///
/// `FileHandle` is not `Sendable`, and this is the honest way past that: the
/// handle has exactly one writer, which writes once and closes, and never
/// touches anything else. The wrapper exists to say so in types rather than
/// in a comment nobody can enforce.
struct StdinWriter: @unchecked Sendable {
    let handle: FileHandle

    func write(_ data: Data) -> Bool {
        // A child is free to close stdin immediately. Without the descriptor-
        // local suppression, Darwin delivers SIGPIPE and kills the entire app
        // before FileHandle can surface EPIPE as an ordinary write failure.
        let descriptor = handle.fileDescriptor
        guard Darwin.fcntl(descriptor, F_SETNOSIGPIPE, 1) != -1 else {
            try? handle.close()
            return false
        }
        let flags = Darwin.fcntl(descriptor, F_GETFL)
        guard flags != -1,
            Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1
        else {
            try? handle.close()
            return false
        }
        defer { try? handle.close() }

        return data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return true }
            var offset = 0
            while offset < bytes.count {
                guard !Task.isCancelled else { return false }
                let written = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                guard written == -1 else { return false }
                if errno == EINTR { continue }
                guard errno == EAGAIN || errno == EWOULDBLOCK else { return false }

                // A finite poll interval is the cancellation boundary. A
                // descendant can escape our process group and retain stdin;
                // no inherited descriptor is allowed to turn task
                // cancellation into a permanently blocked write.
                var readiness = pollfd(
                    fd: descriptor,
                    events: Int16(POLLOUT),
                    revents: 0)
                let pollResult = Darwin.poll(&readiness, 1, 100)
                if pollResult > 0 {
                    let terminalEvents = Int16(POLLERR | POLLHUP | POLLNVAL)
                    guard readiness.revents & terminalEvents == 0 else { return false }
                } else if pollResult == -1, errno != EINTR {
                    return false
                }
            }
            return true
        }
    }
}

final class HarnessPipeLossState: @unchecked Sendable {
    private let lock = NSLock()
    private var droppedSinceLastCheck = false
    private var everDropped = false

    var hasDropped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return everDropped
    }

    func markDropped() {
        lock.lock()
        droppedSinceLastCheck = true
        everDropped = true
        lock.unlock()
    }

    func takeDropped() -> Bool {
        lock.lock()
        let result = droppedSinceLastCheck
        droppedSinceLastCheck = false
        lock.unlock()
        return result
    }
}

private final class HarnessPipeStreamController: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let chunkLimit: Int
    private let loss: HarnessPipeLossState
    private var continuation: AsyncStream<Data>.Continuation?
    private var finished = false

    init(handle: FileHandle, chunkLimit: Int, loss: HarnessPipeLossState) {
        self.handle = handle
        self.chunkLimit = chunkLimit
        self.loss = loss
    }

    func install(_ continuation: AsyncStream<Data>.Continuation) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            continuation.finish()
            return
        }
        self.continuation = continuation
        lock.unlock()

        handle.readabilityHandler = { [weak self] handle in
            self?.receive(from: handle)
        }
        continuation.onTermination = { [weak self] _ in self?.finish() }
    }

    func finish() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let retained = continuation
        continuation = nil
        lock.unlock()

        handle.readabilityHandler = nil
        try? handle.close()
        retained?.finish()
    }

    private func receive(from readable: FileHandle) {
        lock.lock()
        let shouldRead = !finished
        lock.unlock()
        guard shouldRead else { return }

        let data = readable.availableData
        guard !data.isEmpty else {
            finish()
            return
        }

        lock.lock()
        let retained = finished ? nil : continuation
        lock.unlock()
        guard let retained else { return }
        var start = data.startIndex
        while start < data.endIndex {
            let remaining = data.distance(from: start, to: data.endIndex)
            let end = data.index(start, offsetBy: min(chunkLimit, remaining))
            switch retained.yield(Data(data[start..<end])) {
            case .enqueued:
                break
            case .dropped:
                loss.markDropped()
            case .terminated:
                finish()
                return
            @unknown default:
                loss.markDropped()
            }
            start = end
        }
    }
}

struct HarnessPipeByteStream: Sendable {
    let chunks: AsyncStream<Data>
    let loss: HarnessPipeLossState
    private let controller: HarnessPipeStreamController

    fileprivate init(
        chunks: AsyncStream<Data>,
        loss: HarnessPipeLossState,
        controller: HarnessPipeStreamController
    ) {
        self.chunks = chunks
        self.loss = loss
        self.controller = controller
    }

    func finish() { controller.finish() }
}

private struct HarnessTranscriptCollection: Sendable {
    let events: [HarnessEvent]
    let answer: String
    let truncated: Bool
}

private struct HarnessNoteCollection: Sendable {
    let text: String
    let truncated: Bool
}

private enum HarnessProcessStartFailure: Error {
    case executableTrustRevoked
}

/// A child process and every descendant it starts, owned on the main actor.
///
/// Foundation's `Process` inherits MarkDev's process group, so signalling its
/// pid cannot stop grandchildren and signalling its group would stop MarkDev.
/// This owner uses `posix_spawn` with `POSIX_SPAWN_SETPGROUP`: the returned pid
/// is a fresh group id and remains reserved as an unreaped zombie until group
/// cleanup finishes. That reservation is what makes TERM/KILL escalation safe
/// from pid reuse.
@MainActor
final class HarnessProcess {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var processIdentifier: pid_t = 0
    private var exitSource: (any DispatchSourceProcess)?
    private var cleanupTask: Task<Void, Never>?
    private var abandonmentTask: Task<Void, Never>?
    private var leaderExitObserved = false
    private var groupKillIssued = false
    private var waitCompleted = false
    private var terminationStatusValue: Int32 = 0
    private var endedBySignalValue = false
    /// Set when MarkDev ended the process rather than the process ending.
    private(set) var wasEndedByUs = false

    /// A cooperative exit window before escalation to an unblockable signal.
    static let terminationGrace: Duration = .seconds(2)
    /// A normally exiting leader may still have orphan descendants holding our
    /// pipes. Give them a small graceful window, then close the whole group.
    static let orphanGrace: Duration = .milliseconds(250)
    /// Even an uninterruptible child cannot make the UI await process exit
    /// forever. The dispatch source retains this owner and reaps it later.
    static let forcedExitWait: Duration = .seconds(1)

    func start(_ request: HarnessRunRequest, input: Pipe, output: Pipe, errors: Pipe) throws {
        if let authority = request.executableAuthority,
            !HarnessLocator.isCurrent(authority)
        {
            throw HarnessProcessStartFailure.executableTrustRevoked
        }
        let arguments = [
            request.binary.path,
            "run",
            "--json",
            "--max-steps", String(request.maxSteps),
            "--timeout", HarnessRun.durationArgument(request.timeout),
        ]
        let environment = request.environment.keys.sorted().compactMap { key -> String? in
            guard !key.isEmpty, !key.contains("="), !key.contains("\0"),
                let value = request.environment[key], !value.contains("\0")
            else { return nil }
            return key + "=" + value
        }
        guard environment.count == request.environment.count,
            !arguments.contains(where: { $0.contains("\0") })
        else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
        }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try Self.require(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try Self.require(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }

        try Self.require(
            posix_spawn_file_actions_adddup2(
                &actions, input.fileHandleForReading.fileDescriptor, STDIN_FILENO))
        try Self.require(
            posix_spawn_file_actions_adddup2(
                &actions, output.fileHandleForWriting.fileDescriptor, STDOUT_FILENO))
        try Self.require(
            posix_spawn_file_actions_adddup2(
                &actions, errors.fileHandleForWriting.fileDescriptor, STDERR_FILENO))
        let chdirResult = request.workingDirectory.withUnsafeFileSystemRepresentation { path in
            guard let path else { return EINVAL }
            return posix_spawn_file_actions_addchdir(&actions, path)
        }
        try Self.require(chdirResult)
        try Self.require(posix_spawnattr_setpgroup(&attributes, 0))
        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        try Self.require(posix_spawnattr_setflags(&attributes, flags))

        // These are the child's pipe ends. The spawn actions duplicate them to
        // 0/1/2; keeping the parent's copies open would make EOF impossible.
        defer {
            try? input.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            try? errors.fileHandleForWriting.close()
        }

        var spawnedPID: pid_t = 0
        let result = try Self.withMutableCStringArray(arguments) { argv in
            try Self.withMutableCStringArray(environment) { envp in
                request.binary.withUnsafeFileSystemRepresentation { executable in
                    guard let executable else { return EINVAL }
                    return posix_spawn(
                        &spawnedPID,
                        executable,
                        &actions,
                        &attributes,
                        argv,
                        envp)
                }
            }
        }
        try Self.require(result)
        guard spawnedPID > 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ECHILD))
        }
        processIdentifier = spawnedPID

        // Keep the leader unreaped until every descendant has received bounded
        // TERM/KILL cleanup. The strong handler cycle is deliberate: if the UI
        // gives up after the forced-exit deadline, this source still owns the
        // eventual reap and breaks the cycle in `reapLeader`.
        let source = DispatchSource.makeProcessSource(
            identifier: spawnedPID,
            eventMask: .exit,
            queue: .main)
        source.setEventHandler { [self] in
            Task { @MainActor in leaderDidExit() }
        }
        exitSource = source
        source.resume()
    }

    func waitForExit() async {
        if waitCompleted { return }
        await withCheckedContinuation { continuation in
            if waitCompleted {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    /// Ends the run. Safe once the leader's exit was observed: no late signal
    /// can be misattributed to an already-finished run.
    func endIfRunning(grace: Duration = terminationGrace) {
        guard !waitCompleted, !leaderExitObserved, processIdentifier > 0 else { return }
        if leaderExitedWithoutReaping() {
            leaderDidExit()
            return
        }
        wasEndedByUs = true
        signalOwnedGroup(SIGTERM)
        scheduleGroupKill(after: grace)
    }

    var isRunning: Bool { !waitCompleted && !leaderExitObserved && processIdentifier > 0 }
    var status: Int32 { terminationStatusValue }
    var endedBySignal: Bool { endedBySignalValue }

    private func leaderDidExit() {
        guard !leaderExitObserved else { return }
        leaderExitObserved = true
        if groupKillIssued {
            reapLeader()
        } else if cleanupTask == nil {
            // A successful leader does not prove its descendants ended. TERM
            // the now-orphaned group while the zombie leader still reserves
            // its numeric identity, then escalate on a finite deadline.
            signalOwnedGroup(SIGTERM)
            scheduleGroupKill(after: Self.orphanGrace)
        }
    }

    private func scheduleGroupKill(after requestedGrace: Duration) {
        cleanupTask?.cancel()
        let grace = min(max(requestedGrace, .zero), .seconds(5))
        cleanupTask = Task { @MainActor [self] in
            if grace > .zero { try? await Task.sleep(for: grace) }
            guard !Task.isCancelled, processIdentifier > 0 else { return }
            groupKillIssued = true
            signalOwnedGroup(SIGKILL)
            if leaderExitObserved {
                reapLeader()
            } else {
                scheduleAbandonmentDeadline()
            }
        }
    }

    private func scheduleAbandonmentDeadline() {
        abandonmentTask?.cancel()
        abandonmentTask = Task { @MainActor [self] in
            try? await Task.sleep(for: Self.forcedExitWait)
            guard !Task.isCancelled, !waitCompleted else { return }
            // SIGKILL normally makes the dispatch source fire immediately. If
            // the kernel cannot finish the process, release the caller while
            // retaining the source so the eventual exit is still reaped.
            endedBySignalValue = true
            terminationStatusValue = SIGKILL
            finishWaiting()
        }
    }

    private func signalOwnedGroup(_ signal: Int32) {
        let pid = processIdentifier
        guard pid > 0 else { return }
        _ = Darwin.killpg(pid, signal)
    }

    /// Samples direct-child exit without consuming it. Keeping the zombie
    /// reserved preserves safe process-group signalling while preventing a
    /// deadline callback queued just behind an exit notification from
    /// relabelling an on-time completion as a timeout.
    private func leaderExitedWithoutReaping() -> Bool {
        let pid = processIdentifier
        guard pid > 0 else { return false }
        var information = siginfo_t()
        var result: Int32 = -1
        repeat {
            result = Darwin.waitid(
                P_PID,
                id_t(pid),
                &information,
                WEXITED | WNOHANG | WNOWAIT)
        } while result == -1 && errno == EINTR
        return result == 0 && information.si_pid != 0
    }

    private func reapLeader() {
        let pid = processIdentifier
        guard pid > 0 else { return }
        var rawStatus: Int32 = 0
        var result: pid_t = -1
        repeat {
            result = Darwin.waitpid(pid, &rawStatus, WNOHANG)
        } while result == -1 && errno == EINTR
        guard result == pid || (result == -1 && errno == ECHILD) else {
            scheduleAbandonmentDeadline()
            return
        }

        if result == pid {
            let signal = rawStatus & 0x7F
            endedBySignalValue = signal != 0 && signal != 0x7F
            terminationStatusValue = endedBySignalValue
                ? signal
                : (rawStatus >> 8) & 0xFF
        }
        processIdentifier = 0
        cleanupTask?.cancel()
        cleanupTask = nil
        abandonmentTask?.cancel()
        abandonmentTask = nil
        exitSource?.cancel()
        exitSource = nil
        finishWaiting()
    }

    private func finishWaiting() {
        guard !waitCompleted else { return }
        waitCompleted = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending { continuation.resume() }
    }

    private static func require(_ result: Int32) throws {
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(result))
        }
    }

    private static func withMutableCStringArray<Result>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
    ) throws -> Result {
        var pointers: [UnsafeMutablePointer<CChar>?] = []
        pointers.reserveCapacity(strings.count + 1)
        for string in strings {
            guard let pointer = strdup(string) else {
                for retained in pointers { free(retained) }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOMEM))
            }
            pointers.append(pointer)
        }
        pointers.append(nil)
        defer {
            for pointer in pointers.dropLast() { free(pointer) }
        }
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
            }
            return try body(base)
        }
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
    /// Public callers can construct requests without going through
    /// `HarnessPrompt`, so the process boundary enforces its own byte cap.
    public static let maximumInputBytes = 1 * 1_024 * 1_024
    /// The most stdout bytes kept. Beyond it the stream is still *read* — a
    /// pipe nobody drains blocks the child — but nothing more is recorded.
    public static let maximumTranscriptBytes = 4 * 1024 * 1024
    /// The unread stdout awaiting the consumer is bounded independently from
    /// the retained transcript, so a faster child cannot fill application
    /// memory while stdin delivery or event parsing is catching up.
    public static let maximumBufferedStdoutBytes = 512 * 1024
    /// The most events kept.
    public static let maximumEvents = 20_000
    /// The most stderr bytes kept. Diagnostics are a few lines; anything past
    /// this is a stuck loop printing.
    public static let maximumNoteBytes = 128 * 1024
    public static let maximumBufferedStderrBytes = 128 * 1024
    /// Time retained pipe bytes may continue draining after the owned process
    /// group is finished. A descendant that escaped the group and inherited a
    /// descriptor cannot hold a run open beyond this deadline.
    public static let pipeDrainGrace: Duration = .milliseconds(500)
    /// How far past the harness's own `--timeout` MarkDev waits before ending
    /// the process itself.
    public static let backstopGrace: Duration = .seconds(30)
    static let inputTooLargeMessage =
        "The harness input is larger than MarkDev’s 1 MiB safety limit."
    static let inputRejectedMessage =
        "The harness closed its input before accepting the prompt."

    /// Runs one turn, reporting events as they arrive.
    ///
    /// - Parameter onEvent: called on the main actor for every event, so a
    ///   panel can show tool calls and text as they happen rather than only at
    ///   the end. A run against a local model takes minutes; a spinner with
    ///   nothing behind it for that long is indistinguishable from a hang.
    @MainActor
    public static func run(
        _ request: HarnessRunRequest,
        diagnostics: DiagnosticsEmitter = .shared,
        backstopGrace: Duration = HarnessRun.backstopGrace,
        onEvent: @MainActor @escaping (HarnessEvent) -> Void
    ) async -> HarnessRunResult {
        let operationID = DiagnosticOperationID()
        let inputByteCount = request.prompt.utf8.count
        guard inputByteCount <= maximumInputBytes else {
            diagnostics.emit(
                severity: .error,
                subsystem: .harness,
                code: .harnessTerminalInputTooLarge,
                operationID: operationID,
                metadata: DiagnosticMetadata([
                    .byteCount: .integer(Int64(inputByteCount)),
                    .available: .boolean(false),
                ]))
            return HarnessRunResult(
                outcome: .failed(inputTooLargeMessage),
                answer: "", events: [], notes: "", truncated: false)
        }
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        let outputStream = Self.stream(
            from: output.fileHandleForReading,
            maximumBufferedBytes: maximumBufferedStdoutBytes)
        let noteStream = Self.stream(
            from: errors.fileHandleForReading,
            maximumBufferedBytes: maximumBufferedStderrBytes)

        let child = HarnessProcess()
        do {
            try child.start(request, input: input, output: output, errors: errors)
        } catch HarnessProcessStartFailure.executableTrustRevoked {
            diagnostics.emit(
                severity: .error,
                subsystem: .permissions,
                code: .permissionsHarnessExecutableRevoked,
                operationID: operationID,
                metadata: DiagnosticMetadata([.available: .boolean(false)]))
            return HarnessRunResult(
                outcome: .failed("The MANVI executable changed before the run could start."),
                answer: "", events: [], notes: "", truncated: false)
        } catch {
            diagnostics.emit(
                severity: .error,
                subsystem: .harness,
                code: .harnessTerminalFailed,
                operationID: operationID,
                metadata: DiagnosticMetadata([.available: .boolean(false)]))
            return HarnessRunResult(
                outcome: .failed(
                    "Couldn’t start \(request.binary.path): \(error.localizedDescription)"),
                answer: "", events: [], notes: "", truncated: false)
        }

        // Start stderr draining and the independent backstop before stdin.
        // A hostile child can fill stderr without reading stdin, or never read
        // stdin at all; neither case may leave this task waiting forever.
        let noteCollector = Task<HarnessNoteCollection, Never> { @MainActor in
            var text = ""
            var bytes = 0
            var wasTruncated = false
            for await chunk in noteStream.chunks {
                if noteStream.loss.takeDropped() {
                    wasTruncated = true
                    text.removeAll(keepingCapacity: false)
                }
                bytes = saturatingByteCount(bytes, adding: chunk.count)
                guard bytes <= maximumNoteBytes else {
                    wasTruncated = true
                    continue
                }
                text += String(decoding: chunk, as: UTF8.self)
            }
            if noteStream.loss.takeDropped() { wasTruncated = true }
            return HarnessNoteCollection(text: text, truncated: wasTruncated)
        }
        let backstop = Task { @MainActor in
            try? await Task.sleep(for: request.timeout + backstopGrace)
            guard !Task.isCancelled else { return }
            child.endIfRunning()
        }

        let transcriptCollector = Task<HarnessTranscriptCollection, Never> { @MainActor in
            var events: [HarnessEvent] = []
            var answer = ""
            var pending = Data()
            var transcriptBytes = 0
            var truncated = false

            for await chunk in outputStream.chunks {
                if outputStream.loss.takeDropped() {
                    truncated = true
                    pending.removeAll(keepingCapacity: false)
                }
                absorbTranscriptChunk(
                    chunk,
                    pending: &pending,
                    transcriptBytes: &transcriptBytes,
                    events: &events,
                    answer: &answer,
                    truncated: &truncated,
                    onEvent: onEvent)
            }
            if outputStream.loss.takeDropped() {
                truncated = true
                pending.removeAll(keepingCapacity: false)
            }
            absorbFinalTranscriptRecord(
                pending: &pending,
                events: &events,
                answer: &answer,
                truncated: &truncated,
                onEvent: onEvent)
            return HarnessTranscriptCollection(
                events: events,
                answer: answer,
                truncated: truncated)
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
        let writerTask = Task.detached(priority: .userInitiated) {
            writer.write(payload)
        }
        let inputAndTranscript = await withTaskCancellationHandler {
            await child.waitForExit()
            writerTask.cancel()
            let inputWasAccepted = await writerTask.value

            let drainDeadline = Task { @MainActor in
                try? await Task.sleep(for: pipeDrainGrace)
                guard !Task.isCancelled else { return }
                outputStream.finish()
                noteStream.finish()
            }
            let transcript = await transcriptCollector.value
            let notes = await noteCollector.value
            drainDeadline.cancel()
            outputStream.finish()
            noteStream.finish()
            return (inputWasAccepted, transcript, notes)
        } onCancel: {
            writerTask.cancel()
            Task { @MainActor in child.endIfRunning() }
        }

        backstop.cancel()
        let inputWasAccepted = inputAndTranscript.0
        let events = inputAndTranscript.1.events
        let answer = inputAndTranscript.1.answer
        let notes = inputAndTranscript.2.text
        let truncated = inputAndTranscript.1.truncated || inputAndTranscript.2.truncated

        let outcome: HarnessOutcome
        if Task.isCancelled {
            outcome = .cancelled
        } else if child.wasEndedByUs {
            // The only signal MarkDev sends is the backstop's, and the
            // backstop only fires past the harness's own timeout. Reported as
            // the timeout it is rather than as a generic failure: one says
            // "the model is slow, give it longer", the other says nothing.
            // A child that cooperatively handles TERM and exits zero is still
            // a timeout, not a successful completed run. `endIfRunning`
            // separately samples an already-exited leader with WNOWAIT before
            // setting this intent, closing the stale-notification race.
            outcome = .timedOut
        } else if !inputWasAccepted {
            outcome = .failed(inputRejectedMessage)
        } else {
            outcome = HarnessOutcome(exitStatus: child.status, notes: notes)
        }

        let severity: DiagnosticSeverity
        let code: DiagnosticCode
        switch outcome {
        case .finished:
            severity = .info
            code = .harnessTerminalSucceeded
        case .cancelled:
            severity = .notice
            code = .harnessTerminalCancelled
        case .timedOut:
            severity = .error
            code = .harnessTerminalTimedOut
        case .failed where !inputWasAccepted:
            severity = .error
            code = .harnessTerminalInputRejected
        case .failed, .stepsExhausted, .outputCapped:
            severity = .error
            code = .harnessTerminalFailed
        }
        var metadata: [DiagnosticMetadataKey: DiagnosticMetadataValue] = [
            .exitStatus: .integer(Int64(child.status)),
            .truncated: .boolean(truncated),
            .available: .boolean(true),
        ]
        if child.endedBySignal {
            metadata[.signal] = .integer(Int64(child.status))
        }
        diagnostics.emit(
            severity: severity,
            subsystem: .harness,
            code: code,
            operationID: operationID,
            metadata: DiagnosticMetadata(metadata))

        return HarnessRunResult(
            outcome: outcome,
            answer: answer,
            events: events,
            notes: notes,
            truncated: truncated)
    }

    /// Incorporates one stdout read while enforcing both bounds at the point
    /// each event is appended. The outer stream continues draining after this
    /// marks the transcript truncated, so the child never blocks on a full
    /// pipe merely because MarkDev stopped retaining its output.
    @MainActor
    static func absorbTranscriptChunk(
        _ chunk: Data,
        pending: inout Data,
        transcriptBytes: inout Int,
        events: inout [HarnessEvent],
        answer: inout String,
        truncated: inout Bool,
        onEvent: @MainActor (HarnessEvent) -> Void
    ) {
        transcriptBytes = saturatingByteCount(transcriptBytes, adding: chunk.count)
        guard transcriptBytes <= maximumTranscriptBytes, events.count < maximumEvents else {
            truncated = true
            pending.removeAll(keepingCapacity: false)
            return
        }
        pending.append(chunk)

        // Split on newlines, keeping whatever follows the last one for the
        // next chunk — a JSON object is regularly delivered in two reads, and
        // a half-decoded line dropped here is a tool call the panel never sees.
        while let newline = pending.firstIndex(of: 0x0A) {
            guard events.count < maximumEvents else {
                truncated = true
                pending.removeAll(keepingCapacity: false)
                return
            }
            let line = pending[pending.startIndex..<newline]
            pending = pending[pending.index(after: newline)...]
            guard
                let event = HarnessEvent.decode(
                    line: String(decoding: line, as: UTF8.self))
            else { continue }
            // `assistant.text` arrives as deltas, not as the answer so far.
            if event.kind == .text { answer += event.text }
            events.append(event)
            onEvent(event)
        }
    }

    /// Decodes the last NDJSON record after EOF. A final newline is customary,
    /// not part of the protocol contract; discarding a valid unterminated
    /// record can lose the final answer or run report.
    @MainActor
    static func absorbFinalTranscriptRecord(
        pending: inout Data,
        events: inout [HarnessEvent],
        answer: inout String,
        truncated: inout Bool,
        onEvent: @MainActor (HarnessEvent) -> Void
    ) {
        guard !pending.isEmpty else { return }
        defer { pending.removeAll(keepingCapacity: false) }
        guard events.count < maximumEvents else {
            truncated = true
            return
        }
        guard
            let event = HarnessEvent.decode(
                line: String(decoding: pending, as: UTF8.self))
        else { return }
        if event.kind == .text { answer += event.text }
        events.append(event)
        onEvent(event)
    }

    nonisolated static func saturatingByteCount(_ current: Int, adding increment: Int) -> Int {
        guard current >= 0, increment >= 0 else { return .max }
        let (sum, overflow) = current.addingReportingOverflow(increment)
        return overflow ? .max : sum
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
    static func stream(
        from handle: FileHandle,
        maximumBufferedBytes requestedByteLimit: Int
    ) -> HarnessPipeByteStream {
        let byteLimit = min(max(1, requestedByteLimit), maximumTranscriptBytes)
        let chunkLimit = min(64 * 1024, byteLimit)
        let elementLimit = max(1, byteLimit / chunkLimit)
        let loss = HarnessPipeLossState()
        let controller = HarnessPipeStreamController(
            handle: handle,
            chunkLimit: chunkLimit,
            loss: loss)
        let chunks = AsyncStream<Data>(bufferingPolicy: .bufferingNewest(elementLimit)) {
            continuation in
            controller.install(continuation)
        }
        return HarnessPipeByteStream(
            chunks: chunks,
            loss: loss,
            controller: controller)
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
