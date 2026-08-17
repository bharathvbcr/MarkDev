//
//  RichContentHardeningTests.swift
//  MarkDevKitTests
//
//  What the rendering path does when the input is hostile, degenerate, or
//  simply enormous.
//
//  The orientation suite proves the picture comes out the right way up. This
//  one proves nothing here can take the app down on the way: a note is
//  untrusted input, and a diagram that crashes the editor is a worse outcome
//  than one that refuses to draw.
//

import AppKit
import BeautifulMermaid
import XCTest

@testable import MarkDevKit

@MainActor
final class RichContentHardeningTests: XCTestCase {
    private func makeRenderer() -> RichContentRenderer { RichContentRenderer() }

    /// Mirrors `RichContentRenderer.maxRasterPixels`. Kept as a literal rather
    /// than read from the type, so that raising the cap has to be a deliberate
    /// edit here too instead of silently taking the assertion with it.
    private let rasterCap = 16_000_000

    // MARK: - Every diagram type

    func testEverySupportedDiagramTypeRenders() throws {
        // `MermaidRenderer.supportedDiagramTypes` is the library's own list, so
        // a type added by an upgrade shows up here as a failure rather than as
        // a silent gap in coverage.
        let sources: [DiagramType: String] = [
            .flowchart: "flowchart TD\n  A[Start] --> B[End]",
            .stateDiagram: "stateDiagram-v2\n  [*] --> Idle\n  Idle --> Busy\n  Busy --> [*]",
            .sequenceDiagram: "sequenceDiagram\n  Alice->>Bob: Hello\n  Bob-->>Alice: Hi",
            .classDiagram: "classDiagram\n  class Note {\n    +String title\n    +save()\n  }\n  Note <|-- Draft",
            .erDiagram: "erDiagram\n  VAULT ||--o{ NOTE : contains\n  NOTE ||--o{ LINK : has",
            .xyChart: "xychart-beta\n  y-axis 0 --> 100\n  bar [10, 40, 90]",
        ]

        for type in MermaidRenderer.supportedDiagramTypes {
            let source = try XCTUnwrap(
                sources[type], "no fixture for \(type) — a new diagram type needs coverage here")
            guard case .success(let content) = makeRenderer().diagram(
                source, maxWidth: 600, dark: true)
            else { return XCTFail("\(type) should render") }

            XCTAssertGreaterThan(content.size.width, 0, "\(type) drew nothing")
            XCTAssertGreaterThan(content.size.height, 0, "\(type) drew nothing")
            assertBounded(content, what: "\(type)")
        }
    }

    func testEverySupportedDiagramTypeIsDrawnTheRightWayUp() throws {
        // Orientation is a property of the rasteriser, not of one diagram type,
        // so it is checked for all of them against the same ground truth: the
        // library's layout is top-left, so the ink the *layout* puts in its top
        // half must land in the top half of the picture.
        let sources: [DiagramType: String] = [
            .flowchart: "flowchart TD\n  A[AAAAAAAAAAAAAAAAAAAAAAAA] --> B[b]",
            .stateDiagram: "stateDiagram-v2\n  [*] --> LongRunningStateName\n  LongRunningStateName --> b",
            .sequenceDiagram: "sequenceDiagram\n  participant Alice\n  participant Bob\n  Alice->>Bob: hi",
            .classDiagram: "classDiagram\n  class Note {\n    +String title\n  }",
            .erDiagram: "erDiagram\n  VAULT ||--o{ NOTE : contains",
            .xyChart: "xychart-beta\n  y-axis 0 --> 100\n  bar [99, 99, 99]",
        ]

        for type in MermaidRenderer.supportedDiagramTypes {
            let source = try XCTUnwrap(sources[type], "no fixture for \(type)")
            let drawn = try inkCentroid(of: source)
            let laidOut = try layoutCentroid(of: source)
            XCTAssertEqual(
                drawn, laidOut, accuracy: 0.25,
                "\(type): the layout puts its weight at \(laidOut) of the way down, "
                    + "so the picture must too — drew it at \(drawn)")
        }
    }

    // MARK: - Hostile sources

    func testHostileDiagramSourcesFailWithoutCrashing() {
        // Every one of these is something a note can contain. None may crash,
        // hang, or come back as a success with a degenerate size — a zero-sized
        // bitmap reaches TextKit as a fragment measurement.
        let sources: [String] = [
            "",
            "   ",
            "\n\n\n",
            "\u{0}\u{1}\u{2}",
            "flowchart",
            "flowchart TD",
            "flowchart TD\n",
            "flowchart TD\n  A",
            "flowchart TD\n  A -->",
            "flowchart TD\n  --> B",
            "flowchart TD\n  A --> A",
            "flowchart TD\n  A[\"unclosed",
            "flowchart TD\n  A[]] --> B",
            "sequenceDiagram\n  ->>: ",
            "sequenceDiagram\n  A->>B:",
            "classDiagram\n  class",
            "erDiagram\n  ||--o{",
            "xychart-beta",
            "xychart-beta\n  bar []",
            "xychart-beta\n  y-axis 0 --> 0\n  bar [1]",
            "xychart-beta\n  bar [nan, inf]",
            "xychart-beta\n  y-axis 100 --> 0\n  bar [50]",
            "gantt\n  title X",
            "pie\n  \"A\" : 1",
            "mindmap\n  root",
            "flowchart TD\n  A[\u{1F600}\u{1F1EF}\u{1F1F5}] --> B[\u{202E}reversed]",
            "flowchart TD\n  A[" + String(repeating: "x", count: 5_000) + "] --> B[b]",
            "flowchart TD\n  " + String(repeating: "A", count: 2_000),
            String(repeating: "flowchart TD\n", count: 500),
            "flowchart TD\n  A --> B\n" + String(repeating: "  %% comment\n", count: 2_000),
        ]

        for source in sources {
            let label = source.prefix(40).debugDescription
            switch makeRenderer().diagram(source, maxWidth: 600, dark: true) {
            case .success(let content):
                XCTAssertTrue(
                    content.size.width.isFinite && content.size.height.isFinite,
                    "\(label) produced a non-finite size")
                XCTAssertGreaterThan(content.size.width, 0, "\(label) produced a zero width")
                XCTAssertGreaterThan(content.size.height, 0, "\(label) produced a zero height")
                assertBounded(content, what: label)
            case .failure(let failure):
                XCTAssertFalse(failure.reason.isEmpty, "\(label) failed without saying why")
            }
        }
    }

    func testHostileLatexFailsWithoutCrashing() {
        let sources = [
            "", "   ", "\\", "\\\\", "{", "}", "\\frac", "\\frac{}{}", "\\frac{1",
            "\\begin{matrix}", "^", "_", "x^", "\\sqrt{", "\u{0}",
            "\\" + String(repeating: "frac{1}{", count: 200) + String(repeating: "}", count: 200),
            String(repeating: "x^2 + ", count: 5_000) + "1",
            "\u{1F600}", "\\text{\u{202E}}",
        ]

        for source in sources {
            let label = source.prefix(40).debugDescription
            switch makeRenderer().math(source, fontSize: 16, color: .white, display: true) {
            case .success(let content):
                XCTAssertTrue(
                    content.size.width.isFinite && content.size.height.isFinite,
                    "\(label) produced a non-finite size")
            case .failure(let failure):
                XCTAssertFalse(failure.reason.isEmpty, "\(label) failed without saying why")
            }
        }
    }

    // MARK: - Nonsense numbers

    func testNonsenseDimensionsFailRatherThanTrap() {
        // `Int(_:)` traps on a NaN and past `Int.max`, and the cache key is
        // derived from the caller's number before anything validates it. This
        // is a public API; every one of these once reached that conversion.
        let widths: [CGFloat] = [
            .nan, .infinity, -.infinity, .greatestFiniteMagnitude,
            -.greatestFiniteMagnitude, 0, -1, -1e18, 0.5, 1e18,
        ]

        for width in widths {
            switch makeRenderer().diagram("flowchart TD\n  A --> B", maxWidth: width, dark: true) {
            case .success(let content):
                XCTAssertTrue(
                    content.size.width.isFinite && content.size.height.isFinite,
                    "width \(width) produced a non-finite size")
                XCTAssertGreaterThan(content.size.width, 0)
            case .failure(let failure):
                XCTAssertFalse(failure.reason.isEmpty, "width \(width) failed without saying why")
            }

            switch makeRenderer().image(at: "x.png", relativeTo: nil, maxWidth: width) {
            case .success: XCTFail("a relative path with no base cannot resolve")
            case .failure(let failure): XCTAssertFalse(failure.reason.isEmpty)
            }
        }

        for size: CGFloat in [.nan, .infinity, -.infinity, 0, -12, 1e18, .greatestFiniteMagnitude] {
            switch makeRenderer().math("x^2", fontSize: size, color: .white, display: true) {
            case .success(let content):
                XCTAssertTrue(content.size.width.isFinite && content.size.height.isFinite)
            case .failure(let failure):
                XCTAssertFalse(failure.reason.isEmpty, "size \(size) failed without saying why")
            }
        }
    }

    // MARK: - Bounded work

    func testATallDiagramIsRasterisedWithinTheMemoryBound() throws {
        // The drawn size is bounded by the column, but the *layout* is not. A
        // long top-down chain lays out tens of thousands of points tall; before
        // the bound it was rasterised at full size, which is hundreds of
        // megabytes for a picture drawn a few hundred points wide.
        let chain = (0..<220).map { "  N\($0) --> N\($0 + 1)" }.joined(separator: "\n")
        guard case .success(let content) = makeRenderer().diagram(
            "flowchart TD\n" + chain, maxWidth: 600, dark: true)
        else { return XCTFail("a long chain should still render") }

        let image = try XCTUnwrap(content.cgImage)
        XCTAssertGreaterThan(
            content.size.height, content.size.width,
            "the fixture must actually be tall or it proves nothing")
        assertBounded(content, what: "tall chain")
        XCTAssertGreaterThan(image.width, 0)
        XCTAssertGreaterThan(image.height, 0)
    }

    func testAWideDiagramIsScaledToTheColumnRatherThanClipped() {
        let chain = (0..<40).map { "  N\($0) --> N\($0 + 1)" }.joined(separator: "\n")
        guard case .success(let content) = makeRenderer().diagram(
            "flowchart LR\n" + chain, maxWidth: 300, dark: true)
        else { return XCTFail("a wide flowchart should render") }

        XCTAssertLessThanOrEqual(content.size.width, 300.5)
        assertBounded(content, what: "wide chain")
    }

    // MARK: - Caching

    func testAppearanceAndWidthProduceDifferentPictures() throws {
        let renderer = makeRenderer()
        // Wide enough to actually be scaled by both columns. A diagram narrower
        // than its column is left alone rather than stretched, so a small
        // fixture would compare two identical sizes and prove nothing.
        let source = "flowchart LR\n"
            + (0..<10).map { "  N\($0) --> N\($0 + 1)" }.joined(separator: "\n")

        guard case .success(let dark) = renderer.diagram(source, maxWidth: 600, dark: true),
            case .success(let light) = renderer.diagram(source, maxWidth: 600, dark: false),
            case .success(let narrow) = renderer.diagram(source, maxWidth: 200, dark: true),
            case .success(let again) = renderer.diagram(source, maxWidth: 600, dark: true)
        else { return XCTFail("all four should render") }

        XCTAssertGreaterThan(
            dark.size.width, 400, "the fixture must be wide enough for the column to bite")

        XCTAssertTrue(dark.image === again.image, "a repeat request should hit the cache")
        XCTAssertFalse(
            dark.image === light.image, "light and dark must not share a cached bitmap")
        XCTAssertLessThan(narrow.size.width, dark.size.width, "a narrower column must redraw")
    }

    func testAFormulaIsCachedPerColourNotPerAppearance() throws {
        // The key recorded the ambient appearance, not the ink the caller
        // asked for, so the same formula in two colours collided and the
        // second request was served the first one's bitmap.
        let renderer = makeRenderer()
        guard case .success(let red) = renderer.math(
            "x^2", fontSize: 20, color: .systemRed, display: true),
            case .success(let blue) = renderer.math(
                "x^2", fontSize: 20, color: .systemBlue, display: true),
            case .success(let redAgain) = renderer.math(
                "x^2", fontSize: 20, color: .systemRed, display: true)
        else { return XCTFail("all three should typeset") }

        XCTAssertTrue(red.image === redAgain.image, "the same colour should hit the cache")
        XCTAssertFalse(
            red.image === blue.image, "a different colour must not reuse the bitmap")
    }

    func testTheCacheIsBoundedAndStillCorrect() throws {
        // A long document full of diagrams must not pin every bitmap it has
        // scrolled past — and eviction must not hand back the wrong picture.
        let renderer = makeRenderer()
        for index in 0..<200 {
            guard case .success = renderer.diagram(
                "flowchart TD\n  A\(index) --> B\(index)", maxWidth: 600, dark: true)
            else { return XCTFail("diagram \(index) should render") }
        }

        // The first entries are evicted by now; asking again must re-render
        // rather than return whatever inherited their slot.
        guard case .success(let refreshed) = renderer.diagram(
            "flowchart TD\n  A0 --> B0", maxWidth: 600, dark: true)
        else { return XCTFail("an evicted diagram should re-render") }
        XCTAssertGreaterThan(refreshed.size.width, 0)
    }

    // MARK: - Determinism

    func testTheSameSourceAlwaysProducesTheSameBitmap() throws {
        // The graph layout is deterministic by design, and the rasteriser must
        // not undo that: a diagram that redraws differently on each restyle
        // makes the editor shimmer as the reader types.
        let source = "flowchart TD\n  A[Start] --> B[Middle]\n  B --> C[End]"
        let first = try XCTUnwrap(bytes(of: source))
        for _ in 0..<5 {
            XCTAssertEqual(first, try XCTUnwrap(bytes(of: source)), "a redraw must be identical")
        }
    }

    // MARK: - Randomised properties

    func testTheWideNodeIsDrawnWhereTheLayoutPutsItForEverySeed() throws {
        // A fixed fixture can be satisfied by a constant. Here the answer moves
        // with the seed: one node of a chain is made wide, and the widest row
        // of the picture has to land where *that* node sits — near the top when
        // it is first, near the bottom when it is last. A mirrored renderer
        // fails every seed whose node is not exactly in the middle.
        var failures: [String] = []

        for seed in 1...40 {
            var random = SeededGenerator(seed: UInt64(seed))
            let count = Int.random(in: 3...6, using: &random)
            let wideIndex = Int.random(in: 0..<count, using: &random)

            let labels = (0..<count).map { index in
                index == wideIndex
                    ? "N\(index)[WWWWWWWWWWWWWWWWWWWWWWWWWWWWWW]" : "N\(index)[\(index)]"
            }
            let source = "flowchart TD\n"
                + (0..<(count - 1))
                .map { "  \(labels[$0]) --> \(labels[$0 + 1])" }
                .joined(separator: "\n")

            let graph = try MermaidRenderer.layout(source)
            guard case .flowchart(let nodes, _, _) = graph.content, graph.height > 0,
                let wide = nodes.max(by: { $0.width < $1.width })
            else {
                failures.append("seed \(seed): no layout")
                continue
            }
            let expected = (wide.y + wide.height / 2) / graph.height
            let drawn = try widestRowPosition(of: source)

            if abs(drawn - expected) > 0.15 {
                failures.append(
                    "seed \(seed): \(count) nodes, wide one at index \(wideIndex) — "
                        + "layout says \(expected), drew it at \(drawn)")
            }
        }

        XCTAssertEqual(
            failures, [], "the widest node must be drawn where the layout puts it")
    }

    func testGeneratedSourcesNeverCrashOrRunAway() throws {
        // Fuzzing for safety rather than for looks: a note is untrusted input.
        // Whatever comes out must be a failure that says why, or a picture with
        // a finite, positive, bounded size.
        let headers = [
            "flowchart TD", "flowchart LR", "flowchart BT", "stateDiagram-v2",
            "sequenceDiagram", "classDiagram", "erDiagram", "xychart-beta",
            "gantt", "pie", "", "flowchart",
        ]
        let fragments = [
            "A --> B", "A", "-->", "A[", "A[]", "A[\"x\"]", "A --> ", " --> B",
            "A ->> B: hi", "participant P", "class C { +x() }", "E ||--o{ F : g",
            "bar [1, 2, 3]", "y-axis 0 --> 100", "%% comment", "\t\t", "   ",
            "A[\u{1F600}\u{202E}]", "A[" + String(repeating: "z", count: 300) + "]",
            "A --> B --> C --> D", "subgraph S", "end", "[*] --> S",
        ]

        for seed in 1...120 {
            var random = SeededGenerator(seed: UInt64(seed) &* 7919)
            let header = headers.randomElement(using: &random) ?? ""
            let lines = (0..<Int.random(in: 0...12, using: &random)).map { _ in
                "  " + (fragments.randomElement(using: &random) ?? "")
            }
            let source = ([header] + lines).joined(separator: "\n")

            switch makeRenderer().diagram(source, maxWidth: 600, dark: seed.isMultiple(of: 2)) {
            case .success(let content):
                XCTAssertTrue(
                    content.size.width.isFinite && content.size.height.isFinite,
                    "seed \(seed) produced a non-finite size from:\n\(source)")
                XCTAssertGreaterThan(
                    content.size.width, 0, "seed \(seed) produced a zero width from:\n\(source)")
                XCTAssertGreaterThan(
                    content.size.height, 0, "seed \(seed) produced a zero height from:\n\(source)")
                assertBounded(content, what: "seed \(seed)")
            case .failure(let failure):
                XCTAssertFalse(
                    failure.reason.isEmpty, "seed \(seed) failed without saying why")
            }
        }
    }

    // MARK: - Helpers

    /// Fails if a bitmap is larger than the rasteriser promises to allocate.
    private func assertBounded(
        _ content: RenderedContent,
        what: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let image = content.cgImage else {
            return XCTFail("\(what) carried no bitmap", file: file, line: line)
        }
        XCTAssertLessThanOrEqual(
            image.width * image.height, rasterCap + image.width + image.height,
            "\(what) rasterised \(image.width)x\(image.height), past the bound",
            file: file, line: line)
    }

    /// The rendered bytes of a diagram, for comparing two renders.
    private func bytes(of source: String) throws -> Data {
        guard case .success(let content) = makeRenderer().diagram(
            source, maxWidth: 600, dark: true)
        else { throw RenderFailure(reason: "did not render") }
        let image = try XCTUnwrap(content.cgImage)
        return try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }

    /// Where the widest row of the picture sits, as a fraction from the top.
    private func widestRowPosition(of source: String) throws -> Double {
        let rows = try inkRows(of: source)
        var widest: [Int] = []
        var peak = 0
        for (index, row) in rows.extents.enumerated() {
            if row > peak {
                peak = row
                widest = [index]
            } else if row == peak, peak > 0 {
                widest.append(index)
            }
        }
        guard !widest.isEmpty else { throw RenderFailure(reason: "drew nothing") }
        let middle = Double(widest.reduce(0, +)) / Double(widest.count)
        return middle / Double(max(1, rows.height - 1))
    }

    /// Where the picture's ink sits vertically, as a fraction from the top.
    private func inkCentroid(of source: String) throws -> Double {
        let rows = try inkRows(of: source)
        var weighted = 0.0
        var total = 0.0
        for (index, count) in rows.coverages.enumerated() {
            weighted += Double(index) * Double(count)
            total += Double(count)
        }
        guard total > 0 else { throw RenderFailure(reason: "drew nothing") }
        return weighted / total / Double(max(1, rows.height - 1))
    }

    /// Scans a rendered diagram row by row, topmost row first.
    ///
    /// Unlike the orientation suite's probe this reads the bitmap directly
    /// rather than composing it through the fragment's transform — a `CGImage`
    /// stores its rows top-down, and drawing it into an untouched bitmap
    /// context preserves that. The two agree because the fragment's flip exists
    /// precisely to cancel TextKit's, which is itself asserted over there.
    private func inkRows(
        of source: String
    ) throws -> (height: Int, coverages: [Int], extents: [Int]) {
        guard case .success(let content) = makeRenderer().diagram(
            source, maxWidth: 600, dark: true)
        else { throw RenderFailure(reason: "did not render") }

        let image = try XCTUnwrap(content.cgImage)
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

        try pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue)
            else { throw RenderFailure(reason: "no probe context") }
            context.draw(
                image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        }

        let background = (Int(pixels[0]), Int(pixels[1]), Int(pixels[2]))
        var coverages: [Int] = []
        var extents: [Int] = []
        coverages.reserveCapacity(height)
        extents.reserveCapacity(height)

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
            coverages.append(count)
            extents.append(first < 0 ? 0 : last - first + 1)
        }
        return (height, coverages, extents)
    }

    /// Where the *layout* puts its weight vertically, as a fraction from the
    /// top — the ground truth the picture has to agree with.
    private func layoutCentroid(of source: String) throws -> Double {
        let graph = try MermaidRenderer.layout(source)
        guard graph.height > 0 else { throw RenderFailure(reason: "empty layout") }

        var weighted = 0.0
        var total = 0.0
        func add(y: Double, height: Double, width: Double) {
            let area = max(width, 1) * max(height, 1)
            weighted += (y + height / 2) * area
            total += area
        }

        switch graph.content {
        case .flowchart(let nodes, _, _), .stateDiagram(let nodes, _, _):
            for node in nodes { add(y: node.y, height: node.height, width: node.width) }
        case .sequenceDiagram(let actors, _, _, _, _, _):
            for actor in actors { add(y: actor.y, height: actor.height, width: actor.width) }
        case .classDiagram(let classes, _):
            for item in classes { add(y: item.y, height: item.height, width: item.width) }
        case .erDiagram(let entities, _):
            for entity in entities { add(y: entity.y, height: entity.height, width: entity.width) }
        case .xyChart(let chart):
            for bar in chart.bars { add(y: bar.y, height: bar.height, width: bar.width) }
        }

        guard total > 0 else { throw RenderFailure(reason: "nothing laid out") }
        return weighted / total / graph.height
    }
}
