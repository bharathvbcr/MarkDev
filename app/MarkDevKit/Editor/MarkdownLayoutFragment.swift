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
    let note: CGColor
    let tip: CGColor
    let important: CGColor
    let warning: CGColor
    let caution: CGColor
    let accent: CGColor
    /// Contrasts with `accent`, for the tick inside a filled checkbox.
    let checkmark: CGColor

    @MainActor
    init(theme: EditorTheme) {
        codeBackground = theme.codeBackground.cgColor
        quoteColor = theme.quoteColor.cgColor
        secondaryColor = theme.secondaryColor.cgColor
        labelFont = CTFontCreateUIFontForLanguage(.smallSystem, 9, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, 9, nil)
        note = theme.calloutAccent(.note).cgColor
        tip = theme.calloutAccent(.tip).cgColor
        important = theme.calloutAccent(.important).cgColor
        warning = theme.calloutAccent(.warning).cgColor
        caution = theme.calloutAccent(.caution).cgColor
        accent = theme.accentColor.cgColor
        checkmark = theme.checkmarkColor.cgColor
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
    /// Ornaments drawn over inline runs of this fragment's own text.
    var ornaments: [InlineOrnament] = []
    /// This fragment's range in document coordinates, so ornament ranges can
    /// be made local without asking the layout manager mid-draw.
    var documentRange = NSRange(location: 0, length: 0)

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

    /// The area the fragment actually paints.
    ///
    /// Without widening this, the background is clipped to the text's own
    /// bounds and the padding drawn around it is simply not shown. Ornaments
    /// are unioned in too: a checkbox bleeds a point or two past the glyphs it
    /// covers, and a surface sized to the glyphs alone shaves its edges off.
    override var renderingSurfaceBounds: CGRect {
        var bounds = super.renderingSurfaceBounds
        if decoration != .none {
            bounds = bounds.union(decorationRect)
        }
        for ornament in ornaments {
            for rect in rects(for: ornament.range) {
                bounds = bounds.union(
                    rect.insetBy(dx: -Metrics.ornamentBleed, dy: -Metrics.ornamentBleed))
            }
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
        }

        drawOrnaments(in: context, at: point)
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
                }
            }
        }
    }

    /// Draws a checkbox centred on the `- [ ]` it stands in for.
    ///
    /// The literal characters stay in the buffer — that is what keeps ⌘C
    /// copying real Markdown — but the styler paints them clear, so this is
    /// what the reader actually sees. Sizing and centring it within the
    /// marker's *own* rect is what keeps it on the baseline at any body font
    /// size, and what keeps it off the first letter of the item: the box can
    /// only ever occupy space the marker already reserved.
    private func drawCheckbox(
        in rect: CGRect,
        checked: Bool,
        palette: BlockDecorationPalette,
        context: CGContext
    ) {
        let box = Self.checkboxRect(in: rect)
        let side = box.width

        context.saveGState()
        defer { context.restoreGState() }

        let path = CGPath(
            roundedRect: box.insetBy(dx: 0.5, dy: 0.5),
            cornerWidth: Metrics.checkboxRadius,
            cornerHeight: Metrics.checkboxRadius,
            transform: nil)

        if checked {
            context.addPath(path)
            context.setFillColor(palette.accent)
            context.fillPath()

            // A tick, drawn rather than set in a font: a glyph would depend on
            // which symbol font happens to be installed.
            context.setStrokeColor(palette.checkmark)
            context.setLineWidth(1.6)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.move(to: CGPoint(x: box.minX + side * 0.26, y: box.minY + side * 0.52))
            context.addLine(to: CGPoint(x: box.minX + side * 0.44, y: box.minY + side * 0.71))
            context.addLine(to: CGPoint(x: box.minX + side * 0.76, y: box.minY + side * 0.31))
            context.strokePath()
        } else {
            context.addPath(path)
            context.setStrokeColor(
                palette.secondaryColor.copy(alpha: 0.55) ?? palette.secondaryColor)
            context.setLineWidth(1)
            context.strokePath()
        }
    }

    // MARK: - Geometry

    /// The box drawn for a checkbox standing in for the marker at `rect`.
    ///
    /// A pure function of the marker's own rect, and the reason the checkbox
    /// cannot land on the item's text: the side is clamped to the marker's
    /// width as well as its height, so the result is always *contained* by the
    /// characters it replaces. Overlap is not avoided by choosing a good
    /// inset — it is unrepresentable.
    ///
    /// Kept separate from the drawing so the containment property can be
    /// asserted without a graphics context or a laid-out view.
    static func checkboxRect(in rect: CGRect) -> CGRect {
        let side = min(Metrics.checkboxSide, rect.height, rect.width)
        return CGRect(
            x: rect.minX + (rect.width - side) / 2,
            y: rect.midY - side / 2,
            width: side,
            height: side)
    }

    /// The rects a document range occupies, in fragment-local coordinates.
    ///
    /// Read off this fragment's own line fragments rather than by asking the
    /// layout manager to enumerate text segments: that call can re-enter
    /// layout, and this runs inside `draw`. A wrapped paragraph yields one
    /// rect per line the range crosses.
    func rects(for range: NSRange) -> [CGRect] {
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
        static let blockPadding: CGFloat = 8
        static let cornerRadius: CGFloat = 6
        static let barWidth: CGFloat = 3
        static let rulePadding: CGFloat = 6
        static let checkboxSide: CGFloat = 14
        static let checkboxRadius: CGFloat = 4
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
