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
            return revealingWholeTables(revealed, in: document)
        }
    }

    /// Extends the revealed set so a table reveals as one unit.
    ///
    /// Rows are separate blocks, so revealing them one at a time shows the
    /// caret's row as raw `| … |` while its neighbours stay laid out — and
    /// because the row's own pipes then take up space, it jumps sideways out
    /// of the grid the moment the caret arrives. A table is one construct and
    /// shows its syntax all at once, exactly as a code fence does.
    private static func revealingWholeTables(
        _ revealed: Set<Int>,
        in document: ParsedDocument
    ) -> Set<Int> {
        var out = revealed
        for index in revealed where document.blocks[index].kind == .table {
            let table = document.blocks[index].range
            let end = table.location + table.length
            // A table's rows and cells follow it contiguously in block order.
            var cursor = index + 1
            while cursor < document.blocks.count,
                document.blocks[cursor].range.location < end
            {
                out.insert(cursor)
                cursor += 1
            }
        }
        return out
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

    /// Ranges that must stay visible because a drawn stand-in needs the space
    /// they reserve.
    ///
    /// A `- [x]` checkbox is *entirely* syntax: unlike `**`, there is no
    /// content left behind once it is hidden. The renderer draws a checkbox
    /// over it, and that checkbox needs somewhere to sit — so the characters
    /// keep their size, on the baseline, at whatever the body font is, and the
    /// styler merely paints them clear.
    ///
    /// The marker is protected one character wider than it is. The space after
    /// `[ ]` is its own marker, and hiding it closes the gap between the
    /// checkbox and the text, rendering `- [ ] first` as `☐first`.
    ///
    /// A `---` rule is *not* in this list. Its replacement is a drawn line
    /// spanning the text container, which needs no character to sit on — and
    /// keeping the dashes visible under it shows the reader a line struck
    /// through some text rather than a section break.
    public static func markersRequiringReplacement(in document: ParsedDocument) -> [NSRange] {
        var ranges: [NSRange] = []
        ranges.reserveCapacity(8)

        for span in document.spans where span.kind == .taskMarker {
            ranges.append(
                NSRange(location: span.range.location, length: span.range.length + 1))
        }
        return ranges
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
    public init(
        document: ParsedDocument,
        selection: NSRange,
        mode: EditorMode = .livePreview,
        isEditing: Bool = true
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

        let hideable = document.markers.lazy
            .filter { !revealed.contains($0.block) }
            .map(\.range)
            .filter { candidate in
                candidate.length > 0
                    && !protected.intersects(
                        integersIn: candidate.location..<(candidate.location + candidate.length))
            }

        self.init(merging: Array(hideable))
    }
}
