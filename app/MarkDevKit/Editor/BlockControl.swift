//
//  BlockControl.swift
//  MarkDevKit
//
//  The small chips a block draws in its own corner, and where they land.
//

import CoreGraphics

/// A control drawn in the corner of a decorated block.
///
/// Both of these are the same shape of thing — a chip the reader can click that
/// is *not* text, drawn by the layout fragment and hit-tested by the text view —
/// so they share one geometry, one drawing pass, and one hit test. A second
/// mechanism beside this one is how the two would come to disagree about where
/// a chip is: drawn in one place and clickable in another is a control that
/// simply does not work, and it looks like nothing at all.
public enum BlockControl: Sendable, Equatable, CaseIterable {
    /// Puts a code block's code on the pasteboard.
    case copy
    /// Opens rendered content — a diagram, a picture, a formula — in the
    /// zoom viewer.
    case zoom
}

/// Where a block's controls sit, as pure functions of the block's geometry.
///
/// Kept apart from the fragment for the reason ``MarkdownLayoutFragment/checkboxX(textIndent:indentCarriedByFragment:gutter:inset:)``
/// is: placement is arithmetic, and arithmetic can be asserted without a
/// window. Everything here is in the space `draw(at:in:)` works in — the
/// fragment's own frame, origin at its top left.
public enum BlockControlLayout {
    public static let width: CGFloat = 20
    public static let height: CGFloat = 14
    public static let radius: CGFloat = 4
    /// Gap between a chip and the edge it is tucked against.
    public static let inset: CGFloat = 6
    /// Grown around the drawn chip for hit-testing. A 20×14 target is small
    /// for a pointer; the padding costs nothing, because the space around a
    /// chip is a panel's own margin rather than anything else's target.
    public static let hitPadding: CGFloat = 4

    /// The copy chip, in the strip a code panel reserves above its first line.
    ///
    /// Trailing, which is why the fence's language label moved to the leading
    /// end: two things tucked against one edge is an offset calculation whose
    /// answer depends on how long the language happens to be, and `javascript`
    /// would have run into the chip.
    public static func copyRect(inPanel panel: CGRect, stripHeight: CGFloat) -> CGRect {
        CGRect(
            x: panel.maxX - inset - width,
            y: panel.minY + max(0, (stripHeight - height) / 2),
            width: width,
            height: height)
    }

    /// The zoom chip for content drawn in `content`, within the block's
    /// `panel` — the full column, as ``MarkdownLayoutFragment/decorationRect``
    /// reports it.
    ///
    /// At the block's trailing edge, level with the top of the picture. The
    /// obvious alternative — tucked inside the picture's own top-right corner —
    /// was written first and looks wrong for the case it was meant to serve: a
    /// rendered diagram's bitmap carries the graph's own margins, so the chip
    /// lands in forty points of transparent padding and reads as belonging to
    /// nothing. Worse, where it landed then depended on how much whitespace a
    /// library chose to leave, and a small picture needed a second rule to
    /// avoid being covered entirely.
    ///
    /// One rule for both chips instead: a block's controls live at its trailing
    /// edge, which is where the reader has already learnt to look for the copy
    /// chip on every code panel above it.
    public static func zoomRect(forContent content: CGRect, inPanel panel: CGRect) -> CGRect {
        CGRect(
            x: max(panel.minX, panel.maxX - inset - width),
            y: content.minY + inset,
            width: width,
            height: height)
    }

    /// The area a click on `rect` counts as landing in.
    public static func hitArea(of rect: CGRect) -> CGRect {
        rect.insetBy(dx: -hitPadding, dy: -hitPadding)
    }
}
