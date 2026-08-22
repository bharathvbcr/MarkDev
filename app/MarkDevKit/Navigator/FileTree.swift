//
//  FileTree.swift
//  MarkDevKit
//
//  The vault's file hierarchy, and the fuzzy matcher used to filter it.
//

import Foundation

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
    /// Extensions the navigator shows. Anything else is noise in a Markdown
    /// tool, and hiding it keeps the sidebar readable in a mixed repository.
    public static let markdownExtensions: Set<String> = [
        "md", "markdown", "mdown", "mdx", "mkd",
    ]

    /// Directories never worth showing in a notes vault.
    public static let ignoredDirectories: Set<String> = [
        ".git", ".build", "node_modules", ".obsidian", ".trash", "DerivedData",
    ]

    /// Lists the immediate children of `url`.
    ///
    /// Directories sort before files, then case-insensitively by name — the
    /// ordering Finder uses, so the sidebar does not feel foreign.
    public static func children(of url: URL, includeAllFiles: Bool = false) -> [FileNode] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey]
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
            let values = try? entry.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory ?? false

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
    /// Directory symlinks are followed but never twice: a loop (`link -> ..`)
    /// would otherwise walk forever. A depth cap backs the same guarantee up
    /// for filesystems where canonicalisation is unreliable.
    public static func markdownFiles(under root: URL) -> [URL] {
        var found: [URL] = []
        var visited: Set<String> = []
        walk(root, depth: 0, visited: &visited, into: &found)
        return found
    }

    private static func walk(
        _ directory: URL, depth: Int, visited: inout Set<String>, into found: inout [URL]
    ) {
        let maxDepth = 48
        guard depth <= maxDepth else { return }
        let identity = (try? directory.resolvingSymlinksInPath().path) ?? directory.path
        guard visited.insert(identity).inserted else { return }

        for node in children(of: directory) {
            if node.isDirectory {
                walk(node.url, depth: depth + 1, visited: &visited, into: &found)
            } else {
                found.append(node.url)
            }
        }
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
