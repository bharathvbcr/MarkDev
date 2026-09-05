//
//  VaultIndexRegistry.swift
//  MarkDevKit
//
//  One index per vault root, however many windows are open on it.
//

import Foundation

enum VaultIndexRegistryError: Error, Equatable {
    case busy
}

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

    typealias VaultOpenImplementation = @MainActor @Sendable (URL) async throws -> VaultIndex

    private final class WeakIndex {
        weak var value: VaultIndex?

        init(_ value: VaultIndex) {
            self.value = value
        }
    }

    private var indexes: [URL: WeakIndex] = [:]
    private let maximumConcurrentOpens: Int
    private let openImplementation: VaultOpenImplementation
    private var activeOpenCount = 0

    init(
        maximumConcurrentOpens: Int = 4,
        open: @escaping VaultOpenImplementation = { root in
            let index = VaultIndex()
            try await index.openAsync(root)
            return index
        }
    ) {
        precondition((1...8).contains(maximumConcurrentOpens))
        self.maximumConcurrentOpens = maximumConcurrentOpens
        openImplementation = open
    }

    /// The shared index for `root`, with canonicalization and the complete
    /// Rust scan outside MainActor. Concurrent misses are finite; if two calls
    /// race for one root, only the first completed live index is retained.
    public func indexAsync(for root: URL) async throws -> VaultIndex {
        try Task.checkCancellation()
        let normalizer = Task.detached(priority: .userInitiated) {
            let directory = try SecureLocalDirectoryHandle(
                opening: root,
                cancellationCheck: { Task.isCancelled })
            return directory.url.standardizedFileURL
        }
        let key: URL
        do {
            key = try await withTaskCancellationHandler {
                try await normalizer.value
            } onCancel: {
                normalizer.cancel()
            }
        } catch SecureLocalFileError.cancelled {
            throw CancellationError()
        }
        try Task.checkCancellation()

        indexes = indexes.filter { $0.value.value != nil }
        if let existing = indexes[key]?.value { return existing }
        guard activeOpenCount < maximumConcurrentOpens else {
            throw VaultIndexRegistryError.busy
        }
        activeOpenCount += 1
        defer { activeOpenCount -= 1 }

        let fresh = try await openImplementation(key)
        try Task.checkCancellation()
        guard fresh.root?.standardizedFileURL == key else {
            throw VaultIndexError.superseded
        }
        indexes = indexes.filter { $0.value.value != nil }
        if let existing = indexes[key]?.value { return existing }
        indexes[key] = WeakIndex(fresh)
        return fresh
    }

    /// The shared index for `root`, opening it if nobody has yet.
    ///
    /// The key is normalized twice: `NSString.standardizingPath` first,
    /// because `URL.standardizedFileURL` leaves *interior* `.` components in
    /// place (`/vault/./notes` stayed three components deep and got a second,
    /// duplicate index), then symlink resolution so `/var` vs `/private/var`
    /// spellings of one folder meet.
    public func index(for root: URL) -> VaultIndex {
        guard BoundedRegularFileReader.hasLocalFileAuthority(root) else {
            return VaultIndex()
        }
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
