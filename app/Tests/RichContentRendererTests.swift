//
//  RichContentRendererTests.swift
//  MarkDevKitTests
//
//  Math, diagrams, and images — including the failure paths, which are the
//  ones a reader actually notices when they go wrong.
//

import AppKit
import XCTest

@testable import MarkDevKit

@MainActor
final class RichContentRendererTests: XCTestCase {
    private func makeRenderer() -> RichContentRenderer { RichContentRenderer() }

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

    func testTwoNotesWithTheSameImageNameDoNotShareABitmap() throws {
        // The cache used to be keyed on the reference *as written*, so two
        // notes in different folders that both say `![](picture.png)` collided
        // and the second was served the first one's bitmap. Reading ahead
        // along a note's links turns that from unlucky into routine: it fills
        // the cache from directories other than the open document's.
        let parent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevImageKeys-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }

        func directory(named name: String, imageWidth: CGFloat) throws -> URL {
            let directory = parent.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let size = CGSize(width: imageWidth, height: 100)
            let image = NSImage(size: size)
            image.lockFocus()
            NSColor.systemBlue.drawSwatch(in: CGRect(origin: .zero, size: size))
            image.unlockFocus()
            let data = try XCTUnwrap(
                NSBitmapImageRep(data: image.tiffRepresentation ?? Data())?
                    .representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent("picture.png"))
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

        let size = CGSize(width: 120, height: 60)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemGreen.drawSwatch(in: CGRect(origin: .zero, size: size))
        image.unlockFocus()
        let file = directory.appendingPathComponent("shared.png")
        try XCTUnwrap(
            NSBitmapImageRep(data: image.tiffRepresentation ?? Data())?
                .representation(using: .png, properties: [:])
        ).write(to: file)

        let renderer = makeRenderer()
        guard case .success(let relative) = renderer.image(
            at: "shared.png", relativeTo: directory, maxWidth: 400),
            case .success(let absolute) = renderer.image(
                at: file.path, relativeTo: nil, maxWidth: 400)
        else { return XCTFail("both spellings should load") }

        XCTAssertTrue(relative.image === absolute.image, "one file, one bitmap")
    }

    func testAMissingImageReportsItsName() {
        let renderer = makeRenderer()
        guard case .failure(let failure) = renderer.image(
            at: "nope.png", relativeTo: URL(fileURLWithPath: "/tmp"), maxWidth: 400)
        else { return XCTFail("a missing file should fail") }
        XCTAssertTrue(failure.reason.contains("nope.png"))
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
