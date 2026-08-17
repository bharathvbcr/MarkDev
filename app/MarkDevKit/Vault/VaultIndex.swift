//
//  VaultIndex.swift
//  MarkDevKit
//
//  Swift access to the Rust vault index.
//

import Foundation

#if canImport(CMarkDev)
    import CMarkDev
#endif

/// A link pointing at the current note.
public struct Backlink: Codable, Identifiable, Sendable, Hashable {
    public let path: String
    public let title: String
    /// The line the link came from, for context.
    public let context: String
    public let line: UInt32
    /// UTF-16 offset of the link in the source note.
    public let offset: UInt32

    public var id: String { "\(path):\(line):\(offset)" }
}

/// A note naming this one without linking to it.
public struct UnlinkedMention: Codable, Identifiable, Sendable, Hashable {
    public let path: String
    public let title: String
    public let context: String
    public let line: UInt32
    public let offset: UInt32

    public var id: String { "\(path):\(line):\(offset)" }
}

/// A full-text search hit.
public struct SearchHit: Codable, Identifiable, Sendable, Hashable {
    public let path: String
    public let title: String
    public let context: String
    public let line: UInt32
    public let score: UInt32

    public var id: String { "\(path):\(line)" }
}

/// A heading, for the outline.
public struct VaultHeading: Codable, Identifiable, Sendable, Hashable {
    public let level: UInt8
    public let text: String
    /// UTF-16 offset, so the editor can scroll straight to it.
    public let offset: UInt32
    public let line: UInt32

    public var id: String { "\(line):\(offset)" }

    public init(level: UInt8, text: String, offset: UInt32, line: UInt32) {
        self.level = level
        self.text = text
        self.offset = offset
        self.line = line
    }
}

/// A tag and how many notes carry it.
public struct TagCount: Codable, Identifiable, Sendable, Hashable {
    public let tag: String
    public let count: UInt32

    public var id: String { tag }
}

/// Where a `[[wikilink]]` points.
public struct LinkResolution: Codable, Sendable, Hashable {
    public let path: String
    /// UTF-16 offset of the anchored heading, when the link had one.
    public let offset: UInt32?
}

/// The indexed vault.
///
/// # Why this boundary is JSON
///
/// The editor crosses the FFI on every keystroke and uses flat struct buffers
/// for it. These queries run when a note is opened or a search is typed —
/// far less often, over nested variable-length data. JSON keeps the boundary
/// small and legible; the cost is invisible at this frequency.
@MainActor
public final class VaultIndex {
    public private(set) var root: URL?
    public private(set) var noteCount: Int = 0

    #if canImport(CMarkDev)
        // All mutation remains main-actor isolated. Deinitialization is
        // nonisolated in Swift 6, so this annotation permits only the final
        // ownership release there; it does not make query methods concurrent.
        nonisolated(unsafe) private var handle: OpaquePointer?
    #endif

    public init() {}

    deinit {
        #if canImport(CMarkDev)
            if let handle { md_vault_free(handle) }
        #endif
    }

    /// Indexes every Markdown file under `root`.
    ///
    /// Walking and parsing happen in Rust, which is fast enough that a
    /// personal vault indexes in the time it takes the window to appear.
    public func open(_ root: URL) {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        #if canImport(CMarkDev)
            if let handle { md_vault_free(handle) }
            handle = root.path.withCString { md_vault_open($0) }
            self.root = root
            noteCount = handle.map { Int(md_vault_note_count($0)) } ?? 0
        #else
            self.root = root
        #endif
    }

    /// Re-indexes one note from text held in the editor rather than on disk,
    /// so backlinks track what is on screen and not the last save.
    public func update(path: String, text: String) {
        #if canImport(CMarkDev)
            guard let handle else { return }
            path.withCString { pathPointer in
                text.withCString { textPointer in
                    md_vault_update(handle, pathPointer, textPointer)
                }
            }
            noteCount = Int(md_vault_note_count(handle))
        #endif
    }

    /// Vault-relative path for `url`, or `nil` when it sits outside the vault.
    public func relativePath(for url: URL) -> String? {
        guard let root else { return nil }
        let rootComponents = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let fileComponents = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard fileComponents.count > rootComponents.count,
              fileComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
        else {
            return nil
        }
        return fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    /// Absolute URL for a vault-relative path.
    public func url(for path: String) -> URL? {
        guard let root, !path.isEmpty, !path.hasPrefix("/") else { return nil }
        let candidate = root.appendingPathComponent(path).standardizedFileURL
        guard relativePath(for: candidate) != nil else { return nil }
        return candidate
    }

    // MARK: - Queries

    public func backlinks(for path: String) -> [Backlink] {
        query(path) { md_vault_backlinks($0, $1) }
    }

    public func unlinkedMentions(for path: String) -> [UnlinkedMention] {
        query(path) { md_vault_unlinked_mentions($0, $1) }
    }

    public func outline(for path: String) -> [VaultHeading] {
        query(path) { md_vault_outline($0, $1) }
    }

    public func tags() -> [TagCount] {
        #if canImport(CMarkDev)
            guard let handle else { return [] }
            return decode(md_vault_tags(handle)) ?? []
        #else
            return []
        #endif
    }

    public func search(_ text: String, limit: Int = 50) -> [SearchHit] {
        #if canImport(CMarkDev)
            guard let handle, !text.isEmpty, limit > 0 else { return [] }
            let boundedLimit = UInt32(min(limit, Int(UInt32.max)))
            return text.withCString { decode(md_vault_search(handle, $0, boundedLimit)) } ?? []
        #else
            return []
        #endif
    }

    /// Resolves a `[[wikilink]]` target and optional `#anchor`.
    public func resolve(target: String, anchor: String? = nil) -> LinkResolution? {
        #if canImport(CMarkDev)
            guard let handle else { return nil }
            return target.withCString { targetPointer -> LinkResolution? in
                guard let anchor else {
                    return decode(md_vault_resolve(handle, targetPointer, nil))
                }
                return anchor.withCString { anchorPointer in
                    decode(md_vault_resolve(handle, targetPointer, anchorPointer))
                }
            }
        #else
            return nil
        #endif
    }

    /// Every note path, for the palette and link autocomplete.
    public func notePaths() -> [String] {
        #if canImport(CMarkDev)
            guard let handle else { return [] }
            return decode(md_vault_note_paths(handle)) ?? []
        #else
            return []
        #endif
    }

    // MARK: - Decoding

    #if canImport(CMarkDev)
        private func query<T: Decodable>(
            _ path: String,
            _ call: (OpaquePointer, UnsafePointer<CChar>) -> UnsafePointer<CChar>?
        ) -> [T] {
            guard let handle else { return [] }
            return path.withCString { decode(call(handle, $0)) } ?? []
        }

        /// Decodes a borrowed C string.
        ///
        /// The pointer belongs to the Rust handle and is only valid until the
        /// next query on it, so it is decoded immediately and never stored.
        private func decode<T: Decodable>(_ pointer: UnsafePointer<CChar>?) -> T? {
            guard let pointer else { return nil }
            let json = String(cString: pointer)
            guard let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(T.self, from: data)
        }
    #else
        private func query<T: Decodable>(_ path: String, _ call: (Never, Never) -> Never?) -> [T] {
            []
        }
    #endif
}

/// A request to scroll an editor to a UTF-16 offset.
///
/// Carries a fresh identity each time so that revealing the *same* offset
/// twice still registers as a new request — clicking one outline row
/// repeatedly should keep working, which an offset-only value would not.
public struct RevealRequest: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let offset: Int

    public init(offset: Int) {
        self.id = UUID()
        self.offset = offset
    }
}
