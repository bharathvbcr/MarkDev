//
//  MarkDevLogo.swift
//  MarkDevKit
//
//  The MarkDev mark, drawn rather than shipped as pixels.
//

import CoreGraphics
import Foundation

/// The MarkDev logo: an extruded Markdown chevron on a squircle plate.
///
/// This is the **single source of truth** for the mark. The app icon PNGs are
/// rendered from this file by `tools/icongen`, and the in-app brand chrome
/// draws it live through `MarkDevLogoView`. There is no second copy in an
/// asset catalog to drift out of sync — regenerate with `just icons`.
///
/// Everything is expressed as a fraction of the canvas, so the same geometry
/// is correct at 16pt in a toolbar and at 1024px in the Dock. The 3D read
/// comes from sweeping the chevron along a depth vector in a darker shade and
/// laying the lit front face on top; that "repeated offset" extrusion always
/// produces the right silhouette, with no visible-edge classification to get
/// wrong.
public enum MarkDevLogo {
    public enum Style: Sendable {
        /// Plate and mark together — the app icon, and the brand chrome.
        case app
        /// The mark alone on transparency, sized to fill its canvas.
        case mark
        /// A page carrying the mark — the Finder icon for a `.md` file.
        ///
        /// macOS will not compose this one for us: `net.daringfireball.markdown`
        /// is owned by the system's own CoreTypes bundle, so a `UTTypeIcons`
        /// declaration from this app registers *inactive* and is never read.
        /// The document icon has to be real artwork attached to the app's
        /// document-type claim.
        case document
    }

    /// Draws the logo centred in `size`, in a **y-down** coordinate space
    /// (top-left origin), matching SwiftUI's `GraphicsContext`. A y-up bitmap
    /// context must flip its CTM before calling — `tools/icongen` does.
    public static func draw(in ctx: CGContext, size: CGSize, style: Style = .app) {
        let side = min(size.width, size.height)
        guard side > 0 else { return }
        let canvas = CGRect(
            x: (size.width - side) / 2,
            y: (size.height - side) / 2,
            width: side,
            height: side
        )

        switch style {
        case .app:
            let plate = canvas.insetBy(dx: side * plateInset, dy: side * plateInset)
            drawPlate(in: ctx, rect: plate)
            drawMark(in: ctx, box: plate)
        case .mark:
            drawMark(in: ctx, box: markBox(fitting: canvas))
        case .document:
            drawPage(in: ctx, canvas: canvas)
        }
    }

    // MARK: - Proportions

    /// macOS icon grid: the artwork occupies ~80% of the canvas, the rest is
    /// the breathing room the Dock and Finder expect around every icon.
    private static let plateInset: CGFloat = (1 - 0.8047) / 2

    /// Chevron centreline, in plate-relative coordinates.
    private static let chevron: [CGPoint] = [
        CGPoint(x: 0.235, y: 0.375),
        CGPoint(x: 0.500, y: 0.625),
        CGPoint(x: 0.765, y: 0.375),
    ]
    private static let strokeWidth: CGFloat = 0.15
    /// Extrusion direction: down and to the right, so the light reads as
    /// coming from the top-left — the same convention as every macOS control.
    private static let depth = CGVector(dx: 0.055, dy: 0.075)

    /// Bounds the finished mark occupies in plate-relative coordinates,
    /// including the round caps and the extrusion.
    private static var markBounds: CGRect {
        let half = strokeWidth / 2
        let minX = chevron.map(\.x).min()! - half
        let maxX = chevron.map(\.x).max()! + half + depth.dx
        let minY = chevron.map(\.y).min()! - half
        let maxY = chevron.map(\.y).max()! + half + depth.dy
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The virtual plate box that makes the plate-less mark fill `canvas`.
    private static func markBox(fitting canvas: CGRect) -> CGRect {
        let bounds = markBounds
        let padding: CGFloat = 0.94
        let scale = min(padding / bounds.width, padding / bounds.height)
        let side = canvas.width * scale
        let centre = CGPoint(x: bounds.midX * side, y: bounds.midY * side)
        return CGRect(
            x: canvas.midX - centre.x,
            y: canvas.midY - centre.y,
            width: side,
            height: side
        )
    }

    // MARK: - Palette

    private static func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    private static var plateTop: CGColor { srgb(0.224, 0.251, 0.431) }
    private static var plateBottom: CGColor { srgb(0.090, 0.102, 0.200) }
    private static var frontTop: CGColor { srgb(0.435, 0.918, 0.839) }
    private static var frontBottom: CGColor { srgb(0.153, 0.710, 0.788) }
    private static var sideNear: CGColor { srgb(0.071, 0.475, 0.561) }
    private static var sideFar: CGColor { srgb(0.031, 0.235, 0.302) }

    private static func gradient(_ from: CGColor, _ to: CGColor) -> CGGradient? {
        CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [from, to] as CFArray,
            locations: [0, 1]
        )
    }

    private static func lerp(_ from: CGColor, _ to: CGColor, _ t: CGFloat) -> CGColor {
        guard let a = from.components, let b = to.components, a.count >= 4, b.count >= 4 else {
            return from
        }
        return srgb(
            a[0] + (b[0] - a[0]) * t,
            a[1] + (b[1] - a[1]) * t,
            a[2] + (b[2] - a[2]) * t,
            a[3] + (b[3] - a[3]) * t
        )
    }

    // MARK: - Plate

    private static func drawPlate(in ctx: CGContext, rect: CGRect) {
        ctx.saveGState()
        ctx.addPath(squircle(in: rect))
        ctx.clip()

        if let base = gradient(plateTop, plateBottom) {
            ctx.drawLinearGradient(
                base,
                start: CGPoint(x: rect.midX, y: rect.minY),
                end: CGPoint(x: rect.midX, y: rect.maxY),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }

        // A soft key light from the top-left, which is what keeps the plate
        // from reading as a flat swatch behind a 3D mark.
        if let glow = gradient(srgb(1, 1, 1, 0.16), srgb(1, 1, 1, 0)) {
            ctx.drawRadialGradient(
                glow,
                startCenter: CGPoint(x: rect.minX + rect.width * 0.28, y: rect.minY + rect.height * 0.20),
                startRadius: 0,
                endCenter: CGPoint(x: rect.minX + rect.width * 0.28, y: rect.minY + rect.height * 0.20),
                endRadius: rect.width * 0.78,
                options: []
            )
        }
        ctx.restoreGState()

        // Rim light along the edge.
        ctx.saveGState()
        let inset = rect.width * 0.005
        ctx.addPath(squircle(in: rect.insetBy(dx: inset, dy: inset)))
        ctx.setStrokeColor(srgb(1, 1, 1, 0.14))
        ctx.setLineWidth(rect.width * 0.009)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// A superellipse rather than a rounded rectangle: circular corners read
    /// as visibly "pinched" next to the system's icons at Dock size.
    private static func squircle(in rect: CGRect, exponent: CGFloat = 5) -> CGPath {
        let path = CGMutablePath()
        let a = rect.width / 2
        let b = rect.height / 2
        let steps = 360
        for i in 0...steps {
            let t = 2 * CGFloat.pi * CGFloat(i) / CGFloat(steps)
            let c = cos(t)
            let s = sin(t)
            let point = CGPoint(
                x: rect.midX + a * copysign(pow(abs(c), 2 / exponent), c),
                y: rect.midY + b * copysign(pow(abs(s), 2 / exponent), s)
            )
            if i == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.closeSubpath()
        return path
    }

    // MARK: - Document page

    /// Page proportions, as fractions of the icon canvas. Portrait and inset,
    /// the way every other document icon in a Finder window is.
    private static let pageSize = CGSize(width: 0.64, height: 0.82)
    /// Size of the turned-down corner, as a fraction of the page width.
    private static let foldSize: CGFloat = 0.26

    private static var paperTop: CGColor { srgb(1, 1, 1) }
    private static var paperBottom: CGColor { srgb(0.925, 0.937, 0.957) }
    private static var paperEdge: CGColor { srgb(0.741, 0.769, 0.812) }
    private static var foldShade: CGColor { srgb(0.831, 0.855, 0.890) }

    private static func drawPage(in ctx: CGContext, canvas: CGRect) {
        let page = CGRect(
            x: canvas.midX - canvas.width * pageSize.width / 2,
            y: canvas.midY - canvas.height * pageSize.height / 2,
            width: canvas.width * pageSize.width,
            height: canvas.height * pageSize.height
        )
        let fold = page.width * foldSize

        // Body, with the top-right corner cut away for the fold.
        let body = CGMutablePath()
        body.move(to: CGPoint(x: page.minX, y: page.minY))
        body.addLine(to: CGPoint(x: page.maxX - fold, y: page.minY))
        body.addLine(to: CGPoint(x: page.maxX, y: page.minY + fold))
        body.addLine(to: CGPoint(x: page.maxX, y: page.maxY))
        body.addLine(to: CGPoint(x: page.minX, y: page.maxY))
        body.closeSubpath()

        ctx.saveGState()
        ctx.addPath(body)
        ctx.clip()
        if let paper = gradient(paperTop, paperBottom) {
            ctx.drawLinearGradient(
                paper,
                start: CGPoint(x: page.midX, y: page.minY),
                end: CGPoint(x: page.midX, y: page.maxY),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }
        ctx.restoreGState()

        // The turned-down corner, shaded so the fold reads as a fold rather
        // than a notch cut out of the page.
        let flap = CGMutablePath()
        flap.move(to: CGPoint(x: page.maxX - fold, y: page.minY))
        flap.addLine(to: CGPoint(x: page.maxX, y: page.minY + fold))
        flap.addLine(to: CGPoint(x: page.maxX - fold, y: page.minY + fold))
        flap.closeSubpath()
        ctx.addPath(flap)
        ctx.setFillColor(foldShade)
        ctx.fillPath()

        // Hairline edge. Scaled to the canvas so it stays a hairline at every
        // size instead of vanishing at 16pt or turning into a frame at 512.
        ctx.addPath(body)
        ctx.setStrokeColor(paperEdge)
        ctx.setLineWidth(max(canvas.width * 0.006, 0.75))
        ctx.strokePath()

        // The mark, sitting in the lower two-thirds where a document icon's
        // format badge belongs.
        let markArea = CGRect(
            x: page.minX + page.width * 0.16,
            y: page.minY + page.height * 0.36,
            width: page.width * 0.68,
            height: page.height * 0.44
        )
        drawMark(in: ctx, box: markBox(fitting: markArea))
    }

    // MARK: - Mark

    private static func drawMark(in ctx: CGContext, box: CGRect) {
        let path = chevronPath(in: box)
        let lineWidth = box.width * strokeWidth
        let offset = CGVector(dx: box.width * depth.dx, dy: box.height * depth.dy)

        // One step per ~0.35px keeps the swept solid seamless; the bounds stop
        // a large canvas from turning into thousands of stroke passes.
        let span = max(abs(offset.dx), abs(offset.dy))
        let steps = min(400, max(12, Int((span / 0.35).rounded(.up))))

        for i in stride(from: steps, through: 1, by: -1) {
            let t = CGFloat(i) / CGFloat(steps)
            ctx.saveGState()
            ctx.translateBy(x: offset.dx * t, y: offset.dy * t)
            ctx.addPath(path)
            applyStroke(ctx, width: lineWidth)
            ctx.setStrokeColor(lerp(sideNear, sideFar, t))
            ctx.strokePath()
            ctx.restoreGState()
        }

        // Lit front face.
        let face = markBounds
        let top = box.minY + face.minY * box.height
        let height = face.height * box.height

        ctx.saveGState()
        ctx.addPath(path)
        applyStroke(ctx, width: lineWidth)
        ctx.replacePathWithStrokedPath()
        ctx.clip()

        if let front = gradient(frontTop, frontBottom) {
            ctx.drawLinearGradient(
                front,
                start: CGPoint(x: box.minX, y: top),
                end: CGPoint(x: box.maxX, y: top + height),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }
        if let specular = gradient(srgb(1, 1, 1, 0.38), srgb(1, 1, 1, 0)) {
            ctx.drawLinearGradient(
                specular,
                start: CGPoint(x: box.midX, y: top),
                end: CGPoint(x: box.midX, y: top + height * 0.55),
                options: []
            )
        }
        ctx.restoreGState()
    }

    private static func applyStroke(_ ctx: CGContext, width: CGFloat) {
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
    }

    private static func chevronPath(in box: CGRect) -> CGPath {
        let path = CGMutablePath()
        for (index, point) in chevron.enumerated() {
            let mapped = CGPoint(
                x: box.minX + point.x * box.width,
                y: box.minY + point.y * box.height
            )
            if index == 0 {
                path.move(to: mapped)
            } else {
                path.addLine(to: mapped)
            }
        }
        return path
    }
}
