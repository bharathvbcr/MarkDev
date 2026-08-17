//
//  DocumentInbox.swift
//  MarkDevKit
//
//  Files handed to the app by Launch Services, held until a window can take
//  them.
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
/// # Why a handler rather than observation
///
/// The first fix published `pending` from an `@Observable` singleton and let
/// the workspace watch it with `onChange`. It did not work either: the window
/// appeared, drained an empty queue, and the request arrived a moment later
/// without waking anything — verified by tracing the order, which came out as
/// `drain -> []` and only then `application(open:)`.
///
/// So delivery is explicit. A workspace registers itself and is handed
/// anything already waiting; later arrivals go straight through. Nothing here
/// depends on when SwiftUI decides to re-evaluate a body.
@MainActor
public final class DocumentInbox {
    public static let shared = DocumentInbox()

    /// Called with files to open, once a workspace is ready for them.
    private var handler: ((DocumentOpenRequest) -> Void)?

    /// Waiting for a workspace to exist, oldest first.
    public private(set) var pending: [URL] = []
    public private(set) var dropped = 0

    /// The most files one batch will accept.
    ///
    /// Selecting a folder's worth of notes and pressing Return is easy to do
    /// by accident, and each one becomes a tab holding a parsed document.
    public static let limit = 32

    public init() {}

    /// Registers the workspace that opens files, and hands it the backlog.
    ///
    /// Called as a window appears. Passing `nil` unregisters, so a closing
    /// window stops being handed documents; the next window to appear takes
    /// over and receives whatever queued up in between.
    public func setHandler(_ handler: ((DocumentOpenRequest) -> Void)?) {
        self.handler = handler
        flush()
    }

    /// Accepts open requests, delivering them if anyone is ready.
    public func receive(_ urls: [URL]) {
        enqueue(urls)
        flush()
    }

    /// Everything waiting, emptying the queue.
    public func drain() -> DocumentOpenRequest {
        defer {
            pending.removeAll()
            dropped = 0
        }
        return DocumentOpenRequest(urls: pending, dropped: dropped)
    }

    private func flush() {
        guard let handler, !pending.isEmpty else { return }
        handler(drain())
    }

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
}
