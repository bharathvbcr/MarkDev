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

private enum VaultBoundary {
    static let maximumPathBytes = 4 * 1_024
    static let maximumQueryBytes = 4 * 1_024
    static let maximumSearchResults = 1_000

    static func acceptsCString(_ value: String, maximumBytes: Int, allowEmpty: Bool = false)
        -> Bool
    {
        (allowEmpty || !value.isEmpty)
            && !value.utf8.contains(0)
            && value.utf8.count <= maximumBytes
    }

    static func acceptsOptionalCString(_ value: String?, maximumBytes: Int) -> Bool {
        guard let value, !value.isEmpty else { return true }
        return acceptsCString(value, maximumBytes: maximumBytes)
    }
}

private func vaultSaturatedAdd(_ lhs: Int, _ rhs: Int) -> Int {
    let (sum, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? Int.max : sum
}

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
    /// Rewrites that failed after the source note had already moved.
    public let failedRewrites: Int
    /// False means the file move happened but one or more link rewrites did
    /// not, so callers must surface a partial result rather than success.
    public let isComplete: Bool

    public init(
        rewrittenNotes: Int,
        rewrittenLinks: Int,
        failedRewrites: Int = 0,
        isComplete: Bool = true
    ) {
        self.rewrittenNotes = rewrittenNotes
        self.rewrittenLinks = rewrittenLinks
        self.failedRewrites = failedRewrites
        self.isComplete = isComplete
    }
}

/// Whether an editor-buffer update crossed and changed the Rust index.
public enum VaultUpdateResult: Equatable, Sendable {
    case rejected
    case unchanged
    case changed
}

/// Exact coverage of the bounded scan performed when a Rust vault opens.
public struct VaultInitialScanStatus: Codable, Equatable, Sendable {
    public let scanPerformed: Bool
    public let visitedEntries: UInt64
    public let discoveredFiles: UInt64
    public let discoveredBytes: UInt64
    public let selectedFiles: UInt64
    public let selectedBytes: UInt64
    public let indexedFiles: UInt64
    public let indexedBytes: UInt64
    public let skippedFiles: UInt64
    public let skippedSymlinks: UInt64
    public let unreadableDirectories: UInt64
    public let unreadableEntries: UInt64
    public let unreadableFiles: UInt64
    public let oversizedFiles: UInt64
    public let hitDepthLimit: Bool
    public let hitEntryLimit: Bool
    public let hitTotalByteLimit: Bool

    public var isComplete: Bool {
        scanPerformed && !hitDepthLimit && !hitEntryLimit && !hitTotalByteLimit
            && skippedFiles == 0 && unreadableDirectories == 0 && unreadableEntries == 0
            && unreadableFiles == 0 && oversizedFiles == 0
    }

    private enum CodingKeys: String, CodingKey {
        case scanPerformed = "scan_performed"
        case visitedEntries = "visited_entries"
        case discoveredFiles = "discovered_files"
        case discoveredBytes = "discovered_bytes"
        case selectedFiles = "selected_files"
        case selectedBytes = "selected_bytes"
        case indexedFiles = "indexed_files"
        case indexedBytes = "indexed_bytes"
        case skippedFiles = "skipped_files"
        case skippedSymlinks = "skipped_symlinks"
        case unreadableDirectories = "unreadable_directories"
        case unreadableEntries = "unreadable_entries"
        case unreadableFiles = "unreadable_files"
        case oversizedFiles = "oversized_files"
        case hitDepthLimit = "hit_depth_limit"
        case hitEntryLimit = "hit_entry_limit"
        case hitTotalByteLimit = "hit_total_byte_limit"
    }
}

/// What a catch-up sweep changed and whether it covered the whole vault.
public struct VaultReconciliationResult: Equatable, Sendable {
    public let changedNotes: Int
    public let scan: FileTree.ScanResult
    public let unreadableFiles: Int
    /// Files that passed the inventory size check but exceeded the bound when
    /// opened, for example because another process grew them between phases.
    public let oversizedFilesDuringRead: Int
    /// Actual UTF-8 bytes accepted during the read phase.
    public let bytesRead: Int
    /// A file grew beyond the aggregate allowance after inventory.
    public let hitTotalByteLimitDuringRead: Bool

    public var oversizedFiles: Int {
        let (sum, overflow) = scan.oversizedFiles.addingReportingOverflow(
            oversizedFilesDuringRead)
        return overflow ? Int.max : sum
    }

    /// `false` means absence from the scan was not used as proof of deletion.
    public var isComplete: Bool {
        scan.isComplete && unreadableFiles == 0 && oversizedFilesDuringRead == 0
            && !hitTotalByteLimitDuringRead
    }
}

/// The wire shape `md_vault_rename` answers with. Kept private: the decoded
/// ``RenameOutcome`` above is the public spelling.
private struct RenameOutcomePayload: Decodable {
    let rewritten_notes: UInt32
    let rewritten_links: UInt32
    let failed_rewrites: UInt32
    let complete: Bool
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
    /// Advances whenever graph-relevant indexed content may have changed,
    /// including edits and renames that leave the number of notes unchanged.
    public private(set) var contentRevision: UInt64 = 0
    /// Retains coverage evidence for diagnostics and callers using the legacy
    /// integer-returning reconciliation entry point.
    public private(set) var lastReconciliationResult: VaultReconciliationResult?
    /// Coverage of the Rust scan that populated this instance at open time.
    public private(set) var initialScanStatus: VaultInitialScanStatus?
    private let diagnostics: DiagnosticsEmitter

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

    public init(diagnostics: DiagnosticsEmitter = .shared) {
        self.diagnostics = diagnostics
    }

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
        lastReconciliationResult = nil
        #if canImport(CMarkDev)
            coreLock.lock()
            if let handle { md_vault_free(handle) }
            if VaultBoundary.acceptsCString(
                root.path, maximumBytes: VaultBoundary.maximumPathBytes)
            {
                handle = root.path.withCString { md_vault_open($0) }
            } else {
                handle = nil
            }
            noteCount = handle.map { Int(md_vault_note_count($0)) } ?? 0
            initialScanStatus = handle.flatMap { decode(md_vault_scan_status($0)) }
            coreLock.unlock()
            self.root = root
            contentRevision &+= 1
        #else
            self.root = root
            initialScanStatus = nil
        #endif
    }

    /// Re-indexes one note from text held in the editor rather than on disk,
    /// so backlinks track what is on screen and not the last save.
    @discardableResult
    public func update(path: String, text: String) -> VaultUpdateResult {
        #if canImport(CMarkDev)
            guard !path.isEmpty,
                path.utf8.count <= VaultBoundary.maximumPathBytes,
                text.utf8.count <= FileTree.defaultMaximumNoteBytes
            else { return .rejected }
            let pathBytes = Array(path.utf8)
            let textBytes = Array(text.utf8)
            coreLock.lock()
            defer { coreLock.unlock() }
            guard let handle else { return .rejected }
            let rawResult = pathBytes.withUnsafeBytes { pathBuffer in
                textBytes.withUnsafeBytes { textBuffer in
                    md_vault_update(
                        handle,
                        pathBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        UInt(pathBuffer.count),
                        textBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        UInt(textBuffer.count))
                }
            }
            switch rawResult {
            case 2:
                noteCount = Int(md_vault_note_count(handle))
                contentRevision &+= 1
                return .changed
            case 1:
                return .unchanged
            default:
                return .rejected
            }
        #else
            return .rejected
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
            guard limit > 0,
                VaultBoundary.acceptsCString(
                    text, maximumBytes: VaultBoundary.maximumQueryBytes)
            else { return [] }
            let boundedLimit = UInt32(min(limit, VaultBoundary.maximumSearchResults))
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
            guard VaultBoundary.acceptsCString(
                target, maximumBytes: VaultBoundary.maximumQueryBytes),
                VaultBoundary.acceptsOptionalCString(
                    anchor, maximumBytes: VaultBoundary.maximumQueryBytes)
            else { return nil }
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

    /// Whether `path` is a note this index knows.
    ///
    /// The drag-and-drop move asks before renaming into a folder: refusing
    /// with a name beats letting the core refuse with none.
    public func contains(_ path: String) -> Bool {
        notePaths().contains(path)
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
            guard VaultBoundary.acceptsCString(
                path, maximumBytes: VaultBoundary.maximumPathBytes)
            else { return }
            coreLock.lock()
            defer { coreLock.unlock() }
            guard let handle else { return }
            path.withCString { md_vault_remove(handle, $0) }
            noteCount = Int(md_vault_note_count(handle))
            contentRevision &+= 1
        #endif
    }

    /// Brings the index back in line with the disk, once, wholesale.
    ///
    /// FSEvents is lossy around stream birth — writes racing registration can
    /// be dropped outright rather than delivered late (measured against a
    /// plain harness, not assumed) — and a vault opened moments before the
    /// watch began has a scan-to-subscribe gap besides. Whatever the cause,
    /// an event that never arrives leaves the index describing a world that
    /// no longer exists: backlinks to deleted notes, search missing new ones.
    /// One full sweep after subscribing closes every such gap at once.
    ///
    /// The walk and the reads run off the main actor; only the application of
    /// their results touches the core. Notes whose URL is in `excluding` are
    /// skipped entirely — for callers hosting editors, whose buffers are
    /// authoritative over what any file says (the same rule
    /// per-event handling follows).
    ///
    /// Reconciles with explicit traversal limits and returns coverage evidence.
    /// Missing paths are removed only after a complete inventory; a capped or
    /// unreadable walk can update what it did see, but never turns unseen into
    /// deleted.
    ///
    /// - Returns: both the number of changed notes and proof of scan coverage.
    ///   Callers must not reduce an incomplete walk to a successful empty one.
    @discardableResult
    public func reconcileWithDisk(
        excluding: Set<URL> = [], scanLimits: FileTree.ScanLimits = .standard
    ) async -> VaultReconciliationResult {
        let operationID = DiagnosticOperationID()
        guard let root else {
            let result = VaultReconciliationResult(
                changedNotes: 0,
                scan: FileTree.ScanResult(
                    files: [],
                    visitedEntries: 0,
                    discoveredFiles: 0,
                    discoveredBytes: 0,
                    selectedBytes: 0,
                    skippedSymlinks: 0,
                    unreadableDirectories: 1,
                    unreadableEntries: 0,
                    oversizedFiles: 0,
                    hitDepthLimit: false,
                    hitEntryLimit: false,
                    hitTotalByteLimit: false),
                unreadableFiles: 0,
                oversizedFilesDuringRead: 0,
                bytesRead: 0,
                hitTotalByteLimitDuringRead: false)
            lastReconciliationResult = result
            recordIncompleteReconciliation(result, operationID: operationID)
            return result
        }
        let excluded = Set(excluding.map(\.standardizedFileURL.path))

        // Read off the main actor. The snapshot carries bytes, not parsed
        // results, so the apply step below cannot mistake a stale read for a
        // fresh one.
        struct DiskNote: Sendable {
            let url: URL
            let text: String
        }
        let readResult: (FileTree.ScanResult, [DiskNote], Int, Int, Int, Bool) =
            await Task.detached(priority: .utility) {
                let scan = FileTree.scanMarkdownFiles(under: root, limits: scanLimits)
                let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
                let rootPrefix = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
                var unreadableFiles = 0
                var oversizedFilesDuringRead = 0
                var bytesRead = 0
                var hitTotalByteLimitDuringRead = false
                var snapshot: [DiskNote] = []
                snapshot.reserveCapacity(scan.files.count)
                for url in scan.files {
                    let standardized = url.standardizedFileURL.path
                    guard !excluded.contains(standardized) else { continue }
                    let values = try? url.resourceValues(forKeys: [
                        .isRegularFileKey, .isSymbolicLinkKey,
                    ])
                    let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
                    guard values?.isRegularFile == true,
                        values?.isSymbolicLink != true,
                        resolved.hasPrefix(rootPrefix)
                    else {
                        unreadableFiles = vaultSaturatedAdd(unreadableFiles, 1)
                        continue
                    }
                    let remainingBytes = max(0, scanLimits.maxTotalBytes - bytesRead)
                    let maximumBytes = min(scanLimits.maxNoteBytes, remainingBytes)
                    switch FileTree.readUTF8File(
                        at: url, inside: root, maximumBytes: maximumBytes)
                    {
                    case .text(let text):
                        let count = text.utf8.count
                        let nextBytes = vaultSaturatedAdd(bytesRead, count)
                        guard nextBytes <= scanLimits.maxTotalBytes else {
                            hitTotalByteLimitDuringRead = true
                            continue
                        }
                        bytesRead = nextBytes
                        snapshot.append(DiskNote(url: url, text: text))
                    case .oversized:
                        if remainingBytes < scanLimits.maxNoteBytes {
                            hitTotalByteLimitDuringRead = true
                        } else {
                            oversizedFilesDuringRead = vaultSaturatedAdd(
                                oversizedFilesDuringRead, 1)
                        }
                    case .unreadable:
                        unreadableFiles = vaultSaturatedAdd(unreadableFiles, 1)
                    }
                }
                return (
                    scan,
                    snapshot,
                    unreadableFiles,
                    oversizedFilesDuringRead,
                    bytesRead,
                    hitTotalByteLimitDuringRead)
            }.value
        let scan = readResult.0
        let snapshot = readResult.1
        var unreadableFiles = readResult.2
        let oversizedFilesDuringRead = readResult.3
        let bytesRead = readResult.4
        let hitTotalByteLimitDuringRead = readResult.5

        var touched = 0
        let onDisk = Set(scan.files.map(\.standardizedFileURL.path))
        for note in snapshot {
            if let relative = relativePath(for: note.url) {
                switch update(path: relative, text: note.text) {
                case .changed:
                    touched = vaultSaturatedAdd(touched, 1)
                case .unchanged:
                    break
                case .rejected:
                    unreadableFiles = vaultSaturatedAdd(unreadableFiles, 1)
                }
            } else {
                unreadableFiles = vaultSaturatedAdd(unreadableFiles, 1)
            }
        }

        // A note gone from the disk is gone from the index — but only on
        // proven absence. A read that failed for permission reasons must not
        // masquerade as a deletion.
        let scanWasComplete =
            scan.isComplete && unreadableFiles == 0 && oversizedFilesDuringRead == 0
            && !hitTotalByteLimitDuringRead
        if scanWasComplete {
            for path in notePaths() {
                guard let url = url(for: path) else { continue }
                let absolutePath = url.standardizedFileURL.path
                if !excluded.contains(absolutePath),
                    !onDisk.contains(absolutePath),
                    !FileManager.default.fileExists(atPath: url.path)
                {
                    removeNote(path)
                    touched = vaultSaturatedAdd(touched, 1)
                }
            }
        }
        let result = VaultReconciliationResult(
            changedNotes: touched,
            scan: scan,
            unreadableFiles: unreadableFiles,
            oversizedFilesDuringRead: oversizedFilesDuringRead,
            bytesRead: bytesRead,
            hitTotalByteLimitDuringRead: hitTotalByteLimitDuringRead)
        lastReconciliationResult = result
        if !result.isComplete {
            recordIncompleteReconciliation(result, operationID: operationID)
        }
        return result
    }

    private func recordIncompleteReconciliation(
        _ result: VaultReconciliationResult,
        operationID: DiagnosticOperationID
    ) {
        diagnostics.emit(
            severity: .warning,
            subsystem: .vault,
            code: .vaultReconciliationIncomplete,
            operationID: operationID,
            metadata: DiagnosticMetadata([
                .changedCount: .integer(Int64(result.changedNotes)),
                .discoveredFileCount: .integer(Int64(result.scan.discoveredFiles)),
                .visitedEntryCount: .integer(Int64(result.scan.visitedEntries)),
                .skippedSymlinkCount: .integer(Int64(result.scan.skippedSymlinks)),
                .unreadableDirectoryCount: .integer(
                    Int64(result.scan.unreadableDirectories)),
                .unreadableEntryCount: .integer(Int64(result.scan.unreadableEntries)),
                .unreadableFileCount: .integer(Int64(result.unreadableFiles)),
                .oversizedFileCount: .integer(Int64(result.oversizedFiles)),
                .hitDepthLimit: .boolean(result.scan.hitDepthLimit),
                .hitEntryLimit: .boolean(result.scan.hitEntryLimit),
            ]))
    }

    /// Moves a note and rewrites every link that resolved to it.
    ///
    /// - Returns: how many notes and individual links were rewritten, or
    ///   `nil` when the move was refused (unknown source, destination taken,
    ///   file error). `nil` means nothing happened on disk either. A non-nil
    ///   result whose ``RenameOutcome/isComplete`` is false means the source
    ///   moved but one or more link rewrites failed and must be surfaced.
    public func renameNote(from: String, to: String) -> RenameOutcome? {
        #if canImport(CMarkDev)
            guard VaultBoundary.acceptsCString(
                from, maximumBytes: VaultBoundary.maximumPathBytes),
                VaultBoundary.acceptsCString(
                    to, maximumBytes: VaultBoundary.maximumPathBytes)
            else { return nil }
            return coreLock.withLock {
                guard let handle else { return nil }
                let payload: RenameOutcomePayload? = from.withCString { fromPointer in
                    to.withCString { toPointer in
                        decode(md_vault_rename(handle, fromPointer, toPointer))
                    }
                }
                guard let payload else { return nil }
                contentRevision &+= 1
                return RenameOutcome(
                    rewrittenNotes: Int(payload.rewritten_notes),
                    rewrittenLinks: Int(payload.rewritten_links),
                    failedRewrites: Int(payload.failed_rewrites),
                    isComplete: payload.complete)
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

    /// The laid-out graph, computed off the main actor.
    ///
    /// The layout is an all-pairs force simulation over up to `MAX_NODES`
    /// notes — seconds of work for a vault at the cap. Running it against the
    /// shared handle would hold ``coreLock`` the whole time, and every
    /// keystroke-path query takes that lock: typing would freeze behind a
    /// picture. The compute therefore runs against a **clone** taken under
    /// the lock (see `md_vault_clone`) — microseconds — and holds nothing
    /// while it simulates.
    ///
    /// Cancellation is honoured before and after every cancellable boundary.
    /// A simulation already inside Rust runs to completion because that ABI is
    /// synchronous, but its result is discarded and it holds only its private
    /// clone — never the live index lock or the reader's canvas.
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
        guard !Task.isCancelled else { return .empty }
        let worker = Task.detached(priority: .userInitiated) { [self] in
            clonedGraph(focus: focus, depth: depth, tag: tag, folder: folder)
        }
        return await withTaskCancellationHandler {
            if Task.isCancelled { worker.cancel() }
            let result = await worker.value
            return Task.isCancelled ? .empty : result
        } onCancel: {
            // Detached tasks do not inherit cancellation. Explicitly forward
            // it so queued work can stop before cloning and completed stale
            // work can never be returned to a superseded caller.
            worker.cancel()
        }
    }

    /// The synchronous path, against the shared index under ``coreLock``.
    ///
    /// Kept for tests and for callers that want the answer against exactly
    /// the live index; UI code should use ``graphOffMain``.
    public func graph(
        focus: String? = nil,
        depth: Int = 2,
        tag: String? = nil,
        folder: String? = nil
    ) -> VaultGraph {
        lockedGraph(focus: focus, depth: depth, tag: tag, folder: folder)
    }

    /// Graph layout against a private clone, holding nothing but itself.
    nonisolated private func clonedGraph(
        focus: String?,
        depth: Int,
        tag: String?,
        folder: String?
    ) -> VaultGraph {
        #if canImport(CMarkDev)
            guard !Task.isCancelled,
                VaultBoundary.acceptsOptionalCString(
                    focus, maximumBytes: VaultBoundary.maximumQueryBytes),
                VaultBoundary.acceptsOptionalCString(
                    tag, maximumBytes: VaultBoundary.maximumQueryBytes),
                VaultBoundary.acceptsOptionalCString(
                    folder, maximumBytes: VaultBoundary.maximumPathBytes)
            else { return .empty }

            coreLock.lock()
            let snapshot = handle.map { md_vault_clone($0) }
            coreLock.unlock()
            guard !Task.isCancelled, let snapshot else {
                if let snapshot { md_vault_free(snapshot) }
                return .empty
            }
            defer { md_vault_free(snapshot) }

            let bounded = UInt32(max(0, min(depth, 16)))
            // Nested `withCString` rather than a helper: the pointers must all
            // stay alive across the single call, and a helper returning them
            // would hand back memory already freed.
            let graph: VaultGraph = withOptionalCString(focus) { focusPointer in
                withOptionalCString(tag) { tagPointer in
                    withOptionalCString(folder) { folderPointer in
                        decode(
                            md_vault_graph(
                                snapshot, focusPointer, bounded, tagPointer, folderPointer))
                            ?? .empty
                    }
                }
            }
            return Task.isCancelled ? .empty : graph
        #else
            return .empty
        #endif
    }

    /// The body of the synchronous graph path; called with ``coreLock`` held.
    nonisolated private func lockedGraph(
        focus: String?,
        depth: Int,
        tag: String?,
        folder: String?
    ) -> VaultGraph {
        #if canImport(CMarkDev)
            guard VaultBoundary.acceptsOptionalCString(
                focus, maximumBytes: VaultBoundary.maximumQueryBytes),
                VaultBoundary.acceptsOptionalCString(
                    tag, maximumBytes: VaultBoundary.maximumQueryBytes),
                VaultBoundary.acceptsOptionalCString(
                    folder, maximumBytes: VaultBoundary.maximumPathBytes)
            else { return .empty }
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
            guard VaultBoundary.acceptsCString(
                path, maximumBytes: VaultBoundary.maximumPathBytes)
            else { return [] }
            return coreLock.withLock {
                guard let handle else { return [] }
                return path.withCString { pointer -> [T]? in
                    decode(call(handle, pointer))
                } ?? []
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
            // JSONDecoder does not document concurrent-use safety. Queries
            // can decode simultaneously against independent cloned handles,
            // so each decode owns its mutable decoder state.
            return try? JSONDecoder().decode(T.self, from: data)
        }
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
