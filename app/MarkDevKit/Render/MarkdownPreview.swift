//
//  MarkdownPreview.swift
//  MarkDevKit
//
//  The read-only surface, shared by Finder Quick Look and the in-app peek.
//

import AppKit

/// A read-only Markdown view, ready to drop into a Quick Look extension or a
/// peek panel.
///
/// # Why this is the editor, not a second renderer
///
/// This used to be a separate `PreviewRenderer` that flattened a parse into an
/// attributed string. It was deleted, because a second implementation of
/// "render Markdown" drifts from the first — and the parts it lost were
/// exactly the parts worth previewing. Syntax markers are *deleted* on that
/// path, so a table collapsed to `NameAge` with its separators gone, a `---`
/// rule vanished to an empty line, and a `- [x]` disappeared entirely: every
/// construct whose meaning lives in a drawn replacement rather than in
/// characters.
///
/// ``EditorMode/reading`` already means "all syntax hidden, nothing editable",
/// and the layout fragments already draw code panels, checkboxes, tables,
/// formulas, and diagrams. Preview is that mode with no caret to reveal
/// anything — so it is the same engine, configured, and there is nothing left
/// to drift.
///
/// The extension is memory-capped and judged on time-to-first-paint, which was
/// the original argument for a lighter path. It does not survive contact with
/// the measurements: the parse is the same parse, and TextKit 2 lays out only
/// the visible viewport, so a 10,000-line note costs a screenful either way.
@MainActor
public final class MarkdownPreviewController {
    /// The view to install. Scrolls, draws no background of its own so the
    /// host's material shows through.
    public let view: NSScrollView

    private let textView: MarkdownTextView

    public init(theme: EditorTheme = .standard) {
        textView = MarkdownTextView.make(theme: theme)
        // Before any content: assigning the mode also drops editability, and
        // a preview must never be typed into.
        textView.mode = .reading

        // Through the same helper the editor uses, not a scroll view built by
        // hand here. TextKit 2 lays out only the visible viewport and needs
        // the clip view's bounds-change notifications to learn it moved; a
        // hand-rolled host that omits them scrolls into blank space, and the
        // omission is invisible until someone scrolls a long note.
        view = ScrollingTextView.scrollView(hosting: textView)
    }

    /// Reads `url` and previews it.
    ///
    /// Decoding falls back to Latin-1 rather than failing: a note saved by an
    /// older tool is still worth previewing, and Quick Look's alternative is a
    /// blank panel with no explanation.
    public func load(contentsOf url: URL) throws {
        let data = try NoteTextCache.shared.read(
            url, maximumBytes: MarkdownReadLimits.maximumPreviewBytes)
        let markdown =
            String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        show(markdown, directory: url.deletingLastPathComponent())
    }

    /// What a reader sees instead of an empty panel when a file is refused.
    ///
    /// Deliberately Markdown, and deliberately short: it goes through the same
    /// editor as any other document, and anything long enough to wrap would
    /// need a width this panel does not promise.
    static let refusalNotice = """
        ## Cannot be previewed

        This file is either larger than MarkDev can render safely, or it \
        contains bytes that are not text.
        """

    /// Previews `markdown`, resolving relative image paths against `directory`.
    public func show(_ markdown: String, directory: URL?) {
        // Set first: every embedded image resolves against it, and setting it
        // afterwards would invalidate the layout that was just built.
        textView.documentDirectory = directory
        if !textView.setMarkdown(markdown) {
            // `load` already goes out of its way to avoid "a blank panel with
            // no explanation" for a decoding failure, then handed the refusal
            // path exactly that. Quick Look cannot raise an alert, but it can
            // render a sentence — and this surface renders Markdown, so it
            // costs nothing to say what happened.
            //
            // The notice resolves no pictures, so it takes no directory: left
            // pointing at the refused file's folder, a relative path in the
            // notice would resolve against a stranger's documents.
            textView.documentDirectory = nil
            textView.setMarkdown(Self.refusalNotice)
        }
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        view.contentView.scroll(to: .zero)
    }

    /// The text currently previewed.
    public var markdown: String { textView.markdown }
}
