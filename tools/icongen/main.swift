//
//  main.swift
//  icongen
//
//  Renders app/MarkDev/Assets.xcassets from MarkDevLogo: the app icon, and
//  the badge macOS composes into the Markdown document icon.
//
//  Compiled together with app/MarkDevKit/Brand/MarkDevLogo.swift by
//  `just icons`, so the icon on disk cannot drift from the mark the app
//  draws — there is one geometry, rasterised here and vector-drawn there.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One entry of the macOS icon ladder: logical size and scale.
private struct Slot {
    let size: Int
    let scale: Int

    var pixels: Int { size * scale }
    var filename: String { "icon_\(size)x\(size)\(scale == 1 ? "" : "@\(scale)x").png" }
}

private let slots = [16, 32, 128, 256, 512].flatMap { size in
    [Slot(size: size, scale: 1), Slot(size: size, scale: 2)]
}

private func render(pixels: Int, style: MarkDevLogo.Style) throws -> CGImage {
    guard
        let space = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
            data: nil,
            width: pixels,
            height: pixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else {
        throw Failure("could not create a \(pixels)px bitmap context")
    }

    // MarkDevLogo draws in SwiftUI's y-down space; a bitmap context is y-up.
    context.translateBy(x: 0, y: CGFloat(pixels))
    context.scaleBy(x: 1, y: -1)
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    let size = CGSize(width: CGFloat(pixels), height: CGFloat(pixels))
    MarkDevLogo.draw(in: context, size: size, style: style)

    guard let image = context.makeImage() else {
        throw Failure("could not snapshot the \(pixels)px context")
    }
    return image
}

private func write(_ image: CGImage, to url: URL) throws {
    guard
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        )
    else {
        throw Failure("could not open \(url.lastPathComponent) for writing")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw Failure("could not encode \(url.lastPathComponent)")
    }
}

/// The catalog itself is generated too, so the whole `.xcassets` can be
/// gitignored the way the Xcode project and the plists are.
private let catalogJSON = """
    {
      "info" : {
        "author" : "icongen",
        "version" : 1
      }
    }

    """

private func iconSetJSON() -> String {
    let images = slots.map { slot in
        """
            {
              "filename" : "\(slot.filename)",
              "idiom" : "mac",
              "scale" : "\(slot.scale)x",
              "size" : "\(slot.size)x\(slot.size)"
            }
        """
    }
    return """
        {
          "images" : [
        \(images.joined(separator: ",\n"))
          ],
          "info" : {
            "author" : "icongen",
            "version" : 1
          }
        }

        """
}

private struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// --- Entry point -----------------------------------------------------------

do {
    guard CommandLine.arguments.count == 3 else {
        throw Failure("usage: icongen <Assets.xcassets> <DocumentIcon.iconset>")
    }
    let catalog = URL(fileURLWithPath: CommandLine.arguments[1])
    let iconSet = catalog.appendingPathComponent("AppIcon.appiconset")
    try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)

    for slot in slots {
        try write(
            render(pixels: slot.pixels, style: .app),
            to: iconSet.appendingPathComponent(slot.filename))
    }
    try iconSetJSON().write(
        to: iconSet.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8
    )
    try catalogJSON.write(
        to: catalog.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8
    )

    // The document icon cannot live in the asset catalog: actool only emits an
    // .icns for the app icon, and `CFBundleTypeIconFile` resolves against a
    // real file in Resources. `just icons` runs iconutil over this directory.
    let documentSet = URL(fileURLWithPath: CommandLine.arguments[2])
    try? FileManager.default.removeItem(at: documentSet)
    try FileManager.default.createDirectory(at: documentSet, withIntermediateDirectories: true)
    for slot in slots {
        try write(
            render(pixels: slot.pixels, style: .document),
            to: documentSet.appendingPathComponent(slot.filename))
    }

    print("icongen: wrote \(slots.count) app icons and \(slots.count) document icons")
} catch {
    FileHandle.standardError.write(Data("icongen: \(error)\n".utf8))
    exit(1)
}
