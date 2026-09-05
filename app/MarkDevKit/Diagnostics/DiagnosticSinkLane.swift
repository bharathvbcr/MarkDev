//
//  DiagnosticSinkLane.swift
//  MarkDevKit
//
//  Bounded, serial delivery and exact per-sink barrier checkpoints.
//

import Foundation

final class DiagnosticsOneShot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?

    @discardableResult
    func resolve(_ result: Result<Value, Error>) -> Bool {
        let continuation: CheckedContinuation<Value, Error>?

        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return false
        }
        self.result = result
        continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume(with: result)
        return true
    }

    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let resolved: Result<Value, Error>?

            lock.lock()
            resolved = result
            if resolved == nil {
                precondition(self.continuation == nil, "a diagnostics one-shot has one consumer")
                self.continuation = continuation
            }
            lock.unlock()

            if let resolved {
                continuation.resume(with: resolved)
            }
        }
    }

    func successfulValue() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        guard case let .success(value)? = result else { return nil }
        return value
    }
}

fileprivate final class DiagnosticSinkBarrierCheckpoint: @unchecked Sendable {
    private let lock = NSLock()
    private var result: DiagnosticSinkBarrierResult?

    func freeze(_ result: DiagnosticSinkBarrierResult) {
        lock.lock()
        if self.result == nil {
            self.result = result
        }
        lock.unlock()
    }

    func value() -> DiagnosticSinkBarrierResult? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

final class DiagnosticSinkBarrierHandle: @unchecked Sendable {
    let cut: DiagnosticSinkCut

    private let identifier: UUID
    private let lane: DiagnosticSinkLane
    private let promise: DiagnosticsOneShot<DiagnosticSinkBarrierResult>
    private let checkpoint: DiagnosticSinkBarrierCheckpoint

    fileprivate init(
        identifier: UUID,
        cut: DiagnosticSinkCut,
        lane: DiagnosticSinkLane,
        promise: DiagnosticsOneShot<DiagnosticSinkBarrierResult>,
        checkpoint: DiagnosticSinkBarrierCheckpoint
    ) {
        self.identifier = identifier
        self.cut = cut
        self.lane = lane
        self.promise = promise
        self.checkpoint = checkpoint
    }

    func value() async throws -> DiagnosticSinkBarrierResult {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await promise.value()
        } onCancel: {
            self.cancel()
        }
    }

    func currentResult() -> DiagnosticSinkBarrierResult {
        promise.successfulValue() ?? checkpoint.value() ?? lane.currentResult(for: cut)
    }

    func cancel() {
        lane.cancelBarrier(identifier: identifier, promise: promise)
    }
}

final class DiagnosticSinkDeliveryHandle: @unchecked Sendable {
    private let promise: DiagnosticsOneShot<Void>

    init(promise: DiagnosticsOneShot<Void>) {
        self.promise = promise
    }

    func wait() async {
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await promise.value()
            } onCancel: {
                self.promise.resolve(.failure(CancellationError()))
            }
        } catch {
            // A caller cancelling its wait never cancels delivery. Sink errors
            // are accounted by the lane and historically were not thrown from
            // DiagnosticsCenter.record.
        }
    }
}

final class DiagnosticSinkLane: @unchecked Sendable {
    private struct PendingRecord: Sendable {
        let acceptedOrdinal: UInt64
        let record: DiagnosticRecord
        let completion: DiagnosticsOneShot<Void>?
    }

    private struct BarrierWaiter {
        let cut: DiagnosticSinkCut
        let promise: DiagnosticsOneShot<DiagnosticSinkBarrierResult>
        let checkpoint: DiagnosticSinkBarrierCheckpoint
    }

    let id: DiagnosticSinkID

    private let sink: any DiagnosticSink
    private let capacity: Int
    private let maximumBarrierWaiters: Int
    private let lock = NSLock()
    private var buffer: [PendingRecord?]
    private var head = 0
    private var queuedCount = 0
    private var writerIsRunning = false
    private var outstandingCount = 0
    private var maximumOutstandingCount = 0
    private var offeredEventCount: UInt64 = 0
    private var acceptedEventCount: UInt64 = 0
    private var completedAcceptedEventCount: UInt64 = 0
    private var writtenEventCount: UInt64 = 0
    private var failureCount: UInt64 = 0
    private var droppedEventCount: UInt64 = 0
    private var countersSaturated = false
    private var barrierWaiters: [UUID: BarrierWaiter] = [:]

    init(
        registration: DiagnosticSinkRegistration,
        maximumBarrierWaiters: Int
    ) {
        id = registration.id
        sink = registration.sink
        capacity = registration.maximumOutstandingRecords
        self.maximumBarrierWaiters = maximumBarrierWaiters
        buffer = Array(repeating: nil, count: registration.maximumOutstandingRecords)
    }

    func offer(
        _ record: DiagnosticRecord,
        requestingCompletion: Bool = false
    ) -> DiagnosticSinkDeliveryHandle? {
        var shouldStartWriter = false
        let completion = requestingCompletion ? DiagnosticsOneShot<Void>() : nil

        lock.lock()
        offeredEventCount = incremented(offeredEventCount)
        guard capacity > 0,
              outstandingCount < capacity,
              acceptedEventCount < .max
        else {
            droppedEventCount = incremented(droppedEventCount)
            lock.unlock()
            return nil
        }

        acceptedEventCount += 1
        let pending = PendingRecord(
            acceptedOrdinal: acceptedEventCount,
            record: record,
            completion: completion)
        let tail = (head + queuedCount) % capacity
        buffer[tail] = pending
        queuedCount += 1
        outstandingCount += 1
        maximumOutstandingCount = max(maximumOutstandingCount, outstandingCount)
        if !writerIsRunning {
            writerIsRunning = true
            shouldStartWriter = true
        }
        lock.unlock()

        if shouldStartWriter {
            startWriter()
        }
        return completion.map { DiagnosticSinkDeliveryHandle(promise: $0) }
    }

    func healthSnapshot() -> DiagnosticSinkHealth {
        lock.lock()
        defer { lock.unlock() }
        return DiagnosticSinkHealth(
            id: id,
            offeredEventCount: offeredEventCount,
            acceptedEventCount: acceptedEventCount,
            writtenEventCount: writtenEventCount,
            failureCount: failureCount,
            droppedEventCount: droppedEventCount,
            outstandingEventCount: outstandingCount,
            maximumOutstandingEventCount: maximumOutstandingCount,
            countersSaturated: countersSaturated)
    }

    func captureBarrier() throws -> DiagnosticSinkBarrierHandle {
        let identifier = UUID()
        let promise = DiagnosticsOneShot<DiagnosticSinkBarrierResult>()
        let checkpoint = DiagnosticSinkBarrierCheckpoint()
        let cut: DiagnosticSinkCut
        let immediateResult: DiagnosticSinkBarrierResult?

        lock.lock()
        cut = DiagnosticSinkCut(
            id: id,
            offeredEventCount: offeredEventCount,
            acceptedEventCount: acceptedEventCount,
            droppedEventCount: droppedEventCount,
            countersSaturated: countersSaturated)
        if completedAcceptedEventCount >= cut.acceptedEventCount {
            immediateResult = result(for: cut, state: .settled)
        } else if barrierWaiters.count >= maximumBarrierWaiters {
            lock.unlock()
            throw DiagnosticsBarrierError.sinkWaiterLimitExceeded(
                sinkID: id,
                limit: maximumBarrierWaiters)
        } else {
            barrierWaiters[identifier] = BarrierWaiter(
                cut: cut,
                promise: promise,
                checkpoint: checkpoint)
            immediateResult = nil
        }
        lock.unlock()

        let handle = DiagnosticSinkBarrierHandle(
            identifier: identifier,
            cut: cut,
            lane: self,
            promise: promise,
            checkpoint: checkpoint)
        if let immediateResult {
            checkpoint.freeze(immediateResult)
            promise.resolve(.success(immediateResult))
        }
        return handle
    }

    func currentResult(for cut: DiagnosticSinkCut) -> DiagnosticSinkBarrierResult {
        lock.lock()
        defer { lock.unlock() }
        let state: DiagnosticSinkBarrierState = completedAcceptedEventCount >= cut.acceptedEventCount
            ? .settled
            : .pending
        return result(for: cut, state: state)
    }

    func cancelBarrier(
        identifier: UUID,
        promise: DiagnosticsOneShot<DiagnosticSinkBarrierResult>
    ) {
        lock.lock()
        if let waiter = barrierWaiters.removeValue(forKey: identifier) {
            waiter.checkpoint.freeze(result(for: waiter.cut, state: .pending))
        }
        lock.unlock()
        promise.resolve(.failure(CancellationError()))
    }

    var pendingBarrierCountForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return barrierWaiters.count
    }

    private func startWriter() {
        _ = Task.detached(priority: .utility) { [self] in
            await drain()
        }
    }

    private func drain() async {
        while let pending = takeNext() {
            let succeeded: Bool
            do {
                try await sink.write(pending.record)
                succeeded = true
            } catch {
                succeeded = false
            }
            complete(pending, succeeded: succeeded)
        }
    }

    private func takeNext() -> PendingRecord? {
        lock.lock()
        guard queuedCount > 0 else {
            writerIsRunning = false
            lock.unlock()
            return nil
        }

        let pending = buffer[head]
        buffer[head] = nil
        head = (head + 1) % capacity
        queuedCount -= 1
        lock.unlock()
        return pending
    }

    private func complete(_ pending: PendingRecord, succeeded: Bool) {
        var ready: [BarrierWaiter] = []

        lock.lock()
        outstandingCount -= 1
        completedAcceptedEventCount = pending.acceptedOrdinal
        if succeeded {
            writtenEventCount = incremented(writtenEventCount)
        } else {
            failureCount = incremented(failureCount)
        }
        barrierWaiters = barrierWaiters.filter { _, waiter in
            guard waiter.cut.acceptedEventCount <= completedAcceptedEventCount else {
                return true
            }
            ready.append(waiter)
            return false
        }
        lock.unlock()

        for waiter in ready {
            let result = settledResult(for: waiter.cut)
            waiter.checkpoint.freeze(result)
            waiter.promise.resolve(.success(result))
        }
        pending.completion?.resolve(.success(()))
    }

    private func result(
        for cut: DiagnosticSinkCut,
        state: DiagnosticSinkBarrierState
    ) -> DiagnosticSinkBarrierResult {
        let completedThroughCut = min(completedAcceptedEventCount, cut.acceptedEventCount)
        let writtenThroughCut = min(writtenEventCount, completedThroughCut)
        let failureThroughCut = min(
            failureCount,
            completedThroughCut - writtenThroughCut)
        return DiagnosticSinkBarrierResult(
            cut: cut,
            state: state,
            writtenEventCount: writtenThroughCut,
            failureCount: failureThroughCut,
            pendingEventCount: cut.acceptedEventCount - writtenThroughCut - failureThroughCut)
    }

    private func settledResult(for cut: DiagnosticSinkCut) -> DiagnosticSinkBarrierResult {
        lock.lock()
        defer { lock.unlock() }
        return result(for: cut, state: .settled)
    }

    private func incremented(_ value: UInt64) -> UInt64 {
        let (incremented, overflow) = value.addingReportingOverflow(1)
        if overflow {
            countersSaturated = true
            return .max
        }
        return incremented
    }
}

struct CapturedDiagnosticsCut: Sendable {
    let cut: DiagnosticsCut
    let sinkBarriers: [DiagnosticSinkBarrierHandle]

    func cancel() {
        for barrier in sinkBarriers {
            barrier.cancel()
        }
    }
}
