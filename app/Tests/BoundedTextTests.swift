//
//  BoundedTextTests.swift
//  MarkDevKitTests
//

import XCTest

@testable import MarkDevKit

private final class CountingByteSequence: Sequence, IteratorProtocol {
    private let total: Int
    private(set) var observed = 0

    init(total: Int) {
        self.total = total
    }

    func makeIterator() -> CountingByteSequence { self }

    func next() -> UInt8? {
        guard observed < total else { return nil }
        observed += 1
        return 0x61
    }
}

final class BoundedTextTests: XCTestCase {
    func testUTF8AdmissionAcceptsExactBytesAndRefusesPlusOne() {
        XCTAssertEqual(BoundedText.acceptedUTF8ByteCount("éé", maximum: 4), 4)
        XCTAssertNil(BoundedText.acceptedUTF8ByteCount("ééa", maximum: 4))
        XCTAssertNil(BoundedText.acceptedUTF8ByteCount("", maximum: -1))
        XCTAssertEqual(BoundedText.acceptedUTF8ByteCount("", maximum: 0), 0)
        XCTAssertNil(BoundedText.acceptedUTF8ByteCount("x", maximum: 0))
        XCTAssertNil(BoundedText.acceptedUTF8ByteCount("", maximum: Int.max))
    }

    func testUnicodeScalarPrefixPreservesValidityAtTheByteBoundary() {
        let result = BoundedText.unicodeScalarPrefix("aé😀z", maximum: 7)
        XCTAssertEqual(result.text, "aé😀")
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.text.utf8.count, 7)
    }

    /// One `Character` can contain an arbitrary number of combining scalars.
    /// Prefix admission must therefore advance by scalar/UTF-8 budget, not
    /// materialize the complete grapheme before discovering that it is huge.
    func testPrefixOfAGiantCombiningClusterDoesOnlyBoundedWork() {
        let hostile = "a" + String(repeating: "\u{301}", count: 1_000_000)
        let result = BoundedText.unicodeScalarPrefix(hostile, maximum: 64)

        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.text.utf8.count, 63)
        XCTAssertEqual(result.text.unicodeScalars.first, "a".unicodeScalars.first)
        XCTAssertEqual(result.text.unicodeScalars.count, 32)
    }

    func testWhitespaceCollapseAdmitsExactBytesAndRefusesPlusOne() {
        XCTAssertEqual(BoundedText.collapsingWhitespace("a   b", maximum: 5), "a b")
        XCTAssertNil(BoundedText.collapsingWhitespace("a   b!", maximum: 5))
    }

    func testCappedCountNeverInspectsPastLimitPlusOne() {
        let hostile = CountingByteSequence(total: 1_000_000)

        XCTAssertEqual(
            BoundedText.cappedCount(hostile, maximum: 8),
            .exceeded(observedAtLeast: 9))
        XCTAssertEqual(hostile.observed, 9)
    }
}
