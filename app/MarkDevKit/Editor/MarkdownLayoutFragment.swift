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
    /// Font for the explanation shown where content could not be rendered.
    /// Larger than ``labelFont``: this is a sentence the reader has to read and
    /// act on, not a word naming a block.
    let failureFont: CTFont
    /// Font for a drawn list bullet or number. Sized from the body font, so a
    /// bullet keeps its place beside the text at any type size.
    let listMarkerFont: CTFont
    /// Fill, hover fill, and edge of a block's copy or zoom chip.
    let controlBackground: CGColor
    let controlHighlight: CGColor
    let controlBorder: CGColor
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
        failureFont = CTFontCreateUIFontForLanguage(.smallSystem, 11, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, 11, nil)
        listMarkerFont = CTFontCreateUIFontForLanguage(
            .system, theme.bodyFont.pointSize * 0.85, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, theme.bodyFont.pointSize * 0.85, nil)
        controlBackground = theme.controlBackground.cgColor
        controlHighlight = theme.controlHighlight.cgColor
        controlBorder = theme.controlBorder.cgColor
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

    /// The drawn grid this fragment's table row belongs to, resolved by the
    /// delegate while the row's source is collapsed.
    ///
    /// `nil` whenever the row is showing its own Markdown — the caret is in
    /// the table, or the mode is `.source` — in which case TextKit lays the
    /// pipes out as ordinary text and this fragment adds nothing.
    var tableRow: TableRowLayout?

    /// Whether this fragment draws the chip that copies its block's code.
    ///
    /// Set by the delegate rather than derived from ``decoration``, like
    /// ``blockLabel`` and for the same kind of reason: whether a control can be
    /// offered is not a question about the parse. A copy chip needs a
    /// pasteboard and a zoom chip needs a window, and one of those is missing
    /// inside a Quick Look extension.
    var offersCopy = false

    /// Whether this fragment draws the chip that opens its content large.
    var offersZoom = false

    /// The chip under the pointer, drawn brighter than the others.
    var hoveredControl: BlockControl?

    /// Whether the copy chip is showing its confirmation.
    ///
    /// Copying leaves nothing on screen to see — the pasteboard is somewhere
    /// else — so a control that gives no answer reads as one that did nothing,
    /// and the reader clicks it again.
    var copyConfirmed = false

    /// Height the rendered content needs, including its own padding.
    private var contentHeight: CGFloat {
        // A drawn table row stands in for text that has been collapsed to
        // nothing, so the row's whole height is the fragment's to add.
        if let tableRow { return tableRow.height }
        if let renderedContent {
            return renderedContent.size.height + Metrics.blockPadding * 2
        }
        return renderFailure == nil ? 0 : Metrics.failureHeight
    }

    // MARK: - Metrics

    /// Extra space above the block, so a code background does not butt
    /// against the paragraph above it.
    override var topMargin: CGFloat {
        switch decoration {
        case .code(let edge, _) where edge.roundsTop: return Metrics.blockPadding + topStrip
        case .callout(_, let edge) where edge.roundsTop: return Metrics.blockPadding + topStrip
        case .rule: return Metrics.rulePadding
        default: return super.topMargin
        }
    }

    /// Height of the strip above a panel's first line.
    ///
    /// Bought by whatever is drawn in it — a label, a control, or both — and
    /// not otherwise, so a block pays for no space nothing occupies. It is the
    /// strip's *existence* that has to be stable, not its contents: a code
    /// panel offering a copy chip keeps the strip whether or not its fence is
    /// labelled, and whether or not the caret is inside it, so moving the caret
    /// through a fence no longer reflows the page around it.
    private var topStrip: CGFloat {
        blockLabel == nil && !offersCopy ? 0 : Metrics.labelHeight
    }

    /// Vertical band the strip's contents are centred in — the strip itself
    /// plus the padding beneath it, which is empty until the block's first line
    /// of text.
    private var stripBand: CGFloat {
        Metrics.labelHeight + Metrics.blockPadding
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

    /// The chips this fragment draws, with the rects they occupy in the space
    /// `draw(at:in:)` works in.
    ///
    /// The one place that decides where a control is. Drawing and hit-testing
    /// both read it, so a chip cannot be painted in one place and clicked in
    /// another — which is a control that looks like nothing at all.
    var controlRects: [(control: BlockControl, rect: CGRect)] {
        var found: [(BlockControl, CGRect)] = []
        if offersCopy {
            found.append(
                (.copy, BlockControlLayout.copyRect(inPanel: decorationRect, stripHeight: stripBand)))
        }
        if offersZoom, let content = renderedContentRect {
            found.append(
                (.zoom, BlockControlLayout.zoomRect(forContent: content, inPanel: decorationRect)))
        }
        return found
    }

    /// The control a click at `point` — in fragment-local coordinates — lands
    /// on, if any.
    func control(at point: CGPoint) -> BlockControl? {
        for (control, rect) in controlRects
        where BlockControlLayout.hitArea(of: rect).contains(point) {
            return control
        }
        return nil
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
            // Leading, like a callout's. The trailing end of the strip belongs
            // to the copy chip, and two things tucked against one edge is an
            // offset that depends on how long the language happens to be —
            // `javascript` would have run into the chip.
            drawBlockLabel(
                in: context, at: point, colour: palette?.secondaryColor.copy(alpha: 0.75),
                alignment: .leading)
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
        drawControls(in: context, at: point)

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

    // MARK: - Measured lines

    /// A Core Text line and its metrics, built once and reused across draws.
    struct MeasuredLine {
        let line: CTLine
        let width: CGFloat
        let ascent: CGFloat
        let descent: CGFloat
    }

    /// Everything that changes a line's ink apart from its colour.
    struct LineKey: Hashable {
        let text: String
        let fontName: String
        let fontSize: CGFloat
        let kern: Double
    }

    /// Lines drawn in strips and gutters, cached by ``LineKey``.
    ///
    /// A fragment repaints often — hover ticks, copy confirmations, scroll
    /// damage — and every pass used to build an attributed string, a Core
    /// Text line, and its metrics again. Colour is deliberately absent from
    /// the key: the cached line carries none, and ``CTLineDraw`` falls back
    /// to the context's fill colour, so one line serves every tint the
    /// palette can produce. It lives on the fragment and dies with it, so
    /// nothing here needs a bound of its own. Draw-time only; layout metrics
    /// never consult it.
    var measuredLines: [LineKey: MeasuredLine] = [:]

    /// The line for `text`, measuring it on first use.
    private func measuredLine(text: String, font: CTFont, kern: Double) -> MeasuredLine {
        let key = LineKey(
            text: text,
            fontName: CTFontCopyPostScriptName(font) as String,
            fontSize: CTFontGetSize(font),
            kern: kern)
        if let cached = measuredLines[key] { return cached }

        var attributes: [CFString: Any] = [kCTFontAttributeName: font]
        if kern != 0 { attributes[kCTKernAttributeName] = kern as CFNumber }
        guard
            let attributed = CFAttributedStringCreate(
                nil, text as CFString, attributes as CFDictionary)
        else { return Self.emptyMeasuredLine }

        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        let value = MeasuredLine(line: line, width: width, ascent: ascent, descent: descent)
        measuredLines[key] = value
        return value
    }

    /// What a line that could not be built measures: nothing.
    private static let emptyMeasuredLine = MeasuredLine(
        line: CTLineCreateWithAttributedString(
            CFAttributedStringCreate(nil, "" as CFString, nil)!),
        width: 0, ascent: 0, descent: 0)

    /// Draws the label standing in for the block's collapsed opening line.
    private func drawBlockLabel(
        in context: CGContext,
        at point: CGPoint,
        colour: CGColor?,
        alignment: LabelAlignment
    ) {
        guard let label = blockLabel, !label.isEmpty, let palette, let colour else { return }
        let rect = decorationRect.offsetBy(dx: point.x, dy: point.y)

        // Small caps read as a label rather than as a very short line of
        // text, and the tracking is what keeps them from setting solid.
        let measured = measuredLine(text: label, font: palette.labelFont, kern: 0.6)

        let x: CGFloat
        switch alignment {
        case .leading: x = rect.minX + Metrics.panelInset
        case .trailing: x = rect.maxX - measured.width - Metrics.panelInset
        }
        // Centred in the strip the label's own height bought.
        let top = rect.minY
            + (Metrics.labelHeight + Metrics.blockPadding - measured.ascent - measured.descent) / 2

        context.saveGState()
        defer { context.restoreGState() }
        context.setFillColor(colour)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: x, y: top + measured.ascent)
        CTLineDraw(measured.line, context)
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

        let measured = measuredLine(text: marker, font: palette.listMarkerFont, kern: 0)

        // Right-aligned in its gutter, so "9." and "10." share an edge with
        // the text rather than with each other's first digit.
        let right = x + Metrics.listMarkerGutter - Metrics.listMarkerGap
        // On the first line's baseline: the marker belongs to the line it
        // opens, not to the middle of a wrapped paragraph.
        let baseline = point.y + (firstLineBaseline ?? measured.ascent)

        context.saveGState()
        defer { context.restoreGState() }
        context.setFillColor(palette.secondaryColor)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: right - measured.width, y: baseline)
        CTLineDraw(measured.line, context)
    }

    // MARK: - Controls

    /// Draws the block's chips: the one that copies its code, the one that
    /// opens its picture.
    ///
    /// Drawn *after* the panel and before the text, so a chip sits on the
    /// decoration it belongs to; a code line long enough to reach the strip
    /// would otherwise be painted over by its own block's control.
    private func drawControls(in context: CGContext, at point: CGPoint) {
        guard let palette else { return }
        for (control, rect) in controlRects {
            let placed = rect.offsetBy(dx: point.x, dy: point.y)
            guard placed.width > 0, placed.height > 0 else { continue }

            context.saveGState()
            let path = CGPath(
                roundedRect: placed, cornerWidth: BlockControlLayout.radius,
                cornerHeight: BlockControlLayout.radius, transform: nil)
            context.addPath(path)
            context.setFillColor(
                hoveredControl == control ? palette.controlHighlight : palette.controlBackground)
            context.fillPath()

            context.addPath(
                CGPath(
                    roundedRect: placed.insetBy(dx: 0.5, dy: 0.5),
                    cornerWidth: BlockControlLayout.radius,
                    cornerHeight: BlockControlLayout.radius, transform: nil))
            context.setStrokeColor(palette.controlBorder)
            context.setLineWidth(1)
            context.strokePath()

            // The glyph is drawn in a square inside the chip, so both controls
            // are the same weight however wide their chip is.
            let side = min(placed.height - Metrics.controlGlyphInset * 2, placed.width)
            let glyph = CGRect(
                x: placed.midX - side / 2, y: placed.midY - side / 2,
                width: side, height: side)
            context.setLineWidth(1.2)
            context.setLineCap(.round)
            context.setLineJoin(.round)

            switch control {
            case .copy:
                if copyConfirmed {
                    drawTick(in: glyph, context: context, colour: palette.accent)
                } else {
                    drawCopyGlyph(in: glyph, context: context, palette: palette)
                }
            case .zoom:
                drawZoomGlyph(in: glyph, context: context, colour: palette.secondaryColor)
            }
            context.restoreGState()
        }
    }

    /// Two sheets, one behind the other: the icon every reader already knows
    /// means "copy".
    private func drawCopyGlyph(
        in glyph: CGRect, context: CGContext, palette: BlockDecorationPalette
    ) {
        let sheet = glyph.width * 0.72
        let back = CGRect(
            x: glyph.maxX - sheet, y: glyph.minY, width: sheet, height: sheet)
        let front = CGRect(
            x: glyph.minX, y: glyph.maxY - sheet, width: sheet, height: sheet)

        context.setStrokeColor(palette.secondaryColor)
        context.addPath(CGPath(roundedRect: back, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
        context.strokePath()

        // The front sheet is filled with the chip's own colour before it is
        // stroked, so it reads as being *in front* rather than as two squares
        // crossing each other.
        let path = CGPath(roundedRect: front, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)
        context.addPath(path)
        context.setFillColor(
            hoveredControl == .copy ? palette.controlHighlight : palette.controlBackground)
        context.fillPath()
        context.addPath(path)
        context.strokePath()
    }

    /// Four corners pointing outward — the expand glyph, rather than a
    /// magnifier: this opens the picture, it does not enlarge it in place.
    private func drawZoomGlyph(in glyph: CGRect, context: CGContext, colour: CGColor) {
        let arm = glyph.width * 0.36
        context.setStrokeColor(colour)
        for corner in [(true, true), (false, true), (true, false), (false, false)] {
            let x = corner.0 ? glyph.minX : glyph.maxX
            let y = corner.1 ? glyph.minY : glyph.maxY
            let dx = corner.0 ? arm : -arm
            let dy = corner.1 ? arm : -arm
            context.move(to: CGPoint(x: x + dx, y: y))
            context.addLine(to: CGPoint(x: x, y: y))
            context.addLine(to: CGPoint(x: x, y: y + dy))
        }
        context.strokePath()
    }

    /// The same tick a checked checkbox draws, sized to a chip.
    private func drawTick(in glyph: CGRect, context: CGContext, colour: CGColor) {
        context.setStrokeColor(colour)
        context.setLineWidth(1.6)
        context.move(to: CGPoint(x: glyph.minX, y: glyph.midY))
        context.addLine(to: CGPoint(x: glyph.minX + glyph.width * 0.32, y: glyph.maxY - 1))
        context.addLine(to: CGPoint(x: glyph.maxX, y: glyph.minY + 1))
        context.strokePath()
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

    /// Top of whatever stands in for the block's text, in the space
    /// `draw(at:in:)` works in.
    ///
    /// Below the (collapsed) source, which is why it is measured from
    /// `super.layoutFragmentFrame` and not from the override: the override has
    /// already added the content's own height, and measuring from it would put
    /// the content below the room reserved for it.
    private var contentTop: CGFloat {
        super.layoutFragmentFrame.height + Metrics.blockPadding
    }

    /// Where the formula, diagram, or picture is drawn, in fragment-local
    /// coordinates.
    ///
    /// Exposed for the same reason ``decorationRect`` and ``inlineCodeRects``
    /// are: where this lands, and which way up it is, is the whole of two bugs
    /// this has had — and asserting geometry beats inferring it from a
    /// screenshot.
    var renderedContentRect: CGRect? {
        guard let rendered = renderedContent, rendered.cgImage != nil else { return nil }
        return CGRect(
            x: Metrics.blockPadding, y: contentTop,
            width: rendered.size.width, height: rendered.size.height)
    }

    /// Draws a formula, diagram, or image where the source text would be.
    private func drawRenderedContent(in context: CGContext, at point: CGPoint) {
        if let rendered = renderedContent, let image = rendered.cgImage,
            let local = renderedContentRect
        {
            let rect = local.offsetBy(dx: point.x, dy: point.y)
            context.saveGState()
            defer { context.restoreGState() }
            // The text context is flipped — `NSTextView` is a flipped view — and
            // `CGContext.draw` puts an image's first row at the *bottom* of the
            // rect in the current space. Reflecting about the rect's own middle
            // therefore leaves the rect where it is and turns the picture the
            // right way up.
            //
            // Correct for every image because `RenderedContent` normalises them
            // to one orientation. It did not, and a Mermaid diagram was drawn
            // bottom-up next to a formula that was not: the flip happened to
            // suit a bitmap captured from a flipped AppKit view, which is what
            // the formula came from and nothing else did.
            context.translateBy(x: 0, y: rect.midY)
            context.scaleBy(x: 1, y: -1)
            context.translateBy(x: 0, y: -rect.midY)
            context.draw(image, in: rect)
            return
        }

        // Never a silent blank: an empty space where a diagram should be is
        // indistinguishable from one the app cannot render.
        if let failure = renderFailure {
            drawFailure(
                failure.reason, in: context, at: CGPoint(x: point.x, y: point.y + contentTop))
        }
    }

    /// Names the kind of content that failed, so a library's own error message
    /// arrives attached to something the reader can act on.
    ///
    /// A bare `invalidHeader("…")` says nothing about *which* block of a note
    /// is wrong, and the source it belongs to is collapsed behind this strip —
    /// putting the caret in the block is what brings it back.
    private var failureSubject: String? {
        switch decoration.rendered?.kind {
        case .math: "Formula"
        case .diagram: "Diagram"
        case .image: "Image"
        case nil: nil
        }
    }

    /// Draws an explanation where content could not be rendered.
    ///
    /// Clipped to its own panel: a library error can be long, and Core Text
    /// draws a line wherever it is told to, straight off the edge of the column
    /// and over the margin.
    private func drawFailure(_ reason: String, in context: CGContext, at point: CGPoint) {
        guard let palette else { return }
        let rect = CGRect(
            x: point.x, y: point.y,
            width: max(containerWidth - Metrics.blockPadding, 80),
            height: Metrics.failureHeight - Metrics.blockPadding)

        context.saveGState()
        defer { context.restoreGState() }
        context.addPath(
            CGPath(
                roundedRect: rect, cornerWidth: Metrics.cornerRadius,
                cornerHeight: Metrics.cornerRadius, transform: nil))
        context.setFillColor(palette.codeBackground)
        context.fillPath()

        // The same hairline a code panel carries. A block that did not render
        // is still a block, and a tinted rectangle with no edge reads as a
        // rendering artefact rather than as part of the document.
        let inset = rect.insetBy(dx: 0.5, dy: 0.5)
        context.addPath(
            CGPath(
                roundedRect: inset, cornerWidth: Metrics.cornerRadius,
                cornerHeight: Metrics.cornerRadius, transform: nil))
        context.setStrokeColor(palette.codeBorder)
        context.setLineWidth(1)
        context.strokePath()

        context.clip(to: rect.insetBy(dx: Metrics.blockPadding / 2, dy: 0))
        let text = failureSubject.map { "\($0): \(reason)" } ?? reason
        drawLabel(
            text, font: palette.failureFont, color: palette.secondaryColor,
            at: CGPoint(x: rect.minX + Metrics.blockPadding, y: rect.midY - 6), in: context)
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
    ///
    /// When the row's source is collapsed this also draws the row's cells,
    /// each wrapped inside the column the grid solved for it. When it is not —
    /// the caret is in the table, so the Markdown is on screen to be edited —
    /// only the shading and the rule are drawn, and TextKit lays the pipes out
    /// as the ordinary text they are.
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

        guard let tableRow else { return }
        drawTableCells(tableRow, in: context, within: rect)
    }

    /// Paints each cell into the column the grid gave it.
    ///
    /// The cells are drawn from the row's leading text edge, which is the
    /// panel inset the styler reserved — the same inset a code block's text
    /// gets, so the first column's letters do not sit on the row's border.
    private func drawTableCells(
        _ row: TableRowLayout, in context: CGContext, within rect: CGRect
    ) {
        let origin = CGPoint(
            x: rect.minX + Metrics.panelInset,
            y: rect.minY + TableRowLayout.Metrics.verticalPadding)

        for (column, cell) in row.cells.enumerated() {
            let frame = row.grid.rect(forColumn: column, height: cell.height)
            guard frame.width > 0 else { continue }
            let at = CGPoint(x: origin.x + frame.minX, y: origin.y)

            if let pill = palette?.codeBackground {
                context.setFillColor(pill)
                for rect in cell.pills {
                    let placed = rect.offsetBy(dx: at.x, dy: at.y)
                        .insetBy(dx: -Metrics.inlineCodePadding, dy: 0)
                    guard placed.width > 0, placed.height > 0 else { continue }
                    context.addPath(
                        CGPath(
                            roundedRect: placed,
                            cornerWidth: Metrics.inlineCodeRadius,
                            cornerHeight: Metrics.inlineCodeRadius,
                            transform: nil))
                    context.fillPath()
                }
            }

            cell.draw(in: context, at: at)
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
        /// Space between a chip's edge and the glyph inside it.
        static let controlGlyphInset: CGFloat = 3
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
