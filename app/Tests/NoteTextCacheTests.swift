//
//  NoteTextCacheTests.swift
//  MarkDevKitTests
//
//  Read-ahead bytes, and the freshness check that decides whether they may be
//  served — which is the whole difference between a fast open and a lost edit.
//

import XCTest

@testable import MarkDevKit

final class NoteTextCacheTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevNoteTextCache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private func write(_ text: String, to name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Rewrites a file with a modification time that is definitely different.
    ///
    /// Set explicitly rather than by writing and hoping: two writes inside one
    /// filesystem timestamp tick would leave the stamp unchanged, and the test
    /// would pass for the wrong reason.
    private func rewrite(_ text: String, at url: URL, secondsLater: TimeInterval) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(secondsLater)],
            ofItemAtPath: url.path)
    }

    // MARK: - Serving

    func testASecondReadComesFromMemory() throws {
        let cache = NoteTextCache()
        let url = try write("# Note", to: "a.md")

        XCTAssertEqual(try cache.utf8Text(at: url), "# Note")
        XCTAssertEqual(try cache.utf8Text(at: url), "# Note")

        XCTAssertEqual(cache.misses, 1)
        XCTAssertEqual(cache.hits, 1, "the second read must not touch the file's contents")
    }

    func testRemoteAuthorityCannotAliasAPopulatedLocalCacheEntry() throws {
        let cache = NoteTextCache()
        let local = try write("private local bytes", to: "authority.md")
        XCTAssertEqual(try cache.read(local), Data("private local bytes".utf8))
        let hostile = try XCTUnwrap(
            URL(string: "file://remote.example\(local.path)"))

        XCTAssertThrowsError(try cache.read(hostile)) { error in
            guard case NoteTextReadError.unsupportedFile(let refused) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(refused, hostile)
        }
        XCTAssertNil(cache.cached(hostile))
        XCTAssertNil(cache.warm(hostile))
        XCTAssertEqual(cache.hits, 0, "a refused authority must never count as a cache hit")
    }

    func testAFileChangedOnDiskIsReadAgain() throws {
        // The one that matters. Serving a stale note to the *editor* means the
        // reader edits text that is not what is on disk, and saves it back
        // over the newer file.
        let cache = NoteTextCache()
        let url = try write("original", to: "a.md")
        XCTAssertEqual(try cache.utf8Text(at: url), "original")

        try rewrite("replaced entirely", at: url, secondsLater: 2)

        XCTAssertEqual(try cache.utf8Text(at: url), "replaced entirely")
        XCTAssertEqual(cache.hits, 0, "a changed file is never a hit")
    }

    func testAFileRewrittenToTheSameLengthIsStillReadAgain() throws {
        // Size alone would call this unchanged: both are eight bytes.
        let cache = NoteTextCache()
        let url = try write("aaaaaaaa", to: "a.md")
        XCTAssertEqual(try cache.utf8Text(at: url), "aaaaaaaa")

        try rewrite("bbbbbbbb", at: url, secondsLater: 2)

        XCTAssertEqual(try cache.utf8Text(at: url), "bbbbbbbb")
    }

    func testATouchedButUnchangedFileIsReadAgainRatherThanRiskingStaleness() throws {
        let cache = NoteTextCache()
        let url = try write("same bytes", to: "a.md")
        _ = try cache.read(url)

        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)

        XCTAssertNil(cache.cached(url), "a moved timestamp invalidates, erring toward the disk")
    }

    func testCachedNeverReportsAnEntryForAFileThatIsGone() throws {
        let cache = NoteTextCache()
        let url = try write("body", to: "a.md")
        _ = try cache.read(url)
        XCTAssertNotNil(cache.cached(url))

        try FileManager.default.removeItem(at: url)

        XCTAssertNil(cache.cached(url))
    }

    // MARK: - Decoding

    func testUtf8TextRefusesBytesThatAreNotUtf8() throws {
        // The same contract `String(contentsOf:encoding:)` has: opening a
        // document accepts UTF-8 only, and must keep doing so.
        let cache = NoteTextCache()
        let url = directory.appendingPathComponent("latin1.md")
        try Data([0xFF, 0xFE, 0x41, 0x80]).write(to: url)

        XCTAssertThrowsError(try cache.utf8Text(at: url))
        XCTAssertNoThrow(try cache.read(url), "the bytes themselves are still readable")
    }

    func testReadingAMissingFileThrows() {
        let cache = NoteTextCache()
        XCTAssertThrowsError(try cache.read(directory.appendingPathComponent("absent.md")))
    }

    // MARK: - Bounds

    func testAFileTooLargeToHoldIsRefusedAndNotCached() throws {
        let cache = NoteTextCache(maximumFileBytes: 16)
        let url = try write(String(repeating: "x", count: 64), to: "big.md")

        XCTAssertThrowsError(try cache.utf8Text(at: url))
        XCTAssertNil(cache.cached(url))
        XCTAssertNil(cache.warm(url), "and the warmer declines it up front")
        XCTAssertEqual(cache.cachedBytes, 0)
    }

    func testABoundedReadRefusesOneBytePastTheLimit() throws {
        let cache = NoteTextCache(maximumFileBytes: 128)
        let url = try write(String(repeating: "x", count: 65), to: "too-large.md")

        XCTAssertThrowsError(try cache.read(url, maximumBytes: 64)) { error in
            guard let typed = error as? NoteTextReadError,
                case .fileTooLarge(let refused, let maximumBytes) = typed
            else { return XCTFail("unexpected error: \(error)") }
            XCTAssertEqual(refused.lastPathComponent, url.lastPathComponent)
            XCTAssertEqual(maximumBytes, 64)
        }
        XCTAssertNil(cache.cached(url), "refused input must not enter the shared cache")
    }

    func testABoundedReadAcceptsTheExactLimit() throws {
        let cache = NoteTextCache(maximumFileBytes: 64)
        let url = try write(String(repeating: "x", count: 64), to: "edge.md")

        XCTAssertEqual(try cache.read(url, maximumBytes: 64).count, 64)
    }

    func testACachedEntryCannotBypassASmallerCallSiteLimit() throws {
        let cache = NoteTextCache(maximumFileBytes: 128)
        let url = try write(String(repeating: "x", count: 65), to: "cached.md")
        XCTAssertEqual(try cache.read(url, maximumBytes: 65).count, 65)

        XCTAssertThrowsError(try cache.read(url, maximumBytes: 64)) { error in
            guard let typed = error as? NoteTextReadError,
                case .fileTooLarge(let refused, let maximumBytes) = typed
            else { return XCTFail("unexpected error: \(error)") }
            XCTAssertEqual(refused.lastPathComponent, url.lastPathComponent)
            XCTAssertEqual(maximumBytes, 64)
        }
    }

    func testTheCacheIsBoundedByTotalBytes() throws {
        let cache = NoteTextCache(maximumFileBytes: 100, maximumTotalBytes: 100)
        let first = try write(String(repeating: "a", count: 60), to: "a.md")
        let second = try write(String(repeating: "b", count: 60), to: "b.md")

        _ = try cache.read(first)
        _ = try cache.read(second)

        XCTAssertLessThanOrEqual(cache.cachedBytes, 100)
        XCTAssertNil(cache.cached(first), "the oldest entry goes")
        XCTAssertNotNil(cache.cached(second), "never the one just asked for")
    }

    func testAnEntryLargerThanTheWholeBudgetIsNotHeld() throws {
        // The eviction loop stops at one entry so it can never drop what it is
        // in the middle of returning; the size guard is what keeps that from
        // pinning something bigger than the budget forever.
        let cache = NoteTextCache(maximumFileBytes: 100, maximumTotalBytes: 10)
        let url = try write(String(repeating: "x", count: 50), to: "a.md")

        _ = try cache.read(url, maximumBytes: 50)

        XCTAssertEqual(cache.cachedBytes, 0)
    }

    func testASpecialFileIsRefusedWithoutWaitingForAWriter() throws {
        let cache = NoteTextCache(maximumFileBytes: 64)
        let url = directory.appendingPathComponent("pipe.md")
        XCTAssertEqual(url.path.withCString { Darwin.mkfifo($0, 0o600) }, 0)

        XCTAssertThrowsError(try cache.read(url)) { error in
            guard let typed = error as? NoteTextReadError,
                case .unsupportedFile(let refused) = typed
            else { return XCTFail("unexpected error: \(error)") }
            XCTAssertEqual(refused.lastPathComponent, url.lastPathComponent)
        }
    }

    func testASymbolicLinkSharesTheCanonicalCacheEntryWithItsTarget() throws {
        let cache = NoteTextCache(maximumFileBytes: 64)
        let target = try write("body", to: "Target.md")
        let link = directory.appendingPathComponent("Alias.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertEqual(try cache.read(target), Data("body".utf8))
        XCTAssertEqual(try cache.read(link), Data("body".utf8))
        XCTAssertEqual(cache.misses, 1)
        XCTAssertEqual(cache.hits, 1)
    }

    func testAHardLinkRemainsReadableEvenThoughAtomicReplacementIsRefused() throws {
        let cache = NoteTextCache(maximumFileBytes: 64)
        let target = try write("body", to: "Target.md")
        let link = directory.appendingPathComponent("Alias.md")
        try FileManager.default.linkItem(at: target, to: link)

        XCTAssertEqual(try cache.read(link), Data("body".utf8))
        XCTAssertThrowsError(
            try LocalDocumentIO.authorizeSaveAsSynchronously(link, overwrite: true)
        ) { error in
            XCTAssertTrue(
                error as? SecureLocalFileError == .hardLinkedEntry
                    || error is LocalDocumentIOError)
        }
    }

    func testTheSamePathSpelledDifferentlyIsOneEntry() throws {
        let cache = NoteTextCache()
        let url = try write("body", to: "a.md")
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let roundabout = directory.appendingPathComponent("sub/../a.md")

        _ = try cache.read(url)

        XCTAssertNotNil(cache.cached(roundabout))
        XCTAssertEqual(try cache.utf8Text(at: roundabout), "body")
        XCTAssertEqual(cache.hits, 1)
    }
}
