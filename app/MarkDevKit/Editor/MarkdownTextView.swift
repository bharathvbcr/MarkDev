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
public final class MarkdownTextView: ScrollingTextView {
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
        didSet {
            listItems = parsed.blocks.filter { $0.kind == .listItem }
            // Resolved here, not per fragment and not per styling pass, so the
            // collapse and the drawing are handed *the same* answer — see
            // ``RenderedBlocks``. Both assignments to `parsed` happen after the
            // storage already holds the matching text, which is what makes
            // reading it here safe.
            renderedBlocks = RenderedBlocks(
                document: parsed, text: textStorage?.string as NSString?)
        }
    }

    /// The blocks drawn as content — a formula, a diagram, an image — instead
    /// of as their own source. Rebuilt with each parse.
    private(set) var renderedBlocks: RenderedBlocks = .none

    /// The parse's list items, in document order.
    ///
    /// Kept because the layout delegate asks "does an item start on this line"
    /// once per fragment, and TextKit builds a fragment per line: scanning
    /// every block to answer it is the quadratic this codebase has already
    /// paid for three times over — see the marker and span indices in
    /// ``MarkdownStyler``. Blocks arrive in open order, so this is sorted by
    /// start offset and can be searched.
    private var listItems: [BlockDescriptor] = []

    /// Called after every reparse, for observers such as the outline view.
    public var onParse: ((ParsedDocument) -> Void)?

    /// Called with a `[[wikilink]]` target when one is clicked.
    public var onFollowWikiLink: ((String) -> Void)?

    /// Directory the document lives in, for resolving relative image paths.
    ///
    /// Setting it re-renders, since every embedded image resolves against it.
    public var documentDirectory: URL? {
        didSet {
            guard documentDirectory != oldValue else { return }
            textLayoutManager?.invalidateLayout(for: textLayoutManager!.documentRange)
        }
    }

    /// Called when this view takes the keyboard.
    ///
    /// The writing tools act on "the editor you are working in", and with
    /// split panes that is a question only the responder chain can answer.
    public var onFocus: (() -> Void)?

    /// Mistakes found by the last proofreading pass, underlined in place.
    ///
    /// Assigning a set clamps it to the current document: a set that belongs
    /// to a different document is dropped rather than drawn at whatever
    /// offsets it happens to hold.
    public var issues: ProofreadingIssues {
        get { storedIssues }
        set {
            let clamped = newValue.clamped(toLength: textStorage?.length ?? 0)
            guard clamped != storedIssues else { return }
            storedIssues = clamped
            restyle()
            // Observers are told from here as well as from `didChangeText`,
            // because a proofreading pass writes findings straight in without
            // touching the text. There is no input binding for issues, so
            // this cannot loop back on itself.
            onIssues?(clamped)
        }
    }

    /// Called when an edit moves or invalidates the proofreading issues, so
    /// the panel listing them stays in step with the underlines.
    public var onIssues: ((ProofreadingIssues) -> Void)?

    private var storedIssues: ProofreadingIssues = .none

    /// Currently collapsed ranges.
    ///
    /// Readable rather than private so tests can assert against what the view
    /// actually collapsed. Recomputing it in a test is a second implementation
    /// of the one question the editor and the renderer must agree on.
    private(set) var hiddenRanges: HiddenRanges = .none

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

        // Resizing behaviour, sizing limits, and container growth all belong
        // to ``ScrollingTextView`` — setting any of them here would put a
        // second owner on the one contract that decides whether this view can
        // scroll at all.
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
        // A wholesale replacement is a different document as far as the
        // proofreader is concerned; keeping the old offsets would underline
        // arbitrary words in the new text.
        if !storedIssues.isEmpty {
            storedIssues = .none
            onIssues?(storedIssues)
        }
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

        // Tables join the scope whole, from both parses.
        //
        // `alignTableColumns` is the one layer that writes outside the scope:
        // a cell's width can decide a column far away, so a scoped restyle
        // still re-kerns every table in the file. Nothing clears that padding
        // except a scope that reaches it, so text which *stopped* being a
        // table kept an 18pt gap — one turned up in the middle of a code
        // block, hundreds of characters from an edit. Taking the old parse's
        // tables (shifted to where their text now sits) and the new parse's
        // together means the padding is always cleared and recomputed
        // wherever a table was or is. It also makes the pass idempotent: the
        // kern rides on a cell's last character and the measurement includes
        // that character, so re-measuring a half-cleared table drifts wider
        // every time.
        //
        // Costs nothing for a document with no tables, which is most of them.
        let tablesBefore = previous.blocks
            .filter { $0.kind == .table }
            .map { shift($0.range, by: delta, at: editedRange) }
        let tablesAfter = parsed.blocks.filter { $0.kind == .table }.map(\.range)
        if scope != nil, !tablesBefore.isEmpty || !tablesAfter.isEmpty {
            for range in tablesBefore + tablesAfter {
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
            document: parsed, selection: selectedRange(), mode: mode, isEditing: hasKeyboardFocus,
            rendered: renderedBlocks)
        // The range the styler *wrote*, which is the scope grown to whole lines
        // — not the one asked for. Both layers below reapply what its opening
        // `setAttributes` cleared, so they have to cover exactly the same
        // ground. Given the ungrown scope they missed the line at each end: an
        // edit under a code fence cleared the colours of the fence's last line
        // and left them cleared, and nothing restored them until an unrelated
        // change happened to force a whole-document pass.
        let written = MarkdownStyler.apply(
            document: parsed, hidden: hiddenRanges, to: storage, theme: theme, scope: scope)
        // Semantic token colours must be the final foreground layer. The
        // base Markdown pass intentionally resets stale attributes first.
        applyCodeHighlighting(in: storage, scope: scope == nil ? nil : written)
        applyProofreadingUnderlines(in: storage, scope: scope == nil ? nil : written)
        // After every attribute layer, not between two of them: this discards
        // cached layout fragments, and a fragment rebuilt before the
        // underlines land would draw the pre-proofread text.
        invalidateFragments(scope: scope)
        repairTypingAttributes()
    }

    /// Underlines the mistakes the proofreader found.
    ///
    /// Last of the three attribute layers, for the same reason highlighting
    /// comes after the styler: `MarkdownStyler.apply` opens with
    /// `setAttributes`, which drops everything already in range. An underline
    /// applied before it simply is not there afterwards.
    private func applyProofreadingUnderlines(in storage: NSTextStorage, scope: NSRange?) {
        guard !storedIssues.isEmpty else { return }
        let full = NSRange(location: 0, length: storage.length)
        let target = scope ?? full

        for issue in storedIssues.issues {
            let range = NSIntersectionRange(issue.range, full)
            guard range.length > 0, NSIntersectionRange(range, target).length > 0 else { continue }
            storage.addAttribute(.underlineStyle, value: Self.issueUnderline, range: range)
            storage.addAttribute(.underlineColor, value: issue.kind.tint, range: range)
        }
    }

    /// The dotted rule drawn under a mistake — the same shape macOS has used
    /// for spelling since long before this editor existed, so it needs no
    /// explaining.
    private static let issueUnderline = NSUnderlineStyle([.thick, .patternDot]).rawValue

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

    /// Rebuilds layout fragments so their decoration matches the new parse.
    ///
    /// Attributes alone do not do it: block decoration lives on the fragment,
    /// which TextKit caches and happily reuses across a document change. The
    /// result is a fence still painted as prose, or a formula still showing
    /// its source, until something else forces a relayout.
    ///
    /// Scoped where possible — a structural edit passes `nil` and rebuilds
    /// everything, since that is exactly when distant blocks change meaning.
    private func invalidateFragments(scope: NSRange?) {
        guard let manager = textLayoutManager else { return }
        guard let scope, let range = textRange(for: scope) else {
            manager.invalidateLayout(for: manager.documentRange)
            return
        }
        manager.invalidateLayout(for: range)
    }

    /// Converts a character range into a `NSTextRange`.
    private func textRange(for range: NSRange) -> NSTextRange? {
        guard let manager = textLayoutManager,
            let content = manager.textContentManager,
            let start = content.location(
                manager.documentRange.location, offsetBy: range.location),
            let end = content.location(start, offsetBy: range.length)
        else { return nil }
        return NSTextRange(location: start, end: end)
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
        // Never from a parse older than the text. AppKit moves the caret in
        // the middle of an edit — the storage already holds the new
        // characters while `parsed` still describes the old ones — and a
        // restyle here would clear text this parse cannot account for and
        // then style it from the wrong blocks. Nothing is lost by waiting:
        // the reparse recomputes the reveal set itself, and folds the blocks
        // whose syntax appeared or disappeared into its own scope.
        //
        // The symptom was a code block that had just swallowed the line after
        // it: the stale pass reset that line to body text, and the scoped
        // pass that followed had no reason to visit it again.
        //
        // The test is `unparsedChange`, not `hasSettledAfterTextChanges`:
        // announced typing clears the pending change in `didChangeText` while
        // the catch-up it scheduled is still on its way, and that catch-up
        // finds nothing to do. Waiting for it as well would drop this reveal
        // change on the floor.
        guard unparsedChange == nil else { return }

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

    /// Toggles the task checkbox at a character offset, if there is one.
    ///
    /// Edits the text rather than any view state: `[ ]` and `[x]` are the
    /// document, so ticking a box is a document change that undo, save, and
    /// the vault index all see like any other edit.
    @discardableResult
    public func toggleTask(at offset: Int) -> Bool {
        guard let storage = textStorage else { return false }
        guard let marker = parsed.spans.first(where: { span in
            span.kind == .taskMarker && NSLocationInRange(offset, span.range)
        }) else { return false }

        let text = storage.string as NSString
        guard marker.range.location + marker.range.length <= text.length else { return false }

        // The state character sits between the brackets: `[ ]` / `[x]`.
        let current = text.substring(with: marker.range)
        let replacement = current.contains("x") || current.contains("X") ? "[ ]" : "[x]"
        guard current != replacement else { return false }

        // `insertText` rather than editing the storage directly: it is the
        // ordinary input path, so undo, the change notification, and the
        // document binding all behave exactly as they do for typing.
        insertText(replacement, replacementRange: marker.range)
        return true
    }


    /// The task marker whose drawn checkbox covers `point`, if any.
    private func taskMarker(atCheckbox point: CGPoint) -> StyleSpan? {
        let offset = characterIndexForInsertion(at: point)
        guard let marker = parsed.spans.first(where: { span in
            span.kind == .taskMarker
                && NSLocationInRange(min(offset, max(span.range.location, 0)), span.range)
        }) ?? parsed.spans.first(where: { span in
            // The checkbox is drawn in the gutter, left of the text, so a
            // click on it resolves to the first character of the line rather
            // than to the marker itself.
            span.kind == .taskMarker && lineRange(containing: offset).map {
                NSIntersectionRange($0, span.range).length > 0
            } ?? false
        }) else { return nil }
        return marker
    }

    /// The line containing an offset.
    private func lineRange(containing offset: Int) -> NSRange? {
        guard let storage = textStorage else { return nil }
        let text = storage.string as NSString
        guard offset >= 0, offset <= text.length else { return nil }
        return text.lineRange(for: NSRange(location: min(offset, max(text.length - 1, 0)), length: 0))
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

    /// Ticks a checkbox when one is clicked, before the caret moves.
    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // Only the gutter counts: clicking the item's text should place the
        // caret, not toggle the task.
        if isInCheckboxGutter(point), let marker = taskMarker(atCheckbox: point) {
            toggleTask(at: marker.range.location)
            return
        }
        super.mouseDown(with: event)
    }

    /// Whether `point` lands in the gutter the checkbox is drawn into.
    ///
    /// Measured from the clicked line's own indent — the same value the
    /// fragment positions the box from — rather than as a fixed band at the
    /// view's left edge. A fixed band was only ever right for a first-level
    /// item at the margin: indent a task list and the box moves with its text
    /// while the target stays behind, so clicking a checkbox does nothing.
    func isInCheckboxGutter(_ point: CGPoint) -> Bool {
        guard let storage = textStorage, storage.length > 0 else { return false }
        let offset = characterIndexForInsertion(at: point)
        let index = min(max(offset, 0), storage.length - 1)
        let indent =
            (storage.attribute(.paragraphStyle, at: index, effectiveRange: nil)
            as? NSParagraphStyle)?.firstLineHeadIndent ?? 0

        let textStart =
            textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0) + indent
        return point.x < textStart
            && point.x >= textStart - MarkdownLayoutFragment.Metrics.checkboxGutter
    }

    public override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        // Focus changes what is revealed, so the document has to restyle.
        if became {
            restyle()
            onFocus?()
        }
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
        // After the reparse, and not on the replacement path: `setMarkdown`
        // has already cleared the issues and told observers, so reporting
        // again here would announce a set nothing has moved.
        if issuesDidMove {
            issuesDidMove = false
            onIssues?(storedIssues)
        }
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

            // Carried through the edit rather than thrown away, so fixing one
            // mistake does not erase every other underline in the document.
            // This is the same hook the incremental parser uses precisely
            // because it is the one place that sees both halves of the edit.
            if !storedIssues.isEmpty {
                let moved = storedIssues.applying(
                    edit: affectedCharRange, replacementLength: inserted)
                if moved != storedIssues {
                    storedIssues = moved
                    issuesDidMove = true
                }
            }
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

    /// Whether ``storedIssues`` changed during the in-flight edit and the
    /// observers still have to be told.
    private var issuesDidMove = false

    // MARK: - Writing tools

    /// Whether an assistant edit can be applied at all.
    ///
    /// Reading mode is genuinely read-only, so a Replace button there would be
    /// a button that does nothing.
    public var acceptsAssistedEdits: Bool { isEditable }

    /// Replaces `range` with `replacement` as one undoable action.
    ///
    /// Routed through `shouldChangeText` / `didChangeText` rather than writing
    /// to the storage directly. That triad is what registers undo, and it is
    /// also what feeds this view's own override the range and the replacement
    /// the incremental parser needs — a raw `replaceCharacters` would leave
    /// both the undo stack and the parse silently out of step with the text.
    @discardableResult
    public func applyAssistedEdit(
        range: NSRange,
        replacement: String,
        actionName: String
    ) -> Bool {
        guard isEditable, let storage = textStorage else { return false }
        guard range.location >= 0, range.length >= 0,
            range.location + range.length <= storage.length
        else { return false }
        guard shouldChangeText(in: range, replacementString: replacement) else { return false }

        undoManager?.setActionName(actionName)
        storage.replaceCharacters(in: range, with: replacement)
        didChangeText()

        let inserted = NSRange(
            location: range.location, length: (replacement as NSString).length)
        setSelectedRange(inserted)
        scrollRangeToVisible(inserted)
        return true
    }

    /// Where to point a popover for `range`, in this view's coordinates.
    ///
    /// `firstRect(forCharacterRange:)` answers in *screen* coordinates — it
    /// exists for the input method's candidate window — so the result has to
    /// come back through the window to be usable as a positioning rect.
    public func anchorRect(for range: NSRange) -> NSRect {
        scrollRangeToVisible(range)
        var actual = NSRange()
        let onScreen = firstRect(forCharacterRange: range, actualRange: &actual)
        guard !onScreen.isEmpty, let window else {
            // No window yet, or a range the layout cannot place: the middle of
            // what is visible is a defensible place for a panel to appear.
            return NSRect(x: visibleRect.midX, y: visibleRect.midY, width: 1, height: 1)
        }
        return convert(window.convertFromScreen(onScreen), from: nil)
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
            let range = ranges.first?.rangeValue, range.length == 0,
            !landsInRenderedSource(range.location)
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

    /// Whether `offset` is inside the collapsed source of a block drawn as
    /// content — a diagram, a formula, a picture.
    ///
    /// Such a run is not nudged over, and that is the difference between a
    /// diagram you can edit and one you cannot. The nudge is measured against
    /// the ranges hidden for the *previous* caret, and its rule — "a collapsed
    /// marker behaves as though it were zero-width" — is right for a two-character
    /// `**`, whose block is revealed either way. A rendered block's collapsed
    /// run is its *whole source*: nudging out of it sends every click on the
    /// diagram to the character before the opening fence, so the caret never
    /// arrives inside, the block never reveals, and the first thing typed lands
    /// in front of the ```` ``` ```` instead of in the graph.
    ///
    /// Only in live preview, which is the one mode where arriving reveals
    /// anything: source mode collapses nothing to begin with, and reading mode
    /// has no caret to place.
    private func landsInRenderedSource(_ offset: Int) -> Bool {
        guard mode == .livePreview, let entry = renderedBlocks.entry(
            overlapping: NSRange(location: offset, length: 0))
        else { return false }
        return hiddenRanges.covers(entry.range)
    }
}

extension MarkdownTextView: @preconcurrency NSTextLayoutManagerDelegate {
    /// Hands back a fragment that knows how to draw its block's decoration.
    ///
    /// Called during layout for every paragraph, so the decoration lookup has
    /// to be cheap — it scans the block list, which is small and already in
    /// memory.
    /// Captures the theme's drawing colours against *this view's* appearance.
    ///
    /// `NSColor.cgColor` resolves a dynamic colour there and then, against
    /// `NSAppearance.current` — which outside a draw call is whatever AppKit
    /// last set, not the view's. Read carelessly, a panel meant to be 4% black
    /// in light mode is captured as 7% *white*, and paints invisibly onto a
    /// white page. Only the vivid colours survive that, which is why a callout
    /// would still show while a code panel silently would not.
    func makePalette() -> BlockDecorationPalette {
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
        let captured = makePalette()
        textLayoutManager?.enumerateTextLayoutFragments(
            from: textLayoutManager?.documentRange.location
        ) { fragment in
            (fragment as? MarkdownLayoutFragment)?.palette = captured
            return true
        }
        needsDisplay = true
    }

    public func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: any NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        let fragment = MarkdownLayoutFragment(
            textElement: textElement, range: textElement.elementRange)
        fragment.palette = makePalette()

        guard let documentStart = textLayoutManager.documentRange.location as NSTextLocation?,
            let elementRange = textElement.elementRange
        else { return fragment }

        let start = textLayoutManager.offset(from: documentStart, to: elementRange.location)
        let end = textLayoutManager.offset(from: documentStart, to: elementRange.endLocation)
        guard start >= 0, end >= start else { return fragment }

        let range = NSRange(location: start, length: end - start)
        fragment.decoration = BlockDecoration.decoration(
            for: range, in: parsed, rendered: renderedBlocks, hidden: hiddenRanges)
        resolveRenderedContent(for: fragment)
        resolveCollapsedSyntax(for: fragment, at: range)
        return fragment
    }
}

extension MarkdownTextView {
    /// Works out what has to be drawn in place of the syntax this fragment
    /// hides — a fence's language, an alert's flavour, a list item's bullet.
    ///
    /// Resolved here rather than in ``BlockDecoration``, because it is not a
    /// question about the parse: it asks what is *collapsed right now*, which
    /// changes with the caret. While the caret is in the block its ```` ``` ````
    /// and its `- ` are on screen already, and drawing a stand-in beside them
    /// would state the same thing twice.
    func resolveCollapsedSyntax(for fragment: MarkdownLayoutFragment, at range: NSRange) {
        guard let text = textStorage?.string as NSString? else { return }
        let opensWithHiddenLine = hiddenRanges.hidesWholeLine(at: range.location, in: text)

        switch fragment.decoration {
        case .code(let edge, let language):
            if edge.roundsTop, opensWithHiddenLine, let language, !language.isEmpty {
                fragment.blockLabel = language.uppercased()
            }
        case .callout(let kind, let edge):
            if edge.roundsTop, opensWithHiddenLine {
                fragment.blockLabel = kind.title
            }
        case .task:
            // The checkbox is the stand-in; a bullet beside it would be a
            // second marker for one item.
            break
        default:
            fragment.listMarker = listMarker(forFragmentAt: range, in: text)
        }
    }

    /// The bullet or number for a list item opening at this fragment.
    ///
    /// `nil` unless the fragment holds the item's *first* line and that line's
    /// marker is collapsed: a wrapped item's later lines carry no marker, and
    /// a revealed item is showing its own `- ` already.
    private func listMarker(forFragmentAt range: NSRange, in text: NSString) -> String? {
        guard let item = listItem(startingIn: range) else { return nil }

        // The marker as written, so `7.` stays 7 and `*` still nests like `-`.
        let line = text.lineRange(for: NSRange(location: item.range.location, length: 0))
        let content = HiddenRanges.contentRange(of: line, in: text)
        let source = text.substring(with: content)
        guard let written = Self.writtenListMarker(in: source) else { return nil }

        // Leading indentation is spaces and tabs, so its character count is
        // also its length in the UTF-16 units storage is indexed by.
        let indent = source.prefix { $0 == " " || $0 == "\t" }.count
        let marker = NSRange(
            location: content.location + indent, length: (written as NSString).length)
        guard hiddenRanges.covers(marker) else { return nil }

        if written.first?.isNumber == true { return written }
        // Nesting alternates list, item, so each level of indentation is two
        // blocks deep. The glyph changes with it, the way a printed list does.
        return Self.bullets[Int(item.depth) / 2 % Self.bullets.count]
    }

    /// The first list item beginning inside `range`, found by binary search.
    ///
    /// Items nest, so two can begin at the same offset — `- - a` opens an
    /// outer item and an inner one on one line. The outer one is taken,
    /// because the marker read off that line is the outer one's.
    private func listItem(startingIn range: NSRange) -> BlockDescriptor? {
        var low = 0
        var high = listItems.count
        while low < high {
            let mid = low + (high - low) / 2
            if listItems[mid].range.location < range.location {
                low = mid + 1
            } else {
                high = mid
            }
        }
        guard low < listItems.count,
            listItems[low].range.location < NSMaxRange(range)
        else { return nil }
        return listItems[low]
    }

    /// Bullets by nesting level, filled then hollow then square — the
    /// convention a reader already knows from print and from HTML.
    private static let bullets = ["•", "◦", "▪"]

    /// The literal marker at the head of a list item's line, if there is one.
    private static func writtenListMarker(in line: String) -> String? {
        let body = line.drop { $0 == " " || $0 == "\t" }
        guard let first = body.first else { return nil }
        if first == "-" || first == "*" || first == "+" { return String(first) }
        guard first.isNumber else { return nil }
        let digits = body.prefix { $0.isNumber }
        let rest = body.dropFirst(digits.count)
        guard let delimiter = rest.first, delimiter == "." || delimiter == ")" else { return nil }
        return String(digits) + String(delimiter)
    }

    /// Renders a fragment's replacement content, if it has any.
    ///
    /// Done here, on the main actor, rather than inside the fragment:
    /// typesetting a formula, laying out a graph, and reading an image file
    /// all need main-actor state, while TextKit may ask a fragment for its
    /// metrics from anywhere.
    func resolveRenderedContent(for fragment: MarkdownLayoutFragment) {
        guard let block = fragment.decoration.rendered else { return }
        // The column the content has to fit, minus the panel's own padding.
        let width = max(bounds.width - theme.insets.width * 2 - 32, 120)

        let result: Result<RenderedContent, RenderFailure>
        switch block.kind {
        case .math:
            result = RichContentRenderer.shared.math(
                block.source,
                fontSize: theme.bodyFont.pointSize * 1.25,
                color: theme.textColor,
                display: true)
        case .diagram:
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            result = RichContentRenderer.shared.diagram(
                block.source, maxWidth: width, dark: dark)
        case .image(let alt):
            result = RichContentRenderer.shared.image(
                at: block.source, relativeTo: documentDirectory, maxWidth: width
            )
            .mapError { failure in
                // Alt text is the author's own description; showing it beats
                // a bare file name the reader cannot place.
                alt.isEmpty ? failure : RenderFailure(reason: "\(alt) — \(failure.reason)")
            }
        }

        switch result {
        case .success(let content): fragment.renderedContent = content
        case .failure(let failure): fragment.renderFailure = failure
        }
    }
}
