//
//  BoundedRegularFileReaderTests.swift
//  MarkDevKitTests
//

import Darwin
import XCTest

private final class BoundedReadMutationTrigger: @unchecked Sendable {
    private let lock = NSLock()
    private var polls = 0
    private var mutated = false

    func check(file: URL, replacement: Data) -> Bool {
        lock.lock()
        polls += 1
        let shouldMutate = polls == 3
        if shouldMutate { mutated = true }
        lock.unlock()
        if shouldMutate { try? replacement.write(to: file) }
        return false
    }

    var didMutate: Bool {
        lock.lock()
        defer { lock.unlock() }
        return mutated
    }
}

private final class PermanentlyInterruptedCall: @unchecked Sendable {
    private let lock = NSLock()
    private let emergencyTripwire: Int
    private var calls = 0

    init(emergencyTripwire: Int) {
        self.emergencyTripwire = emergencyTripwire
    }

    /// Models a syscall that never makes progress. The EIO sentinel keeps a
    /// missing retry bound from hanging the entire test process.
    func call() -> Int {
        lock.lock()
        calls += 1
        let shouldTrip = calls >= emergencyTripwire
        lock.unlock()

        errno = shouldTrip ? EIO : EINTR
        return -1
    }

    func callInt32() -> Int32 { Int32(call()) }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    var cancellationRequested: Bool { callCount > 0 }
}

private final class InterruptedCallSchedule: @unchecked Sendable {
    private let lock = NSLock()
    private let callsToInterrupt: Set<Int>
    private var calls = 0
    private var interrupted = false

    init(_ callsToInterrupt: Set<Int>) {
        self.callsToInterrupt = callsToInterrupt
    }

    func shouldInterrupt() -> Bool {
        lock.lock()
        calls += 1
        let shouldInterrupt = callsToInterrupt.contains(calls)
        interrupted = interrupted || shouldInterrupt
        lock.unlock()

        if shouldInterrupt { errno = EINTR }
        return shouldInterrupt
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    var didInterrupt: Bool {
        lock.lock()
        defer { lock.unlock() }
        return interrupted
    }
}

private final class PermanentlyInterruptedAfterSuccesses: @unchecked Sendable {
    private let lock = NSLock()
    private let successfulCalls: Int
    private let emergencyTripwire: Int
    private var calls = 0

    init(successfulCalls: Int, emergencyTripwire: Int) {
        self.successfulCalls = successfulCalls
        self.emergencyTripwire = emergencyTripwire
    }

    func shouldInterrupt() -> Bool {
        lock.lock()
        calls += 1
        let shouldInterrupt = calls > successfulCalls
        let shouldTrip = calls >= emergencyTripwire
        lock.unlock()

        guard shouldInterrupt else { return false }
        errno = shouldTrip ? EIO : EINTR
        return true
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

private final class InterruptedThenDeniedPread: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func call() -> Int {
        lock.lock()
        calls += 1
        let attempt = calls
        lock.unlock()

        errno = attempt == 1 ? EINTR : EACCES
        return -1
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

private func restoreExactModificationTime(
    of file: URL,
    to generation: BoundedRegularFileGeneration
) throws {
    let outcome = file.withUnsafeFileSystemRepresentation {
        path -> (result: Int32, failureCode: Int32) in
        guard let path else { return (-1, EINVAL) }
        var times = [
            timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
            timespec(
                tv_sec: Int(generation.modifiedSeconds),
                tv_nsec: Int(generation.modifiedNanoseconds)),
        ]
        let result = times.withUnsafeBufferPointer { buffer in
            Darwin.utimensat(AT_FDCWD, path, buffer.baseAddress, 0)
        }
        return (result, result == 0 ? 0 : errno)
    }
    guard outcome.result == 0 else {
        throw XCTSkip(
            "this filesystem cannot restore an exact nanosecond mtime "
                + "(utimensat errno \(outcome.failureCode))")
    }
}

private func assertOnlyChangeTimeDiffers(
    before: BoundedRegularFileGeneration,
    after: BoundedRegularFileGeneration,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    let stableInvariantsMatch =
        before.device == after.device
        && before.inode == after.inode
        && before.fileGeneration == after.fileGeneration
        && before.birthSeconds == after.birthSeconds
        && before.birthNanoseconds == after.birthNanoseconds
        && before.size == after.size
        && before.linkCount == after.linkCount
        && before.mode == after.mode
        && before.ownerID == after.ownerID
        && before.groupID == after.groupID
        && before.flags == after.flags
    XCTAssertEqual(before.device, after.device, file: file, line: line)
    XCTAssertEqual(before.inode, after.inode, file: file, line: line)
    XCTAssertEqual(before.fileGeneration, after.fileGeneration, file: file, line: line)
    XCTAssertEqual(before.birthSeconds, after.birthSeconds, file: file, line: line)
    XCTAssertEqual(before.birthNanoseconds, after.birthNanoseconds, file: file, line: line)
    XCTAssertEqual(before.size, after.size, file: file, line: line)
    XCTAssertEqual(before.linkCount, after.linkCount, file: file, line: line)
    XCTAssertEqual(before.mode, after.mode, file: file, line: line)
    XCTAssertEqual(before.ownerID, after.ownerID, file: file, line: line)
    XCTAssertEqual(before.groupID, after.groupID, file: file, line: line)
    XCTAssertEqual(before.flags, after.flags, file: file, line: line)
    guard stableInvariantsMatch else { return }

    guard before.modifiedSeconds == after.modifiedSeconds,
        before.modifiedNanoseconds == after.modifiedNanoseconds
    else {
        throw XCTSkip(
            "this filesystem did not restore mtime exactly: "
                + "expected \(before.modifiedSeconds).\(before.modifiedNanoseconds), "
                + "observed \(after.modifiedSeconds).\(after.modifiedNanoseconds)")
    }

    guard before.changedSeconds != after.changedSeconds
        || before.changedNanoseconds != after.changedNanoseconds
    else {
        throw XCTSkip(
            "this filesystem's change-time resolution did not expose the in-place rewrite")
    }
}

final class BoundedRegularFileReaderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        let caches = try XCTUnwrap(
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
        directory = caches.appendingPathComponent(
            "MarkDevBoundedRead-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testOpenRetriesAnInterruptedSyscallAndSucceeds() throws {
        let file = directory.appendingPathComponent("Image.bin")
        let bytes = Data("body".utf8)
        try bytes.write(to: file)
        let interrupted = InterruptedCallSchedule([1])

        let lease = try BoundedRegularFileReader.open(
            file,
            maximumBytes: 1_024,
            openForTesting: { path, flags in
                if interrupted.shouldInterrupt() { return -1 }
                return Darwin.open(path, flags)
            })

        XCTAssertEqual(try lease.read().data, bytes)
        XCTAssertEqual(interrupted.callCount, 2)
    }

    func testEveryFileStatusStageRetriesInterruptionAndSucceeds() throws {
        let file = directory.appendingPathComponent("Image.bin")
        let bytes = Data("body".utf8)
        try bytes.write(to: file)
        // Initial-open fstat, pre-read fstat, and post-read fstat each fail
        // once. Their successful retries shift the stage starts to 1, 3, 5.
        let interrupted = InterruptedCallSchedule([1, 3, 5])

        let lease = try BoundedRegularFileReader.open(
            file,
            maximumBytes: 1_024,
            fileStatusForTesting: { descriptor, status in
                if interrupted.shouldInterrupt() { return -1 }
                return Darwin.fstat(descriptor, status)
            })
        let snapshot = try lease.read()

        XCTAssertEqual(snapshot.data, bytes)
        XCTAssertEqual(interrupted.callCount, 6)
    }

    func testGetPathRetriesAnInterruptedSyscallAndSucceeds() throws {
        let file = directory.appendingPathComponent("Image.bin")
        let bytes = Data("body".utf8)
        try bytes.write(to: file)
        let interrupted = InterruptedCallSchedule([1])

        let lease = try BoundedRegularFileReader.open(
            file,
            maximumBytes: 1_024,
            getPathForTesting: { descriptor, buffer in
                if interrupted.shouldInterrupt() { return -1 }
                return Darwin.fcntl(descriptor, F_GETPATH, buffer)
            })

        XCTAssertEqual(try lease.read().data, bytes)
        XCTAssertEqual(interrupted.callCount, 2)
    }

    func testInterruptedOpenRechecksCancellationBeforeRetrying() throws {
        let file = directory.appendingPathComponent("Image.bin")
        try Data("body".utf8).write(to: file)
        let interrupted = InterruptedCallSchedule([1])

        XCTAssertThrowsError(
            try BoundedRegularFileReader.open(
                file,
                maximumBytes: 1_024,
                cancellationCheck: { interrupted.didInterrupt },
                openForTesting: { path, flags in
                    if interrupted.shouldInterrupt() { return -1 }
                    return Darwin.open(path, flags)
                })
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(interrupted.callCount, 1)
    }

    func testInterruptedGetPathRechecksCancellationBeforeRetrying() throws {
        let file = directory.appendingPathComponent("Image.bin")
        try Data("body".utf8).write(to: file)
        let interrupted = InterruptedCallSchedule([1])

        XCTAssertThrowsError(
            try BoundedRegularFileReader.open(
                file,
                maximumBytes: 1_024,
                cancellationCheck: { interrupted.didInterrupt },
                getPathForTesting: { descriptor, buffer in
                    if interrupted.shouldInterrupt() { return -1 }
                    return Darwin.fcntl(descriptor, F_GETPATH, buffer)
                })
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(interrupted.callCount, 1)
    }

    func testEveryInterruptedFileStatusStageRechecksCancellationBeforeRetrying() throws {
        let file = directory.appendingPathComponent("Image.bin")
        try Data("body".utf8).write(to: file)

        for interruptedStage in 1...3 {
            let interrupted = InterruptedCallSchedule([interruptedStage])

            XCTAssertThrowsError(
                try {
                    let lease = try BoundedRegularFileReader.open(
                        file,
                        maximumBytes: 1_024,
                        cancellationCheck: { interrupted.didInterrupt },
                        fileStatusForTesting: { descriptor, status in
                            if interrupted.shouldInterrupt() { return -1 }
                            return Darwin.fstat(descriptor, status)
                        })
                    _ = try lease.read(cancellationCheck: { interrupted.didInterrupt })
                }()
            ) { error in
                XCTAssertTrue(
                    error is CancellationError,
                    "fstat stage \(interruptedStage) returned \(error)")
            }
            XCTAssertEqual(interrupted.callCount, interruptedStage)
        }
    }

    func testPermanentInterruptedOpenHasAFiniteRetryBoundAndPreservesErrorCode() throws {
        let file = directory.appendingPathComponent("Image.bin")
        try Data("body".utf8).write(to: file)
        let interrupted = PermanentlyInterruptedCall(emergencyTripwire: 257)

        XCTAssertThrowsError(
            try BoundedRegularFileReader.open(
                file,
                maximumBytes: 1_024,
                cancellationCheck: {
                    // Prove the typed failure preserves the exhausted
                    // syscall's code after a probe touches thread errno.
                    errno = EPERM
                    return false
                },
                openForTesting: { _, _ in interrupted.callInt32() })
        ) { error in
            XCTAssertEqual(
                error as? BoundedRegularFileReadError,
                .systemCall(code: EINTR))
        }
        XCTAssertEqual(interrupted.callCount, 9, "the initial open plus eight retries")
    }

    func testPermanentInterruptedGetPathHasAFiniteRetryBoundAndPreservesErrorCode() throws {
        let file = directory.appendingPathComponent("Image.bin")
        try Data("body".utf8).write(to: file)
        let interrupted = PermanentlyInterruptedCall(emergencyTripwire: 257)

        XCTAssertThrowsError(
            try BoundedRegularFileReader.open(
                file,
                maximumBytes: 1_024,
                cancellationCheck: { false },
                getPathForTesting: { _, _ in interrupted.callInt32() })
        ) { error in
            XCTAssertEqual(
                error as? BoundedRegularFileReadError,
                .systemCall(code: EINTR))
        }
        XCTAssertEqual(interrupted.callCount, 9, "the initial fcntl plus eight retries")
    }

    func testEveryPermanentInterruptedFileStatusStageHasAFiniteRetryBound() throws {
        let file = directory.appendingPathComponent("Image.bin")
        try Data("body".utf8).write(to: file)

        for successfulStages in 0...2 {
            let interrupted = PermanentlyInterruptedAfterSuccesses(
                successfulCalls: successfulStages,
                emergencyTripwire: 257)

            XCTAssertThrowsError(
                try {
                    let lease = try BoundedRegularFileReader.open(
                        file,
                        maximumBytes: 1_024,
                        cancellationCheck: { false },
                        fileStatusForTesting: { descriptor, status in
                            if interrupted.shouldInterrupt() { return -1 }
                            return Darwin.fstat(descriptor, status)
                        })
                    _ = try lease.read(cancellationCheck: { false })
                }()
            ) { error in
                XCTAssertEqual(
                    error as? BoundedRegularFileReadError,
                    .systemCall(code: EINTR),
                    "fstat stage \(successfulStages + 1) lost EINTR")
            }
            XCTAssertEqual(
                interrupted.callCount,
                successfulStages + 9,
                "the selected fstat must make one initial attempt and eight retries")
        }
    }

    func testLeaseReadsTheOpenedGenerationAcrossAtomicReplacement() throws {
        let file = directory.appendingPathComponent("Image.bin")
        let replacement = directory.appendingPathComponent("Replacement.bin")
        let oldBytes = Data("old generation".utf8)
        let newBytes = Data("new generation".utf8)
        try oldBytes.write(to: file)

        let lease = try BoundedRegularFileReader.open(file, maximumBytes: 1_024)
        try newBytes.write(to: replacement)
        XCTAssertEqual(Darwin.rename(replacement.path, file.path), 0)

        let opened = try lease.read()
        let current = try BoundedRegularFileReader.read(file, maximumBytes: 1_024)
        XCTAssertEqual(opened.data, oldBytes, "the lease must not reopen the replaced path")
        XCTAssertEqual(current.data, newBytes)
        XCTAssertNotEqual(opened.generation, current.generation)
    }

    func testLeaseRejectsAnInPlaceMutationDuringRead() throws {
        let file = directory.appendingPathComponent("Image.bin")
        try Data(repeating: 0x61, count: 192 * 1_024).write(to: file)
        let lease = try BoundedRegularFileReader.open(file, maximumBytes: 256 * 1_024)
        let trigger = BoundedReadMutationTrigger()
        let replacement = Data(repeating: 0x62, count: 192 * 1_024)

        XCTAssertThrowsError(
            try lease.read(cancellationCheck: {
                trigger.check(file: file, replacement: replacement)
            })
        ) { error in
            XCTAssertEqual(error as? BoundedRegularFileReadError, .changedDuringRead)
        }
        XCTAssertTrue(trigger.didMutate, "the fixture never attacked the active read")
    }

    func testGenerationChangesAfterSameSizeRewriteAndRestoredMTime() throws {
        let file = directory.appendingPathComponent("Image.bin")
        try Data("aaaaaaaa".utf8).write(to: file)
        let before = try BoundedRegularFileReader.open(file, maximumBytes: 1_024)

        try Data("bbbbbbbb".utf8).write(to: file)
        try restoreExactModificationTime(of: file, to: before.generation)
        let after = try BoundedRegularFileReader.open(file, maximumBytes: 1_024)

        try assertOnlyChangeTimeDiffers(
            before: before.generation,
            after: after.generation)
        XCTAssertNotEqual(before.generation, after.generation, "ctime must expose the rewrite")
    }

    func testNonLocalFileAuthorityIsRejectedBeforeOpeningItsPath() throws {
        let file = directory.appendingPathComponent("Image.bin")
        try Data("private".utf8).write(to: file)
        let hostile = try XCTUnwrap(URL(string: "file://attacker.invalid\(file.path)"))

        XCTAssertThrowsError(
            try BoundedRegularFileReader.open(hostile, maximumBytes: 1_024)
        ) { error in
            XCTAssertEqual(error as? BoundedRegularFileReadError, .notFileURL)
        }

        let localhost = try XCTUnwrap(URL(string: "file://localhost\(file.path)"))
        XCTAssertEqual(
            try BoundedRegularFileReader.read(localhost, maximumBytes: 1_024).data,
            Data("private".utf8))
    }

    func testAuthorityValidationRejectsRelativeFileURLsAndAliasReplacementPreservesRefusals()
        throws
    {
        let relative = try XCTUnwrap(URL(string: "file:relative.md"))
        let hostile = try XCTUnwrap(URL(string: "file://remote.example/tmp/private.md"))

        XCTAssertFalse(BoundedRegularFileReader.hasLocalFileAuthority(relative))
        XCTAssertFalse(BoundedRegularFileReader.hasLocalFileAuthority(hostile))
        XCTAssertEqual(
            BoundedRegularFileReader.replacingSystemCompatibilityAlias(in: hostile),
            hostile,
            "a compatibility rewrite must never erase rejected URL authority")
    }

    func testDirectoryMarkedRegularFileIsRejectedBeforeCacheAuthority() throws {
        let file = directory.appendingPathComponent("Image.bin")
        try Data("body".utf8).write(to: file)
        let marked = try XCTUnwrap(URL(string: file.absoluteString + "/"))
        XCTAssertTrue(marked.hasDirectoryPath)

        XCTAssertThrowsError(
            try BoundedRegularFileReader.open(marked, maximumBytes: 1_024)
        ) { error in
            XCTAssertEqual(error as? BoundedRegularFileReadError, .notRegularFile)
        }
    }

    func testInterruptedPreadRechecksCancellationBeforeRetrying() throws {
        let file = directory.appendingPathComponent("Image.bin")
        try Data("body".utf8).write(to: file)
        let lease = try BoundedRegularFileReader.open(file, maximumBytes: 1_024)
        let interrupted = PermanentlyInterruptedCall(emergencyTripwire: 32)

        XCTAssertThrowsError(
            try lease.read(
                cancellationCheck: { interrupted.cancellationRequested },
                preadForTesting: { _, _, _, _ in interrupted.call() })
        ) { error in
            XCTAssertTrue(
                error is CancellationError,
                "cancellation after EINTR must win over another syscall attempt; got \(error)")
        }
        XCTAssertEqual(
            interrupted.callCount,
            1,
            "the reader retried pread without rechecking cancellation")
    }

    func testPreadRetriesOneInterruptionAndReturnsTheCompleteSnapshot() throws {
        let file = directory.appendingPathComponent("Image.bin")
        let bytes = Data("body".utf8)
        try bytes.write(to: file)
        let lease = try BoundedRegularFileReader.open(file, maximumBytes: 1_024)
        let interrupted = InterruptedCallSchedule([1])

        let snapshot = try lease.read(
            cancellationCheck: { false },
            preadForTesting: { descriptor, buffer, byteCount, offset in
                if interrupted.shouldInterrupt() { return -1 }
                return Darwin.pread(descriptor, buffer, byteCount, offset)
            })

        XCTAssertEqual(snapshot.data, bytes)
        XCTAssertEqual(
            interrupted.callCount,
            3,
            "one interrupted attempt, one data read, and one EOF probe are expected")
    }

    func testPreadPreservesTheFailureThatFollowsAnInterruption() throws {
        let file = directory.appendingPathComponent("Image.bin")
        try Data("body".utf8).write(to: file)
        let lease = try BoundedRegularFileReader.open(file, maximumBytes: 1_024)
        let calls = InterruptedThenDeniedPread()

        XCTAssertThrowsError(
            try lease.read(
                cancellationCheck: { false },
                preadForTesting: { _, _, _, _ in calls.call() })
        ) { error in
            XCTAssertEqual(
                error as? BoundedRegularFileReadError,
                .systemCall(code: EACCES),
                "the retry's real failure must replace the transient EINTR")
        }
        XCTAssertEqual(calls.callCount, 2)
    }

    func testPermanentInterruptedPreadHasAFiniteRetryBound() throws {
        let file = directory.appendingPathComponent("Image.bin")
        try Data("body".utf8).write(to: file)
        let lease = try BoundedRegularFileReader.open(file, maximumBytes: 1_024)
        let interrupted = PermanentlyInterruptedCall(emergencyTripwire: 257)

        XCTAssertThrowsError(
            try lease.read(
                cancellationCheck: { false },
                preadForTesting: { _, _, _, _ in interrupted.call() })
        ) { error in
            XCTAssertEqual(
                error as? BoundedRegularFileReadError,
                .systemCall(code: EINTR),
                "a permanently interrupted syscall must fail with its real errno")
        }
        XCTAssertEqual(
            interrupted.callCount,
            9,
            "pread must make one initial attempt and at most eight retries")
    }
}
