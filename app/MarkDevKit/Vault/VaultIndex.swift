//
//  VaultIndex.swift
//  MarkDevKit
//
//  Swift access to the Rust vault index.
//

import Foundation

#if canImport(CMarkDev)
    import CMarkDev
#endif

/// A link pointing at the current note.
public struct Backlink: Codable, Identifiable, Sendable, Hashable {
    public let path: String
    public let title: String
    /// The line the link came from, for context.
    public let context: String
    public let line: UInt32
    /// UTF-16 offset of the link in the source note.
    public let offset: UInt32

    public var id: String { "\(path):\(line):\(offset)" }
}

/// A note naming this one without linking to it.
public struct UnlinkedMention: Codable, Identifiable, Sendable, Hashable {
    public let path: String
    public let title: String
    public let context: String
    public let line: UInt32
    public let offset: UInt32

    public var id: String { "\(path):\(line):\(offset)" }
}

/// A link a note points *out* at, and where it lands.
public struct OutgoingLink: Codable, Identifiable, Sendable, Hashable {
    /// The target as written, without the `#anchor` or `|alias`.
    public let target: String
    public let anchor: String?
    /// What the reader sees — the alias when there is one.
    public let display: String
    public let line: UInt32
    /// UTF-16 offset of the link in the note it was written in.
    public let offset: UInt32
    /// Vault-relative path of the note it resolves to, or `nil` when broken.
    public let path: String?

    public var id: String { "\(line):\(offset):\(target)" }
}

/// A full-text search hit.
public struct SearchHit: Codable, Identifiable, Sendable, Hashable {
    public let path: String
    public let title: String
    public let context: String
    public let line: UInt32
    public let score: UInt32

    public var id: String { "\(path):\(line)" }
}

/// What a rename changed, so the UI can say "rewrote 3 links" instead of
/// a bare success that reads like nothing happened.
public struct RenameOutcome: Equatable, Sendable {
    public let rewrittenNotes: Int
    public let rewrittenLinks: Int

    public init(rewrittenNotes: Int, rewrittenLinks: Int) {
        self.rewrittenNotes = rewrittenNotes
        self.rewrittenLinks = rewrittenLinks
    }
}

/// The wire shape `md_vault_rename` answers with. Kept private: the decoded
/// ``RenameOutcome`` above is the public spelling.
private struct RenameOutcomePayload: Decodable {
    let rewritten_notes: UInt32
    let rewritten_links: UInt32
}

/// A heading, for the outline.
public struct VaultHeading: Codable, Identifiable, Sendable, Hashable {
    public let level: UInt8
    public let text: String
    /// UTF-16 offset, so the editor can scroll straight to it.
    public let offset: UInt32
    public let line: UInt32

    public var id: String { "\(line):\(offset)" }

    public init(level: UInt8, text: String, offset: UInt32, line: UInt32) {
        self.level = level
        self.text = text
        self.offset = offset
        self.line = line
    }
}

/// A tag and how many notes carry it.
public struct TagCount: Codable, Identifiable, Sendable, Hashable {
    public let tag: String
    public let count: UInt32

    public var id: String { tag }
}

/// Where a `[[wikilink]]` points.
public struct LinkResolution: Codable, Sendable, Hashable {
    public let path: String
    /// UTF-16 offset of the anchored heading, when the link had one.
    public let offset: UInt32?
}

/// The indexed vault.
///
/// # Why this boundary is JSON
///
/// The editor crosses the FFI on every keystroke and uses flat struct buffers
/// for it. These queries run when a note is opened or a search is typed —
/// far less often, over nested variable-length data. JSON keeps the boundary
/// small and legible; the cost is invisible at this frequency.
@MainActor
public final class VaultIndex {
    public private(set) var root: URL?
    public private(set) var noteCount: Int = 0

    #if canImport(CMarkDev)
        // Every dereference of `handle` — on the main actor or off it, via
        // ``lockedGraph`` below — happens under ``coreLock``. That is what
        // makes the cross-actor graph computation safe rather than merely
        // hopeful: a layout running on a background thread and an index
        // update on the main actor can interleave at the lock, never inside
        // the Rust structure.
        nonisolated(unsafe) private let coreLock = NSLock()
        // All mutation remains main-actor isolated. Deinitialization is
        // nonisolated in Swift 6, so this annotation permits only the final
        // ownership release there; it does not make query methods concurrent.
        nonisolated(unsafe) private var handle: OpaquePointer?
    #endif

    public init() {}

    deinit {
        #if canImport(CMarkDev)
            // A background layout may still hold ``coreLock``; taking it here
            // means freeing waits for that compute to finish instead of
            // pulling the pointer out from under it.
            coreLock.lock()
            if let handle { md_vault_free(handle) }
            coreLock.unlock()
        #endif
    }

    /// Indexes every Markdown file under `root`.
    ///
    /// Walking and parsing happen in Rust, which is fast enough that a
    /// personal vault indexes in the time it takes the window to appear.
    public func open(_ root: URL) {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        #if canImport(CMarkDev)
            coreLock.lock()
            if let handle { md_vault_free(handle) }
            handle = root.path.withCString { md_vault_open($0) }
            noteCount = handle.map { Int(md_vault_note_count($0)) } ?? 0
            coreLock.unlock()
            self.root = root
        #else
            self.root = root
        #endif
    }

    /// Re-indexes one note from text held in the editor rather than on disk,
    /// so backlinks track what is on screen and not the last save.
    public func update(path: String, text: String) {
        #if canImport(CMarkDev)
            coreLock.lock()
            defer { coreLock.unlock() }
            guard let handle else { return }
            path.withCString { pathPointer in
                text.withCString { textPointer in
                    md_vault_update(handle, pathPointer, textPointer)
                }
            }
            noteCount = Int(md_vault_note_count(handle))
        #endif
    }

    /// Vault-relative path for `url`, or `nil` when it sits outside the vault.
    public func relativePath(for url: URL) -> String? {
        guard let root else { return nil }
        let rootComponents = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let fileComponents = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard fileComponents.count > rootComponents.count,
              fileComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
        else {
            return nil
        }
        return fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    /// Absolute URL for a vault-relative path.
    public func url(for path: String) -> URL? {
        guard let root, !path.isEmpty, !path.hasPrefix("/") else { return nil }
        let candidate = root.appendingPathComponent(path).standardizedFileURL
        guard relativePath(for: candidate) != nil else { return nil }
        return candidate
    }

    // MARK: - Queries

    public func backlinks(for path: String) -> [Backlink] {
        query(path) { md_vault_backlinks($0, $1) }
    }

    /// The links `path` points out at, in the order they appear in the note.
    ///
    /// The outbound half of ``backlinks(for:)``. Answered from the index
    /// rather than by re-parsing the open document: the index read the note
    /// when it indexed it, and a second parse of text already on screen is
    /// work in service of nothing.
    public func links(for path: String) -> [OutgoingLink] {
        query(path) { md_vault_links($0, $1) }
    }

    public func unlinkedMentions(for path: String) -> [UnlinkedMention] {
        query(path) { md_vault_unlinked_mentions($0, $1) }
    }

    public func outline(for path: String) -> [VaultHeading] {
        query(path) { md_vault_outline($0, $1) }
    }

    public func tags() -> [TagCount] {
        #if canImport(CMarkDev)
            return coreLock.withLock {
                guard let handle else { return [] }
                return decode(md_vault_tags(handle)) ?? []
            }
        #else
            return []
        #endif
    }

    public func search(_ text: String, limit: Int = 50) -> [SearchHit] {
        #if canImport(CMarkDev)
            guard !text.isEmpty, limit > 0 else { return [] }
            let boundedLimit = UInt32(min(limit, Int(UInt32.max)))
            return coreLock.withLock {
                guard let handle else { return [] }
                return text.withCString { decode(md_vault_search(handle, $0, boundedLimit)) }
                    ?? []
            }
        #else
            return []
        #endif
    }

    /// Resolves a `[[wikilink]]` target and optional `#anchor`.
    public func resolve(target: String, anchor: String? = nil) -> LinkResolution? {
        #if canImport(CMarkDev)
            return coreLock.withLock { resolveLocked(handle, target: target, anchor: anchor) }
        #else
            return nil
        #endif
    }

    /// The body of ``resolve(target:anchor:)``, called with ``coreLock`` held.
    private nonisolated func resolveLocked(
        _ handle: OpaquePointer?, target: String, anchor: String?
    ) -> LinkResolution? {
        #if canImport(CMarkDev)
            guard let handle else { return nil }
            return target.withCString { targetPointer -> LinkResolution? in
                guard let anchor else {
                    return decode(md_vault_resolve(handle, targetPointer, nil))
                }
                return anchor.withCString { anchorPointer in
                    decode(md_vault_resolve(handle, targetPointer, anchorPointer))
                }
            }
        #else
            return nil
        #endif
    }

    /// Forgets a note whose file has left the disk.
    ///
    /// The caller owns the file operation — trashing or deleting — because
    /// only it can put up a confirmation; this owns the index, which would
    /// otherwise keep answering backlink questions about a note that is gone.
    /// Unknown paths are silently fine: a watcher racing a manual delete is
    /// the second of them.
    public func removeNote(_ path: String) {
        #if canImport(CMarkDev)
            coreLock.lock()
            defer { coreLock.unlock() }
            guard let handle else { return }
            path.withCString { md_vault_remove(handle, $0) }
            noteCount = Int(md_vault_note_count(handle))
        #endif
    }

    /// Moves a note and rewrites every link that resolved to it.
    ///
    /// - Returns: how many notes and individual links were rewritten, or
    ///   `nil` when the move was refused (unknown source, destination taken,
    ///   file error). `nil` means nothing happened on disk either.
    public func renameNote(from: String, to: String) -> RenameOutcome? {
        #if canImport(CMarkDev)
            return coreLock.withLock {
                guard let handle else { return nil }
                let payload: RenameOutcomePayload? = from.withCString { fromPointer in
                    to.withCString { toPointer in
                        decode(md_vault_rename(handle, fromPointer, toPointer))
                    }
                }
                guard let payload else { return nil }
                return RenameOutcome(
                    rewrittenNotes: Int(payload.rewritten_notes),
                    rewrittenLinks: Int(payload.rewritten_links))
            }
        #else
            return nil
        #endif
    }

    /// The link graph, laid out and ready to draw.
    ///
    /// One call rather than nodes-then-edges-then-positions: the layout is a
    /// property of the whole graph, and fetching it in pieces would let a view
    /// draw edges against coordinates from a different build.
    ///
    /// - Parameters:
    ///   - focus: limits the graph to notes within `depth` hops of this one.
    ///     Accepts either a vault-relative path or a wikilink-style name.
    ///   - tag: keeps only notes carrying this tag; the leading `#` is optional.
    ///   - folder: keeps only notes under this vault-relative folder.
    public func graph(
        focus: String? = nil,
        depth: Int = 2,
        tag: String? = nil,
        folder: String? = nil
    ) -> VaultGraph {
        lockedGraph(focus: focus, depth: depth, tag: tag, folder: folder)
    }

    /// The laid-out graph, computed off the main actor.
    ///
    /// The layout is an all-pairs force simulation over up to
    /// `MAX_NODES` notes — seconds of work for a vault at the cap, which is
    /// exactly how a graph view becomes the reason an app feels slow. The
    /// Rust handle is shared, so the compute takes ``coreLock``: it serialises
    /// against index updates rather than racing them, and the main actor is
    /// blocked only if it asks for work at the same instant.
    ///
    /// Determinism makes this safe to prefer over ``graph(focus:depth:tag:
    /// folder:)`` wherever a caller can await: same inputs, same picture,
    /// different thread.
    public func graphOffMain(
        focus: String? = nil,
        depth: Int = 2,
        tag: String? = nil,
        folder: String? = nil
    ) async -> VaultGraph {
        await Task.detached(priority: .userInitiated) { [self] in
            lockedGraph(focus: focus, depth: depth, tag: tag, folder: folder)
        }.value
    }

    /// The body of both graph entry points; called with ``coreLock`` held.
    nonisolated private func lockedGraph(
        focus: String?,
        depth: Int,
        tag: String?,
        folder: String?
    ) -> VaultGraph {
        #if canImport(CMarkDev)
            coreLock.lock()
            defer { coreLock.unlock() }
            guard let handle else { return .empty }
            let bounded = UInt32(max(0, min(depth, 16)))
            // Nested `withCString` rather than a helper: the pointers must all
            // stay alive across the single call, and a helper returning them
            // would hand back memory already freed.
            return withOptionalCString(focus) { focusPointer in
                withOptionalCString(tag) { tagPointer in
                    withOptionalCString(folder) { folderPointer in
                        decode(
                            md_vault_graph(
                                handle, focusPointer, bounded, tagPointer, folderPointer))
                            ?? .empty
                    }
                }
            }
        #else
            return .empty
        #endif
    }

    /// Every note path, for the palette and link autocomplete.
    public func notePaths() -> [String] {
        #if canImport(CMarkDev)
            return coreLock.withLock {
                guard let handle else { return [] }
                return decode(md_vault_note_paths(handle)) ?? []
            }
        #else
            return []
        #endif
    }

    // MARK: - Decoding

    #if canImport(CMarkDev)
        private func query<T: Decodable>(
            _ path: String,
            _ call: (OpaquePointer, UnsafePointer<CChar>) -> UnsafePointer<CChar>?
        ) -> [T] {
            coreLock.withLock {
                guard let handle else { return [] }
                return path.withCString { decode(call(handle, $0)) } ?? []
            }
        }

        /// Runs `body` with a C string for `value`, or with null when it is
        /// absent or empty.
        ///
        /// The pointer is only valid for the duration of `body` — returning it
        /// would hand back memory that has already been freed, which is why
        /// the graph query nests three of these rather than calling a helper
        /// that returns pointers.
        private nonisolated func withOptionalCString<Result>(
            _ value: String?,
            _ body: (UnsafePointer<CChar>?) -> Result
        ) -> Result {
            guard let value, !value.isEmpty else { return body(nil) }
            return value.withCString { body($0) }
        }

        /// Decodes a borrowed C string.
        ///
        /// The pointer belongs to the Rust handle and is only valid until the
        /// next query on it, so it is decoded immediately and never stored.
        private nonisolated func decode<T: Decodable>(_ pointer: UnsafePointer<CChar>?) -> T? {
            guard let pointer else { return nil }
            let json = String(cString: pointer)
            guard let data = json.data(using: .utf8) else { return nil }
            // One decoder for the type, not one per query: these run on the
            // keystroke path whenever backlinks and mentions refresh, and
            // `JSONDecoder()` has no reason to be rebuilt each time.
            return try? VaultIndex.decoder.decode(T.self, from: data)
        }

        private nonisolated static let decoder = JSONDecoder()
    #else
        private func query<T: Decodable>(_ path: String, _ call: (Never, Never) -> Never?) -> [T] {
            []
        }
    #endif
}

/// Sendability is earned by the lock, not by the type: every dereference of
/// the Rust handle happens under ``coreLock``, on whichever actor asks, so a
/// reference handed to a detached task is a hand-off of *turns* rather than
/// of unsynchronised memory. Everything else mutable (`root`, `noteCount`)
/// stays main-actor isolated and is never read from the off-main path.
extension VaultIndex: @unchecked Sendable {}

/// A request to scroll an editor to a UTF-16 offset.
///
/// Carries a fresh identity each time so that revealing the *same* offset
/// twice still registers as a new request — clicking one outline row
/// repeatedly should keep working, which an offset-only value would not.
public struct RevealRequest: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let offset: Int

    public init(offset: Int) {
        self.id = UUID()
        self.offset = offset
    }
}
