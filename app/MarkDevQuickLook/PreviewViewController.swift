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
/// Quick Look extensions are memory-capped and are judged on how fast they
/// paint, so this path shares `MarkDevKit`'s read-only renderer and never
/// touches the editing machinery.
final class PreviewViewController: NSViewController, QLPreviewingController {
    /// The same scrolling surface the editor uses, minus the editing
    /// machinery. A bare `NSTextView` scrolls but does not track its
    /// viewport's width, so resizing the Quick Look panel would clip the
    /// preview instead of rewrapping it.
    private let textView = ScrollingTextView()

    override func loadView() {
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 24, height: 24)

        view = ScrollingTextView.scrollView(hosting: textView)
    }

    func preparePreviewOfFile(at url: URL) async throws {
        // Read off the main actor: Quick Look calls this on a file that may
        // live on a slow or network volume.
        let source = try await Task.detached(priority: .userInitiated) {
            try String(contentsOf: url, encoding: .utf8)
        }.value

        let parsed = ParsedDocument.parse(source)
        let rendered = PreviewRenderer.attributedString(for: source, parsed: parsed)

        await MainActor.run {
            textView.textStorage?.setAttributedString(rendered)
        }
    }
}
