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
    /// Called after each reparse — the outline and backlinks panels observe
    /// this rather than parsing the document a second time.
    public var onParse: ((ParsedDocument) -> Void)?
    /// Called with a `[[wikilink]]` target when one is clicked.
    public var onFollowWikiLink: ((String) -> Void)?
    /// Called with a `#tag` when one is clicked.
    public var onSelectTag: ((String) -> Void)?
    /// Called when a code or diagram block's pop-out control is clicked.
    public var onExpandBlock: ((BlockExcerpt) -> Void)?
    /// Supplies a preview of a `[[wikilink]]`'s target on hover.
    public var peekProvider: ((String) -> NotePeek?)?
    /// Set to scroll the editor to an offset; applied once per request.
    public var reveal: RevealRequest?

    public init(
        text: Binding<String>,
        mode: EditorMode = .livePreview,
        theme: EditorTheme = .standard,
        reveal: RevealRequest? = nil,
        onParse: ((ParsedDocument) -> Void)? = nil,
        onFollowWikiLink: ((String) -> Void)? = nil,
        onSelectTag: ((String) -> Void)? = nil,
        onExpandBlock: ((BlockExcerpt) -> Void)? = nil,
        peekProvider: ((String) -> NotePeek?)? = nil
    ) {
        self._text = text
        self.mode = mode
        self.theme = theme
        self.reveal = reveal
        self.onParse = onParse
        self.onFollowWikiLink = onFollowWikiLink
        self.onSelectTag = onSelectTag
        self.onExpandBlock = onExpandBlock
        self.peekProvider = peekProvider
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let textView = MarkdownTextView.make(theme: theme)
        // Assigning `mode` also sets editability, so this must come before
        // any content is loaded.
        textView.mode = mode
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
        textView.onSelectTag = { [weak coordinator = context.coordinator] tag in
            coordinator?.onSelectTag?(tag)
        }
        textView.onExpandBlock = { [weak coordinator = context.coordinator] excerpt in
            coordinator?.onExpandBlock?(excerpt)
        }
        textView.peekProvider = { [weak coordinator = context.coordinator] target in
            coordinator?.peekProvider?(target)
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
        context.coordinator.onSelectTag = onSelectTag
        context.coordinator.onExpandBlock = onExpandBlock
        context.coordinator.peekProvider = peekProvider
        if textView.mode != mode { textView.mode = mode }

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
        var onSelectTag: ((String) -> Void)?
        var onExpandBlock: ((BlockExcerpt) -> Void)?
        var peekProvider: ((String) -> NotePeek?)?
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
