//
//  NoteTextCache.swift
//  MarkDevKit
//
//  Notes read ahead of being asked for, and the check that says they are
//  still what is on disk.
//

import Foundation

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
/// file's current size and modification time, and a mismatch re-reads.
///
/// The residual gap is a rewrite that leaves both the size and the modification
/// timestamp untouched. That is what every editor's staleness check accepts,
/// and closing it properly means watching the file system rather than
/// distrusting the clock.
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

    /// What a file looked like when its bytes were taken.
    private struct Stamp: Equatable {
        let size: Int
        let modified: Date
    }

    private struct Entry {
        let data: Data
        let stamp: Stamp
    }

    /// Not an actor: the readers are a synchronous `@MainActor` open and a
    /// detached background read, and an actor would make the first of those
    /// asynchronous — which is the whole thing being avoided.
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    /// Insertion order, for eviction.
    private var order: [String] = []
    private var bytes = 0

    public private(set) var hits = 0
    public private(set) var misses = 0

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
        self.maximumFileBytes = maximumFileBytes
        self.maximumTotalBytes = maximumTotalBytes
    }

    // MARK: - Reading

    /// The file's bytes, from memory when it has not changed since they were
    /// taken, and from disk otherwise.
    public func read(_ url: URL) throws -> Data {
        // Canonicalised once, and everything below works from it. Keying on
        // the tidied path while stamping the one that arrived would make two
        // spellings of the same note two entries — and worse, would stat a
        // path the caller never has to be able to resolve.
        let file = Self.canonical(url)
        let key = file.path
        let current = Self.stamp(of: file)

        if let current, let cached = withLock({ entries[key] }), cached.stamp == current {
            withLock { hits += 1 }
            return cached.data
        }
        withLock { misses += 1 }

        let data = try Data(contentsOf: file)
        // Stamped again after the read: a file written *while* it was being
        // read gives bytes that match neither stamp, and caching those would
        // make one torn read permanent rather than momentary.
        if let current, let after = Self.stamp(of: file), after == current {
            store(data, stamp: current, for: key)
        }
        return data
    }

    /// UTF-8 text, with the same contract as `String(contentsOf:encoding:)`.
    public func utf8Text(at url: URL) throws -> String {
        let data = try read(url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(
                .fileReadInapplicableStringEncoding,
                userInfo: [NSURLErrorKey: url])
        }
        return text
    }

    /// Reads `url` into the cache, reporting whether it landed there.
    ///
    /// The warmer's entry point: it wants the bytes cached and the text back,
    /// and it wants a failure — an unreadable file, a note deleted since it
    /// was indexed — to be nothing more than a warm that did not happen.
    @discardableResult
    public func warm(_ url: URL) -> Data? {
        guard let size = Self.stamp(of: Self.canonical(url))?.size, size <= maximumFileBytes
        else { return nil }
        return try? read(url)
    }

    /// The cached bytes for `url`, or `nil` when there are none or they are
    /// stale. Never reads the file's contents.
    public func cached(_ url: URL) -> Data? {
        let file = Self.canonical(url)
        guard let current = Self.stamp(of: file) else { return nil }
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
            hits = 0
            misses = 0
        }
    }

    /// What is held right now, in bytes.
    public var cachedBytes: Int {
        withLock { bytes }
    }

    // MARK: - Storage

    private func store(_ data: Data, stamp: Stamp, for key: String) {
        guard data.count <= maximumFileBytes else { return }
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

    /// One spelling per file, so `Notes/./a.md` and `Notes/a.md` are one
    /// entry — and so the freshness check stats the same file the bytes were
    /// taken from.
    private static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Size and modification time, read fresh.
    ///
    /// `FileManager.attributesOfItem` rather than `URL.resourceValues`: the
    /// latter is allowed to answer from values already cached on the URL, and
    /// a staleness check served from a cache of its own is not a check.
    private static func stamp(of url: URL) -> Stamp? {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? Int,
            let modified = attributes[.modificationDate] as? Date
        else { return nil }
        return Stamp(size: size, modified: modified)
    }
}
