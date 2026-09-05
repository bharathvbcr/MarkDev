//
//  EditorSurfaceRegistry.swift
//  MarkDevKit
//
//  Identity-checked ownership of the native editors mounted in one window.
//

import Foundation

/// Opaque ownership of one mounted ``MarkdownTextView``.
public struct EditorSurfaceMountToken: Hashable, Sendable {
    fileprivate let id: UUID

    fileprivate init(id: UUID) { self.id = id }
}

/// Weak, identity-checked pane-to-editor registry.
///
/// The registry never decides keyboard focus. Mount only makes a native view
/// reachable; a separate focus callback must prove that its token is still the
/// current mount before the workspace or writing tools follow it.
@MainActor
public final class EditorSurfaceRegistry {
    private final class WeakSurface {
        weak var value: MarkdownTextView?

        init(_ value: MarkdownTextView) { self.value = value }
    }

    private struct Entry {
        let token: EditorSurfaceMountToken
        let surface: WeakSurface
    }

    private var entries: [PaneID: Entry] = [:]

    public init() {}

    /// Installs a new mount and invalidates the previous token for this pane.
    @discardableResult
    public func mount(
        _ surface: MarkdownTextView,
        in pane: PaneID
    ) -> EditorSurfaceMountToken {
        pruneReleasedSurfaces()
        let token = EditorSurfaceMountToken(id: UUID())
        entries[pane] = Entry(token: token, surface: WeakSurface(surface))
        return token
    }

    /// True only for the exact view and token currently mounted in `pane`.
    public func isCurrent(
        _ token: EditorSurfaceMountToken,
        surface: MarkdownTextView,
        in pane: PaneID
    ) -> Bool {
        guard let entry = entries[pane], entry.token == token,
            entry.surface.value === surface
        else { return false }
        return true
    }

    /// Removes only the named mount. A delayed dismantle from an old SwiftUI
    /// representable cannot unregister its successor.
    @discardableResult
    public func unmount(
        _ token: EditorSurfaceMountToken,
        surface: MarkdownTextView,
        in pane: PaneID
    ) -> Bool {
        guard isCurrent(token, surface: surface, in: pane) else { return false }
        entries[pane] = nil
        return true
    }

    public func surface(in pane: PaneID) -> MarkdownTextView? {
        guard let entry = entries[pane], let surface = entry.surface.value else {
            entries[pane] = nil
            return nil
        }
        return surface
    }

    public var mountedSurfaces: [MarkdownTextView] {
        pruneReleasedSurfaces()
        return entries.values.compactMap { $0.surface.value }
    }

    public func prune(keeping panes: Set<PaneID>) {
        entries = entries.filter { panes.contains($0.key) && $0.value.surface.value != nil }
    }

    private func pruneReleasedSurfaces() {
        entries = entries.filter { $0.value.surface.value != nil }
    }
}
