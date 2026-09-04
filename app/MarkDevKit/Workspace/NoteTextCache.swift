//
//  NoteTextCache.swift
//  MarkDevKit
//
//  Notes read ahead of being asked for, and the check that says they are
//  still what is on disk.
//

import Darwin
import Foundation

/// Memory ceilings for Markdown that crosses from the file system into a UI.
///
/// The editor can reasonably hold a larger working document than an instant
/// preview, but neither path may let an untrusted file allocate without a
/// bound. Keeping both values here makes every file-backed surface use the
/// same policy instead of accumulating subtly different magic numbers.
public enum MarkdownReadLimits {
    public static let maximumDocumentBytes = 16 * 1_024 * 1_024
    public static let maximumPreviewBytes = 4 * 1_024 * 1_024

    /// Returns the UTF-8 byte count only when the whole document is safe to
    /// hand to the editor and the Rust ABI.
    public static func acceptedDocumentByteCount(_ text: String) -> Int? {
        let count = text.utf8.count
        return count <= maximumDocumentBytes ? count : nil
    }
}

/// Recoverable failures from a bounded note read.
public enum NoteTextReadError: Error, Equatable, LocalizedError {
    case fileTooLarge(URL, maximumBytes: Int)
    case unsupportedFile(URL)
    case fileChangedDuringRead(URL)

    public var errorDescription: String? {
        switch self {
        case .fileTooLarge(let url, let maximumBytes):
            let readable = ByteCountFormatter.string(
                fromByteCount: Int64(maximumBytes), countStyle: .file)
            return "\(url.lastPathComponent) is too large to open safely. The limit is \(readable)."
        case .unsupportedFile(let url):
            return "\(url.lastPathComponent) is not a regular file and cannot be opened safely."
        case .fileChangedDuringRead(let url):
            return "\(url.lastPathComponent) changed while it was being read. Try again."
        }
    }
}

/// Bytes of notes that have been read recently, keyed by file.
///
/// # What this is for
///
/// Opening a note and peeking at one both read the file on the main actor.
/// For a local file that is a millisecond; on an iCloud Drive or a network
/// volume it is however long the volume takes, and the window is unresponsive
/// for all of it. The warmer reads the notes an open document links to *off*
/// the main actor, ahead of time, into here — so following a link becomes a
/// dictionary lookup rather than a synchronous read.
///
/// # Why it stores bytes and not text
///
/// The two readers decode differently, and deliberately: opening a document
/// accepts UTF-8 only, while a preview falls back to Latin-1 so a note from an
/// older tool is still readable. A cache of `String` would have to pick one,
/// and would then hand the other caller text it would have refused.
///
/// # Why freshness is checked rather than assumed
///
/// Nothing in MarkDev watches the file system, so a cached copy can be
/// arbitrarily old — a note edited in another app is not noticed. Serving that
/// to the *editor* would be worse than slow: the reader would edit stale text
/// and save it back over the newer file. So every hit is checked against the
/// file's current identity, size, modification time, and change time, and a
/// mismatch re-reads. Identity detects atomic replacement; change time detects
/// an in-place rewrite whose modification timestamp was deliberately restored.
public final class NoteTextCache: @unchecked Sendable {
    /// Shared because what it accelerates — opening and peeking — happens
    /// from several places against one set of files.
    public static let shared = NoteTextCache()

    /// Files larger than this are never cached.
    ///
    /// The default matches ``PeekLoader/maximumBytes``: above it a note is
    /// opened rather than previewed, and holding a copy of something that big
    /// on the chance it is opened is the wrong trade.
    public let maximumFileBytes: Int

    /// Ceiling on everything held here at once.
    public let maximumTotalBytes: Int

    private struct Entry {
        let data: Data
        let stamp: LocalFileStamp
    }

    struct ReadResult: Sendable {
        let data: Data
        let stamp: LocalFileStamp
    }

    /// Not an actor: the readers are a synchronous `@MainActor` open and a
    /// detached background read, and an actor would make the first of those
    /// asynchronous — which is the whole thing being avoided.
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    /// Insertion order, for eviction.
    private var order: [String] = []
    private var bytes = 0

    private var hitCount = 0
    private var missCount = 0

    public var hits: Int { withLock { hitCount } }
    public var misses: Int { withLock { missCount } }

    public struct Statistics: Equatable, Sendable {
        public let hits: Int
        public let misses: Int
        public let cachedBytes: Int
        public let entryCount: Int
    }

    /// One coherent observation for diagnostics that need to relate counters
    /// to the cache contents. Individual compatibility getters are locked too.
    public var statistics: Statistics {
        withLock {
            Statistics(
                hits: hitCount,
                misses: missCount,
                cachedBytes: bytes,
                entryCount: entries.count)
        }
    }

    /// - Parameters:
    ///   - maximumFileBytes: the largest file that will be held.
    ///   - maximumTotalBytes: the ceiling on everything held at once.
    ///
    /// Both are settable so a test can reach the bounds without writing
    /// sixteen megabytes to a temporary directory to do it.
    public init(
        maximumFileBytes: Int = 4 * 1024 * 1024,
        maximumTotalBytes: Int = 16 * 1024 * 1024
    ) {
        self.maximumFileBytes = max(0, maximumFileBytes)
        self.maximumTotalBytes = max(0, maximumTotalBytes)
    }

    // MARK: - Reading

    /// The file's bytes, from memory when it has not changed since they were
    /// taken, and from disk otherwise.
    public func read(_ url: URL, maximumBytes requestedMaximum: Int? = nil) throws -> Data {
        try readResult(url, maximumBytes: requestedMaximum).data
    }

    /// The bytes and the exact descriptor/path stamp that authorized them.
    /// Workspace uses this to bind an opened document's identity to the same
    /// read, rather than racing a second independent `stat` after the fact.
    func readResult(
        _ url: URL,
        maximumBytes requestedMaximum: Int? = nil
    ) throws -> ReadResult {
        // Canonicalised once, and everything below works from it. Keying on
        // the tidied path while stamping the one that arrived would make two
        // spellings of the same note two entries — and worse, would stat a
        // path the caller never has to be able to resolve.
        let file = Self.canonical(url)
        let key = file.path
        let maximumBytes = max(0, requestedMaximum ?? maximumFileBytes)

        // At most one retry. A racing replace may make the path metadata and
        // opened descriptor disagree; returning either version would let a
        // stale/torn read escape, while retrying forever lets an attacker pin
        // a caller by continually replacing the file.
        for attempt in 0..<2 {
            let current = LocalFileSystem.stamp(of: file)
            if (current?.size ?? 0) > maximumBytes {
                throw NoteTextReadError.fileTooLarge(file, maximumBytes: maximumBytes)
            }

            if let current,
                let cached: Data = withLock({
                    guard let entry = entries[key], entry.stamp == current else { return nil }
                    guard entry.data.count <= maximumBytes else { return nil }
                    hitCount += 1
                    return entry.data
                })
            {
                return ReadResult(data: cached, stamp: current)
            }
            if attempt == 0 { withLock { missCount += 1 } }

            let result = try Self.boundedRead(file, maximumBytes: maximumBytes)
            guard current == result.stamp,
                LocalFileSystem.stamp(of: file) == result.stamp
            else {
                if attempt == 0 { continue }
                throw NoteTextReadError.fileChangedDuringRead(file)
            }
            store(result.data, stamp: result.stamp, for: key)
            return ReadResult(data: result.data, stamp: result.stamp)
        }
        throw NoteTextReadError.fileChangedDuringRead(file)
    }

    /// UTF-8 text, with the same contract as `String(contentsOf:encoding:)`.
    public func utf8Text(at url: URL, maximumBytes: Int? = nil) throws -> String {
        try utf8TextResult(at: url, maximumBytes: maximumBytes).text
    }

    func utf8TextResult(
        at url: URL,
        maximumBytes: Int? = nil
    ) throws -> (text: String, stamp: LocalFileStamp) {
        let result = try readResult(url, maximumBytes: maximumBytes)
        guard let text = String(data: result.data, encoding: .utf8) else {
            throw CocoaError(
                .fileReadInapplicableStringEncoding,
                userInfo: [NSURLErrorKey: url])
        }
        return (text, result.stamp)
    }

    /// Reads `url` into the cache, reporting whether it landed there.
    ///
    /// The warmer's entry point: it wants the bytes cached and the text back,
    /// and it wants a failure — an unreadable file, a note deleted since it
    /// was indexed — to be nothing more than a warm that did not happen.
    @discardableResult
    public func warm(_ url: URL) -> Data? {
        guard let size = LocalFileSystem.stamp(of: Self.canonical(url))?.size,
            size <= maximumFileBytes
        else { return nil }
        return try? read(url, maximumBytes: maximumFileBytes)
    }

    /// The cached bytes for `url`, or `nil` when there are none or they are
    /// stale. Never reads the file's contents.
    public func cached(_ url: URL) -> Data? {
        let file = Self.canonical(url)
        guard let current = LocalFileSystem.stamp(of: file) else { return nil }
        guard let entry = withLock({ entries[file.path] }), entry.stamp == current else {
            return nil
        }
        return entry.data
    }

    public func clear() {
        withLock {
            entries.removeAll()
            order.removeAll()
            bytes = 0
            hitCount = 0
            missCount = 0
        }
    }

    /// What is held right now, in bytes.
    public var cachedBytes: Int {
        withLock { bytes }
    }

    // MARK: - Storage

    private func store(_ data: Data, stamp: LocalFileStamp, for key: String) {
        guard data.count <= maximumFileBytes, data.count <= maximumTotalBytes else { return }
        withLock {
            if let replaced = entries.removeValue(forKey: key) {
                bytes -= replaced.data.count
            } else {
                order.append(key)
            }
            entries[key] = Entry(data: data, stamp: stamp)
            bytes += data.count

            // Never past the entry just stored: the caller is about to use it,
            // and a cache that evicts what it has just been asked for would
            // re-read the same file on the very next request.
            while order.count > 1, bytes > maximumTotalBytes {
                let evicted = order.removeFirst()
                if let entry = entries.removeValue(forKey: evicted) {
                    bytes -= entry.data.count
                }
            }
        }
    }

    private func withLock<Result>(_ body: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Opens the file and reads at most one byte beyond the ceiling.
    ///
    /// The metadata check in ``read(_:maximumBytes:)`` rejects an already
    /// oversized regular file without allocating it. This second bound is
    /// still required: a file can grow after that check, and a special file
    /// can report no useful size at all. Reading to EOF after a successful
    /// `stat` would turn that race back into an unbounded allocation.
    private static func boundedRead(
        _ url: URL,
        maximumBytes: Int
    ) throws -> (data: Data, stamp: LocalFileStamp) {
        guard maximumBytes >= 0 else {
            throw NoteTextReadError.fileTooLarge(url, maximumBytes: 0)
        }
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            // O_NOFOLLOW_ANY rejects a symlink substituted into any component
            // after canonicalisation; O_NONBLOCK prevents a FIFO from hanging
            // the main actor before `fstat` can reject it.
            let noFollowAny: Int32 = 0x2000_0000
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | noFollowAny)
        }
        guard descriptor >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: url.path])
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: url.path])
        }
        guard status.st_mode & S_IFMT == S_IFREG,
            let stamp = LocalFileStamp(status)
        else {
            throw NoteTextReadError.unsupportedFile(url)
        }
        if stamp.size > maximumBytes {
            throw NoteTextReadError.fileTooLarge(url, maximumBytes: maximumBytes)
        }

        let ceiling = maximumBytes == Int.max ? Int.max : maximumBytes + 1
        var data = Data()
        data.reserveCapacity(min(maximumBytes, 64 * 1_024))
        while data.count < ceiling {
            let requested = min(64 * 1_024, ceiling - data.count)
            guard let chunk = try handle.read(upToCount: requested), !chunk.isEmpty else {
                break
            }
            data.append(chunk)
        }
        guard data.count <= maximumBytes else {
            throw NoteTextReadError.fileTooLarge(url, maximumBytes: maximumBytes)
        }
        return (data, stamp)
    }

    /// One spelling per file, so `Notes/./a.md` and `Notes/a.md` are one
    /// entry — and so the freshness check stats the same file the bytes were
    /// taken from.
    private static func canonical(_ url: URL) -> URL {
        LocalFileSystem.canonicalIOURL(url)
    }
}
