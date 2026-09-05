//
//  BoundedRegularFileReaderPublicAPITests.swift
//  MarkDevKitTests
//
//  The app target imports MarkDevKit without @testable. Authority checks used
//  from WorkspaceView must therefore be part of the framework's public surface.
//

import Foundation
import MarkDevKit
import XCTest

final class BoundedRegularFileReaderPublicAPITests: XCTestCase {
    func testAppTargetCanAskWhetherAURLCarriesLocalFileAuthority() throws {
        let local = URL(fileURLWithPath: "/tmp/note.md")
        let remote = try XCTUnwrap(URL(string: "file://remote.example/tmp/note.md"))

        XCTAssertTrue(MarkDevKit.BoundedRegularFileReader.hasLocalFileAuthority(local))
        XCTAssertFalse(MarkDevKit.BoundedRegularFileReader.hasLocalFileAuthority(remote))
    }
}
