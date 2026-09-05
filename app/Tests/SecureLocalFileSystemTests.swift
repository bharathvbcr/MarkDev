//
//  SecureLocalFileSystemTests.swift
//  MarkDevKitTests
//

import Darwin
import XCTest

@testable import MarkDevKit

final class SecureLocalFileSystemTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkDevSecureIO-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func handle(_ syscalls: SecureFileSyscalls = .live) throws
        -> SecureLocalDirectoryHandle
    {
        try SecureLocalDirectoryHandle(opening: directory, syscalls: syscalls)
    }

    private func names() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    func testDirectoryHandleRejectsRemoteAuthorityBeforeOpeningItsLocalPath() throws {
        let hostile = try XCTUnwrap(
            URL(string: "file://remote.example\(directory.path)/"))

        XCTAssertThrowsError(try SecureLocalDirectoryHandle(opening: hostile)) { error in
            XCTAssertEqual(
                error as? SecureLocalFileError,
                .operation(.openDirectory, errno: EINVAL))
        }
    }

    func testUserContentComponentRejectsRemoteAuthorityBeforeComparingItsPath() throws {
        let content = try UserContentDirectory(containing: directory.appendingPathComponent(
            "Private.md"))
        let hostile = try XCTUnwrap(
            URL(string: "file://remote.example\(directory.path)/Private.md"))

        XCTAssertThrowsError(try content.component(for: hostile)) { error in
            XCTAssertEqual(error as? SecureLocalFileError, .invalidComponent)
        }
    }

    private func retainedPrepublicationReceipt(
        from error: Error,
        cause expectedCause: SecureLocalFileError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> FileTransactionReceipt? {
        guard case let .prepublicationFailure(cause, receipt) =
            error as? SecureLocalFileError
        else {
            XCTFail("unexpected error: \(error)", file: file, line: line)
            return nil
        }
        XCTAssertEqual(cause, expectedCause, file: file, line: line)
        XCTAssertEqual(
            receipt.durability,
            .notPublishedRecoveryRetained,
            file: file,
            line: line)
        XCTAssertNotNil(receipt.recovery, file: file, line: line)
        return receipt
    }

    private func extendedAttributeNames(at url: URL) throws -> Set<String> {
        let length = listxattr(url.path, nil, 0, 0)
        guard length >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard length > 0 else { return [] }
        var bytes = [CChar](repeating: 0, count: length)
        let read = bytes.withUnsafeMutableBufferPointer {
            listxattr(url.path, $0.baseAddress, $0.count, 0)
        }
        guard read == length else { throw POSIXError(.EIO) }
        var result: Set<String> = []
        var start = 0
        while start < bytes.count {
            guard let end = bytes[start...].firstIndex(of: 0), end > start else {
                throw POSIXError(.EIO)
            }
            let terminated = Array(bytes[start..<end]) + [0]
            guard let name = terminated.withUnsafeBufferPointer({ buffer in
                buffer.baseAddress.flatMap(String.init(validatingCString:))
            }) else { throw POSIXError(.EILSEQ) }
            result.insert(name)
            start = end + 1
        }
        return result
    }

    private func extendedACLHasEntries(at url: URL) throws -> Bool {
        errno = 0
        let acl = url.path.withCString { acl_get_file($0, ACL_TYPE_EXTENDED) }
        guard let acl else {
            if errno == ENOENT { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        errno = 0
        let result = acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry)
        if result == 0 { return true }
        if errno == EINVAL { return false }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
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

    func testComponentRejectsTraversalSeparatorsNULAndOverlongNames() throws {
        for invalid in ["", ".", "..", "a/b", "a\0b", String(repeating: "x", count: 256)] {
            XCTAssertThrowsError(try FileComponent(invalid), "accepted \(invalid.debugDescription)")
        }
        XCTAssertNoThrow(try FileComponent(String(repeating: "x", count: 255)))
        XCTAssertNoThrow(try FileComponent(String(repeating: "é", count: 127) + "x"))
        XCTAssertThrowsError(try FileComponent(String(repeating: "é", count: 128)))
    }

    func testTransactionRejectsPayloadAtLimitPlusOneBeforeCreatingStage() throws {
        let handle = try handle()
        XCTAssertNoThrow(
            try handle.transaction(
                component: FileComponent("Exact.bin"),
                data: Data(repeating: 0x41, count: 8),
                expectation: .missing,
                policy: .privateStorage,
                maximumBytes: 8
            ).commit())
        XCTAssertThrowsError(
            try handle.transaction(
                component: FileComponent("TooLarge.bin"),
                data: Data(repeating: 0x42, count: 9),
                expectation: .missing,
                policy: .privateStorage,
                maximumBytes: 8
            ).commit()
        ) { error in
            XCTAssertEqual(error as? SecureLocalFileError, .fileTooLarge(maximumBytes: 8))
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("TooLarge.bin").path))
    }

    func testNameLimitQueryFailureIsNotTreatedAsUnlimited() throws {
        var calls = SecureFileSyscalls.live
        calls.fpathconf = { _, _ in
            errno = EIO
            return -1
        }
        let guarded = try handle(calls)
        XCTAssertThrowsError(
            try guarded.transaction(
                component: FileComponent("Note.md"),
                data: Data("safe".utf8),
                expectation: .missing,
                policy: .userContent
            ).commit()
        ) { error in
            XCTAssertEqual(error as? SecureLocalFileError, .operation(.inspect, errno: EIO))
        }
        XCTAssertEqual(try names(), [])
    }

    func testStageNameCollisionRetriesAreBounded() throws {
        var calls = SecureFileSyscalls.live
        var attempts = 0
        calls.createAt = { _, _, _, _ in
            attempts += 1
            errno = EEXIST
            return -1
        }
        let guarded = try handle(calls)
        XCTAssertThrowsError(
            try guarded.transaction(
                component: FileComponent("Note.md"),
                data: Data("safe".utf8),
                expectation: .missing,
                policy: .privateStorage
            ).commit()
        ) { error in
            XCTAssertEqual(error as? SecureLocalFileError, .operation(.createStage, errno: EEXIST))
        }
        XCTAssertEqual(attempts, 8)
    }

    /// `openat(O_CREAT | O_EXCL)` has an ambiguous effect if an adapter
    /// reports interruption after creating the inode. Retrying the same name
    /// sees EEXIST, and silently moving on to another UUID loses the first
    /// stage from every receipt.
    func testEffectThenInterruptedStageCreationIsUnconfirmedAndNeverRetried() throws {
        var calls = SecureFileSyscalls.live
        let liveCreate = calls.createAt
        var createAttempts = 0
        var createdName: String?
        calls.createAt = { parent, name, flags, mode in
            createAttempts += 1
            let result = liveCreate(parent, name, flags, mode)
            guard createAttempts == 1, result >= 0 else { return result }
            createdName = String(cString: name)
            XCTAssertEqual(Darwin.close(result), 0)
            errno = EINTR
            return -1
        }
        let guarded = try handle(calls)

        XCTAssertThrowsError(
            try guarded.transaction(
                component: FileComponent("Note.md"),
                data: Data("after".utf8),
                expectation: .missing,
                policy: .privateStorage
            ).commit()
        ) { error in
            guard case let .prepublicationFailure(cause, receipt) =
                error as? SecureLocalFileError
            else { return XCTFail("unexpected error: \(error)") }
            XCTAssertEqual(cause, .operation(.createStage, errno: EINTR))
            XCTAssertEqual(
                receipt.durability,
                .notPublishedRecoveryUnconfirmed(operation: .createStage, errno: EINTR))
            XCTAssertNil(receipt.recoverySlot)
        }
        XCTAssertEqual(createAttempts, 1, "an ambiguous create must never be retried")
        let name = try XCTUnwrap(createdName)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(name)), Data())
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("Note.md").path))
    }

    func testNoEffectInterruptedStageCreationNeverClaimsOrReusesBystander() throws {
        var calls = SecureFileSyscalls.live
        let liveCreate = calls.createAt
        let bystanderBytes = Data("bystander".utf8)
        var intercept = true
        var createdName: String?
        calls.createAt = { parent, name, flags, mode in
            guard intercept else { return liveCreate(parent, name, flags, mode) }
            intercept = false
            createdName = String(cString: name)
            let bystander = liveCreate(parent, name, flags, mode)
            XCTAssertGreaterThanOrEqual(bystander, 0)
            if bystander >= 0 {
                let count = bystanderBytes.withUnsafeBytes {
                    Darwin.write(bystander, $0.baseAddress, $0.count)
                }
                XCTAssertEqual(count, bystanderBytes.count)
                XCTAssertEqual(Darwin.close(bystander), 0)
            }
            errno = EINTR
            return -1
        }
        let guarded = try handle(calls)
        var observedReceipt: FileTransactionReceipt?

        XCTAssertThrowsError(
            try guarded.transaction(
                component: FileComponent("Note.md"),
                data: Data("first".utf8),
                expectation: .missing,
                policy: .privateStorage
            ).commit()
        ) { error in
            guard case let .prepublicationFailure(cause, receipt) =
                error as? SecureLocalFileError
            else { return XCTFail("unexpected error: \(error)") }
            XCTAssertEqual(cause, .operation(.createStage, errno: EINTR))
            XCTAssertEqual(
                receipt.durability,
                .notPublishedRecoveryUnconfirmed(operation: .createStage, errno: EINTR))
            XCTAssertNil(receipt.recoverySlot)
            observedReceipt = receipt
        }

        let bystanderURL = directory.appendingPathComponent(try XCTUnwrap(createdName))
        XCTAssertEqual(try Data(contentsOf: bystanderURL), bystanderBytes)
        let receipt = try guarded.transaction(
            component: FileComponent("Note.md"),
            data: Data("published".utf8),
            expectation: .missing,
            policy: .privateStorage,
            reusableStage: observedReceipt?.recoverySlot
        ).commit()
        XCTAssertNil(receipt.recoverySlot)
        XCTAssertEqual(try Data(contentsOf: bystanderURL), bystanderBytes)
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent("Note.md")),
            Data("published".utf8))
    }

    func testMissingTransactionPublishesCompletePrivateFileAndSyncsDirectory() throws {
        let destination = directory.appendingPathComponent("Draft.bin")
        let handle = try handle()
        let receipt = try handle.transaction(
            component: FileComponent("Draft.bin"),
            data: Data("complete".utf8),
            expectation: .missing,
            policy: .privateStorage
        ).commit()

        XCTAssertEqual(receipt.durability, .fullySynced)
        XCTAssertEqual(receipt.destination.standardizedFileURL, destination.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: destination), Data("complete".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try names(), ["Draft.bin"])
    }

    func testExactTransactionReplacesOnlyAuthorizedVersionAndChangesIdentity() throws {
        let destination = directory.appendingPathComponent("Note.md")
        try Data("before".utf8).write(to: destination)
        let handle = try handle()
        let before = try handle.version(of: FileComponent("Note.md"))

        let receipt = try handle.transaction(
            component: FileComponent("Note.md"),
            data: Data("after".utf8),
            expectation: .exact(before),
            policy: .userContent
        ).commit()

        XCTAssertEqual(receipt.durability, .recoveryRetained(directorySyncErrno: nil))
        XCTAssertNotEqual(receipt.version?.identity, before.identity)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "after")
        let recovery = try XCTUnwrap(receipt.recovery)
        XCTAssertTrue(recovery.version.matchesAcrossRename(before))
        XCTAssertEqual(
            try String(
                contentsOf: directory.appendingPathComponent(recovery.component.rawValue),
                encoding: .utf8),
            "before")
        XCTAssertEqual(try names().count, 2)
    }

    func testRenameSwapPreservesTheDisplacedVersionAuthorityFields() throws {
        let destination = directory.appendingPathComponent("Note.md")
        let stage = directory.appendingPathComponent("Stage.md")
        try Data("before".utf8).write(to: destination)
        try Data("after".utf8).write(to: stage)
        let handle = try handle()
        let expected = try handle.version(of: FileComponent("Note.md"))

        let result = "Stage.md".withCString { source in
            "Note.md".withCString { target in
                Darwin.renameatx_np(
                    handle.descriptor,
                    source,
                    handle.descriptor,
                    target,
                    UInt32(RENAME_SWAP | RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH))
            }
        }
        XCTAssertEqual(result, 0)
        let displaced = try handle.version(of: FileComponent("Stage.md"))

        XCTAssertNotEqual(displaced, expected, "APFS rename ctime must remain part of strict CAS")
        XCTAssertTrue(displaced.matchesAcrossRename(expected))
    }

    func testModeOwnerGroupAndFlagsRemainPartOfStrictAndAcrossRenameAuthority() throws {
        let destination = directory.appendingPathComponent("Note.md")
        try Data("same".utf8).write(to: destination)
        var status = stat()
        XCTAssertEqual(lstat(destination.path, &status), 0)
        let digest = Data(repeating: 0x5a, count: 32)
        let baselineToken = try XCTUnwrap(FileVersionToken(status: status, sha256: digest))
        let baselineStamp = try XCTUnwrap(LocalFileStamp(status))

        var variants: [stat] = []
        var mode = status
        mode.st_mode ^= mode_t(S_IRGRP)
        variants.append(mode)
        var owner = status
        owner.st_uid &+= 1
        variants.append(owner)
        var group = status
        group.st_gid &+= 1
        variants.append(group)
        var flags = status
        flags.st_flags ^= UInt32(UF_HIDDEN)
        variants.append(flags)

        for changed in variants {
            let token = try XCTUnwrap(FileVersionToken(status: changed, sha256: digest))
            let stamp = try XCTUnwrap(LocalFileStamp(changed))
            XCTAssertNotEqual(token, baselineToken)
            XCTAssertFalse(token.matchesAcrossRename(baselineToken))
            XCTAssertNotEqual(
                stamp,
                baselineStamp,
                "cache admission must not serve bytes under changed file metadata")
        }
    }

    func testExternalCtimeOnlyMutationFailsStrictVersionAdmission() throws {
        let destination = directory.appendingPathComponent("Note.md")
        try Data("same".utf8).write(to: destination)
        let handle = try handle()
        let expected = try handle.version(of: FileComponent("Note.md"))
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        let originalMode = mode_t((attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644)
        XCTAssertEqual(chmod(destination.path, 0o600), 0)
        XCTAssertEqual(chmod(destination.path, originalMode), 0)
        let externallyChanged = try handle.version(of: FileComponent("Note.md"))

        XCTAssertEqual(externallyChanged.sha256, expected.sha256)
        XCTAssertEqual(externallyChanged.identity.device, expected.identity.device)
        XCTAssertEqual(externallyChanged.identity.inode, expected.identity.inode)
        XCTAssertEqual(externallyChanged.size, expected.size)
        XCTAssertEqual(externallyChanged.modifiedSeconds, expected.modifiedSeconds)
        XCTAssertEqual(externallyChanged.modifiedNanoseconds, expected.modifiedNanoseconds)
        XCTAssertNotEqual(externallyChanged, expected)
        XCTAssertThrowsError(
            try handle.transaction(
                component: FileComponent("Note.md"),
                data: Data("mine".utf8),
                expectation: .exact(expected),
                policy: .userContent
            ).commit()
        ) { error in
            XCTAssertEqual(error as? SecureLocalFileError, .expectationMismatch)
        }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "same")
    }

    func testCtimeMutationDuringStagePreparationFailsFinalStrictAdmission() throws {
        let destination = directory.appendingPathComponent("Note.md")
        try Data("same".utf8).write(to: destination)
        let baseline = try handle()
        let expected = try baseline.version(of: FileComponent("Note.md"))
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        let originalMode = mode_t(
            (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o600)
        let temporaryMode: mode_t = originalMode == 0o600 ? 0o400 : 0o600

        var calls = SecureFileSyscalls.live
        let liveCreate = calls.createAt
        let liveFsync = calls.fsync
        var stageDescriptor: Int32 = -1
        var mutated = false
        calls.createAt = { descriptor, name, flags, mode in
            let result = liveCreate(descriptor, name, flags, mode)
            if result >= 0 { stageDescriptor = result }
            return result
        }
        calls.fsync = { descriptor in
            let result = liveFsync(descriptor)
            if result == 0, descriptor == stageDescriptor, !mutated {
                mutated = true
                XCTAssertEqual(chmod(destination.path, temporaryMode), 0)
                XCTAssertEqual(chmod(destination.path, originalMode), 0)
            }
            return result
        }
        let guarded = try handle(calls)

        var retained: FileTransactionReceipt?
        XCTAssertThrowsError(
            try guarded.transaction(
                component: FileComponent("Note.md"),
                data: Data("mine".utf8),
                expectation: .exact(expected),
                policy: .userContent
            ).commit()
        ) { error in
            retained = self.retainedPrepublicationReceipt(
                from: error,
                cause: .expectationMismatch)
        }
        XCTAssertTrue(mutated)
        XCTAssertNotEqual(try baseline.version(of: FileComponent("Note.md")), expected)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "same")
        XCTAssertNotNil(retained?.recovery)
        XCTAssertEqual(try names().filter { $0.hasPrefix(".markdev-stage-") }.count, 1)
    }

    /// No Darwin API makes the final user-space token read and the subsequent
    /// rename an inode-CAS operation. This test documents the accepted same-UID
    /// mutation window without pretending that the transaction can close it.
    func testSameUIDMutationInsideRenameBoundaryDocumentsPlatformLimit() throws {
        let destination = directory.appendingPathComponent("Note.md")
        try Data("before".utf8).write(to: destination)
        let baseline = try handle()
        let expected = try baseline.version(of: FileComponent("Note.md"))
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        let originalMode = mode_t(
            (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o600)
        let temporaryMode: mode_t = originalMode == 0o600 ? 0o400 : 0o600

        var calls = SecureFileSyscalls.live
        let liveRename = calls.renameAtX
        var mutationInsideBoundary = false
        calls.renameAtX = { sourceFD, source, destinationFD, target, flags in
            if !mutationInsideBoundary, flags & UInt32(RENAME_SWAP) != 0 {
                mutationInsideBoundary = true
                XCTAssertEqual(chmod(destination.path, temporaryMode), 0)
                XCTAssertEqual(chmod(destination.path, originalMode), 0)
            }
            return liveRename(sourceFD, source, destinationFD, target, flags)
        }
        let guarded = try handle(calls)

        let receipt = try guarded.transaction(
            component: FileComponent("Note.md"),
            data: Data("after".utf8),
            expectation: .exact(expected),
            policy: .userContent
        ).commit()

        XCTAssertTrue(mutationInsideBoundary)
        XCTAssertEqual(receipt.durability, .recoveryRetained(directorySyncErrno: nil))
        XCTAssertNotNil(receipt.recovery)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "after")
    }

    func testExactTransactionRefusesSameBytesAtDifferentIdentity() throws {
        let destination = directory.appendingPathComponent("Note.md")
        let attacker = directory.appendingPathComponent("Attacker.md")
        try Data("same".utf8).write(to: destination)
        let handle = try handle()
        let expected = try handle.version(of: FileComponent("Note.md"))
        try Data("same".utf8).write(to: attacker)
        XCTAssertEqual(Darwin.rename(attacker.path, destination.path), 0)

        XCTAssertThrowsError(
            try handle.transaction(
                component: FileComponent("Note.md"),
                data: Data("mine".utf8),
                expectation: .exact(expected),
                policy: .userContent
            ).commit()
        ) { XCTAssertEqual($0 as? SecureLocalFileError, .expectationMismatch) }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "same")
        XCTAssertEqual(try names(), ["Note.md"])
    }

    func testTargetSwapAtPublishIsIndeterminateWithoutASecondMutation() throws {
        let destination = directory.appendingPathComponent("Note.md")
        let attacker = directory.appendingPathComponent("Attacker.md")
        try Data("expected".utf8).write(to: destination)
        try Data("attacker".utf8).write(to: attacker)

        let baselineHandle = try handle()
        let expected = try baselineHandle.version(of: FileComponent("Note.md"))
        var calls = SecureFileSyscalls.live
        let liveRename = calls.renameAtX
        var injected = false
        var swaps = 0
        calls.renameAtX = { sourceFD, source, destinationFD, target, flags in
            if !injected, flags & UInt32(RENAME_SWAP) != 0 {
                injected = true
                _ = Darwin.rename(attacker.path, destination.path)
            }
            let result = liveRename(sourceFD, source, destinationFD, target, flags)
            if result == 0, flags & UInt32(RENAME_SWAP) != 0 { swaps += 1 }
            return result
        }
        let guarded = try handle(calls)

        XCTAssertThrowsError(
            try guarded.transaction(
                component: FileComponent("Note.md"),
                data: Data("mine".utf8),
                expectation: .exact(expected),
                policy: .userContent
            ).commit()
        ) { error in
            guard case .indeterminate(let receipt) = error as? SecureLocalFileError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(receipt.durability, .indeterminate(operation: .verify, errno: nil))
            XCTAssertNil(receipt.recoveryComponent)
        }
        XCTAssertEqual(swaps, 1)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "mine")
        let stages = try names().filter { $0.hasPrefix(".markdev-stage-") }
        XCTAssertEqual(stages.count, 1)
        XCTAssertEqual(
            try String(
                contentsOf: directory.appendingPathComponent(try XCTUnwrap(stages.first)),
                encoding: .utf8),
            "attacker")
    }

    func testTargetSubstitutionDoesNotTriggerRollbackOrDirectorySync() throws {
        let destination = directory.appendingPathComponent("Note.md")
        let attacker = directory.appendingPathComponent("Attacker.md")
        try Data("expected".utf8).write(to: destination)
        try Data("attacker".utf8).write(to: attacker)
        let expected = try handle().version(of: FileComponent("Note.md"))
        var calls = SecureFileSyscalls.live
        let liveRename = calls.renameAtX
        let liveFsync = calls.fsync
        let directoryDescriptor = LockedDescriptor()
        var injected = false
        var swaps = 0
        var syncAttempts = 0
        calls.renameAtX = { sourceFD, source, destinationFD, target, flags in
            if !injected, flags & UInt32(RENAME_SWAP) != 0 {
                injected = true
                XCTAssertEqual(Darwin.rename(attacker.path, destination.path), 0)
            }
            let result = liveRename(sourceFD, source, destinationFD, target, flags)
            if result == 0, flags & UInt32(RENAME_SWAP) != 0 { swaps += 1 }
            return result
        }
        calls.fsync = { descriptor in
            if descriptor == directoryDescriptor.value {
                syncAttempts += 1
                errno = EINTR
                return -1
            }
            return liveFsync(descriptor)
        }
        let guarded = try handle(calls)
        directoryDescriptor.value = guarded.descriptor

        XCTAssertThrowsError(
            try guarded.transaction(
                component: FileComponent("Note.md"),
                data: Data("mine".utf8),
                expectation: .exact(expected),
                policy: .userContent
            ).commit()
        ) { error in
            guard case .indeterminate(let receipt) = error as? SecureLocalFileError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(receipt.durability, .indeterminate(operation: .verify, errno: nil))
        }
        XCTAssertEqual(swaps, 1)
        XCTAssertEqual(syncAttempts, 0)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "mine")
        let stages = try names().filter { $0.hasPrefix(".markdev-stage-") }
        XCTAssertEqual(stages.count, 1)
        XCTAssertEqual(
            try String(
                contentsOf: directory.appendingPathComponent(try XCTUnwrap(stages.first)),
                encoding: .utf8),
            "attacker")
    }

    func testDisplacedStageOpenFailureNeverAttemptsASecondMutation() throws {
        let destination = directory.appendingPathComponent("Note.md")
        try Data("before".utf8).write(to: destination)
        let baseline = try handle()
        let expected = try baseline.version(of: FileComponent("Note.md"))
        var calls = SecureFileSyscalls.live
        let liveOpenAt = calls.openAt
        let liveRename = calls.renameAtX
        var swaps = 0
        calls.renameAtX = { sourceFD, source, destinationFD, target, flags in
            let result = liveRename(sourceFD, source, destinationFD, target, flags)
            if result == 0, flags & UInt32(RENAME_SWAP) != 0 { swaps += 1 }
            return result
        }
        calls.openAt = { descriptor, name, flags in
            if swaps == 1, String(cString: name).hasPrefix(".markdev-stage-") {
                errno = EIO
                return -1
            }
            return liveOpenAt(descriptor, name, flags)
        }
        let guarded = try handle(calls)

        XCTAssertThrowsError(
            try guarded.transaction(
                component: FileComponent("Note.md"),
                data: Data("after".utf8),
                expectation: .exact(expected),
                policy: .userContent
            ).commit()
        ) { error in
            guard case .indeterminate(let receipt) = error as? SecureLocalFileError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(receipt.durability, .indeterminate(operation: .verify, errno: nil))
            XCTAssertNil(receipt.recoveryComponent)
        }
        XCTAssertEqual(swaps, 1, "post-publish verification must never mutate a reused name")
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "after")
        let stages = try names().filter { $0.hasPrefix(".markdev-stage-") }
        XCTAssertEqual(stages.count, 1)
        XCTAssertEqual(
            try String(contentsOf: directory.appendingPathComponent(stages[0]), encoding: .utf8),
            "before")
    }

    func testDisplacedStageFstatAndReadFailuresNeverAttemptRollback() throws {
        for failure in ["fstat", "read"] {
            let name = "\(failure).md"
            let destination = directory.appendingPathComponent(name)
            try Data("before".utf8).write(to: destination)
            let baseline = try handle()
            let expected = try baseline.version(of: FileComponent(name))
            var calls = SecureFileSyscalls.live
            let liveOpenAt = calls.openAt
            let liveFstat = calls.fstat
            let liveRead = calls.read
            let liveRename = calls.renameAtX
            var swaps = 0
            var displacedDescriptor: Int32 = -1
            calls.renameAtX = { sourceFD, source, destinationFD, target, flags in
                let result = liveRename(sourceFD, source, destinationFD, target, flags)
                if result == 0, flags & UInt32(RENAME_SWAP) != 0 { swaps += 1 }
                return result
            }
            calls.openAt = { descriptor, component, flags in
                let result = liveOpenAt(descriptor, component, flags)
                if result >= 0, swaps == 1,
                    String(cString: component).hasPrefix(".markdev-stage-")
                {
                    displacedDescriptor = result
                }
                return result
            }
            calls.fstat = { descriptor, status in
                if failure == "fstat", descriptor == displacedDescriptor {
                    errno = EIO
                    return -1
                }
                return liveFstat(descriptor, status)
            }
            calls.read = { descriptor, bytes, count in
                if failure == "read", descriptor == displacedDescriptor {
                    errno = EIO
                    return -1
                }
                return liveRead(descriptor, bytes, count)
            }
            let guarded = try handle(calls)
            let namesBefore = Set(try names())

            XCTAssertThrowsError(
                try guarded.transaction(
                    component: FileComponent(name),
                    data: Data("after".utf8),
                    expectation: .exact(expected),
                    policy: .userContent
                ).commit(), "\(failure) unexpectedly committed"
            ) { error in
                guard case .indeterminate = error as? SecureLocalFileError else {
                    return XCTFail("unexpected \(failure) error: \(error)")
                }
            }
            XCTAssertEqual(swaps, 1)
            XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "after")
            let stages = try names().filter {
                $0.hasPrefix(".markdev-stage-") && !namesBefore.contains($0)
            }
            XCTAssertEqual(stages.count, 1)
            XCTAssertEqual(
                try String(
                    contentsOf: directory.appendingPathComponent(try XCTUnwrap(stages.first)),
                    encoding: .utf8),
                "before")
        }
    }

    func testPublishMismatchPreservesCommittedAndDisplacedArtifactsWithoutRollback() throws {
        let destination = directory.appendingPathComponent("Note.md")
        let attacker = directory.appendingPathComponent("Attacker.md")
        try Data("expected".utf8).write(to: destination)
        try Data("attacker".utf8).write(to: attacker)
        let baseline = try handle()
        let expected = try baseline.version(of: FileComponent("Note.md"))
        var calls = SecureFileSyscalls.live
        let liveRename = calls.renameAtX
        var swapAttempts = 0
        calls.renameAtX = { sourceFD, source, destinationFD, target, flags in
            if flags & UInt32(RENAME_SWAP) != 0 {
                swapAttempts += 1
                if swapAttempts == 1 {
                    XCTAssertEqual(Darwin.rename(attacker.path, destination.path), 0)
                }
            }
            return liveRename(sourceFD, source, destinationFD, target, flags)
        }
        let guarded = try handle(calls)

        XCTAssertThrowsError(
            try guarded.transaction(
                component: FileComponent("Note.md"),
                data: Data("mine".utf8),
                expectation: .exact(expected),
                policy: .userContent
            ).commit()
        ) { error in
            guard case .indeterminate(let receipt) = error as? SecureLocalFileError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(receipt.durability, .indeterminate(operation: .verify, errno: nil))
        }
        XCTAssertEqual(swapAttempts, 1)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "mine")
        let stages = try names().filter { $0.hasPrefix(".markdev-stage-") }
        XCTAssertEqual(stages.count, 1)
        XCTAssertEqual(
            try String(contentsOf: directory.appendingPathComponent(stages[0]), encoding: .utf8),
            "attacker")
    }

    func testSecondSwapHookIsNeverReachedAfterPublishMismatch() throws {
        let destination = directory.appendingPathComponent("Note.md")
        let attacker = directory.appendingPathComponent("Attacker.md")
        let stolen = directory.appendingPathComponent("Stolen.md")
        try Data("expected".utf8).write(to: destination)
        try Data("attacker".utf8).write(to: attacker)
        let baseline = try handle()
        let expected = try baseline.version(of: FileComponent("Note.md"))
        var calls = SecureFileSyscalls.live
        let liveRename = calls.renameAtX
        var swapAttempts = 0
        calls.renameAtX = { sourceFD, source, destinationFD, target, flags in
            if flags & UInt32(RENAME_SWAP) != 0 {
                swapAttempts += 1
                if swapAttempts == 1 {
                    XCTAssertEqual(Darwin.rename(attacker.path, destination.path), 0)
                } else {
                    let stagePath = self.directory.appendingPathComponent(String(cString: source))
                    XCTAssertEqual(Darwin.rename(stagePath.path, stolen.path), 0)
                    do {
                        try Data("substitute".utf8).write(to: stagePath)
                    } catch {
                        XCTFail("could not create rollback substitution: \(error)")
                        errno = EIO
                        return -1
                    }
                }
            }
            return liveRename(sourceFD, source, destinationFD, target, flags)
        }
        let guarded = try handle(calls)

        XCTAssertThrowsError(
            try guarded.transaction(
                component: FileComponent("Note.md"),
                data: Data("mine".utf8),
                expectation: .exact(expected),
                policy: .userContent
            ).commit()
        ) { error in
            guard case .indeterminate = error as? SecureLocalFileError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(swapAttempts, 1)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "mine")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stolen.path))
        let stages = try names().filter { $0.hasPrefix(".markdev-stage-") }
        XCTAssertEqual(stages.count, 1)
        XCTAssertEqual(
            try String(contentsOf: directory.appendingPathComponent(stages[0]), encoding: .utf8),
            "attacker")
    }

    func testCommittedReceiptDoesNotReopenDestinationAfterPublication() throws {
        let destination = directory.appendingPathComponent("Note.md")
        let substitute = directory.appendingPathComponent("Substitute.md")
        try Data("before".utf8).write(to: destination)
        try Data("later external edit".utf8).write(to: substitute)
        let baseline = try handle()
        let expected = try baseline.version(of: FileComponent("Note.md"))
        var calls = SecureFileSyscalls.live
        let liveOpenAt = calls.openAt
        let liveRenameAtX = calls.renameAtX
        var published = false
        var refuseDestinationReopen = true
        var destinationOpensAfterPublish = 0
        calls.openAt = { descriptor, name, flags in
            if published, refuseDestinationReopen, String(cString: name) == "Note.md" {
                destinationOpensAfterPublish += 1
                errno = EIO
                return -1
            }
            return liveOpenAt(descriptor, name, flags)
        }
        calls.renameAtX = { fromDescriptor, from, toDescriptor, to, flags in
            let result = liveRenameAtX(fromDescriptor, from, toDescriptor, to, flags)
            if result == 0 { published = true }
            return result
        }
        let guarded = try handle(calls)

        let receipt = try guarded.transaction(
            component: FileComponent("Note.md"),
            data: Data("after".utf8),
            expectation: .exact(expected),
            policy: .userContent
        ).commit()
        // The atomic rename is the transaction's linearization point. A
        // same-UID process may replace the name afterward; reopening during
        // commit would only create another TOCTOU. The next exact save must
        // detect this subsequent external edit.
        refuseDestinationReopen = false
        XCTAssertEqual(Darwin.rename(substitute.path, destination.path), 0)

        XCTAssertEqual(receipt.durability, .recoveryRetained(directorySyncErrno: nil))
        XCTAssertNotNil(receipt.recovery)
        XCTAssertEqual(destinationOpensAfterPublish, 0)
        XCTAssertEqual(
            try String(contentsOf: destination, encoding: .utf8),
            "later external edit")
        let receiptVersion = try XCTUnwrap(receipt.version)
        XCTAssertThrowsError(
            try guarded.transaction(
                component: FileComponent("Note.md"),
                data: Data("second save".utf8),
                expectation: .exact(receiptVersion),
                policy: .userContent
            ).commit()
        ) { error in
            XCTAssertEqual(error as? SecureLocalFileError, .expectationMismatch)
        }
    }

    func testReceiptRehashesRetainedDescriptorAfterMissingAndExactPublication() throws {
        for kind in ["missing", "exact"] {
            let name = "rehash-\(kind).md"
            let destination = directory.appendingPathComponent(name)
            let guardedBaseline = try handle()
            let expectation: FileTransactionExpectation
            if kind == "exact" {
                try Data("old!".utf8).write(to: destination)
                expectation = .exact(
                    try guardedBaseline.version(of: FileComponent(name)))
            } else {
                expectation = .missing
            }

            var calls = SecureFileSyscalls.live
            let liveRename = calls.renameAtX
            var injected = false
            calls.renameAtX = { sourceFD, source, destinationFD, target, flags in
                let result = liveRename(sourceFD, source, destinationFD, target, flags)
                guard result == 0, !injected else { return result }
                injected = true

                let descriptor = Darwin.open(destination.path, O_RDWR | O_CLOEXEC)
                XCTAssertGreaterThanOrEqual(descriptor, 0)
                if descriptor >= 0 {
                    var publishedStatus = stat()
                    XCTAssertEqual(Darwin.fstat(descriptor, &publishedStatus), 0)
                    let replacement = Array("evil".utf8)
                    let written = replacement.withUnsafeBytes {
                        Darwin.pwrite(descriptor, $0.baseAddress, $0.count, 0)
                    }
                    XCTAssertEqual(written, replacement.count)
                    var times = [publishedStatus.st_atimespec, publishedStatus.st_mtimespec]
                    XCTAssertEqual(Darwin.futimens(descriptor, &times), 0)
                    XCTAssertEqual(Darwin.close(descriptor), 0)
                }
                return result
            }
            let guarded = try handle(calls)

            do {
                let receipt = try guarded.transaction(
                    component: FileComponent(name),
                    data: Data("mine".utf8),
                    expectation: expectation,
                    policy: .userContent
                ).commit()
                let fresh = try handle().version(of: FileComponent(name))
                XCTAssertEqual(
                    receipt.version,
                    fresh,
                    "\(kind) receipt must describe the bytes actually retained after publish")
            } catch SecureLocalFileError.indeterminate(let receipt) {
                // Refusal is also correct: the transaction must never return a
                // stale digest as a successful authority.
                XCTAssertNil(receipt.version)
            }
        }
    }

    func testRetainedNewFileFstatFailureAfterSwapIsIndeterminateWithoutRollback() throws {
        let destination = directory.appendingPathComponent("Note.md")
        try Data("before".utf8).write(to: destination)
        let baseline = try handle()
        let expected = try baseline.version(of: FileComponent("Note.md"))
        var calls = SecureFileSyscalls.live
        let liveCreate = calls.createAt
        let liveFstat = calls.fstat
        let liveRename = calls.renameAtX
        var stageDescriptor: Int32 = -1
        var swaps = 0
        calls.createAt = { descriptor, name, flags, mode in
            let result = liveCreate(descriptor, name, flags, mode)
            if result >= 0 { stageDescriptor = result }
            return result
        }
        calls.renameAtX = { sourceFD, source, destinationFD, target, flags in
            let result = liveRename(sourceFD, source, destinationFD, target, flags)
            if result == 0, flags & UInt32(RENAME_SWAP) != 0 { swaps += 1 }
            return result
        }
        calls.fstat = { descriptor, status in
            if swaps == 1, descriptor == stageDescriptor {
                errno = EIO
                return -1
            }
            return liveFstat(descriptor, status)
        }
        let guarded = try handle(calls)

        XCTAssertThrowsError(
            try guarded.transaction(
                component: FileComponent("Note.md"),
                data: Data("after".utf8),
                expectation: .exact(expected),
                policy: .userContent
            ).commit()
        ) { error in
            guard case .indeterminate(let receipt) = error as? SecureLocalFileError else {
                return XCTFail("post-swap fstat escaped as ordinary error: \(error)")
            }
            XCTAssertEqual(
                receipt.durability,
                .indeterminate(operation: .verify, errno: nil))
            XCTAssertNotNil(receipt.recoveryComponent)
        }
        XCTAssertEqual(swaps, 1)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "after")
        let stages = try names().filter { $0.hasPrefix(".markdev-stage-") }
        XCTAssertEqual(stages.count, 1)
        XCTAssertEqual(
            try String(
                contentsOf: directory.appendingPathComponent(try XCTUnwrap(stages.first)),
                encoding: .utf8),
            "before")
    }

    func testSuccessfulOverwriteRetainsExactDisplacedAuthority() throws {
        let destination = directory.appendingPathComponent("Note.md")
        try Data("before".utf8).write(to: destination)
        let baseline = try handle()
        let expected = try baseline.version(of: FileComponent("Note.md"))
        let guarded = try handle()

        let receipt = try guarded.transaction(
            component: FileComponent("Note.md"),
            data: Data("after".utf8),
            expectation: .exact(expected),
            policy: .userContent
        ).commit()

        XCTAssertEqual(
            receipt.durability,
            .recoveryRetained(directorySyncErrno: nil))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "after")
        let stages = try names().filter { $0.hasPrefix(".markdev-stage-") }
        XCTAssertEqual(stages.count, 1)
        XCTAssertEqual(receipt.recoveryComponent?.rawValue, stages.first)
        let recovery = try XCTUnwrap(receipt.recovery)
        XCTAssertEqual(
            try guarded.version(of: recovery.component),
            recovery.version)
        XCTAssertTrue(recovery.version.matchesAcrossRename(expected))
        XCTAssertEqual(
            try String(contentsOf: directory.appendingPathComponent(stages[0]), encoding: .utf8),
            "before")
    }

    func testAuthoritativeReceiptBindingRejectsDifferentPresentationDestination() throws {
        let destination = directory.appendingPathComponent("Note.md")
        try Data("before".utf8).write(to: destination)
        let guarded = try handle()
        let component = try FileComponent("Note.md")
        let expected = try guarded.version(of: component)
        let key = try guarded.destinationKey(component)

        let receipt = try guarded.transaction(
            component: component,
            data: Data("after".utf8),
            expectation: .exact(expected),
            policy: .userContent
        ).commit()

        XCTAssertTrue(receipt.isBound(to: key, destination: destination))
        XCTAssertFalse(
            receipt.isBound(
                to: key,
                destination: directory.appendingPathComponent("Claimed.md")))
    }

    func testReusableStageCyclesTheSameComponentAndTwoExactInodes() throws {
        let destination = directory.appendingPathComponent("Note.md")
        try Data("version-0".utf8).write(to: destination)
        let guarded = try handle()
        let initial = try guarded.version(of: FileComponent("Note.md"))

        let first = try guarded.transaction(
            component: FileComponent("Note.md"),
            data: Data("version-1".utf8),
            expectation: .exact(initial),
            policy: .userContent
        ).commit()
        let firstVersion = try XCTUnwrap(first.version)
        let firstRecovery = try XCTUnwrap(first.recovery)

        let second = try guarded.transaction(
            component: FileComponent("Note.md"),
            data: Data("version-2".utf8),
            expectation: .exact(firstVersion),
            policy: .userContent,
            reusableStage: FileRecoverySlot(
                authority: firstRecovery,
                contents: .previousDestination)
        ).commit()
        let secondVersion = try XCTUnwrap(second.version)
        let secondRecovery = try XCTUnwrap(second.recovery)

        XCTAssertEqual(secondRecovery.component, firstRecovery.component)
        XCTAssertEqual(secondVersion.identity, firstRecovery.version.identity)
        XCTAssertEqual(secondRecovery.version.identity, firstVersion.identity)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "version-2")
        XCTAssertEqual(
            try String(
                contentsOf: directory.appendingPathComponent(secondRecovery.component.rawValue),
                encoding: .utf8),
            "version-1")
        XCTAssertEqual(try names().count, 2)
    }

    func testExternalCASMismatchRefusesReusableStageBeforeTruncation() throws {
        let destination = directory.appendingPathComponent("Note.md")
        let replacement = directory.appendingPathComponent("Replacement.md")
        try Data("version-0".utf8).write(to: destination)
        let baseline = try handle()
        let initial = try baseline.version(of: FileComponent("Note.md"))
        let first = try baseline.transaction(
            component: FileComponent("Note.md"),
            data: Data("version-1".utf8),
            expectation: .exact(initial),
            policy: .userContent
        ).commit()
        let expected = try XCTUnwrap(first.version)
        let recovery = try XCTUnwrap(first.recovery)
        try Data("version-1".utf8).write(to: replacement)
        XCTAssertEqual(Darwin.rename(replacement.path, destination.path), 0)

        var calls = SecureFileSyscalls.live
        var truncateCalls = 0
        calls.ftruncate = { descriptor, size in
            truncateCalls += 1
            return Darwin.ftruncate(descriptor, size)
        }
        let guarded = try handle(calls)
        XCTAssertThrowsError(
            try guarded.transaction(
                component: FileComponent("Note.md"),
                data: Data("version-2".utf8),
                expectation: .exact(expected),
                policy: .userContent,
                reusableStage: FileRecoverySlot(
                    authority: recovery,
                    contents: .previousDestination)
            ).commit()
        ) { error in
            XCTAssertEqual(error as? SecureLocalFileError, .expectationMismatch)
        }

        XCTAssertEqual(truncateCalls, 0)
        XCTAssertEqual(try guarded.version(of: recovery.component), recovery.version)
        XCTAssertEqual(
            try String(
                contentsOf: directory.appendingPathComponent(recovery.component.rawValue),
                encoding: .utf8),
            "version-0")
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "version-1")
    }

    func testCancellationWhileRewritingReusableStageReturnsRefreshedAuthorityForRetry() throws {
        let destination = directory.appendingPathComponent("Note.md")
        try Data("version-0".utf8).write(to: destination)
        let baseline = try handle()
        let initial = try baseline.version(of: FileComponent("Note.md"))
        let first = try baseline.transaction(
            component: FileComponent("Note.md"),
            data: Data("version-1".utf8),
            expectation: .exact(initial),
            policy: .userContent
        ).commit()
        let expected = try XCTUnwrap(first.version)
        let recovery = try XCTUnwrap(first.recovery)

        var calls = SecureFileSyscalls.live
        let liveWrite = calls.write
        let writeCalls = SecureIOLockedValue(0)
        calls.write = { descriptor, bytes, count in
            writeCalls.mutate { $0 += 1 }
            return liveWrite(descriptor, bytes, min(1, count))
        }
        let guarded = try handle(calls)
        var interrupted = guarded.transaction(
            component: try FileComponent("Note.md"),
            data: Data("interrupted rewrite".utf8),
            expectation: .exact(expected),
            policy: .userContent,
            reusableStage: FileRecoverySlot(
                authority: recovery,
                contents: .previousDestination))
        interrupted.cancellationCheck = { writeCalls.value >= 3 }

        var refreshed: FileRecoveryAuthority?
        XCTAssertThrowsError(try interrupted.commit()) { error in
            refreshed = self.retainedPrepublicationReceipt(
                from: error,
                cause: .cancelled)?.recovery
        }
        XCTAssertEqual(writeCalls.value, 3)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "version-1")
        let refreshedAuthority = try XCTUnwrap(refreshed)
        XCTAssertEqual(refreshedAuthority.component, recovery.component)
        XCTAssertNotEqual(refreshedAuthority.version, recovery.version)

        let resumed = try baseline.transaction(
            component: FileComponent("Note.md"),
            data: Data("version-2".utf8),
            expectation: .exact(expected),
            policy: .userContent,
            reusableStage: FileRecoverySlot(
                authority: refreshedAuthority,
                contents: .unpublishedScratch)
        ).commit()
        XCTAssertEqual(resumed.recoveryComponent, recovery.component)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "version-2")
        XCTAssertEqual(try names().filter { $0.hasPrefix(".markdev-stage-") }.count, 1)
    }

    func testReusableSwapEffectThenInterruptedReturnIsIndeterminateWithSameSlot() throws {
        let destination = directory.appendingPathComponent("Note.md")
        try Data("version-0".utf8).write(to: destination)
        let baseline = try handle()
        let initial = try baseline.version(of: FileComponent("Note.md"))
        let first = try baseline.transaction(
            component: FileComponent("Note.md"),
            data: Data("version-1".utf8),
            expectation: .exact(initial),
            policy: .userContent
        ).commit()
        let expected = try XCTUnwrap(first.version)
        let recovery = try XCTUnwrap(first.recovery)

        var calls = SecureFileSyscalls.live
        let liveRename = calls.renameAtX
        var renameCalls = 0
        calls.renameAtX = { sourceFD, source, destinationFD, target, flags in
            renameCalls += 1
            XCTAssertEqual(liveRename(sourceFD, source, destinationFD, target, flags), 0)
            errno = EINTR
            return -1
        }
        let guarded = try handle(calls)

        XCTAssertThrowsError(
            try guarded.transaction(
                component: FileComponent("Note.md"),
                data: Data("version-2".utf8),
                expectation: .exact(expected),
                policy: .userContent,
                reusableStage: FileRecoverySlot(
                    authority: recovery,
                    contents: .previousDestination)
            ).commit()
        ) { error in
            guard case .indeterminate(let receipt) = error as? SecureLocalFileError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertNotNil(receipt.version)
            XCTAssertEqual(receipt.recoveryComponent, recovery.component)
            XCTAssertTrue(receipt.recoveryVersion?.matchesAcrossRename(expected) == true)
            XCTAssertEqual(
                receipt.durability,
                .indeterminate(operation: .publish, errno: EINTR))
        }
        XCTAssertEqual(renameCalls, 1)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "version-2")
        XCTAssertEqual(
            try String(
                contentsOf: directory.appendingPathComponent(recovery.component.rawValue),
                encoding: .utf8),
            "version-1")
        XCTAssertEqual(try names().filter { $0.hasPrefix(".markdev-stage-") }.count, 1)
    }

    func testReusableStageFinalBindingSubstitutionNeverPublishesOrTruncatesBystander() throws {
        let destination = directory.appendingPathComponent("Note.md")
        try Data("version-0".utf8).write(to: destination)
        let baseline = try handle()
        let initial = try baseline.version(of: FileComponent("Note.md"))
        let first = try baseline.transaction(
            component: FileComponent("Note.md"),
            data: Data("version-1".utf8),
            expectation: .exact(initial),
            policy: .userContent
        ).commit()
        let expected = try XCTUnwrap(first.version)
        let recovery = try XCTUnwrap(first.recovery)
        let stageURL = directory.appendingPathComponent(recovery.component.rawValue)
        let retainedPrepared = directory.appendingPathComponent("retained-prepared")

        var calls = SecureFileSyscalls.live
        let liveOpenAt = calls.openAt
        let liveRename = calls.renameAtX
        var stageOpenCalls = 0
        var publishCalls = 0
        calls.openAt = { parent, name, flags in
            guard String(cString: name) == recovery.component.rawValue else {
                return liveOpenAt(parent, name, flags)
            }
            stageOpenCalls += 1
            if stageOpenCalls == 4 {
                guard Darwin.rename(stageURL.path, retainedPrepared.path) == 0 else {
                    return -1
                }
                do {
                    try Data("bystander".utf8).write(to: stageURL)
                } catch {
                    XCTFail("could not install final-binding bystander: \(error)")
                    errno = EIO
                    return -1
                }
            }
            return liveOpenAt(parent, name, flags)
        }
        calls.renameAtX = { sourceFD, source, destinationFD, target, flags in
            publishCalls += 1
            return liveRename(sourceFD, source, destinationFD, target, flags)
        }
        let guarded = try handle(calls)

        XCTAssertThrowsError(
            try guarded.transaction(
                component: FileComponent("Note.md"),
                data: Data("version-2".utf8),
                expectation: .exact(expected),
                policy: .userContent,
                reusableStage: FileRecoverySlot(
                    authority: recovery,
                    contents: .previousDestination)
            ).commit()
        ) { error in
            guard case let .prepublicationFailure(cause, receipt) =
                error as? SecureLocalFileError
            else { return XCTFail("unexpected error: \(error)") }
            XCTAssertEqual(cause, .expectationMismatch)
            XCTAssertNil(receipt.recovery)
            XCTAssertEqual(
                receipt.durability,
                .notPublishedRecoveryUnconfirmed(operation: .verify, errno: nil))
        }
        XCTAssertGreaterThanOrEqual(stageOpenCalls, 4)
        XCTAssertEqual(publishCalls, 0)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "version-1")
        XCTAssertEqual(try String(contentsOf: stageURL, encoding: .utf8), "bystander")
        XCTAssertEqual(
            try String(contentsOf: retainedPrepared, encoding: .utf8),
            "version-2")
    }

    func testExactRenameBoundaryStageSubstitutionCannotReturnFalseSuccess() throws {
        let destination = directory.appendingPathComponent("Note.md")
        try Data("version-0".utf8).write(to: destination)
        let baseline = try handle()
        let initial = try baseline.version(of: FileComponent("Note.md"))
        let first = try baseline.transaction(
            component: FileComponent("Note.md"),
            data: Data("version-1".utf8),
            expectation: .exact(initial),
            policy: .userContent
        ).commit()
        let expected = try XCTUnwrap(first.version)
        let recovery = try XCTUnwrap(first.recovery)
        let retainedPrepared = directory.appendingPathComponent("retained-prepared")

        var calls = SecureFileSyscalls.live
        let liveRename = calls.renameAtX
        var renameCalls = 0
        calls.renameAtX = { sourceFD, source, destinationFD, target, flags in
            renameCalls += 1
            let stageURL = self.directory.appendingPathComponent(String(cString: source))
            guard Darwin.rename(stageURL.path, retainedPrepared.path) == 0 else {
                return -1
            }
            do {
                try Data("bystander".utf8).write(to: stageURL)
            } catch {
                XCTFail("could not install rename-boundary bystander: \(error)")
                errno = EIO
                return -1
            }
            return liveRename(sourceFD, source, destinationFD, target, flags)
        }
        let guarded = try handle(calls)

        XCTAssertThrowsError(
            try guarded.transaction(
                component: FileComponent("Note.md"),
                data: Data("version-2".utf8),
                expectation: .exact(expected),
                policy: .userContent,
                reusableStage: FileRecoverySlot(
                    authority: recovery,
                    contents: .previousDestination)
            ).commit()
        ) { error in
            guard case .indeterminate(let receipt) = error as? SecureLocalFileError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertNil(receipt.version, "the held prepared inode was not what got published")
            XCTAssertEqual(receipt.recoveryComponent, recovery.component)
            XCTAssertEqual(
                receipt.durability,
                .indeterminate(operation: .verify, errno: nil))
        }
        XCTAssertEqual(renameCalls, 1)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "bystander")
        XCTAssertEqual(
            try String(
                contentsOf: directory.appendingPathComponent(recovery.component.rawValue),
                encoding: .utf8),
            "version-1")
        XCTAssertEqual(try String(contentsOf: retainedPrepared, encoding: .utf8), "version-2")
    }

    func testMissingRenameBoundaryStageSubstitutionCannotReturnFalseSuccess() throws {
        let destination = directory.appendingPathComponent("Created.md")
        let retainedPrepared = directory.appendingPathComponent("retained-prepared")
        var calls = SecureFileSyscalls.live
        let liveRename = calls.renameAtX
        var renameCalls = 0
        calls.renameAtX = { sourceFD, source, destinationFD, target, flags in
            renameCalls += 1
            let stageURL = self.directory.appendingPathComponent(String(cString: source))
            guard Darwin.rename(stageURL.path, retainedPrepared.path) == 0 else {
                return -1
            }
            do {
                try Data("bystander".utf8).write(to: stageURL)
            } catch {
                XCTFail("could not install rename-boundary bystander: \(error)")
                errno = EIO
                return -1
            }
            return liveRename(sourceFD, source, destinationFD, target, flags)
        }
        let guarded = try handle(calls)

        XCTAssertThrowsError(
            try guarded.transaction(
                component: FileComponent("Created.md"),
                data: Data("intended".utf8),
                expectation: .missing,
                policy: .userContent
            ).commit()
        ) { error in
            guard case .indeterminate(let receipt) = error as? SecureLocalFileError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertNil(receipt.version)
            XCTAssertNil(receipt.recovery)
            XCTAssertEqual(
                receipt.durability,
                .indeterminate(operation: .verify, errno: nil))
        }
        XCTAssertEqual(renameCalls, 1)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "bystander")
        XCTAssertEqual(try String(contentsOf: retainedPrepared, encoding: .utf8), "intended")
    }

    func testReusableStageRetriesEffectThenInterruptedTruncateAndSeekAtOffsetZero() throws {
        let destination = directory.appendingPathComponent("Note.md")
        try Data("long previous recovery contents".utf8).write(to: destination)
        let baseline = try handle()
        let initial = try baseline.version(of: FileComponent("Note.md"))
        let first = try baseline.transaction(
            component: FileComponent("Note.md"),
            data: Data("version-1".utf8),
            expectation: .exact(initial),
            policy: .userContent
        ).commit()
        let expected = try XCTUnwrap(first.version)
        let recovery = try XCTUnwrap(first.recovery)

        var calls = SecureFileSyscalls.live
        let liveOpenAt = calls.openAt
        let liveTruncate = calls.ftruncate
        let liveSeek = calls.lseek
        var writableStage = Int32(-1)
        var truncateAttempts = 0
        var preparationSeekAttempts = 0
        var preparationSeekFinished = false
        calls.openAt = { parent, name, flags in
            let result = liveOpenAt(parent, name, flags)
            if result >= 0,
                String(cString: name) == recovery.component.rawValue,
                flags & O_ACCMODE == O_RDWR
            {
                writableStage = result
            }
            return result
        }
        calls.ftruncate = { descriptor, size in
            guard descriptor == writableStage else {
                return liveTruncate(descriptor, size)
            }
            truncateAttempts += 1
            let result = liveTruncate(descriptor, size)
            if truncateAttempts == 1, result == 0 {
                errno = EINTR
                return -1
            }
            return result
        }
        calls.lseek = { descriptor, offset, whence in
            guard descriptor == writableStage,
                truncateAttempts >= 2,
                !preparationSeekFinished,
                offset == 0,
                whence == SEEK_SET
            else { return liveSeek(descriptor, offset, whence) }
            preparationSeekAttempts += 1
            let result = liveSeek(descriptor, offset, whence)
            if preparationSeekAttempts == 1, result == 0 {
                errno = EINTR
                return -1
            }
            preparationSeekFinished = true
            return result
        }
        let guarded = try handle(calls)

        let receipt = try guarded.transaction(
            component: FileComponent("Note.md"),
            data: Data("x".utf8),
            expectation: .exact(expected),
            policy: .userContent,
            reusableStage: FileRecoverySlot(
                authority: recovery,
                contents: .previousDestination)
        ).commit()

        XCTAssertEqual(truncateAttempts, 2)
        XCTAssertEqual(preparationSeekAttempts, 2)
        XCTAssertEqual(receipt.recoveryComponent, recovery.component)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "x")
    }

    func testReusableStagePreventsPostInspectionHardLinkBeforeDestructiveMutation() throws {
        let destination = directory.appendingPathComponent("Note.md")
        try Data("version-0".utf8).write(to: destination)
        let baseline = try handle()
        let initial = try baseline.version(of: FileComponent("Note.md"))
        let first = try baseline.transaction(
            component: FileComponent("Note.md"),
            data: Data("version-1".utf8),
            expectation: .exact(initial),
            policy: .userContent
        ).commit()
        let expected = try XCTUnwrap(first.version)
        let recovery = try XCTUnwrap(first.recovery)
        let recoveryURL = directory.appendingPathComponent(recovery.component.rawValue)
        let hostileAlias = directory.appendingPathComponent("hostile-hard-link")
        XCTAssertEqual(
            try String(contentsOf: recoveryURL, encoding: .utf8),
            "version-0")

        var calls = SecureFileSyscalls.live
        let liveOpenAt = calls.openAt
        let liveTruncate = calls.ftruncate
        var writableStage = Int32(-1)
        var linkResult: Int32?
        var linkError: Int32?
        calls.openAt = { parent, name, flags in
            let result = liveOpenAt(parent, name, flags)
            if result >= 0,
                String(cString: name) == recovery.component.rawValue,
                flags & O_ACCMODE == O_RDWR
            {
                writableStage = result
            }
            return result
        }
        calls.ftruncate = { descriptor, size in
            if descriptor == writableStage, linkResult == nil {
                errno = 0
                linkResult = Darwin.link(recoveryURL.path, hostileAlias.path)
                linkError = errno
            }
            return liveTruncate(descriptor, size)
        }
        let guarded = try handle(calls)

        let second = try guarded.transaction(
            component: FileComponent("Note.md"),
            data: Data("version-2".utf8),
            expectation: .exact(expected),
            policy: .userContent,
            reusableStage: FileRecoverySlot(
                authority: recovery,
                contents: .previousDestination)
        ).commit()

        XCTAssertNotNil(linkResult)
        XCTAssertNotEqual(
            linkResult,
            0,
            "a same-UID directory writer linked the named stage immediately before truncation")
        XCTAssertTrue(
            linkError == EPERM || linkError == EACCES,
            "the mutation guard should reject the hostile link, got errno \(linkError ?? 0)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: hostileAlias.path))
        XCTAssertEqual(second.recoveryComponent, recovery.component)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "version-2")
        XCTAssertEqual(try String(contentsOf: recoveryURL, encoding: .utf8), "version-1")
    }

    func testMutationGuardReconcilesEffectThenEINTRAndRestoresFlags() throws {
        var calls = SecureFileSyscalls.live
        let liveCreateAt = calls.createAt
        let liveFchflags = calls.fchflags
        var stageDescriptor = Int32(-1)
        var guardAttempts = 0
        var restoreAttempts = 0
        calls.createAt = { parent, name, flags, mode in
            let result = liveCreateAt(parent, name, flags, mode)
            if result >= 0 { stageDescriptor = result }
            return result
        }
        calls.fchflags = { descriptor, flags in
            guard descriptor == stageDescriptor else {
                return liveFchflags(descriptor, flags)
            }
            if flags & UInt32(UF_IMMUTABLE) != 0 {
                guardAttempts += 1
                let result = liveFchflags(descriptor, flags)
                if guardAttempts == 1, result == 0 {
                    errno = EINTR
                    return -1
                }
                return result
            }
            if guardAttempts > 0, restoreAttempts < 2 {
                restoreAttempts += 1
                let result = liveFchflags(descriptor, flags)
                if restoreAttempts == 1, result == 0 {
                    errno = EINTR
                    return -1
                }
                return result
            }
            return liveFchflags(descriptor, flags)
        }
        let guarded = try handle(calls)

        _ = try guarded.transaction(
            component: FileComponent("Created.md"),
            data: Data("saved".utf8),
            expectation: .missing,
            policy: .privateStorage
        ).commit()

        XCTAssertEqual(guardAttempts, 2)
        XCTAssertEqual(restoreAttempts, 2)
        var status = stat()
        XCTAssertEqual(
            lstat(directory.appendingPathComponent("Created.md").path, &status),
            0)
        XCTAssertEqual(status.st_flags & UInt32(UF_IMMUTABLE), 0)
        XCTAssertEqual(
            try String(
                contentsOf: directory.appendingPathComponent("Created.md"),
                encoding: .utf8),
            "saved")
    }

    func testPersistentMutationGuardRestoreFailureIsUnconfirmedAndNotReusable() throws {
        var calls = SecureFileSyscalls.live
        let liveCreateAt = calls.createAt
        let liveFchflags = calls.fchflags
        var stageDescriptor = Int32(-1)
        var stageName: String?
        var restoreAttempts = 0
        calls.createAt = { parent, name, flags, mode in
            let result = liveCreateAt(parent, name, flags, mode)
            if result >= 0 {
                stageDescriptor = result
                stageName = String(cString: name)
            }
            return result
        }
        calls.fchflags = { descriptor, flags in
            guard descriptor == stageDescriptor else {
                return liveFchflags(descriptor, flags)
            }
            if flags & UInt32(UF_IMMUTABLE) != 0 {
                return liveFchflags(descriptor, flags)
            }
            restoreAttempts += 1
            errno = EPERM
            return -1
        }
        let guarded = try handle(calls)

        XCTAssertThrowsError(
            try guarded.transaction(
                component: FileComponent("Created.md"),
                data: Data("saved".utf8),
                expectation: .missing,
                policy: .privateStorage
            ).commit()
        ) { error in
            guard case let .prepublicationFailure(cause, receipt) =
                error as? SecureLocalFileError
            else { return XCTFail("unexpected error: \(error)") }
            XCTAssertEqual(cause, .operation(.metadata, errno: EPERM))
            XCTAssertEqual(
                receipt.durability,
                .notPublishedRecoveryUnconfirmed(operation: .verify, errno: nil))
            XCTAssertNil(receipt.recoverySlot)
        }
        XCTAssertEqual(restoreAttempts, 2)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("Created.md").path))
        let retainedName = try XCTUnwrap(stageName)
        let retainedURL = directory.appendingPathComponent(retainedName)
        var status = stat()
        XCTAssertEqual(lstat(retainedURL.path, &status), 0)
        XCTAssertNotEqual(status.st_flags & UInt32(UF_IMMUTABLE), 0)
        // Explicit review can clear the guard; no reusable authority was
        // minted for the un-restored artifact.
        XCTAssertEqual(chflags(retainedURL.path, 0), 0)
    }

    func testReusableStagePersistentInterruptedTruncateAndSeekAreBoundedAndRetained() throws {
        let destination = directory.appendingPathComponent("Note.md")
        try Data("version-0".utf8).write(to: destination)
        let baseline = try handle()
        let initial = try baseline.version(of: FileComponent("Note.md"))
        let first = try baseline.transaction(
            component: FileComponent("Note.md"),
            data: Data("version-1".utf8),
            expectation: .exact(initial),
            policy: .userContent
        ).commit()
        let expected = try XCTUnwrap(first.version)
        let recovery = try XCTUnwrap(first.recovery)

        var truncateCalls = SecureFileSyscalls.live
        let truncateLiveOpenAt = truncateCalls.openAt
        var truncateStage = Int32(-1)
        var truncateAttempts = 0
        var truncatePublishCalls = 0
        truncateCalls.openAt = { parent, name, flags in
            let result = truncateLiveOpenAt(parent, name, flags)
            if result >= 0,
                String(cString: name) == recovery.component.rawValue,
                flags & O_ACCMODE == O_RDWR
            {
                truncateStage = result
            }
            return result
        }
        truncateCalls.ftruncate = { descriptor, _ in
            guard descriptor == truncateStage else {
                return Darwin.ftruncate(descriptor, 0)
            }
            truncateAttempts += 1
            errno = EINTR
            return -1
        }
        truncateCalls.renameAtX = { _, _, _, _, _ in
            truncatePublishCalls += 1
            errno = EIO
            return -1
        }
        let truncateGuarded = try handle(truncateCalls)
        var afterTruncateFailure: FileRecoveryAuthority?
        XCTAssertThrowsError(
            try truncateGuarded.transaction(
                component: FileComponent("Note.md"),
                data: Data("version-2".utf8),
                expectation: .exact(expected),
                policy: .userContent,
                reusableStage: FileRecoverySlot(
                    authority: recovery,
                    contents: .previousDestination)
            ).commit()
        ) { error in
            afterTruncateFailure = self.retainedPrepublicationReceipt(
                from: error,
                cause: .operation(.truncate, errno: EINTR))?.recovery
        }
        XCTAssertEqual(truncateAttempts, 8)
        XCTAssertEqual(truncatePublishCalls, 0)

        let refreshed = try XCTUnwrap(afterTruncateFailure)
        XCTAssertEqual(refreshed.component, recovery.component)
        var seekCalls = SecureFileSyscalls.live
        let seekLiveOpenAt = seekCalls.openAt
        let seekLiveTruncate = seekCalls.ftruncate
        var seekStage = Int32(-1)
        var didTruncate = false
        var seekAttempts = 0
        var seekPublishCalls = 0
        seekCalls.openAt = { parent, name, flags in
            let result = seekLiveOpenAt(parent, name, flags)
            if result >= 0,
                String(cString: name) == refreshed.component.rawValue,
                flags & O_ACCMODE == O_RDWR
            {
                seekStage = result
            }
            return result
        }
        seekCalls.ftruncate = { descriptor, size in
            let result = seekLiveTruncate(descriptor, size)
            if descriptor == seekStage, result == 0 { didTruncate = true }
            return result
        }
        seekCalls.lseek = { descriptor, offset, whence in
            guard descriptor == seekStage,
                didTruncate,
                offset == 0,
                whence == SEEK_SET
            else { return Darwin.lseek(descriptor, offset, whence) }
            if seekAttempts < 8 {
                seekAttempts += 1
                errno = EINTR
                return -1
            }
            // Once the bounded preparation retry budget is exhausted, permit
            // the independent recovery rehash to seek the retained inode. The
            // injected fault is persistent for the operation under test, not
            // for the later authority-reconciliation operation.
            return Darwin.lseek(descriptor, offset, whence)
        }
        seekCalls.renameAtX = { _, _, _, _, _ in
            seekPublishCalls += 1
            errno = EIO
            return -1
        }
        let seekGuarded = try handle(seekCalls)
        XCTAssertThrowsError(
            try seekGuarded.transaction(
                component: FileComponent("Note.md"),
                data: Data("version-2".utf8),
                expectation: .exact(expected),
                policy: .userContent,
                reusableStage: FileRecoverySlot(
                    authority: refreshed,
                    contents: .unpublishedScratch)
            ).commit()
        ) { error in
            let receipt = self.retainedPrepublicationReceipt(
                from: error,
                cause: .operation(.seek, errno: EINTR))
            XCTAssertNotNil(receipt)
            XCTAssertEqual(receipt?.recoveryContents, .unpublishedScratch)
        }
        XCTAssertEqual(seekAttempts, 8)
        XCTAssertEqual(seekPublishCalls, 0)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "version-1")
        XCTAssertEqual(try names().filter { $0.hasPrefix(".markdev-stage-") }.count, 1)
    }

    func testReusableReadOnlyStageIsNormalizedAndStaleMetadataIsScrubbed() throws {
        let destination = directory.appendingPathComponent("Note.md")
        try Data("version-0".utf8).write(to: destination)
        let attribute = "com.markdev.tests.reusable-stale"
        let value = Data("stale".utf8)
        XCTAssertEqual(value.withUnsafeBytes { raw in
            setxattr(destination.path, attribute, raw.baseAddress, raw.count, 0, 0)
        }, 0)
        XCTAssertEqual(chmod(destination.path, 0o444), 0)
        let guarded = try handle()
        let initial = try guarded.version(of: FileComponent("Note.md"))
        let first = try guarded.transaction(
            component: FileComponent("Note.md"),
            data: Data("version-1".utf8),
            expectation: .exact(initial),
            policy: .userContent
        ).commit()
        let recovery = try XCTUnwrap(first.recovery)
        XCTAssertTrue(try extendedAttributeNames(
            at: directory.appendingPathComponent(recovery.component.rawValue)
        ).contains(attribute))
        XCTAssertEqual(chmod(destination.path, 0o644), 0)
        XCTAssertEqual(removexattr(destination.path, attribute, 0), 0)
        XCTAssertEqual(chmod(destination.path, 0o444), 0)
        let expected = try guarded.version(of: FileComponent("Note.md"))

        let second = try guarded.transaction(
            component: FileComponent("Note.md"),
            data: Data("version-2".utf8),
            expectation: .exact(expected),
            policy: .userContent,
            reusableStage: FileRecoverySlot(
                authority: recovery,
                contents: .previousDestination)
        ).commit()

        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o444)
        XCTAssertFalse(try extendedAttributeNames(at: destination).contains(attribute))
        XCTAssertEqual(second.recoveryComponent, recovery.component)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "version-2")
    }

    func testReusableStageScrubsInheritedExtendedACLBeforeApplyingCurrentMetadata() throws {
        let destination = directory.appendingPathComponent("Note.md")
        try Data("version-0".utf8).write(to: destination)
        // Use a non-blocking ACL entry so the test isolates metadata scrubbing;
        // a `deny delete` entry correctly makes the kernel refuse RENAME_SWAP.
        try runChmodACL(["+a", "everyone allow read"], at: destination)
        XCTAssertTrue(try extendedACLHasEntries(at: destination))
        let guarded = try handle()
        let initial = try guarded.version(of: FileComponent("Note.md"))
        let first = try guarded.transaction(
            component: FileComponent("Note.md"),
            data: Data("version-1".utf8),
            expectation: .exact(initial),
            policy: .userContent
        ).commit()
        let reusable = try XCTUnwrap(first.recoverySlot)
        let stageURL = directory.appendingPathComponent(
            reusable.authority.component.rawValue)
        XCTAssertTrue(try extendedACLHasEntries(at: stageURL))
        try runChmodACL(["-N"], at: destination)
        XCTAssertFalse(try extendedACLHasEntries(at: destination))
        let expected = try guarded.version(of: FileComponent("Note.md"))

        let second = try guarded.transaction(
            component: FileComponent("Note.md"),
            data: Data("version-2".utf8),
            expectation: .exact(expected),
            policy: .userContent,
            reusableStage: reusable
        ).commit()

        XCTAssertEqual(second.recoveryComponent, reusable.authority.component)
        XCTAssertFalse(try extendedACLHasEntries(at: destination))
        XCTAssertFalse(try extendedACLHasEntries(at: stageURL))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "version-2")
    }

    func testReusableSlotRoleSurvivesCancellationBeforeFirstMutation() throws {
        for (suffix, role) in [
            ("previous", FileRecoveryContents.previousDestination),
            ("scratch", FileRecoveryContents.unpublishedScratch),
        ] {
            let component = try FileComponent("Role-\(suffix).md")
            let destination = directory.appendingPathComponent(component.rawValue)
            try Data("version-0".utf8).write(to: destination)
            let baseline = try handle()
            let initial = try baseline.version(of: component)
            let first = try baseline.transaction(
                component: component,
                data: Data("version-1".utf8),
                expectation: .exact(initial),
                policy: .userContent
            ).commit()
            let authority = try XCTUnwrap(first.recovery)
            let expected = try XCTUnwrap(first.version)
            var calls = SecureFileSyscalls.live
            let liveOpenAt = calls.openAt
            let liveClose = calls.close
            let liveFchflags = calls.fchflags
            var stageReadOpens = 0
            var namedDescriptor = Int32(-1)
            let cancel = SecureIOLockedValue(false)
            var mutationCalls = 0
            calls.openAt = { parent, name, flags in
                let result = liveOpenAt(parent, name, flags)
                if result >= 0,
                    String(cString: name) == authority.component.rawValue,
                    flags & O_ACCMODE == O_RDONLY
                {
                    stageReadOpens += 1
                    if stageReadOpens == 2 { namedDescriptor = result }
                }
                return result
            }
            calls.close = { descriptor in
                if descriptor == namedDescriptor { cancel.value = true }
                return liveClose(descriptor)
            }
            calls.fchflags = { descriptor, flags in
                mutationCalls += 1
                return liveFchflags(descriptor, flags)
            }
            let guarded = try handle(calls)
            var transaction = guarded.transaction(
                component: component,
                data: Data("version-2".utf8),
                expectation: .exact(expected),
                policy: .userContent,
                reusableStage: FileRecoverySlot(
                    authority: authority,
                    contents: role))
            transaction.cancellationCheck = { cancel.value }

            XCTAssertThrowsError(try transaction.commit()) { error in
                let receipt = self.retainedPrepublicationReceipt(
                    from: error,
                    cause: .cancelled)
                XCTAssertEqual(receipt?.recoveryContents, role)
            }
            XCTAssertEqual(mutationCalls, 0)
            XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "version-1")
        }
    }

    func testReusableSlotCannotCrossDestinationKeyBeforeMutation() throws {
        let firstURL = directory.appendingPathComponent("First.md")
        let secondURL = directory.appendingPathComponent("Second.md")
        try Data("first-0".utf8).write(to: firstURL)
        try Data("second-0".utf8).write(to: secondURL)
        let guarded = try handle()
        let firstInitial = try guarded.version(of: FileComponent("First.md"))
        let first = try guarded.transaction(
            component: FileComponent("First.md"),
            data: Data("first-1".utf8),
            expectation: .exact(firstInitial),
            policy: .userContent
        ).commit()
        let foreignSlot = try XCTUnwrap(first.recoverySlot)
        let foreignURL = directory.appendingPathComponent(
            foreignSlot.authority.component.rawValue)
        let foreignIdentity = try XCTUnwrap(LocalFileSystem.stamp(of: foreignURL)?.identity)
        let secondExpected = try guarded.version(of: FileComponent("Second.md"))

        XCTAssertThrowsError(
            try guarded.transaction(
                component: FileComponent("Second.md"),
                data: Data("second-1".utf8),
                expectation: .exact(secondExpected),
                policy: .userContent,
                reusableStage: foreignSlot
            ).commit()
        ) { error in
            XCTAssertEqual(error as? SecureLocalFileError, .expectationMismatch)
        }
        XCTAssertEqual(try String(contentsOf: secondURL, encoding: .utf8), "second-0")
        XCTAssertEqual(try String(contentsOf: foreignURL, encoding: .utf8), "first-0")
        XCTAssertEqual(LocalFileSystem.stamp(of: foreignURL)?.identity, foreignIdentity)
    }

    /// The regression seam itself must not expose pathname deletion again: an
    /// inspect-then-unlink implementation cannot be made identity-conditional
    /// on Darwin and can erase a substituted bystander.
    func testTransactionSyscallSurfaceContainsNoPathnameDeletionPrimitive() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("MarkDevKit/Workspace/SecureLocalFileSystem.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertFalse(source.contains("unlinkAt"))
        XCTAssertFalse(source.contains("Darwin.unlinkat"))
    }

    func testParentRenameBeforePublishFailsClosedAndDoesNotWriteReplacementDirectory() throws {
        let originalDirectory = directory!
        let moved = originalDirectory.deletingLastPathComponent()
            .appendingPathComponent("\(originalDirectory.lastPathComponent)-moved")
        let guarded = try handle()
        XCTAssertEqual(Darwin.rename(originalDirectory.path, moved.path), 0)
        try FileManager.default.createDirectory(at: originalDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: moved) }

        var retained: FileTransactionReceipt?
        XCTAssertThrowsError(
            try guarded.transaction(
                component: FileComponent("Note.md"),
                data: Data("after".utf8),
                expectation: .missing,
                policy: .userContent
            ).commit()
        ) { error in
            retained = self.retainedPrepublicationReceipt(
                from: error,
                cause: .expectationMismatch)
        }
        XCTAssertEqual(try names(), [])
        let receipt = try XCTUnwrap(retained)
        XCTAssertEqual(
            receipt.destination.standardizedFileURL,
            moved.appendingPathComponent("Note.md").standardizedFileURL)
        let recovery = try XCTUnwrap(receipt.recovery)
        XCTAssertEqual(try guarded.version(of: recovery.component), recovery.version)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: moved.path)
                .filter { $0.hasPrefix(".markdev-stage-") }.count,
            1)
    }

    func testParentMoveInsidePublishReportsTheRetainedDirectoryLocation() throws {
        let originalDirectory = try XCTUnwrap(directory)
        let movedDirectory = originalDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Moved-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: movedDirectory) }
        var calls = SecureFileSyscalls.live
        let liveRename = calls.renameAtX
        var injected = false
        calls.renameAtX = { sourceFD, source, destinationFD, target, flags in
            guard !injected else {
                return liveRename(sourceFD, source, destinationFD, target, flags)
            }
            injected = true
            XCTAssertEqual(Darwin.rename(originalDirectory.path, movedDirectory.path), 0)
            do {
                try FileManager.default.createDirectory(
                    at: originalDirectory,
                    withIntermediateDirectories: false)
            } catch {
                XCTFail("could not recreate original parent spelling: \(error)")
            }
            return liveRename(sourceFD, source, destinationFD, target, flags)
        }
        let guarded = try handle(calls)

        XCTAssertThrowsError(
            try guarded.transaction(
                component: FileComponent("Note.md"),
                data: Data("after".utf8),
                expectation: .missing,
                policy: .userContent
            ).commit()
        ) { error in
            guard case .indeterminate(let receipt) = error as? SecureLocalFileError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(
                receipt.destination.standardizedFileURL,
                movedDirectory.appendingPathComponent("Note.md").standardizedFileURL)
            XCTAssertNotNil(receipt.version)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: originalDirectory.appendingPathComponent("Note.md").path))
        XCTAssertEqual(
            try String(
                contentsOf: movedDirectory.appendingPathComponent("Note.md"),
                encoding: .utf8),
            "after")
    }

    func testHardLinkedTargetIsRefusedBeforeStaging() throws {
        let destination = directory.appendingPathComponent("Note.md")
        let alias = directory.appendingPathComponent("Alias.md")
        try Data("before".utf8).write(to: destination)
        let handle = try handle()
        let expected = try handle.version(of: FileComponent("Note.md"))
        try FileManager.default.linkItem(at: destination, to: alias)

        XCTAssertThrowsError(
            try handle.transaction(
                component: FileComponent("Note.md"),
                data: Data("after".utf8),
                expectation: .exact(expected),
                policy: .userContent
            ).commit()
        ) { error in
            XCTAssertTrue(
                error as? SecureLocalFileError == .expectationMismatch
                    || error as? SecureLocalFileError == .hardLinkedEntry)
        }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "before")
        XCTAssertEqual(try String(contentsOf: alias, encoding: .utf8), "before")
    }

    func testSymlinkFifoAndDirectoryTargetsAreRefused() throws {
        let handle = try handle()
        let real = directory.appendingPathComponent("Real.md")
        try Data("safe".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("Link.md"), withDestinationURL: real)
        XCTAssertEqual(
            mkfifo(directory.appendingPathComponent("Pipe.md").path, 0o600), 0)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("Folder.md"),
            withIntermediateDirectories: false)

        for name in ["Link.md", "Pipe.md", "Folder.md"] {
            XCTAssertThrowsError(
                try handle.transaction(
                    component: FileComponent(name),
                    data: Data("bad".utf8),
                    expectation: .missing,
                    policy: .userContent
                ).commit(), "accepted \(name)")
        }
        XCTAssertEqual(try String(contentsOf: real, encoding: .utf8), "safe")
    }

    func testEINTRAndRepeatedShortWritesStillPublishEveryByte() throws {
        var calls = SecureFileSyscalls.live
        let liveWrite = calls.write
        var attempts = 0
        calls.write = { descriptor, bytes, count in
            attempts += 1
            if attempts == 1 {
                errno = EINTR
                return -1
            }
            return liveWrite(descriptor, bytes, min(count, 3))
        }
        let handle = try handle(calls)
        let payload = Data("0123456789abcdef".utf8)

        _ = try handle.transaction(
            component: FileComponent("Short.bin"),
            data: payload,
            expectation: .missing,
            policy: .privateStorage
        ).commit()

        XCTAssertGreaterThan(attempts, 5)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("Short.bin")), payload)
    }

    func testInterruptedWriteStormStopsAtFiniteBudgetAndRetainsExactStage() throws {
        var calls = SecureFileSyscalls.live
        let liveCreate = calls.createAt
        var stageDescriptor: Int32 = -1
        var writeAttempts = 0
        calls.createAt = { descriptor, name, flags, mode in
            let result = liveCreate(descriptor, name, flags, mode)
            if result >= 0 { stageDescriptor = result }
            return result
        }
        calls.write = { _, _, _ in
            writeAttempts += 1
            errno = EINTR
            return -1
        }
        let guarded = try handle(calls)

        XCTAssertThrowsError(
            try guarded.transaction(
                component: FileComponent("Interrupted.bin"),
                data: Data("payload".utf8),
                expectation: .missing,
                policy: .privateStorage
            ).commit()
        ) { error in
            XCTAssertNotNil(self.retainedPrepublicationReceipt(
                from: error,
                cause: .operation(.write, errno: EINTR)))
        }
        XCTAssertEqual(writeAttempts, 8)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("Interrupted.bin").path))
        XCTAssertEqual(try names().filter { $0.hasPrefix(".markdev-stage-") }.count, 1)
        XCTAssertGreaterThanOrEqual(stageDescriptor, 0)
        errno = 0
        XCTAssertEqual(fcntl(stageDescriptor, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
    }

    func testInterruptedOpenAndSeekStormsStopAtFiniteBudgetBeforePublication() throws {
        let destination = directory.appendingPathComponent("Note.md")
        try Data("before".utf8).write(to: destination)
        let baseline = try handle()
        let expected = try baseline.version(of: FileComponent("Note.md"))

        var openCalls = SecureFileSyscalls.live
        let liveOpenAt = openCalls.openAt
        var openAttempts = 0
        openCalls.openAt = { descriptor, name, flags in
            guard String(cString: name) == "Note.md" else {
                return liveOpenAt(descriptor, name, flags)
            }
            openAttempts += 1
            errno = EINTR
            return -1
        }
        let openGuarded = try handle(openCalls)
        XCTAssertThrowsError(
            try openGuarded.transaction(
                component: FileComponent("Note.md"),
                data: Data("after".utf8),
                expectation: .exact(expected),
                policy: .userContent
            ).commit()
        ) { error in
            XCTAssertEqual(error as? SecureLocalFileError, .operation(.openTarget, errno: EINTR))
        }
        XCTAssertEqual(openAttempts, 8)

        var seekCalls = SecureFileSyscalls.live
        var seekAttempts = 0
        seekCalls.lseek = { _, _, _ in
            seekAttempts += 1
            errno = EINTR
            return -1
        }
        let seekGuarded = try handle(seekCalls)
        XCTAssertThrowsError(
            try seekGuarded.transaction(
                component: FileComponent("Note.md"),
                data: Data("after".utf8),
                expectation: .exact(expected),
                policy: .userContent
            ).commit()
        ) { error in
            XCTAssertEqual(error as? SecureLocalFileError, .operation(.verify, errno: EINTR))
        }
        XCTAssertEqual(seekAttempts, 8)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "before")
        XCTAssertEqual(try names(), ["Note.md"])
    }

    func testInterruptedDirectoryOpenStopsAtEightAttempts() throws {
        var calls = SecureFileSyscalls.live
        var attempts = 0
        calls.openPath = { _, _ in
            attempts += 1
            errno = EINTR
            return -1
        }

        XCTAssertThrowsError(
            try SecureLocalDirectoryHandle(opening: directory, syscalls: calls)
        ) { error in
            XCTAssertEqual(
                error as? SecureLocalFileError,
                .operation(.openDirectory, errno: EINTR))
        }
        XCTAssertEqual(attempts, 8)
    }

    func testInterruptedDirectoryInspectionStopsAtEightAttemptsAndClosesDescriptor() throws {
        var calls = SecureFileSyscalls.live
        let liveOpenPath = calls.openPath
        var openedDescriptor: Int32 = -1
        var attempts = 0
        calls.openPath = { path, flags in
            let result = liveOpenPath(path, flags)
            if result >= 0 { openedDescriptor = result }
            return result
        }
        calls.fstat = { _, _ in
            attempts += 1
            errno = EINTR
            return -1
        }

        XCTAssertThrowsError(
            try SecureLocalDirectoryHandle(opening: directory, syscalls: calls)
        ) { error in
            XCTAssertEqual(
                error as? SecureLocalFileError,
                .operation(.openDirectory, errno: EINTR))
        }
        XCTAssertEqual(attempts, 8)
        XCTAssertGreaterThanOrEqual(openedDescriptor, 0)
        errno = 0
        XCTAssertEqual(fcntl(openedDescriptor, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
    }

    func testInterruptedReadStopsAtEightAttemptsAndClosesTarget() throws {
        let destination = directory.appendingPathComponent("Note.md")
        try Data("before".utf8).write(to: destination)
        let expected = try handle().version(of: FileComponent("Note.md"))
        var calls = SecureFileSyscalls.live
        let liveOpenAt = calls.openAt
        var targetDescriptor: Int32 = -1
        var attempts = 0
        calls.openAt = { descriptor, name, flags in
            let result = liveOpenAt(descriptor, name, flags)
            if result >= 0, String(cString: name) == "Note.md" {
                targetDescriptor = result
            }
            return result
        }
        calls.read = { _, _, _ in
            attempts += 1
            errno = EINTR
            return -1
        }
        let guarded = try handle(calls)

        XCTAssertThrowsError(
            try guarded.transaction(
                component: FileComponent("Note.md"),
                data: Data("after".utf8),
                expectation: .exact(expected),
                policy: .userContent
            ).commit()
        ) { error in
            XCTAssertEqual(error as? SecureLocalFileError, .operation(.verify, errno: EINTR))
        }
        XCTAssertEqual(attempts, 8)
        XCTAssertGreaterThanOrEqual(targetDescriptor, 0)
        errno = 0
        XCTAssertEqual(fcntl(targetDescriptor, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "before")
    }

    func testInterruptedMetadataCallsStopAtEightAttemptsWithoutPublishing() throws {
        let destination = directory.appendingPathComponent("Hidden.md")
        try Data("before".utf8).write(to: destination)
        XCTAssertEqual(chflags(destination.path, UInt32(UF_HIDDEN)), 0)
        defer { _ = chflags(destination.path, 0) }
        let expected = try handle().version(of: FileComponent("Hidden.md"))

        for operation in ["chmod", "chflags"] {
            let retainedBefore = try names().filter { $0.hasPrefix(".markdev-stage-") }.count
            var calls = SecureFileSyscalls.live
            let liveCreate = calls.createAt
            var stageDescriptor: Int32 = -1
            var attempts = 0
            calls.createAt = { descriptor, name, flags, mode in
                let result = liveCreate(descriptor, name, flags, mode)
                if result >= 0 { stageDescriptor = result }
                return result
            }
            if operation == "chmod" {
                calls.fchmod = { _, _ in
                    attempts += 1
                    errno = EINTR
                    return -1
                }
            } else {
                calls.fchflags = { _, _ in
                    attempts += 1
                    errno = EINTR
                    return -1
                }
            }
            let guarded = try handle(calls)

            XCTAssertThrowsError(
                try guarded.transaction(
                    component: FileComponent("Hidden.md"),
                    data: Data("after".utf8),
                    expectation: .exact(expected),
                    policy: .userContent
                ).commit(), operation
            ) { error in
                XCTAssertNotNil(self.retainedPrepublicationReceipt(
                    from: error,
                    cause: .operation(.metadata, errno: EINTR)))
            }
            XCTAssertEqual(attempts, 8, operation)
            XCTAssertGreaterThanOrEqual(stageDescriptor, 0)
            errno = 0
            XCTAssertEqual(fcntl(stageDescriptor, F_GETFD), -1)
            XCTAssertEqual(errno, EBADF)
            XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "before")
            XCTAssertEqual(
                try names().filter { $0.hasPrefix(".markdev-stage-") }.count,
                retainedBefore + 1)
        }
    }

    func testInterruptedStageSyncStopsAtEightAttemptsWithoutPublishing() throws {
        var calls = SecureFileSyscalls.live
        let liveCreate = calls.createAt
        var stageDescriptor: Int32 = -1
        var attempts = 0
        calls.createAt = { descriptor, name, flags, mode in
            let result = liveCreate(descriptor, name, flags, mode)
            if result >= 0 { stageDescriptor = result }
            return result
        }
        calls.fsync = { descriptor in
            guard descriptor == stageDescriptor else { return Darwin.fsync(descriptor) }
            attempts += 1
            errno = EINTR
            return -1
        }
        let guarded = try handle(calls)

        XCTAssertThrowsError(
            try guarded.transaction(
                component: FileComponent("Note.md"),
                data: Data("after".utf8),
                expectation: .missing,
                policy: .privateStorage
            ).commit()
        ) { error in
            XCTAssertNotNil(self.retainedPrepublicationReceipt(
                from: error,
                cause: .operation(.syncFile, errno: EINTR)))
        }
        XCTAssertEqual(attempts, 8)
        XCTAssertGreaterThanOrEqual(stageDescriptor, 0)
        errno = 0
        XCTAssertEqual(fcntl(stageDescriptor, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
        XCTAssertEqual(try names().filter { $0.hasPrefix(".markdev-stage-") }.count, 1)
    }

    func testInterruptedPrivateDirectoryModeStopsAtEightAttemptsAndClosesDirectory() throws {
        var calls = SecureFileSyscalls.live
        let liveOpenPath = calls.openPath
        var openedDescriptor: Int32 = -1
        var attempts = 0
        calls.openPath = { path, flags in
            let result = liveOpenPath(path, flags)
            if result >= 0 { openedDescriptor = result }
            return result
        }
        calls.fchmod = { _, _ in
            attempts += 1
            errno = EINTR
            return -1
        }

        XCTAssertThrowsError(
            try PrivateStorageDirectory(existing: directory, syscalls: calls)
        ) { error in
            XCTAssertEqual(error as? SecureLocalFileError, .operation(.metadata, errno: EINTR))
        }
        XCTAssertEqual(attempts, 8)
        XCTAssertGreaterThanOrEqual(openedDescriptor, 0)
        errno = 0
        XCTAssertEqual(fcntl(openedDescriptor, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
    }

    func testPrivateDirectoryModeSuccessWithoutEffectFailsPostcondition() throws {
        XCTAssertEqual(chmod(directory.path, 0o755), 0)
        var calls = SecureFileSyscalls.live
        calls.fchmod = { _, _ in 0 }

        XCTAssertThrowsError(
            try PrivateStorageDirectory(existing: directory, syscalls: calls)
        ) { error in
            XCTAssertEqual(error as? SecureLocalFileError, .expectationMismatch)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
    }

    func testCancellationStopsAnInterruptedWriteBeforeRetryBudget() throws {
        var calls = SecureFileSyscalls.live
        let attempts = SecureIOLockedValue(0)
        calls.write = { _, _, _ in
            attempts.mutate { $0 += 1 }
            errno = EINTR
            return -1
        }
        let guarded = try handle(calls)
        var transaction = guarded.transaction(
            component: try FileComponent("Cancelled.md"),
            data: Data("after".utf8),
            expectation: .missing,
            policy: .privateStorage)
        transaction.cancellationCheck = { attempts.value >= 3 }

        XCTAssertThrowsError(try transaction.commit()) { error in
            XCTAssertNotNil(self.retainedPrepublicationReceipt(
                from: error,
                cause: .cancelled))
        }
        XCTAssertEqual(attempts.value, 3)
        XCTAssertEqual(try names().filter { $0.hasPrefix(".markdev-stage-") }.count, 1)
    }

    func testInterruptedPublishIsNeverRetried() throws {
        var calls = SecureFileSyscalls.live
        var renameAttempts = 0
        calls.renameAtX = { _, _, _, _, _ in
            renameAttempts += 1
            errno = EINTR
            return -1
        }
        let guarded = try handle(calls)

        XCTAssertThrowsError(
            try guarded.transaction(
                component: FileComponent("Note.md"),
                data: Data("after".utf8),
                expectation: .missing,
                policy: .privateStorage
            ).commit()
        ) { error in
            XCTAssertNotNil(self.retainedPrepublicationReceipt(
                from: error,
                cause: .operation(.publish, errno: EINTR)))
        }
        XCTAssertEqual(renameAttempts, 1)
        XCTAssertEqual(try names().filter { $0.hasPrefix(".markdev-stage-") }.count, 1)
    }

    /// Darwin documents failed rename calls as no-effect. This stronger
    /// injected-adapter schedule nevertheless proves MarkDev never deletes or
    /// reports success if a wrapper/remote implementation performs the rename
    /// and then returns an ambiguous interruption.
    func testMissingPublishEffectThenInterruptedReturnIsIndeterminateWithoutStageLeak() throws {
        var calls = SecureFileSyscalls.live
        let liveRename = calls.renameAtX
        let liveCreate = calls.createAt
        var renameAttempts = 0
        var stageDescriptor: Int32 = -1
        calls.createAt = { parent, name, flags, mode in
            let result = liveCreate(parent, name, flags, mode)
            if result >= 0 { stageDescriptor = result }
            return result
        }
        calls.renameAtX = { sourceFD, source, destinationFD, destination, flags in
            renameAttempts += 1
            XCTAssertEqual(
                liveRename(sourceFD, source, destinationFD, destination, flags), 0)
            errno = EINTR
            return -1
        }
        let guarded = try handle(calls)

        XCTAssertThrowsError(
            try guarded.transaction(
                component: FileComponent("Note.md"),
                data: Data("after".utf8),
                expectation: .missing,
                policy: .privateStorage
            ).commit()
        ) { error in
            guard case .indeterminate(let receipt) = error as? SecureLocalFileError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(
                receipt.durability,
                .indeterminate(operation: .publish, errno: EINTR))
            XCTAssertNotNil(receipt.version)
            XCTAssertNil(receipt.recoveryComponent)
        }
        XCTAssertEqual(renameAttempts, 1)
        XCTAssertEqual(
            try String(
                contentsOf: directory.appendingPathComponent("Note.md"), encoding: .utf8),
            "after")
        XCTAssertEqual(try names(), ["Note.md"])
        XCTAssertGreaterThanOrEqual(stageDescriptor, 0)
        errno = 0
        XCTAssertEqual(fcntl(stageDescriptor, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
    }

    func testSwapEffectThenInterruptedReturnRetainsDisplacedOriginalAsIndeterminate() throws {
        let destination = directory.appendingPathComponent("Note.md")
        try Data("before".utf8).write(to: destination)
        var calls = SecureFileSyscalls.live
        let liveRename = calls.renameAtX
        let liveCreate = calls.createAt
        var renameAttempts = 0
        var stageDescriptor: Int32 = -1
        calls.createAt = { parent, name, flags, mode in
            let result = liveCreate(parent, name, flags, mode)
            if result >= 0 { stageDescriptor = result }
            return result
        }
        calls.renameAtX = { sourceFD, source, destinationFD, target, flags in
            renameAttempts += 1
            XCTAssertEqual(liveRename(sourceFD, source, destinationFD, target, flags), 0)
            errno = EINTR
            return -1
        }
        let guarded = try handle(calls)
        let expected = try guarded.version(of: FileComponent("Note.md"))

        XCTAssertThrowsError(
            try guarded.transaction(
                component: FileComponent("Note.md"),
                data: Data("after".utf8),
                expectation: .exact(expected),
                policy: .userContent
            ).commit()
        ) { error in
            guard case .indeterminate(let receipt) = error as? SecureLocalFileError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(
                receipt.durability,
                .indeterminate(operation: .publish, errno: EINTR))
            XCTAssertNotNil(receipt.version)
            XCTAssertNotNil(receipt.recoveryComponent)
        }
        XCTAssertEqual(renameAttempts, 1)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "after")
        let stages = try names().filter { $0.hasPrefix(".markdev-stage-") }
        XCTAssertEqual(stages.count, 1)
        let stageName = try XCTUnwrap(stages.first)
        XCTAssertEqual(
            try String(
                contentsOf: directory.appendingPathComponent(stageName), encoding: .utf8),
            "before")
        XCTAssertGreaterThanOrEqual(stageDescriptor, 0)
        errno = 0
        XCTAssertEqual(fcntl(stageDescriptor, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
    }

    func testPostPublishStageSubstitutionNeverSwapsBystanderIntoDestination() throws {
        let destination = directory.appendingPathComponent("Note.md")
        let recovery = directory.appendingPathComponent("attacker-recovery")
        try Data("before".utf8).write(to: destination)
        var calls = SecureFileSyscalls.live
        let liveCreate = calls.createAt
        let liveOpenAt = calls.openAt
        let liveRename = calls.renameAtX
        var stageName: String?
        var publishCompleted = false
        var injected = false
        var renameCount = 0
        calls.createAt = { parent, name, flags, mode in
            let result = liveCreate(parent, name, flags, mode)
            if result >= 0, String(cString: name).hasPrefix(".markdev-stage-") {
                stageName = String(cString: name)
            }
            return result
        }
        calls.renameAtX = { sourceFD, source, destinationFD, target, flags in
            renameCount += 1
            let result = liveRename(sourceFD, source, destinationFD, target, flags)
            if result == 0, flags & UInt32(RENAME_SWAP) != 0 {
                publishCompleted = true
            }
            return result
        }
        calls.openAt = { parent, name, flags in
            let component = String(cString: name)
            guard publishCompleted, !injected, component == stageName else {
                return liveOpenAt(parent, name, flags)
            }
            injected = true
            let moved = "attacker-recovery".withCString { recoveryName in
                liveRename(
                    parent,
                    name,
                    parent,
                    recoveryName,
                    UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH))
            }
            XCTAssertEqual(moved, 0)
            let bystander = self.directory.appendingPathComponent(component)
            do {
                try Data("bystander".utf8).write(to: bystander)
            } catch {
                XCTFail("could not create bystander: \(error)")
            }
            errno = EIO
            return -1
        }
        let guarded = try handle(calls)
        let expected = try guarded.version(of: FileComponent("Note.md"))

        XCTAssertThrowsError(
            try guarded.transaction(
                component: FileComponent("Note.md"),
                data: Data("after".utf8),
                expectation: .exact(expected),
                policy: .userContent
            ).commit()
        ) { error in
            guard case .indeterminate = error as? SecureLocalFileError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(renameCount, 1, "no unsafe second pathname swap is permitted")
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "after")
        XCTAssertEqual(try String(contentsOf: recovery, encoding: .utf8), "before")
        let stage = try XCTUnwrap(stageName)
        XCTAssertEqual(
            try String(
                contentsOf: directory.appendingPathComponent(stage), encoding: .utf8),
            "bystander")
    }

    func testInitialStageInspectionFailureNeverLabelsAReusedNameAsRecovery() throws {
        var calls = SecureFileSyscalls.live
        let liveCreate = calls.createAt
        let liveFstat = calls.fstat
        var stageDescriptor: Int32 = -1
        var stageParentDescriptor: Int32 = -1
        var stageName: String?
        var injected = false
        calls.createAt = { parent, name, flags, mode in
            let result = liveCreate(parent, name, flags, mode)
            if result >= 0, String(cString: name).hasPrefix(".markdev-stage-") {
                stageDescriptor = result
                stageParentDescriptor = parent
                stageName = String(cString: name)
            }
            return result
        }
        calls.fstat = { descriptor, status in
            guard descriptor == stageDescriptor, !injected, let stageName else {
                return liveFstat(descriptor, status)
            }
            injected = true
            let removed = stageName.withCString {
                Darwin.unlinkat(stageParentDescriptor, $0, 0)
            }
            XCTAssertEqual(removed, 0)
            do {
                try Data("bystander".utf8).write(
                    to: self.directory.appendingPathComponent(stageName))
            } catch {
                XCTFail("could not create reused stage name: \(error)")
            }
            errno = EIO
            return -1
        }
        let guarded = try handle(calls)

        XCTAssertThrowsError(
            try guarded.transaction(
                component: FileComponent("Note.md"),
                data: Data("after".utf8),
                expectation: .missing,
                policy: .privateStorage
            ).commit()
        ) { error in
            guard case let .prepublicationFailure(cause, receipt) =
                error as? SecureLocalFileError
            else { return XCTFail("unexpected error: \(error)") }
            XCTAssertEqual(cause, .operation(.inspect, errno: EIO))
            XCTAssertNil(receipt.recoveryComponent)
        }
        let name = try XCTUnwrap(stageName)
        XCTAssertEqual(
            try String(
                contentsOf: directory.appendingPathComponent(name), encoding: .utf8),
            "bystander")
    }

    func testPrepublicationFailureRetainsExactStageAuthority() throws {
        var calls = SecureFileSyscalls.live
        calls.write = { _, _, _ in
            errno = EIO
            return -1
        }
        let guarded = try handle(calls)

        XCTAssertThrowsError(
            try guarded.transaction(
                component: FileComponent("Failure.md"),
                data: Data("after".utf8),
                expectation: .missing,
                policy: .privateStorage
            ).commit()
        ) { error in
            guard case let .prepublicationFailure(cause, receipt) =
                error as? SecureLocalFileError
            else { return XCTFail("unexpected error: \(error)") }
            XCTAssertEqual(cause, .operation(.write, errno: EIO))
            XCTAssertEqual(receipt.durability, .notPublishedRecoveryRetained)
            let recovery = try? XCTUnwrap(receipt.recovery)
            XCTAssertNotNil(recovery)
            if let recovery {
                XCTAssertEqual(
                    try? guarded.version(of: recovery.component),
                    recovery.version)
            }
        }
        XCTAssertEqual(try names().filter { $0.hasPrefix(".markdev-stage-") }.count, 1)
    }

    func testZeroWriteAndENOSPCKeepDestinationMissingAndRetainExactStages() throws {
        for injected: (Int, Int32) in [(0, EIO), (-1, ENOSPC)] {
            let retainedBefore = try names().filter { $0.hasPrefix(".markdev-stage-") }.count
            var calls = SecureFileSyscalls.live
            calls.write = { _, _, _ in
                errno = injected.1
                return injected.0
            }
            let handle = try handle(calls)
            let name = "Failure-\(injected.1).bin"

            XCTAssertThrowsError(
                try handle.transaction(
                    component: FileComponent(name),
                    data: Data("payload".utf8),
                    expectation: .missing,
                    policy: .privateStorage
                ).commit()
            ) { error in
                XCTAssertNotNil(self.retainedPrepublicationReceipt(
                    from: error,
                    cause: .operation(.write, errno: injected.1)))
            }
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(name).path))
            XCTAssertEqual(
                try names().filter { $0.hasPrefix(".markdev-stage-") }.count,
                retainedBefore + 1)
        }
    }

    func testFileSyncFailureLeavesOriginalUntouched() throws {
        let destination = directory.appendingPathComponent("Note.md")
        try Data("before".utf8).write(to: destination)
        let baseline = try handle()
        let expected = try baseline.version(of: FileComponent("Note.md"))
        var calls = SecureFileSyscalls.live
        calls.fsync = { _ in
            errno = EIO
            return -1
        }
        let guarded = try handle(calls)

        XCTAssertThrowsError(
            try guarded.transaction(
                component: FileComponent("Note.md"),
                data: Data("after".utf8),
                expectation: .exact(expected),
                policy: .userContent
            ).commit()
        ) { error in
            XCTAssertNotNil(self.retainedPrepublicationReceipt(
                from: error,
                cause: .operation(.syncFile, errno: EIO)))
        }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "before")
        XCTAssertEqual(try names().filter { $0.hasPrefix(".markdev-stage-") }.count, 1)
    }

    func testInterruptedDirectorySyncStopsAtEightAndReportsCommittedButUnconfirmed() throws {
        var calls = SecureFileSyscalls.live
        let directoryDescriptorBox = LockedDescriptor()
        let liveFsync = calls.fsync
        var attempts = 0
        calls.fsync = { descriptor in
            if descriptor == directoryDescriptorBox.value {
                attempts += 1
                errno = EINTR
                return -1
            }
            return liveFsync(descriptor)
        }
        let handle = try handle(calls)
        directoryDescriptorBox.value = handle.descriptor

        let receipt = try handle.transaction(
            component: FileComponent("Note.md"),
            data: Data("saved".utf8),
            expectation: .missing,
            policy: .privateStorage
        ).commit()

        XCTAssertEqual(attempts, 8)
        XCTAssertEqual(receipt.durability, .committedDirectorySyncUnconfirmed(errno: EINTR))
        XCTAssertEqual(
            try String(contentsOf: directory.appendingPathComponent("Note.md"), encoding: .utf8),
            "saved")
    }

    func testCancellationBeforeStagingLeavesOriginalUntouched() throws {
        let destination = directory.appendingPathComponent("Note.md")
        try Data("before".utf8).write(to: destination)
        let handle = try handle()
        let expected = try handle.version(of: FileComponent("Note.md"))

        var transaction = handle.transaction(
            component: try FileComponent("Note.md"),
            data: Data("after".utf8),
            expectation: .exact(expected),
            policy: .userContent)
        transaction.cancellationCheck = { true }

        XCTAssertThrowsError(try transaction.commit()) {
            XCTAssertEqual($0 as? SecureLocalFileError, .cancelled)
        }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "before")
        XCTAssertEqual(try names(), ["Note.md"])
    }

    func testCancellationDuringRepeatedShortWritesRetainsExactIncompleteStage() throws {
        var calls = SecureFileSyscalls.live
        let liveWrite = calls.write
        let writeCalls = SecureIOLockedValue(0)
        calls.write = { descriptor, bytes, count in
            writeCalls.mutate { $0 += 1 }
            return liveWrite(descriptor, bytes, min(1, count))
        }
        let guarded = try handle(calls)
        var transaction = guarded.transaction(
            component: try FileComponent("Cancelled.bin"),
            data: Data(repeating: 0x41, count: 128),
            expectation: .missing,
            policy: .privateStorage)
        transaction.cancellationCheck = {
            writeCalls.value >= 3
        }

        var retained: FileRecoveryAuthority?
        XCTAssertThrowsError(try transaction.commit()) { error in
            guard case let .prepublicationFailure(cause, receipt) =
                error as? SecureLocalFileError
            else { return XCTFail("unexpected error: \(error)") }
            XCTAssertEqual(cause, .cancelled)
            XCTAssertEqual(receipt.durability, .notPublishedRecoveryRetained)
            retained = receipt.recovery
        }
        XCTAssertEqual(writeCalls.value, 3)
        XCTAssertEqual(try names().filter { $0.hasPrefix(".markdev-stage-") }.count, 1)
        let retainedURL = directory.appendingPathComponent(
            try XCTUnwrap(retained).component.rawValue)
        var status = stat()
        XCTAssertEqual(lstat(retainedURL.path, &status), 0)
        XCTAssertEqual(status.st_flags & UInt32(UF_IMMUTABLE), 0)
    }

    func testCancellationDuringStageHashRetainsExactCompleteStageBeforePublish() throws {
        var calls = SecureFileSyscalls.live
        let liveRead = calls.read
        let stageReadCalls = SecureIOLockedValue(0)
        calls.read = { descriptor, bytes, count in
            let result = liveRead(descriptor, bytes, count)
            if result > 0 { stageReadCalls.mutate { $0 += 1 } }
            return result
        }
        let guarded = try handle(calls)
        var transaction = guarded.transaction(
            component: try FileComponent("Cancelled.bin"),
            data: Data(repeating: 0x42, count: 128 * 1_024),
            expectation: .missing,
            policy: .privateStorage)
        transaction.cancellationCheck = { stageReadCalls.value >= 1 }

        var retained: FileRecoveryAuthority?
        XCTAssertThrowsError(try transaction.commit()) { error in
            guard case let .prepublicationFailure(cause, receipt) =
                error as? SecureLocalFileError
            else { return XCTFail("unexpected error: \(error)") }
            XCTAssertEqual(cause, .cancelled)
            XCTAssertEqual(receipt.durability, .notPublishedRecoveryRetained)
            retained = receipt.recovery
        }
        XCTAssertGreaterThanOrEqual(stageReadCalls.value, 1)
        let recovery = try XCTUnwrap(retained)
        XCTAssertEqual(try guarded.version(of: recovery.component), recovery.version)
        let stages = try names().filter { $0.hasPrefix(".markdev-stage-") }
        XCTAssertEqual(stages.count, 1)
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent(stages[0])),
            Data(repeating: 0x42, count: 128 * 1_024))
    }

    func testReplacingUserContentPreservesModeAndExtendedAttribute() throws {
        let destination = directory.appendingPathComponent("Script.md")
        try Data("before".utf8).write(to: destination)
        XCTAssertEqual(chmod(destination.path, 0o640), 0)
        let attribute = "com.markdev.tests.metadata"
        let value = Data("tag".utf8)
        let setResult = value.withUnsafeBytes { raw in
            setxattr(destination.path, attribute, raw.baseAddress, raw.count, 0, 0)
        }
        XCTAssertEqual(setResult, 0)
        let handle = try handle()
        let expected = try handle.version(of: FileComponent("Script.md"))

        _ = try handle.transaction(
            component: FileComponent("Script.md"),
            data: Data("after".utf8),
            expectation: .exact(expected),
            policy: .userContent
        ).commit()

        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o640)
        var buffer = [UInt8](repeating: 0, count: 16)
        let read = buffer.withUnsafeMutableBytes { raw in
            getxattr(destination.path, attribute, raw.baseAddress, raw.count, 0, 0)
        }
        XCTAssertEqual(read, value.count)
        guard read >= 0 else { return }
        XCTAssertEqual(Data(buffer.prefix(read)), value)
    }

    func testReplacingUserContentPreservesSafeUserFlags() throws {
        let destination = directory.appendingPathComponent("Hidden.md")
        try Data("before".utf8).write(to: destination)
        let safeFlags = UInt32(UF_NODUMP | UF_HIDDEN)
        XCTAssertEqual(chflags(destination.path, safeFlags), 0)
        defer { _ = chflags(destination.path, 0) }
        let guarded = try handle()
        let expected = try guarded.version(of: FileComponent("Hidden.md"))

        let receipt = try guarded.transaction(
            component: FileComponent("Hidden.md"),
            data: Data("after".utf8),
            expectation: .exact(expected),
            policy: .userContent
        ).commit()

        var status = stat()
        XCTAssertEqual(lstat(destination.path, &status), 0)
        XCTAssertEqual(receipt.durability, .recoveryRetained(directorySyncErrno: nil))
        XCTAssertNotNil(receipt.recovery)
        XCTAssertEqual(status.st_flags, safeFlags)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "after")
        XCTAssertEqual(try names().filter { $0.hasPrefix(".markdev-stage-") }.count, 1)
    }

    func testUnsupportedModeAndFileFlagsAreRefusedBeforeStaging() throws {
        let modeDestination = directory.appendingPathComponent("SetID.md")
        try Data("before".utf8).write(to: modeDestination)
        XCTAssertEqual(chmod(modeDestination.path, 0o4700), 0)
        defer { _ = chmod(modeDestination.path, 0o600) }
        let modeHandle = try handle()
        let modeVersion = try modeHandle.version(of: FileComponent("SetID.md"))
        XCTAssertThrowsError(
            try modeHandle.transaction(
                component: FileComponent("SetID.md"),
                data: Data("after".utf8),
                expectation: .exact(modeVersion),
                policy: .userContent
            ).commit()
        ) { error in
            guard case .unsupportedFileMode(let bits) = error as? SecureLocalFileError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertNotEqual(bits & mode_t(S_ISUID), 0)
        }

        for unsupported in [
            UInt32(UF_TRACKED),
            UInt32(UF_DATAVAULT),
            UInt32(SF_RESTRICTED),
            UInt32(SF_DATALESS),
            UInt32(0x0000_0100),
        ] {
            let flagDestination = directory.appendingPathComponent("Flag-\(unsupported).md")
            try Data("before".utf8).write(to: flagDestination)
            var calls = SecureFileSyscalls.live
            let liveFstat = calls.fstat
            calls.fstat = { descriptor, status in
                let result = liveFstat(descriptor, status)
                if result == 0, status.pointee.st_mode & S_IFMT == S_IFREG {
                    status.pointee.st_flags |= unsupported
                }
                return result
            }
            let guarded = try handle(calls)
            let component = try FileComponent(flagDestination.lastPathComponent)
            let version = try guarded.version(of: component)
            XCTAssertThrowsError(
                try guarded.transaction(
                    component: component,
                    data: Data("after".utf8),
                    expectation: .exact(version),
                    policy: .userContent
                ).commit()
            ) { error in
                XCTAssertEqual(
                    error as? SecureLocalFileError,
                    .unsupportedFileFlags(unsupported))
            }
            XCTAssertEqual(try String(contentsOf: flagDestination, encoding: .utf8), "before")
        }
        XCTAssertFalse(try names().contains { $0.hasPrefix(".markdev-stage-") })
    }

    func testMetadataSyscallSuccessWithoutApplyingFlagsIsRefusedBeforePublish() throws {
        let destination = directory.appendingPathComponent("Hidden.md")
        try Data("before".utf8).write(to: destination)
        XCTAssertEqual(chflags(destination.path, UInt32(UF_HIDDEN)), 0)
        defer { _ = chflags(destination.path, 0) }
        let expected = try handle().version(of: FileComponent("Hidden.md"))
        var calls = SecureFileSyscalls.live
        calls.fchflags = { _, _ in 0 }
        let guarded = try handle(calls)

        var retained: FileTransactionReceipt?
        XCTAssertThrowsError(
            try guarded.transaction(
                component: FileComponent("Hidden.md"),
                data: Data("after".utf8),
                expectation: .exact(expected),
                policy: .userContent
            ).commit()
        ) { error in
            retained = self.retainedPrepublicationReceipt(
                from: error,
                cause: .expectationMismatch)
        }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "before")
        XCTAssertNotNil(retained?.recovery)
        XCTAssertEqual(try names().filter { $0.hasPrefix(".markdev-stage-") }.count, 1)
    }

    func testPrivateStorageStripsInjectedStageExtendedAttribute() throws {
        let attribute = "com.markdev.private-test"
        let value = Data("private".utf8)
        var calls = SecureFileSyscalls.live
        let liveCreate = calls.createAt
        calls.createAt = { descriptor, name, flags, mode in
            let result = liveCreate(descriptor, name, flags, mode)
            guard result >= 0 else { return result }
            let setResult = value.withUnsafeBytes { bytes in
                fsetxattr(result, attribute, bytes.baseAddress, bytes.count, 0, 0)
            }
            XCTAssertEqual(setResult, 0)
            return result
        }
        let guarded = try handle(calls)
        let destination = directory.appendingPathComponent("Draft.bin")

        _ = try guarded.transaction(
            component: FileComponent("Draft.bin"),
            data: Data("saved".utf8),
            expectation: .missing,
            policy: .privateStorage
        ).commit()

        errno = 0
        XCTAssertEqual(getxattr(destination.path, attribute, nil, 0, 0, 0), -1)
        XCTAssertEqual(errno, ENOATTR)
        XCTAssertTrue(
            try extendedAttributeNames(at: destination).isSubset(of: ["com.apple.provenance"]))
    }
}

/// Syscall hooks and cancellation probes are independently sendable. This
/// box makes the test's shared counters and flags obey the same rule rather
/// than relying on mutable closure captures that become errors in Swift 6.
private final class SecureIOLockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }

    @discardableResult
    func mutate<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&storage)
    }
}

private final class LockedDescriptor: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Int32 = -1

    var value: Int32 {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}
