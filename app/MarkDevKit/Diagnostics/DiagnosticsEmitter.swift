//
//  DiagnosticsEmitter.swift
//  MarkDevKit
//
//  A bounded, non-blocking bridge and exact ordering barrier for diagnostics.
//

import Foundation

public struct DiagnosticsEmitterConfiguration: Equatable, Sendable {
    public static let largestSupportedPendingEventLimit = 100_000
    public static let largestSupportedFlushWaiterLimit = 1_024
    public static let largestSupportedDefaultFlushTimeoutNanoseconds: UInt64 = 60_000_000_000

    public let maximumPendingEvents: Int
    public let maximumFlushWaiters: Int
    public let defaultFlushTimeoutNanoseconds: UInt64

    public init(
        maximumPendingEvents: Int = 1_024,
        maximumFlushWaiters: Int = 64,
        defaultFlushTimeoutNanoseconds: UInt64 = 5_000_000_000
    ) {
        self.maximumPendingEvents = min(
            max(0, maximumPendingEvents),
            Self.largestSupportedPendingEventLimit)
        self.maximumFlushWaiters = min(
            max(0, maximumFlushWaiters),
            Self.largestSupportedFlushWaiterLimit)
        self.defaultFlushTimeoutNanoseconds = min(
            max(1, defaultFlushTimeoutNanoseconds),
            Self.largestSupportedDefaultFlushTimeoutNanoseconds)
    }
}

/// Accepts typed diagnostics without making an application operation await a
/// sink. A single worker preserves ingress order; each sink then owns an
/// independent bounded serial lane.
public final class DiagnosticsEmitter: @unchecked Sendable {
    private struct PendingEvent: Sendable {
        let admissionSequence: UInt64
        let severity: DiagnosticSeverity
        let subsystem: DiagnosticSubsystem
        let code: DiagnosticCode
        let operationID: DiagnosticOperationID?
        let metadata: DiagnosticMetadata
    }

    private struct PendingBarrier: Sendable {
        let identifier: UUID
        let acceptedThrough: UInt64
        let droppedThrough: UInt64
        let promise: DiagnosticsOneShot<CapturedDiagnosticsCut>
    }

    private enum Work: Sendable {
        case event(PendingEvent)
        case dropped(UInt64)
        case barrier(PendingBarrier)
    }

    private enum CutRaceResult: Sendable {
        case captured(CapturedDiagnosticsCut)
        case deadline
    }

    private enum SettlementRaceResult: Sendable {
        case sink(DiagnosticSinkBarrierResult)
        case deadline
    }

    public static let shared = DiagnosticsEmitter(center: .shared)

    private let center: DiagnosticsCenter
    private let capacity: Int
    private let maximumFlushWaiters: Int
    private let defaultFlushTimeoutNanoseconds: UInt64
    private let barrierClock: any DiagnosticBarrierClock
    private let lock = NSLock()
    private var buffer: [PendingEvent?]
    private var head = 0
    private var pendingCount = 0
    private var maximumObservedPendingCount = 0
    private var drainIsRunning = false
    private var nextAcceptedSequence: UInt64? = 1
    private var lastAcceptedSequence: UInt64 = 0
    private var completedSequence: UInt64 = 0
    private var totalDropped: UInt64 = 0
    private var accountedDropped: UInt64 = 0
    private var unaccountedDropped: UInt64 = 0
    private var pendingBarriers: [PendingBarrier] = []
    private var activeFlushReservations: Set<UUID> = []

    public init(
        center: DiagnosticsCenter,
        configuration: DiagnosticsEmitterConfiguration = DiagnosticsEmitterConfiguration(),
        barrierClock: any DiagnosticBarrierClock = SystemDiagnosticBarrierClock()
    ) {
        self.center = center
        capacity = configuration.maximumPendingEvents
        maximumFlushWaiters = configuration.maximumFlushWaiters
        defaultFlushTimeoutNanoseconds = configuration.defaultFlushTimeoutNanoseconds
        self.barrierClock = barrierClock
        buffer = Array(repeating: nil, count: configuration.maximumPendingEvents)
    }

    /// Admits one event and returns immediately. A full ingress queue drops the
    /// newest event and accounts for it at the next drain boundary.
    public func emit(
        severity: DiagnosticSeverity,
        subsystem: DiagnosticSubsystem,
        code: DiagnosticCode,
        operationID: DiagnosticOperationID? = nil,
        metadata: DiagnosticMetadata = DiagnosticMetadata()
    ) {
        var shouldStartDrain = false

        lock.lock()
        if pendingCount < capacity, let admissionSequence = nextAcceptedSequence {
            lastAcceptedSequence = admissionSequence
            nextAcceptedSequence = admissionSequence == .max ? nil : admissionSequence + 1
            let event = PendingEvent(
                admissionSequence: admissionSequence,
                severity: severity,
                subsystem: subsystem,
                code: code,
                operationID: operationID,
                metadata: metadata)
            let tail = (head + pendingCount) % capacity
            buffer[tail] = event
            pendingCount += 1
            maximumObservedPendingCount = max(maximumObservedPendingCount, pendingCount)
        } else {
            totalDropped = Self.saturatingIncrement(totalDropped)
            unaccountedDropped = Self.saturatingIncrement(unaccountedDropped)
        }
        if !drainIsRunning {
            drainIsRunning = true
            shouldStartDrain = true
        }
        lock.unlock()

        if shouldStartDrain { startDrain() }
    }

    /// Compatibility boundary for existing fire-and-wait callers. It is finite
    /// and cancellation-aware; callers that must distinguish timeout from full
    /// settlement use `flush(deadline:)`.
    public func flush() async {
        do {
            _ = try await flush(deadline: defaultDeadline())
        } catch {
            // Compatibility callers historically had no error channel. Health
            // and the throwing overload preserve the truthful result.
        }
    }

    /// Captures an immutable snapshot after all ingress preceding this marker
    /// has entered the centre, then waits for each sink's exact admitted token.
    @discardableResult
    public func flush(deadline: DiagnosticDeadline) async throws -> DiagnosticsBarrierReceipt {
        try Task.checkCancellation()
        let reservationID = try reserveFlush()
        defer { releaseFlush(reservationID) }
        let captured = try await captureCut(
            reservationID: reservationID,
            deadline: deadline)
        do {
            return try await settle(captured, deadline: deadline)
        } catch {
            captured.cancel()
            throw error
        }
    }

    public func snapshot() async -> DiagnosticsSnapshot {
        await center.snapshot()
    }

    public func supportReportData(
        metadata: DiagnosticReportMetadata = .current(),
        generatedAtMilliseconds: Int64? = nil
    ) async throws -> Data {
        try await supportReportData(
            deadline: defaultDeadline(),
            metadata: metadata,
            generatedAtMilliseconds: generatedAtMilliseconds)
    }

    public func supportReportData(
        deadline: DiagnosticDeadline,
        metadata: DiagnosticReportMetadata = .current(),
        generatedAtMilliseconds: Int64? = nil
    ) async throws -> Data {
        let reportBarrier = try await reportBarrier(deadline: deadline)
        return try await center.supportReportData(
            from: reportBarrier.receipt,
            deliveryState: reportBarrier.state,
            metadata: metadata,
            generatedAtMilliseconds: generatedAtMilliseconds)
    }

    public func exportSupportReport(
        to destination: URL,
        metadata: DiagnosticReportMetadata = .current(),
        generatedAtMilliseconds: Int64? = nil
    ) async throws -> DiagnosticExportSummary {
        try await exportSupportReport(
            deadline: defaultDeadline(),
            to: destination,
            metadata: metadata,
            generatedAtMilliseconds: generatedAtMilliseconds)
    }

    public func exportSupportReport(
        deadline: DiagnosticDeadline,
        to destination: URL,
        metadata: DiagnosticReportMetadata = .current(),
        generatedAtMilliseconds: Int64? = nil
    ) async throws -> DiagnosticExportSummary {
        let reportBarrier = try await reportBarrier(deadline: deadline)
        return try await center.exportSupportReport(
            from: reportBarrier.receipt,
            deliveryState: reportBarrier.state,
            to: destination,
            metadata: metadata,
            generatedAtMilliseconds: generatedAtMilliseconds)
    }

    func captureCutForTesting(
        deadline: DiagnosticDeadline
    ) async throws -> ReservedCapturedDiagnosticsCut {
        let reservationID = try reserveFlush()
        do {
            let captured = try await captureCut(
                reservationID: reservationID,
                deadline: deadline)
            return ReservedCapturedDiagnosticsCut(
                reservationID: reservationID,
                captured: captured)
        } catch {
            releaseFlush(reservationID)
            throw error
        }
    }

    func settleCutForTesting(
        _ reserved: ReservedCapturedDiagnosticsCut,
        deadline: DiagnosticDeadline
    ) async throws -> DiagnosticsBarrierReceipt {
        defer { releaseFlush(reserved.reservationID) }
        do {
            return try await settle(reserved.captured, deadline: deadline)
        } catch {
            reserved.captured.cancel()
            throw error
        }
    }

    func cancelCutForTesting(_ reserved: ReservedCapturedDiagnosticsCut) {
        reserved.captured.cancel()
        releaseFlush(reserved.reservationID)
    }

    var pendingBarrierCountForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingBarriers.count
    }

    var activeFlushReservationCountForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return activeFlushReservations.count
    }

    var maximumObservedPendingCountForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximumObservedPendingCount
    }

    func admissionStateForTesting() -> (
        lastAcceptedSequence: UInt64,
        nextAcceptedSequence: UInt64?,
        droppedEventCount: UInt64
    ) {
        lock.lock()
        defer { lock.unlock() }
        return (lastAcceptedSequence, nextAcceptedSequence, totalDropped)
    }

    func setNextAdmissionSequenceForTesting(_ sequence: UInt64?) {
        lock.lock()
        defer { lock.unlock() }
        precondition(pendingCount == 0 && pendingBarriers.isEmpty && !drainIsRunning)
        precondition(sequence.map { $0 > 0 } ?? true)
        nextAcceptedSequence = sequence
        lastAcceptedSequence = sequence.map { $0 - 1 } ?? .max
        completedSequence = lastAcceptedSequence
    }

    private func captureCut(
        reservationID: UUID,
        deadline: DiagnosticDeadline
    ) async throws -> CapturedDiagnosticsCut {
        guard deadline.uptimeNanoseconds > barrierClock.uptimeNanoseconds() else {
            throw DiagnosticsBarrierError.deadlineExceeded(partial: nil)
        }
        let barrier = try enqueueBarrier(identifier: reservationID)
        let clock = barrierClock

        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: CutRaceResult.self) { group in
                group.addTask {
                    .captured(try await barrier.promise.value())
                }
                group.addTask {
                    try await clock.sleep(until: deadline)
                    return .deadline
                }
                defer { group.cancelAll() }

                guard let result = try await group.next() else {
                    throw CancellationError()
                }
                switch result {
                case let .captured(cut):
                    return cut
                case .deadline:
                    cancelBarrier(barrier)
                    throw DiagnosticsBarrierError.deadlineExceeded(partial: nil)
                }
            }
        } onCancel: {
            self.cancelBarrier(barrier)
        }
    }

    private func settle(
        _ captured: CapturedDiagnosticsCut,
        deadline: DiagnosticDeadline
    ) async throws -> DiagnosticsBarrierReceipt {
        try Task.checkCancellation()
        guard !captured.sinkBarriers.isEmpty else {
            return DiagnosticsBarrierReceipt(cut: captured.cut, sinks: [])
        }
        guard deadline.uptimeNanoseconds > barrierClock.uptimeNanoseconds() else {
            let partial = DiagnosticsBarrierReceipt(
                cut: captured.cut,
                sinks: captured.sinkBarriers.map { $0.currentResult() })
            captured.cancel()
            throw DiagnosticsBarrierError.deadlineExceeded(partial: partial)
        }

        let clock = barrierClock
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: SettlementRaceResult.self) { group in
                for barrier in captured.sinkBarriers {
                    group.addTask {
                        .sink(try await barrier.value())
                    }
                }
                group.addTask {
                    try await clock.sleep(until: deadline)
                    return .deadline
                }
                defer { group.cancelAll() }

                var settledByID: [DiagnosticSinkID: DiagnosticSinkBarrierResult] = [:]
                while let result = try await group.next() {
                    switch result {
                    case let .sink(settled):
                        settledByID[settled.cut.id] = settled
                        if settledByID.count == captured.sinkBarriers.count {
                            return DiagnosticsBarrierReceipt(
                                cut: captured.cut,
                                sinks: captured.sinkBarriers.compactMap {
                                    settledByID[$0.cut.id]
                                })
                        }
                    case .deadline:
                        let partial = DiagnosticsBarrierReceipt(
                            cut: captured.cut,
                            sinks: captured.sinkBarriers.map {
                                settledByID[$0.cut.id] ?? $0.currentResult()
                            })
                        captured.cancel()
                        throw DiagnosticsBarrierError.deadlineExceeded(partial: partial)
                    }
                }
                throw CancellationError()
            }
        } onCancel: {
            captured.cancel()
        }
    }

    private func reserveFlush() throws -> UUID {
        try Task.checkCancellation()
        lock.lock()
        guard activeFlushReservations.count < maximumFlushWaiters else {
            lock.unlock()
            throw DiagnosticsBarrierError.waiterLimitExceeded(limit: maximumFlushWaiters)
        }
        let identifier = UUID()
        activeFlushReservations.insert(identifier)
        lock.unlock()
        return identifier
    }

    private func releaseFlush(_ identifier: UUID) {
        lock.lock()
        activeFlushReservations.remove(identifier)
        lock.unlock()
    }

    private func enqueueBarrier(identifier: UUID) throws -> PendingBarrier {
        try Task.checkCancellation()
        var shouldStartDrain = false

        lock.lock()
        guard activeFlushReservations.contains(identifier) else {
            lock.unlock()
            throw CancellationError()
        }
        let barrier = PendingBarrier(
            identifier: identifier,
            acceptedThrough: lastAcceptedSequence,
            droppedThrough: totalDropped,
            promise: DiagnosticsOneShot<CapturedDiagnosticsCut>())
        pendingBarriers.append(barrier)
        if !drainIsRunning {
            drainIsRunning = true
            shouldStartDrain = true
        }
        lock.unlock()

        if shouldStartDrain { startDrain() }
        return barrier
    }

    private func cancelBarrier(_ barrier: PendingBarrier) {
        var shouldStartDrain = false
        lock.lock()
        let countBeforeRemoval = pendingBarriers.count
        pendingBarriers.removeAll { $0.identifier == barrier.identifier }
        if pendingBarriers.count != countBeforeRemoval,
           !drainIsRunning,
           (pendingCount > 0 || unaccountedDropped > 0 || !pendingBarriers.isEmpty)
        {
            drainIsRunning = true
            shouldStartDrain = true
        }
        lock.unlock()
        barrier.promise.resolve(.failure(CancellationError()))
        if shouldStartDrain { startDrain() }
    }

    private func startDrain() {
        _ = Task.detached(priority: .utility) { [self] in
            await drain()
        }
    }

    private func drain() async {
        while let work = nextWork() {
            switch work {
            case let .event(event):
                await center.offer(
                    severity: event.severity,
                    subsystem: event.subsystem,
                    code: event.code,
                    operationID: event.operationID,
                    metadata: event.metadata)
                complete(event.admissionSequence)
            case let .dropped(count):
                await center.accountForIngressDrops(count)
                completeDropped(count)
            case let .barrier(barrier):
                do {
                    let captured = try await center.captureCut(markerID: barrier.identifier)
                    if !barrier.promise.resolve(.success(captured)) {
                        captured.cancel()
                    }
                } catch {
                    barrier.promise.resolve(.failure(error))
                }
            }
        }
    }

    private func nextWork() -> Work? {
        lock.lock()

        if let barrier = pendingBarriers.first {
            let acceptedReady = completedSequence >= barrier.acceptedThrough
            let droppedReady = accountedDropped >= barrier.droppedThrough
            if acceptedReady, droppedReady {
                pendingBarriers.removeFirst()
                lock.unlock()
                return .barrier(barrier)
            }

            if !acceptedReady,
               pendingCount > 0,
               let event = buffer[head],
               event.admissionSequence <= barrier.acceptedThrough
            {
                buffer[head] = nil
                head = (head + 1) % capacity
                pendingCount -= 1
                lock.unlock()
                return .event(event)
            }

            if !droppedReady, unaccountedDropped > 0 {
                let required = barrier.droppedThrough - accountedDropped
                let count = min(unaccountedDropped, required)
                unaccountedDropped -= count
                lock.unlock()
                return .dropped(count)
            }
        } else {
            if unaccountedDropped > 0 {
                let count = unaccountedDropped
                unaccountedDropped = 0
                lock.unlock()
                return .dropped(count)
            }
            if pendingCount > 0 {
                let event = buffer[head]
                buffer[head] = nil
                head = (head + 1) % capacity
                pendingCount -= 1
                lock.unlock()
                return event.map(Work.event)
            }
        }

        drainIsRunning = false
        lock.unlock()
        return nil
    }

    private func complete(_ sequence: UInt64) {
        lock.lock()
        completedSequence = max(completedSequence, sequence)
        lock.unlock()
    }

    private func completeDropped(_ count: UInt64) {
        lock.lock()
        accountedDropped = Self.saturatingAdd(accountedDropped, count)
        lock.unlock()
    }

    private func defaultDeadline() -> DiagnosticDeadline {
        let now = barrierClock.uptimeNanoseconds()
        let (deadline, overflow) = now.addingReportingOverflow(defaultFlushTimeoutNanoseconds)
        return DiagnosticDeadline(uptimeNanoseconds: overflow ? .max : deadline)
    }

    private func reportBarrier(
        deadline: DiagnosticDeadline
    ) async throws -> (receipt: DiagnosticsBarrierReceipt, state: DiagnosticReportDeliveryState) {
        do {
            let receipt = try await flush(deadline: deadline)
            return (receipt, .settled)
        } catch let DiagnosticsBarrierError.deadlineExceeded(partial) {
            guard let partial else {
                throw DiagnosticsBarrierError.deadlineExceeded(partial: nil)
            }
            return (partial, .timedOut)
        }
    }

    private static func saturatingIncrement(_ value: UInt64) -> UInt64 {
        saturatingAdd(value, 1)
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }
}

struct ReservedCapturedDiagnosticsCut: Sendable {
    fileprivate let reservationID: UUID
    let captured: CapturedDiagnosticsCut

    var cut: DiagnosticsCut { captured.cut }
}
