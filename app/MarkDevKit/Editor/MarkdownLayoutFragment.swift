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
    let quoteColor: CGColor
    let secondaryColor: CGColor
    let labelFont: CTFont
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
        quoteColor = theme.quoteColor.cgColor
        secondaryColor = theme.secondaryColor.cgColor
        labelFont = CTFontCreateUIFontForLanguage(.smallSystem, 9, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, 9, nil)
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
        switch decoration {
        case .code(let edge, _) where edge.roundsTop: Metrics.blockPadding
        case .callout(_, let edge) where edge.roundsTop: Metrics.blockPadding
        case .rule: Metrics.rulePadding
        default: super.topMargin
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

    /// The area the fragment actually paints.
    ///
    /// Without widening this, the background is clipped to the text's own
    /// bounds and the padding drawn around it is simply not shown.
    override var renderingSurfaceBounds: CGRect {
        guard decoration != .none else { return super.renderingSurfaceBounds }
        return super.renderingSurfaceBounds.union(decorationRect)
    }

    /// The rect the decoration covers.
    ///
    /// Spans to the text container's edge, not the fragment's own width. A
    /// layout fragment is only as wide as the line it holds, so sizing the
    /// panel from it draws a ragged stack of boxes — one per line, each
    /// stopping where its text happens to end — instead of one block.
    private var decorationRect: CGRect {
        let frame = layoutFragmentFrame
        let width = max(containerWidth - frame.origin.x, frame.width, 1)
        return CGRect(
            x: 0,
            y: -topMargin,
            width: width,
            height: frame.height + topMargin + bottomMargin)
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
        case .code(let edge, let language):
            drawPanel(
                in: context, at: point, edge: edge,
                fill: palette?.codeBackground, bar: nil)
            if edge.roundsTop, let language, !language.isEmpty, let palette {
                drawLanguagePill(language, palette: palette, in: context, at: point)
            }
        case .callout(let kind, let edge):
            let accent = palette?.calloutAccent(kind)
            drawPanel(
                in: context, at: point, edge: edge,
                fill: accent?.copy(alpha: 0.12), bar: accent)
        case .quote(let edge):
            
            drawPanel(in: context, at: point, edge: edge, fill: nil, bar: palette?.quoteColor)
        case .rule:
            drawRule(in: context, at: point)
        case .rendered:
            drawRenderedContent(in: context, at: point)
        case .task(let checked):
            
            drawCheckbox(checked: checked, in: context, at: point)
        case .tableRow(let isHeader, let isLast):
            drawTableRow(isHeader: isHeader, isLast: isLast, in: context, at: point)
        }

        super.draw(at: point, in: context)
    }

    /// Draws the rounded background, joined across the block's lines.
    ///
    /// Only the first and last lines round their corners; the middle draws
    /// square so consecutive fragments meet without a seam.
    private func drawPanel(
        in context: CGContext,
        at point: CGPoint,
        edge: BlockEdge,
        fill: CGColor?,
        bar: CGColor?
    ) {
        let rect = decorationRect.offsetBy(dx: point.x, dy: point.y)
        context.saveGState()
        defer { context.restoreGState() }

        if let fill {
            let radius = Metrics.cornerRadius
            let path = CGMutablePath()
            let topRadius = edge.roundsTop ? radius : 0
            let bottomRadius = edge.roundsBottom ? radius : 0

            path.move(to: CGPoint(x: rect.minX + topRadius, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - topRadius, y: rect.minY))
            if topRadius > 0 {
                path.addArc(
                    tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                    tangent2End: CGPoint(x: rect.maxX, y: rect.minY + topRadius),
                    radius: topRadius)
            }
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRadius))
            if bottomRadius > 0 {
                path.addArc(
                    tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.maxX - bottomRadius, y: rect.maxY),
                    radius: bottomRadius)
            }
            path.addLine(to: CGPoint(x: rect.minX + bottomRadius, y: rect.maxY))
            if bottomRadius > 0 {
                path.addArc(
                    tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.minX, y: rect.maxY - bottomRadius),
                    radius: bottomRadius)
            }
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topRadius))
            if topRadius > 0 {
                path.addArc(
                    tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                    tangent2End: CGPoint(x: rect.minX + topRadius, y: rect.minY),
                    radius: topRadius)
            }
            path.closeSubpath()

            context.addPath(path)
            context.setFillColor(fill)
            context.fillPath()
        }

        if let bar {
            let barRect = CGRect(
                x: rect.minX, y: rect.minY,
                width: Metrics.barWidth, height: rect.height)
            context.setFillColor(bar)
            context.fill(barRect)
        }
    }

    /// Draws the language name in the code block's top-right corner.
    private func drawLanguagePill(
        _ language: String,
        palette: BlockDecorationPalette,
        in context: CGContext,
        at point: CGPoint
    ) {
        let rect = decorationRect.offsetBy(dx: point.x, dy: point.y)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: palette.labelFont,
            kCTForegroundColorAttributeName: palette.secondaryColor.copy(alpha: 0.7) as Any,
        ]
        guard let attributed = CFAttributedStringCreate(
            nil, language.uppercased() as CFString, attributes as CFDictionary)
        else { return }
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        let origin = CGPoint(
            x: rect.maxX - width - Metrics.blockPadding,
            y: rect.minY + 2)

        context.saveGState()
        defer { context.restoreGState() }
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: origin.x, y: origin.y + ascent + descent)
        CTLineDraw(line, context)
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
            context.setFillColor(palette.codeBackground)
            context.fill(rect)
        }

        // A rule under every row but the last: a trailing line with nothing
        // below it reads as the table having lost a row.
        if !isLast {
            context.setStrokeColor(palette.secondaryColor.copy(alpha: 0.22) ?? palette.secondaryColor)
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
