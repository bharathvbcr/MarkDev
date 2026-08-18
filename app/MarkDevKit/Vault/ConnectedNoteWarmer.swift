//
//  ConnectedNoteWarmer.swift
//  MarkDevKit
//
//  Reading ahead along a note's links.
//

import Foundation

/// Reads the notes an open document links to, and warms their pictures.
///
/// # What it does, in order
///
/// 1. Asks the index which notes the open one links to — the index already
///    knows, having read them when it indexed the vault.
/// 2. Reads each of those files into ``NoteTextCache``, off the main actor, so
///    that following the link neither reads nor blocks.
/// 3. Parses each and hands its formulas, diagrams and images to
///    ``ContentPrefetcher`` at connected priority, so the note it opens into
///    has its pictures already drawn.
///
/// # What bounds it
///
/// A note can link to a hundred others, and each of those is a file read, a
/// parse, and possibly several bitmaps. So: at most ``maximumNotes`` targets,
/// each under ``NoteTextCache/maximumFileBytes``, and every picture behind the
/// prefetcher's connected ceiling — which is deliberately a quarter of the
/// render cache, because this is a *guess* about what the reader will do next
/// and a guess must never evict what they are reading now.
///
/// The whole thing is debounced. It is driven from the same place backlinks
/// are refreshed, which is every keystroke, and the set of links a note has
/// changes about once a paragraph.
@MainActor
public final class ConnectedNoteWarmer {
    /// How many linked notes are read ahead.
    ///
    /// Small on purpose. The reader follows one link, not eight, and each
    /// extra target is memory held against a guess that gets weaker the
    /// further down the note's link list it comes from.
    public static let maximumNotes = 8

    /// How long typing must pause before a warm starts.
    public static let debounce = Duration.milliseconds(500)

    private let cache: NoteTextCache
    private let prefetcher: ContentPrefetcher
    private var task: Task<Void, Never>?

    /// The targets of the last warm, so an edit that leaves a note's links
    /// alone — which is nearly every edit — does no work at all.
    private var warmedTargets: [URL] = []

    /// How many notes have actually been read ahead, for tests.
    public private(set) var notesWarmed = 0

    public init(
        cache: NoteTextCache = .shared,
        prefetcher: ContentPrefetcher = .shared
    ) {
        self.cache = cache
        self.prefetcher = prefetcher
    }

    /// Warms whatever `url` links to, after a pause.
    ///
    /// A document outside the vault has no links this can resolve, and cancels
    /// rather than leaving the previous document's targets warming.
    public func warm(from url: URL, in vault: VaultIndex) {
        guard let path = vault.relativePath(for: url) else {
            cancel()
            return
        }

        task?.cancel()
        task = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.debounce)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            // Asked after the pause, not before it: this crosses the FFI, and
            // the caller is on the typing path.
            let targets = self.targets(from: path, in: vault)
            guard targets != self.warmedTargets else { return }
            self.warmedTargets = targets
            await self.warm(targets)
        }
    }

    /// Stops, and forgets what was warmed.
    public func cancel() {
        task?.cancel()
        task = nil
        warmedTargets = []
    }

    /// The notes `path` links to, deduplicated and capped.
    ///
    /// Broken links resolve to nothing and are skipped; a note linking to
    /// itself is not a note to read ahead.
    ///
    /// Internal, with ``warm(_:)``, so a test can drive the two halves without
    /// waiting out the debounce.
    func targets(from path: String, in vault: VaultIndex) -> [URL] {
        var seen: Set<String> = [path]
        var urls: [URL] = []
        for link in vault.links(for: path) {
            guard let target = link.path,
                seen.insert(target).inserted,
                let url = vault.url(for: target)
            else { continue }
            urls.append(url)
            if urls.count == Self.maximumNotes { break }
        }
        return urls
    }

    /// Reads and parses each target away from the main actor, then queues its
    /// pictures on it.
    ///
    /// One note at a time rather than all at once: this is background work
    /// competing with an editor, and eight concurrent parses would win that
    /// competition.
    func warm(_ targets: [URL]) async {
        for target in targets {
            guard !Task.isCancelled else { return }
            let cache = self.cache
            let blocks = await Task.detached(priority: .utility) {
                Self.renderedBlocks(of: target, using: cache)
            }.value
            guard !Task.isCancelled else { return }
            notesWarmed += 1
            prefetcher.warmConnected(blocks, in: target.deletingLastPathComponent())
        }
    }

    /// Reads one note into the cache and returns what it draws as content.
    ///
    /// `nonisolated` and static: every step of it — the read, the parse, the
    /// scan for renderable blocks — is pure and off the main actor, which is
    /// the point of doing it ahead of time at all. Only the rasterising that
    /// follows needs the main actor, and that is the prefetcher's job.
    private nonisolated static func renderedBlocks(
        of url: URL, using cache: NoteTextCache
    ) -> [RenderedBlock] {
        guard let data = cache.warm(url),
            let text = String(data: data, encoding: .utf8)
        else { return [] }
        let parsed = ParsedDocument.parse(text)
        return RenderedBlocks(document: parsed, text: text as NSString).entries.map(\.content)
    }
}
