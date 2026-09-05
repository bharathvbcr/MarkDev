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

    /// Identifies one editor pane's speculative work inside the shared warmer.
    ///
    /// The renderer cache is process-wide, but queue lifetime and rendering
    /// context are not: replacing a note in one pane must not cancel another
    /// pane, and a linked note must use the width of the pane that linked it.
    public struct Owner: Hashable, Sendable {
        private let id: UUID

        public init(id: UUID = UUID()) {
            self.id = id
        }
    }

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

    /// Ceiling on all open-document requests retained by one prefetcher.
    ///
    /// Document batches replace per owner, but several panes can coexist. The
    /// shared ceiling prevents either one enormous parse or an unbounded set of
    /// owners from turning speculative work into retained document-sized state.
    static let maximumDocumentQueue = 256

    /// Ceiling on the connected queue.
    ///
    /// The warmer caps how many notes it reads, but not how many pictures they
    /// hold between them, and connected batches *accumulate* — a document
    /// queue replaces, a connected one appends. One note of a thousand
    /// diagrams should not be able to leave the queue trailing behind the
    /// reader for the rest of the session.
    static let maximumConnectedQueue = 256

    /// Maximum requests inspected in one main-actor turn.
    ///
    /// Cached and declined entries avoid rendering, but they are not free: a
    /// cache probe hashes a key and source admission scans a bounded prefix.
    /// Giving those cheap paths a quantum keeps a re-warm from monopolising a
    /// runloop hop merely because all of its content was seen before.
    static let maximumInspectionsPerStep = 64

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

    private final class RequestQueue {
        private var storage: [RenderRequest]
        private var head = 0

        init(_ requests: [RenderRequest]) {
            storage = requests
        }

        var count: Int { storage.count - head }
        var isEmpty: Bool { head == storage.count }

        func append(contentsOf requests: [RenderRequest]) {
            guard !requests.isEmpty else { return }
            compactIfNeeded()
            storage.append(contentsOf: requests)
        }

        func popFirst() -> RenderRequest? {
            guard head < storage.count else { return nil }
            let request = storage[head]
            head += 1
            return request
        }

        private func compactIfNeeded() {
            guard head > 0 else { return }
            if head == storage.count {
                storage.removeAll(keepingCapacity: true)
                head = 0
            } else if head >= 64, head >= storage.count / 2 {
                storage = Array(storage[head...])
                head = 0
            }
        }
    }

    private let renderer: RichContentRenderer
    private let implicitOwner = Owner()
    private var queues: [Priority: [Owner: RequestQueue]] = [:]
    private var ownerOrder: [Priority: [Owner]] = [:]
    private var nextOwnerIndex: [Priority: Int] = [:]
    private var documentContexts: [Owner: RenderContext] = [:]
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
        warmDocument(blocks, owner: implicitOwner, in: directory, using: context)
    }

    /// Owner-scoped form used by editor panes sharing this prefetcher.
    public func warmDocument(
        _ blocks: [RenderedBlock],
        owner: Owner,
        in directory: URL?,
        using context: RenderContext
    ) {
        documentContext = context
        documentContexts[owner] = context

        // Replacement frees this owner's previous share before the global
        // document ceiling is calculated. Only the admitted prefix is walked,
        // so enqueue itself is bounded even for a hostile parsed document.
        removeQueue(for: owner, priority: .document)
        let room = max(0, Self.maximumDocumentQueue - queuedCount(for: .document))
        let requests = admittedRequests(
            from: blocks, limit: room, directory: directory, context: context)
        declined += blocks.count - requests.count
        install(requests, for: owner, priority: .document)
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
        guard let context = documentContexts[implicitOwner] else { return }
        warmConnected(
            blocks, owner: implicitOwner, in: directory, fallbackContext: context)
    }

    /// Owner-scoped form used by linked-note warming for a particular pane.
    public func warmConnected(_ blocks: [RenderedBlock], owner: Owner, in directory: URL) {
        guard let context = documentContexts[owner] else { return }
        warmConnected(blocks, owner: owner, in: directory, fallbackContext: context)
    }

    private func warmConnected(
        _ blocks: [RenderedBlock],
        owner: Owner,
        in directory: URL,
        fallbackContext context: RenderContext
    ) {
        guard !blocks.isEmpty else { return }
        let room = Self.maximumConnectedQueue - queuedCount(for: .connected)
        guard room > 0 else {
            declined += blocks.count
            return
        }
        let requests = admittedRequests(
            from: blocks, limit: room, directory: directory, context: context)
        declined += blocks.count - requests.count
        append(requests, for: owner, priority: .connected)
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
        ownerOrder.removeAll()
        nextOwnerIndex.removeAll()
        documentContexts.removeAll()
        documentContext = nil
    }

    /// Drops one pane's work without disturbing any other pane.
    public func cancel(owner: Owner) {
        for priority in Priority.allCases {
            removeQueue(for: owner, priority: priority)
        }
        documentContexts.removeValue(forKey: owner)
        if owner == implicitOwner { documentContext = nil }
        guard hasWork else {
            driver?.cancel()
            driver = nil
            return
        }
        start()
    }

    /// Whether anything is still waiting to be warmed.
    public var hasWork: Bool {
        queues.values.contains { ownerQueues in
            ownerQueues.values.contains { !$0.isEmpty }
        }
    }

    // MARK: - Doing the work

    /// Renders at most one block, and reports whether work remains.
    ///
    /// One item per call, because every render here happens on the main actor
    /// and a loop would hold it for as long as the queue is long. Non-image
    /// items that are already cached, or that are declined, cost less than a
    /// render, but still count toward ``maximumInspectionsPerStep``. Most of a
    /// re-warm after a keystroke is exactly those probes, and an unbounded run
    /// of them can stall the main actor too. An image cache probe opens a file
    /// to identify its generation, so it ends the turn even on a hit.
    ///
    /// Internal rather than private so a test can drive a warm to completion
    /// without waiting on a clock.
    @discardableResult
    func step() -> Bool {
        var inspections = 0
        while inspections < Self.maximumInspectionsPerStep,
            let (priority, request) = takeNext()
        {
            inspections += 1
            let isImageRequest: Bool
            if case .image = request.block.kind {
                isImageRequest = true
            } else {
                isImageRequest = false
            }

            // Source admission precedes `isCached`: an image probe opens a
            // descriptor, and an already-refused source must perform no I/O.
            guard Self.sourceIsAdmitted(request.block.source) else {
                declined += 1
                if isImageRequest { return hasWork }
                continue
            }

            if renderer.isCached(request) {
                if isImageRequest { return hasWork }
                continue
            }

            guard renderer.cachedPixels < ceiling(for: priority) else {
                // The cache is already fuller than a warm at this priority may
                // make it. Abandon the rest of that queue rather than retry it
                // item by item: what evicts is what is on screen, and the
                // on-demand path still renders these when the reader arrives.
                declined += queuedCount(for: priority) + 1
                removeAllQueues(for: priority)
                if isImageRequest { return hasWork }
                continue
            }

            _ = renderer.render(request)
            warmed += 1
            return hasWork
        }
        return hasWork
    }

    /// Pops the next request, highest priority first and round-robin within a
    /// priority so one pane cannot monopolise every document turn.
    private func takeNext() -> (Priority, RenderRequest)? {
        for priority in Priority.allCases {
            while var owners = ownerOrder[priority], !owners.isEmpty {
                var cursor = (nextOwnerIndex[priority] ?? 0) % owners.count
                let owner = owners[cursor]
                guard let queue = queues[priority]?[owner], let request = queue.popFirst()
                else {
                    queues[priority]?.removeValue(forKey: owner)
                    owners.remove(at: cursor)
                    ownerOrder[priority] = owners
                    nextOwnerIndex[priority] = owners.isEmpty ? 0 : cursor % owners.count
                    continue
                }

                if queue.isEmpty {
                    queues[priority]?.removeValue(forKey: owner)
                    owners.remove(at: cursor)
                    ownerOrder[priority] = owners
                    nextOwnerIndex[priority] = owners.isEmpty ? 0 : cursor % owners.count
                } else {
                    cursor = (cursor + 1) % owners.count
                    nextOwnerIndex[priority] = cursor
                }
                return (priority, request)
            }
        }
        return nil
    }

    private static func sourceIsAdmitted(_ source: String) -> Bool {
        let codeUnits = source.utf16
        return codeUnits.index(
            codeUnits.startIndex,
            offsetBy: maximumSourceLength + 1,
            limitedBy: codeUnits.endIndex) == nil
    }

    /// Converts only a bounded prefix to requests and rejects oversized
    /// sources before they become retained queue state.
    private func admittedRequests(
        from blocks: [RenderedBlock],
        limit: Int,
        directory: URL?,
        context: RenderContext
    ) -> [RenderRequest] {
        guard limit > 0 else { return [] }
        var requests: [RenderRequest] = []
        requests.reserveCapacity(min(limit, blocks.count))
        for block in blocks.prefix(limit) where Self.sourceIsAdmitted(block.source) {
            requests.append(RenderRequest(block: block, directory: directory, context: context))
        }
        return requests
    }

    private func queuedCount(for priority: Priority) -> Int {
        queues[priority]?.values.reduce(into: 0) { $0 += $1.count } ?? 0
    }

    private func install(_ requests: [RenderRequest], for owner: Owner, priority: Priority) {
        guard !requests.isEmpty else { return }
        queues[priority, default: [:]][owner] = RequestQueue(requests)
        ownerOrder[priority, default: []].append(owner)
        nextOwnerIndex[priority] = min(
            nextOwnerIndex[priority] ?? 0,
            max(0, (ownerOrder[priority]?.count ?? 1) - 1))
    }

    private func append(_ requests: [RenderRequest], for owner: Owner, priority: Priority) {
        guard !requests.isEmpty else { return }
        if let queue = queues[priority]?[owner] {
            queue.append(contentsOf: requests)
        } else {
            install(requests, for: owner, priority: priority)
        }
    }

    private func removeQueue(for owner: Owner, priority: Priority) {
        queues[priority]?.removeValue(forKey: owner)
        guard var owners = ownerOrder[priority],
            let removed = owners.firstIndex(of: owner)
        else { return }
        owners.remove(at: removed)
        ownerOrder[priority] = owners

        let cursor = nextOwnerIndex[priority] ?? 0
        if owners.isEmpty {
            nextOwnerIndex[priority] = 0
        } else if removed < cursor {
            nextOwnerIndex[priority] = (cursor - 1) % owners.count
        } else {
            nextOwnerIndex[priority] = cursor % owners.count
        }
    }

    private func removeAllQueues(for priority: Priority) {
        queues[priority] = [:]
        ownerOrder[priority] = []
        nextOwnerIndex[priority] = 0
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
