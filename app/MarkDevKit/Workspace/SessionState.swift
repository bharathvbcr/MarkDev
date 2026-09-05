//
//  SessionState.swift
//  MarkDevKit
//
//  What a window carries across launches.
//

import Foundation

/// Explicit resource limits for the small persisted window-state document.
/// These are correctness boundaries, not sampling limits: anything outside
/// them is rejected or normalized before it can reach ``Workspace``.
public enum SessionStateLimits {
    public static let maximumDocumentsPerPane = 32
    public static let maximumDocuments = 256
    public static let maximumURLBytes = 16_384
    public static let maximumEncodedBytes = 1_048_576
    public static let maximumJSONNestingDepth = 128
}

/// One open document, as it is worth remembering.
///
/// Only file-backed documents survive a relaunch: the text of an untitled tab
/// exists nowhere but memory, and re-opening an empty "Untitled" on launch is
/// not restoration, it is noise.
public struct DocumentSnapshot: Codable, Equatable, Sendable {
    public let url: String

    public init(url: String) {
        self.url = url
    }
}

/// One pane's tabs and which of them is frontmost.
public struct PaneSnapshot: Codable, Equatable, Sendable {
    public let pane: PaneID
    public let documents: [DocumentSnapshot]
    /// Kept for backward decoding. A runtime document UUID cannot identify a
    /// newly-created document after relaunch, so new snapshots use the URL.
    public let selection: UUID?
    public let selectedDocumentURL: String?

    public init(
        pane: PaneID,
        documents: [DocumentSnapshot],
        selection: UUID?,
        selectedDocumentURL: String? = nil
    ) {
        self.pane = pane
        let canonicalDocuments = Self.canonicalDocuments(documents)
        self.documents = canonicalDocuments
        self.selection = selection
        let canonicalSelection = selectedDocumentURL.flatMap(SessionCanonical.fileURLString)
        self.selectedDocumentURL = canonicalDocuments.contains(where: {
            $0.url == canonicalSelection
        }) ? canonicalSelection : nil
    }

    private enum CodingKeys: String, CodingKey {
        case pane
        case documents
        case selection
        case selectedDocumentURL
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let pane = try container.decode(PaneID.self, forKey: .pane)
        var values = try container.nestedUnkeyedContainer(forKey: .documents)
        if let count = values.count, count > SessionStateLimits.maximumDocumentsPerPane {
            throw DecodingError.dataCorruptedError(
                forKey: .documents,
                in: container,
                debugDescription: "A pane contains too many saved documents.")
        }
        var documents: [DocumentSnapshot] = []
        documents.reserveCapacity(
            min(values.count ?? 0, SessionStateLimits.maximumDocumentsPerPane))
        while !values.isAtEnd {
            guard documents.count < SessionStateLimits.maximumDocumentsPerPane else {
                throw DecodingError.dataCorruptedError(
                    forKey: .documents,
                    in: container,
                    debugDescription: "A pane contains too many saved documents.")
            }
            documents.append(try values.decode(DocumentSnapshot.self))
        }
        self.init(
            pane: pane,
            documents: documents,
            selection: try container.decodeIfPresent(UUID.self, forKey: .selection),
            selectedDocumentURL: try container.decodeIfPresent(
                String.self, forKey: .selectedDocumentURL))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pane, forKey: .pane)
        try container.encode(documents, forKey: .documents)
        try container.encodeIfPresent(selection, forKey: .selection)
        try container.encodeIfPresent(selectedDocumentURL, forKey: .selectedDocumentURL)
    }

    private static func canonicalDocuments(
        _ documents: [DocumentSnapshot]
    ) -> [DocumentSnapshot] {
        var seen: Set<String> = []
        var result: [DocumentSnapshot] = []
        result.reserveCapacity(min(documents.count, SessionStateLimits.maximumDocumentsPerPane))
        for document in documents {
            guard result.count < SessionStateLimits.maximumDocumentsPerPane,
                let url = SessionCanonical.fileURLString(document.url),
                seen.insert(url).inserted
            else { continue }
            result.append(DocumentSnapshot(url: url))
        }
        return result
    }
}

/// The whole window's shape: the split tree, what each pane holds, which pane
/// has the keyboard, and the vault in the navigator.
public struct WorkspaceSnapshot: Codable, Equatable, Sendable {
    public let layout: SplitLayout
    public let panes: [PaneSnapshot]
    public let focusedPane: PaneID
    /// Absolute path of the vault root, when one is open.
    public let vaultRoot: String?

    public init(
        layout: SplitLayout,
        panes: [PaneSnapshot],
        focusedPane: PaneID,
        vaultRoot: String?
    ) {
        self.layout = layout
        let layoutPanes = layout.panes
        let live = Set(layoutPanes)
        var firstEntry: [PaneID: PaneSnapshot] = [:]
        for entry in panes where live.contains(entry.pane) && firstEntry[entry.pane] == nil {
            firstEntry[entry.pane] = entry
        }

        var documentsRemaining = SessionStateLimits.maximumDocuments
        var canonicalPanes: [PaneSnapshot] = []
        canonicalPanes.reserveCapacity(layoutPanes.count)
        for pane in layoutPanes {
            let source = firstEntry[pane]
            let documents = Array(
                (source?.documents ?? []).prefix(
                    min(SessionStateLimits.maximumDocumentsPerPane, documentsRemaining)))
            documentsRemaining -= documents.count
            let selected = source?.selectedDocumentURL.flatMap(SessionCanonical.fileURLString)
            canonicalPanes.append(
                PaneSnapshot(
                    pane: pane,
                    documents: documents,
                    selection: source?.selection,
                    selectedDocumentURL: selected))
        }
        self.panes = canonicalPanes
        self.focusedPane = live.contains(focusedPane) ? focusedPane : layoutPanes[0]
        self.vaultRoot = vaultRoot.flatMap(SessionCanonical.fileURLString)
    }

    private enum CodingKeys: String, CodingKey {
        case layout
        case panes
        case focusedPane
        case vaultRoot
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let layout = try container.decode(SplitLayout.self, forKey: .layout)
        var paneContainer = try container.nestedUnkeyedContainer(forKey: .panes)
        if let count = paneContainer.count, count > SplitLayout.maximumPanes {
            throw DecodingError.dataCorruptedError(
                forKey: .panes,
                in: container,
                debugDescription: "A workspace contains too many pane entries.")
        }
        var panes: [PaneSnapshot] = []
        panes.reserveCapacity(min(paneContainer.count ?? 0, SplitLayout.maximumPanes))
        while !paneContainer.isAtEnd {
            guard panes.count < SplitLayout.maximumPanes else {
                throw DecodingError.dataCorruptedError(
                    forKey: .panes,
                    in: container,
                    debugDescription: "A workspace contains too many pane entries.")
            }
            panes.append(try paneContainer.decode(PaneSnapshot.self))
        }
        self.init(
            layout: layout,
            panes: panes,
            focusedPane: try container.decode(PaneID.self, forKey: .focusedPane),
            vaultRoot: try container.decodeIfPresent(String.self, forKey: .vaultRoot))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(layout, forKey: .layout)
        try container.encode(panes, forKey: .panes)
        try container.encode(focusedPane, forKey: .focusedPane)
        try container.encodeIfPresent(vaultRoot, forKey: .vaultRoot)
    }
}

private enum SessionCanonical {
    static func fileURLString(_ raw: String) -> String? {
        guard raw.utf8.count <= SessionStateLimits.maximumURLBytes,
            !raw.unicodeScalars.contains(where: { $0.value == 0 }),
            let url = URL(string: raw),
            BoundedRegularFileReader.hasLocalFileAuthority(url),
            !url.path.unicodeScalars.contains(where: { $0.value == 0 })
        else { return nil }
        return url.standardizedFileURL.absoluteString
    }
}

/// Atomic process-local one-shot used by ``SessionStore``. Kept as a small
/// concrete type so contention can be stress-tested without resetting the
/// real launch claim.
final class SessionRestoreClaim: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

/// Serial off-main lane for bounded session encoding and UserDefaults I/O.
/// Multiple windows still use last-arrival-wins semantics, but their writes
/// cannot overlap or complete out of actor order.
public actor SessionPersistenceLane {
    public static let shared = SessionPersistenceLane()

    public init() {}

    public func save(_ snapshot: WorkspaceSnapshot) {
        SessionStore.save(snapshot)
    }
}

/// Where snapshots live.
///
/// User defaults rather than a state-restoration archive: this is one small
/// value per window shape change, and `NSWindow` restoration would also want
/// to own the window frames it has no opinion about here.
///
/// One slot, last writer wins — the shape the app was last seen with is what
/// a relaunch brings back. The load side is where windows differ, and
/// ``claimRestore`` is the rule: exactly **one** window per launch may read
/// the snapshot. Without that claim, a second window (⌘N, a Finder
/// double-click) restored the first window's tabs over its own, which read
/// as the app opening somebody else's work.
public enum SessionStore {
    static let key = "session.workspace"

    /// Process-wide, so the claim survives SwiftUI building several
    /// workspaces in one launch. `clear()` deliberately does not reset it: a
    /// second window in the same process must never clone the first window.
    private static let restoreClaim = SessionRestoreClaim()

    public static func save(_ snapshot: WorkspaceSnapshot) {
        let data: Data
        do {
            data = try JSONEncoder().encode(snapshot)
        } catch {
            reject(.workspaceSessionSaveRejected)
            clear()
            return
        }
        guard data.count <= SessionStateLimits.maximumEncodedBytes,
            hasBoundedJSONNesting(data)
        else {
            reject(.workspaceSessionSaveRejected, byteCount: data.count)
            clear()
            return
        }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Reads the stored session, once per process.
    ///
    /// The first caller wins and later callers get `nil` — which is what
    /// makes a newly opened *window* start empty instead of cloned. Returns
    /// nil for corrupt or missing data either way. Missing data is normal;
    /// rejected data is removed and recorded in privacy-safe diagnostics so
    /// support can distinguish it from an intentionally empty launch.
    public static func claimRestore() -> WorkspaceSnapshot? {
        guard restoreClaim.claim() else { return nil }
        return load()
    }

    public static func load() -> WorkspaceSnapshot? {
        guard let stored = UserDefaults.standard.object(forKey: key) else { return nil }
        guard let data = stored as? Data else {
            reject(.workspaceSessionRestoreRejected)
            clear()
            return nil
        }
        guard data.count <= SessionStateLimits.maximumEncodedBytes,
            hasBoundedJSONNesting(data),
            let snapshot = try? JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
        else {
            reject(.workspaceSessionRestoreRejected, byteCount: data.count)
            clear()
            return nil
        }
        return snapshot
    }

    public static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func reject(_ code: DiagnosticCode, byteCount: Int? = nil) {
        let metadata: DiagnosticMetadata
        if let byteCount {
            metadata = DiagnosticMetadata([
                .byteCount: .integer(Int64(clamping: byteCount))
            ])
        } else {
            metadata = DiagnosticMetadata()
        }
        DiagnosticsEmitter.shared.emit(
            severity: .warning,
            subsystem: .workspace,
            code: code,
            operationID: DiagnosticOperationID(),
            metadata: metadata)
    }

    /// Byte-level preflight keeps deeply nested ignored JSON from reaching
    /// Foundation's recursive decoder. Braces inside strings and escaped
    /// quotes do not contribute to structural depth.
    private static func hasBoundedJSONNesting(_ data: Data) -> Bool {
        var depth = 0
        var inString = false
        var escaped = false

        for byte in data {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5C {  // backslash
                    escaped = true
                } else if byte == 0x22 {  // quote
                    inString = false
                }
                continue
            }

            switch byte {
            case 0x22:  // quote
                inString = true
            case 0x7B, 0x5B:  // { [
                depth += 1
                guard depth <= SessionStateLimits.maximumJSONNestingDepth else {
                    return false
                }
            case 0x7D, 0x5D:  // } ]
                depth -= 1
                guard depth >= 0 else { return false }
            default:
                break
            }
        }
        return depth == 0 && !inString && !escaped
    }
}
