//
//  ContentPrefetcher.swift
//  MarkDevKit
//
//  Warming the render cache for content the reader has not reached yet.
//

import AppKit

/// Renders a document's pictures before they are scrolled to.
///
/// # Why this exists
///
/// TextKit 2 lays out only the visible viewport, and a fragment resolves its
/// content — a formula typeset, a graph laid out and rasterised, an image file
/// decoded — synchronously, on the main actor, at the moment the fragment is
/// built. So the cost of every picture in a note is paid *while the reader is
/// scrolling onto it*, which is the one moment it is most visible. A Mermaid
/// graph is tens of milliseconds; several in a row is a stutter.
///
/// Nothing here renders differently from the on-demand path. It calls
/// ``RichContentRenderer/render(_:)``, the same entry point the layout
/// fragment uses, and fills the same shared cache — so a warmed block is not
/// "prefetched content" that has to be kept in step with anything, it is
/// simply a cache hit when the fragment asks.
///
/// # What bounds it
///
/// Three things, because an unbounded warm is worse than none:
///
/// - **The cache's own budget.** ``RichContentRenderer`` evicts oldest-first,
///   so warming past the budget would push out the bitmaps on screen to make
///   room for ones that are not. Each priority stops at a fraction of it.
/// - **The main actor.** Everything here needs it, so work is done one item
///   per runloop hop rather than in a loop — see ``step()``.
/// - **A source-length cap.** The cache bounds a bitmap's *size*; nothing
///   bounds how long a pathological Mermaid source takes to lay out. A warm is
///   opportunistic, so it declines the outliers and leaves them to the
///   on-demand path, where at least the reader has asked for them.
@MainActor
public final class ContentPrefetcher {
    /// Shared because the cache it fills is shared: two panes warming against
    /// separate budgets would between them exceed the one budget that exists.
    public static let shared = ContentPrefetcher()

    /// Which document a batch of work came from.
    public enum Priority: Int, CaseIterable, Sendable {
        /// The document on screen. Drained first.
        case document = 0
        /// A note the open document links to, warmed against the chance the
        /// reader follows the link. Drained only once `document` is empty.
        case connected = 1
    }

    /// How full the render cache may be before a warm at this priority stops
    /// adding to it.
    ///
    /// Fractions of the renderer's own budget rather than absolute numbers, so
    /// there is one place the size of the cache is decided. Connected notes
    /// get the smaller share: they are a guess about what the reader will do
    /// next, and a guess must not crowd out what is being read now.
    func ceiling(for priority: Priority) -> Int {
        switch priority {
        case .document: return renderer.pixelBudget / 2
        case .connected: return renderer.pixelBudget / 4
        }
    }

    /// Sources longer than this are left to the on-demand path.
    static let maximumSourceLength = 20_000

    /// Ceiling on the connected queue.
    ///
    /// The warmer caps how many notes it reads, but not how many pictures they
    /// hold between them, and connected batches *accumulate* — a document
    /// queue replaces, a connected one appends. One note of a thousand
    /// diagrams should not be able to leave the queue trailing behind the
    /// reader for the rest of the session.
    static let maximumConnectedQueue = 256

    /// How long a warm waits before its first item.
    ///
    /// Long enough for the layout pass that triggered it to finish, and for a
    /// burst of typing to settle — a warm that starts inside the keystroke it
    /// was scheduled from is competing with the thing it exists to smooth.
    static let startDelay = Duration.milliseconds(200)

    /// The pause between items.
    ///
    /// A real suspension rather than `Task.yield()`. The main queue is drained
    /// to empty in one runloop pass, so a yielding loop re-enqueues itself
    /// inside the very drain it is meant to be making way for, and the events
    /// it should be yielding to wait until the queue runs dry.
    static let stepPause = Duration.milliseconds(2)

    private let renderer: RichContentRenderer
    private var queues: [Priority: [RenderRequest]] = [:]
    private var driver: Task<Void, Never>?

    /// The context the open document is being rendered in.
    ///
    /// Remembered so connected notes can be warmed the same way without a
    /// second owner of "how wide is a column, and how dark is it" — the editor
    /// is the only thing that knows, and it says so every time it warms.
    public private(set) var documentContext: RenderContext?

    /// How many blocks this has actually rendered, for tests and for judging
    /// whether a warm is doing anything.
    public private(set) var warmed = 0
    /// How many it declined — over the cache's ceiling, or too large to be
    /// worth doing speculatively.
    public private(set) var declined = 0

    public init(renderer: RichContentRenderer = .shared) {
        self.renderer = renderer
    }

    // MARK: - Asking for a warm

    /// Warms the blocks of the document on screen.
    ///
    /// Replaces any previous document batch rather than adding to it: the
    /// caller re-states its whole list whenever the parse, the width, or the
    /// appearance changes, and the superseded list describes a document, a
    /// column, or a palette that no longer applies.
    public func warmDocument(
        _ blocks: [RenderedBlock], in directory: URL?, using context: RenderContext
    ) {
        documentContext = context
        queues[.document] = blocks.map {
            RenderRequest(block: $0, directory: directory, context: context)
        }
        start()
    }

    /// Warms the blocks of a note the open document links to.
    ///
    /// Rendered in the *open document's* context, which is the only sensible
    /// one available: a linked note has no column of its own until it is
    /// opened, and it will be opened into this one.
    ///
    /// Does nothing before a document has warmed. There is nothing to guess
    /// with, and guessing a width would fill the cache with entries that miss.
    public func warmConnected(_ blocks: [RenderedBlock], in directory: URL) {
        guard let context = documentContext, !blocks.isEmpty else { return }
        let queued = queues[.connected]?.count ?? 0
        let room = Self.maximumConnectedQueue - queued
        guard room > 0 else {
            declined += blocks.count
            return
        }
        declined += max(0, blocks.count - room)
        queues[.connected, default: []] += blocks.prefix(room).map {
            RenderRequest(block: $0, directory: directory, context: context)
        }
        start()
    }

    /// Drops everything queued and stops.
    ///
    /// Called when the document is replaced: the queue describes a document
    /// that is no longer open, and the connected half describes what *that*
    /// document linked to.
    public func cancel() {
        driver?.cancel()
        driver = nil
        queues.removeAll()
    }

    /// Whether anything is still waiting to be warmed.
    public var hasWork: Bool {
        queues.values.contains { !$0.isEmpty }
    }

    // MARK: - Doing the work

    /// Renders at most one block, and reports whether work remains.
    ///
    /// One item per call, because every render here happens on the main actor
    /// and a loop would hold it for as long as the queue is long. Items that
    /// are already cached, or that are declined, cost only a dictionary lookup
    /// and do not count as the call's one item — most of a re-warm after a
    /// keystroke is exactly that, and paying a runloop hop each for a hundred
    /// entries the reader has already scrolled past would make the warm slower
    /// than the thing it is warming.
    ///
    /// Internal rather than private so a test can drive a warm to completion
    /// without waiting on a clock.
    @discardableResult
    func step() -> Bool {
        while let (priority, request) = takeNext() {
            if renderer.isCached(request) { continue }

            guard renderer.cachedPixels < ceiling(for: priority) else {
                // The cache is already fuller than a warm at this priority may
                // make it. Abandon the rest of that queue rather than retry it
                // item by item: what evicts is what is on screen, and the
                // on-demand path still renders these when the reader arrives.
                declined += queues[priority]?.count ?? 0
                declined += 1
                queues[priority] = []
                continue
            }

            guard request.block.source.utf16.count <= Self.maximumSourceLength else {
                declined += 1
                continue
            }

            _ = renderer.render(request)
            warmed += 1
            return hasWork
        }
        return false
    }

    /// Pops the next request, highest priority first.
    private func takeNext() -> (Priority, RenderRequest)? {
        for priority in Priority.allCases {
            guard var queue = queues[priority], !queue.isEmpty else { continue }
            let request = queue.removeFirst()
            queues[priority] = queue
            return (priority, request)
        }
        return nil
    }

    private func start() {
        guard driver == nil, hasWork else { return }
        driver = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.startDelay)
            } catch {
                return
            }
            while !Task.isCancelled, let prefetcher = self, prefetcher.step() {
                do {
                    try await Task.sleep(for: Self.stepPause)
                } catch {
                    return
                }
            }
            // Only when this task is still the live one. A cancelled driver
            // has already been replaced by whoever cancelled it, and clearing
            // the field here would strand the replacement with no way to be
            // seen as running.
            guard !Task.isCancelled else { return }
            self?.driver = nil
        }
    }
}
