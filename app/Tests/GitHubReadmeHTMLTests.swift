//
//  GitHubReadmeHTMLTests.swift
//  MarkDevKitTests
//
//  The GitPulse README spelling of GitHub chrome: centred badge rows, a
//  tagline with `<br>` and `<strong>`, a hero `width="100%"`, and a
//  screenshot gallery whose cells are `[<img>](url)`.
//

import AppKit
import XCTest

@testable import MarkDevKit

@MainActor
final class GitHubReadmeHTMLTests: XCTestCase {

    private func directory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevReadme-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    @discardableResult
    private func writePNG(width: Int, height: Int, name: String, to directory: URL) throws -> URL {
        let image = NSImage(size: CGSize(width: width, height: height))
        image.lockFocus()
        NSColor.systemOrange.drawSwatch(
            in: CGRect(x: 0, y: 0, width: width, height: height))
        image.unlockFocus()
        let data = try XCTUnwrap(
            NSBitmapImageRep(data: image.tiffRepresentation ?? Data())?
                .representation(using: .png, properties: [:]))
        let url = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    private func view(
        _ markdown: String, directory: URL? = nil, width: CGFloat = 640, height: CGFloat = 900
    ) -> MarkdownTextView {
        let view = MarkdownTextView.make()
        view.mode = .reading
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        view.documentDirectory = directory
        view.setMarkdown(markdown)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.textLayoutManager?.ensureLayout(for: view.textLayoutManager!.documentRange)
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func fragments(_ view: MarkdownTextView) -> [MarkdownLayoutFragment] {
        guard let manager = view.textLayoutManager else { return [] }
        manager.ensureLayout(for: manager.documentRange)
        var found: [MarkdownLayoutFragment] = []
        manager.enumerateTextLayoutFragments(
            from: manager.documentRange.location, options: [.ensuresLayout]
        ) { fragment in
            if let fragment = fragment as? MarkdownLayoutFragment { found.append(fragment) }
            return true
        }
        return found
    }

    func testABadgeRowDrawsChipsInsteadOfRawHTML() {
        let source = """
            Intro.

            <p align="center">
              <a href="https://example.com/"><img src="https://img.shields.io/badge/ci-passing-green" alt="CI"></a>
              <a href="https://example.com/"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License: MIT"></a>
            </p>
            """
        let view = view(source)
        let flow = fragments(view).compactMap(\.htmlFlow).first
        XCTAssertNotNil(flow, "the badge row must be drawn, not shown as tags")
        XCTAssertGreaterThan(flow?.height ?? 0, 10)
        XCTAssertEqual(flow?.pieces.count, 2)

        let storage = view.textStorage
        let tag = (source as NSString).range(of: "<p align")
        let font = storage?.attribute(.font, at: tag.location, effectiveRange: nil) as? NSFont
        XCTAssertEqual(
            font?.pointSize ?? 0, EditorTheme.hiddenMarkerFontSize, accuracy: 0.001,
            "the HTML is replaced by the chips")
    }

    func testATaglineDrawsBoldTextNotTheTags() throws {
        let source = """
            Intro.

            <p align="center">
              <strong>High-performance, local-first native Git desktop client.</strong><br>
              Engineered with a native Rust backend.<br>
              <a href="https://example.com/"><strong>Explore the showcase &rarr;</strong></a>
            </p>
            """
        let view = view(source)
        let flow = try XCTUnwrap(fragments(view).compactMap(\.htmlFlow).first)
        XCTAssertGreaterThan(flow.height, 20)
        XCTAssertGreaterThanOrEqual(flow.pieces.count, 3)
    }

    func testAHundredPercentHeroFillsTheColumn() throws {
        let directory = try directory()
        try writePNG(width: 800, height: 200, name: "docs/hero.png", to: directory)

        let source = """
            Intro.

            <p align="center">
              <img src="docs/hero.png" alt="Hero" width="100%">
            </p>
            """
        let view = view(source, directory: directory, width: 520)
        let flow = try XCTUnwrap(fragments(view).compactMap(\.htmlFlow).first)
        XCTAssertGreaterThan(flow.height, 40)

        var imageWidth: CGFloat = 0
        for piece in flow.pieces {
            if case .image(_, let rect) = piece {
                imageWidth = rect.width
            }
        }
        XCTAssertGreaterThan(imageWidth, 400, "width=100% is the column, not the file's 800pt")
        XCTAssertLessThan(imageWidth, 520)
    }

    func testAScreenshotTableDrawsThePicturesNotTheTags() throws {
        let directory = try directory()
        try writePNG(width: 320, height: 180, name: "docs/files.png", to: directory)
        try writePNG(width: 320, height: 180, name: "docs/diff.png", to: directory)

        let source = """
            Intro.

            | Files | Diff |
            | --- | --- |
            | [<img src="docs/files.png" alt="Files view">](docs/files.png) | [<img src="docs/diff.png" alt="Diff view">](docs/diff.png) |
            """
        let view = view(source, directory: directory)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.layoutSubtreeIfNeeded()
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
        }

        let rows = fragments(view).compactMap(\.tableRow)
        XCTAssertGreaterThanOrEqual(rows.count, 2, "header and the screenshot row")
        let screenshot = try XCTUnwrap(rows.last)
        XCTAssertEqual(screenshot.cells.count, 2)
        XCTAssertEqual(
            screenshot.cells.map { $0.pictures.count }, [1, 1],
            "each cell is the picture, not the <img> tag")
        XCTAssertGreaterThan(screenshot.cells[0].pictures[0].rect.width, 40)
        XCTAssertGreaterThan(screenshot.height, 80)
    }

    func testTheCaretBringsTheHTMLBack() {
        let source = """
            Intro.

            <p align="center">
              <img src="docs/hero.png" alt="Hero">
            </p>
            """
        let view = view(source)
        view.mode = .livePreview
        let html = (source as NSString).range(of: "<p align")
        view.setSelectedRange(NSRange(location: html.location + 3, length: 0))
        view.textLayoutManager?.ensureLayout(for: view.textLayoutManager!.documentRange)

        XCTAssertFalse(
            view.hiddenRanges.covers(html),
            "the markup has to come back to be edited")
        XCTAssertTrue(fragments(view).allSatisfy { $0.htmlFlow == nil })
    }
}
