//
//  TransientPresentationTests.swift
//  MarkDevKitTests
//

import XCTest

@testable import MarkDevKit

final class TransientPresentationTests: XCTestCase {
    func testProtectedPresentationPreemptsOverlayAndDefersError() {
        let pane = PaneID()
        let closeID = UUID()
        var owner = TransientPresentationCoordinator()

        XCTAssertPresentation(owner.present(.commandPalette, restoringFocusTo: pane))
        XCTAssertPresentation(owner.present(.closeReview(closeID), restoringFocusTo: pane))
        XCTAssertEqual(owner.active?.presentation, .closeReview(closeID))
        XCTAssertEqual(
            owner.present(.graph, restoringFocusTo: pane),
            .refused)
        XCTAssertEqual(
            owner.presentError("disk failed", restoringFocusTo: pane),
            .deferredError)

        let closeGeneration = try! XCTUnwrap(owner.active?.generation)
        guard case .advancedToDeferredError = owner.dismiss(closeGeneration) else {
            return XCTFail("the retained error must follow the close sheet")
        }
        XCTAssertEqual(owner.errorMessage, "disk failed")
        let errorGeneration = try! XCTUnwrap(owner.active?.generation)
        guard case .restoreFocus(let intent) = owner.dismiss(errorGeneration) else {
            return XCTFail("the completed chain must restore focus")
        }
        XCTAssertEqual(intent.pane, pane)
        XCTAssertTrue(owner.consumeFocusRestoration(intent))
        XCTAssertFalse(owner.consumeFocusRestoration(intent))
    }

    func testNativePanelHasOneExactProtectedLease() {
        let pane = PaneID()
        let panelID = UUID()
        var owner = TransientPresentationCoordinator()

        XCTAssertPresentation(owner.present(.graph, restoringFocusTo: pane))
        XCTAssertPresentation(owner.present(.nativePanel(panelID), restoringFocusTo: pane))
        let generation = try! XCTUnwrap(owner.active?.generation)
        XCTAssertEqual(owner.active?.presentation, .nativePanel(panelID))
        XCTAssertEqual(
            owner.present(.nativePanel(UUID()), restoringFocusTo: pane),
            .refused,
            "a second chooser must not overlap the active AppKit sheet")
        XCTAssertEqual(
            owner.present(.closeReview(UUID()), restoringFocusTo: pane),
            .refused,
            "close review must wait for the active AppKit sheet")
        XCTAssertEqual(
            owner.presentError("late failure", restoringFocusTo: pane),
            .deferredError)

        guard case .advancedToDeferredError = owner.dismiss(generation) else {
            return XCTFail("the exact panel completion must advance to its deferred error")
        }
        XCTAssertEqual(owner.errorMessage, "late failure")
        XCTAssertEqual(owner.dismiss(generation), .ignored)
    }

    func testDestructiveOperationRequiresTheExactApprovedPrompt() {
        let pane = PaneID()
        let promptID = UUID()
        let otherID = UUID()
        var owner = TransientPresentationCoordinator()

        XCTAssertEqual(
            owner.present(
                .destructiveOperation(id: promptID, title: "Moving"),
                restoringFocusTo: pane),
            .refused,
            "an operation cannot be installed directly")

        XCTAssertPresentation(owner.present(.destructivePrompt(promptID), restoringFocusTo: pane))
        let promptGeneration = try! XCTUnwrap(owner.active?.generation)
        XCTAssertEqual(
            owner.beginDestructiveOperation(
                promptID: otherID,
                generation: promptGeneration,
                title: "Moving"),
            .refused)
        XCTAssertEqual(owner.active?.presentation, .destructivePrompt(promptID))

        let staleGeneration = TransientPresentationCoordinator.Generation()
        XCTAssertEqual(
            owner.beginDestructiveOperation(
                promptID: promptID,
                generation: staleGeneration,
                title: "Moving"),
            .refused)
        XCTAssertPresentation(
            owner.beginDestructiveOperation(
                promptID: promptID,
                generation: promptGeneration,
                title: "Moving"))
        XCTAssertEqual(
            owner.active?.presentation,
            .destructiveOperation(id: promptID, title: "Moving"))
    }

    func testCloseAndErrorCanNeverMorphIntoDestructiveOperation() {
        let pane = PaneID()
        let closeID = UUID()
        var closeOwner = TransientPresentationCoordinator()
        XCTAssertPresentation(closeOwner.present(.closeReview(closeID), restoringFocusTo: pane))
        let closeGeneration = try! XCTUnwrap(closeOwner.active?.generation)
        XCTAssertEqual(
            closeOwner.beginDestructiveOperation(
                promptID: closeID,
                generation: closeGeneration,
                title: "Moving"),
            .refused)

        var errorOwner = TransientPresentationCoordinator()
        XCTAssertPresentation(errorOwner.presentError("failed", restoringFocusTo: pane))
        let errorGeneration = try! XCTUnwrap(errorOwner.active?.generation)
        XCTAssertEqual(
            errorOwner.beginDestructiveOperation(
                promptID: closeID,
                generation: errorGeneration,
                title: "Moving"),
            .refused)
    }

    func testStaleGenerationAndDoubleCompletionCannotDismissSuccessor() {
        let pane = PaneID()
        var owner = TransientPresentationCoordinator()
        XCTAssertPresentation(owner.present(.commandPalette, restoringFocusTo: pane))
        let first = try! XCTUnwrap(owner.active?.generation)
        guard case .restoreFocus(let firstIntent) = owner.dismiss(first) else {
            return XCTFail("first overlay should dismiss")
        }
        XCTAssertPresentation(owner.present(.graph, restoringFocusTo: pane))
        let second = try! XCTUnwrap(owner.active?.generation)

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(owner.dismiss(first), .ignored)
        XCTAssertEqual(owner.active?.presentation, .graph)
        guard case .restoreFocus(let secondIntent) = owner.dismiss(second) else {
            return XCTFail("successor should dismiss once")
        }
        XCTAssertEqual(owner.dismiss(second), .ignored)
        XCTAssertFalse(owner.consumeFocusRestoration(firstIntent))
        XCTAssertTrue(owner.consumeFocusRestoration(secondIntent))
    }

    private func XCTAssertPresentation(
        _ result: TransientPresentationCoordinator.PresentationResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch result {
        case .presented, .replaced, .alreadyPresented:
            break
        case .deferredError, .refused:
            XCTFail("expected a presentation transition, got \(result)", file: file, line: line)
        }
    }
}
