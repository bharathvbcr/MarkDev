//
//  PreviewViewController.swift
//  MarkDevQuickLook
//
//  The Space-bar preview in Finder.
//

import AppKit
import MarkDevKit
import QuickLookUI

/// Renders a Markdown file into Quick Look's preview panel.
///
/// The whole controller is a host for ``MarkDevPreviewController``: the
/// preview is the editor in reading mode, so what Finder shows on Space is
/// what the app shows when the note is opened. Nothing about the rendering
/// lives here.
final class PreviewViewController: NSViewController, QLPreviewingController {
    private let preview = MarkdownPreviewController()

    override func loadView() {
        view = preview.view
    }

    func preparePreviewOfFile(at url: URL) async throws {
        // Read off the main actor: Quick Look calls this for files that may
        // live on a slow or network volume, and blocking the main thread of a
        // preview extension is what makes Space feel broken.
        let data = try await Task.detached(priority: .userInitiated) {
            try Data(contentsOf: url)
        }.value

        // Latin-1 as a fallback rather than a thrown error: a note saved by an
        // older tool is still worth previewing, and Quick Look's alternative
        // is a blank panel that explains nothing.
        let markdown =
            String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""

        await MainActor.run {
            preview.show(markdown, directory: url.deletingLastPathComponent())
        }
    }
}
