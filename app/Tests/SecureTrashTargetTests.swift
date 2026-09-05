//
//  SecureTrashTargetTests.swift
//  MarkDevKitTests
//

import Darwin
import XCTest

@testable import MarkDevKit

final class SecureTrashTargetTests: XCTestCase {
    func testRemoteAuthorityCannotMintConsentForALocalTrashTarget() throws {
        try withTemporaryDirectory { directory in
            let target = directory.appendingPathComponent("target.md")
            try Data("keep".utf8).write(to: target)
            let hostile = try XCTUnwrap(
                URL(string: "file://remote.example\(target.path)"))

            XCTAssertThrowsError(try SecureTrashTarget(at: hostile)) { error in
                guard case LocalFileResolutionError.notAFileURL(let rejected) = error else {
                    return XCTFail("unexpected error: \(error)")
                }
                XCTAssertEqual(rejected, hostile)
            }
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep")
        }
    }

    func testFinalSymlinkIsRejectedWithoutFollowingItsTarget() throws {
        try withTemporaryDirectory { directory in
            let target = directory.appendingPathComponent("target.md")
            let alias = directory.appendingPathComponent("alias.md")
            try Data("safe".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(
                at: alias,
                withDestinationURL: target)

            XCTAssertThrowsError(try SecureTrashTarget(at: alias))
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "safe")
        }
    }

    func testAtomicPathReplacementInvalidatesApproval() throws {
        try withTemporaryDirectory { directory in
            let target = directory.appendingPathComponent("note.md")
            let replacement = directory.appendingPathComponent("replacement.md")
            try Data("original".utf8).write(to: target)
            let approval = try SecureTrashTarget(at: target)
            try Data("replacement".utf8).write(to: replacement)
            XCTAssertEqual(
                Darwin.rename(replacement.path, target.path),
                0)

            XCTAssertFalse(try approval.matchesCurrentEntry())
            XCTAssertEqual(
                try approval.moveToTrashIfCurrent(),
                .stale,
                "stale consent must not move the replacement")
            XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        }
    }

    func testModeAndLinkCountChangesInvalidateFullStamp() throws {
        try withTemporaryDirectory { directory in
            let target = directory.appendingPathComponent("note.md")
            let hardLink = directory.appendingPathComponent("hard-link.md")
            try Data("text".utf8).write(to: target)

            let beforeMode = try SecureTrashTarget(at: target)
            XCTAssertEqual(Darwin.chmod(target.path, S_IRUSR | S_IWUSR), 0)
            XCTAssertFalse(try beforeMode.matchesCurrentEntry())

            let beforeLink = try SecureTrashTarget(at: target)
            XCTAssertEqual(Darwin.link(target.path, hardLink.path), 0)
            XCTAssertFalse(try beforeLink.matchesCurrentEntry())
        }
    }

    func testRegularFileAndDirectoryRemainCurrentWhenUnchanged() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("note.md")
            let folder = directory.appendingPathComponent("folder", isDirectory: true)
            try Data("text".utf8).write(to: file)
            try FileManager.default.createDirectory(
                at: folder,
                withIntermediateDirectories: false)

            XCTAssertTrue(try SecureTrashTarget(at: file).matchesCurrentEntry())
            XCTAssertTrue(try SecureTrashTarget(at: folder).matchesCurrentEntry())
        }
    }

    private func withTemporaryDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkDev-trash-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}
