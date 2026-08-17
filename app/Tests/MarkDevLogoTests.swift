//
//  MarkDevLogoTests.swift
//  MarkDevKitTests
//

import CoreGraphics
import XCTest

@testable import MarkDevKit

/// The logo is drawn, not shipped as pixels, so nothing else would notice if
/// the geometry regressed to a blank plate — or if the mark survived at Dock
/// size but vanished at 16pt, where most of a macOS icon's life is spent.
final class MarkDevLogoTests: XCTestCase {
    /// A rendered logo, addressable by pixel.
    private struct Raster {
        let pixels: Int
        let bytes: [UInt8]

        /// Premultiplied-last RGBA at a *fractional* position, so tests can
        /// name a point in the geometry rather than in a specific resolution.
        func sample(_ x: CGFloat, _ y: CGFloat) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
            let px = min(pixels - 1, max(0, Int(x * CGFloat(pixels))))
            let py = min(pixels - 1, max(0, Int(y * CGFloat(pixels))))
            let i = (py * pixels + px) * 4
            return (
                CGFloat(bytes[i]) / 255, CGFloat(bytes[i + 1]) / 255,
                CGFloat(bytes[i + 2]) / 255, CGFloat(bytes[i + 3]) / 255
            )
        }

        /// Fraction of the canvas covered by the lit teal face. The mark is
        /// far greener than the indigo plate, which makes a channel test a
        /// reliable stand-in for "the mark is actually there".
        var markCoverage: CGFloat {
            var count = 0
            for i in stride(from: 0, to: bytes.count, by: 4) where bytes[i + 3] > 200 {
                let r = CGFloat(bytes[i]) / 255
                let g = CGFloat(bytes[i + 1]) / 255
                if g > 0.45 && g > r * 1.3 { count += 1 }
            }
            return CGFloat(count) / CGFloat(pixels * pixels)
        }

        var opaqueCoverage: CGFloat {
            var count = 0
            for i in stride(from: 3, to: bytes.count, by: 4) where bytes[i] > 200 { count += 1 }
            return CGFloat(count) / CGFloat(pixels * pixels)
        }
    }

    private func render(pixels: Int, style: MarkDevLogo.Style) throws -> Raster {
        let bytesPerRow = pixels * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * pixels)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))

        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(
                CGContext(
                    data: buffer.baseAddress,
                    width: pixels,
                    height: pixels,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            )
            // Same flip `tools/icongen` applies: the geometry is authored in
            // SwiftUI's y-down space.
            context.translateBy(x: 0, y: CGFloat(pixels))
            context.scaleBy(x: 1, y: -1)
            MarkDevLogo.draw(
                in: context, size: CGSize(width: pixels, height: pixels), style: style
            )
        }
        return Raster(pixels: pixels, bytes: bytes)
    }

    func testAppStyleLeavesTheIconGridMarginTransparent() throws {
        // macOS expects the artwork inset inside its canvas; a plate bled to
        // the edge sits visibly larger than every neighbour in the Dock.
        let raster = try render(pixels: 512, style: .app)
        XCTAssertEqual(raster.sample(0.01, 0.01).a, 0, accuracy: 0.01)
        XCTAssertEqual(raster.sample(0.99, 0.99).a, 0, accuracy: 0.01)
        XCTAssertGreaterThan(raster.opaqueCoverage, 0.5)
        XCTAssertLessThan(raster.opaqueCoverage, 0.75)
    }

    func testAppStyleDrawsTheMarkOnThePlate() throws {
        let raster = try render(pixels: 512, style: .app)

        // Apex of the chevron: plate-relative (0.5, 0.625), mapped through
        // the icon-grid inset.
        let inset = (1 - 0.8047) / 2
        let apex = raster.sample(0.5, inset + 0.625 * 0.8047)
        XCTAssertGreaterThan(apex.g, 0.45, "the apex of the chevron should be lit teal")
        XCTAssertGreaterThan(apex.g, apex.r * 1.3)

        // Above the chevron is bare plate: dark, opaque, and not teal.
        let plate = raster.sample(0.5, inset + 0.2 * 0.8047)
        XCTAssertEqual(plate.a, 1, accuracy: 0.01)
        XCTAssertLessThan(plate.g, 0.45)

        XCTAssertGreaterThan(raster.markCoverage, 0.03)
    }

    func testExtrusionIsDarkerThanTheFrontFace() throws {
        // The 3D read depends entirely on the swept side being shaded away
        // from the light; if the two ever converge the logo goes flat.
        let raster = try render(pixels: 512, style: .app)
        let inset = (1 - 0.8047) / 2
        func plateSpace(_ x: CGFloat, _ y: CGFloat) -> (CGFloat, CGFloat) {
            (inset + x * 0.8047, inset + y * 0.8047)
        }

        let (fx, fy) = plateSpace(0.70, 0.44)
        let front = raster.sample(fx, fy)
        // Just below and right of the same arm: the extruded side.
        let (sx, sy) = plateSpace(0.745, 0.52)
        let side = raster.sample(sx, sy)

        XCTAssertEqual(front.a, 1, accuracy: 0.01)
        XCTAssertEqual(side.a, 1, accuracy: 0.01)
        XCTAssertGreaterThan(front.g, side.g + 0.15, "front face must read lighter than the side")
    }

    func testMarkSurvivesAtToolbarAndMenuBarSizes() throws {
        // 16pt is where an icon usually fails: geometry expressed in absolute
        // units, or a stroke thinner than a pixel, disappears here first.
        for pixels in [16, 32] {
            let raster = try render(pixels: pixels, style: .app)
            XCTAssertGreaterThan(
                raster.markCoverage, 0.02, "the mark vanished at \(pixels)px"
            )
        }
    }

    func testMarkStyleFillsItsCanvasWithoutAPlate() throws {
        let mark = try render(pixels: 512, style: .mark)
        let app = try render(pixels: 512, style: .app)

        // No plate: the corners stay clear.
        XCTAssertEqual(mark.sample(0.02, 0.02).a, 0, accuracy: 0.01)
        // And the mark is scaled up to use the space the plate freed.
        XCTAssertGreaterThan(mark.markCoverage, app.markCoverage)
    }

    func testDocumentStyleDrawsAFoldedPageCarryingTheMark() throws {
        let raster = try render(pixels: 512, style: .document)

        // Page, not plate: the canvas corners stay clear and the top-right
        // corner is cut away by the fold.
        XCTAssertEqual(raster.sample(0.02, 0.02).a, 0, accuracy: 0.01)
        XCTAssertEqual(
            raster.sample(0.81, 0.10).a, 0, accuracy: 0.01,
            "the folded corner should be cut out of the page")

        // The flap has to be shaded, or the fold reads as a notch.
        let flap = raster.sample(0.70, 0.20)
        let paper = raster.sample(0.30, 0.15)
        XCTAssertEqual(flap.a, 1, accuracy: 0.01)
        XCTAssertEqual(paper.a, 1, accuracy: 0.01)
        XCTAssertGreaterThan(paper.r, flap.r + 0.05)

        // And the page carries the same mark as the app icon.
        XCTAssertGreaterThan(raster.markCoverage, 0.02)
        let centre = raster.sample(0.50, 0.62)
        XCTAssertGreaterThan(centre.g, 0.45)
        XCTAssertGreaterThan(centre.g, centre.r * 1.3)
    }

    func testZeroSizedCanvasDrawsNothing() throws {
        // `Canvas` reports a zero size during layout before its frame settles;
        // the guard in `draw` is what stops that from dividing by zero.
        var bytes = [UInt8](repeating: 0, count: 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(
                CGContext(
                    data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                    bytesPerRow: 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            )
            MarkDevLogo.draw(in: context, size: .zero, style: .app)
        }
        XCTAssertEqual(bytes, [0, 0, 0, 0])
    }
}
