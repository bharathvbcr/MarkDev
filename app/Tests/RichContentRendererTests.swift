//
//  RichContentRendererTests.swift
//  MarkDevKitTests
//
//  Math, diagrams, and images — including the failure paths, which are the
//  ones a reader actually notices when they go wrong.
//

import AppKit
import Darwin
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import MarkDevKit

private func restoreExactRendererFixtureModificationTime(
    of file: URL,
    to generation: MarkDevKit.BoundedRegularFileGeneration
) throws {
    let outcome = file.withUnsafeFileSystemRepresentation {
        path -> (result: Int32, failureCode: Int32) in
        guard let path else { return (-1, EINVAL) }
        var times = [
            timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
            timespec(
                tv_sec: Int(generation.modifiedSeconds),
                tv_nsec: Int(generation.modifiedNanoseconds)),
        ]
        let result = times.withUnsafeBufferPointer { buffer in
            Darwin.utimensat(AT_FDCWD, path, buffer.baseAddress, 0)
        }
        return (result, result == 0 ? 0 : errno)
    }
    guard outcome.result == 0 else {
        throw XCTSkip(
            "this filesystem cannot restore an exact nanosecond mtime "
                + "(utimensat errno \(outcome.failureCode))")
    }
}

private func assertOnlyRendererFixtureChangeTimeDiffers(
    before: MarkDevKit.BoundedRegularFileGeneration,
    after: MarkDevKit.BoundedRegularFileGeneration,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    let stableInvariantsMatch =
        before.device == after.device
        && before.inode == after.inode
        && before.fileGeneration == after.fileGeneration
        && before.birthSeconds == after.birthSeconds
        && before.birthNanoseconds == after.birthNanoseconds
        && before.size == after.size
        && before.linkCount == after.linkCount
        && before.mode == after.mode
        && before.ownerID == after.ownerID
        && before.groupID == after.groupID
        && before.flags == after.flags
    XCTAssertEqual(before.device, after.device, file: file, line: line)
    XCTAssertEqual(before.inode, after.inode, file: file, line: line)
    XCTAssertEqual(before.fileGeneration, after.fileGeneration, file: file, line: line)
    XCTAssertEqual(before.birthSeconds, after.birthSeconds, file: file, line: line)
    XCTAssertEqual(before.birthNanoseconds, after.birthNanoseconds, file: file, line: line)
    XCTAssertEqual(before.size, after.size, file: file, line: line)
    XCTAssertEqual(before.linkCount, after.linkCount, file: file, line: line)
    XCTAssertEqual(before.mode, after.mode, file: file, line: line)
    XCTAssertEqual(before.ownerID, after.ownerID, file: file, line: line)
    XCTAssertEqual(before.groupID, after.groupID, file: file, line: line)
    XCTAssertEqual(before.flags, after.flags, file: file, line: line)
    guard stableInvariantsMatch else { return }

    guard before.modifiedSeconds == after.modifiedSeconds,
        before.modifiedNanoseconds == after.modifiedNanoseconds
    else {
        throw XCTSkip(
            "this filesystem did not restore mtime exactly: "
                + "expected \(before.modifiedSeconds).\(before.modifiedNanoseconds), "
                + "observed \(after.modifiedSeconds).\(after.modifiedNanoseconds)")
    }

    guard before.changedSeconds != after.changedSeconds
        || before.changedNanoseconds != after.changedNanoseconds
    else {
        throw XCTSkip(
            "this filesystem's change-time resolution did not expose the in-place rewrite")
    }
}

@MainActor
final class RichContentRendererTests: XCTestCase {
    private func makeRenderer() -> RichContentRenderer { RichContentRenderer() }

    private var adversarialBackingScales: [(name: String, value: CGFloat)] {
        [
            ("greatest finite", .greatestFiniteMagnitude),
            ("very large finite", CGFloat(1e300)),
            ("least positive", .leastNonzeroMagnitude),
            ("zero", 0),
            ("negative", -1),
        ]
    }

    /// A hostile scale may be declined, but it must never escape as invalid
    /// geometry or as an unbounded bitmap. In particular, converting NaN or an
    /// out-of-range floating-point product to `Int` traps before XCTest can
    /// report an ordinary assertion failure.
    private func assertBoundedRender(
        _ result: Result<RenderedContent, RenderFailure>,
        _ context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch result {
        case .success(let content):
            XCTAssertTrue(content.size.width.isFinite, context, file: file, line: line)
            XCTAssertTrue(content.size.height.isFinite, context, file: file, line: line)
            XCTAssertGreaterThan(content.size.width, 0, context, file: file, line: line)
            XCTAssertGreaterThan(content.size.height, 0, context, file: file, line: line)
            XCTAssertLessThanOrEqual(content.size.width, 20_000, context, file: file, line: line)
            XCTAssertLessThanOrEqual(content.size.height, 20_000, context, file: file, line: line)

            guard let bitmap = content.cgImage else {
                return XCTFail("\(context): success had no bitmap", file: file, line: line)
            }
            let (pixels, overflow) = bitmap.width.multipliedReportingOverflow(by: bitmap.height)
            XCTAssertFalse(overflow, context, file: file, line: line)
            XCTAssertGreaterThan(bitmap.width, 0, context, file: file, line: line)
            XCTAssertGreaterThan(bitmap.height, 0, context, file: file, line: line)
            XCTAssertLessThanOrEqual(
                pixels,
                17_000_000,
                "\(context): \(bitmap.width)x\(bitmap.height) escaped the raster bound",
                file: file,
                line: line)
        case .failure(let failure):
            XCTAssertFalse(
                failure.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "\(context): a refused scale must fail clearly",
                file: file,
                line: line)
        }
    }

    /// A deterministic PNG whose physical pixels and logical AppKit size are
    /// controlled independently. `NSImage.lockFocus()` inherits the test
    /// process's backing scale, which made cache-identity tests accidentally
    /// depend on the screen they ran on.
    private func png(
        pixelWidth: Int,
        pixelHeight: Int,
        pointSize: CGSize? = nil,
        orientation: CGImagePropertyOrientation = .up,
        red: CGFloat = 0.15,
        green: CGFloat = 0.45,
        blue: CGFloat = 0.85
    ) throws -> Data {
        try encodedRaster(
            type: .png,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            bitsPerComponent: 8,
            pointSize: pointSize,
            orientation: orientation,
            red: red,
            green: green,
            blue: blue)
    }

    private func encodedRaster(
        type: UTType,
        pixelWidth: Int,
        pixelHeight: Int,
        bitsPerComponent: Int,
        floatingPoint: Bool = false,
        pointSize: CGSize? = nil,
        orientation: CGImagePropertyOrientation = .up,
        red: CGFloat = 0.15,
        green: CGFloat = 0.45,
        blue: CGFloat = 0.85
    ) throws -> Data {
        let componentOrder: CGBitmapInfo
        switch (bitsPerComponent, floatingPoint) {
        case (8, false):
            componentOrder = .byteOrder32Big
        case (16, false):
            componentOrder = .byteOrder16Big
        case (32, true):
            componentOrder = [.byteOrder32Little, .floatComponents]
        default:
            throw RenderFailure(reason: "unsupported raster fixture storage")
        }
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: bitsPerComponent,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | componentOrder.rawValue))
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(
            CGRect(x: 0, y: 0, width: CGFloat(pixelWidth), height: CGFloat(pixelHeight)))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(
                output, type.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation.rawValue
        ]
        if let pointSize {
            properties[kCGImagePropertyDPIWidth] = CGFloat(pixelWidth) * 72 / pointSize.width
            properties[kCGImagePropertyDPIHeight] = CGFloat(pixelHeight) * 72 / pointSize.height
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw RenderFailure(reason: "could not encode a raster fixture")
        }
        return output as Data
    }

    /// A lossless, non-symmetric 3x2 colour grid carrying only an EXIF
    /// orientation change. Cell centres remain solid through ImageIO, so the
    /// test can distinguish all mirrors and rotations without comparing a
    /// renderer against another invocation of itself.
    private func orientationPNG(_ orientation: CGImagePropertyOrientation) throws -> Data {
        let cell = 30
        let columns = 3
        let rows = 2
        let colours: [(CGFloat, CGFloat, CGFloat)] = [
            (1, 0, 0), (0, 1, 0), (0, 0, 1),
            (0, 1, 1), (1, 0, 1), (1, 1, 0),
        ]
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: columns * cell,
                height: rows * cell,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue))
        for (index, colour) in colours.enumerated() {
            context.setFillColor(red: colour.0, green: colour.1, blue: colour.2, alpha: 1)
            context.fill(
                CGRect(
                    x: CGFloat((index % columns) * cell),
                    y: CGFloat((index / columns) * cell),
                    width: CGFloat(cell),
                    height: CGFloat(cell)))
        }
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(
                output,
                UTType.png.identifier as CFString,
                1,
                nil))
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImagePropertyOrientation: orientation.rawValue] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw RenderFailure(reason: "could not encode orientation fixture")
        }
        return output as Data
    }

    /// Classifies the colour at each cell centre, returning rows top-to-bottom.
    private func orientationSignature(
        of image: CGImage,
        columns: Int,
        rows: Int
    ) throws -> [[Int]] {
        let colours: [(Int, Int, Int)] = [
            (255, 0, 0), (0, 255, 0), (0, 0, 255),
            (0, 255, 255), (255, 0, 255), (255, 255, 0),
        ]
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let bytesPerRow = image.width * 4
        try pixels.withUnsafeMutableBytes { raw in
            let context = try XCTUnwrap(
                CGContext(
                    data: raw.baseAddress,
                    width: image.width,
                    height: image.height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue))
            // A bitmap context stores the first memory row as the displayed
            // top row when a CGImage is drawn into its full bounds. Applying
            // AppKit's usual view-space flip here reflects the sampled image
            // and swaps EXIF transforms 5/7 and 6/8.
            context.draw(
                image,
                in: CGRect(
                    x: 0,
                    y: 0,
                    width: CGFloat(image.width),
                    height: CGFloat(image.height)))
        }

        return (0..<rows).map { row in
            (0..<columns).map { column in
                let x = min(image.width - 1, (2 * column + 1) * image.width / (2 * columns))
                let y = min(image.height - 1, (2 * row + 1) * image.height / (2 * rows))
                let offset = y * bytesPerRow + x * 4
                let sample = (
                    Int(pixels[offset]),
                    Int(pixels[offset + 1]),
                    Int(pixels[offset + 2]))
                return colours.enumerated().min { lhs, rhs in
                    func distance(_ colour: (Int, Int, Int)) -> Int {
                        let red = sample.0 - colour.0
                        let green = sample.1 - colour.1
                        let blue = sample.2 - colour.2
                        return red * red + green * green + blue * blue
                    }
                    return distance(lhs.element) < distance(rhs.element)
                }?.offset ?? -1
            }
        }
    }

    /// EXIF 1...8 transformed into the specification's top-first display
    /// matrix. These are explicit index maps, independent of ImageIO.
    private func orientedSignature(
        _ source: [[Int]],
        orientation: CGImagePropertyOrientation
    ) -> [[Int]] {
        let rowCount = source.count
        let columnCount = source[0].count
        switch orientation {
        case .up:
            return source
        case .upMirrored:
            return source.map { Array($0.reversed()) }
        case .down:
            return source.reversed().map { Array($0.reversed()) }
        case .downMirrored:
            return Array(source.reversed())
        case .leftMirrored:
            return (0..<columnCount).map { column in
                (0..<rowCount).map { row in source[row][column] }
            }
        case .right:
            return (0..<columnCount).map { row in
                (0..<rowCount).map { column in source[rowCount - 1 - column][row] }
            }
        case .rightMirrored:
            return (0..<columnCount).map { row in
                (0..<rowCount).map { column in
                    source[rowCount - 1 - column][columnCount - 1 - row]
                }
            }
        case .left:
            return (0..<columnCount).map { row in
                (0..<rowCount).map { column in source[column][columnCount - 1 - row] }
            }
        @unknown default:
            return []
        }
    }

    /// Removes one complete, independently checksummed PNG chunk. ImageIO's
    /// writer records DPI in both `pHYs` and `eXIf`; removing `eXIf` leaves a
    /// valid non-square-pixel fixture whose thumbnail dimensions are changed
    /// by `kCGImageSourceCreateThumbnailWithTransform`.
    private func removingPNGChunk(named name: String, from data: Data) throws -> Data {
        let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        guard data.count >= signature.count, Array(data.prefix(signature.count)) == signature else {
            throw RenderFailure(reason: "not a PNG")
        }

        func bigEndianUInt32(at offset: Int) throws -> UInt32 {
            guard offset >= 0, offset <= data.count - MemoryLayout<UInt32>.size else {
                throw RenderFailure(reason: "truncated PNG")
            }
            return data[offset..<(offset + MemoryLayout<UInt32>.size)].reduce(0) {
                ($0 << 8) | UInt32($1)
            }
        }

        var output = Data(data.prefix(signature.count))
        var offset = signature.count
        while offset < data.count {
            let length = Int(try bigEndianUInt32(at: offset))
            let (chunkBytes, lengthOverflow) = length.addingReportingOverflow(12)
            let (chunkEnd, endOverflow) = offset.addingReportingOverflow(chunkBytes)
            guard !lengthOverflow, !endOverflow, chunkEnd <= data.count else {
                throw RenderFailure(reason: "truncated PNG chunk")
            }
            let type = String(
                decoding: data[(offset + 4)..<(offset + 8)],
                as: UTF8.self)
            if type != name { output.append(data[offset..<chunkEnd]) }
            offset = chunkEnd
        }
        return output
    }

    private func imageDirectory(prefix: String = "MarkDevImages") throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    // MARK: - Math

    func testASimpleFormulaTypesets() {
        let renderer = makeRenderer()
        let result = renderer.math(
            "E = mc^2", fontSize: 16, color: .labelColor, display: true)

        switch result {
        case .success(let content):
            XCTAssertGreaterThan(content.size.width, 0)
            XCTAssertGreaterThan(content.size.height, 0)
        case .failure(let failure):
            XCTFail("a valid formula should typeset: \(failure.reason)")
        }
    }

    func testOversizedMathIsRejectedWithoutCanonicalizingOrRetainingItsSource() {
        let renderer = makeRenderer()

        // Ordinary bounded failures remain worth caching: they otherwise put a
        // failing SwiftMath parse back on every layout pass.
        guard case .failure = renderer.math(
            "\\frac{1", fontSize: 16, color: .labelColor, display: true)
        else { return XCTFail("the bounded control formula should fail") }
        XCTAssertEqual(renderer.cacheInventoryForTesting.failures, 1)

        // Every source contains a spelling the canonicalizer rewrites. The byte
        // admission check must win before that Character-array pass, before key
        // construction, and before attacker-sized strings can churn the bounded
        // cache and evict the useful control failure above.
        let rewritingPayload = String(repeating: "\\varnothing", count: 750)
        XCTAssertGreaterThan(rewritingPayload.utf8.count, 8_192)
        for index in 0..<140 {
            guard case .failure(let failure) = renderer.math(
                rewritingPayload + "_{\(index)}",
                fontSize: 16,
                color: .labelColor,
                display: true)
            else { return XCTFail("oversized formula \(index) should be refused") }
            XCTAssertTrue(failure.reason.contains("Formula too long"), failure.reason)
        }

        XCTAssertEqual(renderer.cacheInventoryForTesting.successes, 0)
        XCTAssertEqual(
            renderer.cacheInventoryForTesting.failures,
            1,
            "oversized formulas must not retain their source or evict bounded failures")
    }

    func testExtremeBackingScalesNeverTrapOrEscapeMathRasterBounds() {
        for scale in adversarialBackingScales {
            let result = makeRenderer().math(
                "\\sum_{i=0}^{64} \\frac{i^2 + 1}{i + 1}",
                fontSize: 18,
                color: .labelColor,
                display: true,
                maxWidth: 500,
                scale: scale.value)
            assertBoundedRender(result, "math at \(scale.name) scale")
        }
    }

    func testAComplexFormulaTypesets() {
        let renderer = makeRenderer()
        let latex = "\\int_{0}^{\\infty} \\frac{x^3}{e^x - 1} dx = \\frac{\\pi^4}{15}"
        guard case .success(let content) = renderer.math(
            latex, fontSize: 16, color: .labelColor, display: true)
        else { return XCTFail("integral should typeset") }

        // A real formula is wider than a single glyph; a near-zero width would
        // mean it silently rendered nothing.
        XCTAssertGreaterThan(content.size.width, 40)
    }

    func testInvalidLatexReportsAFailureRatherThanRenderingNothing() {
        // A blank gap where a formula should be gives the reader no idea
        // whether the app failed or the formula is wrong.
        let renderer = makeRenderer()
        let result = renderer.math(
            "\\frac{1", fontSize: 16, color: .labelColor, display: false)

        guard case .failure(let failure) = result else {
            return XCTFail("unbalanced braces should fail")
        }
        XCTAssertFalse(failure.reason.isEmpty, "a failure must say why")
    }

    func testDisplayAndInlineMathDifferAndAreCachedSeparately() {
        let renderer = makeRenderer()
        guard case .success(let display) = renderer.math(
            "\\sum_{i=0}^{n} i", fontSize: 16, color: .labelColor, display: true),
            case .success(let inline) = renderer.math(
                "\\sum_{i=0}^{n} i", fontSize: 16, color: .labelColor, display: false)
        else { return XCTFail("both styles should typeset") }

        // Display style sets limits above and below, so it is taller.
        XCTAssertNotEqual(display.size.height, inline.size.height, accuracy: 0.5)
    }

    func testFractionalMathBackingScalesDoNotCollideInEitherOrder() throws {
        let scales: [CGFloat] = [1.01, 1.09]
        let source = "\\sum_{i=0}^{128} \\frac{i^3 + 7i}{i + 1}"

        func bitmapSize(using renderer: RichContentRenderer, scale: CGFloat) throws -> CGSize {
            guard case .success(let content) = renderer.math(
                source,
                fontSize: 20,
                color: .labelColor,
                display: true,
                scale: scale)
            else { throw RenderFailure(reason: "formula should typeset") }
            let bitmap = try XCTUnwrap(content.cgImage)
            return CGSize(width: CGFloat(bitmap.width), height: CGFloat(bitmap.height))
        }

        let expected = try scales.map { scale in
            try bitmapSize(using: RichContentRenderer(), scale: scale)
        }
        XCTAssertNotEqual(
            expected[0], expected[1],
            "the fixture must rasterise differently at the two fractional scales")

        for order in [scales, Array(scales.reversed())] {
            let renderer = RichContentRenderer()
            for scale in order {
                let index = try XCTUnwrap(scales.firstIndex(of: scale))
                XCTAssertEqual(try bitmapSize(using: renderer, scale: scale), expected[index])
            }
            XCTAssertEqual(
                renderer.cacheInventoryForTesting.successes,
                2,
                "fractional scales that render different bitmaps need distinct cache entries")
        }
    }

    // MARK: - Diagrams

    func testAFlowchartRenders() {
        let renderer = makeRenderer()
        let source = "graph TD;\n  A[Start] --> B[Middle];\n  B --> C[End];"
        switch renderer.diagram(source, maxWidth: 400, dark: true) {
        case .success(let content):
            XCTAssertGreaterThan(content.size.width, 0)
            XCTAssertGreaterThan(content.size.height, 0)
        case .failure(let failure):
            XCTFail("a flowchart should render: \(failure.reason)")
        }
    }

    func testASequenceDiagramRenders() {
        let renderer = makeRenderer()
        let source = """
            sequenceDiagram
              Alice->>Bob: Hello
              Bob-->>Alice: Hi
            """
        guard case .success = renderer.diagram(source, maxWidth: 400, dark: true) else {
            return XCTFail("a sequence diagram should render")
        }
    }

    func testWideDiagramsAreScaledToFitRatherThanClipped() {
        // A diagram cut off at the column edge is worse than a smaller
        // readable one.
        let renderer = makeRenderer()
        let source = "graph LR;\n" + (0..<12).map { "  N\($0) --> N\($0 + 1);" }.joined(separator: "\n")

        guard case .success(let content) = renderer.diagram(source, maxWidth: 300, dark: true)
        else { return XCTFail("a wide flowchart should render") }
        XCTAssertLessThanOrEqual(content.size.width, 300.5)
    }

    func testFractionalDiagramBackingScalesDoNotCollideInEitherOrder() throws {
        let scales: [CGFloat] = [1.01, 1.09]
        let source = "graph LR; A[One] --> B[Two]; B --> C[Three]; C --> D[Four];"

        func bitmapSize(using renderer: RichContentRenderer, scale: CGFloat) throws -> CGSize {
            guard case .success(let content) = renderer.diagram(
                source,
                maxWidth: 500,
                dark: false,
                scale: scale)
            else { throw RenderFailure(reason: "diagram should render") }
            let bitmap = try XCTUnwrap(content.cgImage)
            return CGSize(width: CGFloat(bitmap.width), height: CGFloat(bitmap.height))
        }

        let expected = try scales.map { scale in
            try bitmapSize(using: RichContentRenderer(), scale: scale)
        }
        XCTAssertNotEqual(
            expected[0], expected[1],
            "the fixture must rasterise differently at the two fractional scales")

        for order in [scales, Array(scales.reversed())] {
            let renderer = RichContentRenderer()
            for scale in order {
                let index = try XCTUnwrap(scales.firstIndex(of: scale))
                XCTAssertEqual(try bitmapSize(using: renderer, scale: scale), expected[index])
            }
            XCTAssertEqual(
                renderer.cacheInventoryForTesting.successes,
                2,
                "fractional scales that render different bitmaps need distinct cache entries")
        }
    }

    func testExtremeBackingScalesNeverTrapOrEscapeDiagramRasterBounds() {
        let source = "graph LR; A[One] --> B[Two]; B --> C[Three];"
        for scale in adversarialBackingScales {
            let result = makeRenderer().diagram(
                source,
                maxWidth: 500,
                dark: false,
                scale: scale.value)
            assertBoundedRender(result, "diagram at \(scale.name) scale")
        }
    }

    func testOversizedDiagramIsRejectedWithoutRetainingItsSource() {
        let renderer = makeRenderer()
        let oversized = "not-a-diagram\n" + String(repeating: "x", count: 65_536)
        XCTAssertGreaterThan(oversized.utf8.count, 65_536)

        guard case .failure(let failure) = renderer.diagram(
            oversized, maxWidth: 500, dark: false)
        else { return XCTFail("an attacker-sized diagram should be refused") }

        XCTAssertTrue(failure.reason.contains("Diagram too long"), failure.reason)
        XCTAssertEqual(
            renderer.cacheInventoryForTesting.failures,
            0,
            "an attacker-sized diagram must not be retained as a failure-cache key")
    }

    func testAnUnsupportedDiagramTypeExplainsItself() {
        // Gantt is outside the library's supported set. It must say so rather
        // than render blank — the reader cannot otherwise tell the difference
        // between unsupported and broken.
        let renderer = makeRenderer()
        let source = "gantt\n  title A Gantt Diagram\n  section S\n  Task :a1, 2024-01-01, 30d"

        if case .failure(let failure) = renderer.diagram(source, maxWidth: 400, dark: true) {
            XCTAssertFalse(failure.reason.isEmpty, "an unsupported type must say why")
        }
        // A future library version may add gantt; either outcome is correct
        // so long as it is not a silent blank, which the size check covers.
    }

    func testGibberishDiagramsFailCleanly() {
        let renderer = makeRenderer()
        guard case .failure = renderer.diagram("!!! not a diagram !!!", maxWidth: 400, dark: true)
        else { return XCTFail("nonsense should not render as a diagram") }
    }

    // MARK: - Images

    func testALocalImageLoadsAndIsScaledToTheColumn() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevImages-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let image = NSImage(size: CGSize(width: 800, height: 400))
        image.lockFocus()
        NSColor.systemBlue.drawSwatch(in: CGRect(x: 0, y: 0, width: 800, height: 400))
        image.unlockFocus()
        let data = try XCTUnwrap(
            NSBitmapImageRep(data: image.tiffRepresentation ?? Data())?
                .representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent("wide.png"))

        let renderer = makeRenderer()
        guard case .success(let content) = renderer.image(
            at: "wide.png", relativeTo: directory, maxWidth: 400)
        else { return XCTFail("a local image should load") }

        XCTAssertEqual(content.size.width, 400, accuracy: 0.5)
        XCTAssertEqual(content.size.height, 200, accuracy: 1, "aspect ratio should hold")
    }

    func testExtremeBackingScalesCannotPoisonVectorOrRasterRenderRequests() throws {
        let directory = try imageDirectory(prefix: "MarkDevImageBackingScale")
        try circleSVG(size: 64).write(
            to: directory.appendingPathComponent("vector.svg"),
            atomically: true,
            encoding: .utf8)
        try png(pixelWidth: 64, pixelHeight: 32)
            .write(to: directory.appendingPathComponent("raster.png"))

        for source in ["vector.svg", "raster.png"] {
            for scale in adversarialBackingScales {
                let request = RenderRequest(
                    block: RenderedBlock(kind: .image(alt: ""), source: source),
                    directory: directory,
                    context: RenderContext(
                        width: 500,
                        dark: false,
                        mathFontSize: 16,
                        textColor: .labelColor,
                        scale: scale.value))
                assertBoundedRender(
                    makeRenderer().render(request),
                    "\(source) at \(scale.name) scale")
            }
        }
    }

    func testTwoNotesWithTheSameImageNameDoNotShareABitmap() throws {
        // The cache used to be keyed on the reference *as written*, so two
        // notes in different folders that both say `![](picture.png)` collided
        // and the second was served the first one's bitmap. Reading ahead
        // along a note's links turns that from unlucky into routine: it fills
        // the cache from directories other than the open document's.
        let parent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevImageKeys-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }

        func directory(named name: String, imageWidth: Int) throws -> URL {
            let directory = parent.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try png(pixelWidth: imageWidth, pixelHeight: 100)
                .write(to: directory.appendingPathComponent("picture.png"))
            return directory
        }

        let first = try directory(named: "One", imageWidth: 100)
        let second = try directory(named: "Two", imageWidth: 200)

        let renderer = makeRenderer()
        guard case .success(let one) = renderer.image(
            at: "picture.png", relativeTo: first, maxWidth: 400),
            case .success(let two) = renderer.image(
                at: "picture.png", relativeTo: second, maxWidth: 400)
        else { return XCTFail("both images should load") }

        XCTAssertEqual(one.size.width, 100, accuracy: 0.5)
        XCTAssertEqual(
            two.size.width, 200, accuracy: 0.5,
            "the second note's picture, not the first note's under the same name")
    }

    func testTheSameFileReachedTwoWaysIsOneCacheEntry() throws {
        // The flip side of keying on the resolved file: an absolute reference
        // and a relative one naming the same picture must not be two bitmaps.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevImageKeys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("shared.png")
        try png(pixelWidth: 120, pixelHeight: 60).write(to: file)

        let renderer = makeRenderer()
        guard case .success(let relative) = renderer.image(
            at: "shared.png", relativeTo: directory, maxWidth: 400),
            case .success(let absolute) = renderer.image(
                at: file.path, relativeTo: nil, maxWidth: 400)
        else { return XCTFail("both spellings should load") }

        XCTAssertTrue(relative.image === absolute.image, "one file, one bitmap")
    }

    func testRasterLogicalSizeUsesEncodedDPI() throws {
        // 240x120 pixels at 144 DPI are 120x60 AppKit points. Pixel dimensions
        // remain the resource-admission authority; DPI controls only layout.
        let directory = try imageDirectory(prefix: "MarkDevImageDPI")
        try png(
            pixelWidth: 240,
            pixelHeight: 120,
            pointSize: CGSize(width: 120, height: 60)
        ).write(to: directory.appendingPathComponent("retina.png"))

        guard case .success(let content) = makeRenderer().image(
            at: "retina.png", relativeTo: directory, maxWidth: 400)
        else { return XCTFail("a high-DPI PNG should load") }

        XCTAssertEqual(content.size.width, 120, accuracy: 0.5)
        XCTAssertEqual(content.size.height, 60, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(content.cgImage).width, 240)
        XCTAssertEqual(try XCTUnwrap(content.cgImage).height, 120)
    }

    func testHighDepthPNGAndFloatTIFFStayWithinRealizedStorageBound() throws {
        let directory = try imageDirectory(prefix: "MarkDevImageHighDepth")
        let fixtures: [(name: String, type: UTType, depth: Int, floatingPoint: Bool)] = [
            ("sixteen.png", .png, 16, false),
            ("float.tiff", .tiff, 32, true),
        ]

        for fixture in fixtures {
            let data = try encodedRaster(
                type: fixture.type,
                pixelWidth: 101,
                pixelHeight: 51,
                bitsPerComponent: fixture.depth,
                floatingPoint: fixture.floatingPoint)
            let source = try XCTUnwrap(
                CGImageSourceCreateWithData(data as CFData, nil))
            let properties = try XCTUnwrap(
                CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                    as? [CFString: Any])
            XCTAssertEqual(
                (properties[kCGImagePropertyDepth] as? NSNumber)?.intValue,
                fixture.depth,
                "the fixture must retain its high-depth declaration")
            if fixture.floatingPoint {
                XCTAssertEqual(
                    (properties[kCGImagePropertyIsFloat] as? NSNumber)?.boolValue,
                    true,
                    "the TIFF fixture must exercise the float decoder path")
            }
            try data.write(to: directory.appendingPathComponent(fixture.name))

            guard case .success(let content) = makeRenderer().image(
                at: fixture.name, relativeTo: directory, maxWidth: 400),
                let bitmap = content.cgImage
            else { return XCTFail("\(fixture.name) should render through bounded ImageIO") }
            let (decodedBytes, overflow) = bitmap.bytesPerRow.multipliedReportingOverflow(
                by: bitmap.height)
            XCTAssertFalse(overflow)
            XCTAssertLessThanOrEqual(decodedBytes, 64_000_000)
        }
    }

    func testRealEightSixteenAndThirtyTwoBitRastersDownsampleUnderSmallStorageBudget() throws {
        let directory = try imageDirectory(prefix: "MarkDevImageSmallDecodeBudget")
        let budget = 1_000_000
        let fixtures: [(name: String, type: UTType, depth: Int, floatingPoint: Bool)] = [
            ("eight.png", .png, 8, false),
            ("sixteen.png", .png, 16, false),
            ("float.tiff", .tiff, 32, true),
        ]
        let renderer = RichContentRenderer(decodedRasterByteBudget: budget)

        for fixture in fixtures {
            let data = try encodedRaster(
                type: fixture.type,
                pixelWidth: 600,
                pixelHeight: 300,
                bitsPerComponent: fixture.depth,
                floatingPoint: fixture.floatingPoint)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let properties = try XCTUnwrap(
                CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            XCTAssertEqual(
                (properties[kCGImagePropertyDepth] as? NSNumber)?.intValue,
                fixture.depth,
                "the real fixture must exercise its declared storage depth")
            try data.write(to: directory.appendingPathComponent(fixture.name))

            guard case .success(let content) = renderer.image(
                at: fixture.name,
                relativeTo: directory,
                maxWidth: 800),
                let bitmap = content.cgImage
            else { return XCTFail("\(fixture.name) should render through downsampling") }
            let (decodedBytes, overflow) = bitmap.bytesPerRow.multipliedReportingOverflow(
                by: bitmap.height)
            XCTAssertFalse(overflow)
            XCTAssertLessThan(
                max(bitmap.width, bitmap.height),
                600,
                "\(fixture.name) must actually take the small-budget thumbnail path")
            XCTAssertLessThanOrEqual(
                decodedBytes,
                budget,
                "\(fixture.name) retained \(decodedBytes) decoded bytes past the seam")
        }
    }

    func testRasterLogicalSizeAndPixelsFollowEXIFOrientation() throws {
        for orientation in [
            CGImagePropertyOrientation.leftMirrored,
            .right,
            .rightMirrored,
            .left,
        ] {
            let directory = try imageDirectory(prefix: "MarkDevImageOrientation")
            try png(
                pixelWidth: 240,
                pixelHeight: 120,
                pointSize: CGSize(width: 120, height: 60),
                orientation: orientation
            ).write(to: directory.appendingPathComponent("rotated.png"))

            guard case .success(let content) = makeRenderer().image(
                at: "rotated.png", relativeTo: directory, maxWidth: 400)
            else { return XCTFail("an oriented high-DPI PNG should load") }

            XCTAssertEqual(try XCTUnwrap(content.cgImage).width, 120)
            XCTAssertEqual(try XCTUnwrap(content.cgImage).height, 240)
            XCTAssertEqual(content.size.width, 60, accuracy: 0.5)
            XCTAssertEqual(content.size.height, 120, accuracy: 0.5)
        }
    }

    func testEveryEXIFOrientationMapsLosslessRasterPixelsBySpecification() throws {
        let directory = try imageDirectory(prefix: "MarkDevImageOrientationPixels")
        let orientations: [CGImagePropertyOrientation] = [
            .up, .upMirrored, .down, .downMirrored,
            .leftMirrored, .right, .rightMirrored, .left,
        ]
        let renderer = RichContentRenderer()
        var upright: [[Int]]?
        var encodedUpright: [[Int]]?

        for orientation in orientations {
            let name = "orientation-\(orientation.rawValue).png"
            let data = try orientationPNG(orientation)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let properties = try XCTUnwrap(
                CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            XCTAssertEqual(
                (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value,
                orientation.rawValue,
                "the lossless fixture must retain EXIF orientation \(orientation.rawValue)")
            let encodedImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let encodedSignature = try orientationSignature(
                of: encodedImage,
                columns: 3,
                rows: 2)
            if orientation == .up {
                encodedUpright = encodedSignature
            } else {
                XCTAssertEqual(
                    encodedSignature,
                    try XCTUnwrap(encodedUpright),
                    "the fixture encoder must change only metadata, not source pixels")
            }
            try data.write(to: directory.appendingPathComponent(name))

            guard case .success(let content) = renderer.image(
                at: name,
                relativeTo: directory,
                maxWidth: 200),
                let bitmap = content.cgImage
            else { return XCTFail("orientation \(orientation.rawValue) should render") }
            let swapsAxes = (5...8).contains(Int(orientation.rawValue))
            let columns = swapsAxes ? 2 : 3
            let rows = swapsAxes ? 3 : 2
            XCTAssertEqual(bitmap.width, columns * 30)
            XCTAssertEqual(bitmap.height, rows * 30)
            let signature = try orientationSignature(
                of: bitmap,
                columns: columns,
                rows: rows)
            XCTAssertEqual(Set(signature.flatMap { $0 }), Set(0..<6))

            if orientation == .up {
                upright = signature
            } else {
                let sourceSignature = try XCTUnwrap(upright)
                XCTAssertEqual(
                    signature,
                    orientedSignature(sourceSignature, orientation: orientation),
                    "EXIF orientation \(orientation.rawValue) mapped pixels incorrectly")
            }
        }
    }

    func testInvalidRasterDPIAlwaysFallsBackToFinite72DPIPoints() {
        let invalid: [Double?] = [nil, 0, -1, .nan, .infinity]
        for dpi in invalid {
            let plain = RichContentRenderer.rasterPointSize(
                pixelWidth: 240,
                pixelHeight: 120,
                dpiWidth: dpi,
                dpiHeight: dpi,
                orientation: CGImagePropertyOrientation.up.rawValue)
            XCTAssertEqual(plain, CGSize(width: 240, height: 120))
            XCTAssertTrue(plain.width.isFinite)
            XCTAssertTrue(plain.height.isFinite)

            let rotated = RichContentRenderer.rasterPointSize(
                pixelWidth: 240,
                pixelHeight: 120,
                dpiWidth: dpi,
                dpiHeight: dpi,
                orientation: CGImagePropertyOrientation.right.rawValue)
            XCTAssertEqual(rotated, CGSize(width: 120, height: 240))
        }
    }

    func testRasterDPIAxesSwapWithEXIFRotation() {
        let rotated = RichContentRenderer.rasterPointSize(
            pixelWidth: 240,
            pixelHeight: 120,
            dpiWidth: 144,
            dpiHeight: 72,
            orientation: CGImagePropertyOrientation.right.rawValue)
        XCTAssertEqual(rotated, CGSize(width: 120, height: 120))
    }

    func testHalfInvalidRasterDPIFallsBackAsAPair() {
        XCTAssertEqual(
            RichContentRenderer.rasterPointSize(
                pixelWidth: 240,
                pixelHeight: 120,
                dpiWidth: 144,
                dpiHeight: 0,
                orientation: CGImagePropertyOrientation.up.rawValue),
            CGSize(width: 240, height: 120),
            "one corrupt DPI axis must not distort the picture with half-trusted metadata")
    }

    func testSubpointHighDPIRasterIsFlooredInsteadOfRejected() throws {
        let directory = try imageDirectory(prefix: "MarkDevImageSubpointDPI")
        try png(
            pixelWidth: 1,
            pixelHeight: 1,
            pointSize: CGSize(width: 0.5, height: 0.5)
        ).write(to: directory.appendingPathComponent("tiny.png"))

        guard case .success(let content) = makeRenderer().image(
            at: "tiny.png", relativeTo: directory, maxWidth: 400)
        else { return XCTFail("valid high-DPI metadata must not make an image unreadable") }
        XCTAssertEqual(content.size, CGSize(width: 1, height: 1))
    }

    func testPixelAspectTransformMayChangeDecodedDimensionsWithinItsBound() throws {
        let directory = try imageDirectory(prefix: "MarkDevImagePixelAspect")
        let encoded = try png(
            pixelWidth: 101,
            pixelHeight: 51,
            pointSize: CGSize(width: 101 * 72.0 / 300, height: 51 * 72.0 / 150))
        let aspectData = try removingPNGChunk(named: "eXIf", from: encoded)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(aspectData as CFData, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let pixelWidth = try XCTUnwrap(
            (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue)
        let pixelHeight = try XCTUnwrap(
            (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue)
        let dpiWidth = try XCTUnwrap(
            (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue)
        let dpiHeight = try XCTUnwrap(
            (properties[kCGImagePropertyDPIHeight] as? NSNumber)?.doubleValue)
        let encodedPixelAspect = pixelWidth / pixelHeight
        let physicalAspect = (pixelWidth / dpiWidth) / (pixelHeight / dpiHeight)
        XCTAssertGreaterThan(
            encodedPixelAspect,
            1.9,
            "the stored pixel grid must be the wide half of the fixture")
        XCTAssertLessThan(
            physicalAspect,
            1,
            "the DPI metadata must describe slightly taller physical pixels")
        XCTAssertGreaterThan(
            abs(encodedPixelAspect - physicalAspect),
            0.9,
            "the metadata must require a real pixel-aspect transform")
        try aspectData.write(to: directory.appendingPathComponent("aspect.png"))

        guard case .success(let content) = makeRenderer().image(
            at: "aspect.png", relativeTo: directory, maxWidth: 400),
            let bitmap = content.cgImage
        else { return XCTFail("ImageIO may transform a valid non-square pixel aspect") }
        let decodedAspect = Double(bitmap.width) / Double(bitmap.height)
        XCTAssertLessThanOrEqual(max(bitmap.width, bitmap.height), 101)
        XCTAssertEqual(
            decodedAspect,
            physicalAspect,
            accuracy: 0.03,
            "the transformed pixels should preserve physical, not stored-pixel, aspect")
        XCTAssertEqual(
            Double(content.size.width / content.size.height),
            physicalAspect,
            accuracy: 0.01,
            "layout should preserve the physical aspect described by metadata")
    }

    func testRasterAdmissionBoundsHighDepthStorageBeforeDecode() throws {
        let maximum = try XCTUnwrap(
            RichContentRenderer.rasterThumbnailMaximumDimension(
                pixelWidth: 4_000,
                pixelHeight: 4_000,
                depth: 16,
                colorModel: kCGImagePropertyColorModelRGB as String,
                hasAlpha: true,
                indexed: false))

        XCTAssertLessThan(
            maximum,
            4_000,
            "a 16-bit RGBA square cannot be eagerly decoded at the pixel-only ceiling")
    }

    func testRasterAdmissionReturnsTheExactLargestPermittedDimension() throws {
        let maximum = try XCTUnwrap(
            RichContentRenderer.rasterThumbnailMaximumDimension(
                pixelWidth: 1_000,
                pixelHeight: 1_000,
                depth: 16,
                colorModel: kCGImagePropertyColorModelRGB as String,
                hasAlpha: true,
                indexed: false,
                storageByteLimit: 1_048_576,
                rasterPixelLimit: 1_000_000,
                rowAlignment: 4_096))

        // Independently derived: 16-bit RGBA requests eight bytes per pixel.
        // Through 512 pixels each row rounds to one 4 KiB page, so exactly 256
        // rows consume 1 MiB and row 257 is the first byte over the ceiling.
        XCTAssertEqual(maximum, 256)
        XCTAssertEqual(4_096 * maximum, 1_048_576)
        XCTAssertGreaterThan(4_096 * (maximum + 1), 1_048_576)
    }

    func testRasterAdmissionFailsClosedWithoutDepthOrColorModel() {
        XCTAssertNil(
            RichContentRenderer.rasterThumbnailMaximumDimension(
                pixelWidth: 100,
                pixelHeight: 100,
                depth: nil,
                colorModel: kCGImagePropertyColorModelRGB as String,
                hasAlpha: true,
                indexed: false))
        XCTAssertNil(
            RichContentRenderer.rasterThumbnailMaximumDimension(
                pixelWidth: 100,
                pixelHeight: 100,
                depth: 8,
                colorModel: nil,
                hasAlpha: true,
                indexed: false))
    }

    func testRasterAdmissionBoundsEverySupportedStorageClass() throws {
        let byteLimit: Int64 = 1_048_576
        let pixelLimit: Int64 = 1_000_000
        let alignment: Int64 = 4_096
        let classes: [(model: String, alpha: Bool, indexed: Bool, components: Int64)] = [
            (kCGImagePropertyColorModelGray as String, false, false, 4),
            (kCGImagePropertyColorModelGray as String, true, false, 4),
            (kCGImagePropertyColorModelRGB as String, false, false, 4),
            (kCGImagePropertyColorModelRGB as String, true, false, 4),
            (kCGImagePropertyColorModelLab as String, true, false, 4),
            (kCGImagePropertyColorModelCMYK as String, true, false, 5),
            (kCGImagePropertyColorModelRGB as String, false, true, 4),
        ]

        for depth: Int64 in [8, 16, 32] {
            for storageClass in classes {
                let maximum = Int64(try XCTUnwrap(
                    RichContentRenderer.rasterThumbnailMaximumDimension(
                        pixelWidth: 1_000,
                        pixelHeight: 1_000,
                        depth: depth,
                        colorModel: storageClass.model,
                        hasAlpha: storageClass.alpha,
                        indexed: storageClass.indexed,
                        storageByteLimit: byteLimit,
                        rasterPixelLimit: pixelLimit,
                        rowAlignment: alignment)))
                let componentBytes = (max(depth, 8) + 7) / 8
                let rowBytes = maximum * storageClass.components * componentBytes
                let alignedRowBytes = ((rowBytes + alignment - 1) / alignment) * alignment
                XCTAssertLessThanOrEqual(maximum * maximum, pixelLimit)
                XCTAssertLessThanOrEqual(
                    alignedRowBytes * maximum,
                    byteLimit,
                    "\(storageClass.model), depth \(depth) exceeded its predecode budget")
            }
        }
    }

    func testRasterAdmissionRejectsInvalidMetadataAndArithmeticOverflow() {
        for depth: Int64 in [0, 33] {
            XCTAssertNil(
                RichContentRenderer.rasterThumbnailMaximumDimension(
                    pixelWidth: 100,
                    pixelHeight: 100,
                    depth: depth,
                    colorModel: kCGImagePropertyColorModelRGB as String,
                    hasAlpha: true,
                    indexed: false))
        }
        XCTAssertNil(
            RichContentRenderer.rasterThumbnailMaximumDimension(
                pixelWidth: 100,
                pixelHeight: 100,
                depth: 8,
                colorModel: "hostile-model",
                hasAlpha: true,
                indexed: false))
        XCTAssertNil(
            RichContentRenderer.rasterThumbnailMaximumDimension(
                pixelWidth: Int64.max,
                pixelHeight: Int64.max,
                depth: 8,
                colorModel: kCGImagePropertyColorModelRGB as String,
                hasAlpha: true,
                indexed: false))
    }

    func testUnknownOrientationDoesNotInventAnAxisSwap() {
        for orientation: UInt32 in [0, 9, .max] {
            XCTAssertEqual(
                RichContentRenderer.rasterPointSize(
                    pixelWidth: 240,
                    pixelHeight: 120,
                    dpiWidth: 144,
                    dpiHeight: 72,
                    orientation: orientation),
                CGSize(width: 120, height: 120))
        }
    }

    func testExtremeFiniteRasterDPIAlwaysProducesFinitePositiveLayout() {
        for dpi in [144.0, Double.greatestFiniteMagnitude, Double.leastNonzeroMagnitude] {
            let size = RichContentRenderer.rasterPointSize(
                pixelWidth: 1,
                pixelHeight: 1,
                dpiWidth: dpi,
                dpiHeight: dpi,
                orientation: CGImagePropertyOrientation.up.rawValue)
            XCTAssertTrue(size.width.isFinite)
            XCTAssertTrue(size.height.isFinite)
            XCTAssertGreaterThan(size.width, 0)
            XCTAssertGreaterThan(size.height, 0)
        }
    }

    func testRealizedRasterBufferRejectsEveryBoundaryViolation() {
        XCTAssertTrue(
            RichContentRenderer.rasterBufferIsAdmitted(
                width: 100,
                height: 101,
                bytesPerRow: 416,
                maximumDimension: 101))
        for invalid in [
            (0, 1, 4, 1),
            (1, 0, 4, 1),
            (1, 1, 0, 1),
            (2, 1, 8, 1),
            (1, 2, 4, 1),
        ] {
            XCTAssertFalse(
                RichContentRenderer.rasterBufferIsAdmitted(
                    width: invalid.0,
                    height: invalid.1,
                    bytesPerRow: invalid.2,
                    maximumDimension: invalid.3))
        }
        XCTAssertFalse(
            RichContentRenderer.rasterBufferIsAdmitted(
                width: Int.max,
                height: 2,
                bytesPerRow: 4,
                maximumDimension: Int.max))
        XCTAssertFalse(
            RichContentRenderer.rasterBufferIsAdmitted(
                width: 1,
                height: 2,
                bytesPerRow: Int.max,
                maximumDimension: 2))
        XCTAssertFalse(
            RichContentRenderer.rasterBufferIsAdmitted(
                width: 11,
                height: 10,
                bytesPerRow: 44,
                maximumDimension: 11,
                rasterPixelLimit: 100,
                storageByteLimit: 1_000))
        XCTAssertFalse(
            RichContentRenderer.rasterBufferIsAdmitted(
                width: 10,
                height: 10,
                bytesPerRow: 44,
                maximumDimension: 10,
                rasterPixelLimit: 100,
                storageByteLimit: 400))
    }

    func testAtomicReplacementInvalidatesSuccessfulImageCache() throws {
        let directory = try imageDirectory(prefix: "MarkDevImageReplacement")
        let file = directory.appendingPathComponent("changing.png")
        try png(pixelWidth: 40, pixelHeight: 20).write(to: file, options: .atomic)

        let renderer = makeRenderer()
        guard case .success(let before) = renderer.image(
            at: "changing.png", relativeTo: directory, maxWidth: 400)
        else { return XCTFail("the initial image should load") }

        try png(pixelWidth: 80, pixelHeight: 20, red: 0.85, blue: 0.15)
            .write(to: file, options: .atomic)
        guard case .success(let after) = renderer.image(
            at: "changing.png", relativeTo: directory, maxWidth: 400)
        else { return XCTFail("the replacement image should load") }

        XCTAssertEqual(before.size.width, 40, accuracy: 0.5)
        XCTAssertEqual(after.size.width, 80, accuracy: 0.5)
        XCTAssertFalse(before.image === after.image, "a replacement is a new file generation")
    }

    func testCacheAuthorityCannotCrossRequestedFormatsDuringRename() throws {
        let directory = try imageDirectory(prefix: "MarkDevImageFormatAuthority")
        let renamed = directory.appendingPathComponent("renamed.svg")
        try png(pixelWidth: 40, pixelHeight: 20).write(to: renamed)

        // Models the descriptor race deterministically: a request opened as a
        // PNG now has the path spelling acquired after a rename to `.svg`.
        let renderer = RichContentRenderer(imageFileOpener: { _, maximumBytes in
            try MarkDevKit.BoundedRegularFileReader.open(
                renamed,
                maximumBytes: maximumBytes,
                cancellationCheck: { false })
        })
        guard case .success = renderer.image(
            at: "before.png", relativeTo: directory, maxWidth: 400)
        else { return XCTFail("the first request should retain PNG format authority") }

        guard case .failure = renderer.image(
            at: "renamed.svg", relativeTo: directory, maxWidth: 400)
        else {
            return XCTFail(
                "a cached raster must not bypass SVG validation after a cross-format rename")
        }
    }

    func testSameInodeMutationInvalidatesSuccessfulImageCache() throws {
        let directory = try imageDirectory(prefix: "MarkDevImageMutation")
        let file = directory.appendingPathComponent("changing.png")
        try png(pixelWidth: 48, pixelHeight: 24).write(to: file)
        let beforeGeneration = try MarkDevKit.BoundedRegularFileReader.read(
            file,
            maximumBytes: 1_048_576).generation

        let renderer = makeRenderer()
        guard case .success(let before) = renderer.image(
            at: "changing.png", relativeTo: directory, maxWidth: 400)
        else { return XCTFail("the initial image should load") }

        // No `.atomic`: this truncates and rewrites the existing inode, so a
        // cache keyed only by path or device/inode still serves stale pixels.
        try png(pixelWidth: 96, pixelHeight: 24, green: 0.85, blue: 0.15)
            .write(to: file)
        let afterGeneration = try MarkDevKit.BoundedRegularFileReader.read(
            file,
            maximumBytes: 1_048_576).generation
        guard case .success(let after) = renderer.image(
            at: "changing.png", relativeTo: directory, maxWidth: 400)
        else { return XCTFail("the rewritten image should load") }

        XCTAssertEqual(beforeGeneration.device, afterGeneration.device)
        XCTAssertEqual(beforeGeneration.inode, afterGeneration.inode)
        XCTAssertNotEqual(beforeGeneration, afterGeneration)
        XCTAssertEqual(before.size.width, 48, accuracy: 0.5)
        XCTAssertEqual(after.size.width, 96, accuracy: 0.5)
        XCTAssertFalse(before.image === after.image, "an in-place rewrite is a new generation")
    }

    func testSameSizeRewriteWithRestoredModificationTimeInvalidatesImageCache() throws {
        let directory = try imageDirectory(prefix: "MarkDevImageForgedMetadata")
        let file = directory.appendingPathComponent("changing.png")
        let firstBytes = try png(pixelWidth: 64, pixelHeight: 32, red: 0.9, blue: 0.1)
        let secondBytes = try png(pixelWidth: 64, pixelHeight: 32, red: 0.1, blue: 0.9)
        XCTAssertEqual(firstBytes.count, secondBytes.count, "the fixture must preserve byte size")
        try firstBytes.write(to: file)
        let beforeGeneration = try MarkDevKit.BoundedRegularFileReader.read(
            file,
            maximumBytes: 1_048_576).generation

        let renderer = makeRenderer()
        guard case .success(let before) = renderer.image(
            at: "changing.png", relativeTo: directory, maxWidth: 400)
        else { return XCTFail("the initial image should load") }

        try secondBytes.write(to: file)
        try restoreExactRendererFixtureModificationTime(
            of: file,
            to: beforeGeneration)
        let afterGeneration = try MarkDevKit.BoundedRegularFileReader.read(
            file,
            maximumBytes: 1_048_576).generation
        try assertOnlyRendererFixtureChangeTimeDiffers(
            before: beforeGeneration,
            after: afterGeneration)
        guard case .success(let after) = renderer.image(
            at: "changing.png", relativeTo: directory, maxWidth: 400)
        else { return XCTFail("the rewritten image should load") }

        XCTAssertFalse(
            before.image === after.image,
            "ctime must bind the cache when size, inode, and mtime are unchanged")
    }

    func testCachedImageProbeRejectsAReplacementGeneration() throws {
        let directory = try imageDirectory(prefix: "MarkDevImageProbeGeneration")
        let file = directory.appendingPathComponent("changing.png")
        try png(pixelWidth: 40, pixelHeight: 20).write(to: file, options: .atomic)
        let request = RenderRequest(
            block: RenderedBlock(kind: .image(alt: ""), source: "changing.png"),
            directory: directory,
            context: RenderContext(
                width: 400, dark: false, mathFontSize: 16, textColor: .labelColor))

        let renderer = makeRenderer()
        XCTAssertFalse(renderer.isCached(request))
        guard case .success = renderer.render(request) else {
            return XCTFail("the initial image should load")
        }
        XCTAssertTrue(renderer.isCached(request))

        try png(pixelWidth: 80, pixelHeight: 20).write(to: file, options: .atomic)
        XCTAssertFalse(
            renderer.isCached(request),
            "a pathname hit for an old file generation is not a cache hit")
    }

    func testInvalidReplacementDoesNotReuseCachedSuccess() throws {
        let directory = try imageDirectory(prefix: "MarkDevImageInvalidReplacement")
        let file = directory.appendingPathComponent("changing.png")
        try png(pixelWidth: 40, pixelHeight: 20).write(to: file, options: .atomic)

        let renderer = makeRenderer()
        guard case .success = renderer.image(
            at: "changing.png", relativeTo: directory, maxWidth: 400)
        else { return XCTFail("the initial image should load") }

        try Data("not a png".utf8).write(to: file, options: .atomic)
        guard case .failure = renderer.image(
            at: "changing.png", relativeTo: directory, maxWidth: 400)
        else { return XCTFail("invalid replacement bytes must not reuse a cached success") }
    }

    func testAtomicReplacementInvalidatesCachedImageFailure() throws {
        let directory = try imageDirectory(prefix: "MarkDevImageRecovery")
        let file = directory.appendingPathComponent("recovering.png")
        try Data("not a png".utf8).write(to: file, options: .atomic)

        let renderer = makeRenderer()
        guard case .failure = renderer.image(
            at: "recovering.png", relativeTo: directory, maxWidth: 400)
        else { return XCTFail("invalid bytes should fail") }

        try png(pixelWidth: 72, pixelHeight: 36).write(to: file, options: .atomic)
        guard case .success(let recovered) = renderer.image(
            at: "recovering.png", relativeTo: directory, maxWidth: 400)
        else { return XCTFail("a valid replacement must recover without global invalidation") }
        XCTAssertEqual(recovered.size.width, 72, accuracy: 0.5)
    }

    func testImageCreatedAtPreviouslyMissingPathIsNotHiddenByFailureCache() throws {
        let cacheDirectory = try XCTUnwrap(
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
        let directory = cacheDirectory
            .appendingPathComponent("MarkDevImageAppears-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("appears.png")
        let renderer = makeRenderer()

        guard case .failure = renderer.image(
            at: "appears.png", relativeTo: directory, maxWidth: 400)
        else { return XCTFail("a missing file should fail") }

        try png(pixelWidth: 64, pixelHeight: 32).write(to: file, options: .atomic)
        guard case .success = renderer.image(
            at: "appears.png", relativeTo: directory, maxWidth: 400)
        else { return XCTFail("creating the file must recover without global invalidation") }
    }

    func testIntrinsicAndExplicitRasterWidthsDoNotShareACacheEntry() throws {
        let directory = try imageDirectory(prefix: "MarkDevImageSizing")
        try png(pixelWidth: 100, pixelHeight: 50)
            .write(to: directory.appendingPathComponent("sizing.png"))

        let renderer = makeRenderer()
        guard case .success(let intrinsic) = renderer.image(
            at: "sizing.png", relativeTo: directory, maxWidth: 400),
            case .success(let explicit) = renderer.image(
                at: "sizing.png", relativeTo: directory, maxWidth: 400, width: 400)
        else { return XCTFail("both sizing modes should load") }

        XCTAssertEqual(intrinsic.size.width, 100, accuracy: 0.5)
        XCTAssertEqual(explicit.size.width, 400, accuracy: 0.5)
        XCTAssertFalse(intrinsic.image === explicit.image)
    }

    func testExplicitThenIntrinsicRasterWidthsDoNotShareACacheEntry() throws {
        let directory = try imageDirectory(prefix: "MarkDevImageSizingReverse")
        try png(pixelWidth: 100, pixelHeight: 50)
            .write(to: directory.appendingPathComponent("sizing.png"))

        let renderer = makeRenderer()
        guard case .success(let explicit) = renderer.image(
            at: "sizing.png", relativeTo: directory, maxWidth: 400, width: 400),
            case .success(let intrinsic) = renderer.image(
                at: "sizing.png", relativeTo: directory, maxWidth: 400)
        else { return XCTFail("both sizing modes should load") }

        XCTAssertEqual(explicit.size.width, 400, accuracy: 0.5)
        XCTAssertEqual(intrinsic.size.width, 100, accuracy: 0.5)
        XCTAssertFalse(intrinsic.image === explicit.image)
    }

    func testFractionalRasterWidthsDoNotCollideInEitherOrder() throws {
        let directory = try imageDirectory(prefix: "MarkDevImageFractionalSizing")
        try png(pixelWidth: 160, pixelHeight: 80)
            .write(to: directory.appendingPathComponent("sizing.png"))
        let widths: [CGFloat] = [72.1, 72.9]

        for order in [widths, Array(widths.reversed())] {
            let renderer = RichContentRenderer()
            var rendered: [RenderedContent] = []
            for width in order {
                guard case .success(let content) = renderer.image(
                    at: "sizing.png",
                    relativeTo: directory,
                    maxWidth: 400,
                    width: width)
                else { return XCTFail("the raster should render at \(width) points") }
                XCTAssertEqual(
                    content.size.width,
                    width,
                    accuracy: 0.000_001,
                    "the exact width, not an earlier width in its integer bucket")
                rendered.append(content)
            }
            XCTAssertFalse(
                rendered[0].image === rendered[1].image,
                "different fractional sizes need different cache entries in either order")
            XCTAssertEqual(renderer.cacheInventoryForTesting.successes, 2)
        }
    }

    func testTrailingSlashCannotReuseCachedRegularFile() throws {
        let directory = try imageDirectory(prefix: "MarkDevImageTrailingSlash")
        try png(pixelWidth: 60, pixelHeight: 30)
            .write(to: directory.appendingPathComponent("regular.png"))

        let renderer = makeRenderer()
        guard case .success = renderer.image(
            at: "regular.png", relativeTo: directory, maxWidth: 400)
        else { return XCTFail("the regular file should load") }
        guard case .failure = renderer.image(
            at: "regular.png/", relativeTo: directory, maxWidth: 400)
        else { return XCTFail("a directory-marked reference must not hit the file cache") }

        for source in [
            directory.appendingPathComponent("regular.png").path + "/",
            directory.appendingPathComponent("regular.png").absoluteString + "/",
        ] {
            guard case .failure = makeRenderer().image(
                at: source, relativeTo: nil, maxWidth: 400)
            else { return XCTFail("directory-marked source should fail: \(source)") }
        }
    }

    func testNonLocalFileURLAuthorityCannotReadALocalPath() throws {
        let directory = try imageDirectory(prefix: "MarkDevImageAuthority")
        let file = directory.appendingPathComponent("private.png")
        try png(pixelWidth: 60, pixelHeight: 30).write(to: file)

        let source = "file://attacker.invalid\(file.path)"
        guard case .failure = makeRenderer().image(
            at: source, relativeTo: nil, maxWidth: 400)
        else { return XCTFail("a nonlocal file authority must never become a local read") }

        guard case .success = makeRenderer().image(
            at: "file://localhost\(file.path)", relativeTo: nil, maxWidth: 400)
        else { return XCTFail("localhost is the only explicit local file authority") }
    }

    func testRemoteAndNonLocalFileBasesCannotGrantLocalDirectoryAuthority() throws {
        let directory = try imageDirectory(prefix: "MarkDevImageBaseAuthority")
        try png(pixelWidth: 60, pixelHeight: 30)
            .write(to: directory.appendingPathComponent("private.png"))

        for base in [
            try XCTUnwrap(URL(string: "https://attacker.invalid\(directory.path)/")),
            try XCTUnwrap(URL(string: "file://attacker.invalid\(directory.path)/")),
        ] {
            guard case .failure = makeRenderer().image(
                at: "private.png", relativeTo: base, maxWidth: 400)
            else { return XCTFail("a nonlocal base must not grant local authority: \(base)") }
        }
    }

    func testPercentEncodedAbsolutePathIsDecodedExactlyOnce() throws {
        let directory = try imageDirectory(prefix: "MarkDevImagePercent")
        let file = directory.appendingPathComponent("space name.png")
        try png(pixelWidth: 60, pixelHeight: 30).write(to: file)
        let encodedAbsolute = String(file.absoluteString.dropFirst("file://".count))
        XCTAssertTrue(encodedAbsolute.contains("%20"), "the fixture needs an encoded space")

        let renderer = makeRenderer()
        guard case .success(let encoded) = renderer.image(
            at: encodedAbsolute, relativeTo: nil, maxWidth: 400),
            case .success(let raw) = renderer.image(
                at: file.path, relativeTo: nil, maxWidth: 400)
        else { return XCTFail("encoded and raw absolute paths should both load") }
        XCTAssertTrue(encoded.image === raw.image, "both spellings name one file generation")
    }

    func testPercentEncodedProtocolRelativeReferenceRemainsRemote() throws {
        let directory = try imageDirectory(prefix: "MarkDevImageEncodedRemote")
        let file = directory.appendingPathComponent("private.png")
        try png(pixelWidth: 60, pixelHeight: 30).write(to: file)
        let encoded = file.path
            .replacingOccurrences(of: "/", with: "%2F")

        guard case .failure = makeRenderer().image(
            at: "%2F\(encoded)", relativeTo: directory, maxWidth: 400)
        else { return XCTFail("an encoded protocol-relative reference must remain remote") }
    }

    func testAMissingImageReportsItsName() {
        let renderer = makeRenderer()
        guard case .failure(let failure) = renderer.image(
            at: "nope.png", relativeTo: URL(fileURLWithPath: "/tmp"), maxWidth: 400)
        else { return XCTFail("a missing file should fail") }
        XCTAssertTrue(failure.reason.contains("nope.png"))
    }

    func testAParentRelativePathResolvesToTheParentFile() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevParentImg-\(UUID().uuidString)")
        let notes = root.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let image = NSImage(size: CGSize(width: 80, height: 40))
        image.lockFocus()
        NSColor.systemOrange.drawSwatch(in: CGRect(x: 0, y: 0, width: 80, height: 40))
        image.unlockFocus()
        let data = try XCTUnwrap(
            NSBitmapImageRep(data: image.tiffRepresentation ?? Data())?
                .representation(using: .png, properties: [:]))
        try data.write(to: root.appendingPathComponent("pic.png"))

        let renderer = makeRenderer()
        guard case .success(let content) = renderer.image(
            at: "../pic.png", relativeTo: notes, maxWidth: 400)
        else { return XCTFail("a parent-relative local path must load") }
        XCTAssertGreaterThan(content.size.width, 0)
        XCTAssertGreaterThan(content.size.height, 0)
    }

    func testRemoteImagesAreRefused() {
        // Opening a note must not become a network request: that is both a
        // privacy leak and a way for a document to phone home on preview.
        let renderer = makeRenderer()
        for source in [
            "https://example.com/a.png", "http://example.com/a.png",
            "//example.com/a.png",
        ] {
            if case .success = renderer.image(at: source, relativeTo: nil, maxWidth: 400) {
                XCTFail("\(source) should not have loaded")
            }
        }
    }

    func testEmptyAndOddSourcesFailCleanly() {
        let renderer = makeRenderer()
        guard case .failure = renderer.image(at: "", relativeTo: nil, maxWidth: 400) else {
            return XCTFail("an empty source should fail")
        }
        guard case .failure = renderer.image(at: "x.png", relativeTo: nil, maxWidth: 400) else {
            return XCTFail("a relative path with no base should fail")
        }
    }

    // MARK: - Vector images

    /// An SVG whose nominal size is `size`, drawing a filled circle.
    ///
    /// A circle rather than a rectangle because the tests below measure the
    /// *edge*: a shape whose outline is axis-aligned is sharp at any
    /// resolution, and would pass whether it had been rendered or resampled.
    private func circleSVG(size: Int) -> String {
        """
        <svg xmlns="http://www.w3.org/2000/svg" width="\(size)" height="\(size)" \
        viewBox="0 0 \(size) \(size)"><circle cx="\(size / 2)" cy="\(size / 2)" \
        r="\(size / 2 - 1)" fill="black"/></svg>
        """
    }

    /// Writes `files` into a directory of their own, removed when the test ends.
    private func directory(containing files: [String: String]) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevVectors-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        for (name, contents) in files {
            try contents.write(
                to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return directory
    }

    func testIntrinsicAndExplicitVectorWidthsDoNotShareACacheEntry() throws {
        let directory = try directory(containing: ["sizing.svg": circleSVG(size: 100)])
        let renderer = makeRenderer()

        guard case .success(let intrinsic) = renderer.image(
            at: "sizing.svg", relativeTo: directory, maxWidth: 400),
            case .success(let explicit) = renderer.image(
                at: "sizing.svg", relativeTo: directory, maxWidth: 400, width: 400)
        else { return XCTFail("both sizing modes should load") }

        XCTAssertEqual(intrinsic.size.width, 100, accuracy: 0.5)
        XCTAssertEqual(explicit.size.width, 400, accuracy: 0.5)
        XCTAssertFalse(intrinsic.image === explicit.image)
    }

    func testExpensiveVectorCacheDoesNotCrossFileGenerations() throws {
        let directory = try imageDirectory(prefix: "MarkDevVectorReplacement")
        let file = directory.appendingPathComponent("changing.svg")
        try """
            <svg xmlns="http://www.w3.org/2000/svg" width="100" height="100" \
            viewBox="0 0 100 100"><rect width="100" height="100" fill="red"/></svg>
            """.write(to: file, atomically: true, encoding: .utf8)

        let renderer = RichContentRenderer(expensiveRasterBudget: .zero)
        guard case .success(let before) = renderer.image(
            at: "changing.svg", relativeTo: directory, maxWidth: 400)
        else { return XCTFail("the initial vector should load") }

        try """
            <svg xmlns="http://www.w3.org/2000/svg" width="200" height="100" \
            viewBox="0 0 200 100"><rect width="200" height="100" fill="blue"/></svg>
            """.write(to: file, atomically: true, encoding: .utf8)
        guard case .success(let after) = renderer.image(
            at: "changing.svg", relativeTo: directory, maxWidth: 400)
        else { return XCTFail("the replacement vector should load") }

        XCTAssertEqual(before.size, CGSize(width: 100, height: 100))
        XCTAssertEqual(after.size, CGSize(width: 200, height: 100))
        XCTAssertEqual(try XCTUnwrap(after.cgImage).width, 400)
        XCTAssertEqual(try XCTUnwrap(after.cgImage).height, 200)
    }

    func testGenerationChurnKeepsEveryRendererCacheBounded() throws {
        let directory = try imageDirectory(prefix: "MarkDevVectorGenerationChurn")
        let file = directory.appendingPathComponent("changing.svg")
        let renderer = RichContentRenderer(
            pixelBudget: 100_000,
            expensiveRasterBudget: .zero)

        for generation in 0..<180 {
            let color = String(format: "#%06X", generation)
            try """
                <svg xmlns="http://www.w3.org/2000/svg" width="64" height="32" \
                viewBox="0 0 64 32"><rect width="64" height="32" fill="\(color)"/></svg>
                """.write(to: file, atomically: true, encoding: .utf8)
            guard case .success = renderer.image(
                at: "changing.svg", relativeTo: directory, maxWidth: 400)
            else { return XCTFail("generation \(generation) should render") }

            let inventory = renderer.cacheInventoryForTesting
            XCTAssertLessThanOrEqual(inventory.successes, 128)
            XCTAssertLessThanOrEqual(inventory.failures, 128)
            XCTAssertLessThanOrEqual(inventory.expensive, 128)
            XCTAssertLessThanOrEqual(renderer.cachedPixels, renderer.pixelBudget)
        }
    }

    /// How many pixels of `image` sit on an edge — neither transparent nor
    /// opaque.
    ///
    /// The measure of whether a picture was *rendered* at its size or blown up
    /// from a smaller one. Rendering leaves a band one pixel wide along the
    /// outline; resampling smears the same outline across as many pixels as it
    /// was magnified by.
    private func edgePixels(of image: CGImage) throws -> Int {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue)
            else { throw RenderFailure(reason: "could not build a probe context") }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return stride(from: 3, to: pixels.count, by: 4)
            .reduce(into: 0) { count, offset in
                if pixels[offset] > 8, pixels[offset] < 247 { count += 1 }
            }
    }

    func testAVectorKeepsItsOwnSizeInTheColumn() throws {
        // A 16-point icon is a 16-point icon. Being able to draw a vector at
        // any size is not a reason to stretch one across the column.
        let directory = try directory(containing: ["icon.svg": circleSVG(size: 16)])
        guard case .success(let content) = makeRenderer().image(
            at: "icon.svg", relativeTo: directory, maxWidth: 400)
        else { return XCTFail("an SVG should load") }

        XCTAssertEqual(content.size.width, 16, accuracy: 0.5)
        XCTAssertEqual(
            try XCTUnwrap(content.cgImage).width, 32,
            "rasterised at the drawn size and the Retina scale, not at the file's own")
    }

    func testAVectorAskedForLargerIsRenderedRatherThanResampled() throws {
        // The whole of what "SVG support" means: a mark written at a nominal
        // 16 points and asked for at 400 has to be *drawn* at 400. Enlarging
        // the 16-point bitmap would look like this test passing — same size,
        // same everything — and be a blur on the page, which is why what is
        // measured here is the outline rather than the size.
        let directory = try directory(containing: ["icon.svg": circleSVG(size: 16)])
        let renderer = makeRenderer()

        guard case .success(let drawn) = renderer.image(
            at: "icon.svg", relativeTo: directory, maxWidth: 800, width: 400)
        else { return XCTFail("an SVG should load") }
        XCTAssertEqual(drawn.size.width, 400, accuracy: 0.5, "the width the note asked for")

        let bitmap = try XCTUnwrap(drawn.cgImage)
        XCTAssertEqual(bitmap.width, 800, "800 pixels for 400 points at the Retina scale")

        // The control: the same file at its own size, enlarged to the same
        // bitmap. Self-anchoring — it is the picture this would have produced
        // had the vector been resampled rather than rendered.
        guard case .success(let small) = renderer.image(
            at: "icon.svg", relativeTo: directory, maxWidth: 16)
        else { return XCTFail("an SVG should load") }
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: bitmap.width, height: bitmap.height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue))
        context.interpolationQuality = .high
        context.draw(
            try XCTUnwrap(small.cgImage),
            in: CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))

        let rendered = try edgePixels(of: bitmap)
        let resampled = try edgePixels(of: try XCTUnwrap(context.makeImage()))
        XCTAssertLessThan(
            rendered, resampled / 4,
            "the outline is smeared over \(rendered) pixels, against \(resampled) for the "
                + "same picture blown up — this vector was resampled, not rendered")
    }

    func testAVectorWithAHugeCanvasIsRasterisedAtTheSizeItIsDrawn() throws {
        // The bound that matters for memory: the nominal size in the file says
        // nothing about how big the picture is on the page, and a 4000-point
        // canvas decoded at its own scale for a 600-point column is 64 times
        // the bitmap anyone asked for.
        let directory = try directory(containing: ["big.svg": circleSVG(size: 4000)])
        guard case .success(let content) = makeRenderer().image(
            at: "big.svg", relativeTo: directory, maxWidth: 600)
        else { return XCTFail("an SVG should load") }

        XCTAssertEqual(content.size.width, 600, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(content.cgImage).width, 1200)
    }

    func testAVectorAskedForAtAnAbsurdSizeIsStillBounded() throws {
        // A note can ask for any width it likes; the bitmap held for it cannot
        // grow without limit. The picture is still drawn at the size asked
        // for — it is the *detail* that gives way.
        let directory = try directory(containing: ["big.svg": circleSVG(size: 100)])
        guard case .success(let content) = makeRenderer().image(
            at: "big.svg", relativeTo: directory, maxWidth: 20_000, width: 20_000)
        else { return XCTFail("an SVG should load") }

        let bitmap = try XCTUnwrap(content.cgImage)
        XCTAssertEqual(content.size.width, 20_000, accuracy: 1)
        XCTAssertLessThanOrEqual(
            bitmap.width * bitmap.height, 17_000_000,
            "\(bitmap.width)x\(bitmap.height) is past the raster cap")
    }

    func testARasterIsNotTreatedAsScalable() throws {
        let directory = try directory(containing: ["icon.svg": circleSVG(size: 16)])
        let renderer = makeRenderer()
        XCTAssertTrue(renderer.isScalable(at: "icon.svg", relativeTo: directory))
        XCTAssertTrue(renderer.isScalable(at: "ICON.SVG", relativeTo: directory))
        XCTAssertFalse(renderer.isScalable(at: "icon.png", relativeTo: directory))
        XCTAssertFalse(renderer.isScalable(at: "icon", relativeTo: directory))
        XCTAssertFalse(
            renderer.isScalable(at: "https://example.com/a.svg", relativeTo: directory),
            "a remote reference resolves to no file at all")
    }

    func testAMalformedVectorFailsRatherThanDrawingNothing() throws {
        let directory = try directory(containing: ["broken.svg": "this is not markup"])
        guard case .failure = makeRenderer().image(
            at: "broken.svg", relativeTo: directory, maxWidth: 400)
        else { return XCTFail("an unreadable SVG should report a failure") }
    }

    // MARK: - A width the note asked for

    func testTheWidthOnABlockReachesTheRender() throws {
        // The wiring an `<img width=…>` depends on: the width travels on the
        // block, through `render(_:)`, to the size the picture is drawn at.
        let directory = try directory(containing: ["icon.svg": circleSVG(size: 400)])
        let request = RenderRequest(
            block: RenderedBlock(kind: .image(alt: ""), source: "icon.svg", width: 72),
            directory: directory,
            context: RenderContext(
                width: 600, dark: false, mathFontSize: 16, textColor: .labelColor))

        guard case .success(let content) = makeRenderer().render(request) else {
            return XCTFail("an SVG should load")
        }
        XCTAssertEqual(content.size.width, 72, accuracy: 0.5)
    }

    func testAWidthPastTheColumnIsStillBoundedByIt() throws {
        let directory = try directory(containing: ["icon.svg": circleSVG(size: 16)])
        guard case .success(let content) = makeRenderer().image(
            at: "icon.svg", relativeTo: directory, maxWidth: 300, width: 900)
        else { return XCTFail("an SVG should load") }
        XCTAssertEqual(content.size.width, 300, accuracy: 0.5)
    }

    func testTheCachedProbeAgreesWithTheRenderForAWidthedImage() throws {
        // `isCached` is what the prefetcher walks past on, so it has to answer
        // about the entry `render` would actually make. Two pictures of one
        // file differing only in the width the note asked for are two entries.
        let directory = try directory(containing: ["icon.svg": circleSVG(size: 400)])
        let renderer = makeRenderer()
        func request(width: CGFloat?) -> RenderRequest {
            RenderRequest(
                block: RenderedBlock(kind: .image(alt: ""), source: "icon.svg", width: width),
                directory: directory,
                context: RenderContext(
                    width: 600, dark: false, mathFontSize: 16, textColor: .labelColor))
        }

        XCTAssertFalse(renderer.isCached(request(width: 72)))
        guard case .success = renderer.render(request(width: 72)) else {
            return XCTFail("an SVG should load")
        }
        XCTAssertTrue(renderer.isCached(request(width: 72)), "the probe missed what it just made")
        XCTAssertFalse(
            renderer.isCached(request(width: 144)),
            "a different width is a different picture")
        XCTAssertFalse(renderer.isCached(request(width: nil)))
    }

    // MARK: - Caching

    func testInvalidFileChurnFillsButNeverExceedsTheFailureCacheBound() throws {
        let directory = try imageDirectory(prefix: "MarkDevImageFailureChurn")
        let renderer = RichContentRenderer()

        for index in 0..<180 {
            let name = "invalid-\(index).png"
            try Data("not a PNG \(index)".utf8)
                .write(to: directory.appendingPathComponent(name))
            guard case .failure = renderer.image(
                at: name,
                relativeTo: directory,
                maxWidth: 400)
            else { return XCTFail("\(name) must be a genuine decode failure") }

            XCTAssertEqual(
                renderer.cacheInventoryForTesting.failures,
                min(index + 1, 128),
                "failure churn must reach and then stay at the cache ceiling")
        }
        XCTAssertEqual(renderer.cacheInventoryForTesting.successes, 0)
        XCTAssertEqual(renderer.cacheInventoryForTesting.failures, 128)
    }

    func testCacheRetainedSourceBytesStayWithinTheConfiguredBudget() {
        let sourceBudget = 24_000
        let renderer = RichContentRenderer(retainedSourceByteBudget: sourceBudget)
        let payload = String(repeating: "x", count: 4_000)

        for index in 0..<48 {
            guard case .failure = renderer.math(
                "\\frac{\(payload)\(index)",
                fontSize: 16,
                color: .labelColor,
                display: true)
            else { return XCTFail("the malformed bounded formula should fail") }
            XCTAssertLessThanOrEqual(
                renderer.cacheInventoryForTesting.retainedSourceBytes,
                sourceBudget,
                "count-bounded keys still need a byte bound")
        }
        XCTAssertGreaterThan(renderer.cacheInventoryForTesting.failures, 0)
    }

    func testResultsAreCachedAndInvalidatable() {
        let renderer = makeRenderer()
        guard case .success(let first) = renderer.math(
            "a + b", fontSize: 14, color: .labelColor, display: false),
            case .success(let second) = renderer.math(
                "a + b", fontSize: 14, color: .labelColor, display: false)
        else { return XCTFail("formula should typeset") }

        XCTAssertTrue(first.image === second.image, "a repeat request should hit the cache")

        renderer.invalidate()
        guard case .success(let third) = renderer.math(
            "a + b", fontSize: 14, color: .labelColor, display: false)
        else { return XCTFail("formula should typeset after invalidation") }
        XCTAssertFalse(first.image === third.image, "invalidate should drop the cache")
    }

    func testFailuresAreCachedToo() {
        // Retrying a broken formula on every restyle would put a failing
        // parse on the keystroke path.
        let renderer = makeRenderer()
        guard case .failure(let first) = renderer.math(
            "\\frac{1", fontSize: 14, color: .labelColor, display: false),
            case .failure(let second) = renderer.math(
                "\\frac{1", fontSize: 14, color: .labelColor, display: false)
        else { return XCTFail("invalid latex should fail") }
        XCTAssertEqual(first, second)
    }
}
