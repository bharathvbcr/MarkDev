//
//  VaultIndexRegistry.swift
//  MarkDevKit
//
//  One index per vault root, however many windows are open on it.
//

import Foundation

/// Shares one ``VaultIndex`` across every window that has the same vault open.
///
/// Each window used to own its own index, which meant a second window re-walked
/// the whole corpus and held a second copy of it — twice the work and twice
/// the memory for the same files. The registry keys instances by standardized,
/// symlink-resolved root, so two spellings of one folder share; different
/// folders get their own.
///
/// Sharing is safe because everything mutable in `VaultIndex` is `@MainActor`
/// anyway: two windows' updates serialise through the same actor, and the
/// core's own lock guards the Rust side (see ``VaultIndex/coreLock``).
///
/// Indexes live until process exit. A personal-vault index is kilobytes of
/// strings; evicting on last-close would buy nothing and cost a full re-walk
/// when the reader reopens the same vault an hour later.
@MainActor
public final class VaultIndexRegistry {
    public static let shared = VaultIndexRegistry()

    private var indexes: [URL: VaultIndex] = [:]

    private init() {}

    /// The shared index for `root`, opening it if nobody has yet.
    ///
    /// The key is normalized twice: `NSString.standardizingPath` first,
    /// because `URL.standardizedFileURL` leaves *interior* `.` components in
    /// place (`/vault/./notes` stayed three components deep and got a second,
    /// duplicate index), then symlink resolution so `/var` vs `/private/var`
    /// spellings of one folder meet.
    public func index(for root: URL) -> VaultIndex {
        let collapsed = (root.path as NSString).standardizingPath
        let key = URL(fileURLWithPath: collapsed)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        if let existing = indexes[key] {
            return existing
        }
        let fresh = VaultIndex()
        fresh.open(key)
        indexes[key] = fresh
        return fresh
    }

    #if DEBUG
        /// Empties the pool. Tests only.
        public func reset() {
            indexes.removeAll()
        }
    #endif
}
