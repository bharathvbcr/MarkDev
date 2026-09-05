//
//  RecoveryJournalTests.swift
//  MarkDevKitTests
//
//  Durable, bounded recovery-observation persistence.
//

import Darwin
import Foundation
import XCTest
@testable import MarkDevKit

final class RecoveryJournalTests: XCTestCase {
    private final class LockedValue<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value

        init(_ value: Value) {
            stored = value
        }

        func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
            lock.lock()
            defer { lock.unlock() }
            return body(&stored)
        }

        var value: Value {
            withLock { $0 }
        }
    }

    private enum DestinationTopology: CaseIterable {
        case absent
        case old
        case new
        case foreign
    }

    private enum StageTopology: CaseIterable {
        case absent
        case expected
        case foreign
    }

    private enum ExpectedReconciliation {
        case reusable
        case published
        case review
    }

    private struct ReconciliationFixture {
        let entry: RecoveryJournalEntry
        let expected: ExpectedReconciliation
        let directory: URL
    }

    private var root: URL!
    private var journalDirectory: URL!
    private var documentDirectory: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MarkDev-RecoveryJournal-\(UUID().uuidString)",
            isDirectory: true)
        journalDirectory = root.appendingPathComponent("journal", isDirectory: true)
        documentDirectory = root.appendingPathComponent("documents", isDirectory: true)
        try FileManager.default.createDirectory(
            at: journalDirectory,
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: documentDirectory,
            withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testProductionStorageRejectsRemoteAuthorityBeforeStandardizingItsPath() throws {
        let hostile = try XCTUnwrap(
            URL(string: "file://remote.example\(root.path)/"))

        XCTAssertThrowsError(
            try RecoveryJournal.production(applicationSupportDirectory: hostile)
        ) { error in
            XCTAssertEqual(
                error as? RecoveryJournalError,
                .invalidStorage(.operation(.openDirectory, errno: EINVAL)))
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("MarkDev").path))
    }

    func testDestinationObservationRejectsRemoteAuthorityBeforeStandardizingItsPath() throws {
        let destination = documentDirectory.appendingPathComponent("Private.md")
        let handle = try SecureLocalDirectoryHandle(opening: documentDirectory)
        let key = try handle.destinationKey(try FileComponent("Private.md"))
        let hostile = try XCTUnwrap(
            URL(string: "file://remote.example\(destination.path)"))

        XCTAssertThrowsError(
            try RecoveryJournalDestinationObservation(
                presentationURL: hostile,
                destinationKey: key)
        ) { error in
            XCTAssertEqual(error as? RecoveryJournalError, .invalidEntry)
        }
    }

    func testRetainedRecoveryAuthoritySurvivesFreshProcessStateViaJournal() throws {
        let destination = documentDirectory.appendingPathComponent("Note.md")
        try Data("before".utf8).write(to: destination)
        let handle = try SecureLocalDirectoryHandle(opening: documentDirectory)
        let component = try FileComponent("Note.md")
        let original = try handle.version(of: component)
        let key = try handle.destinationKey(component)
        let receipt = try handle.transaction(
            component: component,
            data: Data("after".utf8),
            expectation: .exact(original),
            policy: .userContent
        ).commit()
        let recovery = try XCTUnwrap(receipt.recoverySlot)
        let committed = try XCTUnwrap(receipt.version)
        let observation = try RecoveryJournalDestinationObservation(
            presentationURL: destination,
            destinationKey: key)
        let id = UUID()
        let journal = try RecoveryJournal(storageDirectory: journalDirectory)

        _ = try journal.upsert(RecoveryJournalEntry(
            id: id,
            revision: 1,
            phase: .preparing,
            destination: observation,
            expectation: .exact(RecoveryJournalFileVersionObservation(original)),
            stage: nil,
            committedDestinationVersion: nil))
        let prePublishStage = RecoveryJournalStageObservation(
            component: recovery.authority.component,
            version: committed,
            destinationKey: key,
            contents: .unpublishedScratch)
        _ = try journal.upsert(RecoveryJournalEntry(
            id: id,
            revision: 2,
            phase: .staged,
            destination: observation,
            expectation: .exact(RecoveryJournalFileVersionObservation(original)),
            stage: prePublishStage,
            committedDestinationVersion: nil))
        _ = try journal.upsert(RecoveryJournalEntry(
            id: id,
            revision: 3,
            phase: .publishing,
            destination: observation,
            expectation: .exact(RecoveryJournalFileVersionObservation(original)),
            stage: prePublishStage,
            committedDestinationVersion: nil))
        _ = try journal.upsert(RecoveryJournalEntry(
            id: id,
            revision: 4,
            phase: .committed,
            destination: observation,
            expectation: .exact(RecoveryJournalFileVersionObservation(original)),
            stage: RecoveryJournalStageObservation(recovery),
            committedDestinationVersion: RecoveryJournalFileVersionObservation(committed)))

        let relaunched = try RecoveryJournal(
            storageDirectory: journalDirectory,
            openingMode: .existing)
        let entry = try XCTUnwrap(relaunched.load().entries.first)
        let reconciled = try SecureLocalFileSystem.reconcileRecoveryJournalEntry(entry)
        guard case .published(let liveVersion, let liveRecovery) = reconciled else {
            return XCTFail("expected a descriptor-revalidated committed entry")
        }
        XCTAssertEqual(liveVersion, committed)
        XCTAssertEqual(liveRecovery, recovery)
    }

    @MainActor
    func testLiveWorkspaceOverwriteIsPersistedForFreshRegistryReconciliation() throws {
        let journal = try RecoveryJournal(storageDirectory: journalDirectory)
        let destination = documentDirectory.appendingPathComponent("Live.md")
        try Data("before".utf8).write(to: destination)
        let firstRegistry = ProcessFileTransactionRegistry(
            recoveryJournal: journal)
        let firstWorkspace = Workspace(
            documentIO: LocalDocumentIO(),
            transactionRegistry: firstRegistry)
        try firstWorkspace.open(destination, in: firstWorkspace.focusedPane)
        XCTAssertTrue(firstWorkspace.updateText(
            "after", in: firstWorkspace.focusedPane))
        _ = try firstWorkspace.save(in: firstWorkspace.focusedPane)

        // RED before live integration: the process registry owns the exact
        // displaced inode, but the durable repository still has no entry, so
        // a fresh Workspace/registry cannot discover it after relaunch.
        let persisted = try journal.load()
        XCTAssertEqual(persisted.entries.count, 1)
        let entry = try XCTUnwrap(persisted.entries.first)
        XCTAssertEqual(entry.phase, .committed)

        let relaunchedJournal = try RecoveryJournal(
            storageDirectory: journalDirectory,
            openingMode: .existing)
        let freshRegistry = ProcessFileTransactionRegistry(
            recoveryJournal: relaunchedJournal)
        _ = Workspace(
            documentIO: LocalDocumentIO(),
            transactionRegistry: freshRegistry)
        let handle = try SecureLocalDirectoryHandle(opening: documentDirectory)
        let key = try handle.destinationKey(try FileComponent("Live.md"))
        guard case .reusable(_, let slot, _) = freshRegistry.entryForTesting(
            destinationKey: key)
        else {
            return XCTFail("fresh registry must recover the exact displaced inode")
        }
        XCTAssertEqual(slot.contents, .previousDestination)
        XCTAssertEqual(
            try Data(contentsOf: documentDirectory.appendingPathComponent(
                slot.authority.component.rawValue)),
            Data("before".utf8))
    }

    @MainActor
    func testLiveWorkspaceStageCreatedBeforeTokenRequiresReviewWithoutMintingAuthority() throws {
        let journal = try RecoveryJournal(storageDirectory: journalDirectory)
        let destination = documentDirectory.appendingPathComponent("CreateWindow.md")
        let originalBytes = Data("before".utf8)
        try originalBytes.write(to: destination)
        let didInterrupt = LockedValue(false)
        let firstRegistry = ProcessFileTransactionRegistry(
            recoveryJournal: journal,
            journalCheckpointDidPersist: { checkpoint in
                guard checkpoint == .stageCreatedUnobserved else { return nil }
                return didInterrupt.withLock { interrupted in
                    guard !interrupted else { return nil }
                    interrupted = true
                    return RecoveryJournalError.cancelled
                }
            })
        let firstWorkspace = Workspace(
            documentIO: LocalDocumentIO(),
            transactionRegistry: firstRegistry)
        try firstWorkspace.open(destination, in: firstWorkspace.focusedPane)
        XCTAssertTrue(firstWorkspace.updateText(
            "after", in: firstWorkspace.focusedPane))
        XCTAssertThrowsError(try firstWorkspace.save(in: firstWorkspace.focusedPane))
        XCTAssertTrue(didInterrupt.value)
        XCTAssertEqual(try Data(contentsOf: destination), originalBytes)

        let persisted = try journal.load()
        let entry = try XCTUnwrap(persisted.entries.first)
        XCTAssertEqual(persisted.entries.count, 1)
        XCTAssertEqual(entry.phase, .preparing)
        XCTAssertNil(entry.stage)
        let plannedComponent = try XCTUnwrap(entry.plannedStageComponent)
        let plannedURL = documentDirectory.appendingPathComponent(plannedComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: plannedURL.path))
        XCTAssertEqual(try Data(contentsOf: plannedURL), Data())
        let plannedIdentity = try identity(of: plannedURL)

        let handle = try SecureLocalDirectoryHandle(opening: documentDirectory)
        let key = try handle.destinationKey(try FileComponent("CreateWindow.md"))
        for _ in 0..<2 {
            let relaunchedJournal = try RecoveryJournal(
                storageDirectory: journalDirectory,
                openingMode: .existing)
            let freshRegistry = ProcessFileTransactionRegistry(
                recoveryJournal: relaunchedJournal)
            let freshWorkspace = Workspace(
                documentIO: LocalDocumentIO(),
                transactionRegistry: freshRegistry)
            XCTAssertEqual(
                freshWorkspace.recoveryJournalState,
                .requiresReview(.recoveryIncident))
            XCTAssertNil(freshRegistry.entryForTesting(destinationKey: key))
            XCTAssertEqual(try relaunchedJournal.load().entries, [entry])
            XCTAssertEqual(try identity(of: plannedURL), plannedIdentity)
            XCTAssertEqual(try Data(contentsOf: plannedURL), Data())
            XCTAssertEqual(try Data(contentsOf: destination), originalBytes)
        }
    }

    @MainActor
    func testLiveWorkspaceInterruptionAtEveryDurableCheckpointReconcilesAfterRelaunch() throws {
        let checkpoints = RecoveryJournalCheckpoint.allCases.filter {
            $0 != .stageCreatedUnobserved
        }
        for (index, checkpoint) in checkpoints.enumerated() {
            let directories = try freshLiveDirectories(
                "checkpoint-\(index)-\(String(describing: checkpoint))")
            let journal = try RecoveryJournal(storageDirectory: directories.journal)
            let destination = directories.documents.appendingPathComponent("Note.md")
            let originalBytes = Data("before".utf8)
            let replacementBytes = Data("after".utf8)
            try originalBytes.write(to: destination)
            let didInterrupt = LockedValue(false)
            let firstRegistry = ProcessFileTransactionRegistry(
                recoveryJournal: journal,
                journalCheckpointDidPersist: { observed in
                    guard observed == checkpoint else { return nil }
                    return didInterrupt.withLock { interrupted in
                        guard !interrupted else { return nil }
                        interrupted = true
                        return RecoveryJournalError.cancelled
                    }
                })
            let firstWorkspace = Workspace(
                documentIO: LocalDocumentIO(),
                transactionRegistry: firstRegistry)
            try firstWorkspace.open(destination, in: firstWorkspace.focusedPane)
            XCTAssertTrue(firstWorkspace.updateText(
                "after", in: firstWorkspace.focusedPane))
            XCTAssertThrowsError(
                try firstWorkspace.save(in: firstWorkspace.focusedPane),
                "checkpoint \(checkpoint) must interrupt")
            XCTAssertTrue(didInterrupt.value, "checkpoint \(checkpoint) did not fire")

            let persisted = try journal.load()
            let persistedEntry = try XCTUnwrap(
                persisted.entries.first,
                "checkpoint \(checkpoint) lost its durable observation")
            XCTAssertEqual(persisted.entries.count, 1)
            let expectedPhase: RecoveryJournalTransactionPhase
            switch checkpoint {
            case .preparing, .stageObserved:
                expectedPhase = .preparing
            case .staged:
                expectedPhase = .staged
            case .publishing:
                expectedPhase = .publishing
            case .committed:
                expectedPhase = .committed
            case .stageCreatedUnobserved:
                return XCTFail("create-before-token has a dedicated review-only test")
            }
            XCTAssertEqual(persistedEntry.phase, expectedPhase)
            XCTAssertEqual(
                try Data(contentsOf: destination),
                checkpoint == .committed ? replacementBytes : originalBytes)

            let handle = try SecureLocalDirectoryHandle(opening: directories.documents)
            let key = try handle.destinationKey(try FileComponent("Note.md"))
            var priorRecoveredSlot: FileRecoverySlot?
            var generationAfterFirstRelaunch: UInt64?
            for relaunch in 0..<2 {
                let relaunchedJournal = try RecoveryJournal(
                    storageDirectory: directories.journal,
                    openingMode: .existing)
                let freshRegistry = ProcessFileTransactionRegistry(
                    recoveryJournal: relaunchedJournal)
                let freshWorkspace = Workspace(
                    documentIO: LocalDocumentIO(),
                    transactionRegistry: freshRegistry)
                try freshWorkspace.open(destination, in: freshWorkspace.focusedPane)
                XCTAssertEqual(
                    freshWorkspace.document(in: freshWorkspace.focusedPane)?.text,
                    checkpoint == .committed ? "after" : "before")

                switch checkpoint {
                case .preparing:
                    XCTAssertEqual(
                        freshWorkspace.recoveryJournalState,
                        .ready(retainedCount: 0))
                    XCTAssertNil(freshRegistry.entryForTesting(destinationKey: key))
                    XCTAssertTrue(try relaunchedJournal.load().entries.isEmpty)
                case .stageObserved, .staged, .publishing, .committed:
                    XCTAssertEqual(
                        freshWorkspace.recoveryJournalState,
                        .ready(retainedCount: 1))
                    guard case .reusable(_, let slot, _) = freshRegistry.entryForTesting(
                        destinationKey: key)
                    else {
                        XCTFail("checkpoint \(checkpoint) did not restore exact authority")
                        continue
                    }
                    XCTAssertEqual(
                        slot.contents,
                        checkpoint == .committed
                            ? .previousDestination
                            : .unpublishedScratch)
                    if let priorRecoveredSlot {
                        XCTAssertEqual(slot, priorRecoveredSlot)
                    } else {
                        priorRecoveredSlot = slot
                    }
                    let retainedURL = directories.documents.appendingPathComponent(
                        slot.authority.component.rawValue)
                    XCTAssertTrue(FileManager.default.fileExists(atPath: retainedURL.path))
                case .stageCreatedUnobserved:
                    return XCTFail("create-before-token has a dedicated review-only test")
                }

                let afterRelaunch = try relaunchedJournal.load()
                if relaunch == 0 {
                    generationAfterFirstRelaunch = afterRelaunch.generation
                } else {
                    XCTAssertEqual(
                        afterRelaunch.generation,
                        generationAfterFirstRelaunch,
                        "second reconciliation must be idempotent")
                }
            }
        }
    }

    @MainActor
    func testLiveWorkspaceCorruptUnsupportedAndUnavailableJournalFailClosed() throws {
        let corrupt = try freshLiveDirectories("live-corrupt")
        let corruptJournal = try RecoveryJournal(storageDirectory: corrupt.journal)
        for copyName in [RecoveryJournal.copyAFileName, RecoveryJournal.copyBFileName] {
            try overwrite(
                corrupt.journal.appendingPathComponent(copyName),
                with: Data("corrupt".utf8))
        }
        try assertLiveWorkspaceSaveIsJournalBlocked(
            registry: ProcessFileTransactionRegistry(
                recoveryJournal: corruptJournal),
            expectedIssue: .corrupt,
            destination: corrupt.documents.appendingPathComponent("Corrupt.md"))

        let unsupported = try freshLiveDirectories("live-unsupported")
        let unsupportedJournal = try RecoveryJournal(storageDirectory: unsupported.journal)
        let unsupportedCopy = unsupported.journal.appendingPathComponent(
            RecoveryJournal.copyAFileName)
        var unsupportedBytes = try Data(contentsOf: unsupportedCopy)
        unsupportedBytes[RecoveryJournalDiskFormat.recordMagic.count + 3] ^= 0x01
        try overwrite(unsupportedCopy, with: unsupportedBytes)
        try assertLiveWorkspaceSaveIsJournalBlocked(
            registry: ProcessFileTransactionRegistry(
                recoveryJournal: unsupportedJournal),
            expectedIssue: .unsupportedSchema,
            destination: unsupported.documents.appendingPathComponent("Unsupported.md"))

        let unavailable = try freshLiveDirectories("live-unavailable")
        try assertLiveWorkspaceSaveIsJournalBlocked(
            registry: ProcessFileTransactionRegistry(
                journalStartupFailure: .applicationSupportUnavailable),
            expectedIssue: .applicationSupportUnavailable,
            destination: unavailable.documents.appendingPathComponent("Unavailable.md"))
    }

    @MainActor
    func testLiveWorkspaceReconciliationIsIdempotentAcrossFreshRegistries() throws {
        let journal = try RecoveryJournal(storageDirectory: journalDirectory)
        let destination = documentDirectory.appendingPathComponent("Idempotent.md")
        try Data("before".utf8).write(to: destination)
        do {
            let registry = ProcessFileTransactionRegistry(recoveryJournal: journal)
            let workspace = Workspace(
                documentIO: LocalDocumentIO(),
                transactionRegistry: registry)
            try workspace.open(destination, in: workspace.focusedPane)
            XCTAssertTrue(workspace.updateText("after", in: workspace.focusedPane))
            _ = try workspace.save(in: workspace.focusedPane)
        }

        let baselineJournal = try journal.load()
        let baselineFiles = try physicalSnapshot(in: documentDirectory)
        XCTAssertEqual(baselineJournal.entries.count, 1)
        let handle = try SecureLocalDirectoryHandle(opening: documentDirectory)
        let key = try handle.destinationKey(try FileComponent("Idempotent.md"))
        var firstSlot: FileRecoverySlot?

        for _ in 0..<3 {
            let relaunchedJournal = try RecoveryJournal(
                storageDirectory: journalDirectory,
                openingMode: .existing)
            let registry = ProcessFileTransactionRegistry(
                recoveryJournal: relaunchedJournal)
            let workspace = Workspace(
                documentIO: LocalDocumentIO(),
                transactionRegistry: registry)
            XCTAssertEqual(workspace.recoveryJournalState, .ready(retainedCount: 1))
            guard case .reusable(_, let slot, _) = registry.entryForTesting(
                destinationKey: key)
            else {
                return XCTFail("fresh registry did not retain exact recovery authority")
            }
            XCTAssertEqual(slot.contents, .previousDestination)
            if let firstSlot {
                XCTAssertEqual(slot, firstSlot)
            } else {
                firstSlot = slot
            }
            XCTAssertEqual(try relaunchedJournal.load(), baselineJournal)
            XCTAssertEqual(try physicalSnapshot(in: documentDirectory), baselineFiles)
        }
    }

    @MainActor
    func testOneHundredLiveSavesAcrossRelaunchRetainOneComponentAndTwoInodes() throws {
        let destination = documentDirectory.appendingPathComponent("Bounded.md")
        try Data("v0".utf8).write(to: destination)
        var observedIdentities = Set<LocalFileIdentity>()
        var retainedComponent: FileComponent?

        do {
            let journal = try RecoveryJournal(storageDirectory: journalDirectory)
            let registry = ProcessFileTransactionRegistry(recoveryJournal: journal)
            let workspace = Workspace(
                documentIO: LocalDocumentIO(),
                transactionRegistry: registry)
            try workspace.open(destination, in: workspace.focusedPane)
            let handle = try SecureLocalDirectoryHandle(opening: documentDirectory)
            let key = try handle.destinationKey(try FileComponent("Bounded.md"))

            for generation in 1...99 {
                let next = "v\(generation)"
                XCTAssertTrue(workspace.updateText(next, in: workspace.focusedPane))
                _ = try workspace.save(in: workspace.focusedPane)
                guard case .reusable(_, let slot, _) = registry.entryForTesting(
                    destinationKey: key)
                else {
                    return XCTFail("save \(generation) lost the retained slot")
                }
                XCTAssertEqual(slot.contents, .previousDestination)
                if let retainedComponent {
                    XCTAssertEqual(slot.authority.component, retainedComponent)
                } else {
                    retainedComponent = slot.authority.component
                }
                let recoveryURL = documentDirectory.appendingPathComponent(
                    slot.authority.component.rawValue)
                observedIdentities.insert(try identity(of: destination))
                observedIdentities.insert(try identity(of: recoveryURL))
                XCTAssertEqual(observedIdentities.count, 2)
                XCTAssertEqual(
                    try Data(contentsOf: recoveryURL),
                    Data("v\(generation - 1)".utf8))
                XCTAssertEqual(try journal.load().entries.count, 1)
                XCTAssertEqual(
                    try names(in: documentDirectory),
                    Set(["Bounded.md", slot.authority.component.rawValue]))
            }
        }

        let relaunchedJournal = try RecoveryJournal(
            storageDirectory: journalDirectory,
            openingMode: .existing)
        let relaunchedRegistry = ProcessFileTransactionRegistry(
            recoveryJournal: relaunchedJournal)
        let relaunchedWorkspace = Workspace(
            documentIO: LocalDocumentIO(),
            transactionRegistry: relaunchedRegistry)
        XCTAssertEqual(
            relaunchedWorkspace.recoveryJournalState,
            .ready(retainedCount: 1))
        try relaunchedWorkspace.open(destination, in: relaunchedWorkspace.focusedPane)
        XCTAssertTrue(relaunchedWorkspace.updateText(
            "v100", in: relaunchedWorkspace.focusedPane))
        _ = try relaunchedWorkspace.save(in: relaunchedWorkspace.focusedPane)

        let handle = try SecureLocalDirectoryHandle(opening: documentDirectory)
        let key = try handle.destinationKey(try FileComponent("Bounded.md"))
        guard case .reusable(_, let finalSlot, _) = relaunchedRegistry.entryForTesting(
            destinationKey: key)
        else { return XCTFail("the relaunched save lost the retained slot") }
        XCTAssertEqual(
            finalSlot.authority.component,
            try XCTUnwrap(retainedComponent))
        let finalRecoveryURL = documentDirectory.appendingPathComponent(
            finalSlot.authority.component.rawValue)
        observedIdentities.insert(try identity(of: destination))
        observedIdentities.insert(try identity(of: finalRecoveryURL))
        XCTAssertEqual(observedIdentities.count, 2)
        XCTAssertEqual(try Data(contentsOf: destination), Data("v100".utf8))
        XCTAssertEqual(try Data(contentsOf: finalRecoveryURL), Data("v99".utf8))
        let finalSnapshot = try relaunchedJournal.load()
        XCTAssertEqual(finalSnapshot.entries.count, 1)
        XCTAssertEqual(finalSnapshot.entries.first?.phase, .committed)
        XCTAssertEqual(
            try names(in: documentDirectory),
            Set(["Bounded.md", finalSlot.authority.component.rawValue]))
    }

    func testEveryPhaseAndDestinationStageTopologyReconcilesIdempotentlyOrFailsClosed() throws {
        let phases: [RecoveryJournalTransactionPhase] = [
            .preparing, .staged, .publishing, .committed, .indeterminate,
        ]
        var index = 0
        for phase in phases {
            for destination in DestinationTopology.allCases {
                for stage in StageTopology.allCases {
                    index += 1
                    let fixture = try reconciliationFixture(
                        phase: phase,
                        destination: destination,
                        stage: stage,
                        index: index)
                    let before = try physicalSnapshot(in: fixture.directory)
                    let first = try SecureLocalFileSystem.reconcileRecoveryJournalEntry(
                        fixture.entry)
                    let second = try SecureLocalFileSystem.reconcileRecoveryJournalEntry(
                        fixture.entry)
                    XCTAssertEqual(first, second, "\(phase) \(destination) \(stage)")
                    switch fixture.expected {
                    case .reusable:
                        guard case .reusable(let slot) = first else {
                            XCTFail("expected reusable: \(phase) \(destination) \(stage)")
                            continue
                        }
                        XCTAssertEqual(slot.authority.component.rawValue, "scratch")
                    case .published:
                        guard case .published(_, let slot) = first else {
                            XCTFail("expected published: \(phase) \(destination) \(stage)")
                            continue
                        }
                        XCTAssertEqual(slot?.authority.component.rawValue, "scratch")
                    case .review:
                        XCTAssertEqual(first, .requiresReview)
                    }
                    XCTAssertEqual(
                        try physicalSnapshot(in: fixture.directory),
                        before,
                        "reconciliation must not mutate or delete any artifact")
                }
            }
        }
    }

    func testPreparingWithoutStageIsNoRecoveryOnlyWhileExpectationStillHolds() throws {
        let destination = documentDirectory.appendingPathComponent("Note.md")
        try Data("old".utf8).write(to: destination)
        let handle = try SecureLocalDirectoryHandle(opening: documentDirectory)
        let component = try FileComponent("Note.md")
        let old = try handle.version(of: component)
        let key = try handle.destinationKey(component)
        let entry = RecoveryJournalEntry(
            id: UUID(), revision: 1, phase: .preparing,
            destination: try RecoveryJournalDestinationObservation(
                presentationURL: destination,
                destinationKey: key),
            expectation: .exact(RecoveryJournalFileVersionObservation(old)),
            stage: nil,
            committedDestinationVersion: nil)
        XCTAssertEqual(
            try SecureLocalFileSystem.reconcileRecoveryJournalEntry(entry),
            .noRecovery)
        try overwrite(destination, with: Data("foreign".utf8))
        XCTAssertEqual(
            try SecureLocalFileSystem.reconcileRecoveryJournalEntry(entry),
            .requiresReview)
    }

    func testMissingDestinationInterruptedPublishIsResolvedWithoutInventingRecovery() throws {
        let destination = documentDirectory.appendingPathComponent("New.md")
        let stage = documentDirectory.appendingPathComponent("scratch")
        try Data("new".utf8).write(to: stage)
        let handle = try SecureLocalDirectoryHandle(opening: documentDirectory)
        let destinationComponent = try FileComponent("New.md")
        let stageComponent = try FileComponent("scratch")
        let key = try handle.destinationKey(destinationComponent)
        let stageBefore = try handle.version(of: stageComponent)
        let observation = try RecoveryJournalDestinationObservation(
            presentationURL: destination,
            destinationKey: key)
        let entry = RecoveryJournalEntry(
            id: UUID(), revision: 1, phase: .publishing,
            destination: observation,
            expectation: .missing,
            stage: RecoveryJournalStageObservation(
                component: stageComponent,
                version: stageBefore,
                destinationKey: key,
                contents: .unpublishedScratch),
            committedDestinationVersion: nil)
        try FileManager.default.moveItem(at: stage, to: destination)

        let first = try SecureLocalFileSystem.reconcileRecoveryJournalEntry(entry)
        guard case .published(let version, nil) = first else {
            return XCTFail("missing-target rename must reconcile as published")
        }
        XCTAssertTrue(
            RecoveryJournalFileVersionObservation(stageBefore).matchesAcrossRename(version))
        XCTAssertEqual(
            try SecureLocalFileSystem.reconcileRecoveryJournalEntry(entry),
            first)
    }

    func testReconciliationCancellationNeverConstructsAuthority() throws {
        let fixture = try reconciliationFixture(
            phase: .staged,
            destination: .old,
            stage: .expected,
            index: 10_000)
        XCTAssertThrowsError(try SecureLocalFileSystem.reconcileRecoveryJournalEntry(
            fixture.entry,
            cancellationCheck: { true })) { error in
                XCTAssertEqual(error as? SecureLocalFileError, .cancelled)
            }
    }

    func testNameSubstitutionAtEachReconciliationOpenBoundaryNeverMintsAuthority() throws {
        for target in ["Note.md", "scratch"] {
            let fixture = try reconciliationFixture(
                phase: .staged,
                destination: .old,
                stage: .expected,
                index: target == "Note.md" ? 20_001 : 20_002)
            let targetURL = fixture.directory.appendingPathComponent(target)
            let retained = fixture.directory.appendingPathComponent("retained-\(target)")
            let bystander = Data("bystander-\(target)".utf8)
            var calls = SecureFileSyscalls.live
            let liveOpen = calls.openAt
            var injected = false
            calls.openAt = { parent, name, flags in
                if !injected, String(cString: name) == target {
                    injected = true
                    guard self.move(targetURL, to: retained) == 0 else {
                        return -1
                    }
                    do {
                        try self.createPrivateFile(at: targetURL, data: bystander)
                    } catch {
                        XCTFail("could not install open-boundary bystander: \(error)")
                        errno = EIO
                        return -1
                    }
                }
                return liveOpen(parent, name, flags)
            }
            XCTAssertEqual(
                try SecureLocalFileSystem.reconcileRecoveryJournalEntry(
                    fixture.entry,
                    syscalls: calls),
                .requiresReview)
            XCTAssertTrue(injected)
            XCTAssertEqual(try Data(contentsOf: targetURL), bystander)
            XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
        }
    }

    func testInitializationCreatesOnlyFixedPrivateSingleLinkedInodesAndSyncsParent() throws {
        var calls = RecoveryJournalSyscalls.live
        let liveOpenPath = calls.files.openPath
        let liveSync = calls.files.fsync
        var directoryDescriptors = Set<Int32>()
        var syncedDescriptors: [Int32] = []
        calls.files.openPath = { path, flags in
            let descriptor = liveOpenPath(path, flags)
            if descriptor >= 0 { directoryDescriptors.insert(descriptor) }
            return descriptor
        }
        calls.files.fsync = { descriptor in
            syncedDescriptors.append(descriptor)
            return liveSync(descriptor)
        }

        let journal = try RecoveryJournal(
            storageDirectory: journalDirectory,
            syscalls: calls)
        XCTAssertEqual(try journal.load().generation, 1)
        XCTAssertEqual(try journalNames(), Set([
            RecoveryJournal.lockFileName,
            RecoveryJournal.copyAFileName,
            RecoveryJournal.copyBFileName,
        ]))
        for url in journalFileURLs() {
            let status = try status(of: url)
            XCTAssertEqual(status.st_mode & S_IFMT, S_IFREG)
            XCTAssertEqual(status.st_mode & mode_t(0o7777), 0o600)
            XCTAssertEqual(status.st_uid, geteuid())
            XCTAssertEqual(status.st_nlink, 1)
            let descriptor = try openReadOnly(url)
            defer { _ = Darwin.close(descriptor) }
            XCTAssertNoThrow(try verifyEmptyExtendedACL(on: descriptor))
        }
        XCTAssertTrue(
            syncedDescriptors.contains(where: directoryDescriptors.contains),
            "first creation must fsync the containing directory")
        XCTAssertGreaterThanOrEqual(syncedDescriptors.count, 4)
    }

    func testOneThousandUpdatesAlternateWithoutAddingNamesOrChangingInodes() throws {
        let journal = try RecoveryJournal(storageDirectory: journalDirectory)
        let identities = try journalFileURLs().map { try identity(of: $0) }
        let id = UUID()
        for revision in 1...1_000 {
            _ = try journal.upsert(try preparingEntry(
                id: id,
                revision: UInt64(revision)))
        }
        let snapshot = try journal.load()
        XCTAssertEqual(snapshot.generation, 1_001)
        XCTAssertEqual(snapshot.entries, [try preparingEntry(id: id, revision: 1_000)])
        XCTAssertEqual(try journalNames().count, 3)
        XCTAssertEqual(try journalFileURLs().map { try identity(of: $0) }, identities)

        let a = try decodedRecord(.a)
        let b = try decodedRecord(.b)
        XCTAssertEqual(Set([a.generation, b.generation]), Set([1_000, 1_001]))
    }

    func testExistingModeDistinguishesFirstUseFromMissingSet() throws {
        XCTAssertThrowsError(try RecoveryJournal(
            storageDirectory: journalDirectory,
            openingMode: .existing)
        ) { error in
            XCTAssertEqual(error as? RecoveryJournalError, .incompleteFileSet)
        }
        XCTAssertEqual(try journalNames(), [])
    }

    func testLaterMissingCopyIsNeverSilentlyRecreated() throws {
        _ = try RecoveryJournal(storageDirectory: journalDirectory)
        let copy = journalURL(for: .b)
        let retained = journalDirectory.appendingPathComponent("retained-b")
        try FileManager.default.moveItem(at: copy, to: retained)

        XCTAssertThrowsError(try RecoveryJournal(storageDirectory: journalDirectory)) { error in
            XCTAssertEqual(error as? RecoveryJournalError, .incompleteFileSet)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
    }

    func testCrashCreationBoundariesResumeOnlyProvableEmptyInitialSet() throws {
        enum Boundary: CaseIterable { case lock, copyA, copyB }
        for boundary in Boundary.allCases {
            let directory = try freshJournalDirectory("boundary-\(boundary)")
            try createPrivateFile(at: directory.appendingPathComponent(
                RecoveryJournal.lockFileName))
            if boundary != .lock {
                try createPrivateFile(at: directory.appendingPathComponent(
                    RecoveryJournal.copyAFileName))
            }
            if boundary == .copyB {
                try createPrivateFile(at: directory.appendingPathComponent(
                    RecoveryJournal.copyBFileName))
            }
            let recovered = try RecoveryJournal(storageDirectory: directory)
            XCTAssertEqual(try recovered.load().generation, 1, "\(boundary)")
            XCTAssertEqual(try names(in: directory).count, 3, "\(boundary)")
        }
    }

    func testCrashAfterOneOrBothCanonicalInitialWritesResumesSameFileSet() throws {
        let fileSetID = UUID()
        let initial = try RecoveryJournalDiskFormat.encodeRecord(
            fileSetID: fileSetID,
            generation: 1,
            entries: [])
        for writtenCopies in 1...2 {
            let directory = try freshJournalDirectory("written-\(writtenCopies)")
            try createPrivateFile(at: directory.appendingPathComponent(
                RecoveryJournal.lockFileName))
            try createPrivateFile(
                at: directory.appendingPathComponent(RecoveryJournal.copyAFileName),
                data: initial)
            try createPrivateFile(
                at: directory.appendingPathComponent(RecoveryJournal.copyBFileName),
                data: writtenCopies == 2 ? initial : Data())
            let recovered = try RecoveryJournal(storageDirectory: directory)
            XCTAssertEqual(recovered.fileSetID, fileSetID)
            XCTAssertEqual(try recovered.load().generation, 1)
        }
    }

    func testInjectedBootstrapFailuresAtEveryCreateTruncateAndSyncBoundaryResume() throws {
        for failingCreate in 1...3 {
            let directory = try freshJournalDirectory("create-failure-\(failingCreate)")
            var calls = RecoveryJournalSyscalls.live
            let liveCreate = calls.files.createAt
            var count = 0
            calls.files.createAt = { parent, name, flags, mode in
                count += 1
                guard count != failingCreate else {
                    errno = EIO
                    return -1
                }
                return liveCreate(parent, name, flags, mode)
            }
            XCTAssertThrowsError(try RecoveryJournal(
                storageDirectory: directory,
                syscalls: calls))
            XCTAssertEqual(
                try RecoveryJournal(storageDirectory: directory).load().generation,
                1)
        }

        for failingTruncate in 1...3 {
            let directory = try freshJournalDirectory("truncate-failure-\(failingTruncate)")
            var calls = RecoveryJournalSyscalls.live
            let liveTruncate = calls.files.ftruncate
            var count = 0
            calls.files.ftruncate = { descriptor, length in
                count += 1
                guard count != failingTruncate else {
                    errno = EIO
                    return -1
                }
                return liveTruncate(descriptor, length)
            }
            XCTAssertThrowsError(try RecoveryJournal(
                storageDirectory: directory,
                syscalls: calls))
            XCTAssertEqual(
                try RecoveryJournal(storageDirectory: directory).load().generation,
                1)
        }

        for failingSync in 1...4 {
            let directory = try freshJournalDirectory("sync-failure-\(failingSync)")
            var calls = RecoveryJournalSyscalls.live
            let liveSync = calls.files.fsync
            var count = 0
            calls.files.fsync = { descriptor in
                count += 1
                guard count != failingSync else {
                    errno = EIO
                    return -1
                }
                return liveSync(descriptor)
            }
            XCTAssertThrowsError(try RecoveryJournal(
                storageDirectory: directory,
                syscalls: calls))
            XCTAssertEqual(
                try RecoveryJournal(storageDirectory: directory).load().generation,
                1)
        }
    }

    func testInjectedPartialBootstrapWriteIsAmbiguousAndNeverRepaired() throws {
        let directory = try freshJournalDirectory("partial-write")
        var calls = RecoveryJournalSyscalls.live
        let liveWrite = calls.files.pwrite
        var count = 0
        calls.files.pwrite = { descriptor, bytes, byteCount, offset in
            count += 1
            if count == 1 {
                return liveWrite(descriptor, bytes, max(1, byteCount / 2), offset)
            }
            errno = ENOSPC
            return -1
        }
        XCTAssertThrowsError(try RecoveryJournal(
            storageDirectory: directory,
            syscalls: calls))
        let before = try Data(contentsOf: directory.appendingPathComponent(
            RecoveryJournal.copyAFileName))
        XCTAssertFalse(before.isEmpty)
        XCTAssertThrowsError(try RecoveryJournal(storageDirectory: directory)) { error in
            XCTAssertEqual(error as? RecoveryJournalError, .incompleteFileSet)
        }
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent(
                RecoveryJournal.copyAFileName)),
            before)
    }

    func testPartialOrForeignIncompleteInitializationFailsClosedWithoutMutation() throws {
        for bytes in [Data("MDR".utf8), Data("foreign".utf8)] {
            let directory = try freshJournalDirectory("partial-\(UUID().uuidString)")
            let lock = directory.appendingPathComponent(RecoveryJournal.lockFileName)
            let copy = directory.appendingPathComponent(RecoveryJournal.copyAFileName)
            try createPrivateFile(at: lock)
            try createPrivateFile(at: copy, data: bytes)

            XCTAssertThrowsError(try RecoveryJournal(storageDirectory: directory)) { error in
                XCTAssertEqual(error as? RecoveryJournalError, .incompleteFileSet)
            }
            XCTAssertEqual(try Data(contentsOf: copy), bytes)
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(
                    RecoveryJournal.copyBFileName).path))
        }
    }

    func testRepairRejectsSymlinkOrHardLinkSubstitutionAndPreservesBystander() throws {
        for hardLink in [false, true] {
            let directory = try freshJournalDirectory("substitution-\(hardLink)")
            try createPrivateFile(at: directory.appendingPathComponent(
                RecoveryJournal.lockFileName))
            let bystander = directory.appendingPathComponent("bystander")
            try createPrivateFile(at: bystander, data: Data("keep".utf8))
            let copyA = directory.appendingPathComponent(RecoveryJournal.copyAFileName)
            if hardLink {
                XCTAssertEqual(Darwin.link(bystander.path, copyA.path), 0)
            } else {
                XCTAssertEqual(Darwin.symlink(bystander.path, copyA.path), 0)
            }

            XCTAssertThrowsError(try RecoveryJournal(storageDirectory: directory))
            XCTAssertEqual(try Data(contentsOf: bystander), Data("keep".utf8))
        }
    }

    func testNameSubstitutionDuringRepairNeverWritesOrDeletesBystander() throws {
        try createPrivateFile(at: journalDirectory.appendingPathComponent(
            RecoveryJournal.lockFileName))
        try createPrivateFile(at: journalURL(for: .a))
        try createPrivateFile(at: journalURL(for: .b))
        let retained = journalDirectory.appendingPathComponent("retained-a")
        let bystanderBytes = Data("bystander".utf8)
        var calls = RecoveryJournalSyscalls.live
        let liveWrite = calls.files.pwrite
        var injected = false
        calls.files.pwrite = { descriptor, bytes, count, offset in
            if !injected {
                injected = true
                guard self.move(self.journalURL(for: .a), to: retained) == 0 else {
                    return -1
                }
                do {
                    try self.createPrivateFile(
                        at: self.journalURL(for: .a),
                        data: bystanderBytes)
                } catch {
                    XCTFail("could not install repair-boundary bystander: \(error)")
                    errno = EIO
                    return -1
                }
            }
            return liveWrite(descriptor, bytes, count, offset)
        }

        XCTAssertThrowsError(try RecoveryJournal(
            storageDirectory: journalDirectory,
            syscalls: calls))
        XCTAssertTrue(injected)
        XCTAssertEqual(try Data(contentsOf: journalURL(for: .a)), bystanderBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
    }

    func testLockSubstitutionDuringCommittedUpdateSurfacesIncidentAndPreservesBothNames() throws {
        _ = try RecoveryJournal(storageDirectory: journalDirectory)
        let lockURL = journalDirectory.appendingPathComponent(RecoveryJournal.lockFileName)
        let retained = journalDirectory.appendingPathComponent("retained-lock")
        let bystanderBytes = Data("lock-bystander".utf8)
        var calls = RecoveryJournalSyscalls.live
        let liveTruncate = calls.files.ftruncate
        var injected = false
        calls.files.ftruncate = { descriptor, length in
            if !injected {
                injected = true
                guard self.move(lockURL, to: retained) == 0 else {
                    return -1
                }
                do {
                    try self.createPrivateFile(at: lockURL, data: bystanderBytes)
                } catch {
                    XCTFail("could not install lock-boundary bystander: \(error)")
                    errno = EIO
                    return -1
                }
            }
            return liveTruncate(descriptor, length)
        }
        let journal = try RecoveryJournal(
            storageDirectory: journalDirectory,
            openingMode: .existing,
            syscalls: calls)
        XCTAssertThrowsError(try journal.upsert(try preparingEntry()))
        XCTAssertTrue(injected)
        XCTAssertEqual(try Data(contentsOf: lockURL), bystanderBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
        XCTAssertThrowsError(try RecoveryJournal(
            storageDirectory: journalDirectory,
            openingMode: .existing))
    }

    func testChecksumCoversGenerationFileSetAndPayload() throws {
        _ = try RecoveryJournal(storageDirectory: journalDirectory)
        let original = try Data(contentsOf: journalURL(for: .a))
        for offset in [12, 50, original.count - 1] {
            var corrupted = original
            corrupted[offset] ^= 0x01
            XCTAssertThrowsError(try RecoveryJournalDiskFormat.decodeRecord(corrupted)) { error in
                XCTAssertEqual(error as? RecoveryJournalError, .invalidEntry)
            }
        }
    }

    func testLockManifestRoundTripsExactUUIDWithBinaryZeroIdentityFields() throws {
        let identity = RecoveryJournalFileIdentityObservation(
            device: 0,
            inode: 0x0000_0000_0000_0001,
            generation: 0,
            birthSeconds: 0,
            birthNanoseconds: 0)
        let manifest = RecoveryJournalDiskFormat.FileSetManifest(
            fileSetID: try XCTUnwrap(UUID(
                uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")),
            lockIdentity: identity,
            copyAIdentity: identity,
            copyBIdentity: identity)

        XCTAssertEqual(
            try RecoveryJournalDiskFormat.decodeLockManifest(
                RecoveryJournalDiskFormat.encodeLockManifest(manifest)),
            manifest)
    }

    func testOneCorruptOrTruncatedCopyFallsBackButBothInvalidFailClosed() throws {
        let journal = try RecoveryJournal(storageDirectory: journalDirectory)
        _ = try journal.upsert(try preparingEntry())
        try overwrite(journalURL(for: .b), with: Data("bad".utf8))
        var snapshot = try journal.load()
        XCTAssertEqual(snapshot.generation, 1)
        XCTAssertEqual(snapshot.degradedCopies, [.b])

        try overwrite(journalURL(for: .b), with: Data())
        snapshot = try journal.load()
        XCTAssertEqual(snapshot.degradedCopies, [.b])
        try overwrite(journalURL(for: .a), with: Data("also bad".utf8))
        XCTAssertThrowsError(try journal.load()) { error in
            XCTAssertEqual(error as? RecoveryJournalError, .bothCopiesInvalid)
        }
    }

    func testEqualGenerationDivergenceFailsClosed() throws {
        let journal = try RecoveryJournal(storageDirectory: journalDirectory)
        let a = try RecoveryJournalDiskFormat.encodeRecord(
            fileSetID: journal.fileSetID,
            generation: 9,
            entries: [])
        let b = try RecoveryJournalDiskFormat.encodeRecord(
            fileSetID: journal.fileSetID,
            generation: 9,
            entries: [try preparingEntry()])
        try overwrite(journalURL(for: .a), with: a)
        try overwrite(journalURL(for: .b), with: b)
        XCTAssertThrowsError(try journal.load()) { error in
            XCTAssertEqual(error as? RecoveryJournalError, .equalGenerationDivergence)
        }
    }

    func testForeignFileSetFailsClosedEvenWhenOtherCopyIsValid() throws {
        let journal = try RecoveryJournal(storageDirectory: journalDirectory)
        let foreign = try RecoveryJournalDiskFormat.encodeRecord(
            fileSetID: UUID(),
            generation: 2,
            entries: [])
        try overwrite(journalURL(for: .b), with: foreign)
        XCTAssertThrowsError(try journal.load()) { error in
            XCTAssertEqual(error as? RecoveryJournalError, .fileSetMismatch)
        }
    }

    func testCanonicalPayloadRejectsDuplicateWhitespaceExponentUUIDCaseAndPercentAliases() throws {
        let entry = try preparingEntry(id: try XCTUnwrap(UUID(
            uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")))
        let canonical = try RecoveryJournalDiskFormat.canonicalPayload(entries: [entry])
        let canonicalString = try XCTUnwrap(String(data: canonical, encoding: .utf8))
        let firstBrace = canonicalString.startIndex..<canonicalString.index(
            after: canonicalString.startIndex)
        let mutations: [String] = [
            canonicalString.replacingOccurrences(
                of: "{", with: "{ ", options: [], range: firstBrace),
            canonicalString.replacingOccurrences(
                of: "\"revision\":1", with: "\"revision\":1e0"),
            canonicalString.replacingOccurrences(
                of: entry.id.uuidString, with: entry.id.uuidString.lowercased()),
            canonicalString.replacingOccurrences(
                of: "\"entries\":", with: "\"entries\":[],\"entries\":"),
        ]
        for mutation in mutations {
            let record = try RecoveryJournalDiskFormat.encodeRecord(
                fileSetID: UUID(),
                generation: 1,
                canonicalPayload: Data(mutation.utf8))
            XCTAssertThrowsError(
                try RecoveryJournalDiskFormat.decodeEntries(from: record),
                mutation)
        }

        let spacedURL = documentDirectory.appendingPathComponent("space name.md")
        let spacedHandle = try SecureLocalDirectoryHandle(opening: documentDirectory)
        let spacedComponent = try FileComponent("space name.md")
        let spacedKey = try spacedHandle.destinationKey(spacedComponent)
        let spacedEntry = RecoveryJournalEntry(
            id: UUID(), revision: 1, phase: .preparing,
            destination: try RecoveryJournalDestinationObservation(
                presentationURL: spacedURL,
                destinationKey: spacedKey),
            expectation: .missing,
            stage: nil,
            committedDestinationVersion: nil)
        let spacedPayload = try RecoveryJournalDiskFormat.canonicalPayload(
            entries: [spacedEntry])
        let spacedString = try XCTUnwrap(String(data: spacedPayload, encoding: .utf8))
        let ambiguous = spacedString.replacingOccurrences(of: "%20", with: "%2520")
        let ambiguousRecord = try RecoveryJournalDiskFormat.encodeRecord(
            fileSetID: UUID(), generation: 1, canonicalPayload: Data(ambiguous.utf8))
        XCTAssertThrowsError(
            try RecoveryJournalDiskFormat.decodeEntries(from: ambiguousRecord))

        // File-system URLs on Darwin preserve the exact decomposed component
        // spelling used by descriptor-relative syscalls. Start from that valid
        // spelling, then rewrite only the URL to its canonically equivalent NFC
        // form; the persisted component bytes must prevent alias acceptance.
        let exactComponent = try FileComponent("e\u{301}.md")
        let exactKey = try spacedHandle.destinationKey(exactComponent)
        let exactEntry = RecoveryJournalEntry(
            id: UUID(), revision: 1, phase: .preparing,
            destination: try RecoveryJournalDestinationObservation(
                presentationURL: documentDirectory.appendingPathComponent(
                    exactComponent.rawValue),
                destinationKey: exactKey),
            expectation: .missing,
            stage: nil,
            committedDestinationVersion: nil)
        let exactPayload = try RecoveryJournalDiskFormat.canonicalPayload(
            entries: [exactEntry])
        let exactString = try XCTUnwrap(String(data: exactPayload, encoding: .utf8))
        let alternateURLSpelling = exactString.replacingOccurrences(
            of: "e%CC%81", with: "%C3%A9")
        XCTAssertNotEqual(alternateURLSpelling, exactString)
        let alternateRecord = try RecoveryJournalDiskFormat.encodeRecord(
            fileSetID: UUID(),
            generation: 1,
            canonicalPayload: Data(alternateURLSpelling.utf8))
        XCTAssertThrowsError(
            try RecoveryJournalDiskFormat.decodeEntries(from: alternateRecord))
    }

    func testCanonicalPayloadRejectsExcessiveNestingAndOversizedFieldsOrRecord() throws {
        let nested = Data((String(repeating: "[", count: 17)
            + String(repeating: "]", count: 17)).utf8)
        let nestedRecord = try RecoveryJournalDiskFormat.encodeRecord(
            fileSetID: UUID(), generation: 1, canonicalPayload: nested)
        XCTAssertThrowsError(
            try RecoveryJournalDiskFormat.decodeEntries(from: nestedRecord)
        ) { error in
            XCTAssertEqual(
                error as? RecoveryJournalError,
                .nestingLimitExceeded(maximumDepth: RecoveryJournalLimits.maximumJSONDepth))
        }

        let oversizedBookmark = Data(
            repeating: 0x41,
            count: RecoveryJournalLimits.maximumURLOrBookmarkBytes + 1)
        XCTAssertThrowsError(try RecoveryJournalDiskFormat.canonicalPayload(entries: [
            try preparingEntry(bookmark: oversizedBookmark),
        ])) { error in
            XCTAssertEqual(
                error as? RecoveryJournalError,
                .fieldSizeExceeded(
                    maximumBytes: RecoveryJournalLimits.maximumURLOrBookmarkBytes))
        }

        let largeEntries = try (0..<RecoveryJournalLimits.maximumEntries).map { _ in
            try preparingEntry(
                id: UUID(),
                bookmark: Data(repeating: 0x42, count: 5_000))
        }
        XCTAssertThrowsError(
            try RecoveryJournalDiskFormat.canonicalPayload(entries: largeEntries)
        ) { error in
            XCTAssertEqual(
                error as? RecoveryJournalError,
                .encodedSizeExceeded(maximumBytes: RecoveryJournalLimits.maximumEncodedBytes))
        }
    }

    func testEntryCountRevisionGenerationAndPhaseDomainsAreBounded() throws {
        let journal = try RecoveryJournal(storageDirectory: journalDirectory)
        for _ in 0..<RecoveryJournalLimits.maximumEntries {
            _ = try journal.upsert(try preparingEntry(id: UUID()))
        }
        XCTAssertThrowsError(try journal.upsert(try preparingEntry(id: UUID()))) { error in
            XCTAssertEqual(
                error as? RecoveryJournalError,
                .tooManyEntries(maximum: RecoveryJournalLimits.maximumEntries))
        }
        XCTAssertThrowsError(try RecoveryJournalDiskFormat.encodeRecord(
            fileSetID: journal.fileSetID,
            generation: 0,
            entries: [])) { error in
            XCTAssertEqual(error as? RecoveryJournalError, .invalidEntry)
        }

        let id = UUID()
        let first = try preparingEntry(id: id, revision: 1)
        XCTAssertThrowsError(try RecoveryJournalEntryTransition.validate(
            previous: first,
            next: try preparingEntry(id: id, revision: 3)))
        let maxed = try preparingEntry(id: id, revision: UInt64.max)
        XCTAssertThrowsError(try RecoveryJournalEntryTransition.validate(
            previous: maxed,
            next: try preparingEntry(id: id, revision: 1))) { error in
            XCTAssertEqual(error as? RecoveryJournalError, .revisionExhausted)
        }

        let stageURL = documentDirectory.appendingPathComponent("scratch")
        try Data("scratch".utf8).write(to: stageURL)
        let handle = try SecureLocalDirectoryHandle(opening: documentDirectory)
        let stageComponent = try FileComponent("scratch")
        let destinationComponent = try FileComponent("Note.md")
        let key = try handle.destinationKey(destinationComponent)
        let publishing = RecoveryJournalEntry(
            id: id,
            revision: 2,
            phase: .publishing,
            destination: first.destination,
            expectation: first.expectation,
            stage: RecoveryJournalStageObservation(
                component: stageComponent,
                version: try handle.version(of: stageComponent),
                destinationKey: key,
                contents: .unpublishedScratch),
            committedDestinationVersion: nil)
        XCTAssertThrowsError(try RecoveryJournalEntryTransition.validate(
            previous: first,
            next: publishing)) { error in
            XCTAssertEqual(error as? RecoveryJournalError, .invalidEntry)
        }
    }

    func testGenerationExhaustionDoesNotMutateEitherCopy() throws {
        let journal = try RecoveryJournal(storageDirectory: journalDirectory)
        let maxed = try RecoveryJournalDiskFormat.encodeRecord(
            fileSetID: journal.fileSetID,
            generation: UInt64.max,
            entries: [])
        try overwrite(journalURL(for: .a), with: maxed)
        try overwrite(journalURL(for: .b), with: maxed)
        let before = try journalFileURLs().map { try Data(contentsOf: $0) }
        XCTAssertThrowsError(try journal.upsert(try preparingEntry())) { error in
            XCTAssertEqual(error as? RecoveryJournalError, .generationExhausted)
        }
        XCTAssertEqual(try journalFileURLs().map { try Data(contentsOf: $0) }, before)
    }

    func testPersistentInterruptedTruncateOrWriteIsBoundedAndLeavesOlderCopyReadable() throws {
        for operation in [RecoveryJournalOperation.truncateFile, .writeFile] {
            _ = try RecoveryJournal(storageDirectory: journalDirectory)
            var calls = RecoveryJournalSyscalls.live
            var attempts = 0
            if operation == .truncateFile {
                calls.files.ftruncate = { _, _ in
                    attempts += 1
                    errno = EINTR
                    return -1
                }
            } else {
                calls.files.pwrite = { _, _, _, _ in
                    attempts += 1
                    errno = EINTR
                    return -1
                }
            }
            let injected = try RecoveryJournal(
                storageDirectory: journalDirectory,
                openingMode: .existing,
                syscalls: calls)
            XCTAssertThrowsError(try injected.upsert(try preparingEntry())) { error in
                XCTAssertEqual(
                    error as? RecoveryJournalError,
                    .operation(operation, errno: EINTR))
            }
            XCTAssertEqual(attempts, RecoveryJournalLimits.maximumInterruptedSyscallAttempts)
            XCTAssertEqual(try RecoveryJournal(
                storageDirectory: journalDirectory,
                openingMode: .existing).load().generation, 1)
            try resetJournalDirectory()
        }
    }

    func testEffectThenInterruptedWriteIsIdempotentlyRetriedAtSameOffset() throws {
        _ = try RecoveryJournal(storageDirectory: journalDirectory)
        var calls = RecoveryJournalSyscalls.live
        let liveWrite = calls.files.pwrite
        var attempts: [(off_t, Int)] = []
        calls.files.pwrite = { descriptor, bytes, count, offset in
            attempts.append((offset, count))
            if attempts.count == 1 {
                XCTAssertEqual(liveWrite(descriptor, bytes, count, offset), count)
                errno = EINTR
                return -1
            }
            return liveWrite(descriptor, bytes, count, offset)
        }
        let journal = try RecoveryJournal(
            storageDirectory: journalDirectory,
            openingMode: .existing,
            syscalls: calls)
        let snapshot = try journal.upsert(try preparingEntry())
        XCTAssertEqual(snapshot.generation, 2)
        XCTAssertGreaterThanOrEqual(attempts.count, 2)
        XCTAssertEqual(attempts[0].0, attempts[1].0)
        XCTAssertEqual(attempts[0].1, attempts[1].1)
    }

    func testPartialWriteAndSyncUncertaintyNeverHideOlderValidGeneration() throws {
        _ = try RecoveryJournal(storageDirectory: journalDirectory)
        var partialCalls = RecoveryJournalSyscalls.live
        let liveWrite = partialCalls.files.pwrite
        var writeCalls = 0
        partialCalls.files.pwrite = { descriptor, bytes, count, offset in
            writeCalls += 1
            if writeCalls == 1 {
                return liveWrite(descriptor, bytes, max(1, count / 2), offset)
            }
            errno = ENOSPC
            return -1
        }
        let partial = try RecoveryJournal(
            storageDirectory: journalDirectory,
            openingMode: .existing,
            syscalls: partialCalls)
        XCTAssertThrowsError(try partial.upsert(try preparingEntry()))
        let fallback = try RecoveryJournal(
            storageDirectory: journalDirectory,
            openingMode: .existing).load()
        XCTAssertEqual(fallback.generation, 1)
        XCTAssertEqual(fallback.degradedCopies.count, 1)

        try resetJournalDirectory()
        _ = try RecoveryJournal(storageDirectory: journalDirectory)
        var syncCalls = RecoveryJournalSyscalls.live
        var attempts = 0
        syncCalls.files.fsync = { _ in
            attempts += 1
            errno = EINTR
            return -1
        }
        let uncertain = try RecoveryJournal(
            storageDirectory: journalDirectory,
            openingMode: .existing,
            syscalls: syncCalls)
        XCTAssertThrowsError(try uncertain.upsert(try preparingEntry())) { error in
            XCTAssertEqual(
                error as? RecoveryJournalError,
                .durabilityUncertain(.syncFile, errno: EINTR))
        }
        XCTAssertEqual(attempts, RecoveryJournalLimits.maximumInterruptedSyscallAttempts)
        XCTAssertEqual(try RecoveryJournal(
            storageDirectory: journalDirectory,
            openingMode: .existing).load().generation, 2)
    }

    func testPostEffectSyncUncertaintyMakesIdenticalUpsertRetryIdempotentAndHealsCopy() throws {
        _ = try RecoveryJournal(storageDirectory: journalDirectory)
        let entry = try preparingEntry()
        var calls = RecoveryJournalSyscalls.live
        var syncAttempts = 0
        calls.files.fsync = { _ in
            syncAttempts += 1
            errno = EINTR
            return -1
        }
        let uncertain = try RecoveryJournal(
            storageDirectory: journalDirectory,
            openingMode: .existing,
            syscalls: calls)
        XCTAssertThrowsError(try uncertain.upsert(entry)) { error in
            XCTAssertEqual(
                error as? RecoveryJournalError,
                .durabilityUncertain(.syncFile, errno: EINTR))
        }
        XCTAssertEqual(
            syncAttempts,
            RecoveryJournalLimits.maximumInterruptedSyscallAttempts)

        let reopened = try RecoveryJournal(
            storageDirectory: journalDirectory,
            openingMode: .existing)
        XCTAssertEqual(try reopened.load().entries, [entry])
        let healed = try reopened.upsert(entry)
        XCTAssertEqual(healed.generation, 3)
        for copy in RecoveryJournalCopy.allCases {
            XCTAssertEqual(
                try RecoveryJournalDiskFormat.decodeEntries(
                    from: Data(contentsOf: journalURL(for: copy))),
                [entry])
        }
        XCTAssertEqual(try reopened.upsert(entry).generation, healed.generation)

        let differentSameRevision = try preparingEntry(
            id: entry.id,
            revision: entry.revision,
            bookmark: Data([0x01]))
        let before = try journalFileURLs().map { try Data(contentsOf: $0) }
        XCTAssertThrowsError(try reopened.upsert(differentSameRevision)) { error in
            XCTAssertEqual(error as? RecoveryJournalError, .invalidEntry)
        }
        XCTAssertEqual(try journalFileURLs().map { try Data(contentsOf: $0) }, before)
    }

    func testPostEffectSyncUncertaintyMakesExactRemoveRetryIdempotentButRejectsNewerRevision() throws {
        let initial = try RecoveryJournal(storageDirectory: journalDirectory)
        let entry = try preparingEntry()
        _ = try initial.upsert(entry)

        var calls = RecoveryJournalSyscalls.live
        var syncAttempts = 0
        calls.files.fsync = { _ in
            syncAttempts += 1
            errno = EINTR
            return -1
        }
        let uncertain = try RecoveryJournal(
            storageDirectory: journalDirectory,
            openingMode: .existing,
            syscalls: calls)
        XCTAssertThrowsError(try uncertain.remove(
            id: entry.id,
            expectedRevision: entry.revision)) { error in
                XCTAssertEqual(
                    error as? RecoveryJournalError,
                    .durabilityUncertain(.syncFile, errno: EINTR))
            }
        XCTAssertEqual(
            syncAttempts,
            RecoveryJournalLimits.maximumInterruptedSyscallAttempts)

        let reopened = try RecoveryJournal(
            storageDirectory: journalDirectory,
            openingMode: .existing)
        XCTAssertTrue(try reopened.load().entries.isEmpty)
        let healed = try reopened.remove(
            id: entry.id,
            expectedRevision: entry.revision)
        XCTAssertEqual(healed.generation, 4)
        XCTAssertEqual(
            try reopened.remove(
                id: entry.id,
                expectedRevision: entry.revision).generation,
            healed.generation)

        let newerID = UUID()
        _ = try reopened.upsert(try preparingEntry(id: newerID, revision: 1))
        _ = try reopened.upsert(try preparingEntry(id: newerID, revision: 2))
        XCTAssertThrowsError(try reopened.remove(
            id: newerID,
            expectedRevision: 1)) { error in
                XCTAssertEqual(error as? RecoveryJournalError, .invalidEntry)
            }
    }

    func testLockContentionAndCancellationAreBounded() throws {
        _ = try RecoveryJournal(storageDirectory: journalDirectory)
        for cancels in [false, true] {
            var calls = RecoveryJournalSyscalls.live
            let attempts = LockedValue(0)
            calls.fileLock = { _, operation in
                if operation == LOCK_UN { return 0 }
                attempts.withLock { $0 += 1 }
                errno = EWOULDBLOCK
                return -1
            }
            XCTAssertThrowsError(try RecoveryJournal(
                storageDirectory: journalDirectory,
                openingMode: .existing,
                syscalls: calls,
                cancellationCheck: { cancels && attempts.value >= 3 })
            ) { error in
                XCTAssertEqual(
                    error as? RecoveryJournalError,
                    cancels
                        ? .cancelled
                        : .lockUnavailable(
                            maximumAttempts: RecoveryJournalLimits.maximumLockAttempts))
            }
            XCTAssertEqual(
                attempts.value,
                cancels ? 3 : RecoveryJournalLimits.maximumLockAttempts)
        }
    }

    func testUnlockIsAttemptedExactlyOnceOnSuccessAndFailure() throws {
        _ = try RecoveryJournal(storageDirectory: journalDirectory)
        for fails in [false, true] {
            var calls = RecoveryJournalSyscalls.live
            let liveLock = calls.fileLock
            var unlocks = 0
            calls.fileLock = { descriptor, operation in
                if operation == LOCK_UN {
                    unlocks += 1
                    if fails {
                        errno = EINTR
                        return -1
                    }
                }
                return liveLock(descriptor, operation)
            }
            if fails {
                XCTAssertThrowsError(try RecoveryJournal(
                    storageDirectory: journalDirectory,
                    openingMode: .existing,
                    syscalls: calls)) { error in
                        XCTAssertEqual(
                            error as? RecoveryJournalError,
                            .operation(.releaseLock, errno: EINTR))
                    }
            } else {
                _ = try RecoveryJournal(
                    storageDirectory: journalDirectory,
                    openingMode: .existing,
                    syscalls: calls)
            }
            XCTAssertEqual(unlocks, 1)
        }
    }

    func testBodyFailureStillAttemptsExactlyOneUnlock() throws {
        _ = try RecoveryJournal(storageDirectory: journalDirectory)
        var calls = RecoveryJournalSyscalls.live
        let liveLock = calls.fileLock
        var unlocks = 0
        calls.fileLock = { descriptor, operation in
            if operation == LOCK_UN { unlocks += 1 }
            return liveLock(descriptor, operation)
        }
        let journal = try RecoveryJournal(
            storageDirectory: journalDirectory,
            openingMode: .existing,
            syscalls: calls)
        unlocks = 0
        XCTAssertThrowsError(try journal.upsert(
            try preparingEntry(revision: 2)))
        XCTAssertEqual(unlocks, 1)
    }

    func testBootstrapBodyAndUnlockFailuresAreBothPreserved() throws {
        var calls = RecoveryJournalSyscalls.live
        let liveCreate = calls.files.createAt
        let liveLock = calls.fileLock
        var creates = 0
        var unlocks = 0
        calls.files.createAt = { parent, name, flags, mode in
            creates += 1
            guard creates != 2 else {
                errno = EIO
                return -1
            }
            return liveCreate(parent, name, flags, mode)
        }
        calls.fileLock = { descriptor, operation in
            if operation == LOCK_UN {
                unlocks += 1
                errno = EINTR
                return -1
            }
            return liveLock(descriptor, operation)
        }

        XCTAssertThrowsError(try RecoveryJournal(
            storageDirectory: journalDirectory,
            syscalls: calls)) { error in
                XCTAssertEqual(
                    error as? RecoveryJournalError,
                    .cleanupFailure(
                        primary: .invalidStorage(
                            .operation(.createStage, errno: EIO)),
                        cleanup: .releaseLock,
                        errno: EINTR))
            }
        XCTAssertEqual(unlocks, 1)
    }

    func testOperationBodyAndUnlockFailuresAreBothPreserved() throws {
        _ = try RecoveryJournal(storageDirectory: journalDirectory)
        var calls = RecoveryJournalSyscalls.live
        let liveLock = calls.fileLock
        var unlocks = 0
        calls.fileLock = { descriptor, operation in
            if operation == LOCK_UN {
                unlocks += 1
                if unlocks == 2 {
                    errno = EINTR
                    return -1
                }
            }
            return liveLock(descriptor, operation)
        }
        let journal = try RecoveryJournal(
            storageDirectory: journalDirectory,
            openingMode: .existing,
            syscalls: calls)

        XCTAssertThrowsError(try journal.upsert(
            try preparingEntry(revision: 2))) { error in
                XCTAssertEqual(
                    error as? RecoveryJournalError,
                    .cleanupFailure(
                        primary: .invalidEntry,
                        cleanup: .releaseLock,
                        errno: EINTR))
            }
        XCTAssertEqual(unlocks, 2)
    }

    func testTwoJournalInstancesSerializeConcurrentWritersWithoutLostEntry() throws {
        _ = try RecoveryJournal(storageDirectory: journalDirectory)
        let first = try RecoveryJournal(
            storageDirectory: journalDirectory,
            openingMode: .existing)
        let second = try RecoveryJournal(
            storageDirectory: journalDirectory,
            openingMode: .existing)
        let entries = [try preparingEntry(), try preparingEntry()]
        let queue = DispatchQueue(
            label: "RecoveryJournal.concurrent",
            attributes: .concurrent)
        let group = DispatchGroup()
        let errors = LockedValue<[String]>([])
        for (journal, entry) in zip([first, second], entries) {
            group.enter()
            queue.async {
                defer { group.leave() }
                do { _ = try journal.upsert(entry) }
                catch {
                    errors.withLock { $0.append(String(describing: error)) }
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(errors.value.isEmpty, "\(errors.value)")
        let loaded = try first.load()
        XCTAssertEqual(Set(loaded.entries.map(\.id)), Set(entries.map(\.id)))
    }

    func testModeHardLinkAndNameSubstitutionAreRejectedWithoutDeletingArtifacts() throws {
        for mutation in 0..<3 {
            try resetJournalDirectory()
            _ = try RecoveryJournal(storageDirectory: journalDirectory)
            let copy = journalURL(for: .a)
            let retained = journalDirectory.appendingPathComponent("retained")
            switch mutation {
            case 0:
                XCTAssertEqual(chmod(copy.path, 0o644), 0)
            case 1:
                XCTAssertEqual(Darwin.link(copy.path, retained.path), 0)
            default:
                try FileManager.default.moveItem(at: copy, to: retained)
                try createPrivateFile(at: copy, data: Data("bystander".utf8))
            }
            XCTAssertThrowsError(try RecoveryJournal(
                storageDirectory: journalDirectory,
                openingMode: .existing))
            if mutation == 2 {
                XCTAssertEqual(try Data(contentsOf: copy), Data("bystander".utf8))
                XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
            }
        }
    }

    func testForgedOwnerMetadataIsRejectedAtTrustedChildBoundary() throws {
        _ = try RecoveryJournal(storageDirectory: journalDirectory)
        var calls = RecoveryJournalSyscalls.live
        let liveStat = calls.files.fstat
        calls.files.fstat = { descriptor, status in
            let result = liveStat(descriptor, status)
            if result == 0, status.pointee.st_mode & S_IFMT == S_IFREG {
                status.pointee.st_uid = geteuid() &+ 1
            }
            return result
        }
        XCTAssertThrowsError(try RecoveryJournal(
            storageDirectory: journalDirectory,
            openingMode: .existing,
            syscalls: calls)) { error in
                XCTAssertEqual(
                    error as? RecoveryJournalError,
                    .invalidStorage(.unsupportedEntry))
            }
    }

    func testExistingJournalRejectsExtendedACL() throws {
        _ = try RecoveryJournal(storageDirectory: journalDirectory)
        let copy = journalURL(for: .a)
        try runChmodACL(["+a", "everyone allow read"], at: copy)
        XCTAssertThrowsError(try RecoveryJournal(
            storageDirectory: journalDirectory,
            openingMode: .existing))
        XCTAssertEqual(try Data(contentsOf: copy).isEmpty, false)
    }

    func testJournalNeverUsesRenameMutation() throws {
        var calls = RecoveryJournalSyscalls.live
        var renames = 0
        calls.files.renameAtX = { _, _, _, _, _ in
            renames += 1
            errno = EPERM
            return -1
        }
        let journal = try RecoveryJournal(
            storageDirectory: journalDirectory,
            syscalls: calls)
        _ = try journal.upsert(try preparingEntry())
        XCTAssertEqual(renames, 0)
        XCTAssertEqual(try journalNames().count, 3)
    }

    // MARK: - Helpers

    private func freshLiveDirectories(
        _ name: String
    ) throws -> (journal: URL, documents: URL) {
        let directory = try freshJournalDirectory(name)
        let journal = directory.appendingPathComponent("journal", isDirectory: true)
        let documents = directory.appendingPathComponent("documents", isDirectory: true)
        try FileManager.default.createDirectory(
            at: journal,
            withIntermediateDirectories: false)
        try FileManager.default.createDirectory(
            at: documents,
            withIntermediateDirectories: false)
        return (journal, documents)
    }

    @MainActor
    private func assertLiveWorkspaceSaveIsJournalBlocked(
        registry: ProcessFileTransactionRegistry,
        expectedIssue: WorkspaceRecoveryJournalIssue,
        destination: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let originalBytes = Data("before".utf8)
        try originalBytes.write(to: destination)
        let workspace = Workspace(
            documentIO: LocalDocumentIO(),
            transactionRegistry: registry)
        XCTAssertEqual(
            workspace.recoveryJournalState,
            .requiresReview(expectedIssue),
            file: file,
            line: line)
        try workspace.open(destination, in: workspace.focusedPane)
        XCTAssertTrue(
            workspace.updateText("after", in: workspace.focusedPane),
            file: file,
            line: line)
        XCTAssertThrowsError(
            try workspace.save(in: workspace.focusedPane),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? WorkspaceError,
                .recoveryJournalRequiresReview(expectedIssue),
                file: file,
                line: line)
        }
        XCTAssertEqual(
            try Data(contentsOf: destination),
            originalBytes,
            file: file,
            line: line)
        XCTAssertEqual(
            workspace.document(in: workspace.focusedPane)?.hasUnsavedChanges,
            true,
            file: file,
            line: line)
        XCTAssertEqual(
            workspace.recoveryJournalState,
            .requiresReview(expectedIssue),
            file: file,
            line: line)
    }

    private func reconciliationFixture(
        phase: RecoveryJournalTransactionPhase,
        destination topology: DestinationTopology,
        stage stageTopology: StageTopology,
        index: Int
    ) throws -> ReconciliationFixture {
        let directory = try freshJournalDirectory("reconcile-\(index)")
        let destinationURL = directory.appendingPathComponent("Note.md")
        let stageURL = directory.appendingPathComponent("scratch")
        try Data("old".utf8).write(to: destinationURL)
        try Data("new".utf8).write(to: stageURL)
        let handle = try SecureLocalDirectoryHandle(opening: directory)
        let destinationComponent = try FileComponent("Note.md")
        let stageComponent = try FileComponent("scratch")
        let key = try handle.destinationKey(destinationComponent)
        let original = try handle.version(of: destinationComponent)
        let staged = try handle.version(of: stageComponent)
        let destinationObservation = try RecoveryJournalDestinationObservation(
            presentationURL: destinationURL,
            destinationKey: key)
        let prePublishStage = RecoveryJournalStageObservation(
            component: stageComponent,
            version: staged,
            destinationKey: key,
            contents: .unpublishedScratch)

        if topology == .new {
            try exchange(stageComponent, destinationComponent, in: handle)
        }
        let committedObservation: RecoveryJournalFileVersionObservation
        let committedStage: RecoveryJournalStageObservation
        if topology == .new {
            committedObservation = RecoveryJournalFileVersionObservation(
                try handle.version(of: destinationComponent))
            committedStage = RecoveryJournalStageObservation(
                component: stageComponent,
                version: try handle.version(of: stageComponent),
                destinationKey: key,
                contents: .previousDestination)
        } else {
            committedObservation = RecoveryJournalFileVersionObservation(original)
            committedStage = RecoveryJournalStageObservation(
                component: stageComponent,
                version: staged,
                destinationKey: key,
                contents: .previousDestination)
        }

        switch topology {
        case .absent:
            try FileManager.default.removeItem(at: destinationURL)
        case .foreign:
            try overwrite(destinationURL, with: Data("foreign-destination".utf8))
        case .old, .new:
            break
        }
        switch stageTopology {
        case .absent:
            try FileManager.default.removeItem(at: stageURL)
        case .foreign:
            let retained = directory.appendingPathComponent("retained-stage")
            try FileManager.default.moveItem(at: stageURL, to: retained)
            try Data("foreign-stage".utf8).write(to: stageURL)
        case .expected:
            break
        }

        let stageObservation = phase == .committed ? committedStage : prePublishStage
        let entry = RecoveryJournalEntry(
            id: UUID(),
            revision: 1,
            phase: phase,
            destination: destinationObservation,
            expectation: .exact(RecoveryJournalFileVersionObservation(original)),
            stage: stageObservation,
            committedDestinationVersion: phase == .committed
                ? committedObservation
                : nil)
        let expected: ExpectedReconciliation
        if stageTopology != .expected {
            expected = .review
        } else {
            switch (phase, topology) {
            case (.preparing, .old),
                (.staged, .old),
                (.publishing, .old),
                (.indeterminate, .old):
                expected = .reusable
            case (.publishing, .new),
                (.indeterminate, .new),
                (.committed, .new),
                (.committed, .old):
                expected = .published
            default:
                expected = .review
            }
        }
        return ReconciliationFixture(
            entry: entry,
            expected: expected,
            directory: directory)
    }

    private func exchange(
        _ source: FileComponent,
        _ destination: FileComponent,
        in handle: SecureLocalDirectoryHandle
    ) throws {
        let result = source.rawValue.withCString { sourceName in
            destination.rawValue.withCString { destinationName in
                Darwin.renameatx_np(
                    handle.descriptor,
                    sourceName,
                    handle.descriptor,
                    destinationName,
                    UInt32(RENAME_SWAP | RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH))
            }
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private func physicalSnapshot(in directory: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            let url = directory.appendingPathComponent(name)
            var status = stat()
            let outcome = url.withUnsafeFileSystemRepresentation { path in
                path.map { Darwin.lstat($0, &status) } ?? -1
            }
            guard outcome == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            if status.st_mode & S_IFMT == S_IFREG {
                result[name] = try Data(contentsOf: url)
            } else {
                result[name] = Data()
            }
        }
        return result
    }

    private func preparingEntry(
        id: UUID = UUID(),
        revision: UInt64 = 1,
        bookmark: Data? = nil
    ) throws -> RecoveryJournalEntry {
        let component = try FileComponent("Note.md")
        let handle = try SecureLocalDirectoryHandle(opening: documentDirectory)
        let key = try handle.destinationKey(component)
        let destination = documentDirectory.appendingPathComponent(component.rawValue)
        return RecoveryJournalEntry(
            id: id,
            revision: revision,
            phase: .preparing,
            destination: try RecoveryJournalDestinationObservation(
                presentationURL: destination,
                destinationKey: key,
                bookmark: bookmark),
            expectation: .missing,
            stage: nil,
            committedDestinationVersion: nil)
    }

    private func journalURL(for copy: RecoveryJournalCopy) -> URL {
        journalDirectory.appendingPathComponent(
            copy == .a
                ? RecoveryJournal.copyAFileName
                : RecoveryJournal.copyBFileName)
    }

    private func journalFileURLs() -> [URL] {
        [
            journalDirectory.appendingPathComponent(RecoveryJournal.lockFileName),
            journalURL(for: .a),
            journalURL(for: .b),
        ]
    }

    private func journalNames() throws -> Set<String> {
        try names(in: journalDirectory)
    }

    private func names(in directory: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    }

    private func decodedRecord(
        _ copy: RecoveryJournalCopy
    ) throws -> RecoveryJournalDiskFormat.DecodedRecord {
        try RecoveryJournalDiskFormat.decodeRecord(
            Data(contentsOf: journalURL(for: copy)))
    }

    private func freshJournalDirectory(_ name: String) throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false)
        return directory
    }

    private func resetJournalDirectory() throws {
        try? FileManager.default.removeItem(at: journalDirectory)
        try FileManager.default.createDirectory(
            at: journalDirectory,
            withIntermediateDirectories: false)
    }

    private func status(of url: URL) throws -> stat {
        var value = stat()
        guard url.withUnsafeFileSystemRepresentation({ path in
            path.map { Darwin.lstat($0, &value) } ?? -1
        }) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return value
    }

    private func move(_ source: URL, to destination: URL) -> Int32 {
        source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else {
                    errno = EINVAL
                    return -1
                }
                return Darwin.rename(sourcePath, destinationPath)
            }
        }
    }

    private func identity(of url: URL) throws -> LocalFileIdentity {
        LocalFileIdentity(try status(of: url))
    }

    private func createPrivateFile(at url: URL, data: Data = Data()) throws {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map {
                Darwin.open($0, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            } ?? -1
        }
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { _ = Darwin.close(descriptor) }
        try clearAndVerifyExtendedACL(on: descriptor)
        try write(data, to: descriptor)
        guard Darwin.fsync(descriptor) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private func overwrite(_ url: URL, with data: Data) throws {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map {
                Darwin.open($0, O_WRONLY | O_TRUNC | O_CLOEXEC | O_NOFOLLOW)
            } ?? -1
        }
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { _ = Darwin.close(descriptor) }
        try write(data, to: descriptor)
        guard Darwin.fsync(descriptor) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private func write(_ data: Data, to descriptor: Int32) throws {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { bytes in
                Darwin.pwrite(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    data.count - offset,
                    off_t(offset))
            }
            guard count > 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            offset += count
        }
    }

    private func openReadOnly(_ url: URL) throws -> Int32 {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) } ?? -1
        }
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return descriptor
    }

    private func runChmodACL(_ arguments: [String], at url: URL) throws {
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = arguments + [url.path]
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(
                decoding: errors.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self)
            throw XCTSkip(
                "extended ACL unsupported in this test environment: \(detail)")
        }
    }
}
