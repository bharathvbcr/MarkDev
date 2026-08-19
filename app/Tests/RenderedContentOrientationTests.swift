//
//  RenderedContentOrientationTests.swift
//  MarkDevKitTests
//
//  Which way up a rendered block comes out.
//
//  Every other test of this path asserts a *size*, which is why a diagram that
//  rendered perfectly and upside down passed all of them. Orientation is the
//  one property a bitmap pipeline loses silently: nothing throws, nothing
//  measures short, and the picture is wrong.
//
//  These tests cover all three kinds of rendered content, because the flip is
//  a property of the pipeline rather than of Mermaid — math and embedded
//  images cross the same boundary and are drawn by the same fragment.
//

import AppKit
import BeautifulMermaid
import XCTest

@testable import MarkDevKit

/// A rasterised block, measured in rows from the top of the picture down.
private struct InkProfile {
    let width: Int
    let height: Int
    /// Pixels differing from the background, per row, topmost row first.
    let coverage: [Int]
    /// The horizontal extent of ink on each row, topmost row first.
    let extent: [Int]

    /// Where the widest row of the picture sits, as a fraction from the top.
    /// 0 is the top edge, 1 the bottom.
    ///
    /// Diagrams are mostly padding, so a fixed band near an edge measures
    /// background and says nothing. Locating a *feature* — the row the widest
    /// thing in the picture crosses — is what pins the orientation.
    var widestRow: Double { position(of: extent) }

    /// Where the densest row sits, as a fraction from the top.
    var densestRow: Double { position(of: coverage) }

    /// The vertical centre of mass of the ink, as a fraction from the top.
    var centroid: Double {
        let total = coverage.reduce(0, +)
        guard total > 0 else { return 0.5 }
        let weighted = coverage.enumerated()
            .reduce(0.0) { $0 + Double($1.offset) * Double($1.element) }
        return weighted / Double(total) / Double(max(1, height - 1))
    }

    /// The midpoint of every row tying for the maximum, so a feature spanning
    /// many rows reports its centre rather than whichever edge came first.
    private func position(of rows: [Int]) -> Double {
        guard let peak = rows.max(), peak > 0 else { return 0.5 }
        let hits = rows.indices.filter { rows[$0] == peak }
        let middle = Double(hits.reduce(0, +)) / Double(hits.count)
        return middle / Double(max(1, height - 1))
    }
}

@MainActor
final class RenderedContentOrientationTests: XCTestCase {

    // MARK: - Flowchart

    func testATopDownFlowchartDrawsItsFirstNodeAtTheTop() throws {
        // The bug this guards: BeautifulMermaid's AppKit image path rasterises
        // into a raw CGContext, whose origin is at the bottom, while its
        // DiagramRenderer draws in a top-left space. Every diagram came out
        // mirrored top to bottom.
        let source = """
            flowchart TD
              Wide[WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW] --> Narrow[i]
            """

        // Ground truth is the library's own layout, not an assumption about
        // Mermaid: `y` grows downward, so the node at the smaller `y` is the
        // one the reader has to see on top.
        let graph = try MermaidRenderer.layout(source)
        guard case .flowchart(let nodes, _, _) = graph.content, nodes.count == 2 else {
            return XCTFail("expected a two-node flowchart")
        }
        let wide = try XCTUnwrap(nodes.max { $0.width < $1.width })
        let narrow = try XCTUnwrap(nodes.min { $0.width < $1.width })
        XCTAssertLessThan(wide.y, narrow.y, "layout should place the wide node above the narrow one")

        // The wide node is a near-full-width box and the narrow one is a few
        // points across, so the widest row of the picture is the one crossing
        // the wide node. It belongs in the top half.
        let profile = try renderDiagram(source, maxWidth: 600)
        XCTAssertLessThan(
            profile.widestRow, 0.5,
            "the wide node is above in layout, so the widest row must be in the top half "
                + "(found at \(profile.widestRow) of the way down)")
    }

    func testABottomUpFlowchartDrawsItsFirstNodeAtTheBottom() throws {
        // The mirror of the test above. A renderer that flipped *everything*
        // would satisfy one of these and fail the other, so the pair pins the
        // orientation rather than merely detecting that it is consistent.
        let source = """
            flowchart BT
              Wide[WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW] --> Narrow[i]
            """

        let graph = try MermaidRenderer.layout(source)
        guard case .flowchart(let nodes, _, _) = graph.content, nodes.count == 2 else {
            return XCTFail("expected a two-node flowchart")
        }
        let wide = try XCTUnwrap(nodes.max { $0.width < $1.width })
        let narrow = try XCTUnwrap(nodes.min { $0.width < $1.width })
        XCTAssertGreaterThan(wide.y, narrow.y, "BT should place the wide node below")

        let profile = try renderDiagram(source, maxWidth: 600)
        XCTAssertGreaterThan(
            profile.widestRow, 0.5,
            "the wide node is below in layout, so the widest row must be in the bottom half "
                + "(found at \(profile.widestRow) of the way down)")
    }

    // MARK: - Sequence

    func testASequenceDiagramDrawsItsParticipantsAtTheTop() throws {
        // The reported symptom: a sequence diagram whose participant boxes sat
        // along the bottom edge with the messages running upward.
        let source = """
            sequenceDiagram
              participant Frontend
              participant Gateway
              Frontend->>Gateway: request
              Gateway-->>Frontend: response
            """

        let graph = try MermaidRenderer.layout(source)
        guard case .sequenceDiagram(let actors, _, _, let lifelines, _, _) = graph.content,
            let actor = actors.first, let lifeline = lifelines.first
        else { return XCTFail("expected a sequence diagram with actors and lifelines") }
        XCTAssertLessThan(
            actor.y, lifeline.bottomY,
            "layout should hang lifelines below the participant boxes")

        // Participant boxes are filled rectangles; everything below them is
        // hairlines and message labels. The densest row of the picture is
        // therefore inside the row of boxes, and it belongs at the top.
        let profile = try renderDiagram(source, maxWidth: 600)
        XCTAssertLessThan(
            profile.densestRow, 0.5,
            "participant boxes must be at the top "
                + "(densest row at \(profile.densestRow) of the way down)")
    }

    // MARK: - Charts

    func testBarsGrowUpwardFromTheAxis() throws {
        // "Charts" in the report are Mermaid's xychart, which goes through the
        // same rasteriser. Two charts differing only in bar height isolate the
        // bars from the axes, labels, and title, which are identical in both.
        let short = """
            xychart-beta
              y-axis 0 --> 100
              bar [3, 3, 3, 3]
            """
        let tall = """
            xychart-beta
              y-axis 0 --> 100
              bar [97, 97, 97, 97]
            """

        let shortProfile = try renderDiagram(short, maxWidth: 600)
        let tallProfile = try renderDiagram(tall, maxWidth: 600)

        XCTAssertLessThan(
            tallProfile.centroid, shortProfile.centroid,
            "taller bars must put more ink higher up the picture "
                + "(tall \(tallProfile.centroid), short \(shortProfile.centroid))")
    }

    // MARK: - Math

    func testASuperscriptSitsAboveTheSameTermAsASubscript() throws {
        // Math crosses the same boundary by a different route — an NSView
        // cached into a bitmap rep rather than a CGContext — so it needs its
        // own witness rather than an argument that it is probably fine.
        //
        // The two formulae differ only in whether the heavy term is raised or
        // lowered, so comparing them measures the *direction* the typesetter's
        // vertical axis runs without depending on where a baseline lands or on
        // how much of the picture is padding. A flip swaps the pair.
        //
        // A fraction is the obvious thing to reach for here and is the wrong
        // tool: its rule is the widest row in the picture and sits at the
        // vertical centre, so it reports ~0.5 whichever way up the glyphs are.
        guard case .success(let raised) = RichContentRenderer().math(
            "X^{WWWW}", fontSize: 28, color: .white, display: true),
            case .success(let lowered) = RichContentRenderer().math(
                "X_{WWWW}", fontSize: 28, color: .white, display: true)
        else { return XCTFail("both formulae should typeset") }

        let above = try measure(raised).centroid
        let below = try measure(lowered).centroid
        XCTAssertLessThan(
            above, below - 0.1,
            "a superscript must sit decisively higher than the same subscript "
                + "(raised \(above), lowered \(below))")
    }

    // MARK: - Embedded images

    func testAnEmbeddedImageKeepsTheOrientationOfTheFileOnDisk() throws {
        // Self-anchoring: rather than assert which half of the picture is
        // bright — which would only restate how this test wrote the file — it
        // measures the file's own bitmap and requires the rendered one to
        // agree with it.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevOrientation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = try halfAndHalfImage(width: 120, height: 80)
        let data = try XCTUnwrap(
            NSBitmapImageRep(cgImage: source).representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent("halves.png"))

        let expected = try measure(RenderedContent(cgImage: source, size: CGSize(width: 120, height: 80)))
        XCTAssertGreaterThan(
            abs(expected.centroid - 0.5), 0.15,
            "the fixture must be decisively lopsided or it cannot detect a flip")

        guard case .success(let loaded) = RichContentRenderer().image(
            at: "halves.png", relativeTo: directory, maxWidth: 600)
        else { return XCTFail("a local image should load") }

        let actual = try measure(loaded)
        XCTAssertEqual(
            actual.centroid, expected.centroid, accuracy: 0.1,
            "the loaded image must sit the same way up as the file it came from")
    }

    func testAVectorIsRasterisedTheRightWayUp() throws {
        // Nothing else in the vector path asserts orientation: every other
        // test of it measures a *size*, and a picture rendered perfectly and
        // upside down has exactly the size it should. This is the same trap
        // the Mermaid image path fell into — a raw `CGContext` has its origin
        // at the bottom left, and whether AppKit takes that into account when
        // it draws into one is AppKit's business rather than something to
        // assume.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevOrientation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // A band across the top fifth, clear of the corners: the probe reads
        // its background from the top-left pixel, so a fixture whose ink
        // starts there would have the probe measuring the picture inside out.
        try """
            <svg xmlns="http://www.w3.org/2000/svg" width="100" height="100" \
            viewBox="0 0 100 100"><rect width="100" height="100" fill="white"/>\
            <rect x="10" y="10" width="80" height="20" fill="black"/></svg>
            """
            .write(
                to: directory.appendingPathComponent("banded.svg"), atomically: true,
                encoding: .utf8)

        guard case .success(let content) = RichContentRenderer().image(
            at: "banded.svg", relativeTo: directory, maxWidth: 200, width: 200)
        else { return XCTFail("an SVG should load") }

        let profile = try measure(content)
        XCTAssertLessThan(
            profile.centroid, 0.35,
            "the band is at the top of the file and must be at the top of the picture "
                + "(centroid \(profile.centroid))")
    }

    /// A bitmap whose halves differ, for detecting a vertical flip.
    ///
    /// Built through a `CGContext` rather than `NSImage.lockFocus` so that the
    /// fixture does not itself depend on the convention under test.
    private func halfAndHalfImage(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height) / 2))
        return try XCTUnwrap(context.makeImage())
    }

    // MARK: - Probe

    private func renderDiagram(
        _ source: String,
        maxWidth: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> InkProfile {
        guard case .success(let content) = RichContentRenderer().diagram(
            source, maxWidth: maxWidth, dark: true)
        else {
            XCTFail("diagram should render", file: file, line: line)
            throw RenderFailure(reason: "did not render")
        }
        return try measure(content, file: file, line: line)
    }

    /// Measures `content` the way the reader sees it.
    ///
    /// The picture is composed through the same transform
    /// `MarkdownLayoutFragment.drawRenderedContent` uses, into a context
    /// flipped the way TextKit hands one to a layout fragment. What this
    /// measures is therefore what lands on screen, not what the renderer
    /// believes it produced.
    private func measure(
        _ content: RenderedContent,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> InkProfile {
        let image = try XCTUnwrap(content.cgImage, file: file, line: line)
        let width = max(1, Int(content.size.width.rounded()))
        let height = max(1, Int(content.size.height.rounded()))
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

        try pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue)
            else { throw RenderFailure(reason: "could not build a probe context") }

            // Become the top-left space TextKit lays fragments out in. A bitmap
            // context's own origin is at the bottom, so without this the probe
            // would measure a mirror of the fragment's space and agree with a
            // renderer that was upside down.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)

            let rect = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
            context.translateBy(x: 0, y: rect.midY)
            context.scaleBy(x: 1, y: -1)
            context.translateBy(x: 0, y: -rect.midY)
            context.draw(image, in: rect)
        }

        // Row 0 of the buffer is the top-left of the picture, and the flip
        // above put the fragment's y=0 there — so these rows read top-down.
        let background = (Int(pixels[0]), Int(pixels[1]), Int(pixels[2]))
        var coverage: [Int] = []
        var extent: [Int] = []
        coverage.reserveCapacity(height)
        extent.reserveCapacity(height)

        for row in 0..<height {
            var count = 0
            var first = -1
            var last = -1
            for column in 0..<width {
                let offset = row * bytesPerRow + column * 4
                let distance =
                    abs(Int(pixels[offset]) - background.0)
                    + abs(Int(pixels[offset + 1]) - background.1)
                    + abs(Int(pixels[offset + 2]) - background.2)
                if distance > 24 {
                    count += 1
                    if first < 0 { first = column }
                    last = column
                }
            }
            coverage.append(count)
            extent.append(first < 0 ? 0 : last - first + 1)
        }

        let inked = coverage.reduce(0, +)
        XCTAssertGreaterThan(inked, 0, "the block drew nothing", file: file, line: line)
        XCTAssertLessThan(
            inked, width * height,
            "every pixel differs from the corner, so the corner is not background",
            file: file, line: line)

        return InkProfile(width: width, height: height, coverage: coverage, extent: extent)
    }
}
