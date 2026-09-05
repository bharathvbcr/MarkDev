//
//  SecureLocalFileReadTests.swift
//  MarkDevKitTests
//

import Darwin
import XCTest

@testable import MarkDevKit

/// The read and cancellation callbacks may run concurrently. Keep their
/// shared progress behind one explicit synchronization boundary so the test
/// exercises production cancellation without introducing its own data race.
private final class LockedReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        storage += 1
        return storage
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

final class SecureLocalFileReadTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkDevSecureRead-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testReadReturnsExactBytesVersionAndCanonicalURLAtBoundary() throws {
        let file = directory.appendingPathComponent("Note.md")
        try Data("12345678".utf8).write(to: file)

        let snapshot = try SecureLocalFileSystem.read(file, maximumBytes: 8)

        XCTAssertEqual(snapshot.data, Data("12345678".utf8))
        XCTAssertEqual(snapshot.version.size, 8)
        XCTAssertEqual(snapshot.canonicalURL, file.standardizedFileURL)
        XCTAssertEqual(snapshot.version.sha256.count, 32)
    }

    func testReadRejectsFileURLsWhoseAuthorityWouldBeDiscardedIntoALocalPath() throws {
        let file = directory.appendingPathComponent("Authority.md")
        try Data("local-only".utf8).write(to: file)
        let hostileURLs = try [
            XCTUnwrap(URL(string: "file://remote.example\(file.path)")),
            XCTUnwrap(URL(string: "file://user:password@localhost\(file.path)")),
            XCTUnwrap(URL(string: "file://localhost:44\(file.path)")),
            XCTUnwrap(URL(string: "\(file.absoluteString)?ignored=1")),
            XCTUnwrap(URL(string: "\(file.absoluteString)#ignored")),
        ]

        for hostile in hostileURLs {
            XCTAssertTrue(hostile.isFileURL)
            XCTAssertThrowsError(
                try SecureLocalFileSystem.read(hostile, maximumBytes: 64),
                "accepted authority-bearing URL \(hostile.absoluteString)"
            ) { error in
                guard case SecureLocalFileError.operation(.openTarget, EINVAL) = error else {
                    return XCTFail("unexpected error for \(hostile): \(error)")
                }
            }
        }

        let localhost = try XCTUnwrap(URL(string: "file://localhost\(file.path)"))
        XCTAssertEqual(
            try SecureLocalFileSystem.read(localhost, maximumBytes: 64).data,
            Data("local-only".utf8))
    }

    func testReadRefusesLimitPlusOneWithoutReturningPartialBytes() throws {
        let file = directory.appendingPathComponent("Note.md")
        try Data(repeating: 0x61, count: 9).write(to: file)

        XCTAssertThrowsError(try SecureLocalFileSystem.read(file, maximumBytes: 8)) {
            XCTAssertEqual(
                $0 as? SecureLocalFileError,
                .fileTooLarge(maximumBytes: 8))
        }
    }

    func testReadResolvesSymlinkOnceAndReturnsCanonicalTargetAuthority() throws {
        let target = directory.appendingPathComponent("Target.md")
        let alias = directory.appendingPathComponent("Alias.md")
        try Data("target".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)

        let snapshot = try SecureLocalFileSystem.read(alias, maximumBytes: 64)

        XCTAssertEqual(snapshot.data, Data("target".utf8))
        XCTAssertEqual(snapshot.canonicalURL, target.standardizedFileURL)
    }

    func testReadAllowsHardLinkButCarriesNonUniqueLinkCount() throws {
        let target = directory.appendingPathComponent("Target.md")
        let alias = directory.appendingPathComponent("Alias.md")
        try Data("target".utf8).write(to: target)
        try FileManager.default.linkItem(at: target, to: alias)

        let snapshot = try SecureLocalFileSystem.read(alias, maximumBytes: 64)

        XCTAssertEqual(snapshot.data, Data("target".utf8))
        XCTAssertEqual(snapshot.version.linkCount, 2)
    }

    func testReadRefusesFIFOWithoutWaitingForAWriter() throws {
        let fifo = directory.appendingPathComponent("Pipe.md")
        XCTAssertEqual(fifo.path.withCString { Darwin.mkfifo($0, 0o600) }, 0)

        XCTAssertThrowsError(try SecureLocalFileSystem.read(fifo, maximumBytes: 64)) {
            XCTAssertEqual($0 as? SecureLocalFileError, .unsupportedEntry)
        }
    }

    func testReadRefusesNameSubstitutionDuringDescriptorRead() throws {
        let file = directory.appendingPathComponent("Note.md")
        try Data(repeating: 0x61, count: 128 * 1_024).write(to: file)
        var calls = SecureFileSyscalls.live
        let liveRead = calls.read
        var replaced = false
        calls.read = { descriptor, bytes, count in
            let result = liveRead(descriptor, bytes, count)
            if result > 0, !replaced {
                replaced = true
                let replacement = self.directory.appendingPathComponent("Replacement.md")
                try? Data(repeating: 0x62, count: 128 * 1_024).write(to: replacement)
                _ = Darwin.rename(replacement.path, file.path)
            }
            return result
        }

        XCTAssertThrowsError(
            try SecureLocalFileSystem.read(file, maximumBytes: 256 * 1_024, syscalls: calls)
        ) { error in
            XCTAssertEqual(error as? SecureLocalFileError, .expectationMismatch)
        }
    }

    func testReadPermanentEINTRStopsAfterEightAttemptsAndClosesDescriptor() throws {
        let file = directory.appendingPathComponent("Note.md")
        try Data("body".utf8).write(to: file)
        var calls = SecureFileSyscalls.live
        var attempts = 0
        var openedDescriptor: Int32 = -1
        let liveOpenAt = calls.openAt
        calls.openAt = { parent, component, flags in
            let result = liveOpenAt(parent, component, flags)
            if result >= 0 { openedDescriptor = result }
            return result
        }
        calls.read = { _, _, _ in
            attempts += 1
            errno = EINTR
            return -1
        }

        XCTAssertThrowsError(
            try SecureLocalFileSystem.read(file, maximumBytes: 64, syscalls: calls)
        ) { error in
            XCTAssertEqual(
                error as? SecureLocalFileError,
                .operation(.verify, errno: EINTR))
        }
        XCTAssertEqual(attempts, 8)
        XCTAssertGreaterThanOrEqual(openedDescriptor, 0)
        XCTAssertEqual(fcntl(openedDescriptor, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
    }

    func testReadCancellationDuringBodyReturnsNoSnapshot() throws {
        let file = directory.appendingPathComponent("Note.md")
        try Data(repeating: 0x61, count: 128 * 1_024).write(to: file)
        var calls = SecureFileSyscalls.live
        let liveRead = calls.read
        let reads = LockedReadCounter()
        calls.read = { descriptor, bytes, count in
            let result = liveRead(descriptor, bytes, min(count, 1))
            if result > 0 { reads.increment() }
            return result
        }

        XCTAssertThrowsError(
            try SecureLocalFileSystem.read(
                file,
                maximumBytes: 256 * 1_024,
                syscalls: calls,
                cancellationCheck: { reads.value >= 3 })
        ) { error in
            XCTAssertEqual(error as? SecureLocalFileError, .cancelled)
        }
        XCTAssertEqual(reads.value, 3)
    }
}
