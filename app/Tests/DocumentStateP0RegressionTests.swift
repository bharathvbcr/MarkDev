//
//  DocumentStateP0RegressionTests.swift
//  MarkDevKitTests
//
//  Red tests retained from the descriptor-relative document-state audit.
//

import Darwin
import XCTest

@testable import MarkDevKit

@MainActor
final class DocumentStateP0RegressionTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkDevDocumentP0-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A content-only conflict check cannot distinguish the file that was opened
    /// from a replacement containing the same bytes. Saving must be authorized
    /// by the descriptor-backed version, not by text equality.
    func testSaveRejectsIdentitySwappedFileEvenWhenBytesAreIdentical() throws {
        let file = directory.appendingPathComponent("Note.md")
        let replacement = directory.appendingPathComponent("Replacement.md")
        try Data("baseline".utf8).write(to: file)

        let workspace = Workspace(documentIO: LocalDocumentIO(), transactionRegistry: ProcessFileTransactionRegistry())
        try workspace.open(file, in: workspace.focusedPane)
        XCTAssertTrue(workspace.updateText("mine", in: workspace.focusedPane))

        try Data("baseline".utf8).write(to: replacement)
        XCTAssertEqual(Darwin.rename(replacement.path, file.path), 0)

        XCTAssertThrowsError(try workspace.save(in: workspace.focusedPane))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "baseline")
        XCTAssertTrue(workspace.document(in: workspace.focusedPane)?.hasUnsavedChanges == true)
    }

    /// Atomic path replacement silently detaches one name of a hard-linked
    /// document. Refuse rather than making two names that used to be one file
    /// disagree about which edit was saved.
    func testSaveRefusesHardLinkedOriginalWithoutBreakingAliasSemantics() throws {
        let file = directory.appendingPathComponent("Note.md")
        let alias = directory.appendingPathComponent("Alias.md")
        try Data("baseline".utf8).write(to: file)
        try FileManager.default.linkItem(at: file, to: alias)

        let workspace = Workspace(documentIO: LocalDocumentIO(), transactionRegistry: ProcessFileTransactionRegistry())
        try workspace.open(file, in: workspace.focusedPane)
        XCTAssertTrue(workspace.updateText("mine", in: workspace.focusedPane))

        XCTAssertThrowsError(try workspace.save(in: workspace.focusedPane))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "baseline")
        XCTAssertEqual(try String(contentsOf: alias, encoding: .utf8), "baseline")
        XCTAssertTrue(workspace.document(in: workspace.focusedPane)?.hasUnsavedChanges == true)
    }
}
