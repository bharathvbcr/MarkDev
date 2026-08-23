//
//  RevealPolicy.swift
//  MarkDevKit
//
//  Decides which syntax is visible for a given caret position.
//

import Foundation

/// How much Markdown syntax the editor shows.
///
/// Backed by stable string names rather than ordinals because the chosen mode
/// is written to user defaults: an integer raw value would silently change
/// meaning if a case were ever inserted, quietly switching someone into a
/// different mode after an update.
public enum EditorMode: String, Sendable, CaseIterable {
    /// Syntax is hidden except in the block holding the caret. The default.
    case livePreview
    /// All syntax visible — plain Markdown editing.
    case source
    /// All syntax hidden, nothing editable.
    case reading
}

/// Works out which blocks reveal their syntax, and which markers may be
/// hidden at all.
///
/// Revealing is per *block*, not per marker. If markers uncovered themselves
/// one at a time as the caret crossed them, text would shift under the cursor
/// mid-keystroke; revealing the whole construct at once keeps the line stable
/// while it is being edited.
public enum RevealPolicy {
    /// Indices into `document.blocks` whose syntax should be visible.
    public static func revealedBlocks(
        in document: ParsedDocument,
        selection: NSRange,
        mode: EditorMode = .livePreview
    ) -> Set<Int> {
        switch mode {
        case .source:
            return Set(document.blocks.indices)
        case .reading:
            return []
        case .livePreview:
            var revealed: Set<Int> = []
            for (index, block) in document.blocks.enumerated()
            where intersects(block: block.range, selection: selection) {
                revealed.insert(index)
            }
            return expandingTables(revealed, in: document)
        }
    }

    /// Whether what is revealed depends on where the caret is.
    ///
    /// Only live preview answers per position. Source reveals every block and
    /// reading reveals none, so in both the set is decided by the mode alone:
    /// no caret movement and no edit can change it, and the difference between
    /// two of them is always empty.
    ///
    /// The editor caches the reveal set to work out which blocks have to be
    /// restyled when it changes. Asking a mode that cannot change it is not
    /// merely wasted work — see ``MarkdownTextView/reparse(edit:)``, where the
    /// two answers are compared as *ranges*, and a set covering every block
    /// produces two arrays that disagree wherever an edit lands on a block
    /// boundary. The union of both then reaches the whole document.
    public static func revealFollowsCaret(_ mode: EditorMode) -> Bool {
        mode == .livePreview
    }

    /// Reveals every block of a table any part of which is revealed.
    ///
    /// A table is one construct, not a stack of independent rows. Its rows are
    /// drawn against columns solved across all of them, so revealing a single
    /// row leaves the reader with one line of raw pipes — laid out to a width
    /// nothing else shares — between rows that still agree with each other,
    /// while the rows around it show their cell text with the pipes hidden and
    /// no alignment at all. Caret in the table means the whole table is
    /// Markdown; caret out of it means the whole table is a grid.
    ///
    /// Costs nothing for a document whose caret is not in a table, which is
    /// almost every keystroke.
    private static func expandingTables(
        _ revealed: Set<Int>, in document: ParsedDocument
    ) -> Set<Int> {
        let tables = document.blocks.enumerated()
            .filter { $0.element.kind == .table && revealed.contains($0.offset) }
            .map(\.element.range)
        guard !tables.isEmpty else { return revealed }

        var expanded = revealed
        for (index, block) in document.blocks.enumerated() where !expanded.contains(index) {
            if tables.contains(where: { NSIntersectionRange($0, block.range).length > 0 }) {
                expanded.insert(index)
            }
        }
        return expanded
    }

    /// A caret sitting exactly on a block boundary counts as inside it, so
    /// typing at the end of a heading keeps its `# ` visible instead of
    /// having the prefix vanish on the last character.
    private static func intersects(block: NSRange, selection: NSRange) -> Bool {
        let blockEnd = block.location + block.length
        if selection.length == 0 {
            return selection.location >= block.location && selection.location <= blockEnd
        }
        let selectionEnd = selection.location + selection.length
        return selection.location < blockEnd && selectionEnd > block.location
    }

    /// Ranges whose *entire* text is replaced by rendered content.
    ///
    /// Unlike a marker, the whole block goes: a formula's source is replaced
    /// by the typeset formula, not merely stripped of its `$$`. These hide
    /// only while the caret is elsewhere — the source has to come back to be
    /// edited, which is the same bargain live preview makes everywhere else.
    public static func blocksRenderedAsContent(
        in document: ParsedDocument,
        revealed: Set<Int>
    ) -> [NSRange] {
        // Table rows included: a row's cells are drawn in place of its
        // source, exactly as a formula's are. `revealed` already carries the
        // rule that a table reveals whole — see `expandingTables`.
        var ranges: [NSRange] = []
        for (index, block) in document.blocks.enumerated() {
            switch block.kind {
            case .mathBlock, .mermaidBlock, .tableRow, .tableHead:
                guard !revealed.contains(index) else { continue }
            default:
                continue
            }
            ranges.append(block.range)
        }
        return ranges
    }

    /// Ranges that must stay visible because hiding them would destroy
    /// information no drawn stand-in replaces yet.
    ///
    /// Both `- [x]` and `---` are *entirely* syntax: unlike `**`, nothing is
    /// left behind once they are hidden. They may only be hidden because the
    /// layout fragment now draws a checkbox and a horizontal line in their
    /// place — hiding them with nothing drawn would read as data loss.
    ///
    /// Kept as a hook rather than deleted: any future construct that is all
    /// syntax has to earn its drawn replacement the same way.
    public static func markersRequiringReplacement(in document: ParsedDocument) -> [NSRange] {
        []
    }
}

extension HiddenRanges {
    /// The markers to collapse, given a selection and mode.
    ///
    /// Combines the two independent reasons a marker stays visible: its block
    /// holds the caret, or it has no drawn replacement yet.
    /// - Parameter isEditing: whether the editor has keyboard focus. An
    ///   unfocused editor reveals nothing: syntax appears because the caret is
    ///   somewhere, and with no caret in play showing it makes a note look
    ///   like raw source the moment it opens.
    /// - Parameter rendered: the blocks drawn as content rather than as their
    ///   own source, which collapse *whole* rather than marker by marker. The
    ///   default of ``RenderedBlocks/none`` means nothing is drawn in any
    ///   block's place, so nothing collapses on that account — a caller who
    ///   omits it gets every source shown, never a block hidden with nothing
    ///   standing in for it.
    public init(
        document: ParsedDocument,
        selection: NSRange,
        mode: EditorMode = .livePreview,
        isEditing: Bool = true,
        rendered: RenderedBlocks = .none
    ) {
        guard mode != .source else {
            self.init(merging: [])
            return
        }

        let effectiveMode: EditorMode = isEditing ? mode : .reading
        let revealed = RevealPolicy.revealedBlocks(
            in: document, selection: selection, mode: effectiveMode)

        // An IndexSet, not an array scan: checking each marker against every
        // protected range is quadratic, and a long task list has thousands of
        // both.
        var protected = IndexSet()
        for range in RevealPolicy.markersRequiringReplacement(in: document)
        where range.length > 0 {
            protected.insert(integersIn: range.location..<(range.location + range.length))
        }

        // Rendered blocks and table rows hide entirely, not just their delimiters.
        let tableRows: [NSRange] = document.blocks.enumerated().compactMap { index, block in
            guard (block.kind == .tableRow || block.kind == .tableHead) && !revealed.contains(index) else {
                return nil
            }
            return block.range
        }
        let replaced = rendered.collapsedRanges(revealed: revealed) + tableRows

        let hideable = document.markers.lazy
            .filter { !revealed.contains($0.block) }
            .map(\.range)
            .filter { candidate in
                candidate.length > 0
                    && !protected.intersects(
                        integersIn: candidate.location..<(candidate.location + candidate.length))
            }

        self.init(
            merging: Array(hideable) + replaced,
            // Only the explicit read-only surface may make an authored blank
            // separator non-clickable. An unfocused live editor borrows
            // reading reveal policy, but it must restore an ordinary line as
            // soon as the writer clicks back into it.
            compactsReplacedBlockSeparators: mode == .reading)
    }
}
