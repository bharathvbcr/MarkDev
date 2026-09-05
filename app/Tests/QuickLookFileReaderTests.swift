//
//  QuickLookFileReaderTests.swift
//  MarkDevKitTests
//

import Darwin
import Dispatch
import XCTest

private final class BlockedQuickLookRead: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSignal = DispatchSemaphore(value: 0)
    private var started = false
    private var observedCancellation = false

    let value: String

    init(value: String) {
        self.value = value
    }

    /// Deliberately returns a value after cancellation. The coordinator must
    /// both propagate cancellation to this worker and refuse its stale value;
    /// relying on the operation to throw would leave the commit gate untested.
    func readIgnoringCancellationUntilReleased() -> String {
        lock.lock()
        started = true
        lock.unlock()

        let deadline = DispatchTime.now() + .seconds(5)
        while releaseSignal.wait(timeout: .now() + .milliseconds(1)) == .timedOut {
            if Task.isCancelled {
                lock.lock()
                observedCancellation = true
                lock.unlock()
            }
            if DispatchTime.now() >= deadline { break }
        }

        if Task.isCancelled {
            lock.lock()
            observedCancellation = true
            lock.unlock()
        }
        return value
    }

    func release() {
        releaseSignal.signal()
    }

    var didStart: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    var didObserveCancellation: Bool {
        lock.lock()
        defer { lock.unlock() }
        return observedCancellation
    }
}

@MainActor
private final class QuickLookCommitRecorder {
    private(set) var values: [String] = []
    private(set) var urls: [URL] = []

    func record(_ value: String, for url: URL) {
        values.append(value)
        urls.append(url)
    }
}

final class QuickLookFileReaderTests: XCTestCase {
    private var directory: URL!

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    override func setUpWithError() throws {
        // Foundation's `resolvingSymlinksInPath()` preserves the `/var`
        // compatibility alias on macOS. Resolve the existing temporary root
        // with realpath(3), so O_NOFOLLOW_ANY is testing only fixture paths.
        let temporaryPath = FileManager.default.temporaryDirectory.path
        let canonicalPath = try XCTUnwrap(
            temporaryPath.withCString { path -> String? in
                guard let resolved = Darwin.realpath(path, nil) else { return nil }
                defer { Darwin.free(resolved) }
                return String(cString: resolved)
            },
            "realpath failed for \(temporaryPath): \(String(cString: strerror(errno)))"
        )
        directory = URL(fileURLWithPath: canonicalPath, isDirectory: true)
            .appendingPathComponent("MarkDevQuickLookRead-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testExactLimitIsAcceptedAndLimitPlusOneIsRefused() throws {
        let exact = directory.appendingPathComponent("Exact.md")
        let oversized = directory.appendingPathComponent("Oversized.md")
        try Data("12345678".utf8).write(to: exact)
        try Data("123456789".utf8).write(to: oversized)

        XCTAssertEqual(
            try QuickLookFileReader.read(exact, maximumBytes: 8),
            Data("12345678".utf8))
        XCTAssertThrowsError(try QuickLookFileReader.read(oversized, maximumBytes: 8)) {
            XCTAssertEqual($0 as? QuickLookReadError, .tooLarge(maximumBytes: 8))
        }
    }

    func testZeroLimitDistinguishesEmptyFromOneByte() throws {
        let empty = directory.appendingPathComponent("Empty.md")
        let nonempty = directory.appendingPathComponent("Nonempty.md")
        try Data().write(to: empty)
        try Data([0x61]).write(to: nonempty)

        XCTAssertEqual(try QuickLookFileReader.read(empty, maximumBytes: 0), Data())
        XCTAssertThrowsError(try QuickLookFileReader.read(nonempty, maximumBytes: 0)) {
            XCTAssertEqual($0 as? QuickLookReadError, .tooLarge(maximumBytes: 0))
        }
    }

    func testLeafAndIntermediateSymlinksAreRefused() throws {
        let target = directory.appendingPathComponent("Target.md")
        let leaf = directory.appendingPathComponent("Leaf.md")
        let realFolder = directory.appendingPathComponent("Real", isDirectory: true)
        let folderAlias = directory.appendingPathComponent("Alias", isDirectory: true)
        try Data("private".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: leaf, withDestinationURL: target)
        try FileManager.default.createDirectory(at: realFolder, withIntermediateDirectories: false)
        let nested = realFolder.appendingPathComponent("Nested.md")
        try Data("nested".utf8).write(to: nested)
        try FileManager.default.createSymbolicLink(at: folderAlias, withDestinationURL: realFolder)

        XCTAssertThrowsError(try QuickLookFileReader.read(leaf, maximumBytes: 64)) {
            XCTAssertEqual($0 as? QuickLookReadError, .systemCall(code: ELOOP))
        }
        XCTAssertThrowsError(
            try QuickLookFileReader.read(
                folderAlias.appendingPathComponent("Nested.md"), maximumBytes: 64)
        ) {
            XCTAssertEqual($0 as? QuickLookReadError, .systemCall(code: ELOOP))
        }
    }

    func testFIFOAndDirectoryAreRefusedWithoutReading() throws {
        let fifo = directory.appendingPathComponent("Pipe.md")
        XCTAssertEqual(fifo.path.withCString { Darwin.mkfifo($0, 0o600) }, 0)

        XCTAssertThrowsError(try QuickLookFileReader.read(fifo, maximumBytes: 64)) {
            XCTAssertEqual($0 as? QuickLookReadError, .notRegularFile)
        }
        XCTAssertThrowsError(try QuickLookFileReader.read(directory, maximumBytes: 64)) {
            XCTAssertEqual($0 as? QuickLookReadError, .notRegularFile)
        }
    }

    func testInvalidLimitsFailBeforeOpeningThePath() {
        let absent = directory.appendingPathComponent("Absent.md")

        XCTAssertThrowsError(try QuickLookFileReader.read(absent, maximumBytes: -1)) {
            XCTAssertEqual($0 as? QuickLookReadError, .invalidLimit)
        }
        XCTAssertThrowsError(try QuickLookFileReader.read(absent, maximumBytes: Int.max)) {
            XCTAssertEqual($0 as? QuickLookReadError, .invalidLimit)
        }
    }

    func testNonFileURLCannotBeReinterpretedAsALocalPath() throws {
        let remote = try XCTUnwrap(URL(string: "https://example.test/Note.md"))

        XCTAssertThrowsError(try QuickLookFileReader.read(remote, maximumBytes: 64)) {
            XCTAssertEqual($0 as? QuickLookReadError, .notRegularFile)
        }
    }

    /// Quick Look has no in-app Support window, so a categorical OSLog entry
    /// is the only operational trace of a refused preview. It must never log
    /// the requested path or an arbitrary dependency error description.
    func testPreviewFailureLoggingUsesOnlyAClosedPrivacySafeCode() throws {
        let source = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("app/MarkDevQuickLook/PreviewViewController.swift"),
            encoding: .utf8)

        XCTAssertTrue(source.contains("import OSLog"))
        XCTAssertTrue(source.contains("QuickLookDiagnostics.failureCode"))
        XCTAssertTrue(source.contains("privacy: .public"))
        XCTAssertFalse(source.contains("localizedDescription"))
        XCTAssertFalse(source.contains("url.path"))

        let cancellation = try XCTUnwrap(source.range(of: "catch is CancellationError"))
        let failure = try XCTUnwrap(
            source.range(of: "let code = QuickLookDiagnostics.failureCode"))
        XCTAssertLessThan(cancellation.lowerBound, failure.lowerBound)
        XCTAssertFalse(
            source[cancellation.lowerBound..<failure.lowerBound].contains("logger."),
            "normal cancellation must not be emitted as an operational failure")
    }

    func testDiagnosticFailureCodesAreClosedAndDoNotExposeAssociatedValues() {
        XCTAssertEqual(
            QuickLookDiagnostics.failureCode(for: QuickLookReadError.invalidLimit),
            .invalidLimit)
        XCTAssertEqual(
            QuickLookDiagnostics.failureCode(for: QuickLookReadError.notRegularFile),
            .notRegularFile)
        XCTAssertEqual(
            QuickLookDiagnostics.failureCode(
                for: QuickLookReadError.tooLarge(maximumBytes: 123_456)),
            .tooLarge)
        XCTAssertEqual(
            QuickLookDiagnostics.failureCode(for: QuickLookReadError.changedDuringRead),
            .changedDuringRead)
        XCTAssertEqual(
            QuickLookDiagnostics.failureCode(for: QuickLookReadError.systemCall(code: EACCES)),
            .systemCall)

        let published = QuickLookDiagnostics.failureCode(
            for: QuickLookReadError.systemCall(code: EACCES)).rawValue
        XCTAssertFalse(published.contains(String(EACCES)))
        XCTAssertFalse(published.contains("permission"))
    }

    func testDiagnosticFailureCodesDistinguishCancellationAndUnknownErrors() {
        struct DependencyFailure: Error {}

        XCTAssertEqual(
            QuickLookDiagnostics.failureCode(for: CancellationError()),
            .cancelled)
        XCTAssertEqual(
            QuickLookDiagnostics.failureCode(for: DependencyFailure()),
            .unexpected)
    }

    /// Positive control for the cancellation tests: the coordinator must not
    /// satisfy stale-publication assertions by declining every commit.
    @MainActor
    func testPreviewCoordinatorCommitsACompletedRequestOnceWithItsExactURL() async throws {
        let coordinator = QuickLookPreviewCoordinator<String>()
        let recorder = QuickLookCommitRecorder()
        let url = URL(fileURLWithPath: "/tmp/current.md")

        let request = coordinator.start(
            url: url,
            operation: { "current" },
            commit: { value, committedURL in
                recorder.record(value, for: committedURL)
            })
        try await request.value()

        XCTAssertEqual(request.url, url)
        XCTAssertGreaterThan(request.generation, 0)
        XCTAssertEqual(recorder.values, ["current"])
        XCTAssertEqual(recorder.urls, [url])
    }

    /// Cancelling the caller waiting for a preview must cancel the retained
    /// detached worker. The hostile worker still returns a value afterwards,
    /// proving that a second, post-await gate prevents stale publication.
    @MainActor
    func testCallerCancellationPropagatesToWorkerAndRefusesItsLateValue() async {
        let coordinator = QuickLookPreviewCoordinator<String>()
        let recorder = QuickLookCommitRecorder()
        let read = BlockedQuickLookRead(value: "stale")
        defer { read.release() }

        let request = coordinator.start(
            url: URL(fileURLWithPath: "/tmp/cancelled.md"),
            operation: { read.readIgnoringCancellationUntilReleased() },
            commit: { value, url in recorder.record(value, for: url) })
        let waiter = Task { try await request.value() }

        let didStart = await waitForQuickLookCondition { read.didStart }
        XCTAssertTrue(didStart)
        waiter.cancel()
        let didCancelWorker = await waitForQuickLookCondition {
            read.didObserveCancellation
        }
        XCTAssertTrue(
            didCancelWorker,
            "cancelling the caller never reached the detached worker")
        read.release()

        await assertQuickLookCancellation(waiter)
        XCTAssertTrue(recorder.values.isEmpty, "cancelled content reached the preview commit")
        XCTAssertTrue(recorder.urls.isEmpty)
    }

    /// B is allowed to finish while cancellation-uncooperative A is still
    /// running. A then returns last; neither URL identity nor an older request
    /// generation may authorize it to overwrite B.
    @MainActor
    func testNewRequestCancelsOldWorkerAndLateOldResultCannotOverwriteNewPreview() async throws {
        let coordinator = QuickLookPreviewCoordinator<String>()
        let recorder = QuickLookCommitRecorder()
        let firstURL = URL(fileURLWithPath: "/tmp/first.md")
        let secondURL = URL(fileURLWithPath: "/tmp/second.md")
        let firstRead = BlockedQuickLookRead(value: "first-late")
        defer { firstRead.release() }

        let first = coordinator.start(
            url: firstURL,
            operation: { firstRead.readIgnoringCancellationUntilReleased() },
            commit: { value, url in recorder.record(value, for: url) })
        let firstDidStart = await waitForQuickLookCondition { firstRead.didStart }
        XCTAssertTrue(firstDidStart)

        let second = coordinator.start(
            url: secondURL,
            operation: { "second-current" },
            commit: { value, url in recorder.record(value, for: url) })
        XCTAssertEqual(first.url, firstURL)
        XCTAssertEqual(second.url, secondURL)
        XCTAssertGreaterThan(second.generation, first.generation)
        let firstDidCancel = await waitForQuickLookCondition {
            firstRead.didObserveCancellation
        }
        XCTAssertTrue(
            firstDidCancel,
            "superseding B did not cancel A")

        try await second.value()
        XCTAssertEqual(recorder.values, ["second-current"])
        XCTAssertEqual(recorder.urls, [secondURL])

        firstRead.release()
        await assertQuickLookCancellation(first)
        XCTAssertEqual(
            recorder.values,
            ["second-current"],
            "A finished last and overwrote B despite its stale generation")
        XCTAssertEqual(recorder.urls, [secondURL])
    }

    /// A coordinator is the lifetime owner of its detached read. Releasing the
    /// owner must cancel that work even if nobody explicitly cancels a waiter.
    @MainActor
    func testPreviewCoordinatorDeinitCancelsRetainedWorkerAndCannotCommit() async {
        var coordinator: QuickLookPreviewCoordinator<String>? =
            QuickLookPreviewCoordinator<String>()
        weak var releasedCoordinator = coordinator
        let recorder = QuickLookCommitRecorder()
        let read = BlockedQuickLookRead(value: "orphaned")
        defer { read.release() }

        let request = coordinator!.start(
            url: URL(fileURLWithPath: "/tmp/orphaned.md"),
            operation: { read.readIgnoringCancellationUntilReleased() },
            commit: { value, url in recorder.record(value, for: url) })
        let didStart = await waitForQuickLookCondition { read.didStart }
        XCTAssertTrue(didStart)

        coordinator = nil
        XCTAssertNil(releasedCoordinator, "the active request retained its coordinator")
        let didCancelWorker = await waitForQuickLookCondition {
            read.didObserveCancellation
        }
        XCTAssertTrue(
            didCancelWorker,
            "coordinator deinit left its detached worker running")
        read.release()

        await assertQuickLookCancellation(request)
        XCTAssertTrue(recorder.values.isEmpty)
        XCTAssertTrue(recorder.urls.isEmpty)
    }

    /// The controller is not compiled into the unit-test bundle, so pin the
    /// integration seam explicitly: `preview.show` must live in the
    /// coordinator's guarded commit, never after a raw detached-task await.
    func testPreviewControllerRoutesShowThroughGenerationCheckedCoordinator() throws {
        let source = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("app/MarkDevQuickLook/PreviewViewController.swift"),
            encoding: .utf8)

        XCTAssertTrue(source.contains("QuickLookPreviewCoordinator<Data>"))
        XCTAssertTrue(source.contains("commit:"))
        XCTAssertTrue(source.contains("preview.show("))
        XCTAssertTrue(source.contains(".value()"))
        XCTAssertFalse(
            source.contains("Task.detached("),
            "the controller bypassed the retained cancellation/generation boundary")
        let commit = try XCTUnwrap(source.range(of: "commit:"))
        let show = try XCTUnwrap(source.range(of: "preview.show("))
        XCTAssertLessThan(
            commit.lowerBound,
            show.lowerBound,
            "preview.show must execute inside the generation-checked commit closure")
    }
}

private func waitForQuickLookCondition(
    _ condition: @escaping @Sendable () -> Bool
) async -> Bool {
    for _ in 0..<1_000 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}

@MainActor
private func assertQuickLookCancellation<Success: Sendable>(
    _ task: Task<Success, Error>,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await task.value
        XCTFail("expected cancellation", file: file, line: line)
    } catch is CancellationError {
        // Expected.
    } catch {
        XCTFail("expected CancellationError, got \(error)", file: file, line: line)
    }
}

@MainActor
private func assertQuickLookCancellation<Success: Sendable>(
    _ request: QuickLookPreviewRequest<Success>,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await request.value()
        XCTFail("expected cancellation", file: file, line: line)
    } catch is CancellationError {
        // Expected.
    } catch {
        XCTFail("expected CancellationError, got \(error)", file: file, line: line)
    }
}
