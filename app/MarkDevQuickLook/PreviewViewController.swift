//
//  PreviewViewController.swift
//  MarkDevQuickLook
//
//  The Space-bar preview in Finder.
//

import AppKit
import OSLog
import QuickLookUI

/// Renders a Markdown file into Quick Look's preview panel.
///
/// The whole controller is a host for ``MarkDevPreviewController``: the
/// preview is the editor in reading mode, so what Finder shows on Space is
/// what the app shows when the note is opened. Nothing about the rendering
/// lives here.
final class PreviewViewController: NSViewController, QLPreviewingController {
    private static let logger = Logger(
        subsystem: "dev.markdev.MarkDev.QuickLook",
        category: "preview")
    private let preview = MarkdownPreviewController()
    private let previewCoordinator = QuickLookPreviewCoordinator<Data>()

    override func loadView() {
        view = preview.view
    }

    func preparePreviewOfFile(at url: URL) async throws {
        // Read off the main actor: Quick Look calls this for files that may
        // live on a slow or network volume, and blocking the main thread of a
        // preview extension is what makes Space feel broken.
        let request = previewCoordinator.start(
            url: url,
            operation: {
                try QuickLookFileReader.read(
                    url, maximumBytes: MarkdownReadLimits.maximumPreviewBytes)
            },
            commit: { [preview] data, committedURL in
                // The coordinator has just rechecked request generation and
                // exact URL on MainActor. This closure cannot suspend, so a
                // superseding request cannot interleave before publication.
                let markdown =
                    String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1)
                    ?? ""
                try Task.checkCancellation()
                preview.show(
                    markdown,
                    directory: committedURL.deletingLastPathComponent())
            })

        do {
            try await request.value()
        } catch is CancellationError {
            // Supersession and Quick Look dismissals are normal lifecycle
            // events, not preview failures worth an error-level log entry.
            throw CancellationError()
        } catch {
            let code = QuickLookDiagnostics.failureCode(for: error)
            Self.logger.error(
                "Preview preparation failed: \(code.rawValue, privacy: .public)")
            throw error
        }
    }
}
