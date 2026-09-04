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
    /// Called with the underlying text view when this editor is the one the
    /// reader is working in — on first appearance, and whenever it takes the
    /// keyboard. The writing tools attach to whatever arrives here.
    public var onSurface: ((MarkdownTextView) -> Void)?
    /// Called when the selection changes with (words, characters).
    public var onSelectionStats: ((Int, Int) -> Void)?
    /// Called when a link is hovered or unhovered.
    public var onHoveredLink: ((String?) -> Void)?
    /// Called when the editor refuses a document and is therefore showing
    /// nothing. Wired to the window's alert, because a blank page is otherwise
    /// the only thing the reader is told.
    public var onDocumentRejected: ((String) -> Void)?
    /// Set to scroll the editor to an offset; applied once per request.
    public var reveal: RevealRequest?

    public init(
        text: Binding<String>,
        mode: EditorMode = .livePreview,
        theme: EditorTheme = .standard,
        documentDirectory: URL? = nil,
        reveal: RevealRequest? = nil,
        onParse: ((ParsedDocument) -> Void)? = nil,
        onFollowWikiLink: ((String) -> Void)? = nil,
        onSurface: ((MarkdownTextView) -> Void)? = nil,
        onSelectionStats: ((Int, Int) -> Void)? = nil,
        onHoveredLink: ((String?) -> Void)? = nil,
        onDocumentRejected: ((String) -> Void)? = nil
    ) {
        self._text = text
        self.mode = mode
        self.theme = theme
        self.documentDirectory = documentDirectory
        self.reveal = reveal
        self.onParse = onParse
        self.onFollowWikiLink = onFollowWikiLink
        self.onSurface = onSurface
        self.onSelectionStats = onSelectionStats
        self.onDocumentRejected = onDocumentRejected
        self.onHoveredLink = onHoveredLink
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
        textView.onSelectionStatsChanged = { [weak coordinator = context.coordinator] words, chars in
            coordinator?.onSelectionStats?(words, chars)
        }
        textView.onHoveredLinkChanged = { [weak coordinator = context.coordinator] link in
            coordinator?.onHoveredLink?(link)
        }
        textView.onFocus = { [weak coordinator = context.coordinator, weak textView] in
            guard let textView else { return }
            coordinator?.onSurface?(textView)
        }
        textView.setMarkdown(text)

        let scrollView = ScrollingTextView.scrollView(hosting: textView)

        context.coordinator.textView = textView
        // Deferred for the same reason `onParse` is: this runs inside
        // SwiftUI's update pass, and a callback that touches @State from
        // there is dropped. Without it a fresh window has no writing surface
        // registered until the editor is first clicked, so ⌘⇧E does nothing.
        Task { @MainActor [weak textView] in
            guard let textView else { return }
            context.coordinator.onSurface?(textView)
        }
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MarkdownTextView else { return }

        context.coordinator.onParse = onParse
        context.coordinator.onFollowWikiLink = onFollowWikiLink
        context.coordinator.onSurface = onSurface
        context.coordinator.onSelectionStats = onSelectionStats
        context.coordinator.onHoveredLink = onHoveredLink
        context.coordinator.onDocumentRejected = onDocumentRejected
        if textView.mode != mode { textView.mode = mode }
        if textView.baseTheme.bodyFont != theme.bodyFont || textView.theme.lineSpacing != theme.lineSpacing {
            textView.setBaseTheme(theme)
        }
        // Assigning re-renders only on a genuine change; the property guards
        // itself, so a document switching folders repaints its images and one
        // that did not costs nothing.
        textView.documentDirectory = documentDirectory

        // Only push text in when it genuinely differs, or every keystroke
        // would reset the document and collapse the selection.
        if context.coordinator.shouldPush(text, currentlyShowing: textView.markdown) {
            let selection = textView.selectedRange()
            let accepted = textView.setMarkdown(text)
            context.coordinator.recordPush(of: text, accepted: accepted)
            if accepted {
                let length = (textView.markdown as NSString).length
                textView.setSelectedRange(
                    NSRange(location: min(selection.location, length), length: 0))
            } else {
                // Reported once per distinct document, not once per update
                // pass: the alert is modal, and a window that re-raises it
                // every time SwiftUI recomputes cannot be dismissed.
                context.coordinator.onDocumentRejected?(
                    "This document could not be opened. It is either larger than "
                        + "MarkDev can edit safely, or it contains bytes that are not text.")
            }
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
        coordinator.onSurface = onSurface
        coordinator.onSelectionStats = onSelectionStats
        coordinator.onHoveredLink = onHoveredLink
        return coordinator
    }

    @MainActor
    public final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        var onParse: ((ParsedDocument) -> Void)?
        var onFollowWikiLink: ((String) -> Void)?
        var onSurface: ((MarkdownTextView) -> Void)?
        var onSelectionStats: ((Int, Int) -> Void)?
        var onHoveredLink: ((String?) -> Void)?
        var onDocumentRejected: ((String) -> Void)?
        /// The exact text the editor last refused.
        ///
        /// `updateNSView` pushes text in whenever it differs from the view's,
        /// and a refused document never becomes the view's — so the condition
        /// stays true and SwiftUI re-attempts the same rejected parse on every
        /// update pass, for the life of the window. Holding the string costs
        /// nothing (Swift strings are copy-on-write, so this is a retain) and
        /// turns an unbounded retry into one attempt per distinct document.
        var refusedText: String?
        var appliedReveal: UUID?
        weak var textView: MarkdownTextView?

        init(text: Binding<String>, onParse: ((ParsedDocument) -> Void)?) {
            self.text = text
            self.onParse = onParse
        }

        /// Whether `text` should be handed to the view.
        ///
        /// Pure, and separate from `updateNSView`, because that method takes a
        /// SwiftUI `Context` no test can construct — leaving the rule that
        /// bounds the retry loop the one part of this file nothing could
        /// assert. The rule: push when the view does not already hold the
        /// text, unless that exact text is the one it just refused.
        func shouldPush(_ text: String, currentlyShowing current: String) -> Bool {
            text != current && refusedText != text
        }

        /// Records the outcome of a push so the next update can act on it.
        func recordPush(of text: String, accepted: Bool) {
            refusedText = accepted ? nil : text
        }

        public func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? MarkdownTextView else { return }
            text.wrappedValue = textView.markdown
        }
    }
}
