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

    enum Metrics {
        static let blockPadding: CGFloat = 8
        static let cornerRadius: CGFloat = 6
        static let barWidth: CGFloat = 3
        static let rulePadding: CGFloat = 6
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
