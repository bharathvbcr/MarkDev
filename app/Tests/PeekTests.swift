//
//  PeekTests.swift
//  MarkDevKitTests
//
//  Hold-Space preview: what it loads, what it refuses, and where the arrow
//  keys move the selection it previews.
//

import XCTest

@testable import MarkDevKit

final class PeekLoaderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevPeek-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ contents: String, to name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testANoteLoads() throws {
        let url = try write("# Hello\n\nWorld.\n", to: "Note.md")
        guard case .success(let text) = PeekLoader.read(url) else {
            return XCTFail("a small note should peek")
        }
        XCTAssertEqual(text, "# Hello\n\nWorld.\n")
    }

    func testAMissingFileFailsWithItsName() {
        let url = directory.appendingPathComponent("Gone.md")
        guard case .failure(let failure) = PeekLoader.read(url) else {
            return XCTFail("a missing file cannot be peeked")
        }
        XCTAssertTrue(
            failure.reason.contains("Gone.md"),
            "the reason must name the file, or it explains nothing")
    }

    func testAnOversizeNoteIsRefusedRatherThanStalling() throws {
        // A peek fires on key-down and has to be instant. Reading and laying
        // out a multi-megabyte file there leaves the reader holding a key
        // while nothing happens, which reads as a hang.
        let url = directory.appendingPathComponent("Huge.md")
        let chunk = String(repeating: "lorem ipsum dolor sit amet\n", count: 40_000)
        var contents = chunk
        while contents.utf8.count <= PeekLoader.maximumBytes {
            contents += chunk
        }
        try contents.write(to: url, atomically: true, encoding: .utf8)

        guard case .failure(let failure) = PeekLoader.read(url) else {
            return XCTFail("a file past the limit should not peek")
        }
        XCTAssertTrue(failure.reason.lowercased().contains("large"))
    }

    func testAFileExactlyAtTheLimitStillPeeks() throws {
        // The boundary belongs to the readable side; an off-by-one here means
        // a file refuses to preview for no reason the reader can see.
        let url = directory.appendingPathComponent("Edge.md")
        try Data(repeating: 0x61, count: PeekLoader.maximumBytes).write(to: url)

        guard case .success = PeekLoader.read(url) else {
            return XCTFail("a file at exactly the limit should peek")
        }
    }

    func testANonUTF8NoteFallsBackRatherThanFailing() throws {
        let url = directory.appendingPathComponent("Latin.md")
        // 0xE9 is `é` in Latin-1 and invalid on its own in UTF-8.
        try Data([0x63, 0x61, 0x66, 0xE9]).write(to: url)

        guard case .success(let text) = PeekLoader.read(url) else {
            return XCTFail("a Latin-1 note is still worth reading")
        }
        XCTAssertEqual(text, "café")
    }

    func testAnEmptyNotePeeksAsEmpty() throws {
        let url = try write("", to: "Empty.md")
        guard case .success(let text) = PeekLoader.read(url) else {
            return XCTFail("an empty note is not an error")
        }
        XCTAssertEqual(text, "")
    }
}

final class NavigatorKeyboardTests: XCTestCase {
    private let rows = ["/v/a.md", "/v/b.md", "/v/c.md"].map { URL(fileURLWithPath: $0) }

    func testMovingDownStepsToTheNextRow() {
        XCTAssertEqual(NavigatorKeyboard.move(rows[0], by: 1, in: rows), rows[1])
    }

    func testMovingUpStepsToThePreviousRow() {
        XCTAssertEqual(NavigatorKeyboard.move(rows[2], by: -1, in: rows), rows[1])
    }

    func testTheFirstPressWithNothingSelectedEntersFromTheMatchingEnd() {
        XCTAssertEqual(NavigatorKeyboard.move(nil, by: 1, in: rows), rows.first)
        XCTAssertEqual(NavigatorKeyboard.move(nil, by: -1, in: rows), rows.last)
    }

    func testArrowingPastEitherEndReportsNoMove() {
        // `nil` rather than the unchanged row: the view reports the key as
        // unhandled so it falls through to AppKit, instead of a dead press
        // that swallows the event at the end of the list.
        XCTAssertNil(NavigatorKeyboard.move(rows.last, by: 1, in: rows))
        XCTAssertNil(NavigatorKeyboard.move(rows.first, by: -1, in: rows))
    }

    func testAnEmptyListNeverMoves() {
        XCTAssertNil(NavigatorKeyboard.move(nil, by: 1, in: []))
        XCTAssertNil(NavigatorKeyboard.move(rows[0], by: -1, in: []))
    }

    func testASelectionThatHasBeenFilteredAwayReEntersTheList() {
        // The filter rebuilds the row list under the selection. Treating a
        // stale selection as "nothing selected" is what keeps the arrow keys
        // working after typing into the filter field.
        let stale = URL(fileURLWithPath: "/v/gone.md")
        XCTAssertEqual(NavigatorKeyboard.move(stale, by: 1, in: rows), rows.first)
    }
}
