import AppKit
import XCTest

/// Explicit raster scale lets tests exercise hosted 1x and local Retina displays.
@MainActor
enum RenderingTestBitmap {
    static func capture(_ view: NSView, scale: CGFloat) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width * scale),
            pixelsHigh: Int(view.bounds.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// RGB alone cannot distinguish opaque black ink from transparent black.
    static func differs(_ sample: NSColor, from background: NSColor) -> Bool {
        abs(sample.redComponent - background.redComponent) > 0.01
            || abs(sample.greenComponent - background.greenComponent) > 0.01
            || abs(sample.blueComponent - background.blueComponent) > 0.01
            || abs(sample.alphaComponent - background.alphaComponent) > 0.01
    }

    static func inkedPixels(_ rep: NSBitmapImageRep) -> Int {
        guard let background = rep.colorAt(x: 2, y: 2)?.usingColorSpace(.deviceRGB) else {
            return 0
        }
        var count = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let sample = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                if differs(sample, from: background) { count += 1 }
            }
        }
        return count
    }

}
