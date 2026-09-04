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
/// The registry is a weak rendezvous point, not an owner. Windows that overlap
/// share one live index, but closing the last window releases the Rust index
/// and its complete vault corpus instead of retaining every vault ever opened
/// until process exit.
@MainActor
public final class VaultIndexRegistry {
    public static let shared = VaultIndexRegistry()

    private final class WeakIndex {
        weak var value: VaultIndex?

        init(_ value: VaultIndex) {
            self.value = value
        }
    }

    private var indexes: [URL: WeakIndex] = [:]

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

        // Pruning on the only public lookup keeps even the dictionary of dead
        // path keys bounded by currently live vaults plus, at most, the keys
        // released since the previous lookup.
        indexes = indexes.filter { $0.value.value != nil }
        if let existing = indexes[key]?.value {
            return existing
        }
        let fresh = VaultIndex()
        fresh.open(key)
        indexes[key] = WeakIndex(fresh)
        return fresh
    }

    #if DEBUG
        /// Empties the pool. Tests only.
        public func reset() {
            indexes.removeAll()
        }
    #endif
}
