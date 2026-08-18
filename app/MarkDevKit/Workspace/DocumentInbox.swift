//
//  DocumentInbox.swift
//  MarkDevKit
//
//  Files handed to the app by Launch Services, held until a window that is
//  actually on screen can take them.
//

import Foundation

/// Files to open, and what was left out.
public struct DocumentOpenRequest: Equatable, Sendable {
    public let urls: [URL]
    /// How many further files were refused because the batch was too large.
    ///
    /// Carried *with* the request rather than read from the inbox afterwards:
    /// the first version cleared the count while handing over the files, so
    /// the caller always read zero and the truncation was never mentioned.
    public let dropped: Int

    public init(urls: [URL], dropped: Int = 0) {
        self.urls = urls
        self.dropped = dropped
    }

    public var isEmpty: Bool { urls.isEmpty }

    /// A message about what was discarded, or `nil` when nothing was.
    public var truncationMessage: String? {
        guard dropped > 0 else { return nil }
        return "Opened \(urls.count) files; \(dropped) more were not opened."
    }
}

/// Names one registered surface, so it can withdraw exactly its own
/// registration.
///
/// A plain "clear the handler" cannot be used: surfaces come and go in an
/// order nobody controls, and a departing one must never take a *newer*
/// registration down with it.
public struct DocumentSurfaceToken: Hashable, Sendable {
    private let id = UUID()
    fileprivate init() {}
}

/// Files the system has asked the app to open.
///
/// # Why this exists at all
///
/// Double-clicking a note in Finder delivers the open request *before* the
/// first window's view exists — the app is still launching. Nothing was
/// implementing `application(_:open:)`, and SwiftUI's `onOpenURL` does not
/// cover file opens, so MarkDev was ranked `Owner` of every Markdown document
/// on the machine and answered a double-click with an empty untitled window.
///
/// # Why a registry of surfaces, and not a handler
///
/// The queue-and-hand-over shape is right; "hand it to whoever registered
/// last" was not. Traced against a running build, SwiftUI answers *every*
/// Launch Services file open by building a throwaway `WorkspaceView` — it
/// appears, registers, and disappears again, all before
/// `application(_:open:)` is delivered:
///
///     onAppear    ws=0x…5bd0   (the window on screen)
///     onAppear    ws=0x…af80   (a throwaway, with an off-screen window)
///     onDisappear ws=0x…af80
///     application(open:) […/ReproNote.md]
///     openFromInbox ws=0x…af80 → openFile OK
///
/// The file opened, into a workspace nobody was rendering, and the window on
/// screen went on showing "Untitled". Because nothing withdrew the throwaway's
/// registration, *every* later double-click went the same way for the life of
/// the process.
///
/// So a surface is registered with a token it withdraws itself, and the inbox
/// asks each one how ready it is rather than assuming the newest is the right
/// one. Two independent things then have to fail before a document is lost:
/// the departing surface must fail to withdraw *and* its window must still
/// claim to be on screen.
///
/// # Nothing is consumed by a surface that cannot show it
///
/// Delivery answers whether it was taken. A refused request goes back at the
/// head of the queue, and if no surface can take it the inbox asks the app for
/// a window and holds the files until one arrives. A request that lands
/// nowhere stays a request.
@MainActor
public final class DocumentInbox {
    public static let shared = DocumentInbox()

    /// Hands a batch to a surface. `false` means "I cannot show these", and
    /// the batch stays queued for someone who can.
    public typealias Delivery = (DocumentOpenRequest) -> Bool

    /// Runs `work` after `delay`. Injected so the grace period below is
    /// asserted rather than waited on.
    public typealias Scheduler =
        @MainActor (_ delay: TimeInterval, _ work: @escaping @MainActor @Sendable () -> Void) ->
            Void

    private struct Surface {
        let token: DocumentSurfaceToken
        /// Registration order, so ties break towards the newest window.
        let order: Int
        let readiness: () -> DocumentSurfaceReadiness
        let deliver: Delivery
    }

    /// Waiting for a surface that can show them, oldest first.
    public private(set) var pending: [URL] = []
    public private(set) var dropped = 0

    /// Asks the app to open a window, when a request has nowhere to go.
    ///
    /// Set by the app; `nil` in a Quick Look extension, which cannot open
    /// windows — there the files simply stay queued rather than vanishing.
    public var windowProvider: (() -> Void)?

    private var surfaces: [Surface] = []
    private var nextOrder = 0
    private let schedule: Scheduler
    /// Whether a window has been asked for and has not arrived yet, so a burst
    /// of requests opens one window rather than one window each.
    private var isAwaitingWindow = false
    private var isHoldingForPreparation = false
    /// Whether the grace below has already been spent on what is queued now.
    /// Without it the hold re-arms itself every time it expires, and a surface
    /// that never shows a window keeps the queue turning over for ever.
    private var hasWaitedForPreparation = false

    /// The most files one batch will accept.
    ///
    /// Selecting a folder's worth of notes and pressing Return is easy to do
    /// by accident, and each one becomes a tab holding a parsed document.
    public static let limit = 32

    /// The most surfaces that may be registered at once.
    ///
    /// Registration is withdrawn by the surface itself, and a surface that
    /// never withdraws would otherwise accumulate for the life of the process.
    /// Only surfaces that have no usable window are ever dropped to stay under
    /// this, so a real window can never be evicted by a leak.
    public static let maximumSurfaces = 64

    /// How long a surface that has not shown its window yet may hold a
    /// request back.
    ///
    /// Long enough for a window that is genuinely on its way, short enough
    /// that one which never appears cannot strand a document. Without the
    /// bound, a surface that registers and neither shows a window nor
    /// withdraws would hold the queue for the life of the process.
    public static let preparationGrace: TimeInterval = 2

    public init(schedule: @escaping Scheduler = DocumentInbox.defaultScheduler) {
        self.schedule = schedule
    }

    public static let defaultScheduler: Scheduler = { delay, work in
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            work()
        }
    }

    // MARK: - Surfaces

    /// Registers a window that can show documents, and hands it the backlog if
    /// it is the best place for it.
    ///
    /// The returned token is the *only* way to withdraw this registration.
    @discardableResult
    public func register(
        readiness: @escaping () -> DocumentSurfaceReadiness,
        deliver: @escaping Delivery
    ) -> DocumentSurfaceToken {
        let token = DocumentSurfaceToken()
        surfaces.append(
            Surface(token: token, order: nextOrder, readiness: readiness, deliver: deliver))
        nextOrder += 1
        // A window arriving answers whatever was asked for; the next dead end
        // is allowed to ask again, and to wait again for this one to show.
        isAwaitingWindow = false
        hasWaitedForPreparation = false
        enforceSurfaceLimit()
        deliverPending()
        return token
    }

    /// Withdraws one registration, leaving every other surface alone.
    ///
    /// Delivery is retried immediately: a throwaway surface leaving is exactly
    /// the moment the window on screen becomes the right place for a file.
    public func unregister(_ token: DocumentSurfaceToken) {
        surfaces.removeAll { $0.token == token }
        deliverPending()
    }

    /// Retries delivery. Called when a window appears, is shown, or becomes
    /// key — none of which the inbox can observe for itself.
    public func refresh() {
        deliverPending()
    }

    /// Whether anything is registered. Diagnostics and tests.
    public var surfaceCount: Int { surfaces.count }

    // MARK: - Requests

    /// Accepts open requests, delivering them if anyone can show them.
    ///
    /// Only file URLs are taken. A custom-scheme URL is not a document open
    /// and must not be turned into one — reading it as a file is, for a remote
    /// scheme, a synchronous network fetch on the main thread.
    public func receive(_ urls: [URL]) {
        enqueue(urls.filter(\.isFileURL))
        deliverPending()
    }

    /// Everything waiting, emptying the queue.
    public func drain() -> DocumentOpenRequest {
        defer {
            pending.removeAll()
            dropped = 0
        }
        return DocumentOpenRequest(urls: pending, dropped: dropped)
    }

    // MARK: - Delivery

    private func deliverPending() {
        purgeDepartedSurfaces()
        guard !pending.isEmpty else { return }

        // Readiness is asked once per surface per pass: it is answered by
        // AppKit, and a value that changes mid-sort is a sort that does not
        // order anything. Best first, newest breaking a tie.
        let ranked =
            surfaces
            .map { (surface: $0, readiness: $0.readiness()) }
            .sorted {
                $0.readiness == $1.readiness
                    ? $0.surface.order > $1.surface.order
                    : $0.readiness > $1.readiness
            }

        for candidate in ranked where candidate.readiness >= .background {
            let request = drain()
            if candidate.surface.deliver(request) {
                isAwaitingWindow = false
                hasWaitedForPreparation = false
                return
            }
            // Refused. Back at the head, in the order it arrived, for the next
            // candidate — or for a window that does not exist yet.
            restore(request)
        }

        // Nobody could take it. A window that has not been shown *yet* is
        // worth waiting for — once; anything else means there is no window at
        // all.
        if !hasWaitedForPreparation, ranked.contains(where: { $0.readiness == .preparing }) {
            holdForPreparingSurfaces()
            return
        }
        requestWindow()
    }

    private func holdForPreparingSurfaces() {
        guard !isHoldingForPreparation else { return }
        isHoldingForPreparation = true
        schedule(Self.preparationGrace) { [weak self] in
            guard let self else { return }
            self.isHoldingForPreparation = false
            // Whatever was preparing has had its chance. If it still cannot
            // take the files, the pass below asks for a window that can.
            self.hasWaitedForPreparation = true
            self.deliverPending()
        }
    }

    private func requestWindow() {
        guard let windowProvider, !isAwaitingWindow else { return }
        isAwaitingWindow = true
        windowProvider()
    }

    /// Drops surfaces whose window has been closed.
    ///
    /// Only `gone` is dropped here — a surface still preparing is one whose
    /// window has not been shown yet, and dropping that is how the window on
    /// its way loses its registration.
    private func purgeDepartedSurfaces() {
        surfaces.removeAll { $0.readiness() == .gone }
    }

    /// Keeps the registry bounded, evicting only surfaces that cannot show a
    /// document anyway, oldest first.
    private func enforceSurfaceLimit() {
        guard surfaces.count > Self.maximumSurfaces else { return }
        var excess = surfaces.count - Self.maximumSurfaces
        surfaces.removeAll { surface in
            guard excess > 0, surface.readiness() < .background else { return false }
            excess -= 1
            return true
        }
    }

    // MARK: - The queue

    private func enqueue(_ urls: [URL]) {
        for url in urls {
            let standardized = url.standardizedFileURL
            // A second request for a file already waiting is not a second
            // file: Launch Services can deliver duplicates when an app is
            // asked to open the same document twice in quick succession.
            guard !pending.contains(standardized) else { continue }
            guard pending.count < Self.limit else {
                dropped += 1
                continue
            }
            pending.append(standardized)
        }
    }

    /// Puts a refused request back at the head of the queue.
    ///
    /// At the head, and in arrival order, so a refusal cannot reorder what the
    /// reader asked for. The bound still applies: whatever no longer fits is
    /// counted as dropped rather than silently kept.
    private func restore(_ request: DocumentOpenRequest) {
        var restored = request.urls
        for url in pending where !restored.contains(url) {
            restored.append(url)
        }
        dropped += request.dropped
        pending = Array(restored.prefix(Self.limit))
        dropped += max(0, restored.count - Self.limit)
    }
}
