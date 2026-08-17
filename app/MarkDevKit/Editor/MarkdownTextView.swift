//
//  MarkdownTextView.swift
//  MarkDevKit
//
//  The TextKit 2 writing surface.
//

@preconcurrency import AppKit

/// One change to the text, as the storage reports it.
///
/// `range` is where the new text sits *after* the change, `delta` how much
/// longer the document became, and `replacement` the text now occupying
/// `range`. Everything the incremental parser and the restyle scope need is
/// derivable from those three.
public struct TextEdit: Sendable, Equatable {
    public let range: NSRange
    public let delta: Int
    public let replacement: String

    public init(range: NSRange, delta: Int, replacement: String) {
        self.range = range
        self.delta = delta
        self.replacement = replacement
    }

    /// The range this edit replaced, in the pre-edit document's coordinates.
    public var replacedRange: NSRange {
        NSRange(location: range.location, length: max(0, range.length - delta))
    }
}

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
    public private(set) var parsed: ParsedDocument = .empty

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

    /// Holds the parse across edits so unchanged structure is not reparsed.
    private var document = IncrementalDocument(text: "")

    /// Set while ``setMarkdown(_:)`` swaps the whole document, so the change
    /// notifications it provokes do not each start their own reparse of text
    /// that is about to be parsed anyway.
    private var isReplacingDocument = false

    /// The edit the text view announced through `shouldChangeText`, waiting
    /// for the `didChangeText` that applies it.
    private var announcedEdit: TextEdit?

    /// A change the storage has made that no reparse has accounted for yet.
    /// Cleared by ``reparse(edit:)``; anything still here when the catch-up
    /// runs is a change that arrived without announcing itself.
    private var unparsedChange: PendingChange?

    /// A storage change waiting to be parsed, and how much is known about it.
    private enum PendingChange {
        /// An edit whose extent is known, so the restyle can be scoped.
        case scoped(TextEdit)
        /// A change whose reported range made no sense. Reparse everything
        /// rather than trust it.
        case whole
    }

    /// Whether a catch-up is already queued, so a burst of storage edits
    /// schedules one pass rather than one per edit.
    private var isCatchUpScheduled = false

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

        if let storage = textStorage {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(storageDidProcessEditing(_:)),
                name: NSTextStorage.didProcessEditingNotification,
                object: storage)
        }
    }

    // MARK: - Content

    /// Replaces the document text and reparses from scratch.
    public func setMarkdown(_ markdown: String) {
        guard let storage = textStorage else { return }
        isReplacingDocument = true
        defer { isReplacingDocument = false }
        // Any edit still in flight described the document being replaced.
        announcedEdit = nil
        unparsedChange = nil
        storage.setAttributedString(NSAttributedString(string: markdown))
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
    /// `edit`, when known, scopes the restyle to what the edit actually
    /// changed. Restyling the whole buffer per keystroke is O(document) and
    /// stalls typing in a long file.
    public func reparse(edit: TextEdit? = nil) {
        unparsedChange = nil
        let previous = parsed
        let delta = edit?.delta ?? 0
        let editedRange = edit?.range
        let text = markdown
        var onlyOffsetsMoved = false
        if let edit {
            onlyOffsetsMoved = document.apply(
                range: edit.replacedRange, replacement: edit.replacement, fullText: text)
        } else {
            document.rebuild(from: text)
        }
        parsed = document.parsed

        // The blocks whose syntax appeared or disappeared join the scope. An
        // edit that moves the caret into another block changes how that block
        // is drawn without changing a single thing about the parse, so no
        // amount of comparing the two parses would find it.
        let revealedBefore = revealedRanges(of: revealedBlocks, in: previous)
            .map { shift($0, by: delta, at: editedRange) }
        revealedBlocks = RevealPolicy.revealedBlocks(
            in: parsed, selection: selectedRange(), mode: mode)
        let revealedAfter = revealedRanges(of: revealedBlocks, in: parsed)

        var scope = incrementalScope(
            from: previous, to: parsed, edited: editedRange, delta: delta,
            onlyOffsetsMoved: onlyOffsetsMoved)
        if scope != nil, revealedBefore != revealedAfter {
            for range in revealedBefore + revealedAfter {
                scope = scope.map { NSUnionRange($0, range) }
            }
        }

        restyle(scope: scope)
        onParse?(parsed)
    }

    /// The ranges of the blocks at `indices`, in document order.
    private func revealedRanges(of indices: Set<Int>, in document: ParsedDocument) -> [NSRange] {
        indices
            .filter { document.blocks.indices.contains($0) }
            .map { document.blocks[$0].range }
            .sorted { $0.location == $1.location ? $0.length < $1.length : $0.location < $1.location }
    }

    /// A pre-edit range in post-edit coordinates.
    ///
    /// Three cases, the same three the core's own shift uses: before the edit
    /// nothing moves, after it everything moves by `delta`, and across it only
    /// the end moves.
    private func shift(_ range: NSRange, by delta: Int, at edited: NSRange?) -> NSRange {
        guard let edited else { return range }
        let replacedEnd = edited.location + edited.length - delta
        if NSMaxRange(range) <= edited.location { return range }
        if range.location >= replacedEnd {
            return NSRange(location: max(0, range.location + delta), length: range.length)
        }
        return NSRange(location: range.location, length: max(0, range.length + delta))
    }

    /// The range worth restyling after an edit, or `nil` to restyle it all.
    ///
    /// Delegates to ``ParseDivergence``, which compares the two parses and
    /// answers where they stop agreeing. This replaces an earlier rule — *any*
    /// change in the sequence of block kinds forces a full restyle — which was
    /// correct but far too blunt. On a 10,000-line file, typing one character
    /// in front of a heading demotes it to a paragraph, and that single kind
    /// change cost a whole-document restyle of 922ms: the stall the user sees
    /// on their first keystroke.
    ///
    /// `onlyOffsetsMoved` is the core's own verdict that the edit could not
    /// have changed structure. It is a promise about spans and markers too, so
    /// comparing the blocks alone is enough — which is what keeps ordinary
    /// prose typing off the O(document) comparison entirely.
    ///
    /// Falls back to a full restyle when there is no edit to reason from, or
    /// when either parse has no blocks at all — an empty document on one side
    /// leaves nothing to line the two up by.
    private func incrementalScope(
        from previous: ParsedDocument,
        to current: ParsedDocument,
        edited: NSRange?,
        delta: Int,
        onlyOffsetsMoved: Bool
    ) -> NSRange? {
        guard let edited, !previous.blocks.isEmpty, !current.blocks.isEmpty else { return nil }
        return ParseDivergence.restyleScope(
            from: previous,
            to: current,
            edited: edited,
            delta: delta,
            documentLength: textStorage?.length ?? NSMaxRange(edited),
            depth: onlyOffsetsMoved ? .offsetsOnly : .reparsed
        )
    }

    /// Reapplies attributes for the current parse and selection.
    private func restyle(scope: NSRange? = nil) {
        guard !isStyling, let storage = textStorage else { return }
        isStyling = true
        defer { isStyling = false }

        hiddenRanges = HiddenRanges(
            document: parsed, selection: selectedRange(), mode: mode, isEditing: hasKeyboardFocus)
        MarkdownStyler.apply(
            document: parsed, hidden: hiddenRanges, to: storage, theme: theme, scope: scope)
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
        //
        // Found by binary search, not by filtering every marker in the
        // document: this runs once per code block, so a scan makes a
        // whole-document restyle quadratic — 756ms of a 922ms stall on the
        // first structural edit in a 10,000-line file.
        let fenceMarkers = parsed.markers[parsed.markerIndices(overlapping: range)]

        var start = range.location
        var end = range.location + range.length
        if let first = fenceMarkers.first?.range, first.location <= start {
            start = first.location + first.length
        }
        if let last = fenceMarkers.last?.range, last.location + last.length >= end {
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
        guard !isReplacingDocument else { return }
        let edit = announcedEdit
        announcedEdit = nil
        reparse(edit: edit)
    }

    /// Notices every character change the storage makes, and reparses the ones
    /// nothing else did.
    ///
    /// Undo and redo are why this exists. AppKit replays them straight into
    /// `NSTextStorage`: verified in a real window, with a real first responder
    /// and AppKit's own undo manager, neither `shouldChangeText` nor
    /// `didChangeText` fires. Before this, ⌘Z left the document styled for
    /// text it no longer contained — permanently, until something else
    /// happened to restyle it.
    ///
    /// The work is deferred rather than done here. This notification arrives
    /// *inside* the storage's edit cycle, where an observer may adjust
    /// attributes but must not open an editing cycle of its own — and a
    /// restyle does exactly that. One turn of the runloop later the cycle has
    /// finished and the same scoped restyle typing gets can be applied safely.
    /// An announced edit never reaches the catch-up: `didChangeText` runs
    /// first and clears the change.
    ///
    /// Attribute-only edits — every restyle this class performs — carry no
    /// `.editedCharacters`, so styling cannot feed itself back in here.
    @objc private func storageDidProcessEditing(_ note: Notification) {
        guard let storage = note.object as? NSTextStorage, storage === textStorage,
            storage.editedMask.contains(.editedCharacters),
            !isStyling, !isReplacingDocument
        else { return }

        let edited = storage.editedRange
        let delta = storage.changeInLength
        if edited.location >= 0, edited.length >= 0, NSMaxRange(edited) <= storage.length,
            edited.length - delta >= 0
        {
            unparsedChange = .scoped(
                TextEdit(
                    range: edited,
                    delta: delta,
                    replacement: (storage.string as NSString).substring(with: edited)))
        } else {
            unparsedChange = .whole
        }

        guard !isCatchUpScheduled else { return }
        isCatchUpScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isCatchUpScheduled = false
            guard let pending = self.unparsedChange else { return }
            self.unparsedChange = nil
            switch pending {
            case .scoped(let edit): self.reparse(edit: edit)
            case .whole: self.reparse()
            }
        }
    }

    /// Captures every edit the text view is about to make.
    ///
    /// Typing, pasting and deleting all pass through here, which is what lets
    /// them be reparsed synchronously — before the next frame draws. Undo does
    /// not, and is picked up by ``storageDidProcessEditing(_:)`` instead.
    public override func shouldChangeText(
        in affectedCharRange: NSRange,
        replacementString: String?
    ) -> Bool {
        if let replacementString, !isStyling {
            let inserted = (replacementString as NSString).length
            announcedEdit = TextEdit(
                range: NSRange(location: affectedCharRange.location, length: inserted),
                delta: inserted - affectedCharRange.length,
                replacement: replacementString)
        }

        let allowed = super.shouldChangeText(
            in: affectedCharRange, replacementString: replacementString)
        if !allowed {
            // A refused edit never reaches `didChangeText`, so its record would
            // sit here and be consumed by whatever edit came next — describing
            // a change to the document that never happened, at offsets that
            // mean something else now.
            announcedEdit = nil
        }
        return allowed
    }

    /// Whether every change to the text has been parsed and drawn.
    ///
    /// `false` between an unannounced edit — undo, redo, or anything written
    /// straight into the storage — and the catch-up that reparses it a runloop
    /// turn later. Tests that inspect styling need to wait for this; the app
    /// never has to, because the turn happens before the next frame.
    var hasSettledAfterTextChanges: Bool {
        unparsedChange == nil && !isCatchUpScheduled
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

        // Safe to style from `parsed` here: a text change reparses inside the
        // storage's own edit cycle, which finishes before AppKit moves the
        // caret. Styling from a parse older than the text is what wrote the
        // previous document's ranges onto the new one.
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

        fragment.decoration = BlockDecoration.decoration(
            for: NSRange(location: start, length: end - start), in: parsed)
        return fragment
    }
}
