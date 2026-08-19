//
//  PictureHardeningTests.swift
//  MarkDevKitTests
//
//  The bounds around drawing a picture, and the things a note can put in front
//  of them.
//
//  A vector is the reason this file exists. Every other rendered thing has a
//  cost the app can see coming — a formula is a line of LaTeX, a diagram is a
//  graph it laid out itself — but an SVG is arbitrary geometry from disk,
//  rasterised **synchronously on the main actor** while TextKit builds a
//  fragment. Measured on this machine, path-dense SVG costs about 2.6ms per
//  kilobyte: 104KB drew in 0.36s and 10MB in thirty seconds. Nothing about
//  that is recoverable from once it has started, so everything here is about
//  refusing to start.
//

import AppKit
import XCTest

@testable import MarkDevKit

@MainActor
final class PictureHardeningTests: XCTestCase {

    // MARK: - Harness

    private func directory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevPictures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    @discardableResult
    private func write(_ contents: String, _ name: String, to directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// An SVG of `size` nominal points holding `paths` filled triangles.
    ///
    /// Deterministic: a fixture whose cost varied run to run would make the
    /// budget tests below flap.
    private func denseSVG(paths: Int, size: Int = 1000) -> String {
        var generator = SeededGenerator(seed: 0xD1CE_5EED)
        var body = ""
        body.reserveCapacity(paths * 90)
        for _ in 0..<paths {
            let coordinates = (0..<6).map { _ in Int.random(in: 0...size, using: &generator) }
            let colour = Int.random(in: 0...0xFF_FFFF, using: &generator)
            body += """
                <path d="M\(coordinates[0]) \(coordinates[1]) L\(coordinates[2]) \
                \(coordinates[3]) L\(coordinates[4]) \(coordinates[5])Z" \
                fill="#\(String(format: "%06x", colour))"/>
                """
        }
        return """
            <svg xmlns="http://www.w3.org/2000/svg" width="\(size)" height="\(size)" \
            viewBox="0 0 \(size) \(size)">\(body)</svg>
            """
    }

    private func plainSVG(width: Int, height: Int) -> String {
        """
        <svg xmlns="http://www.w3.org/2000/svg" width="\(width)" height="\(height)" \
        viewBox="0 0 \(width) \(height)"><rect width="\(width)" height="\(height)" \
        fill="black"/></svg>
        """
    }

    // MARK: - A file too heavy to draw

    func testAVectorPastTheSizeBoundIsRefusedAndSaysWhy() throws {
        // The bound is on the file rather than on the drawing because there is
        // nothing to measure before the drawing has happened, and no way to
        // stop it once it has started.
        let directory = try directory()
        let heavy = String(repeating: " ", count: 1_100_000)
        try write(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\" "
                + "viewBox=\"0 0 10 10\"><!--\(heavy)--><rect width=\"10\" height=\"10\"/></svg>",
            "heavy.svg", to: directory)

        guard case .failure(let failure) = RichContentRenderer().image(
            at: "heavy.svg", relativeTo: directory, maxWidth: 600)
        else { return XCTFail("a file past the bound must not be drawn") }

        XCTAssertTrue(failure.reason.contains("heavy.svg"), failure.reason)
        XCTAssertTrue(failure.reason.contains("MB"), "the reason has to name what it weighs")
    }

    func testAHeavyFileIsWeighedBeforeItIsOpened() throws {
        // Opening it is already most of the cost — 200ms for 5MB, measured —
        // so a bound applied after the load would be a bound that had already
        // been paid. Timed rather than inspected: there is no other way to
        // tell "refused" from "loaded and then refused", and the margin here
        // is two orders of magnitude.
        let directory = try directory()
        try write(denseSVG(paths: 60_000), "dense.svg", to: directory)
        let bytes = try XCTUnwrap(
            try directory.appendingPathComponent("dense.svg")
                .resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertGreaterThan(bytes, 1_048_576, "the fixture has to be past the bound")

        let clock = ContinuousClock()
        let started = clock.now
        guard case .failure = RichContentRenderer().image(
            at: "dense.svg", relativeTo: directory, maxWidth: 600)
        else { return XCTFail("a file past the bound must not be drawn") }
        let taken = clock.now - started

        // Generous on purpose: the margin that matters is against *loading*
        // the file, which is 100ms for this fixture before any of it is drawn,
        // and against drawing it, which is seconds. A budget tight enough to
        // measure a `stat` would fail on a busy machine instead of on a bug.
        XCTAssertLessThan(
            taken, .milliseconds(250),
            "refusing took \(taken) — the file was opened, or drawn, before it was weighed")
    }

    func testTheBoundIsOnVectorsAndNotOnEveryPicture() throws {
        // A raster's cost is its pixels, which are bounded by the file's own
        // dimensions and by the decoders. Weighing one would refuse ordinary
        // photographs for no reason.
        let directory = try directory()
        // Noise, not a swatch: a flat colour compresses to a third of the
        // bound and the fixture would prove nothing.
        let width = 900
        let height = 700
        var generator = SeededGenerator(seed: 0x5EED_1A9E)
        let rep = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32))
        let pixels = try XCTUnwrap(rep.bitmapData)
        for offset in 0..<(width * height * 4) {
            pixels[offset] = UInt8.random(in: 0...255, using: &generator)
        }
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 1_048_576, "the fixture has to be past the bound")
        try data.write(to: directory.appendingPathComponent("photo.png"))

        guard case .success = RichContentRenderer().image(
            at: "photo.png", relativeTo: directory, maxWidth: 600)
        else { return XCTFail("a large raster is not the thing being bounded") }
    }

    // MARK: - A file too expensive to draw twice

    func testAnExpensiveVectorIsDrawnOnceAndScaledAfterwards() throws {
        // Rasterising is geometry-bound, not pixel-bound: the same file costs
        // the same second at 300 points as at 3,000. A picture is re-rendered
        // whenever the width it is drawn at changes, and the column changes
        // with every step of a window resize — so without this, dragging a
        // window edge over a heavy note is a stall per step, forever.
        //
        // The budget is set to nothing rather than the fixture made slow: a
        // test that needs a genuinely expensive file is a test whose meaning
        // changes with the machine it runs on.
        let directory = try directory()
        try write(plainSVG(width: 100, height: 100), "mark.svg", to: directory)
        let renderer = RichContentRenderer(expensiveRasterBudget: .zero)

        guard case .success(let first) = renderer.image(
            at: "mark.svg", relativeTo: directory, maxWidth: 600, width: 600)
        else { return XCTFail("an SVG should load") }
        XCTAssertEqual(try XCTUnwrap(first.cgImage).width, 1200)

        guard case .success(let second) = renderer.image(
            at: "mark.svg", relativeTo: directory, maxWidth: 300, width: 300)
        else { return XCTFail("an SVG should load") }
        XCTAssertEqual(second.size.width, 300, accuracy: 0.5, "drawn at the size asked for")
        XCTAssertEqual(
            try XCTUnwrap(second.cgImage).width, 1200,
            "the bitmap that was already paid for, scaled — not a second rasterisation")
    }

    func testAnOrdinaryVectorIsNotQuietlyScaledInstead() throws {
        // The other half, and the one that would go unnoticed: if everything
        // were served from whatever bitmap happened to be made first, every
        // picture in the app would go soft after a resize and no test here
        // would say so.
        let directory = try directory()
        try write(plainSVG(width: 100, height: 100), "mark.svg", to: directory)
        let renderer = RichContentRenderer()

        guard case .success = renderer.image(
            at: "mark.svg", relativeTo: directory, maxWidth: 600, width: 600),
            case .success(let second) = renderer.image(
                at: "mark.svg", relativeTo: directory, maxWidth: 300, width: 300)
        else { return XCTFail("an SVG should load") }

        XCTAssertEqual(
            try XCTUnwrap(second.cgImage).width, 600,
            "a cheap picture is rendered again at the size it is now drawn")
    }

    func testInvalidatingForgetsWhatWasExpensive() throws {
        let directory = try directory()
        try write(plainSVG(width: 100, height: 100), "mark.svg", to: directory)
        let renderer = RichContentRenderer(expensiveRasterBudget: .zero)

        guard case .success = renderer.image(
            at: "mark.svg", relativeTo: directory, maxWidth: 600, width: 600)
        else { return XCTFail("an SVG should load") }
        renderer.invalidate()

        guard case .success(let after) = renderer.image(
            at: "mark.svg", relativeTo: directory, maxWidth: 300, width: 300)
        else { return XCTFail("an SVG should load") }
        XCTAssertEqual(
            try XCTUnwrap(after.cgImage).width, 600,
            "a theme change drops the bitmaps, and this one with them")
    }

    // MARK: - Shapes nothing can be drawn at

    func testAnAbsurdlyTallVectorIsBroughtBackToADrawableSize() throws {
        // A vector's aspect is whatever its viewBox says, and the drawn size
        // is handed to TextKit as a fragment's height. 100,000 points is not a
        // picture, it is a document a thousand screens long with a hairline in
        // it.
        let directory = try directory()
        try write(plainSVG(width: 10, height: 100_000), "tall.svg", to: directory)

        guard case .success(let content) = RichContentRenderer().image(
            at: "tall.svg", relativeTo: directory, maxWidth: 600, width: 600)
        else { return XCTFail("an SVG should load") }

        XCTAssertLessThanOrEqual(content.size.height, 20_000)
        XCTAssertEqual(
            content.size.width / content.size.height, 10 / 100_000, accuracy: 0.0001,
            "brought back in proportion, not squashed")
        let bitmap = try XCTUnwrap(content.cgImage)
        XCTAssertLessThanOrEqual(bitmap.width * bitmap.height, 17_000_000)
    }

    func testAHairlineIsDrawnRatherThanRefused() throws {
        // The mirror of the tall case, and the one that matters more because
        // it is a thing people actually write: a divider is a 10,000x1
        // viewBox, which in a 600-point column is 0.06 points tall — a picture
        // with no row of pixels to put anywhere. Telling the reader their
        // divider is broken would be the wrong answer.
        let directory = try directory()
        try write(plainSVG(width: 10_000, height: 1), "rule.svg", to: directory)

        guard case .success(let content) = RichContentRenderer().image(
            at: "rule.svg", relativeTo: directory, maxWidth: 600)
        else { return XCTFail("a hairline is still a picture") }

        XCTAssertEqual(content.size.width, 600, accuracy: 0.5)
        XCTAssertEqual(content.size.height, 1, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(content.cgImage).height, 1)
    }

    func testAVectorWithNoSizeOfItsOwnFailsClearly() throws {
        let directory = try directory()
        try write(plainSVG(width: 0, height: 0), "empty.svg", to: directory)
        try write("<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>", "bare.svg", to: directory)

        for name in ["empty.svg", "bare.svg"] {
            guard case .failure(let failure) = RichContentRenderer().image(
                at: name, relativeTo: directory, maxWidth: 600)
            else { return XCTFail("\(name) has no size to draw at") }
            XCTAssertTrue(failure.reason.contains(name), failure.reason)
        }
    }

    func testFilesThatAreNotPicturesFailRatherThanCrash() throws {
        let directory = try directory()
        try write("", "empty.svg", to: directory)
        try write("not markup at all", "text.svg", to: directory)
        try write("<svg", "truncated.svg", to: directory)
        try write("<svg xmlns=\"http://www.w3.org/2000/svg\"><rect/>", "unclosed.svg", to: directory)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("folder.svg"), withIntermediateDirectories: true)

        for name in ["empty.svg", "text.svg", "truncated.svg", "unclosed.svg", "folder.svg"] {
            guard case .failure = RichContentRenderer().image(
                at: name, relativeTo: directory, maxWidth: 600)
            else { return XCTFail("\(name) is not a picture") }
        }
        // A device file: opening it is fine, reading it forever is not.
        guard case .failure = RichContentRenderer().image(
            at: "/dev/null", relativeTo: nil, maxWidth: 600)
        else { return XCTFail("/dev/null is not a picture") }
    }

    func testAFileWhoseNameLiesFailsRatherThanBeingSizedByTheLie() throws {
        // `isScalable` reads the extension, because it is asked before
        // anything is loaded — so the worry is a raster sized by the rules for
        // a vector, or the reverse. It cannot happen:
        // `NSImage(contentsOf:)` resolves the type from the extension too, and
        // declines a file whose name and content disagree. Pinned here because
        // the sizing rules lean on it, and because the opposite — that
        // `NSImage` sniffs the bytes — is the natural assumption to make.
        let directory = try directory()
        try write(plainSVG(width: 120, height: 60), "actually-a-vector.png", to: directory)

        let image = NSImage(size: CGSize(width: 40, height: 20))
        image.lockFocus()
        NSColor.systemPink.drawSwatch(in: CGRect(x: 0, y: 0, width: 40, height: 20))
        image.unlockFocus()
        try XCTUnwrap(
            NSBitmapImageRep(data: image.tiffRepresentation ?? Data())?
                .representation(using: .png, properties: [:])
        ).write(to: directory.appendingPathComponent("actually-a-raster.svg"))

        let renderer = RichContentRenderer()
        for name in ["actually-a-vector.png", "actually-a-raster.svg"] {
            guard case .failure(let failure) = renderer.image(
                at: name, relativeTo: directory, maxWidth: 600)
            else { return XCTFail("\(name) does not load as what it claims to be") }
            XCTAssertTrue(failure.reason.contains(name), failure.reason)
        }
    }

    // MARK: - Nothing leaves the machine

    func testRenderingAnSVGNeverFetchesWhatItPointsAt() throws {
        // The invariant the whole image path is built around: opening a note
        // must not become a network request. An SVG is the one picture format
        // that can *contain* a reference to another one — `<image href>`, or
        // an external entity in a DOCTYPE — so refusing remote references at
        // the Markdown level is not the whole of it.
        //
        // Answered by listening rather than by reasoning: a socket on the
        // loopback interface that nothing else knows the port of, and an SVG
        // that names it three ways.
        let listener = try LoopbackListener()
        defer { listener.stop() }

        let directory = try directory()
        try write(
            """
            <?xml version="1.0"?>
            <!DOCTYPE svg [ <!ENTITY x SYSTEM "http://127.0.0.1:\(listener.port)/entity"> ]>
            <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" \
            width="200" height="100" viewBox="0 0 200 100">
              <image href="http://127.0.0.1:\(listener.port)/href.png" width="100" height="100"/>
              <image xlink:href="http://127.0.0.1:\(listener.port)/xlink.png" width="100" \
            height="100"/>
              <text x="0" y="20">&x;</text>
              <rect width="200" height="20" fill="black"/>
            </svg>
            """, "phones-home.svg", to: directory)

        guard case .success = RichContentRenderer().image(
            at: "phones-home.svg", relativeTo: directory, maxWidth: 600, width: 600)
        else { return XCTFail("the SVG itself should still draw") }

        // Rasterising is synchronous and has finished; a fetch it started
        // would have connected by now. The wait is for one it started and did
        // not wait for itself.
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline, listener.connections == 0 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(
            listener.connections, 0,
            "drawing the SVG opened a connection: a note that phones home when it is read")
    }

    // MARK: - The width pictures are rendered against

    func testTheRenderWidthNeverExceedsTheColumnItIsFor() {
        for column in stride(from: 0.0, through: 2_000, by: 0.5) {
            let width = MarkdownTextView.renderWidth(for: column)
            XCTAssertGreaterThanOrEqual(width, MarkdownTextView.minimumRenderWidth)
            if column >= MarkdownTextView.minimumRenderWidth {
                XCTAssertLessThanOrEqual(
                    width, column,
                    "a picture measured against \(width) does not fit a column of \(column)")
            }
        }
    }

    func testTheRenderWidthIsMonotonicAndCoarse() {
        // Coarse is the point: every distinct value is a fresh rasterisation
        // of every picture in the document, and a resize walks the column
        // through every pixel between two sizes.
        var previous = MarkdownTextView.renderWidth(for: 0)
        var distinct: Set<CGFloat> = []
        for column in stride(from: 0.0, through: 1_200, by: 1) {
            let width = MarkdownTextView.renderWidth(for: column)
            XCTAssertGreaterThanOrEqual(width, previous, "widening the column narrowed a picture")
            previous = width
            distinct.insert(width)
        }
        XCTAssertLessThanOrEqual(
            distinct.count, 1_200 / Int(MarkdownTextView.renderWidthStep) + 1,
            "1,200 points of resizing produced \(distinct.count) different renders")
    }

    func testNonsenseColumnsDoNotProduceNonsenseWidths() {
        for column in [CGFloat.nan, .infinity, -.infinity, -1, 0, 1, .greatestFiniteMagnitude] {
            let width = MarkdownTextView.renderWidth(for: column)
            XCTAssertTrue(width.isFinite, "\(column) produced \(width)")
            XCTAssertGreaterThanOrEqual(width, MarkdownTextView.minimumRenderWidth)
        }
    }
}

/// A socket on the loopback interface that counts connections and answers
/// nothing.
///
/// Deliberately not a `URLProtocol`: that only sees traffic a `URLSession` in
/// this process makes, and the question here is whether *AppKit* fetches
/// something while it draws.
private final class LoopbackListener {
    /// Shared with the accept thread. A class of its own so the thread
    /// captures the counter and not the listener, which is what lets the
    /// listener stay an ordinary object.
    private final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        func record() {
            lock.lock()
            count += 1
            lock.unlock()
        }
    }

    let port: UInt16
    private let socketDescriptor: Int32
    private let tally = Tally()

    var connections: Int { tally.value }

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw RenderFailure(reason: "no socket") }

        var yes: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        // Loopback and an ephemeral port: nothing outside this process knows
        // where it is, so a connection can only have come from what was drawn.
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        address.sin_port = 0

        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 8) == 0 else {
            close(descriptor)
            throw RenderFailure(reason: "could not listen")
        }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0, assigned.sin_port != 0 else {
            close(descriptor)
            throw RenderFailure(reason: "could not name the socket")
        }

        socketDescriptor = descriptor
        port = assigned.sin_port.bigEndian

        let tally = self.tally
        Thread.detachNewThread {
            // Ends when `stop()` closes the descriptor and `accept` fails.
            while true {
                let client = accept(descriptor, nil, nil)
                if client < 0 { return }
                close(client)
                tally.record()
            }
        }
    }

    func stop() {
        close(socketDescriptor)
    }
}
