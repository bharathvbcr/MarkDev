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
                    let array = Unmanaged<CFArray>
                        .fromOpaque(eventPaths).takeUnretainedValue()
                    guard let changed = array as? [String], !changed.isEmpty else { return }
                    let watcher = Unmanaged<VaultWatcher>.fromOpaque(info)
                        .takeUnretainedValue()
                    // Sound because the stream was scheduled on the main
                    // queue: this block *is* the main actor running.
                    MainActor.assumeIsolated {
                        watcher.onEvents?(changed)
                    }
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

        stream = created
        FSEventStreamSetDispatchQueue(created, .main)
        FSEventStreamStart(created)
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
