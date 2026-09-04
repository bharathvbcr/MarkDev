//
//  InspectorOutgoingLinkTests.swift
//  MarkDevKitTests
//
//  An outgoing link's source location must never become a target reveal location.
//

import XCTest

@testable import MarkDevKit

@MainActor
final class InspectorOutgoingLinkTests: XCTestCase {
    func testOutgoingLinkDoesNotReuseItsSourceOffsetInTheTarget() {
        let link = OutgoingLink(
            target: "Target",
            anchor: nil,
            display: "Target",
            line: 12,
            offset: 731,
            path: "Target.md")

        XCTAssertEqual(InspectorView.targetRevealOffset(for: link), 0)
        XCTAssertNotEqual(InspectorView.targetRevealOffset(for: link), link.offset)
    }

    func testNamedAnchorStillDoesNotPretendItsSourceOffsetIsResolved() {
        let link = OutgoingLink(
            target: "Target",
            anchor: "heading",
            display: "Heading",
            line: 12,
            offset: 731,
            path: "Target.md")

        XCTAssertEqual(InspectorView.targetRevealOffset(for: link), 0)
    }
}
