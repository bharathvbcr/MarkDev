//
//  MarkdownLayoutFragment.swift
//  MarkDevKit
//
//  Custom drawing behind code blocks, callouts, quotes, and rules.
//

@preconcurrency import AppKit
@preconcurrency import CoreText

/// Immutable, concurrency-safe drawing values captured from `EditorTheme` on
/// the main actor. TextKit's fragment callbacks predate actor annotations and
/// may be nonisolated, so the renderer must not retain NSColor or NSFont.
struct BlockDecorationPalette: Sendable {
    let codeBackground: CGColor
    /// Hairline around a code panel, so it reads as a card.
    let codeBorder: CGColor
    let tableHeader: CGColor
    let tableBorder: CGColor
    let quoteColor: CGColor
    let secondaryColor: CGColor
    let labelFont: CTFont
    /// Font for a drawn list bullet or number. Sized from the body font, so a
    /// bullet keeps its place beside the text at any type size.
    let listMarkerFont: CTFont
    let accent: CGColor
    /// Contrasts with `accent`, for the tick inside a filled checkbox.
    let checkmark: CGColor
    let note: CGColor
    let tip: CGColor
    let important: CGColor
    let warning: CGColor
    let caution: CGColor

    @MainActor
    init(theme: EditorTheme) {
        codeBackground = theme.codeBackground.cgColor
        codeBorder = theme.codeBorder.cgColor
        tableHeader = theme.tableHeaderBackground.cgColor
        tableBorder = theme.tableBorder.cgColor
        quoteColor = theme.quoteColor.cgColor
        secondaryColor = theme.secondaryColor.cgColor
        labelFont = CTFontCreateUIFontForLanguage(.smallSystem, 9, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, 9, nil)
        listMarkerFont = CTFontCreateUIFontForLanguage(
            .system, theme.bodyFont.pointSize * 0.85, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, theme.bodyFont.pointSize * 0.85, nil)
        accent = theme.accentColor.cgColor
        checkmark = NSColor.white.cgColor
        note = theme.calloutAccent(.note).cgColor
        tip = theme.calloutAccent(.tip).cgColor
        important = theme.calloutAccent(.important).cgColor
        warning = theme.calloutAccent(.warning).cgColor
        caution = theme.calloutAccent(.caution).cgColor
    }

    func calloutAccent(_ kind: CalloutKind) -> CGColor {
        switch kind {
        case .note: note
        case .tip: tip
        case .important: important
        case .warning: warning
        case .caution: caution
        }
    }
}

/// A layout fragment that paints block decoration behind its text.
///
/// This is the Apple-sanctioned extension point for custom block rendering in
/// TextKit 2: the layout manager's delegate returns a fragment subclass, and
/// the subclass overrides `draw(at:in:)`. TextKit 2 exposes no glyph layer, so
/// there is no other place to intervene.
///
/// Note the fragment draws decoration and then calls `super` for the text
/// itself. Painting the text here as well would mean reimplementing line
/// layout, which is precisely what TextKit already does correctly.
final class MarkdownLayoutFragment: NSTextLayoutFragment {
    var decoration: BlockDecoration = .none
    var palette: BlockDecorationPalette?

    /// Content standing in for the block's text, resolved by the delegate.
    ///
    /// Rendering runs on the main actor — it typesets, lays out graphs, and
    /// reads files — while TextKit may call a fragment's metrics and drawing
    /// from anywhere. Resolving up front, like the palette does, keeps the
    /// fragment itself free of isolation concerns.
    var renderedContent: RenderedContent?
    /// Why rendering failed, when it did.
    var renderFailure: RenderFailure?

    /// A word drawn in the block's top strip in place of the line of syntax
    /// that named it — a fence's language, an alert's flavour.
    ///
    /// Resolved by the delegate, like ``renderedContent``, because it depends
    /// on what is *collapsed* as well as on what was parsed: while the caret
    /// is inside the block its ```` ```bash ```` is on screen already, and a
    /// label beside it would be the same fact twice.
    var blockLabel: String?

    /// The glyph standing in for a collapsed list marker — a bullet, or the
    /// item's own number.
    ///
    /// A `- ` is *entirely* syntax: hiding it with nothing in its place turns
    /// a list into a stack of indented sentences, which is the failure
    /// ``RevealPolicy/markersRequiringReplacement`` exists to prevent.
    var listMarker: String?

    /// Height the rendered content needs, including its own padding.
    private var contentHeight: CGFloat {
        if let renderedContent {
            return renderedContent.size.height + Metrics.blockPadding * 2
        }
        return renderFailure == nil ? 0 : Metrics.failureHeight
    }

    // MARK: - Metrics

    /// Extra space above the block, so a code background does not butt
    /// against the paragraph above it.
    override var topMargin: CGFloat {
        // A label sits in the top strip, so the strip has to be tall enough to
        // hold it — otherwise it prints over the block's first line of text.
        let label = blockLabel == nil ? 0 : Metrics.labelHeight
        switch decoration {
        case .code(let edge, _) where edge.roundsTop: return Metrics.blockPadding + label
        case .callout(_, let edge) where edge.roundsTop: return Metrics.blockPadding + label
        case .rule: return Metrics.rulePadding
        default: return super.topMargin
        }
    }

    override var bottomMargin: CGFloat {
        switch decoration {
        case .code(let edge, _) where edge.roundsBottom: Metrics.blockPadding
        case .callout(_, let edge) where edge.roundsBottom: Metrics.blockPadding
        case .rule: Metrics.rulePadding
        default: super.bottomMargin
        }
    }

    /// Grown to fit rendered content.
    ///
    /// A formula or diagram is far taller than the collapsed source it stands
    /// in for, and without extending the frame the following paragraph would
    /// be laid out straight over it.
    override var layoutFragmentFrame: CGRect {
        var frame = super.layoutFragmentFrame
        let extra = contentHeight
        if extra > 0 { frame.size.height += extra }
        return frame
    }

    /// The area the fragment actually paints — its text, and whatever it draws
    /// outside it.
    ///
    /// Without widening this, the background is clipped to the text's own
    /// bounds and the padding drawn around it is simply not shown.
    ///
    /// A list marker is drawn in the gutter *left* of the text, so a fragment
    /// that draws one has to claim that space even when it carries no
    /// decoration at all — otherwise the bullet is clipped away at the
    /// fragment's leading edge, which is exactly how it looked.
    override var renderingSurfaceBounds: CGRect {
        var bounds = super.renderingSurfaceBounds
        if decoration != .none { bounds = bounds.union(decorationRect) }
        // Claimed explicitly rather than left to the panel: an item whose text
        // is *only* its marker reports no indent for the panel to be measured
        // from, and the bullet then lands outside a surface that stops at the
        // fragment's own leading edge — drawn, clipped, and invisible.
        if let gutter = gutterRect { bounds = bounds.union(gutter) }
        return bounds
    }

    /// The gutter a drawn stand-in for a collapsed marker occupies.
    ///
    /// One rule for both stand-ins — the checkbox and the list marker — so
    /// neither can be clipped by a surface that forgot about it.
    var gutterRect: CGRect? {
        let gutter: CGFloat
        let inset: CGFloat
        switch (decoration.taskChecked, listMarker) {
        case (.some, _):
            gutter = Metrics.checkboxGutter
            inset = Metrics.checkboxInset
        case (nil, .some):
            gutter = Metrics.listMarkerGutter
            inset = 0
        default:
            return nil
        }

        let x = Self.checkboxX(
            textIndent: textIndent, indentCarriedByFragment: indentCarriedByFragment,
            gutter: gutter, inset: inset)
        guard x.isFinite else { return nil }
        return CGRect(x: x, y: 0, width: gutter, height: max(layoutFragmentFrame.height, 1))
    }

    /// The rect the decoration covers.
    ///
    /// Spans the text container, not the fragment's own width. A layout
    /// fragment is only as wide as the line it holds, so sizing the panel from
    /// it draws a ragged stack of boxes — one per line, each stopping where its
    /// text happens to end — instead of one block.
    ///
    /// It starts at `-indentCarriedByFragment` for the same reason the
    /// checkbox does: `draw(at:in:)` works in a space translated to the
    /// fragment's origin, and TextKit puts an indented paragraph's fragments
    /// *sometimes* at the indent and sometimes at the container's edge. Taking
    /// the indent back out is what makes a callout's accent bar land in one
    /// column instead of stepping right on the lines that carry it — and what
    /// keeps ``renderingSurfaceBounds`` wide enough to include a checkbox
    /// drawn in the gutter to the left of the text.
    /// It covers the fragment's *whole* frame, margins included: TextKit lays
    /// fragments out back to back and counts `topMargin` and `bottomMargin`
    /// inside the frame it hands over, so a panel drawn from `-topMargin`
    /// reaches up into the line above and paints over it — which is what put
    /// the head of a code panel through the last line of the list before it.
    // Internal rather than private so the geometry can be asserted directly:
    // where a panel starts is the whole of the bug this replaced.
    var decorationRect: CGRect {
        let frame = layoutFragmentFrame
        return CGRect(
            x: -indentCarriedByFragment,
            y: 0,
            width: max(containerWidth, frame.width, 1),
            height: frame.height)
    }

    /// Where this fragment's text begins, in fragment-local coordinates.
    ///
    /// Read from the paragraph style the styler applied, not recomputed from
    /// the block's nesting depth: the indent is the styler's decision, and a
    /// second calculation of it here would be a copy that drifts.
    ///
    /// The style rather than the line's own `typographicBounds`, because a
    /// fragment can end with an empty trailing line whose bounds begin at
    /// zero — reading geometry lands on that one and reports no indent at all.
    var textIndent: CGFloat {
        // The paragraph's own text first. A line fragment can be empty, or can
        // hold nothing but collapsed syntax — a list item written `- ` with no
        // text is exactly that — and reading the indent from it then reports
        // none, which puts the bullet in the margin instead of the gutter.
        if let paragraph = (textElement as? NSTextParagraph)?.attributedString,
            paragraph.length > 0,
            let style = paragraph.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
                as? NSParagraphStyle
        {
            return style.firstLineHeadIndent
        }
        for line in textLineFragments where line.attributedString.length > 0 {
            guard let style = line.attributedString.attribute(
                .paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            else { continue }
            return style.firstLineHeadIndent
        }
        return textLineFragments.first?.typographicBounds.origin.x ?? 0
    }

    /// How much of the paragraph's indent is already baked into where this
    /// fragment is drawn.
    ///
    /// `draw(at:in:)` receives a `point` of `(0, 0)` with the context already
    /// translated to the fragment's origin, so anything measured from `point`
    /// is measured from wherever TextKit decided to put the fragment — and for
    /// an indented paragraph that is *sometimes* the indent and sometimes the
    /// container's edge. Subtracting this makes the arithmetic independent of
    /// which, since whatever the frame already contributes is taken back out.
    var indentCarriedByFragment: CGFloat {
        let padding = textLayoutManager?.textContainer?.lineFragmentPadding ?? 0
        return max(layoutFragmentFrame.origin.x - padding, 0)
    }

    /// Leading edge of a task item's checkbox, in the drawing space `point`
    /// establishes.
    ///
    /// Kept as a pure function of four measurements so the invariant that
    /// matters — the box lands immediately left of the item's own text, at the
    /// same place on screen however TextKit expresses the fragment's origin —
    /// can be tested without a window. See ``MarkdownLayoutFragment/checkboxX``.
    static func checkboxX(
        textIndent: CGFloat,
        indentCarriedByFragment: CGFloat,
        gutter: CGFloat,
        inset: CGFloat
    ) -> CGFloat {
        textIndent - indentCarriedByFragment - gutter + inset
    }

    /// Usable width of the text container, or the fragment's own as a
    /// fallback before layout has settled.
    private var containerWidth: CGFloat {
        guard let container = textLayoutManager?.textContainer else {
            return layoutFragmentFrame.width
        }
        let width = container.size.width - container.lineFragmentPadding * 2
        guard width > 0, width < CGFloat.greatestFiniteMagnitude else {
            return layoutFragmentFrame.width
        }
        return width
    }

    // MARK: - Drawing

    override func draw(at point: CGPoint, in context: CGContext) {
        switch decoration {
        case .none:
            break
        case .code(let edge, _):
            drawPanel(
                in: context, at: point, edge: edge,
                fill: palette?.codeBackground, border: palette?.codeBorder, bar: nil)
            drawBlockLabel(
                in: context, at: point, colour: palette?.secondaryColor.copy(alpha: 0.75),
                alignment: .trailing)
        case .callout(let kind, let edge):
            let accent = palette?.calloutAccent(kind)
            drawPanel(
                in: context, at: point, edge: edge,
                fill: accent?.copy(alpha: 0.12), border: nil, bar: accent)
            drawBlockLabel(in: context, at: point, colour: accent, alignment: .leading)
        case .quote(let edge):
            drawPanel(
                in: context, at: point, edge: edge, fill: nil, border: nil,
                bar: palette?.quoteColor)
        case .rule:
            drawRule(in: context, at: point)
        case .rendered:
            drawRenderedContent(in: context, at: point)
        case .task(let checked):
            drawCheckbox(checked: checked, in: context, at: point)
        case .tableRow(let isHeader, let isLast):
            drawTableRow(isHeader: isHeader, isLast: isLast, in: context, at: point)
        }

        if listMarker != nil { drawListMarker(in: context, at: point) }
        drawInlineCodePills(in: context, at: point)

        super.draw(at: point, in: context)
    }

    /// Draws the rounded background, joined across the block's lines.
    ///
    /// Only the first and last lines round their corners; the middle draws
    /// square so consecutive fragments meet without a seam. The border follows
    /// the same rule and additionally *omits* the horizontal edges a middle
    /// piece would draw — a line across the panel at every line break.
    private func drawPanel(
        in context: CGContext,
        at point: CGPoint,
        edge: BlockEdge,
        fill: CGColor?,
        border: CGColor?,
        bar: CGColor?
    ) {
        let rect = decorationRect.offsetBy(dx: point.x, dy: point.y)
        context.saveGState()
        defer { context.restoreGState() }

        if let fill {
            context.addPath(Self.panelPath(in: rect, edge: edge))
            context.setFillColor(fill)
            context.fillPath()
        }

        if let border {
            // Half a point in, so a one-point stroke lands on the pixel grid
            // rather than straddling it and drawing two grey rows.
            let inset = rect.insetBy(dx: 0.5, dy: 0)
            context.addPath(Self.panelBorderPath(in: inset, edge: edge))
            context.setStrokeColor(border)
            context.setLineWidth(1)
            context.strokePath()
        }

        if let bar {
            let barRect = CGRect(
                x: rect.minX, y: rect.minY,
                width: Metrics.barWidth, height: rect.height)
            context.setFillColor(bar)
            context.fill(barRect)
        }
    }

    /// The panel's outline, rounded only on the edges this piece owns.
    private static func panelPath(in rect: CGRect, edge: BlockEdge) -> CGPath {
        let radius = Metrics.cornerRadius
        let top = edge.roundsTop ? radius : 0
        let bottom = edge.roundsBottom ? radius : 0
        let path = CGMutablePath()

        path.move(to: CGPoint(x: rect.minX + top, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY))
        if top > 0 {
            path.addArc(
                tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                tangent2End: CGPoint(x: rect.maxX, y: rect.minY + top),
                radius: top)
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottom))
        if bottom > 0 {
            path.addArc(
                tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                tangent2End: CGPoint(x: rect.maxX - bottom, y: rect.maxY),
                radius: bottom)
        }
        path.addLine(to: CGPoint(x: rect.minX + bottom, y: rect.maxY))
        if bottom > 0 {
            path.addArc(
                tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                tangent2End: CGPoint(x: rect.minX, y: rect.maxY - bottom),
                radius: bottom)
        }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + top))
        if top > 0 {
            path.addArc(
                tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                tangent2End: CGPoint(x: rect.minX + top, y: rect.minY),
                radius: top)
        }
        path.closeSubpath()
        return path
    }

    /// The strokable part of the outline: the sides always, and a horizontal
    /// edge only where the block actually ends.
    private static func panelBorderPath(in rect: CGRect, edge: BlockEdge) -> CGPath {
        let radius = Metrics.cornerRadius
        let top = edge.roundsTop ? radius : 0
        let bottom = edge.roundsBottom ? radius : 0
        let path = CGMutablePath()

        // Left side, top to bottom, taking in whichever corners are ours.
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + top))
        if top > 0 {
            path.addArc(
                tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                tangent2End: CGPoint(x: rect.minX + top, y: rect.minY),
                radius: top)
            path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY))
            path.addArc(
                tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                tangent2End: CGPoint(x: rect.maxX, y: rect.minY + top),
                radius: top)
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottom))
        } else {
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - bottom))
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottom))
        }

        if bottom > 0 {
            // Continue from the right side around the foot and back up.
            path.addArc(
                tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                tangent2End: CGPoint(x: rect.maxX - bottom, y: rect.maxY),
                radius: bottom)
            path.addLine(to: CGPoint(x: rect.minX + bottom, y: rect.maxY))
            path.addArc(
                tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                tangent2End: CGPoint(x: rect.minX, y: rect.maxY - bottom),
                radius: bottom)
            if top > 0 { path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + top)) }
        }
        return path
    }

    /// Which end of the top strip a label sits at.
    private enum LabelAlignment {
        case leading
        case trailing
    }

    /// Draws the label standing in for the block's collapsed opening line.
    private func drawBlockLabel(
        in context: CGContext,
        at point: CGPoint,
        colour: CGColor?,
        alignment: LabelAlignment
    ) {
        guard let label = blockLabel, !label.isEmpty, let palette, let colour else { return }
        let rect = decorationRect.offsetBy(dx: point.x, dy: point.y)

        let attributes: [CFString: Any] = [
            kCTFontAttributeName: palette.labelFont,
            kCTForegroundColorAttributeName: colour,
            // Small caps read as a label rather than as a very short line of
            // text, and the tracking is what keeps them from setting solid.
            kCTKernAttributeName: 0.6 as CFNumber,
        ]
        guard let attributed = CFAttributedStringCreate(
            nil, label as CFString, attributes as CFDictionary)
        else { return }
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))

        let x: CGFloat
        switch alignment {
        case .leading: x = rect.minX + Metrics.panelInset
        case .trailing: x = rect.maxX - width - Metrics.panelInset
        }
        // Centred in the strip the label's own height bought.
        let top = rect.minY + (Metrics.labelHeight + Metrics.blockPadding - ascent - descent) / 2

        context.saveGState()
        defer { context.restoreGState() }
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: x, y: top + ascent)
        CTLineDraw(line, context)
    }

    /// Draws the bullet or number standing in for a collapsed list marker.
    ///
    /// Placed by the same arithmetic as the checkbox, and for the same reason:
    /// TextKit hands some fragments an origin that already includes the
    /// paragraph's indent and some one that does not, so anything measured
    /// from `point` alone lands in a different column on alternate items.
    private func drawListMarker(in context: CGContext, at point: CGPoint) {
        guard let marker = listMarker, let palette else { return }
        let x = point.x + Self.checkboxX(
            textIndent: textIndent,
            indentCarriedByFragment: indentCarriedByFragment,
            gutter: Metrics.listMarkerGutter,
            inset: 0)

        let attributes: [CFString: Any] = [
            kCTFontAttributeName: palette.listMarkerFont,
            kCTForegroundColorAttributeName: palette.secondaryColor,
        ]
        guard let attributed = CFAttributedStringCreate(
            nil, marker as CFString, attributes as CFDictionary)
        else { return }
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))

        // Right-aligned in its gutter, so "9." and "10." share an edge with
        // the text rather than with each other's first digit.
        let right = x + Metrics.listMarkerGutter - Metrics.listMarkerGap
        // On the first line's baseline: the marker belongs to the line it
        // opens, not to the middle of a wrapped paragraph.
        let baseline = point.y + (firstLineBaseline ?? ascent)

        context.saveGState()
        defer { context.restoreGState() }
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: right - width, y: baseline)
        CTLineDraw(line, context)
    }

    /// Draws a rounded pill behind every run of inline code on this fragment's
    /// lines.
    ///
    /// The styler marks the runs and this measures them, for the reason the
    /// panel is drawn here too: `.backgroundColor` fills the whole line box,
    /// so a code word inside a heading is given a slab as tall as the heading
    /// and touching the paragraph under it.
    ///
    /// Per *line fragment*, so a span that wraps gets a pill on each line it
    /// occupies rather than one box spanning the gap between them.
    private func drawInlineCodePills(in context: CGContext, at point: CGPoint) {
        guard let palette else { return }
        let rects = inlineCodeRects
        guard !rects.isEmpty else { return }

        context.saveGState()
        defer { context.restoreGState() }
        context.setFillColor(palette.codeBackground)
        for rect in rects {
            context.addPath(
                CGPath(
                    roundedRect: rect.offsetBy(dx: point.x, dy: point.y),
                    cornerWidth: Metrics.inlineCodeRadius,
                    cornerHeight: Metrics.inlineCodeRadius, transform: nil))
            context.fillPath()
        }
    }

    /// The pills this fragment would draw, in the space `draw(at:in:)` works
    /// in — which is the fragment's own frame, with the origin at its top left.
    ///
    /// Exposed so the geometry can be asserted against TextKit's own answer for
    /// where those characters are, rather than against a screenshot.
    var inlineCodeRects: [CGRect] {
        var rects: [CGRect] = []
        for line in textLineFragments {
            let string = line.attributedString
            let whole = NSRange(location: 0, length: string.length)
            guard whole.length > 0 else { continue }

            string.enumerateAttribute(.inlineCodeRun, in: whole) { value, range, _ in
                guard value != nil, range.length > 0 else { return }
                guard let rect = pillRect(for: range, in: line) else { return }
                rects.append(rect)
            }
        }
        return rects
    }

    /// The pill for one run, or `nil` if the line cannot place it.
    ///
    /// Everything is guarded: `locationForCharacter` is asked about indices
    /// this fragment owns, but a run whose glyphs are all collapsed measures
    /// zero, and a rect of zero or non-finite size handed to Core Graphics is
    /// a drawing bug that shows up as a missing frame rather than as an error.
    private func pillRect(for range: NSRange, in line: NSTextLineFragment) -> CGRect? {
        let length = line.attributedString.length
        let first = min(max(range.location, 0), length)
        let last = min(NSMaxRange(range), length)
        guard last > first else { return nil }

        let bounds = line.typographicBounds
        let start = line.locationForCharacter(at: first).x
        // A run reaching the end of the line is measured to the line's own
        // edge: `locationForCharacter` is asked only about indices the line
        // certainly owns.
        let end = last < length ? line.locationForCharacter(at: last).x : bounds.width
        let width = end - start
        guard width > 0.5, width.isFinite, start.isFinite else { return nil }

        // Sized to the type, not to the leading: the pill hugs the glyphs so
        // consecutive lines of prose keep an even rhythm.
        let height = min(bounds.height, Metrics.inlineCodeHeight(for: font(of: range, in: line)))
        guard height > 0, height.isFinite else { return nil }

        return CGRect(
            x: bounds.origin.x + start - Metrics.inlineCodePadding,
            y: bounds.origin.y + (bounds.height - height) / 2,
            width: width + Metrics.inlineCodePadding * 2,
            height: height)
    }

    /// The font a run is set in, for sizing its pill.
    private func font(of range: NSRange, in line: NSTextLineFragment) -> NSFont? {
        guard range.location < line.attributedString.length else { return nil }
        return line.attributedString.attribute(.font, at: range.location, effectiveRange: nil)
            as? NSFont
    }

    /// Distance from the fragment's top to the baseline of its first line.
    private var firstLineBaseline: CGFloat? {
        guard let first = textLineFragments.first else { return nil }
        return first.typographicBounds.origin.y + first.glyphOrigin.y
    }

    /// Draws a single line of text with Core Text.
    ///
    /// Core Text rather than `NSString.draw`: the fragment may draw off the
    /// main actor, and AppKit's string drawing is not safe there.
    private func drawLabel(
        _ text: String,
        font: CTFont,
        color: CGColor,
        at origin: CGPoint,
        in context: CGContext
    ) {
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color,
        ]
        guard let attributed = CFAttributedStringCreate(
            nil, text as CFString, attributes as CFDictionary)
        else { return }
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, nil)

        context.saveGState()
        defer { context.restoreGState() }
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: origin.x, y: origin.y + ascent)
        CTLineDraw(line, context)
    }

    /// Draws a formula, diagram, or image where the source text would be.
    private func drawRenderedContent(in context: CGContext, at point: CGPoint) {
        let top = point.y + super.layoutFragmentFrame.height + Metrics.blockPadding

        if let rendered = renderedContent, let image = rendered.cgImage {
            let rect = CGRect(
                x: point.x + Metrics.blockPadding, y: top,
                width: rendered.size.width, height: rendered.size.height)
            context.saveGState()
            defer { context.restoreGState() }
            // Flip: the text context has its origin at the top, CGImage does
            // not, so an unflipped draw renders the diagram upside down.
            context.translateBy(x: 0, y: rect.midY)
            context.scaleBy(x: 1, y: -1)
            context.translateBy(x: 0, y: -rect.midY)
            context.draw(image, in: rect)
            return
        }

        // Never a silent blank: an empty space where a diagram should be is
        // indistinguishable from one the app cannot render.
        if let failure = renderFailure {
            drawFailure(failure.reason, in: context, at: CGPoint(x: point.x, y: top))
        }
    }

    /// Draws an explanation where content could not be rendered.
    private func drawFailure(_ reason: String, in context: CGContext, at point: CGPoint) {
        guard let palette else { return }
        let rect = CGRect(
            x: point.x, y: point.y,
            width: max(containerWidth - Metrics.blockPadding, 80),
            height: Metrics.failureHeight - Metrics.blockPadding)

        context.saveGState()
        defer { context.restoreGState() }
        context.setFillColor(palette.codeBackground)
        context.addPath(
            CGPath(
                roundedRect: rect, cornerWidth: Metrics.cornerRadius,
                cornerHeight: Metrics.cornerRadius, transform: nil))
        context.fillPath()

        drawLabel(
            reason, font: palette.labelFont, color: palette.secondaryColor,
            at: CGPoint(x: rect.minX + Metrics.blockPadding, y: rect.midY - 4), in: context)
    }

    /// Draws a checkbox where the `- [ ]` used to be.
    ///
    /// The marker text is collapsed and the paragraph indented to leave room
    /// for this, so the box sits in the gutter and the item's text starts
    /// after it.
    ///
    /// `point` arrives as `(0, 0)` with the context already translated to the
    /// fragment's origin — and TextKit does not put every fragment of one list
    /// in the same place. Measured on a two-item task list, the first item's
    /// fragment sits at the paragraph's 45pt indent and the second at the
    /// container's edge. A fixed offset from `point` is therefore right for
    /// one item and paints over the first letter of the other, which is what
    /// it did. ``checkboxX(textIndent:indentCarriedByFragment:gutter:inset:)``
    /// takes back out whatever the fragment's own origin contributed, so both
    /// land in one column.
    private func drawCheckbox(checked: Bool, in context: CGContext, at point: CGPoint) {
        guard let palette else { return }
        let side = Metrics.checkboxSide
        let rect = CGRect(
            x: point.x
                + Self.checkboxX(
                    textIndent: textIndent,
                    indentCarriedByFragment: indentCarriedByFragment,
                    gutter: Metrics.checkboxGutter,
                    inset: Metrics.checkboxInset),
            y: point.y + (layoutFragmentFrame.height - side) / 2,
            width: side, height: side)
        context.saveGState()
        defer { context.restoreGState() }

        let path = CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil)

        if checked {
            context.addPath(path)
            context.setFillColor(palette.accent)
            context.fillPath()

            // A tick, drawn rather than set in a font: a glyph would depend on
            // which symbol font happens to be installed.
            context.setStrokeColor(palette.checkmark)
            context.setLineWidth(1.8)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.move(to: CGPoint(x: rect.minX + side * 0.24, y: rect.midY))
            context.addLine(to: CGPoint(x: rect.minX + side * 0.44, y: rect.maxY - side * 0.28))
            context.addLine(to: CGPoint(x: rect.maxX - side * 0.22, y: rect.minY + side * 0.28))
            context.strokePath()
        } else {
            context.addPath(path)
            context.setStrokeColor(
                palette.secondaryColor.copy(alpha: 0.55) ?? palette.secondaryColor)
            context.setLineWidth(1.2)
            context.strokePath()
        }
    }
}

extension MarkdownLayoutFragment {
    /// Draws a table row's shading and its separating rule.
    private func drawTableRow(
        isHeader: Bool, isLast: Bool, in context: CGContext, at point: CGPoint
    ) {
        guard let palette else { return }
        let rect = decorationRect.offsetBy(dx: point.x, dy: point.y)

        context.saveGState()
        defer { context.restoreGState() }

        if isHeader {
            context.setFillColor(palette.tableHeader)
            context.fill(rect)
        }

        // A rule under every row but the last: a trailing line with nothing
        // below it reads as the table having lost a row.
        if !isLast {
            context.setStrokeColor(palette.tableBorder)
            context.setLineWidth(1)
            context.move(to: CGPoint(x: rect.minX, y: rect.maxY - 0.5))
            context.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 0.5))
            context.strokePath()
        }
    }

    /// Draws a thematic break in place of its `---`.
    private func drawRule(in context: CGContext, at point: CGPoint) {
        let rect = decorationRect.offsetBy(dx: point.x, dy: point.y)
        let y = rect.midY
        context.saveGState()
        defer { context.restoreGState() }
        guard let color = palette?.secondaryColor.copy(alpha: 0.35) else { return }
        context.setStrokeColor(color)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: rect.minX, y: y))
        context.addLine(to: CGPoint(x: rect.maxX, y: y))
        context.strokePath()
    }

    enum Metrics {
        static let blockPadding: CGFloat = 8
        /// Space between a code panel's edge and the code inside it. Owned
        /// here because both halves need it: the styler indents the text by
        /// it, and the panel places its language label against it.
        static let panelInset: CGFloat = 12
        static let cornerRadius: CGFloat = 6
        static let barWidth: CGFloat = 3
        static let rulePadding: CGFloat = 6
        /// Height reserved for an explanation when rendering fails.
        static let failureHeight: CGFloat = 34
        static let checkboxSide: CGFloat = 13
        /// Leading gutter the checkbox sits in.
        static let checkboxInset: CGFloat = 2
        /// Space the styler reserves for the checkbox and its gap.
        static let checkboxGutter: CGFloat = 21
        /// Strip a block label occupies above the block's first line.
        static let labelHeight: CGFloat = 11
        /// Gutter a list bullet or number is set in, ending just before the
        /// item's text. Narrower than the 16pt a list item is indented by, so
        /// it always fits inside the indent the styler already reserves.
        static let listMarkerGutter: CGFloat = 14
        /// Space between the marker and the text it introduces.
        static let listMarkerGap: CGFloat = 5
        /// Breathing room either side of an inline code run.
        static let inlineCodePadding: CGFloat = 3
        static let inlineCodeRadius: CGFloat = 4

        /// Height of the pill behind a run set in `font`.
        ///
        /// Derived from the type rather than from the line box: a line's
        /// height carries the paragraph's leading, and a pill that tall in a
        /// heading touches the line beneath it.
        static func inlineCodeHeight(for font: NSFont?) -> CGFloat {
            guard let font else { return 0 }
            return (font.ascender - font.descender).rounded() + inlineCodePadding * 2
        }
    }
}

extension EditorTheme {
    /// Background tint for a GFM alert.
    ///
    /// `nonisolated` because fragment drawing is: TextKit calls
    /// `draw(at:in:)` outside main-actor isolation, and these read only
    /// `NSColor` statics.
    public nonisolated func calloutBackground(_ kind: CalloutKind) -> NSColor {
        calloutAccent(kind).withAlphaComponent(0.12)
    }

    /// Accent colour for a GFM alert, matching GitHub's own semantics so the
    /// meaning carries over from where these notes are usually read.
    public nonisolated func calloutAccent(_ kind: CalloutKind) -> NSColor {
        switch kind {
        case .note: .systemBlue
        case .tip: .systemGreen
        case .important: .systemPurple
        case .warning: .systemOrange
        case .caution: .systemRed
        }
    }
}
