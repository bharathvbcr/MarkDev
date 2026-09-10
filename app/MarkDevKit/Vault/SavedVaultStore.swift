import Foundation
import Observation

/// A remembered folder location, independent of the current window's session.
public struct SavedVault: Identifiable, Equatable, Sendable {
    public let url: URL
    public var id: String { url.path }
    public var name: String { url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent }

    fileprivate init?(_ url: URL) {
        guard url.absoluteString.utf8.count <= SavedVaultStore.maximumURLBytes,
            BoundedRegularFileReader.hasLocalFileAuthority(url),
            // Foundation can leave an encoded NUL undecoded in `path`.
            // Reject its original spelling as well as the decoded scalar.
            !url.absoluteString.contains("%00"),
            !url.path.unicodeScalars.contains(where: { $0.value == 0 })
        else { return nil }
        // The open-vault loader supplies a canonical directory. This lexical
        // normalization also removes trailing slashes and interior dots from
        // stored spellings without checking whether a volume is mounted.
        let path = "/" + url.standardized.path.split(separator: "/").joined(separator: "/")
        self.url = URL(fileURLWithPath: path, isDirectory: true)
    }
}

public enum SavedVaultStoreError: Error, LocalizedError, Sendable {
    case invalidURL
    case listFull
    case unreadableList
    case listTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Only a local vault folder with a supported path can be saved."
        case .listFull:
            "Saved Vaults is full. Remove a saved vault before adding another."
        case .unreadableList:
            "Saved vaults could not be loaded. Reset the saved list to add folders again. Your files will stay in place."
        case .listTooLarge:
            "The saved vault list is too large. Remove an entry before saving another."
        }
    }
}

/// One observable owner shared by all workspace windows. Only folder URLs are
/// persisted; reopening always goes through the existing vault loader, and
/// removing an entry never touches the folder or the workspace session.
@MainActor @Observable
public final class SavedVaultStore {
    public static let shared = SavedVaultStore()
    nonisolated static let key = "vaults.saved"
    nonisolated static let maximumVaults = 50
    nonisolated static let maximumURLBytes = 8_192
    nonisolated static let maximumEncodedBytes = 1_048_576

    public private(set) var vaults: [SavedVault] = []
    public private(set) var loadError: SavedVaultStoreError?
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let stored = defaults.object(forKey: Self.key) else { return }
        do {
            guard let data = stored as? Data, data.count <= Self.maximumEncodedBytes else {
                throw SavedVaultStoreError.unreadableList
            }
            let strings = try JSONDecoder().decode([String].self, from: data)
            guard strings.count <= Self.maximumVaults else {
                throw SavedVaultStoreError.unreadableList
            }
            var seen: Set<String> = []
            var loaded: [SavedVault] = []
            for string in strings {
                guard string.utf8.count <= Self.maximumURLBytes,
                    let url = URL(string: string), let vault = SavedVault(url)
                else { throw SavedVaultStoreError.unreadableList }
                if seen.insert(vault.id).inserted { loaded.append(vault) }
            }
            vaults = loaded
        } catch {
            // Keep rejected storage intact until the user explicitly resets
            // it. A load failure must not look like an intentionally empty list.
            loadError = .unreadableList
        }
    }

    public func contains(_ root: URL) -> Bool {
        guard let vault = SavedVault(root) else { return false }
        return vaults.contains { $0.id == vault.id }
    }

    /// Called with the current vault's root after the loader has opened it.
    public func save(_ root: URL) throws {
        guard loadError == nil else { throw SavedVaultStoreError.unreadableList }
        guard let vault = SavedVault(root) else { throw SavedVaultStoreError.invalidURL }
        guard !vaults.contains(where: { $0.id == vault.id }) else { return }
        guard vaults.count < Self.maximumVaults else { throw SavedVaultStoreError.listFull }
        try persist([vault] + vaults)
    }

    public func remove(_ vault: SavedVault) throws {
        guard loadError == nil else { throw SavedVaultStoreError.unreadableList }
        try persist(vaults.filter { $0.id != vault.id })
    }

    /// Explicit recovery for an unreadable preference, never a folder deletion.
    public func reset() {
        defaults.removeObject(forKey: Self.key)
        vaults = []
        loadError = nil
    }

    private func persist(_ updated: [SavedVault]) throws {
        let data = try JSONEncoder().encode(updated.map { $0.url.absoluteString })
        guard data.count <= Self.maximumEncodedBytes else {
            throw SavedVaultStoreError.listTooLarge
        }
        defaults.set(data, forKey: Self.key)
        vaults = updated
    }
}
