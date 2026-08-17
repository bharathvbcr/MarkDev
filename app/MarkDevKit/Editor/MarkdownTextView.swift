//
//  MarkdownTextView.swift
//  MarkDevKit
//
//  The TextKit 2 writing surface.
//

@preconcurrency import AppKit

/// A Markdown editor built on TextKit 2 with live preview.
///
/// The TextKit 2 object graph is assembled explicitly —
/// `NSTextContentStorage` → `NSTextLayoutManager` → `NSTextContainer` — and
/// handed to the designated initialiser, which is the supported way to get a
/// TextKit 2 stack in an `NSTextView` *subclass*.
///
/// Everything specific to live preview lives in three overrides:
/// `setSelectedRanges` (caret skips collapsed syntax), `didChangeText`
/// (reparse), and the typing-attribute fix-up. There is no parallel text
/// engine.
@MainActor
public final class MarkdownTextView: NSTextView {
    /// Visual configuration. Setting it restyles.
    public var theme: EditorTheme = .standard {
        didSet { restyle() }
    }

    /// How much syntax is shown. Setting it restyles.
    public var mode: EditorMode = .livePreview {
        didSet {
            // Reading mode is genuinely read-only, which is also what lets a
            // plain click follow a wikilink: an editable text view treats a
            // click on a link as "put the caret here" instead.
            isEditable = mode != .reading
            restyle()
        }
    }

    /// The most recent parse. Read-only to callers; the outline, backlinks
    /// panel, and inspector all read from here rather than reparsing.
    public private(set) var parsed: ParsedDocument = .empty {
        didSet { ornamentIndex = InlineOrnaments(document: parsed) }
    }

    /// Ornaments for the current parse, rebuilt with it.
    ///
    /// Derived once here rather than per fragment: the layout delegate runs
    /// for every line, and rebuilding this there would make it O(lines).
    private var ornamentIndex: InlineOrnaments = .empty

    /// Called after every reparse, for observers such as the outline view.
    public var onParse: ((ParsedDocument) -> Void)?

    /// Called with a `[[wikilink]]` target when one is clicked.
    public var onFollowWikiLink: ((String) -> Void)?

    /// Currently collapsed ranges.
    private var hiddenRanges: HiddenRanges = .none

    /// Which blocks are revealed, cached so caret movement only restyles when
    /// the answer actually changes. Without this, every arrow key would
    /// restyle the whole document.
    private var revealedBlocks: Set<Int> = []

    /// Guards against reentrant styling.
    private var isStyling = false

    /// Where the in-flight edit landed, so the restyle after it can be
    /// scoped. Cleared once consumed; `nil` means "restyle everything".
    private var pendingEditedRange: NSRange?

    /// The edit captured from the storage delegate, awaiting application to
    /// the incremental document.
    private var pendingEdit: (old: NSRange, replacement: String)?

    /// Holds the parse across edits so unchanged structure is not reparsed.
    private var document = IncrementalDocument(text: "")

    // MARK: - Construction

    /// Builds a text view backed by a TextKit 2 stack.
    public static func make(theme: EditorTheme = .standard) -> MarkdownTextView {
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)

        let container = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.textContainer = container

        let view = MarkdownTextView(frame: .zero, textContainer: container)
        view.theme = theme
        view.configure()
        // Set after `configure` so the delegate never sees a half-built view.
        layoutManager.delegate = view
        return view
    }

    private func configure() {
        isRichText = false
        isEditable = true
        isSelectable = true
        allowsUndo = true
        // Markdown is plain text; letting AppKit substitute typographic
        // quotes and dashes would silently rewrite the file on disk.
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false

        // Find and replace over the document, using AppKit's own find bar
        // rather than a reimplementation. It searches text storage, which
        // still holds every collapsed syntax marker — so `**bold**` is
        // findable by its asterisks in live preview, exactly as it would be
        // in source mode. That is the same property that keeps ⌘C copying
        // real Markdown; see ``HiddenRanges``.
        usesFindBar = true
        isIncrementalSearchingEnabled = true

        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        textContainerInset = theme.insets
        drawsBackground = false

        font = theme.bodyFont
        textColor = theme.textColor
        insertionPointColor = theme.accentColor
        // The styler colours wikilinks itself; without this AppKit would
        // repaint them its own blue-underlined default.
        linkTextAttributes = [:]
    }

    // MARK: - Content

    /// Replaces the document text and reparses from scratch.
    public func setMarkdown(_ markdown: String) {
        guard let storage = textStorage else { return }
        storage.setAttributedString(NSAttributedString(string: markdown))
        pendingEdit = nil
        document.rebuild(from: markdown)
        parsed = document.parsed
        revealedBlocks = RevealPolicy.revealedBlocks(
            in: parsed, selection: selectedRange(), mode: mode)
        restyle()
        onParse?(parsed)
    }

    /// The current document text.
    public var markdown: String {
        // Reads storage, not a rendering of it — collapsed syntax is still
        // present, so this round-trips exactly.
        textStorage?.string ?? ""
    }

    // MARK: - Parsing and styling

    /// Reparses and restyles.
    ///
    /// `editedRange`, when known, scopes the restyle to the affected blocks.
    /// Restyling the whole buffer per keystroke is O(document) and stalls
    /// typing in a long file.
    public func reparse(editedRange: NSRange? = nil) {
        let previous = parsed
        let text = markdown
        if let edit = pendingEdit {
            document.apply(range: edit.old, replacement: edit.replacement, fullText: text)
            pendingEdit = nil
        } else {
            document.rebuild(from: text)
        }
        parsed = document.parsed
        revealedBlocks = RevealPolicy.revealedBlocks(
            in: parsed, selection: selectedRange(), mode: mode)

        restyle(scope: incrementalScope(from: previous, to: parsed, edited: editedRange))
        onParse?(parsed)
    }

    /// The range worth restyling after an edit, or `nil` to restyle it all.
    ///
    /// Attributes in `NSTextStorage` shift with the text around them, so an
    /// ordinary insertion leaves every other block correctly styled already.
    /// The exception is an edit that changes how *later* text parses — typing
    /// an opening fence swallows the rest of the file — which shows up as a
    /// changed sequence of block kinds. That case falls back to a full
    /// restyle rather than trying to be clever about it.
    private func incrementalScope(
        from previous: ParsedDocument,
        to current: ParsedDocument,
        edited: NSRange?
    ) -> NSRange? {
        guard let edited, !previous.blocks.isEmpty, !current.blocks.isEmpty else { return nil }

        // Any change in block structure means later text may parse
        // differently; restyle everything.
        guard previous.blocks.count == current.blocks.count else { return nil }
        for (old, new) in zip(previous.blocks, current.blocks) where old.kind != new.kind {
            return nil
        }

        // Structure held: restyle the blocks the edit touched.
        var scope = edited
        for block in current.blocks
        where NSIntersectionRange(block.range, edited).length > 0 || block.range.contains(edited.location) {
            scope = NSUnionRange(scope, block.range)
        }
        return scope
    }

    /// Reapplies attributes for the current parse and selection.
    private func restyle(scope: NSRange? = nil) {
        guard !isStyling, let storage = textStorage else { return }
        isStyling = true
        defer { isStyling = false }

        hiddenRanges = HiddenRanges(
            document: parsed, selection: selectedRange(), mode: mode, isEditing: hasKeyboardFocus)
        MarkdownStyler.apply(
            document: parsed, hidden: hiddenRanges, to: storage, theme: theme, scope: scope,
            drawsReplacements: mode != .source)
        // Semantic token colours must be the final foreground layer. The
        // base Markdown pass intentionally resets stale attributes first.
        applyCodeHighlighting(in: storage, scope: scope)
        repairTypingAttributes()
    }

    /// Colours fenced code through the Rust tree-sitter core.
    ///
    /// Applied after the styler's own attributes so language colours win over
    /// the flat monospace treatment the block-level pass gives code.
    private func applyCodeHighlighting(in storage: NSTextStorage, scope: NSRange?) {
        let full = NSRange(location: 0, length: storage.length)
        let target = scope ?? full
        let text = storage.string as NSString

        for block in parsed.blocks where block.kind == .codeBlock {
            guard let language = block.info, !language.isEmpty else { continue }
            let range = NSIntersectionRange(block.range, full)
            guard range.length > 0, NSIntersectionRange(range, target).length > 0 else { continue }

            // The fence lines are syntax, not code; highlighting them would
            // colour the ``` as if it were part of the program.
            guard let body = codeBody(of: block, in: text) else { continue }
            let code = text.substring(with: body)

            for span in SyntaxHighlighter.shared.spans(language: language, code: code) {
                let absolute = NSRange(
                    location: body.location + span.range.location, length: span.range.length)
                guard absolute.location + absolute.length <= full.length else { continue }
                storage.addAttribute(
                    .foregroundColor, value: theme.color(for: span.kind), range: absolute)
            }
        }
    }

    /// The code inside a fence, excluding the delimiter lines.
    private func codeBody(of block: BlockDescriptor, in text: NSString) -> NSRange? {
        let range = NSIntersectionRange(block.range, NSRange(location: 0, length: text.length))
        guard range.length > 0 else { return nil }

        // Markers cover the fence lines; the body is what they leave behind.
        let fenceMarkers = parsed.markers
            .map(\.range)
            .filter { NSIntersectionRange($0, range).length > 0 }
            .sorted { $0.location < $1.location }

        var start = range.location
        var end = range.location + range.length
        if let first = fenceMarkers.first, first.location <= start {
            start = first.location + first.length
        }
        if let last = fenceMarkers.last, last.location + last.length >= end {
            end = last.location
        }
        guard end > start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    /// Whether this view holds keyboard focus.
    ///
    /// A view with no window counts as focused. Focus is about *another*
    /// responder holding the keyboard, which only means anything once there
    /// is a window to hold it — a detached view driven programmatically
    /// should behave as though the caret it was given is real.
    private var hasKeyboardFocus: Bool {
        guard let window else { return true }
        return window.firstResponder === self
    }

    /// Recomputes the reveal set, restyling only the blocks whose visibility
    /// actually flipped.
    private func updateRevealIfNeeded() {
        let next = RevealPolicy.revealedBlocks(
            in: parsed, selection: selectedRange(), mode: mode)
        guard next != revealedBlocks else { return }

        // Only the blocks entering or leaving the revealed set need work —
        // typically the one being left and the one being entered.
        let changed = next.symmetricDifference(revealedBlocks)
        revealedBlocks = next

        var scope: NSRange?
        for index in changed where parsed.blocks.indices.contains(index) {
            let range = parsed.blocks[index].range
            scope = scope.map { NSUnionRange($0, range) } ?? range
        }
        restyle(scope: scope)
    }

    /// Stops newly typed text inheriting a collapsed marker's 0.01pt font.
    ///
    /// The caret can legitimately sit immediately after hidden syntax — at a
    /// block boundary, for instance. Without this, the next character typed
    /// there would be invisible, which looks exactly like dropped input.
    private func repairTypingAttributes() {
        var attributes = typingAttributes
        if let font = attributes[.font] as? NSFont,
            font.pointSize <= EditorTheme.hiddenMarkerFontSize
        {
            attributes[.font] = theme.bodyFont
            attributes[.foregroundColor] = theme.textColor
            typingAttributes = attributes
        }
    }

    /// Scrolls to a UTF-16 offset and puts the caret there.
    ///
    /// Selecting rather than only scrolling matters: it reveals the target
    /// block's syntax under the live-preview policy, so arriving at a heading
    /// shows the heading you can edit.
    public func reveal(offset: Int) {
        let length = (markdown as NSString).length
        let clamped = max(0, min(offset, length))
        setSelectedRange(NSRange(location: clamped, length: 0))
        scrollRangeToVisible(NSRange(location: clamped, length: 0))
    }

    // MARK: - Overrides

    /// Follows a wikilink click.
    ///
    /// Only links using MarkDev's own scheme are handled here; anything else
    /// falls through to AppKit, which opens ordinary URLs as expected.
    public override func clicked(onLink link: Any, at charIndex: Int) {
        let url: URL? =
            (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        guard let url, url.scheme == MarkdownStyler.wikiLinkScheme else {
            super.clicked(onLink: link, at: charIndex)
            return
        }
        // The target rides in the host, percent-decoded back to its raw form.
        let target = (url.host(percentEncoded: false) ?? url.absoluteString)
            .replacingOccurrences(of: "\(MarkdownStyler.wikiLinkScheme)://", with: "")
        onFollowWikiLink?(target.removingPercentEncoding ?? target)
    }

    public override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        // Focus changes what is revealed, so the document has to restyle.
        if became { restyle() }
        return became
    }

    public override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { restyle() }
        return resigned
    }

    public override func didChangeText() {
        super.didChangeText()
        let edited = pendingEditedRange
        pendingEditedRange = nil
        reparse(editedRange: edited)
    }

    /// Captures every user edit before it is applied.
    ///
    /// This is the hook rather than `NSTextStorageDelegate`, because in
    /// TextKit 2 the `NSTextContentStorage` is itself the storage's delegate —
    /// taking that slot would displace it. `shouldChangeText` sees typing,
    /// paste, delete, and undo alike, and uniquely gives both the range being
    /// replaced *and* the replacement, which is exactly what the incremental
    /// parser needs.
    public override func shouldChangeText(
        in affectedCharRange: NSRange,
        replacementString: String?
    ) -> Bool {
        if let replacementString, !isStyling {
            pendingEdit = (affectedCharRange, replacementString)
            pendingEditedRange = NSRange(
                location: affectedCharRange.location,
                length: (replacementString as NSString).length)
        }
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    /// Diagnostics for the incremental parser: how many edits avoided a
    /// reparse, how many needed one, and how often the two text copies had to
    /// be resynchronised.
    public var parseStatistics: (shifted: Int, full: Int, resyncs: Int) {
        (document.shiftedEdits, document.fullReparses, document.resyncs)
    }

    /// Moves the caret over collapsed syntax as though it were not there.
    ///
    /// This is the one place the editor must disagree with TextKit: the
    /// characters exist in storage, so left/right arrow would otherwise stop
    /// inside an invisible `**` and appear to hang. Ranged selections are
    /// left alone — a selection that spans hidden syntax *should* include it,
    /// so copying yields real Markdown.
    public override func setSelectedRanges(
        _ ranges: [NSValue],
        affinity: NSSelectionAffinity,
        stillSelecting: Bool
    ) {
        let adjusted: [NSValue]
        if !hiddenRanges.ranges.isEmpty, !stillSelecting, ranges.count == 1,
            let range = ranges.first?.rangeValue, range.length == 0
        {
            let previous = selectedRange()
            let forward = range.location >= previous.location
            let moved = hiddenRanges.nudge(range.location, forward: forward)
            adjusted = [NSValue(range: NSRange(location: moved, length: 0))]
        } else {
            adjusted = ranges
        }

        super.setSelectedRanges(adjusted, affinity: affinity, stillSelecting: stillSelecting)

        if !stillSelecting, !isStyling {
            updateRevealIfNeeded()
        }
    }
}

extension MarkdownTextView: @preconcurrency NSTextLayoutManagerDelegate {
    /// Hands back a fragment that knows how to draw its block's decoration.
    ///
    /// Called during layout for every paragraph, so the decoration lookup has
    /// to be cheap — it scans the block list, which is small and already in
    /// memory.
    public func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: any NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        let fragment = MarkdownLayoutFragment(
            textElement: textElement, range: textElement.elementRange)
        fragment.palette = BlockDecorationPalette(theme: theme)

        guard let documentStart = textLayoutManager.documentRange.location as NSTextLocation?,
            let elementRange = textElement.elementRange
        else { return fragment }

        let start = textLayoutManager.offset(from: documentStart, to: elementRange.location)
        let end = textLayoutManager.offset(from: documentStart, to: elementRange.endLocation)
        guard start >= 0, end >= start else { return fragment }

        let range = NSRange(location: start, length: end - start)
        fragment.documentRange = range
        fragment.decoration = BlockDecoration.decoration(for: range, in: parsed)
        // Source mode shows the characters as written, so nothing may be drawn
        // over them — a checkbox on top of a `[ ]` the reader asked to see is
        // the one thing source mode must not do.
        fragment.ornaments = mode == .source ? [] : ornamentIndex.ornaments(in: range)
        return fragment
    }
}
