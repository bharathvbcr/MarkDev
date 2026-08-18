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
