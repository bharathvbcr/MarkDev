//
//  FileTree.swift
//  MarkDevKit
//
//  The vault's file hierarchy, and the fuzzy matcher used to filter it.
//

import Foundation
import Darwin

/// One entry in the navigator.
public struct FileNode: Identifiable, Sendable, Equatable {
    public let url: URL
    public let isDirectory: Bool
    /// `nil` until a directory is expanded — directories are scanned lazily so
    /// opening a large vault does not stat every file up front.
    public var children: [FileNode]?

    public var id: URL { url }
    public var name: String { url.lastPathComponent }

    /// The name to show in the sidebar.
    ///
    /// `.md` is dropped because the navigator only lists Markdown: repeating
    /// it on every row costs width that note titles need, and truncates the
    /// part that distinguishes them. Any other extension stays, since there it
    /// is the thing that tells two entries apart.
    public var displayName: String {
        guard !isDirectory, url.pathExtension.lowercased() == "md" else { return name }
        return url.deletingPathExtension().lastPathComponent
    }

    public init(url: URL, isDirectory: Bool, children: [FileNode]? = nil) {
        self.url = url
        self.isDirectory = isDirectory
        self.children = children
    }
}

/// Reads a vault directory into ``FileNode`` trees.
public enum FileTree {
    /// Largest note either scanner will hold in memory by default (16 MiB).
    public static let defaultMaximumNoteBytes = MarkdownReadLimits.maximumDocumentBytes
    /// Largest aggregate body-text payload either scanner retains (256 MiB).
    public static let defaultMaximumVaultBytes = 256 * 1_024 * 1_024

    /// Resource bounds shared with the Rust vault's initial scan.
    public struct ScanLimits: Sendable, Equatable {
        public let maxDepth: Int
        public let maxEntries: Int
        public let maxNoteBytes: Int
        public let maxTotalBytes: Int

        public init(
            maxDepth: Int,
            maxEntries: Int,
            maxNoteBytes: Int = FileTree.defaultMaximumNoteBytes,
            maxTotalBytes: Int = FileTree.defaultMaximumVaultBytes
        ) {
            self.maxDepth = max(0, maxDepth)
            self.maxEntries = max(0, maxEntries)
            self.maxNoteBytes = max(0, maxNoteBytes)
            self.maxTotalBytes = max(0, maxTotalBytes)
        }

        public static let standard = ScanLimits(
            maxDepth: 48,
            maxEntries: 100_000,
            maxNoteBytes: FileTree.defaultMaximumNoteBytes,
            maxTotalBytes: FileTree.defaultMaximumVaultBytes)
    }

    /// Files discovered and the exact coverage of that walk.
    public struct ScanResult: Sendable, Equatable {
        public let files: [URL]
        public let visitedEntries: Int
        public let discoveredFiles: Int
        public let discoveredBytes: Int
        public let selectedBytes: Int
        public let skippedSymlinks: Int
        public let unreadableDirectories: Int
        public let unreadableEntries: Int
        public let oversizedFiles: Int
        public let hitDepthLimit: Bool
        public let hitEntryLimit: Bool
        public let hitTotalByteLimit: Bool

        public init(
            files: [URL],
            visitedEntries: Int,
            discoveredFiles: Int? = nil,
            discoveredBytes: Int = 0,
            selectedBytes: Int = 0,
            skippedSymlinks: Int,
            unreadableDirectories: Int,
            unreadableEntries: Int,
            oversizedFiles: Int,
            hitDepthLimit: Bool,
            hitEntryLimit: Bool,
            hitTotalByteLimit: Bool = false
        ) {
            self.files = files
            self.visitedEntries = max(0, visitedEntries)
            self.discoveredFiles = max(files.count, discoveredFiles ?? files.count)
            self.discoveredBytes = max(0, discoveredBytes)
            self.selectedBytes = max(0, selectedBytes)
            self.skippedSymlinks = max(0, skippedSymlinks)
            self.unreadableDirectories = max(0, unreadableDirectories)
            self.unreadableEntries = max(0, unreadableEntries)
            self.oversizedFiles = max(0, oversizedFiles)
            self.hitDepthLimit = hitDepthLimit
            self.hitEntryLimit = hitEntryLimit
            self.hitTotalByteLimit = hitTotalByteLimit
        }

        public var skippedFiles: Int {
            discoveredFiles >= files.count ? discoveredFiles - files.count : 0
        }

        public var isComplete: Bool {
            !hitDepthLimit && !hitEntryLimit && !hitTotalByteLimit && skippedFiles == 0
                && unreadableDirectories == 0 && unreadableEntries == 0 && oversizedFiles == 0
        }
    }

    enum UTF8ReadResult: Sendable, Equatable {
        case text(String)
        case oversized
        case unreadable
    }

    struct OpenRegularFile {
        let handle: FileHandle
        let size: Int64
    }

    /// Extensions the navigator shows. Anything else is noise in a Markdown
    /// tool, and hiding it keeps the sidebar readable in a mixed repository.
    public static let markdownExtensions: Set<String> = [
        "md", "markdown", "mdown", "mdx", "mkd",
    ]

    /// Directories never worth showing in a notes vault.
    public static let ignoredDirectories: Set<String> = [
        ".git", ".build", "node_modules", ".obsidian", ".trash", "DerivedData", "target",
    ]

    /// Lists the immediate children of `url`.
    ///
    /// Directories sort before files, then case-insensitively by name — the
    /// ordering Finder uses, so the sidebar does not feel foreign.
    public static func children(of url: URL, includeAllFiles: Bool = false) -> [FileNode] {
        guard BoundedRegularFileReader.hasLocalFileAuthority(url) else { return [] }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey, .isSymbolicLinkKey]
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else {
            // An unreadable directory shows as empty rather than failing the
            // whole sidebar; permissions vary across a vault.
            return []
        }

        var nodes: [FileNode] = []
        for entry in entries {
            guard let values = try? entry.resourceValues(forKeys: Set(keys)) else { continue }
            // The selected vault's resolved directory is the authority.
            // Navigator aliases are not traversable portals to a different
            // tree, even when they currently happen to point back inside.
            guard values.isSymbolicLink != true else { continue }
            let isDirectory = values.isDirectory ?? false

            if isDirectory {
                guard !ignoredDirectories.contains(entry.lastPathComponent) else { continue }
                nodes.append(FileNode(url: entry, isDirectory: true))
            } else {
                let ext = entry.pathExtension.lowercased()
                guard includeAllFiles || markdownExtensions.contains(ext) else { continue }
                nodes.append(FileNode(url: entry, isDirectory: false))
            }
        }

        return nodes.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// Whether `url` is a file MarkDev can open.
    public static func isMarkdown(_ url: URL) -> Bool {
        markdownExtensions.contains(url.pathExtension.lowercased())
    }

    /// Every Markdown file under `root`, recursively.
    ///
    /// The catch-up sweep's input: FSEvents is lossy around stream birth
    /// (writes racing registration can be dropped outright, measured rather
    /// than assumed), so the watcher needs one full walk to backstop what it
    /// never heard about. Honours ``ignoredDirectories`` and skips hidden
    /// entries, exactly as ``children(of:)`` does — one set of visibility
    /// rules, not two that drift.
    ///
    /// Symlinks are excluded, and traversal is bounded by the same defaults as
    /// the Rust vault scanner. Call ``scanMarkdownFiles(under:limits:)`` when
    /// the consumer must distinguish a complete walk from a capped one.
    public static func markdownFiles(under root: URL) -> [URL] {
        scanMarkdownFiles(under: root).files
    }

    /// Recursively inventories Markdown while carrying proof of coverage.
    public static func scanMarkdownFiles(
        under root: URL, limits: ScanLimits = .standard
    ) -> ScanResult {
        guard BoundedRegularFileReader.hasLocalFileAuthority(root) else {
            return ScanResult(
                files: [],
                visitedEntries: 0,
                skippedSymlinks: 0,
                unreadableDirectories: 1,
                unreadableEntries: 0,
                oversizedFiles: 0,
                hitDepthLimit: false,
                hitEntryLimit: false)
        }
        let fileManager = FileManager.default
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let rootPath = resolvedRoot.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let keys: [URLResourceKey] = [
            .fileSizeKey, .isDirectoryKey, .isHiddenKey, .isRegularFileKey, .isSymbolicLinkKey,
        ]

        var files: [URL] = []
        var visitedEntries = 0
        var discoveredFiles = 0
        var discoveredBytes = 0
        var selectedBytes = 0
        var skippedSymlinks = 0
        var unreadableDirectories = 0
        var unreadableEntries = 0
        var oversizedFiles = 0
        var hitDepthLimit = false
        var hitEntryLimit = false
        var hitTotalByteLimit = false
        var pending: [(url: URL, depth: Int)] = [(resolvedRoot, 0)]

        directoryWalk: while let directory = pending.popLast() {
            let directoryValues: URLResourceValues
            do {
                directoryValues = try directory.url.resourceValues(forKeys: [
                    .isDirectoryKey, .isSymbolicLinkKey,
                ])
            } catch {
                unreadableDirectories = saturatedAdd(unreadableDirectories, 1)
                continue
            }
            let resolvedDirectory = directory.url.resolvingSymlinksInPath().standardizedFileURL.path
            guard directoryValues.isSymbolicLink != true,
                resolvedDirectory == rootPath || resolvedDirectory.hasPrefix(rootPrefix)
            else {
                skippedSymlinks = saturatedAdd(skippedSymlinks, 1)
                continue
            }
            guard directoryValues.isDirectory == true else {
                unreadableDirectories = saturatedAdd(unreadableDirectories, 1)
                continue
            }

            guard
                let enumerator = fileManager.enumerator(
                    at: directory.url,
                    includingPropertiesForKeys: keys,
                    options: [.skipsPackageDescendants, .skipsSubdirectoryDescendants],
                    errorHandler: { _, _ in
                        unreadableDirectories = saturatedAdd(unreadableDirectories, 1)
                        return false
                    })
            else {
                unreadableDirectories = saturatedAdd(unreadableDirectories, 1)
                continue
            }

            while let entry = enumerator.nextObject() as? URL {
                guard visitedEntries < limits.maxEntries else {
                    hitEntryLimit = true
                    break directoryWalk
                }
                visitedEntries = saturatedAdd(visitedEntries, 1)

                let name = entry.lastPathComponent
                let values: URLResourceValues
                do {
                    values = try entry.resourceValues(forKeys: Set(keys))
                } catch {
                    unreadableEntries = saturatedAdd(unreadableEntries, 1)
                    continue
                }

                if values.isSymbolicLink == true {
                    skippedSymlinks = saturatedAdd(skippedSymlinks, 1)
                    continue
                }

                if values.isHidden == true || name.hasPrefix(".") || ignoredDirectories.contains(name) {
                    continue
                }

                let resolvedEntry = entry.resolvingSymlinksInPath().standardizedFileURL
                let entryPath = resolvedEntry.path
                guard entryPath == rootPath || entryPath.hasPrefix(rootPrefix) else {
                    skippedSymlinks = saturatedAdd(skippedSymlinks, 1)
                    continue
                }

                if values.isDirectory == true {
                    if directory.depth >= limits.maxDepth {
                        hitDepthLimit = true
                    } else {
                        pending.append((entry, directory.depth + 1))
                    }
                    continue
                }

                guard values.isRegularFile == true, isMarkdown(entry) else { continue }
                discoveredFiles = saturatedAdd(discoveredFiles, 1)
                guard let fileSize = values.fileSize else {
                    unreadableEntries = saturatedAdd(unreadableEntries, 1)
                    continue
                }
                guard fileSize >= 0 else {
                    unreadableEntries = saturatedAdd(unreadableEntries, 1)
                    continue
                }
                discoveredBytes = saturatedAdd(discoveredBytes, fileSize)
                guard fileSize <= limits.maxNoteBytes else {
                    oversizedFiles = saturatedAdd(oversizedFiles, 1)
                    continue
                }
                let (proposedBytes, overflow) = selectedBytes.addingReportingOverflow(fileSize)
                guard !overflow, proposedBytes <= limits.maxTotalBytes else {
                    hitTotalByteLimit = true
                    continue
                }
                selectedBytes = proposedBytes
                files.append(entry.standardizedFileURL)
            }
        }

        // The Rust index presents paths lexically as well, so callers receive
        // stable ordering independent of filesystem enumeration order.
        files.sort { $0.path < $1.path }
        return ScanResult(
            files: files,
            visitedEntries: visitedEntries,
            discoveredFiles: discoveredFiles,
            discoveredBytes: discoveredBytes,
            selectedBytes: selectedBytes,
            skippedSymlinks: skippedSymlinks,
            unreadableDirectories: unreadableDirectories,
            unreadableEntries: unreadableEntries,
            oversizedFiles: oversizedFiles,
            hitDepthLimit: hitDepthLimit,
            hitEntryLimit: hitEntryLimit,
            hitTotalByteLimit: hitTotalByteLimit)
    }

    /// Reads at most `maximumBytes + 1`, refusing symlinks in any path
    /// component on macOS. The second check catches a file that grows after
    /// the inventory's metadata snapshot.
    static func readUTF8File(
        at url: URL, inside root: URL, maximumBytes: Int
    ) -> UTF8ReadResult {
        let maximumBytes = max(0, maximumBytes)
        guard
            BoundedRegularFileReader.hasLocalFileAuthority(url),
            BoundedRegularFileReader.hasLocalFileAuthority(root),
            let values = try? url.resourceValues(forKeys: [
                .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
            ]),
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            let fileSize = values.fileSize
        else {
            return .unreadable
        }
        guard fileSize <= maximumBytes else { return .oversized }

        // `URL.resolvingSymlinksInPath()` intentionally leaves macOS's
        // `/var -> /private/var` system alias unresolved. Canonicalise both
        // paths with realpath so O_NOFOLLOW_ANY can reject attacker-controlled
        // aliases without also rejecting an ordinary vault below /var.
        guard let canonicalRoot = canonicalExistingPath(root),
            let canonicalFile = canonicalExistingPath(url)
        else {
            return .unreadable
        }
        let rootPrefix = canonicalRoot.hasSuffix("/") ? canonicalRoot : canonicalRoot + "/"
        guard canonicalFile.hasPrefix(rootPrefix) else { return .unreadable }

        guard let opened = openVerifiedRegularFile(
            at: URL(fileURLWithPath: canonicalFile, isDirectory: false)
        ) else { return .unreadable }
        guard opened.size >= 0 else { return .unreadable }
        guard opened.size <= Int64(maximumBytes) else { return .oversized }
        let handle = opened.handle

        var data = Data()
        let readCeiling = maximumBytes == Int.max ? Int.max : maximumBytes + 1
        do {
            while data.count < readCeiling {
                let count = min(64 * 1024, readCeiling - data.count)
                guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { break }
                data.append(chunk)
            }
            try handle.close()
        } catch {
            try? handle.close()
            return .unreadable
        }
        guard data.count <= maximumBytes else { return .oversized }
        guard let text = String(data: data, encoding: .utf8) else { return .unreadable }
        return .text(text)
    }

    /// Opens without waiting on special files, then validates the object bound
    /// to the descriptor. This closes the regular-file-to-FIFO swap between
    /// URL metadata and `open(2)` without trusting either pre-open snapshot.
    static func openVerifiedRegularFile(at url: URL) -> OpenRegularFile? {
        guard let canonicalPath = canonicalExistingPath(url) else { return nil }
        let descriptor = canonicalPath.withCString { path -> Int32 in
            let noFollowAny: Int32 = 0x2000_0000
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | noFollowAny)
        }
        guard descriptor >= 0 else { return nil }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
            status.st_mode & S_IFMT == S_IFREG
        else {
            Darwin.close(descriptor)
            return nil
        }
        return OpenRegularFile(
            handle: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true),
            size: status.st_size)
    }

    private static func canonicalExistingPath(_ url: URL) -> String? {
        guard BoundedRegularFileReader.hasLocalFileAuthority(url) else { return nil }
        return url.withUnsafeFileSystemRepresentation { path -> String? in
            guard let path else { return nil }
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            return buffer.withUnsafeMutableBufferPointer { resolved in
                guard let baseAddress = resolved.baseAddress,
                    Darwin.realpath(path, baseAddress) != nil
                else {
                    return nil
                }
                return String(cString: baseAddress)
            }
        }
    }

    private static func saturatedAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }
}

/// Subsequence matching for the navigator filter and the command palette.
///
/// Deliberately a subsequence match rather than a substring one: typing
/// `mdv` should find `MarkDevView`, which is the whole point of fuzzy
/// filtering. Scoring favours matches at word starts and consecutive runs, so
/// the obvious candidate ranks first instead of merely appearing somewhere in
/// the list.
public enum FuzzyMatch {
    /// A match and its score, or `nil` when `query` is not a subsequence.
    public static func score(_ candidate: String, query: String) -> Int? {
        guard !query.isEmpty else { return 0 }

        let haystack = Array(candidate.lowercased())
        let needle = Array(query.lowercased())
        guard needle.count <= haystack.count else { return nil }

        let greedy = greedyScore(haystack, needle)
        let acronym = acronymScore(haystack, needle)

        switch (greedy, acronym) {
        case (nil, nil): return nil
        case (let g?, nil): return g
        case (nil, let a?): return a
        case (let g?, let a?): return max(g, a)
        }
    }

    /// Matches only at word starts, so `mn` finds `Meeting Notes`.
    ///
    /// The greedy pass alone cannot do this: scanning left to right it takes
    /// the `n` inside "Meeting" before reaching the one that begins "Notes",
    /// and a later word-start match can never be recovered. Rather than a
    /// full dynamic-programming matcher, this second pass covers the case
    /// people actually rely on — typing initials.
    private static func acronymScore(_ haystack: [Character], _ needle: [Character]) -> Int? {
        var starts: [Int] = []
        for (index, character) in haystack.enumerated() {
            let isStart =
                index == 0
                || {
                    let before = haystack[index - 1]
                    return before == " " || before == "/" || before == "-" || before == "_"
                        || before == "."
                }()
            if isStart, character.isLetter || character.isNumber {
                starts.append(index)
            }
        }

        var startIndex = 0
        var matched = 0
        for character in needle {
            var found = false
            while startIndex < starts.count {
                if haystack[starts[startIndex]] == character {
                    startIndex += 1
                    found = true
                    break
                }
                startIndex += 1
            }
            guard found else { return nil }
            matched += 1
        }

        // Weighted above any greedy result of the same length, since an
        // initials match is a much stronger signal of intent.
        return matched * 22 - haystack.count / 8
    }

    /// Leftmost subsequence match, scoring runs and word boundaries.
    private static func greedyScore(_ haystack: [Character], _ needle: [Character]) -> Int? {
        var score = 0
        var haystackIndex = 0
        var previousMatch: Int?

        for character in needle {
            var found: Int?
            while haystackIndex < haystack.count {
                if haystack[haystackIndex] == character {
                    found = haystackIndex
                    haystackIndex += 1
                    break
                }
                haystackIndex += 1
            }
            guard let index = found else { return nil }

            score += 1
            // Consecutive characters are far more likely to be what the user
            // meant than scattered ones.
            if let previous = previousMatch, index == previous + 1 {
                score += 8
            }
            // So are matches at a word boundary.
            if index == 0 {
                score += 12
            } else {
                let before = haystack[index - 1]
                if before == " " || before == "/" || before == "-" || before == "_" || before == "." {
                    score += 10
                }
            }
            previousMatch = index
        }

        // Prefer shorter candidates when scores tie: `Notes.md` should beat
        // `Notes about something else.md` for the query `notes`.
        score -= haystack.count / 8
        return score
    }

    /// Ranks `candidates` by how well they match `query`.
    public static func rank<T>(
        _ candidates: [T], query: String, key: (T) -> String
    ) -> [T] {
        guard !query.isEmpty else { return candidates }
        return
            candidates
            .compactMap { candidate -> (T, Int)? in
                guard let score = score(key(candidate), query: query) else { return nil }
                return (candidate, score)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }
}
