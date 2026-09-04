//
//  HTMLFlowLayout.swift
//  MarkDevKit
//
//  A finished drawing of an HTMLFlow, safe to paint from a layout fragment.
//

import AppKit
import CoreText

/// Pieces of a README HTML fragment, already placed in the column.
///
/// Same bargain as ``TableRowLayout``: TextKit may ask a fragment to draw
/// from anywhere, so this holds `CGImage`s and `CTLine`s rather than a live
/// text system.
struct HTMLFlowLayout: @unchecked Sendable {
    enum Piece {
        case image(CGImage, CGRect)
        case badge(line: CTLine, rect: CGRect, fill: CGColor, ink: CGColor)
        case text(line: CTLine, origin: CGPoint)

        func offset(dx: CGFloat, dy: CGFloat) -> Piece {
            switch self {
            case .image(let image, let rect):
                return .image(image, rect.offsetBy(dx: dx, dy: dy))
            case .badge(let line, let rect, let fill, let ink):
                return .badge(
                    line: line, rect: rect.offsetBy(dx: dx, dy: dy), fill: fill, ink: ink)
            case .text(let line, let origin):
                return .text(
                    line: line, origin: CGPoint(x: origin.x + dx, y: origin.y + dy))
            }
        }
    }

    let pieces: [Piece]
    let height: CGFloat
    /// The one picture a single-image flow drew, so the zoom chip can reuse
    /// the ordinary rendered-content path.
    let primaryImage: RenderedContent?

    enum Metrics {
        static let imageGap: CGFloat = 6
        static let lineGap: CGFloat = 8
        static let badgeHeight: CGFloat = 20
        static let badgePadding: CGFloat = 8
        static let badgeRadius: CGFloat = 4
    }

    /// Lays `flow` out in `columnWidth`, loading local pictures and drawing
    /// remote ones as alt-text chips. Never fetches.
    @MainActor
    static func make(
        flow: HTMLFlow,
        columnWidth: CGFloat,
        directory: URL?,
        theme: EditorTheme,
        ink: NSColor
    ) -> HTMLFlowLayout {
        let column = max(columnWidth, 1)
        let bodyFont = flow.headingLevel.map { theme.headingFont(level: $0) } ?? theme.bodyFont
        let boldFont =
            NSFont(
                descriptor: bodyFont.fontDescriptor.withSymbolicTraits(.bold),
                size: bodyFont.pointSize) ?? .boldSystemFont(ofSize: bodyFont.pointSize)
        let italicFont =
            NSFont(
                descriptor: bodyFont.fontDescriptor.withSymbolicTraits(.italic),
                size: bodyFont.pointSize) ?? bodyFont
        let monoFont = theme.monoFont
        let badgeFont = CTFontCreateUIFontForLanguage(.smallSystem, 11, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, 11, nil)
        let inkColor = ink.cgColor
        let linkColor = theme.linkColor.cgColor
        let badgeFill = theme.secondaryColor.withAlphaComponent(0.14).cgColor
        let badgeInk = theme.secondaryColor.cgColor

        if let rows = flow.rows {
            return layoutTable(
                rows, column: column, directory: directory, theme: theme, ink: ink)
        }

        var pieces: [Piece] = []
        var y: CGFloat = 0
        var primary: RenderedContent?
        var imageCount = 0

        let lines = split(flow.items)
        for (index, line) in lines.enumerated() {
            if index > 0 { y += Metrics.lineGap }
            var images: [HTMLFlow.Image] = []
            var runs: [HTMLFlow.Run] = []
            for item in line {
                switch item {
                case .image(let image): images.append(image)
                case .run(let run): runs.append(run)
                case .lineBreak: break
                }
            }
            if !images.isEmpty {
                let (rowPieces, rowHeight, rowPrimary) = layoutImages(
                    images, at: y, column: column, alignment: flow.alignment,
                    directory: directory, badgeFont: badgeFont, badgeFill: badgeFill,
                    badgeInk: badgeInk)
                pieces.append(contentsOf: rowPieces)
                imageCount += images.count
                if primary == nil { primary = rowPrimary }
                y += rowHeight
            }
            if !runs.isEmpty {
                let (textPieces, textHeight) = layoutText(
                    runs, at: y, column: column, alignment: flow.alignment,
                    bodyFont: bodyFont, boldFont: boldFont, italicFont: italicFont,
                    monoFont: monoFont,
                    ink: inkColor, link: linkColor, lineSpacing: theme.lineSpacing)
                pieces.append(contentsOf: textPieces)
                y += textHeight
            }
        }

        return HTMLFlowLayout(
            pieces: pieces,
            height: max(ceil(y), 0),
            primaryImage: imageCount == 1 ? primary : nil)
    }

    @MainActor
    private static func layoutTable(
        _ rows: [[HTMLFlow]],
        column: CGFloat,
        directory: URL?,
        theme: EditorTheme,
        ink: NSColor
    ) -> HTMLFlowLayout {
        let columns = rows.map(\.count).max() ?? 0
        guard columns > 0 else {
            return HTMLFlowLayout(pieces: [], height: 0, primaryImage: nil)
        }
        let gap = Metrics.imageGap
        let colWidth = max((column - gap * CGFloat(columns - 1)) / CGFloat(columns), 24)
        var pieces: [Piece] = []
        var y: CGFloat = 0
        var imageCount = 0
        var primary: RenderedContent?

        for (index, row) in rows.enumerated() {
            if index > 0 { y += gap }
            var rowHeight: CGFloat = 0
            var rowPieces: [Piece] = []
            for (columnIndex, cell) in row.enumerated() {
                let layout = make(
                    flow: cell, columnWidth: colWidth, directory: directory,
                    theme: theme, ink: ink)
                let x = CGFloat(columnIndex) * (colWidth + gap)
                rowPieces.append(contentsOf: layout.pieces.map { $0.offset(dx: x, dy: y) })
                rowHeight = max(rowHeight, layout.height)
                imageCount += cell.images.count
                if primary == nil { primary = layout.primaryImage }
            }
            pieces.append(contentsOf: rowPieces)
            y += rowHeight
        }
        return HTMLFlowLayout(
            pieces: pieces,
            height: max(ceil(y), 0),
            primaryImage: imageCount == 1 ? primary : nil)
    }

    private static func split(_ items: [HTMLFlow.Item]) -> [[HTMLFlow.Item]] {
        var lines: [[HTMLFlow.Item]] = [[]]
        for item in items {
            if case .lineBreak = item {
                lines.append([])
            } else {
                lines[lines.count - 1].append(item)
            }
        }
        return lines.filter { !$0.isEmpty }
    }

    @MainActor
    private static func layoutImages(
        _ images: [HTMLFlow.Image],
        at top: CGFloat,
        column: CGFloat,
        alignment: HTMLFlow.Alignment,
        directory: URL?,
        badgeFont: CTFont,
        badgeFill: CGColor,
        badgeInk: CGColor
    ) -> (pieces: [Piece], height: CGFloat, primary: RenderedContent?) {
        struct Placed {
            var piece: Piece
            var x: CGFloat
            var y: CGFloat
            var width: CGFloat
            var height: CGFloat
        }

        var placed: [Placed] = []
        var x: CGFloat = 0
        var y = top
        var rowHeight: CGFloat = 0
        var rowStart = 0
        var primary: RenderedContent?

        func flushRow() {
            guard rowStart < placed.count else { return }
            let rowWidth = placed[rowStart...].map(\.width).reduce(0, +)
                + Metrics.imageGap * CGFloat(max(placed.count - rowStart - 1, 0))
            let shift: CGFloat
            switch alignment {
            case .leading: shift = 0
            case .center: shift = max(column - rowWidth, 0) / 2
            case .trailing: shift = max(column - rowWidth, 0)
            }
            if shift > 0 {
                for index in rowStart..<placed.count {
                    placed[index].x += shift
                }
            }
        }

        for image in images {
            let (piece, size, content) = render(
                image, column: column, directory: directory,
                badgeFont: badgeFont, badgeFill: badgeFill, badgeInk: badgeInk)
            if content != nil { primary = content }
            if x > 0, x + size.width > column {
                flushRow()
                y += rowHeight + Metrics.imageGap
                x = 0
                rowHeight = 0
                rowStart = placed.count
            }
            placed.append(
                Placed(piece: piece, x: x, y: y, width: size.width, height: size.height))
            x += size.width + Metrics.imageGap
            rowHeight = max(rowHeight, size.height)
        }
        flushRow()

        let pieces: [Piece] = placed.map { item in
            let rect = CGRect(x: item.x, y: item.y, width: item.width, height: item.height)
            switch item.piece {
            case .image(let image, _): return .image(image, rect)
            case .badge(let line, _, let fill, let ink):
                return .badge(line: line, rect: rect, fill: fill, ink: ink)
            case .text(let line, _):
                return .text(line: line, origin: CGPoint(x: item.x, y: item.y))
            }
        }
        return (pieces, y + rowHeight - top, primary)
    }

    @MainActor
    private static func render(
        _ image: HTMLFlow.Image,
        column: CGFloat,
        directory: URL?,
        badgeFont: CTFont,
        badgeFill: CGColor,
        badgeInk: CGColor
    ) -> (Piece, CGSize, RenderedContent?) {
        let requested: CGFloat? = image.fillsColumn ? column : image.width
        let result = RichContentRenderer.shared.image(
            at: image.source, relativeTo: directory, maxWidth: column, width: requested)
        if case .success(let content) = result, let cgImage = content.cgImage {
            return (.image(cgImage, CGRect(origin: .zero, size: content.size)), content.size, content)
        }
        let label = badgeLabel(for: image)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: badgeFont,
            .foregroundColor: NSColor(cgColor: badgeInk) ?? .secondaryLabelColor,
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: label, attributes: attributes))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let advance = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        let size = CGSize(
            width: ceil(advance) + Metrics.badgePadding * 2,
            height: Metrics.badgeHeight)
        return (
            .badge(line: line, rect: CGRect(origin: .zero, size: size), fill: badgeFill, ink: badgeInk),
            size, nil)
    }

    private static func badgeLabel(for image: HTMLFlow.Image) -> String {
        let alt = image.alt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !alt.isEmpty { return alt }
        if let url = URL(string: image.source), let host = url.host, !host.isEmpty {
            return host
        }
        let name = (image.source as NSString).lastPathComponent
        return name.isEmpty ? "image" : name
    }

    private static func layoutText(
        _ runs: [HTMLFlow.Run],
        at top: CGFloat,
        column: CGFloat,
        alignment: HTMLFlow.Alignment,
        bodyFont: NSFont,
        boldFont: NSFont,
        italicFont: NSFont,
        monoFont: NSFont,
        ink: CGColor,
        link: CGColor,
        lineSpacing: CGFloat
    ) -> (pieces: [Piece], height: CGFloat) {
        let text = NSMutableAttributedString()
        for run in runs {
            let font: NSFont
            if run.mono { font = monoFont }
            else if run.bold { font = boldFont }
            else if run.italic { font = italicFont }
            else { font = bodyFont }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor(cgColor: run.href == nil ? ink : link)
                    ?? (run.href == nil ? .labelColor : .linkColor),
            ]
            if run.href != nil {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            text.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        guard text.length > 0 else { return ([], 0) }

        let typesetter = CTTypesetterCreateWithAttributedString(text)
        var start = 0
        var y = top
        var pieces: [Piece] = []
        let length = text.length

        while start < length {
            var count = CTTypesetterSuggestLineBreak(typesetter, start, Double(column))
            if count <= 0 { count = 1 }
            let range = CFRange(location: start, length: min(count, length - start))
            let line = CTTypesetterCreateLine(typesetter, range)
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let advance = CGFloat(
                CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            let visible = max(advance - CGFloat(CTLineGetTrailingWhitespaceWidth(line)), 0)
            let slack = max(column - visible, 0)
            let x: CGFloat
            switch alignment {
            case .leading: x = 0
            case .center: x = slack / 2
            case .trailing: x = slack
            }
            pieces.append(.text(line: line, origin: CGPoint(x: x, y: y + ascent)))
            y += ascent + descent + leading + lineSpacing
            start = range.location + range.length
        }
        return (pieces, max(y - lineSpacing - top, 0))
    }

    /// Paints the pieces with their top-left at `origin`.
    func draw(in context: CGContext, at origin: CGPoint) {
        for piece in pieces {
            switch piece {
            case .image(let image, let rect):
                let placed = rect.offsetBy(dx: origin.x, dy: origin.y)
                context.saveGState()
                context.translateBy(x: 0, y: placed.midY)
                context.scaleBy(x: 1, y: -1)
                context.translateBy(x: 0, y: -placed.midY)
                context.draw(image, in: placed)
                context.restoreGState()
            case .badge(let line, let rect, let fill, _):
                let placed = rect.offsetBy(dx: origin.x, dy: origin.y)
                context.saveGState()
                context.setFillColor(fill)
                context.addPath(
                    CGPath(
                        roundedRect: placed,
                        cornerWidth: Metrics.badgeRadius,
                        cornerHeight: Metrics.badgeRadius,
                        transform: nil))
                context.fillPath()
                var ascent: CGFloat = 0
                var descent: CGFloat = 0
                _ = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
                context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                context.textPosition = CGPoint(
                    x: placed.minX + Metrics.badgePadding,
                    y: placed.minY + (placed.height + ascent - descent) / 2)
                CTLineDraw(line, context)
                context.restoreGState()
            case .text(let line, let baseline):
                context.saveGState()
                context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                context.textPosition = CGPoint(
                    x: origin.x + baseline.x, y: origin.y + baseline.y)
                CTLineDraw(line, context)
                context.restoreGState()
            }
        }
    }
}
