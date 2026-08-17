//
//  MarkdownEditorView.swift
//  MarkDevKit
//
//  SwiftUI bridge for the TextKit 2 editor.
//

import AppKit
import SwiftUI

/// SwiftUI wrapper around ``MarkdownTextView``.
///
/// The editor is AppKit because TextKit 2 is; the chrome around it is
/// SwiftUI because that is where Liquid Glass lives. This is the seam.
public struct MarkdownEditorView: NSViewRepresentable {
    @Binding public var text: String
    public var mode: EditorMode
    public var theme: EditorTheme
    /// The folder the document was loaded from, for resolving relative image
    /// paths. An unsaved document has none, and its images cannot resolve —
    /// which is correct: there is nothing yet for `./shot.png` to be relative
    /// *to*.
    public var documentDirectory: URL?
    /// Called after each reparse — the outline and backlinks panels observe
    /// this rather than parsing the document a second time.
    public var onParse: ((ParsedDocument) -> Void)?
    /// Called with a `[[wikilink]]` target when one is clicked.
    public var onFollowWikiLink: ((String) -> Void)?
    /// Set to scroll the editor to an offset; applied once per request.
    public var reveal: RevealRequest?

    public init(
        text: Binding<String>,
        mode: EditorMode = .livePreview,
        theme: EditorTheme = .standard,
        documentDirectory: URL? = nil,
        reveal: RevealRequest? = nil,
        onParse: ((ParsedDocument) -> Void)? = nil,
        onFollowWikiLink: ((String) -> Void)? = nil
    ) {
        self._text = text
        self.mode = mode
        self.theme = theme
        self.documentDirectory = documentDirectory
        self.reveal = reveal
        self.onParse = onParse
        self.onFollowWikiLink = onFollowWikiLink
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let textView = MarkdownTextView.make(theme: theme)
        // Assigning `mode` also sets editability, so this must come before
        // any content is loaded.
        textView.mode = mode
        // Before `setMarkdown`, so the first layout pass can already resolve
        // embedded images instead of drawing a failure and correcting itself.
        textView.documentDirectory = documentDirectory
        textView.delegate = context.coordinator
        // Deferred: the first parse happens inside `setMarkdown` below, which
        // runs during SwiftUI's view-update pass. Touching @State there is
        // dropped, so observers would miss the initial document and show
        // stale counts until the first keystroke.
        textView.onParse = { document in
            Task { @MainActor in context.coordinator.onParse?(document) }
        }
        textView.onFollowWikiLink = { [weak coordinator = context.coordinator] target in
            coordinator?.onFollowWikiLink?(target)
        }
        textView.setMarkdown(text)

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        context.coordinator.textView = textView
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MarkdownTextView else { return }

        context.coordinator.onParse = onParse
        context.coordinator.onFollowWikiLink = onFollowWikiLink
        if textView.mode != mode { textView.mode = mode }
        // Assigning re-renders only on a genuine change; the property guards
        // itself, so a document switching folders repaints its images and one
        // that did not costs nothing.
        textView.documentDirectory = documentDirectory

        // Only push text in when it genuinely differs, or every keystroke
        // would reset the document and collapse the selection.
        if textView.markdown != text {
            let selection = textView.selectedRange()
            textView.setMarkdown(text)
            let length = (textView.markdown as NSString).length
            textView.setSelectedRange(
                NSRange(location: min(selection.location, length), length: 0))
        }

        // Applied once per request. Comparing identities rather than offsets
        // is what lets the same outline row be clicked twice in a row.
        if let reveal, context.coordinator.appliedReveal != reveal.id {
            context.coordinator.appliedReveal = reveal.id
            // After the text push above, so the offset lands in the document
            // the request was made against.
            DispatchQueue.main.async { textView.reveal(offset: reveal.offset) }
        }
    }

    public func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(text: $text, onParse: onParse)
        coordinator.onFollowWikiLink = onFollowWikiLink
        return coordinator
    }

    @MainActor
    public final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        var onParse: ((ParsedDocument) -> Void)?
        var onFollowWikiLink: ((String) -> Void)?
        var appliedReveal: UUID?
        weak var textView: MarkdownTextView?

        init(text: Binding<String>, onParse: ((ParsedDocument) -> Void)?) {
            self.text = text
            self.onParse = onParse
        }

        public func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? MarkdownTextView else { return }
            text.wrappedValue = textView.markdown
        }
    }
}
