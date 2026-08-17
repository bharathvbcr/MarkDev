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
        didSet {
            palette = makePalette()
            restyle()
        }
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

    /// Called with a `#tag` when one is clicked.
    public var onSelectTag: ((String) -> Void)?

    /// Called when a code or diagram block's pop-out control is clicked.
    public var onExpandBlock: ((BlockExcerpt) -> Void)?

    /// Asked for a preview of a `[[wikilink]]`'s target while the pointer
    /// rests on it. Returning `nil` shows nothing, which is the right answer
    /// for a link to a note that does not exist yet.
    public var peekProvider: ((String) -> NotePeek?)?

    /// Currently collapsed ranges.
    private var hiddenRanges: HiddenRanges = .none

    /// Decoration for the current parse, indexed once so the per-line
    /// fragment callback is a binary search rather than a scan of every block.
    private var decorations: DocumentDecorations = .empty

    /// Drawing colours captured from the theme. Held rather than rebuilt per
    /// fragment: TextKit asks for one fragment per line, and each rebuild
    /// allocates a `CTFont`.
    private var palette: BlockDecorationPalette = BlockDecorationPalette(theme: .standard)

    /// The link peek currently on screen, and what it is showing.
    private var peek: (popover: NSPopover, target: String)?
    /// Fires after the pointer has rested on a link long enough to mean it.
    private var peekTimer: Timer?
    private var hoverTracking: NSTrackingArea?

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
        decorations = DocumentDecorations(document: parsed)
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
        decorations = DocumentDecorations(document: parsed)
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
            drawsReplacements: mode != .source, contentWidth: usableContentWidth)
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
            guard let body = codeBody(of: block.range, in: text) else { continue }
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
    private func codeBody(of block: NSRange, in text: NSString) -> NSRange? {
        let range = NSIntersectionRange(block, NSRange(location: 0, length: text.length))
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

    /// Captures the theme's drawing colours against *this view's* appearance.
    ///
    /// `NSColor.cgColor` resolves a dynamic colour there and then, against
    /// `NSAppearance.current` — which outside a draw call is whatever AppKit
    /// last set, not the view's. Read carelessly, a panel meant to be 4% black
    /// in light mode is captured as 7% *white*, and paints invisibly onto a
    /// white page. Only the vivid colours survive that, which is why a callout
    /// would still show while a code panel silently would not.
    private func makePalette() -> BlockDecorationPalette {
        var palette: BlockDecorationPalette?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            palette = BlockDecorationPalette(theme: theme)
        }
        return palette ?? BlockDecorationPalette(theme: theme)
    }

    /// Recaptures the palette when the system flips between light and dark.
    ///
    /// Fragments hold the colours they were built with, so the ones already
    /// laid out have to be handed the new palette — otherwise a switch to dark
    /// mode leaves every panel painted for the light one until the text
    /// happens to change.
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        palette = makePalette()
        let captured = palette
        textLayoutManager?.enumerateTextLayoutFragments(
            from: textLayoutManager?.documentRange.location
        ) { fragment in
            (fragment as? MarkdownLayoutFragment)?.palette = captured
            return true
        }
        needsDisplay = true
    }

    /// Width a line of text may actually occupy, which is what decides
    /// whether a table's natural columns will fit.
    private var usableContentWidth: CGFloat? {
        guard let container = textContainer else { return nil }
        let width = container.size.width - container.lineFragmentPadding * 2
        guard width > 0, width < CGFloat.greatestFiniteMagnitude else { return nil }
        return width
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
        guard let url, let scheme = url.scheme,
            scheme == MarkdownStyler.wikiLinkScheme || scheme == MarkdownStyler.tagScheme
        else {
            super.clicked(onLink: link, at: charIndex)
            return
        }
        // The target rides in the host, percent-decoded back to its raw form.
        let raw = (url.host(percentEncoded: false) ?? url.absoluteString)
            .replacingOccurrences(of: "\(scheme)://", with: "")
        let target = raw.removingPercentEncoding ?? raw
        if scheme == MarkdownStyler.tagScheme {
            onSelectTag?(target)
        } else {
            onFollowWikiLink?(target)
        }
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
        fragment.palette = palette

        guard let documentStart = textLayoutManager.documentRange.location as NSTextLocation?,
            let elementRange = textElement.elementRange
        else { return fragment }

        let start = textLayoutManager.offset(from: documentStart, to: elementRange.location)
        let end = textLayoutManager.offset(from: documentStart, to: elementRange.endLocation)
        guard start >= 0, end >= start else { return fragment }

        let range = NSRange(location: start, length: end - start)
        fragment.documentRange = range
        fragment.decoration = decorations.decoration(for: range)
        // Source mode shows the characters as written, so nothing may be drawn
        // over them — a checkbox on top of a `[ ]` the reader asked to see is
        // the one thing source mode must not do.
        fragment.ornaments = mode == .source ? [] : decorations.ornaments(in: range)
        return fragment
    }
}

// MARK: - Interaction

extension MarkdownTextView {
    /// Routes a click to whatever is drawn under it before treating it as
    /// caret placement.
    ///
    /// Ornaments and controls are painted by a layout fragment, not by views,
    /// so there is nothing for AppKit to hit-test — this is where a drawn
    /// checkbox becomes a clickable one. Anything not claimed here falls
    /// through to `NSTextView`, so ordinary selection is untouched.
    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if expandBlock(at: point) { return }
        if toggleTask(at: point) { return }
        super.mouseDown(with: event)
    }

    /// Opens the code or diagram block whose pop-out control was clicked.
    private func expandBlock(at point: NSPoint) -> Bool {
        guard onExpandBlock != nil, let manager = textLayoutManager else { return false }
        let origin = textContainerOrigin
        let inContainer = NSPoint(x: point.x - origin.x, y: point.y - origin.y)

        var hit: MarkdownLayoutFragment?
        manager.enumerateTextLayoutFragments(from: manager.documentRange.location) { fragment in
            guard let fragment = fragment as? MarkdownLayoutFragment else { return true }
            let frame = fragment.layoutFragmentFrame
            // Stop once past the click: fragments are enumerated in document
            // order, so everything below it is irrelevant.
            if frame.minY > inContainer.y + frame.height { return false }
            if let control = fragment.expandControlRect {
                let rect = control.offsetBy(dx: frame.origin.x, dy: frame.origin.y)
                if rect.insetBy(dx: -3, dy: -3).contains(inContainer) {
                    hit = fragment
                    return false
                }
            }
            return true
        }

        guard let hit, let excerpt = excerpt(for: hit) else { return false }
        onExpandBlock?(excerpt)
        return true
    }

    /// The content of the block a fragment belongs to, ready to pop out.
    private func excerpt(for fragment: MarkdownLayoutFragment) -> BlockExcerpt? {
        guard case .code(_, let language, let isDiagram) = fragment.decoration,
            let blockRange = decorations.blockRange(containing: fragment.documentRange.location)
        else { return nil }

        let text = markdown as NSString
        let clamped = NSIntersectionRange(blockRange, NSRange(location: 0, length: text.length))
        guard clamped.length > 0 else { return nil }
        let body = codeBody(of: blockRange, in: text) ?? clamped
        return BlockExcerpt(
            language: language,
            isDiagram: isDiagram,
            content: text.substring(with: body))
    }

    /// Ticks or unticks the task whose checkbox was clicked.
    ///
    /// Live preview only. In source mode the literal `[ ]` is what the reader
    /// asked to see and a click belongs to the caret; in reading mode the
    /// document is not editable, and quietly making one construct writable
    /// would break the promise the mode makes.
    private func toggleTask(at point: NSPoint) -> Bool {
        guard mode == .livePreview, isEditable else { return false }
        let index = characterIndexForInsertion(at: point)
        guard let span = parsed.spans.first(where: {
            $0.kind == .taskMarker
                && index >= $0.range.location
                && index <= $0.range.location + $0.range.length
        }) else { return false }

        // `[ ]` — the state lives in the single character between brackets, so
        // toggling is a one-character edit and undo reads as one step.
        let inner = NSRange(location: span.range.location + 1, length: 1)
        guard inner.location + inner.length <= (markdown as NSString).length else { return false }
        let replacement = span.data != 0 ? " " : "x"

        guard shouldChangeText(in: inner, replacementString: replacement) else { return true }
        textStorage?.replaceCharacters(in: inner, with: replacement)
        didChangeText()
        return true
    }

    // MARK: - Link peek

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }

    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard peekProvider != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        schedulePeek(at: point)
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        dismissPeek()
    }

    /// Arms the peek, or dismisses one showing a link the pointer has left.
    ///
    /// Deliberately delayed: a preview that appears the instant the pointer
    /// crosses a link flashes open and shut while someone is only moving
    /// across the line, which is worse than not having one.
    private func schedulePeek(at point: NSPoint) {
        guard let target = wikiLinkTarget(at: point) else {
            dismissPeek()
            return
        }
        guard peek?.target != target else { return }
        peekTimer?.invalidate()
        peekTimer = Timer.scheduledTimer(withTimeInterval: Self.peekDelay, repeats: false) {
            [weak self] _ in
            Task { @MainActor in self?.showPeek(for: target, at: point) }
        }
    }

    /// The `[[wikilink]]` target under `point`, if any.
    private func wikiLinkTarget(at point: NSPoint) -> String? {
        // Outside the text entirely, `characterIndexForInsertion` still
        // returns the nearest index, so the glyph rect has to be confirmed —
        // otherwise the whole right margin of a line would peek its link.
        guard bounds.contains(point) else { return nil }
        let index = characterIndexForInsertion(at: point)
        guard let span = parsed.spans.first(where: {
            $0.kind == .wikiLink && index >= $0.range.location
                && index < $0.range.location + $0.range.length
        }) else { return nil }
        return parsed.target(for: span)
    }

    private func showPeek(for target: String, at point: NSPoint) {
        peekTimer = nil
        guard let content = peekProvider?(target) else { return }
        dismissPeek()

        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.animates = true
        popover.contentViewController = NotePeekController(
            peek: content,
            onOpen: { [weak self] in
                self?.dismissPeek()
                self?.onFollowWikiLink?(target)
            })
        let anchor = NSRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)
        popover.show(relativeTo: anchor, of: self, preferredEdge: .maxY)
        peek = (popover, target)
    }

    private func dismissPeek() {
        peekTimer?.invalidate()
        peekTimer = nil
        peek?.popover.performClose(nil)
        peek = nil
    }

    private static let peekDelay: TimeInterval = 0.45
}
