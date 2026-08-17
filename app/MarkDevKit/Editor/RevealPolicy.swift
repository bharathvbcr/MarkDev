//
//  RevealPolicy.swift
//  MarkDevKit
//
//  Decides which syntax is visible for a given caret position.
//

import Foundation

/// How much Markdown syntax the editor shows.
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
            return revealed
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

        // Rendered blocks hide entirely, not just their delimiters.
        let replaced = rendered.collapsedRanges(revealed: revealed)

        let hideable = document.markers.lazy
            .filter { !revealed.contains($0.block) }
            .map(\.range)
            .filter { candidate in
                candidate.length > 0
                    && !protected.intersects(
                        integersIn: candidate.location..<(candidate.location + candidate.length))
            }

        self.init(merging: Array(hideable) + replaced)
    }
}
