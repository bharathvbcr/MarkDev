//
//  HarnessLocator.swift
//  MarkDevKit
//
//  Finding the `manvi` binary from inside a GUI app.
//

import CryptoKit
import Darwin
import Foundation

/// A stable description of the executable bytes a reader authorized.
///
/// The persisted value is the digest only. Paths and filesystem identifiers
/// stay in memory, where they can reject a stale discovery immediately before
/// launch without becoming another copy of a private path in preferences.
public struct HarnessExecutableIdentity: Sendable, Equatable {
    public let fingerprint: String

    fileprivate let resolvedPath: String
    fileprivate let device: UInt64
    fileprivate let inode: UInt64
    fileprivate let byteCount: Int64
    fileprivate let changedSeconds: Int64
    fileprivate let changedNanoseconds: Int64
}

/// Where MANVI is, and how that was decided.
public struct HarnessLocation: Sendable, Equatable {
    public let url: URL
    /// How it was found, for the settings panel to say.
    public let origin: Origin
    /// The exact executable found at ``url``. Never rendered or logged.
    public let identity: HarnessExecutableIdentity

    fileprivate let selection: Selection

    public enum Origin: String, Sendable, Equatable {
        /// A path the reader set.
        case configured
        /// Found on the `PATH` this process inherited.
        case processPath
        /// Found in one of the directories tools are conventionally installed
        /// in.
        case conventional
        /// Found by asking a login shell, which is the only way to see a
        /// `PATH` set by a version manager.
        case loginShell
    }

    fileprivate enum Selection: Sendable, Equatable {
        case configured(String)
        case automatic

        var consentTag: String {
            switch self {
            case .configured: "configured"
            case .automatic: "automatic"
            }
        }
    }

    public var summary: String {
        switch origin {
        case .configured: "Set in MarkDev"
        case .processPath: "Found on PATH"
        case .conventional: "Found in \(url.deletingLastPathComponent().path)"
        case .loginShell: "Found by your login shell"
        }
    }

    /// A path-free value suitable for binding editing consent.
    var editingConsentFingerprint: String {
        HarnessLocator.stableFingerprint([
            "markdev.harness.editing-consent.v1",
            selection.consentTag,
            identity.fingerprint,
        ])
    }

    func matches(configured value: String?) -> Bool {
        switch (selection, HarnessLocator.selection(for: value)) {
        case (.automatic, .automatic): true
        case (.configured(let lhs), .configured(let rhs)): lhs == rhs
        default: false
        }
    }
}

/// A lock-protected, fixed-memory reader for a login shell's stdout pipe.
///
/// The descriptor is nonblocking and polled in a detached task. Retention stops
/// at the cap, but reads continue so a verbose profile cannot fill the pipe and
/// deadlock before it exits. Once the direct child exits, a short monotonic
/// drain deadline prevents a background descendant that inherited stdout from
/// keeping discovery alive forever.
private final class HarnessShellOutputReader: @unchecked Sendable {
    struct Result: Sendable {
        let data: Data
        let overflowed: Bool
        let reachedEOF: Bool
        let failed: Bool
    }

    private let descriptor: Int32
    private let byteLimit: Int
    private let lock = NSLock()
    private var finishDeadline: UInt64?

    init?(duplicating descriptor: Int32, byteLimit: Int) {
        guard byteLimit > 0 else { return nil }
        let copy = Darwin.dup(descriptor)
        guard copy >= 0 else { return nil }
        let flags = Darwin.fcntl(copy, F_GETFL)
        guard flags >= 0, Darwin.fcntl(copy, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            Darwin.close(copy)
            return nil
        }
        self.descriptor = copy
        self.byteLimit = byteLimit
    }

    func finish(after seconds: TimeInterval) {
        let bounded = max(0, min(seconds, 1))
        let nanos = UInt64(bounded * 1_000_000_000)
        let now = DispatchTime.now().uptimeNanoseconds
        let (deadline, overflow) = now.addingReportingOverflow(nanos)
        lock.lock()
        finishDeadline = overflow ? UInt64.max : deadline
        lock.unlock()
    }

    func read() -> Result {
        defer { Darwin.close(descriptor) }
        var retained = Data()
        retained.reserveCapacity(min(byteLimit, 64 * 1_024))
        var totalBytes = 0
        var overflowed = false
        var reachedEOF = false
        var failed = false
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)

        while true {
            if shouldFinish { break }
            var item = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
            let result = Darwin.poll(&item, 1, 20)
            if result < 0 {
                if errno == EINTR { continue }
                failed = true
                break
            }
            if result == 0 { continue }

            while true {
                let count = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.read(descriptor, bytes.baseAddress, bytes.count)
                }
                if count > 0 {
                    let amount = Int(count)
                    let (sum, didOverflow) = totalBytes.addingReportingOverflow(amount)
                    totalBytes = didOverflow ? .max : sum
                    if totalBytes > byteLimit { overflowed = true }
                    let remaining = max(0, byteLimit - retained.count)
                    if remaining > 0 {
                        retained.append(contentsOf: buffer.prefix(min(remaining, amount)))
                    }
                    continue
                }
                if count == 0 {
                    reachedEOF = true
                    break
                }
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK { failed = true }
                break
            }
            if reachedEOF || failed { break }
        }

        return Result(
            data: retained,
            overflowed: overflowed,
            reachedEOF: reachedEOF,
            failed: failed)
    }

    private var shouldFinish: Bool {
        lock.lock()
        let deadline = finishDeadline
        lock.unlock()
        guard let deadline else { return false }
        return DispatchTime.now().uptimeNanoseconds >= deadline
    }
}

/// Foundation.Process owns and reaps one login-shell probe child.
@MainActor
private final class HarnessShellProcess {
    private let process = Process()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var hasExited = false
    private var escalation: Task<Void, Never>?
    private(set) var wasEndedByUs = false

    func start(executable: URL, arguments: [String], output: Pipe) throws {
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
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

    func endIfRunning(grace: TimeInterval) {
        guard !hasExited, process.isRunning else { return }
        wasEndedByUs = true
        process.terminate()
        let expectedPID = process.processIdentifier
        escalation?.cancel()
        escalation = Task { @MainActor [weak self] in
            let bounded = max(0, min(grace, 5))
            if bounded > 0 { try? await Task.sleep(for: .seconds(bounded)) }
            guard !Task.isCancelled, let self,
                !self.hasExited,
                self.process.isRunning,
                expectedPID > 0,
                self.process.processIdentifier == expectedPID
            else { return }
            Darwin.kill(expectedPID, SIGKILL)
        }
    }

    var exitedSuccessfully: Bool {
        hasExited && process.terminationReason == .exit && process.terminationStatus == 0
    }

    private func markExited() {
        guard !hasExited else { return }
        hasExited = true
        escalation?.cancel()
        escalation = nil
        let pending = waiters
        waiters.removeAll()
        for continuation in pending { continuation.resume() }
    }
}

/// Finds the harness binary.
///
/// A GUI app has a short PATH, so discovery checks an explicit selection, that
/// PATH, conventional install directories, and finally a bounded login shell.
/// Every candidate passes through the same regular-file, executable, identity
/// boundary before it can be returned.
public enum HarnessLocator {
    public static let binaryName = "manvi"
    static let maximumShellOutputBytes = 64 * 1_024
    static let maximumExecutableBytes: Int64 = 512 * 1_024 * 1_024
    private static let maximumSearchDirectories = 256
    private static let maximumPathBytes = 4 * 1_024
    private static let shellOutputDrainGrace: TimeInterval = 0.1

    static func conventionalDirectories(home: String = NSHomeDirectory()) -> [String] {
        [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/go/bin",
            "\(home)/.local/bin",
            "\(home)/bin",
        ]
    }

    public static func locateSynchronously(
        configured: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> HarnessLocation? {
        let selected = selection(for: configured)
        if case .configured(let path) = selected {
            return location(
                at: path, origin: .configured, selection: selected, fileManager: fileManager)
        }

        let directories = (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .prefix(maximumSearchDirectories)
        for rawDirectory in directories {
            if Task.isCancelled { return nil }
            let directory = String(rawDirectory)
            guard directory.hasPrefix("/"), directory.utf8.count <= maximumPathBytes else { continue }
            let path = (directory as NSString).appendingPathComponent(binaryName)
            if let found = location(
                at: path, origin: .processPath, selection: selected, fileManager: fileManager)
            {
                return found
            }
        }

        for directory in conventionalDirectories() {
            if Task.isCancelled { return nil }
            let path = (directory as NSString).appendingPathComponent(binaryName)
            if let found = location(
                at: path, origin: .conventional, selection: selected, fileManager: fileManager)
            {
                return found
            }
        }
        return nil
    }

    public static func locate(
        configured: String?,
        timeout: TimeInterval = 5
    ) async -> HarnessLocation? {
        guard !Task.isCancelled else { return nil }
        let discovery = Task.detached(priority: .utility) {
            locateSynchronously(configured: configured)
        }
        let found = await withTaskCancellationHandler {
            await discovery.value
        } onCancel: {
            discovery.cancel()
        }
        guard !Task.isCancelled else { return nil }
        if let found { return found }

        let selected = selection(for: configured)
        if case .configured = selected { return nil }
        guard !Task.isCancelled else { return nil }
        let shell = TerminalSession.resolveShell()
        guard
            let path = await probeLoginShell(
                executable: URL(fileURLWithPath: shell),
                arguments: ["-l", "-c", "command -v \(binaryName)"],
                timeout: timeout,
                terminationGrace: 0.25,
                maximumOutputBytes: maximumShellOutputBytes)
        else { return nil }
        let identity = Task.detached(priority: .utility) {
            location(at: path, origin: .loginShell, selection: selected, fileManager: .default)
        }
        let foundIdentity = await withTaskCancellationHandler {
            await identity.value
        } onCancel: {
            identity.cancel()
        }
        return Task.isCancelled ? nil : foundIdentity
    }

    /// Whether a cached location still resolves to the same executable file.
    /// Content was hashed at discovery; the cheap launch-time check compares
    /// the kernel identity and nanosecond change time, which changes for an
    /// in-place rewrite as well as a replacement.
    static func isCurrent(_ location: HarnessLocation) -> Bool {
        guard let status = executableStatus(at: location.url.path) else { return false }
        let identity = location.identity
        return status.resolvedPath == identity.resolvedPath
            && status.device == identity.device
            && status.inode == identity.inode
            && status.byteCount == identity.byteCount
            && status.changedSeconds == identity.changedSeconds
            && status.changedNanoseconds == identity.changedNanoseconds
    }

    /// Executes one bounded shell probe. Internal so hostile process fixtures
    /// test the production path without making process controls public API.
    static func probeLoginShell(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval,
        terminationGrace: TimeInterval,
        maximumOutputBytes: Int
    ) async -> String? {
        guard timeout.isFinite, timeout > 0,
            terminationGrace.isFinite, terminationGrace >= 0,
            maximumOutputBytes > 0,
            maximumOutputBytes <= maximumShellOutputBytes,
            !Task.isCancelled
        else { return nil }

        let output = Pipe()
        guard
            let reader = HarnessShellOutputReader(
                duplicating: output.fileHandleForReading.fileDescriptor,
                byteLimit: maximumOutputBytes)
        else { return nil }
        let readerTask = Task.detached(priority: .utility) { reader.read() }
        let child = await HarnessShellProcess()

        do {
            try await child.start(executable: executable, arguments: arguments, output: output)
        } catch {
            try? output.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            reader.finish(after: 0)
            _ = await readerTask.value
            return nil
        }
        // The child owns a duplicated write descriptor after spawn. Closing the
        // parent's copies is required for EOF to mean the child actually ended.
        try? output.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()

        let timeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            child.endIfRunning(grace: terminationGrace)
        }
        await withTaskCancellationHandler {
            await child.waitForExit()
        } onCancel: {
            Task { @MainActor in child.endIfRunning(grace: terminationGrace) }
        }
        timeoutTask.cancel()
        reader.finish(after: shellOutputDrainGrace)
        let outputResult = await readerTask.value
        let wasEndedByUs = await child.wasEndedByUs
        let exitedSuccessfully = await child.exitedSuccessfully

        guard !Task.isCancelled,
            !wasEndedByUs,
            exitedSuccessfully,
            outputResult.reachedEOF,
            !outputResult.failed,
            !outputResult.overflowed,
            let text = String(data: outputResult.data, encoding: .utf8)
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let last = trimmed.split(separator: "\n").last.map(String.init),
            last.hasPrefix("/"),
            last.utf8.count <= maximumPathBytes,
            !last.contains("\0")
        else { return nil }
        return last.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    fileprivate static func selection(for configured: String?) -> HarnessLocation.Selection {
        let value = configured?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else { return .automatic }
        let expanded = (value as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        return .configured(url.path)
    }

    static func stableFingerprint(_ fields: [String]) -> String {
        var hasher = SHA256()
        for field in fields {
            hasher.update(data: Data(field.utf8))
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private struct ExecutableStatus: Equatable {
        let resolvedPath: String
        let device: UInt64
        let inode: UInt64
        let byteCount: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64
    }

    private static func location(
        at path: String,
        origin: HarnessLocation.Origin,
        selection: HarnessLocation.Selection,
        fileManager: FileManager
    ) -> HarnessLocation? {
        guard path.hasPrefix("/"), path.utf8.count <= maximumPathBytes,
            fileManager.isExecutableFile(atPath: path),
            let identity = executableIdentity(at: path)
        else { return nil }
        return HarnessLocation(
            url: URL(fileURLWithPath: identity.resolvedPath),
            origin: origin,
            identity: identity,
            selection: selection)
    }

    private static func executableIdentity(at path: String) -> HarnessExecutableIdentity? {
        guard let before = executableStatus(at: path),
            before.byteCount >= 0,
            before.byteCount <= maximumExecutableBytes,
            !Task.isCancelled
        else { return nil }
        let descriptor = Darwin.open(
            before.resolvedPath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        var opened = stat()
        guard Darwin.fstat(descriptor, &opened) == 0,
            status(from: opened, resolvedPath: before.resolvedPath) == before
        else { return nil }

        var contentHasher = SHA256()
        var bytesRead: Int64 = 0
        do {
            while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
                guard !Task.isCancelled else { return nil }
                let (sum, overflow) = bytesRead.addingReportingOverflow(Int64(chunk.count))
                guard !overflow, sum <= maximumExecutableBytes else { return nil }
                bytesRead = sum
                contentHasher.update(data: chunk)
            }
        } catch {
            return nil
        }
        guard bytesRead == before.byteCount else { return nil }
        var afterRaw = stat()
        guard Darwin.fstat(descriptor, &afterRaw) == 0,
            let after = status(from: afterRaw, resolvedPath: before.resolvedPath),
            after == before
        else { return nil }

        let contentDigest = contentHasher.finalize().map { String(format: "%02x", $0) }.joined()
        let fingerprint = stableFingerprint([
            "markdev.harness.executable.v1",
            before.resolvedPath,
            String(before.device),
            String(before.inode),
            String(before.byteCount),
            String(before.changedSeconds),
            String(before.changedNanoseconds),
            contentDigest,
        ])
        return HarnessExecutableIdentity(
            fingerprint: fingerprint,
            resolvedPath: before.resolvedPath,
            device: before.device,
            inode: before.inode,
            byteCount: before.byteCount,
            changedSeconds: before.changedSeconds,
            changedNanoseconds: before.changedNanoseconds)
    }

    private static func executableStatus(at path: String) -> ExecutableStatus? {
        guard let resolved = physicalPath(of: path) else { return nil }
        guard resolved.hasPrefix("/"), resolved.utf8.count <= maximumPathBytes,
            Darwin.access(resolved, X_OK) == 0
        else { return nil }
        var raw = stat()
        guard Darwin.lstat(resolved, &raw) == 0 else { return nil }
        return status(from: raw, resolvedPath: resolved)
    }

    private static func physicalPath(of path: String) -> String? {
        guard path.hasPrefix("/"), path.utf8.count <= maximumPathBytes else { return nil }
        return path.withCString { representation in
            guard let resolved = Darwin.realpath(representation, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }

    private static func status(from raw: stat, resolvedPath: String) -> ExecutableStatus? {
        guard (raw.st_mode & S_IFMT) == S_IFREG else { return nil }
        return ExecutableStatus(
            resolvedPath: resolvedPath,
            device: UInt64(raw.st_dev),
            inode: UInt64(raw.st_ino),
            byteCount: Int64(raw.st_size),
            changedSeconds: Int64(raw.st_ctimespec.tv_sec),
            changedNanoseconds: Int64(raw.st_ctimespec.tv_nsec))
    }
}
