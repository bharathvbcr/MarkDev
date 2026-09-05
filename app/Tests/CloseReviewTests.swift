//
//  CloseReviewTests.swift
//  MarkDevKitTests
//
//  Persistence action matrices and the asynchronous sheet coordinator.
//

import XCTest

@testable import MarkDevKit

@MainActor
final class CloseReviewTests: XCTestCase {
    private enum TestFailure: Error { case promptDidNotAppear }

    private func document(
        edited: Bool,
        durabilityUnconfirmed: Bool,
        title: String = "Untitled"
    ) -> OpenDocument {
        var document = OpenDocument(text: edited ? "draft" : "")
        document.hasUnsavedChanges = edited
        document.hasUnconfirmedDurability = durabilityUnconfirmed
        return document
    }

    private func presentation(
        edited: Bool = true,
        durabilityUnconfirmed: Bool = false
    ) throws -> DocumentPersistencePresentation {
        try XCTUnwrap(
            DocumentPersistencePresentation(
                document: document(
                    edited: edited,
                    durabilityUnconfirmed: durabilityUnconfirmed)))
    }

    private func waitForPrompt(
        _ coordinator: CloseReviewCoordinator,
        attempts: Int = 100
    ) async throws -> CloseReviewPrompt {
        for _ in 0..<attempts {
            if let prompt = coordinator.prompt { return prompt }
            await Task.yield()
        }
        XCTFail("close-review task did not reach its prompt")
        throw TestFailure.promptDidNotAppear
    }

    // MARK: - Persistence policy

    func testCleanDocumentNeedsNoPresentation() {
        XCTAssertNil(
            DocumentPersistencePresentation(
                document: document(edited: false, durabilityUnconfirmed: false)))
    }

    func testEditedDocumentOffersSaveCloseAnywayAndCancel() throws {
        let value = try presentation(edited: true, durabilityUnconfirmed: false)
        XCTAssertEqual(value.risk, .edited)
        XCTAssertEqual(value.actions, [.save, .closeAnyway, .cancel])
        XCTAssertTrue(value.detail.contains("edits"))
        XCTAssertFalse(value.detail.contains("directory"))
    }

    func testDurabilityOnlyDocumentOffersRetryAndRewriteWithoutClaimingEditsAreLost() throws {
        let value = try presentation(edited: false, durabilityUnconfirmed: true)
        XCTAssertEqual(value.risk, .durabilityUnconfirmed)
        XCTAssertEqual(
            value.actions,
            [.retryDurability, .saveAgain, .closeAnyway, .cancel])
        XCTAssertTrue(value.detail.contains("directory"))
        XCTAssertFalse(value.detail.contains("discard edits"))
    }

    func testEditedAndUnconfirmedDocumentRequiresANewSave() throws {
        let value = try presentation(edited: true, durabilityUnconfirmed: true)
        XCTAssertEqual(value.risk, .editedAndDurabilityUnconfirmed)
        XCTAssertEqual(value.actions, [.saveAgain, .closeAnyway, .cancel])
        XCTAssertFalse(value.actions.contains(.retryDurability))
    }

    func testVaultTrashPresentationNamesTheDestructiveEffectAndAffectedDocuments() {
        let empty = VaultTrashPresentation(targetName: "Archive", affectedDocumentCount: -1)
        let populated = VaultTrashPresentation(targetName: "Archive", affectedDocumentCount: 3)

        XCTAssertEqual(empty.affectedDocumentCount, 0)
        XCTAssertEqual(empty.actions, [.moveToTrash, .cancel])
        XCTAssertTrue(empty.headline.contains("Archive"))
        XCTAssertTrue(populated.detail.contains("3 open documents"))
    }

    func testDestructiveApprovalUsesReviewedSnapshotsAndRejectsConcurrentChanges() throws {
        let clean = OpenDocument(id: UUID(), text: "clean")
        var risky = OpenDocument(id: UUID(), text: "draft", hasUnsavedChanges: true)
        risky.hasUnconfirmedDurability = true
        var reviewed = risky
        reviewed.hasUnsavedChanges = false
        reviewed.hasUnconfirmedDurability = false

        let approval = try XCTUnwrap(
            DestructiveDocumentApproval(
                originalDocuments: [clean, risky],
                reviewedDocuments: [reviewed]))
        XCTAssertEqual(approval.documents, [clean, reviewed])
        XCTAssertTrue(approval.isCurrent([clean, reviewed]))

        var editedWhileConfirming = reviewed
        editedWhileConfirming.text = "successor"
        editedWhileConfirming.hasUnsavedChanges = true
        XCTAssertFalse(approval.isCurrent([clean, editedWhileConfirming]))
        XCTAssertFalse(approval.isCurrent([clean]))
        XCTAssertFalse(approval.isCurrent([clean, reviewed, OpenDocument()]))
        XCTAssertFalse(approval.isCurrent([reviewed, clean]))
    }

    func testDestructiveApprovalRejectsDuplicateAndOutOfScopeReviews() {
        let target = OpenDocument()
        let outsider = OpenDocument()

        XCTAssertNil(
            DestructiveDocumentApproval(
                originalDocuments: [target, target],
                reviewedDocuments: []))
        XCTAssertNil(
            DestructiveDocumentApproval(
                originalDocuments: [target],
                reviewedDocuments: [target, target]))
        XCTAssertNil(
            DestructiveDocumentApproval(
                originalDocuments: [target],
                reviewedDocuments: [outsider]))
    }

    func testEveryOfferedActionHasVisibleCopy() throws {
        let matrices = [
            try presentation(edited: true, durabilityUnconfirmed: false),
            try presentation(edited: false, durabilityUnconfirmed: true),
            try presentation(edited: true, durabilityUnconfirmed: true),
        ]
        for matrix in matrices {
            XCTAssertFalse(matrix.headline.isEmpty)
            XCTAssertFalse(matrix.detail.isEmpty)
            XCTAssertEqual(Set(matrix.actions).count, matrix.actions.count)
            for action in matrix.actions { XCTAssertFalse(action.label.isEmpty) }
        }
    }

    // MARK: - Stable terminal identity

    func testTerminalTitleChangesDoNotChangeTheApprovedProcessGeneration() {
        let sessionID = UUID()
        let before = TerminalCloseRisk(sessionID: sessionID, generation: 7, title: "zsh")
        let after = TerminalCloseRisk(sessionID: sessionID, generation: 7, title: "build")
        let restarted = TerminalCloseRisk(sessionID: sessionID, generation: 8, title: "zsh")

        XCTAssertEqual(before, after)
        XCTAssertNotEqual(before, restarted)
        XCTAssertEqual(Set([before, after, restarted]).count, 2)
    }

    func testEmptyTerminalRiskSetNeedsNoPresentation() {
        XCTAssertNil(TerminalClosePresentation(risks: []))
    }

    func testTerminalPresentationUsesPurposeSpecificConfirmation() throws {
        let risk = TerminalCloseRisk(sessionID: UUID(), generation: 4, title: "build")
        let close = try XCTUnwrap(
            TerminalClosePresentation(risks: [risk], purpose: .closeSessions))
        let restart = try XCTUnwrap(
            TerminalClosePresentation(risks: [risk], purpose: .restartSession))
        let window = try XCTUnwrap(
            TerminalClosePresentation(risks: [risk], purpose: .closeWindow))

        XCTAssertEqual(close.actions, [.stopAndClose, .cancel])
        XCTAssertEqual(restart.actions, [.stopAndRestart, .cancel])
        XCTAssertEqual(window.actions, [.stopAndClose, .cancel])
        XCTAssertTrue(restart.headline.contains("Restart"))
        XCTAssertTrue(window.headline.contains("closing"))
        XCTAssertNil(
            TerminalClosePresentation(
                risks: [risk, risk], purpose: .restartSession),
            "one restart decision must never authorize multiple processes")
    }

    func testSessionWithoutAForkedPTYIsNotATerminalCloseRisk() throws {
        let sessions = TerminalSessions()
        _ = try sessions.open(TerminalSession.resolve(document: nil, vault: nil))
        XCTAssertTrue(sessions.closeRisks.isEmpty)
    }

    func testTerminalCloseRiskTracksTheExactLaunchedGeneration() throws {
        let sessions = TerminalSessions()
        let config = TerminalSession.resolve(document: nil, vault: nil)
        let id = try sessions.open(config)
        let host = try XCTUnwrap(sessions.host(for: id))
        defer { sessions.closeAll() }

        let original = try XCTUnwrap(sessions.closeRisk(for: id))
        XCTAssertTrue(sessions.isCurrent(original))

        // The model asks for a restart first; until the renderer applies it,
        // the old process really is still the process at risk.
        XCTAssertTrue(sessions.restart(id))
        XCTAssertTrue(sessions.isCurrent(original))
        let generation = try XCTUnwrap(sessions.current?.generation)
        host.relaunchIfNeeded(config, generation: generation)

        let replacement = try XCTUnwrap(sessions.closeRisk(for: id))
        XCTAssertNotEqual(original, replacement)
        XCTAssertFalse(sessions.isCurrent(original))
        XCTAssertTrue(sessions.isCurrent(replacement))
        XCTAssertFalse(
            sessions.isUnchangedOrExited(afterReviewing: original),
            "consent for the old process must not authorize its successor")
        XCTAssertTrue(sessions.isUnchangedOrExited(afterReviewing: replacement))
    }

    func testWindowTerminalConsentRejectsNewAndRestartedProcesses() throws {
        let sessions = TerminalSessions()
        let firstID = try sessions.open(TerminalSession.resolve(document: nil, vault: nil))
        let firstHost = try XCTUnwrap(sessions.host(for: firstID))
        defer { sessions.closeAll() }
        let reviewed = sessions.closeRisks
        XCTAssertTrue(sessions.areUnchangedOrExited(afterReviewing: reviewed))

        let secondID = try sessions.open(TerminalSession.resolve(document: nil, vault: nil))
        _ = try XCTUnwrap(sessions.host(for: secondID))
        XCTAssertFalse(sessions.areUnchangedOrExited(afterReviewing: reviewed))

        sessions.close(secondID)
        XCTAssertTrue(sessions.restart(firstID))
        let generation = try XCTUnwrap(sessions.current?.generation)
        firstHost.relaunchIfNeeded(
            TerminalSession.resolve(document: nil, vault: nil),
            generation: generation)
        XCTAssertFalse(sessions.areUnchangedOrExited(afterReviewing: reviewed))
    }

    func testLateExitFromReplacedGenerationCannotMarkTheReplacementDead() throws {
        let sessions = TerminalSessions()
        let id = try sessions.open(TerminalSession.resolve(document: nil, vault: nil))
        XCTAssertTrue(sessions.restart(id))

        sessions.markExited(.code(9), for: id, generation: 0)
        XCTAssertNil(sessions.current?.exit)
        sessions.markExited(.code(0), for: id, generation: 1)
        XCTAssertEqual(sessions.current?.exit, .code(0))
    }

    // MARK: - Autosave suspension ownership

    func testConcurrentCloseReleaseCannotResumeAutosaveUnderTheWinningReview() {
        let gate = AutosaveSuspensionGate()
        let winningReview = gate.acquire()
        let losingReview = gate.acquire()

        XCTAssertTrue(gate.isSuspended)
        XCTAssertFalse(
            gate.release(losingReview),
            "the losing close owns only its token, not the winning review")
        XCTAssertTrue(gate.isSuspended)
        XCTAssertTrue(gate.release(winningReview))
        XCTAssertFalse(gate.isSuspended)
    }

    func testEditWhileCloseSheetIsOpenCannotScheduleUntilRelease() {
        let gate = AutosaveSuspensionGate()
        let review = gate.acquire()
        var scheduledWrites = 0

        if !gate.isSuspended { scheduledWrites += 1 }
        XCTAssertEqual(scheduledWrites, 0)

        XCTAssertTrue(gate.release(review))
        if !gate.isSuspended { scheduledWrites += 1 }
        XCTAssertEqual(scheduledWrites, 1)
    }

    func testViewTeardownInvalidatesEveryTokenAndStaleReleasesStayInert() {
        let gate = AutosaveSuspensionGate()
        let first = gate.acquire()
        let second = gate.acquire()

        XCTAssertTrue(gate.invalidateAll())
        XCTAssertFalse(gate.isSuspended)
        XCTAssertFalse(gate.release(first))
        XCTAssertFalse(gate.release(second))
        XCTAssertFalse(gate.invalidateAll())
    }

    func testSuccessfulCloseReleasesItsTokenExactlyOnce() {
        let gate = AutosaveSuspensionGate()
        let review = gate.acquire()

        XCTAssertTrue(gate.release(review))
        XCTAssertFalse(gate.release(review))
        XCTAssertFalse(gate.isSuspended)
    }

    func testCancelledCloseWhileViewRemainsReleasesItsTokenExactlyOnce() {
        let gate = AutosaveSuspensionGate()
        let cancelledReview = gate.acquire()

        XCTAssertTrue(gate.isSuspended)
        XCTAssertTrue(gate.release(cancelledReview))
        XCTAssertFalse(gate.release(cancelledReview))
        XCTAssertFalse(gate.isSuspended)
    }

    // MARK: - Window close attempt ownership

    func testApprovedDelegateReentryRetainsApprovalUntilWindowWillClose() {
        var gate = WindowCloseAttemptGate()

        XCTAssertTrue(gate.beginReview())
        XCTAssertTrue(gate.approveReview(expectingDelegateReentry: true))
        XCTAssertEqual(
            gate.delegateReentered(originalDelegateApproved: true),
            .approved)
        XCTAssertEqual(gate.phase, .awaitingWindowClose)
        XCTAssertFalse(gate.performCloseReturned())

        gate.windowWillClose()
        XCTAssertEqual(gate.phase, .idle)
        XCTAssertFalse(gate.cancel(), "window close already consumed the attempt")
    }

    func testOriginalDelegateRefusalCancelsApprovalExactlyOnce() {
        var gate = WindowCloseAttemptGate()
        var cancellations = 0

        XCTAssertTrue(gate.beginReview())
        XCTAssertTrue(gate.approveReview(expectingDelegateReentry: true))
        if gate.delegateReentered(originalDelegateApproved: false) == .refused {
            cancellations += 1
        }
        if gate.performCloseReturned() { cancellations += 1 }
        if gate.cancel() { cancellations += 1 }

        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(gate.phase, .idle)
    }

    func testPerformCloseWithoutDelegateReentryCancelsApprovalExactlyOnce() {
        var gate = WindowCloseAttemptGate()
        var cancellations = 0

        XCTAssertTrue(gate.beginReview())
        XCTAssertTrue(gate.approveReview(expectingDelegateReentry: true))
        if gate.performCloseReturned() { cancellations += 1 }
        if gate.performCloseReturned() { cancellations += 1 }
        if gate.cancel() { cancellations += 1 }

        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(gate.phase, .idle)
    }

    func testConcurrentWindowAndQuitReviewsFailClosedWithoutChangingOwner() {
        var gate = WindowCloseAttemptGate()
        var cancellations = 0

        XCTAssertTrue(gate.beginReview(), "window close owns the first review")
        XCTAssertFalse(gate.beginReview(), "concurrent Quit must fail closed")
        XCTAssertEqual(gate.phase, .reviewing)
        if gate.cancel() { cancellations += 1 }
        if gate.cancel() { cancellations += 1 }
        XCTAssertFalse(
            gate.approveReview(expectingDelegateReentry: true),
            "a stale review completion cannot revive the cancelled attempt")

        XCTAssertTrue(gate.beginReview(), "a later Quit may start after cancellation")
        XCTAssertTrue(gate.approveReview(expectingDelegateReentry: false))
        XCTAssertFalse(
            gate.beginReview(),
            "a window close cannot replace termination approval")
        if gate.cancel() { cancellations += 1 }
        if gate.cancel() { cancellations += 1 }

        XCTAssertEqual(cancellations, 2, "each owned attempt releases once")
        XCTAssertEqual(gate.phase, .idle)
    }

    func testTeardownCancelsEveryPreClosePhaseExactlyOnce() {
        var reviewing = WindowCloseAttemptGate()
        XCTAssertTrue(reviewing.beginReview())
        XCTAssertTrue(reviewing.cancel())
        XCTAssertFalse(reviewing.cancel())

        var awaitingDelegate = WindowCloseAttemptGate()
        XCTAssertTrue(awaitingDelegate.beginReview())
        XCTAssertTrue(awaitingDelegate.approveReview(expectingDelegateReentry: true))
        XCTAssertTrue(awaitingDelegate.cancel())
        XCTAssertFalse(awaitingDelegate.cancel())

        var awaitingClose = WindowCloseAttemptGate()
        XCTAssertTrue(awaitingClose.beginReview())
        XCTAssertTrue(awaitingClose.approveReview(expectingDelegateReentry: false))
        XCTAssertTrue(awaitingClose.cancel())
        XCTAssertFalse(awaitingClose.cancel())
    }

    // MARK: - Coordinator lifecycle

    func testDocumentResponseCompletesExactlyThePromptThatWasShown() async throws {
        let coordinator = CloseReviewCoordinator()
        let value = try presentation()
        let request = Task { await coordinator.requestDocument(value) }
        let prompt = try await waitForPrompt(coordinator)
        guard case .document(let promptID, _) = prompt else {
            return XCTFail("expected document prompt")
        }

        coordinator.respond(to: UUID(), with: DocumentCloseReviewAction.closeAnyway)
        XCTAssertEqual(coordinator.prompt, prompt, "a stale sheet response must be ignored")
        coordinator.respond(to: promptID, with: DocumentCloseReviewAction.save)

        let result = await request.value
        XCTAssertEqual(result, .save)
        XCTAssertNil(coordinator.prompt)
        XCTAssertFalse(coordinator.isPresenting)
        // A second response from the old sheet is a no-op, not a double resume.
        coordinator.respond(to: promptID, with: DocumentCloseReviewAction.cancel)
        XCTAssertNil(coordinator.prompt)
    }

    func testTerminalResponseUsesItsOwnTypedActionChannel() async throws {
        let coordinator = CloseReviewCoordinator()
        let risk = TerminalCloseRisk(sessionID: UUID(), generation: 0, title: "build")
        let terminal = try XCTUnwrap(TerminalClosePresentation(risks: [risk]))
        let request = Task { await coordinator.requestTerminals(terminal) }
        let prompt = try await waitForPrompt(coordinator)
        guard case .terminals(let promptID, _) = prompt else {
            return XCTFail("expected terminal prompt")
        }

        coordinator.respond(to: promptID, with: TerminalCloseReviewAction.stopAndClose)
        let result = await request.value
        XCTAssertEqual(result, .stopAndClose)
        XCTAssertNil(coordinator.prompt)
    }

    func testCoordinatorRejectsAnActionThePresentationDidNotOffer() async throws {
        let coordinator = CloseReviewCoordinator()
        let value = try presentation(edited: true, durabilityUnconfirmed: false)
        let request = Task { await coordinator.requestDocument(value) }
        let prompt = try await waitForPrompt(coordinator)

        coordinator.respond(to: prompt.id, with: DocumentCloseReviewAction.retryDurability)
        XCTAssertEqual(coordinator.prompt, prompt)
        coordinator.respond(to: prompt.id, with: DocumentCloseReviewAction.cancel)

        let result = await request.value
        XCTAssertEqual(result, .cancel)
        XCTAssertNil(coordinator.prompt)
    }

    func testRestartPromptRejectsCloseConfirmation() async throws {
        let coordinator = CloseReviewCoordinator()
        let risk = TerminalCloseRisk(sessionID: UUID(), generation: 9, title: "server")
        let value = try XCTUnwrap(
            TerminalClosePresentation(risks: [risk], purpose: .restartSession))
        let request = Task { await coordinator.requestTerminals(value) }
        let prompt = try await waitForPrompt(coordinator)

        coordinator.respond(to: prompt.id, with: TerminalCloseReviewAction.stopAndClose)
        XCTAssertEqual(coordinator.prompt, prompt)
        coordinator.respond(to: prompt.id, with: TerminalCloseReviewAction.stopAndRestart)

        let result = await request.value
        XCTAssertEqual(result, .stopAndRestart)
        XCTAssertNil(coordinator.prompt)
    }

    func testVaultTrashResponseUsesItsOwnTypedActionChannel() async throws {
        let coordinator = CloseReviewCoordinator()
        let presentation = VaultTrashPresentation(
            targetName: "Archive",
            affectedDocumentCount: 2)
        let request = Task { await coordinator.requestVaultTrash(presentation) }
        let prompt = try await waitForPrompt(coordinator)
        guard case .vaultTrash(let promptID, _) = prompt else {
            return XCTFail("expected Trash prompt")
        }

        coordinator.respond(to: promptID, with: DocumentCloseReviewAction.closeAnyway)
        XCTAssertEqual(coordinator.prompt, prompt, "another action channel must be ignored")
        coordinator.respond(to: promptID, with: VaultTrashReviewAction.moveToTrash)

        let result = await request.value
        XCTAssertEqual(result, .moveToTrash)
        XCTAssertNil(coordinator.prompt)
    }

    func testConcurrentCloseAttemptFailsClosedWithoutReplacingTheActiveSheet() async throws {
        let coordinator = CloseReviewCoordinator()
        let value = try presentation()
        let first = Task { await coordinator.requestDocument(value) }
        let original = try await waitForPrompt(coordinator)

        let second = await coordinator.requestDocument(
            try presentation(edited: true, durabilityUnconfirmed: true))
        XCTAssertEqual(second, .cancel)
        XCTAssertEqual(coordinator.prompt, original)

        coordinator.dismiss(promptID: original.id)
        let firstResult = await first.value
        XCTAssertEqual(firstResult, .cancel)
        XCTAssertNil(coordinator.prompt)
    }

    func testCancellingTheAwaitingTaskDismissesTheSheetAndResumesOnce() async throws {
        let coordinator = CloseReviewCoordinator()
        let value = try presentation()
        let request = Task { await coordinator.requestDocument(value) }
        _ = try await waitForPrompt(coordinator)

        request.cancel()
        let result = await request.value
        XCTAssertEqual(result, .cancel)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertNil(coordinator.prompt)
        XCTAssertFalse(coordinator.isPresenting)
    }

    func testCoordinatorSurvivesAThousandSequentialPromptResponses() async throws {
        let coordinator = CloseReviewCoordinator()
        let value = try presentation()

        for index in 0..<1_000 {
            let request = Task { await coordinator.requestDocument(value) }
            let prompt = try await waitForPrompt(coordinator)
            let answer: DocumentCloseReviewAction = index.isMultiple(of: 2) ? .save : .cancel
            coordinator.respond(to: prompt.id, with: answer)
            let result = await request.value
            XCTAssertEqual(result, answer, "mismatch at iteration \(index)")
            XCTAssertNil(coordinator.prompt)
        }
    }
}
