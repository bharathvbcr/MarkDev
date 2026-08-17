//
//  TerminalSessions.swift
//  MarkDevKit
//
//  The shells that exist, independent of whether the drawer is on screen.
//

import Foundation
import Observation

/// One shell, and everything about it that is not the pty itself.
public struct TerminalSessionState: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// Where and what to launch. Fixed for the session's life: a running
    /// shell is never relocated, so changing directory means a new session.
    public let config: TerminalSession
    /// What the tab shows — the folder name, or whatever the shell sets via
    /// the title escape sequence.
    public var title: String
    /// How the shell ended, once it has.
    public var exit: TerminalExit?
    /// Bumped to relaunch in place. The host view watches it; nothing else
    /// restarts a shell, so a restart is always an explicit act.
    public var generation: Int

    public init(
        id: UUID = UUID(),
        config: TerminalSession,
        title: String? = nil,
        exit: TerminalExit? = nil,
        generation: Int = 0
    ) {
        self.id = id
        self.config = config
        self.title = title ?? (config.workingDirectory as NSString).lastPathComponent
        self.exit = exit
        self.generation = generation
    }

    /// Whether the shell is still running.
    public var isLive: Bool { exit == nil }
}

/// Why a terminal could not be opened.
public struct TerminalOpenFailure: Error, Equatable, Sendable {
    public let reason: String
    public init(reason: String) { self.reason = reason }
}

/// Every open shell, and which one is showing.
///
/// # Why this is not state inside the drawer
///
/// It was, and that made two things impossible. Hiding the drawer destroyed
/// the view, which killed the pty — so ⌘J twice threw away a running build.
/// And a shell has exactly one working directory for its whole life, so
/// "open a terminal in *this* folder" had nowhere to put a second one.
///
/// Holding the list above the view fixes both: the drawer becomes a renderer
/// of sessions that outlive it, and opening a folder is appending to a list
/// rather than relocating something already running.
///
/// The invariants — a selection that always names a session that exists, a
/// close that lands on a neighbour rather than nowhere — are properties of
/// this type, so they are tested against the model rather than by clicking.
@MainActor
@Observable
public final class TerminalSessions {
    /// In creation order.
    public private(set) var sessions: [TerminalSessionState] = []
    /// Always either `nil` or the id of a session in ``sessions``.
    public private(set) var selection: TerminalSessionState.ID?

    /// The most shells that may exist at once.
    ///
    /// Bounded because each one is a real process holding a pty: a stuck
    /// "open terminal here" in a loop would otherwise fork until the system
    /// refused, and the failure would land somewhere far from the cause.
    /// Eight is far above what anyone opens deliberately.
    public static let limit = 8

    public init() {}

    public var current: TerminalSessionState? {
        guard let selection else { return nil }
        return sessions.first { $0.id == selection }
    }

    public var isEmpty: Bool { sessions.isEmpty }

    /// Sessions that are still running.
    public var live: [TerminalSessionState] { sessions.filter(\.isLive) }

    // MARK: - Opening

    /// Opens a new shell and selects it.
    ///
    /// At the limit, an exited session is reclaimed first — those are already
    /// dead and hold nothing. If every session is live, this refuses rather
    /// than killing one: the reader is the only one who knows which of their
    /// running shells is expendable.
    @discardableResult
    public func open(_ config: TerminalSession) throws -> TerminalSessionState.ID {
        if sessions.count >= Self.limit {
            guard let reclaimable = sessions.first(where: { !$0.isLive }) else {
                throw TerminalOpenFailure(
                    reason:
                        "\(Self.limit) terminals are already open. Close one before opening another."
                )
            }
            remove(reclaimable.id)
        }

        let session = TerminalSessionState(config: config)
        sessions.append(session)
        selection = session.id
        return session.id
    }

    /// Shows a shell for `config`, reusing a live one already in that
    /// directory.
    ///
    /// The sidebar's "Open Terminal Here" goes through this. Clicking a folder
    /// twice should bring its shell forward, not fork a second one beside the
    /// first — that is how a session list fills with duplicates nobody meant
    /// to open. The drawer's own "+" calls ``open(_:)`` and always forks.
    @discardableResult
    public func reveal(_ config: TerminalSession) throws -> TerminalSessionState.ID {
        if let existing = sessions.first(where: {
            $0.isLive && $0.config.workingDirectory == config.workingDirectory
        }) {
            selection = existing.id
            return existing.id
        }
        return try open(config)
    }

    // MARK: - Mutating one session

    public func select(_ id: TerminalSessionState.ID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        selection = id
    }

    /// Closes a session. Selection lands on the next one, or the previous if
    /// there is no next — never on nothing while sessions remain.
    public func close(_ id: TerminalSessionState.ID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = selection == id
        sessions.remove(at: index)

        guard wasSelected else { return }
        guard !sessions.isEmpty else {
            selection = nil
            return
        }
        selection = sessions[min(index, sessions.count - 1)].id
    }

    public func closeAll() {
        sessions.removeAll()
        selection = nil
    }

    /// Relaunches the shell in place, keeping its tab and directory.
    public func restart(_ id: TerminalSessionState.ID) {
        update(id) { session in
            session.generation += 1
            session.exit = nil
        }
    }

    public func setTitle(_ title: String, for id: TerminalSessionState.ID) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(id) { $0.title = trimmed }
    }

    public func markExited(_ exit: TerminalExit, for id: TerminalSessionState.ID) {
        update(id) { $0.exit = exit }
    }

    private func update(
        _ id: TerminalSessionState.ID, _ body: (inout TerminalSessionState) -> Void
    ) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        body(&sessions[index])
    }

    /// Removes without touching the selection. Only ``open(_:)`` reclaims this
    /// way, and it sets the selection itself immediately afterwards.
    private func remove(_ id: TerminalSessionState.ID) {
        sessions.removeAll { $0.id == id }
        if selection == id { selection = sessions.first?.id }
    }
}
