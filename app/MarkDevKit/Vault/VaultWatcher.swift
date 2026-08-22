//
//  VaultWatcher.swift
//  MarkDevKit
//
//  Watching the vault for changes made anywhere else.
//

import CoreServices
import Foundation

/// Watches one directory tree and reports the paths that changed.
///
/// Nothing else in this app watches the file system, which is why notes
/// created by another tool appear only after reopening the vault and why an
/// external edit used to surface as a save-time refusal rather than as
/// information. One stream here feeds all three consumers: the navigator's
/// tree, the link index, and the open-document conflict check.
///
/// The stream is scheduled on the main queue, so events arrive on the main
/// actor — everything that reacts to them (SwiftUI state, the index, the
/// workspace) lives there, and no consumer has to hop.
public final class VaultWatcher: @unchecked Sendable {
    /// Called with each batch of changed absolute paths, on the main actor.
    public var onEvents: (([String]) -> Void)?

    private var stream: FSEventStreamRef?
    /// The root currently watched.
    public private(set) var watchedRoot: URL?

    public init() {}

    deinit {
        stop()
    }

    /// Begins watching `root`, replacing any previous watch.
    ///
    /// Creating a stream over a missing directory succeeds and reports
    /// nothing; whether that matters is a navigator question, not this type's.
    ///
    /// Delivery near stream birth is lossy at the OS level: writes that race
    /// `FSEventStreamStart`'s registration can be dropped outright rather
    /// than delivered late — measured against a plain harness, in both
    /// main-queue and private-queue configurations, with and without churn.
    /// Consumers that must not miss changes therefore pair this with a
    /// catch-up sweep (``VaultIndex/reconcileWithDisk(excluding:)``), which
    /// is what makes the gap harmless rather than pretending it away.
    public func start(at root: URL) {
        stop()
        watchedRoot = root.standardizedFileURL

        var context = FSEventStreamContext(
            version: 0,
            // Unretained: the stream's lifetime is contained by this
            // instance's — `stop()` runs first in `deinit` — so the watcher
            // cannot die while the C layer still holds its address, and the
            // stream cannot keep it alive past its own storage.
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil)

        let sinceWhen = FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        // FileEvents for per-file paths; **UseCFTypes** because the callback
        // below reads `eventPaths` as a CFArray of strings — without this
        // flag it is a bare C array and that read is memory unsafety.
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagUseCFTypes)

        guard
            let created = FSEventStreamCreate(
                kCFAllocatorDefault,
                { _, info, count, eventPaths, _, _ in
                    guard count > 0, let info else { return }
                    // The C layer hands back a CFArray of CFStrings behind a
                    // raw pointer; the count is its element count.
                    let watcher = Unmanaged<VaultWatcher>.fromOpaque(info)
                        .takeUnretainedValue()
                    watcher.handleCallback(count: count, eventPaths: eventPaths)
                },
                &context,
                [root.path] as CFArray,
                sinceWhen,
                0.3,
                flags)
        else {
            watchedRoot = nil
            return
        }

        // Scheduled before started: that ordering is the API's contract. A
        // start that fails leaves a stream that reports nothing while
        // `watchedRoot` would claim otherwise — every consumer (navigator
        // refresh, index updates, conflict detection) silently disabled.
        // Refused the only way this type can: by not claiming to watch.
        FSEventStreamSetDispatchQueue(created, .main)
        guard FSEventStreamStart(created) else {
            FSEventStreamRelease(created)
            watchedRoot = nil
            return
        }

        stream = created
    }

    /// The stream callback's continuation, after the closure has recovered
    /// `self` from the unretained context. Split out so the decoding — the
    /// CFArray read behind a raw pointer — is assertable without the daemon,
    /// whose delivery under churn is a platform mood rather than this type's
    /// behaviour.
    func handleCallback(count: Int, eventPaths: UnsafeMutableRawPointer?) {
        guard count > 0, let eventPaths else { return }
        // With UseCFTypes the C layer hands back a CFArray of CFStrings
        // behind that raw pointer; the count is its element count.
        let array = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
        guard let changed = array as? [String], !changed.isEmpty else { return }
        // Sound because the stream is scheduled on the main queue: this call
        // *is* the main actor running.
        MainActor.assumeIsolated {
            self.onEvents?(changed)
        }
    }

    /// Ends watching. Harmless when not started.
    public func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            watchedRoot = nil
        }
    }
}


/// One file-system stream per vault folder, however many windows watch it.
///
/// Every window used to open its own `FSEventStream`, so two views of one
/// vault meant two streams reporting identical batches to two handlers that
/// both re-indexed the same files. The coordinator refcounts subscribers per
/// root: the first starts the stream, the last to leave stops it, and every
/// event fans out to whoever is still listening.
@MainActor
public final class VaultWatchCoordinator {
    public static let shared = VaultWatchCoordinator()

    private struct Entry {
        let watcher: VaultWatcher
        var subscribers: [UUID: ([String]) -> Void] = [:]
    }

    private var entries: [URL: Entry] = [:]

    #if DEBUG
        /// When false, ``subscribe`` performs its bookkeeping without
        /// starting an underlying FSEventStream. For coordinator tests:
        /// fseventsd throttles a *process* whose lifetime creates and
        /// destroys many streams — delivery degrades to multi-second delays,
        /// not fixable by settling — so every real birth in the suite counts.
        /// The coordinator's refcounting needs none of them: fan-out is
        /// covered by ``emit(root:paths:)``, live-stream behaviour by the
        /// watcher canaries that deliberately spend births.
        nonisolated(unsafe) public static var startsRealStreamsForTesting = true
    #endif

    private init() {}

    /// Begins receiving events for `root`; returns the token that ends them.
    @discardableResult
    public func subscribe(
        to root: URL, handler: @escaping ([String]) -> Void
    ) -> UUID {
        let key = normalized(root)
        let token = UUID()

        if entries[key] == nil {
            let watcher = VaultWatcher()
            #if DEBUG
                if Self.startsRealStreamsForTesting {
                    watcher.start(at: root)
                }
            #else
                watcher.start(at: root)
            #endif
            watcher.onEvents = { [weak self] paths in
                self?.fanOut(key: key, paths: paths)
            }
            entries[key] = Entry(watcher: watcher)
        }
        entries[key]?.subscribers[token] = handler
        return token
    }

    /// Ends this subscription; stops the underlying stream at zero.
    public func unsubscribe(_ token: UUID, root: URL) {
        let key = normalized(root)
        entries[key]?.subscribers.removeValue(forKey: token)
        if entries[key]?.subscribers.isEmpty == true {
            entries[key]?.watcher.stop()
            entries.removeValue(forKey: key)
        }
    }

    private func fanOut(key: URL, paths: [String]) {
        guard let entry = entries[key] else { return }
        // Snapshot before delivering: a handler that unsubscribes *in
        // response to* an event mutates this dictionary, and mutating a
        // dictionary during iteration over its values is a runtime crash —
        // one that only fires when a consumer happens to react that way.
        for handler in Array(entry.subscribers.values) {
            handler(paths)
        }
    }

    private func normalized(_ root: URL) -> URL {
        (root.path as NSString).standardizingPath
            .pipe { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath() }
    }

    // MARK: - Test seams

    #if DEBUG
        /// Whether `root` currently has a live stream. Root-scoped so a
        /// multi-root test cannot pass on shared-state luck.
        func activeStreamCount(forTestingRoot root: URL) -> Int {
            entries[normalized(root)] != nil ? 1 : 0
        }

        func emit(root: URL, paths: [String]) {
            fanOut(key: normalized(root), paths: paths)
        }
    #endif
}

private extension String {
    /// Scoped helper so the pipeline above stays one readable line.
    func pipe<R>(_ transform: (String) -> R) -> R {
        transform(self)
    }
}
