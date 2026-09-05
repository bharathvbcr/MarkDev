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
    /// Stable identity for this split's speculative render work. Omitted by
    /// standalone consumers, whose mounted text view creates its own owner.
    public var prefetchOwner: ContentPrefetcher.Owner?
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
    /// Registers the underlying AppKit view without claiming keyboard focus.
    /// The returned token names this exact mount until ``onUnmount`` retires
    /// it; a replacement view receives a different token.
    public var onMount: ((MarkdownTextView) -> EditorSurfaceMountToken?)?
    /// Called only when this exact mounted view takes the keyboard.
    public var onFocus: ((EditorSurfaceMountToken, MarkdownTextView) -> Void)?
    /// Retires the exact mount during SwiftUI dismantle. A stale callback may
    /// arrive after a replacement has mounted, so consumers compare the token.
    public var onUnmount: ((EditorSurfaceMountToken, MarkdownTextView) -> Void)?
    /// Called when the selection changes with (words, characters).
    public var onSelectionStats: ((Int, Int) -> Void)?
    /// Called when a link is hovered or unhovered.
    public var onHoveredLink: ((String?) -> Void)?
    /// Called when the editor refuses a document and is therefore showing
    /// nothing. Wired to the window's alert, because a blank page is otherwise
    /// the only thing the reader is told.
    public var onDocumentRejected: ((String) -> Void)?
    /// Called for a privacy-safe image paste/drop failure.
    public var onAssetIngestionError: ((String) -> Void)?
    /// Set to scroll the editor to an offset; applied once per request.
    public var reveal: RevealRequest?

    public init(
        text: Binding<String>,
        mode: EditorMode = .livePreview,
        theme: EditorTheme = .standard,
        prefetchOwner: ContentPrefetcher.Owner? = nil,
        documentDirectory: URL? = nil,
        reveal: RevealRequest? = nil,
        onParse: ((ParsedDocument) -> Void)? = nil,
        onFollowWikiLink: ((String) -> Void)? = nil,
        onMount: ((MarkdownTextView) -> EditorSurfaceMountToken?)? = nil,
        onFocus: ((EditorSurfaceMountToken, MarkdownTextView) -> Void)? = nil,
        onUnmount: ((EditorSurfaceMountToken, MarkdownTextView) -> Void)? = nil,
        onSelectionStats: ((Int, Int) -> Void)? = nil,
        onHoveredLink: ((String?) -> Void)? = nil,
        onDocumentRejected: ((String) -> Void)? = nil,
        onAssetIngestionError: ((String) -> Void)? = nil
    ) {
        self._text = text
        self.mode = mode
        self.theme = theme
        self.prefetchOwner = prefetchOwner
        self.documentDirectory = documentDirectory
        self.reveal = reveal
        self.onParse = onParse
        self.onFollowWikiLink = onFollowWikiLink
        self.onMount = onMount
        self.onFocus = onFocus
        self.onUnmount = onUnmount
        self.onSelectionStats = onSelectionStats
        self.onDocumentRejected = onDocumentRejected
        self.onAssetIngestionError = onAssetIngestionError
        self.onHoveredLink = onHoveredLink
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let textView = MarkdownTextView.make(theme: theme)
        #if !MARKDEV_QUICKLOOK
        if let prefetchOwner {
            textView.setContentPrefetchOwner(prefetchOwner)
        }
        #endif
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
        textView.onAssetIngestionError = { [weak coordinator = context.coordinator] message in
            coordinator?.onAssetIngestionError?(message)
        }
        textView.onFocus = { [weak coordinator = context.coordinator, weak textView] in
            guard let textView else { return }
            coordinator?.focus(textView)
        }
        textView.setMarkdown(text)

        let scrollView = ScrollingTextView.scrollView(hosting: textView)

        context.coordinator.textView = textView
        // Registration mutates a plain weak registry, not SwiftUI view state,
        // so it is deliberately synchronous. The old deferred callback could
        // outlive dismantle and install a dead editor after its successor.
        context.coordinator.mount(textView)
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MarkdownTextView else { return }

        context.coordinator.onParse = onParse
        context.coordinator.onFollowWikiLink = onFollowWikiLink
        context.coordinator.onMount = onMount
        context.coordinator.onFocus = onFocus
        context.coordinator.onUnmount = onUnmount
        context.coordinator.onSelectionStats = onSelectionStats
        context.coordinator.onHoveredLink = onHoveredLink
        context.coordinator.onDocumentRejected = onDocumentRejected
        context.coordinator.onAssetIngestionError = onAssetIngestionError
        context.coordinator.mount(textView)
        #if !MARKDEV_QUICKLOOK
        if let prefetchOwner {
            textView.setContentPrefetchOwner(prefetchOwner)
        }
        #endif
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
        coordinator.onMount = onMount
        coordinator.onFocus = onFocus
        coordinator.onUnmount = onUnmount
        coordinator.onSelectionStats = onSelectionStats
        coordinator.onHoveredLink = onHoveredLink
        coordinator.onAssetIngestionError = onAssetIngestionError
        return coordinator
    }

    public static func dismantleNSView(
        _ scrollView: NSScrollView,
        coordinator: Coordinator
    ) {
        guard let textView = scrollView.documentView as? MarkdownTextView else { return }
        coordinator.unmount(textView)
        textView.onAssetIngestionError = nil
        textView.cancelAssetIngestion()
        #if !MARKDEV_QUICKLOOK
        textView.cancelContentPrefetching()
        #endif
        textView.onFocus = nil
        textView.delegate = nil
    }

    @MainActor
    public final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        var onParse: ((ParsedDocument) -> Void)?
        var onFollowWikiLink: ((String) -> Void)?
        var onMount: ((MarkdownTextView) -> EditorSurfaceMountToken?)?
        var onFocus: ((EditorSurfaceMountToken, MarkdownTextView) -> Void)?
        var onUnmount: ((EditorSurfaceMountToken, MarkdownTextView) -> Void)?
        var onSelectionStats: ((Int, Int) -> Void)?
        var onHoveredLink: ((String?) -> Void)?
        var onDocumentRejected: ((String) -> Void)?
        var onAssetIngestionError: ((String) -> Void)?
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
        private var mountToken: EditorSurfaceMountToken?

        init(text: Binding<String>, onParse: ((ParsedDocument) -> Void)?) {
            self.text = text
            self.onParse = onParse
        }

        func mount(_ textView: MarkdownTextView) {
            guard mountToken == nil, self.textView === textView else { return }
            mountToken = onMount?(textView)
        }

        func focus(_ textView: MarkdownTextView) {
            guard self.textView === textView, let mountToken else { return }
            onFocus?(mountToken, textView)
        }

        func unmount(_ textView: MarkdownTextView) {
            guard self.textView === textView, let mountToken else { return }
            self.mountToken = nil
            onUnmount?(mountToken, textView)
            self.textView = nil
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
