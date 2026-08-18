//
//  Workspace.swift
//  MarkDevKit
//
//  Panes, their tabs, and the vault they belong to.
//

import Foundation
import SwiftUI

/// One open document in a pane.
public struct OpenDocument: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var url: URL?
    public var text: String
    public var hasUnsavedChanges: Bool
    /// The exact contents last read from or written to disk. Keeping the
    /// baseline lets dirty state clear when an undo returns to it, and lets a
    /// save detect an edit made by another process before overwriting it.
    var persistedText: String?

    public init(id: UUID = UUID(), url: URL? = nil, text: String = "", hasUnsavedChanges: Bool = false) {
        self.id = id
        self.url = url
        self.text = text
        self.hasUnsavedChanges = hasUnsavedChanges
        self.persistedText = url == nil || hasUnsavedChanges ? nil : text
    }

    /// Title for the tab. Untitled documents still need a stable label.
    public var title: String {
        url?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }
}

/// Recoverable document-lifecycle failures surfaced by ``Workspace``.
public enum WorkspaceError: Error, Equatable, LocalizedError {
    case noDocument
    case paneUnavailable
    case needsSaveDestination
    case destinationAlreadyOpen(URL)
    case destinationExists(URL)
    case documentChangedOnDisk(URL)
    case unsupportedLocation(URL)

    public var errorDescription: String? {
        switch self {
        case .noDocument:
            "There is no document to save."
        case .paneUnavailable:
            "The target editor is no longer open."
        case .needsSaveDestination:
            "Choose a name and location before saving this document."
        case .destinationAlreadyOpen(let url):
            "\(url.lastPathComponent) is already open in this workspace."
        case .destinationExists(let url):
            "\(url.lastPathComponent) already exists."
        case .documentChangedOnDisk(let url):
            "\(url.lastPathComponent) changed on disk. Reload it or use Save As to preserve both versions."
        case .unsupportedLocation(let url):
            "MarkDev can only open files on this Mac, and \(url.scheme ?? "that location") is not one."
        }
    }
}

/// The file boundary for editor-targeted drops.
public enum MarkdownDropPolicy {
    /// Whether `url` is a Markdown file type declared by MarkDev.
    ///
    /// A directory named `Archive.md` is still a directory and must remain a
    /// vault drop rather than being sent through the document reader.
    public static func accepts(_ url: URL) -> Bool {
        guard FileTree.isMarkdown(url), !url.hasDirectoryPath else {
            return false
        }
        return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
    }
}

/// The documents open in one pane, and which is frontmost.
public struct PaneState: Sendable, Equatable {
    public var documents: [OpenDocument]
    public var selection: OpenDocument.ID?

    public init(documents: [OpenDocument] = [], selection: OpenDocument.ID? = nil) {
        self.documents = documents
        self.selection = selection
    }

    public var current: OpenDocument? {
        documents.first { $0.id == selection } ?? documents.first
    }
}

/// The whole window: a split layout, the panes it contains, and the vault
/// root the navigator shows.
///
/// Observable so SwiftUI tracks it, but the interesting logic — opening a
/// document that is already open, closing the last tab in a pane — lives in
/// plain methods that can be tested without a view.
@MainActor
@Observable
public final class Workspace {
    public private(set) var layout: SplitLayout
    public private(set) var panes: [PaneID: PaneState]
    public var focusedPane: PaneID
    public var vaultRoot: URL?

    public init(vaultRoot: URL? = nil) {
        let first = PaneID()
        self.layout = SplitLayout(pane: first)
        self.panes = [first: PaneState(documents: [OpenDocument()], selection: nil)]
        self.focusedPane = first
        self.vaultRoot = vaultRoot

        if let document = panes[first]?.documents.first {
            panes[first]?.selection = document.id
        }
    }

    /// Binding for the split view, so divider drags write straight back.
    public var layoutBinding: Binding<SplitLayout> {
        Binding(get: { self.layout }, set: { self.layout = $0 })
    }

    public func state(for pane: PaneID) -> PaneState {
        panes[pane] ?? PaneState()
    }

    /// The document currently shown in `pane`.
    public func document(in pane: PaneID) -> OpenDocument? {
        panes[pane]?.current
    }

    /// Each modified document exactly once, even if a split shows it in
    /// several panes. This is the authoritative close/quit review list.
    public var documentsWithUnsavedChanges: [OpenDocument] {
        allDocuments.filter(\.hasUnsavedChanges)
    }

    /// A live pane containing `document`, in stable layout order.
    public func pane(containing document: OpenDocument.ID) -> PaneID? {
        layout.panes.first { pane in
            panes[pane]?.documents.contains(where: { $0.id == document }) == true
        }
    }

    // MARK: - Documents

    /// Creates and selects a fresh untitled document in `pane`.
    ///
    /// The initial pristine tab already represents exactly that state, so it
    /// is reused instead of accumulating indistinguishable empty tabs.
    @discardableResult
    public func newDocument(in pane: PaneID) -> OpenDocument.ID? {
        guard var state = panes[pane] else { return nil }
        if state.documents.count == 1, state.documents[0].isPristineUntitled {
            state.selection = state.documents[0].id
            panes[pane] = state
            return state.selection
        }

        let document = OpenDocument()
        state.documents.append(document)
        state.selection = document.id
        panes[pane] = state
        return document.id
    }

    /// Opens `url` in `pane`, focusing it if already open there.
    ///
    /// Reusing an open tab rather than stacking duplicates is the behaviour
    /// every editor has; opening the same note five times is never intended.
    public func open(_ url: URL, in pane: PaneID) throws {
        guard var state = panes[pane] else { return }

        let document = try resolvedDocument(for: url)
        if let existing = state.documents.first(where: { $0.id == document.id }) {
            state.selection = existing.id
            panes[pane] = state
            return
        }
        if state.documents.count == 1, state.documents[0].isPristineUntitled {
            state.documents[0] = document
        } else {
            state.documents.append(document)
        }
        state.selection = document.id
        panes[pane] = state
    }

    /// Opens `url` in a new pane beside `pane`.
    ///
    /// File resolution happens before layout mutation. A missing, unreadable,
    /// or non-UTF-8 drop therefore cannot leave an empty split behind. If the
    /// document is already open, the new pane shares its canonical identity so
    /// edits continue to propagate between views.
    @discardableResult
    public func open(
        _ url: URL,
        beside pane: PaneID,
        edge: SplitEdge = .trailing
    ) throws -> PaneID {
        guard panes[pane] != nil, layout.panes.contains(pane) else {
            throw WorkspaceError.paneUnavailable
        }
        let document = try resolvedDocument(for: url)

        let new = PaneID()
        layout.split(pane, edge: edge, with: new)
        guard layout.panes.contains(new) else {
            throw WorkspaceError.paneUnavailable
        }
        panes[new] = PaneState(documents: [document], selection: document.id)
        focusedPane = new
        return new
    }

    /// Updates the text of the document shown in `pane`.
    public func updateText(_ text: String, in pane: PaneID) {
        guard let state = panes[pane], let current = state.current else { return }
        guard let index = state.documents.firstIndex(where: { $0.id == current.id }) else { return }
        guard state.documents[index].text != text else { return }

        var document = state.documents[index]
        document.text = text
        document.hasUnsavedChanges = document.persistedText.map { $0 != text } ?? !text.isEmpty
        propagate(document)
    }

    /// Atomically saves the selected document, optionally assigning a new URL.
    ///
    /// The original URL is guarded by an exact content comparison with the
    /// version read from disk. This intentionally fails closed if another app
    /// edited or removed the file while it was open.
    @discardableResult
    public func save(
        in pane: PaneID,
        to requestedURL: URL? = nil,
        overwrite: Bool = false
    ) throws -> URL {
        guard let current = document(in: pane) else { throw WorkspaceError.noDocument }
        guard let destination = (requestedURL ?? current.url)?.standardizedFileURL else {
            throw WorkspaceError.needsSaveDestination
        }

        if allDocuments.contains(where: { $0.id != current.id && $0.url == destination }) {
            throw WorkspaceError.destinationAlreadyOpen(destination)
        }

        let isSavingOriginal = current.url?.standardizedFileURL == destination
        if isSavingOriginal {
            let diskText: String
            do {
                diskText = try String(contentsOf: destination, encoding: .utf8)
            } catch {
                throw WorkspaceError.documentChangedOnDisk(destination)
            }
            guard diskText == current.persistedText else {
                throw WorkspaceError.documentChangedOnDisk(destination)
            }
        } else if FileManager.default.fileExists(atPath: destination.path), !overwrite {
            throw WorkspaceError.destinationExists(destination)
        }

        // `atomically: true` writes a sibling temporary file before replacing
        // the destination, so an interrupted write cannot leave a half-file.
        try current.text.write(to: destination, atomically: true, encoding: .utf8)

        var saved = current
        saved.url = destination
        saved.persistedText = saved.text
        saved.hasUnsavedChanges = false
        propagate(saved)
        return destination
    }

    public func select(_ document: OpenDocument.ID, in pane: PaneID) {
        panes[pane]?.selection = document
    }

    /// Closes a tab. A pane left with no tabs gets a fresh empty one rather
    /// than rendering blank.
    public func close(_ document: OpenDocument.ID, in pane: PaneID) {
        guard var state = panes[pane] else { return }
        state.documents.removeAll { $0.id == document }

        if state.documents.isEmpty {
            let replacement = OpenDocument()
            state.documents = [replacement]
            state.selection = replacement.id
        } else if state.selection == document {
            state.selection = state.documents.last?.id
        }
        panes[pane] = state
    }

    /// Whether closing this tab would discard the last in-memory view of a
    /// dirty document. Closing one of several views is always safe.
    public func requiresConfirmationBeforeClosing(
        _ document: OpenDocument.ID,
        in pane: PaneID
    ) -> Bool {
        guard panes[pane]?.documents.contains(where: { $0.id == document }) == true,
              let value = allDocuments.first(where: { $0.id == document }),
              value.hasUnsavedChanges
        else {
            return false
        }
        return documentOccurrences(document) == 1
    }

    // MARK: - Panes

    /// Splits `pane`, carrying its current document into the new one so the
    /// new pane opens on something rather than blank.
    @discardableResult
    public func split(_ pane: PaneID, edge: SplitEdge) -> PaneID {
        let new = PaneID()
        layout.split(pane, edge: edge, with: new)

        let document = panes[pane]?.current ?? OpenDocument()
        panes[new] = PaneState(documents: [document], selection: document.id)
        focusedPane = new
        return new
    }

    /// Closes a pane and forgets its state.
    public func closePane(_ pane: PaneID) {
        guard layout.close(pane) else { return }
        panes[pane] = nil
        if focusedPane == pane {
            focusedPane = layout.panes.first ?? focusedPane
        }
    }

    /// Moves focus `offset` panes along, in visual order, wrapping at both
    /// ends.
    ///
    /// Splitting is the only way focus moved between panes before this, which
    /// left clicking as the sole way back — a keyboard user could open a split
    /// and then not reach one half of it. Wrapping matters for the same reason
    /// it does in the palette: a held key should never dead-end.
    public func focusPane(offset: Int) {
        let order = layout.panes
        guard order.count > 1 else { return }
        // An unknown focused pane (mid-close, before pruning) starts from the
        // first, so the shortcut still moves rather than doing nothing.
        let current = order.firstIndex(of: focusedPane) ?? 0
        let next = ((current + offset) % order.count + order.count) % order.count
        focusedPane = order[next]
    }

    /// Discards state for panes no longer in the layout.
    ///
    /// Without this the dictionary grows for the lifetime of the window,
    /// holding the full text of every document ever opened in a closed pane.
    public func pruneOrphanedPanes() {
        let live = Set(layout.panes)
        panes = panes.filter { live.contains($0.key) }
    }

    // MARK: - Canonical document identity

    /// One representative of each document identity across all panes.
    private var allDocuments: [OpenDocument] {
        var seen: Set<OpenDocument.ID> = []
        return layout.panes.compactMap { panes[$0] }
            .flatMap(\.documents)
            .filter { seen.insert($0.id).inserted }
    }

    /// Returns the one in-memory identity for `url`, loading it when needed.
    ///
    /// This is the canonical read boundary for both ordinary opens and drops.
    /// Keeping it ahead of any pane mutation is what makes open failure atomic.
    private func resolvedDocument(for requestedURL: URL) throws -> OpenDocument {
        // Every open — Finder, a drop, a wikilink, a URL handed to the app —
        // arrives here, so this is where a location that is not a file on this
        // machine is refused. `String(contentsOf:)` will happily take an
        // `https:` URL and fetch it, synchronously, on the main actor: opening
        // a note must never become a network request.
        guard requestedURL.isFileURL else {
            throw WorkspaceError.unsupportedLocation(requestedURL)
        }
        let url = requestedURL.standardizedFileURL
        if let existing = allDocuments.first(where: { $0.url == url }) {
            return existing
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        return OpenDocument(url: url, text: text)
    }

    /// Replaces every view of `document` so split panes can never drift.
    private func propagate(_ document: OpenDocument) {
        for pane in Array(panes.keys) {
            guard var state = panes[pane] else { continue }
            var changed = false
            for index in state.documents.indices where state.documents[index].id == document.id {
                state.documents[index] = document
                changed = true
            }
            if changed { panes[pane] = state }
        }
    }

    private func documentOccurrences(_ document: OpenDocument.ID) -> Int {
        panes.values.reduce(into: 0) { count, state in
            count += state.documents.lazy.filter { $0.id == document }.count
        }
    }
}

private extension OpenDocument {
    var isPristineUntitled: Bool {
        url == nil && text.isEmpty && !hasUnsavedChanges
    }
}
