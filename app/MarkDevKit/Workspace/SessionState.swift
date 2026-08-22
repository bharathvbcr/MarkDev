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
/// Keyed per window *role* rather than globally: two windows each remember
/// their last shape, last writer wins on the shared defaults domain, and a
/// single-window launch reads the most recent one. That is deliberately the
/// simplest behaviour that makes reopening the app return to work.
public enum SessionStore {
    static let key = "session.workspace"

    public static func save(_ snapshot: WorkspaceSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    public static func load() -> WorkspaceSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
    }

    public static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
