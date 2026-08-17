//
//  MarkdownLayoutFragment.swift
//  MarkDevKit
//
//  Custom drawing behind code blocks, tables, callouts, quotes, and rules,
//  and over checkboxes, tags, and inline code.
//

@preconcurrency import AppKit
@preconcurrency import CoreText

/// Immutable, concurrency-safe drawing values captured from `EditorTheme` on
/// the main actor. TextKit's fragment callbacks predate actor annotations and
/// may be nonisolated, so the renderer must not retain NSColor or NSFont.
struct BlockDecorationPalette: Sendable {
    let codeBackground: CGColor
    let codeBorder: CGColor
    let tableHeaderBackground: CGColor
    let tableStripeBackground: CGColor
    let tableBorder: CGColor
    let tagBackground: CGColor
    let tagForeground: CGColor
    let inlineCodeBackground: CGColor
    let accentColor: CGColor
    let checkmarkColor: CGColor
    let quoteColor: CGColor
    let secondaryColor: CGColor
    let labelFont: CTFont
    let note: CGColor
    let tip: CGColor
    let important: CGColor
    let warning: CGColor
    let caution: CGColor

    @MainActor
    init(theme: EditorTheme) {
        codeBackground = theme.codeBackground.cgColor
        codeBorder = theme.codeBorder.cgColor
        tableHeaderBackground = theme.tableHeaderBackground.cgColor
        tableStripeBackground = theme.tableStripeBackground.cgColor
        tableBorder = theme.tableBorder.cgColor
        tagBackground = theme.tagBackground.cgColor
        tagForeground = theme.tagColor.cgColor
        inlineCodeBackground = theme.codeBackground.cgColor
        accentColor = theme.accentColor.cgColor
        checkmarkColor = theme.checkmarkColor.cgColor
        quoteColor = theme.quoteColor.cgColor
        secondaryColor = theme.secondaryColor.cgColor
        labelFont = CTFontCreateUIFontForLanguage(.smallSystem, 9, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, 9, nil)
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
    /// Ornaments drawn over inline runs of this fragment's own text.
    var ornaments: [InlineOrnament] = []
    /// This fragment's range in document coordinates, so ornament ranges can
    /// be made local without asking the layout manager mid-draw.
    var documentRange: NSRange = NSRange(location: 0, length: 0)
    var palette: BlockDecorationPalette?

    // MARK: - Metrics

    /// Extra space above the block, so a code background does not butt
    /// against the paragraph above it.
    override var topMargin: CGFloat {
        switch decoration {
        case .code(let edge, _, _) where edge.roundsTop: Metrics.blockPadding
        case .callout(_, let edge) where edge.roundsTop: Metrics.blockPadding
        // A table asks for no margin above it at all. Its top padding is
        // paragraph spacing *inside* the header row, so the panel starts at
        // the row's own top edge. Reaching above it would put the panel's
        // border in the previous line's box — which, once live preview has
        // collapsed the blank line between them, is occupied by real text.
        case .table: 0
        case .rule: Metrics.rulePadding
        default: super.topMargin
        }
    }

    override var bottomMargin: CGFloat {
        switch decoration {
        case .code(let edge, _, _) where edge.roundsBottom: Metrics.blockPadding
        case .callout(_, let edge) where edge.roundsBottom: Metrics.blockPadding
        case .table(let edge, _) where edge.roundsBottom: Metrics.tablePadding
        case .rule: Metrics.rulePadding
        default: super.bottomMargin
        }
    }

    /// The area the fragment actually paints.
    ///
    /// Without widening this, the background is clipped to the text's own
    /// bounds and the padding drawn around it is simply not shown. Ornaments
    /// widen it too: a checkbox and a tag pill both bleed a point or two past
    /// the glyphs they cover, and a surface sized to the glyphs alone shaves
    /// the pill's ends off.
    ///
    /// The ornament allowance is a flat inset rather than a union of their
    /// actual rects. Every ornament sits over this fragment's own glyphs, so a
    /// uniform bleed is always enough — and working out where they are would
    /// mean reading line geometry from inside a bounds query, which TextKit
    /// asks for constantly and which can drive layout while layout is already
    /// running.
    override var renderingSurfaceBounds: CGRect {
        var bounds = super.renderingSurfaceBounds
        if decoration != .none {
            bounds = bounds.union(decorationRect)
        }
        if !ornaments.isEmpty {
            bounds = bounds.insetBy(dx: -Metrics.ornamentBleed, dy: -Metrics.ornamentBleed)
        }
        return bounds
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

    /// The pop-out control's rect, in fragment-local coordinates, or `nil`
    /// when this fragment carries no such control.
    ///
    /// Only the first line of a code or diagram block gets one: the panel has
    /// a single top-right corner however many lines it spans.
    var expandControlRect: CGRect? {
        guard case .code(let edge, _, _) = decoration, edge.roundsTop else { return nil }
        let rect = decorationRect
        let side = Metrics.controlSide
        return CGRect(
            x: rect.maxX - Metrics.blockPadding - side,
            y: rect.minY + Metrics.controlInset,
            width: side,
            height: side)
    }

    // MARK: - Drawing

    override func draw(at point: CGPoint, in context: CGContext) {
        switch decoration {
        case .none:
            break
        case .code(let edge, let language, _):
            drawPanel(
                in: context, at: point, edge: edge,
                fill: palette?.codeBackground, bar: nil,
                border: palette?.codeBorder)
            if edge.roundsTop, let palette {
                if let language, !language.isEmpty {
                    drawLabel(language, palette: palette, in: context, at: point)
                }
                drawExpandControl(palette: palette, in: context, at: point)
            }
        case .callout(let kind, let edge):
            let accent = palette?.calloutAccent(kind)
            drawPanel(
                in: context, at: point, edge: edge,
                fill: accent?.copy(alpha: 0.12), bar: accent, border: nil)
        case .quote(let edge):
            drawPanel(
                in: context, at: point, edge: edge, fill: nil,
                bar: palette?.quoteColor, border: nil)
        case .rule:
            drawRule(in: context, at: point)
        case .table(let edge, let role):
            drawTableRow(in: context, at: point, edge: edge, role: role)
        }

        drawOrnaments(in: context, at: point)
        super.draw(at: point, in: context)
    }

    // MARK: - Panels

    /// Draws the rounded background, joined across the block's lines.
    ///
    /// Only the first and last lines round their corners; the middle draws
    /// square so consecutive fragments meet without a seam. For the same
    /// reason the border is stroked as three separate edges rather than around
    /// the path — stroking a middle line's full rectangle would draw a
    /// horizontal rule across the block at every line break.
    private func drawPanel(
        in context: CGContext,
        at point: CGPoint,
        edge: BlockEdge,
        fill: CGColor?,
        bar: CGColor?,
        border: CGColor?
    ) {
        let rect = decorationRect.offsetBy(dx: point.x, dy: point.y)
        context.saveGState()
        defer { context.restoreGState() }

        if let fill {
            context.addPath(Self.panelPath(rect, edge: edge, radius: Metrics.cornerRadius))
            context.setFillColor(fill)
            context.fillPath()
        }

        if let border {
            drawPanelBorder(rect, edge: edge, color: border, in: context)
        }

        if let bar {
            let barRect = CGRect(
                x: rect.minX, y: rect.minY,
                width: Metrics.barWidth, height: rect.height)
            context.setFillColor(bar)
            context.fill(barRect)
        }
    }

    /// Strokes the panel's outline without closing it across line seams.
    private func drawPanelBorder(
        _ rect: CGRect,
        edge: BlockEdge,
        color: CGColor,
        in context: CGContext
    ) {
        let radius = Metrics.cornerRadius
        // Half a point in, so a 1pt stroke lands on the pixel rather than
        // straddling it and reading as a soft 2pt smudge.
        let inset = rect.insetBy(dx: 0.5, dy: 0.5)
        let path = CGMutablePath()
        let topRadius = edge.roundsTop ? radius : 0
        let bottomRadius = edge.roundsBottom ? radius : 0

        // Left edge, always.
        path.move(to: CGPoint(x: inset.minX, y: edge.roundsTop ? inset.minY + topRadius : rect.minY))
        path.addLine(
            to: CGPoint(x: inset.minX, y: edge.roundsBottom ? inset.maxY - bottomRadius : rect.maxY))
        // Right edge, always.
        path.move(to: CGPoint(x: inset.maxX, y: edge.roundsTop ? inset.minY + topRadius : rect.minY))
        path.addLine(
            to: CGPoint(x: inset.maxX, y: edge.roundsBottom ? inset.maxY - bottomRadius : rect.maxY))

        if edge.roundsTop {
            path.move(to: CGPoint(x: inset.minX, y: inset.minY + topRadius))
            path.addArc(
                tangent1End: CGPoint(x: inset.minX, y: inset.minY),
                tangent2End: CGPoint(x: inset.minX + topRadius, y: inset.minY),
                radius: topRadius)
            path.addLine(to: CGPoint(x: inset.maxX - topRadius, y: inset.minY))
            path.addArc(
                tangent1End: CGPoint(x: inset.maxX, y: inset.minY),
                tangent2End: CGPoint(x: inset.maxX, y: inset.minY + topRadius),
                radius: topRadius)
        }
        if edge.roundsBottom {
            path.move(to: CGPoint(x: inset.minX, y: inset.maxY - bottomRadius))
            path.addArc(
                tangent1End: CGPoint(x: inset.minX, y: inset.maxY),
                tangent2End: CGPoint(x: inset.minX + bottomRadius, y: inset.maxY),
                radius: bottomRadius)
            path.addLine(to: CGPoint(x: inset.maxX - bottomRadius, y: inset.maxY))
            path.addArc(
                tangent1End: CGPoint(x: inset.maxX, y: inset.maxY),
                tangent2End: CGPoint(x: inset.maxX, y: inset.maxY - bottomRadius),
                radius: bottomRadius)
        }

        context.addPath(path)
        context.setStrokeColor(color)
        context.setLineWidth(1)
        context.strokePath()
    }

    /// A rounded rectangle that rounds only the corners `edge` asks for.
    private static func panelPath(_ rect: CGRect, edge: BlockEdge, radius: CGFloat) -> CGPath {
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
        return path
    }

    // MARK: - Tables

    /// Draws one line of a table.
    ///
    /// Live preview hides every `|` and the whole delimiter row, so without
    /// this a table reads as a run of jammed-together words. The panel, the
    /// tinted header, and the alternating row fills are what make the grid
    /// legible once its punctuation is gone.
    private func drawTableRow(
        in context: CGContext,
        at point: CGPoint,
        edge: BlockEdge,
        role: TableRole
    ) {
        guard let palette else { return }
        let rect = decorationRect.offsetBy(dx: point.x, dy: point.y)
        context.saveGState()
        defer { context.restoreGState() }

        let fill: CGColor?
        switch role {
        case .header: fill = palette.tableHeaderBackground
        case .separator: fill = nil
        case .body(let row): fill = row.isMultiple(of: 2) ? nil : palette.tableStripeBackground
        }

        if let fill {
            context.addPath(Self.panelPath(rect, edge: edge, radius: Metrics.cornerRadius))
            context.setFillColor(fill)
            context.fillPath()
        }
        drawPanelBorder(rect, edge: edge, color: palette.tableBorder, in: context)

        // The delimiter row collapses to nothing in live preview, which leaves
        // exactly the gap the header rule belongs in.
        if case .separator = role {
            context.setStrokeColor(palette.tableBorder)
            context.setLineWidth(1)
            context.move(to: CGPoint(x: rect.minX, y: rect.midY))
            context.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            context.strokePath()
        }
    }

    // MARK: - Labels and controls

    /// Draws the language name in the code block's top-right corner.
    private func drawLabel(
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
        // Left of the pop-out control, which owns the corner itself.
        let origin = CGPoint(
            x: rect.maxX - width - Metrics.blockPadding - Metrics.controlSide
                - Metrics.labelGap,
            y: rect.minY + 2)

        context.saveGState()
        defer { context.restoreGState() }
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: origin.x, y: origin.y + ascent + descent)
        CTLineDraw(line, context)
    }

    /// Draws the pop-out control: two opposed corner brackets.
    ///
    /// Drawn rather than set as a button because there is no view here to hold
    /// one — a layout fragment is geometry, and the text view hit-tests
    /// ``expandControlRect`` to make it clickable.
    private func drawExpandControl(
        palette: BlockDecorationPalette,
        in context: CGContext,
        at point: CGPoint
    ) {
        guard let local = expandControlRect else { return }
        let rect = local.offsetBy(dx: point.x, dy: point.y).insetBy(dx: 3, dy: 3)
        let arm = rect.width * 0.42

        context.saveGState()
        defer { context.restoreGState() }
        context.setStrokeColor(palette.secondaryColor.copy(alpha: 0.75) ?? palette.secondaryColor)
        context.setLineWidth(1.5)
        context.setLineCap(.round)

        // Top-left bracket.
        context.move(to: CGPoint(x: rect.minX, y: rect.minY + arm))
        context.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        context.addLine(to: CGPoint(x: rect.minX + arm, y: rect.minY))
        // Bottom-right bracket.
        context.move(to: CGPoint(x: rect.maxX, y: rect.maxY - arm))
        context.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        context.addLine(to: CGPoint(x: rect.maxX - arm, y: rect.maxY))
        context.strokePath()
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

    // MARK: - Ornaments

    private func drawOrnaments(in context: CGContext, at point: CGPoint) {
        guard let palette, !ornaments.isEmpty else { return }
        for ornament in ornaments {
            for local in rects(for: ornament.range) {
                let rect = local.offsetBy(dx: point.x, dy: point.y)
                switch ornament {
                case .checkbox(_, let checked):
                    drawCheckbox(in: rect, checked: checked, palette: palette, context: context)
                case .codePill:
                    drawPill(
                        in: rect, fill: palette.inlineCodeBackground, palette: palette,
                        context: context)
                case .tagPill:
                    drawPill(
                        in: rect, fill: palette.tagBackground, palette: palette, context: context)
                }
            }
        }
    }

    /// Draws a checkbox centred on the `[ ]` it stands in for.
    ///
    /// The literal characters stay in the buffer — that is what keeps ⌘C
    /// copying real Markdown — but the styler paints them clear, so this is
    /// what the reader actually sees. Sizing it from the marker's own rect is
    /// what keeps it on the baseline at any body font size.
    private func drawCheckbox(
        in rect: CGRect,
        checked: Bool,
        palette: BlockDecorationPalette,
        context: CGContext
    ) {
        let side = min(Metrics.checkboxSide, rect.height)
        let box = CGRect(
            x: rect.minX + max(0, (rect.width - side) / 2),
            y: rect.midY - side / 2,
            width: side,
            height: side)

        context.saveGState()
        defer { context.restoreGState() }

        let path = CGPath(
            roundedRect: box.insetBy(dx: 0.5, dy: 0.5),
            cornerWidth: Metrics.checkboxRadius,
            cornerHeight: Metrics.checkboxRadius,
            transform: nil)

        if checked {
            context.addPath(path)
            context.setFillColor(palette.accentColor)
            context.fillPath()

            context.setStrokeColor(palette.checkmarkColor)
            context.setLineWidth(1.8)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.move(to: CGPoint(x: box.minX + side * 0.26, y: box.minY + side * 0.52))
            context.addLine(to: CGPoint(x: box.minX + side * 0.44, y: box.minY + side * 0.71))
            context.addLine(to: CGPoint(x: box.minX + side * 0.76, y: box.minY + side * 0.31))
            context.strokePath()
        } else {
            context.addPath(path)
            context.setStrokeColor(palette.secondaryColor.copy(alpha: 0.55) ?? palette.secondaryColor)
            context.setLineWidth(1.2)
            context.strokePath()
        }
    }

    /// Draws a rounded pill behind an inline run.
    ///
    /// A pill rather than the flat `.backgroundColor` attribute AppKit would
    /// otherwise paint: that one is a square box hugging the glyphs with no
    /// breathing room, which is what makes inline code look pasted in.
    private func drawPill(
        in rect: CGRect,
        fill: CGColor,
        palette: BlockDecorationPalette,
        context: CGContext
    ) {
        let box = rect.insetBy(dx: -Metrics.pillPadding, dy: -Metrics.pillInset)
        guard box.width > 0, box.height > 0 else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.addPath(
            CGPath(
                roundedRect: box,
                cornerWidth: min(Metrics.pillRadius, box.height / 2),
                cornerHeight: min(Metrics.pillRadius, box.height / 2),
                transform: nil))
        context.setFillColor(fill)
        context.fillPath()
    }

    // MARK: - Geometry

    /// The rects a document range occupies, in fragment-local coordinates.
    ///
    /// Read off this fragment's own line fragments rather than by asking the
    /// layout manager to enumerate text segments: that call can re-enter
    /// layout, and this runs inside `draw`. A wrapped paragraph yields one
    /// rect per line the range crosses.
    private func rects(for range: NSRange) -> [CGRect] {
        guard documentRange.length > 0, range.length > 0 else { return [] }
        let start = range.location - documentRange.location
        let end = start + range.length
        guard end > 0, start < documentRange.length else { return [] }

        var out: [CGRect] = []
        for line in textLineFragments {
            let lineRange = line.characterRange
            let lineStart = lineRange.location
            let lineEnd = lineRange.location + lineRange.length
            let from = max(start, lineStart)
            let to = min(end, lineEnd)
            guard to > from else { continue }

            let bounds = line.typographicBounds
            let x0 = line.locationForCharacter(at: from - lineStart).x
            let x1 = line.locationForCharacter(at: to - lineStart).x
            guard x1 > x0 else { continue }
            out.append(
                CGRect(
                    x: bounds.minX + x0,
                    y: bounds.minY,
                    width: x1 - x0,
                    height: bounds.height))
        }
        return out
    }

    enum Metrics {
        static let blockPadding: CGFloat = 10
        /// Generous enough to read as a card rather than a highlighted
        /// paragraph, which is the whole difference between a code block that
        /// looks designed and one that looks like a background colour.
        static let cornerRadius: CGFloat = 10
        static let barWidth: CGFloat = 3
        /// The panel's own inner padding. The *separation* from the line
        /// above is paragraph spacing on the header row instead — see
        /// `MarkdownStyler.Metrics.tableGap` — because a fragment margin does
        /// not reserve space against a collapsed blank line.
        static let tablePadding: CGFloat = 10
        static let rulePadding: CGFloat = 6
        static let controlSide: CGFloat = 14
        static let controlInset: CGFloat = 3
        static let labelGap: CGFloat = 6
        static let checkboxSide: CGFloat = 14
        static let checkboxRadius: CGFloat = 4
        static let pillPadding: CGFloat = 4
        static let pillInset: CGFloat = -1
        static let pillRadius: CGFloat = 5
        /// How far an ornament may reach past the glyphs it covers, so the
        /// rendering surface is widened enough not to clip it.
        static let ornamentBleed: CGFloat = 6
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
