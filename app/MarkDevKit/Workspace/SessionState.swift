//
//  SessionState.swift
//  MarkDevKit
//
//  What a window carries across launches.
//

import Foundation

/// One open document, as it is worth remembering.
///
/// Only file-backed documents survive a relaunch: the text of an untitled tab
/// exists nowhere but memory, and re-opening an empty "Untitled" on launch is
/// not restoration, it is noise.
public struct DocumentSnapshot: Codable, Equatable, Sendable {
    public var url: String

    public init(url: String) {
        self.url = url
    }
}

/// One pane's tabs and which of them is frontmost.
public struct PaneSnapshot: Codable, Equatable, Sendable {
    public var pane: PaneID
    public var documents: [DocumentSnapshot]
    public var selection: UUID?

    public init(pane: PaneID, documents: [DocumentSnapshot], selection: UUID?) {
        self.pane = pane
        self.documents = documents
        self.selection = selection
    }
}

/// The whole window's shape: the split tree, what each pane holds, which pane
/// has the keyboard, and the vault in the navigator.
public struct WorkspaceSnapshot: Codable, Equatable, Sendable {
    public var layout: SplitLayout
    public var panes: [PaneSnapshot]
    public var focusedPane: PaneID
    /// Absolute path of the vault root, when one is open.
    public var vaultRoot: String?

    public init(
        layout: SplitLayout,
        panes: [PaneSnapshot],
        focusedPane: PaneID,
        vaultRoot: String?
    ) {
        self.layout = layout
        self.panes = panes
        self.focusedPane = focusedPane
        self.vaultRoot = vaultRoot
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
    /// workspaces in one launch; guarded, because claims can race only
    /// across threads that are already racing to be first anyway.
    nonisolated(unsafe) private static var restoreClaimed = false

    public static func save(_ snapshot: WorkspaceSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Reads the stored session, once per process.
    ///
    /// The first caller wins and later callers get `nil` — which is what
    /// makes a newly opened *window* start empty instead of cloned. Returns
    /// nil for corrupt or missing data either way; both mean "nothing to
    /// restore", and neither is worth an alert.
    public static func claimRestore() -> WorkspaceSnapshot? {
        guard !restoreClaimed else { return nil }
        restoreClaimed = true
        return load()
    }

    public static func load() -> WorkspaceSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
    }

    public static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
