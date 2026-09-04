//
//  DiagnosticsEmitter.swift
//  MarkDevKit
//
//  A bounded, non-blocking bridge from synchronous production call sites.
//

import Foundation

public struct DiagnosticsEmitterConfiguration: Equatable, Sendable {
    public static let largestSupportedPendingEventLimit = 100_000

    public let maximumPendingEvents: Int

    public init(maximumPendingEvents: Int = 1_024) {
        self.maximumPendingEvents = min(
            max(0, maximumPendingEvents),
            Self.largestSupportedPendingEventLimit)
    }
}

/// Accepts typed diagnostics without making an application operation await
/// disk or OS logging. A single detached worker preserves admission order and
/// the fixed-size queue prevents an unavailable sink from becoming an
/// unbounded task or memory leak.
///
/// Mutable state is protected exclusively by `lock`; the unchecked Sendable
/// conformance records that invariant explicitly. Payload types are themselves
/// Sendable and contain no arbitrary strings.
public final class DiagnosticsEmitter: @unchecked Sendable {
    public static let shared = DiagnosticsEmitter(center: .shared)

    private struct PendingEvent: Sendable {
        let admissionSequence: UInt64
        let severity: DiagnosticSeverity
        let subsystem: DiagnosticSubsystem
        let code: DiagnosticCode
        let operationID: DiagnosticOperationID?
        let metadata: DiagnosticMetadata
    }

    private struct FlushWaiter {
        let acceptedThrough: UInt64
        let droppedThrough: UInt64
        let continuation: CheckedContinuation<Void, Never>
    }

    private enum Work: Sendable {
        case event(PendingEvent)
        case dropped(UInt64)
    }

    private let center: DiagnosticsCenter
    private let capacity: Int
    private let lock = NSLock()
    private var buffer: [PendingEvent?]
    private var head = 0
    private var pendingCount = 0
    private var drainIsRunning = false
    private var acceptedSequence: UInt64 = 0
    private var completedSequence: UInt64 = 0
    private var totalDropped: UInt64 = 0
    private var accountedDropped: UInt64 = 0
    private var unaccountedDropped: UInt64 = 0
    private var flushWaiters: [FlushWaiter] = []

    public init(
        center: DiagnosticsCenter,
        configuration: DiagnosticsEmitterConfiguration = DiagnosticsEmitterConfiguration()
    ) {
        self.center = center
        capacity = configuration.maximumPendingEvents
        buffer = Array(repeating: nil, count: configuration.maximumPendingEvents)
    }

    /// Admits one event and returns immediately. Full queues fail closed by
    /// dropping the new event and accounting for it in `DiagnosticsHealth`;
    /// application success and failure semantics never depend on a sink.
    public func emit(
        severity: DiagnosticSeverity,
        subsystem: DiagnosticSubsystem,
        code: DiagnosticCode,
        operationID: DiagnosticOperationID? = nil,
        metadata: DiagnosticMetadata = DiagnosticMetadata()
    ) {
        var shouldStartDrain = false

        lock.lock()
        if pendingCount < capacity {
            acceptedSequence = Self.saturatingIncrement(acceptedSequence)
            let event = PendingEvent(
                admissionSequence: acceptedSequence,
                severity: severity,
                subsystem: subsystem,
                code: code,
                operationID: operationID,
                metadata: metadata)
            let tail = (head + pendingCount) % capacity
            buffer[tail] = event
            pendingCount += 1
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

    /// Waits until every event admitted or dropped before this call has been
    /// delivered or accounted. Events emitted concurrently after this method
    /// takes its lock are outside that barrier.
    public func flush() async {
        await withCheckedContinuation { continuation in
            var shouldResume = false
            var shouldStartDrain = false

            lock.lock()
            let acceptedThrough = acceptedSequence
            let droppedThrough = totalDropped
            if completedSequence >= acceptedThrough && accountedDropped >= droppedThrough {
                shouldResume = true
            } else {
                flushWaiters.append(
                    FlushWaiter(
                        acceptedThrough: acceptedThrough,
                        droppedThrough: droppedThrough,
                        continuation: continuation))
                if !drainIsRunning {
                    drainIsRunning = true
                    shouldStartDrain = true
                }
            }
            lock.unlock()

            if shouldStartDrain { startDrain() }
            if shouldResume { continuation.resume() }
        }
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
                await center.record(
                    severity: event.severity,
                    subsystem: event.subsystem,
                    code: event.code,
                    operationID: event.operationID,
                    metadata: event.metadata)
                complete(event.admissionSequence)
            case let .dropped(count):
                await center.accountForIngressDrops(count)
                completeDropped(count)
            }
        }
    }

    private func nextWork() -> Work? {
        var ready: [CheckedContinuation<Void, Never>] = []

        lock.lock()
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

        drainIsRunning = false
        ready = takeReadyWaitersLocked()
        lock.unlock()
        for continuation in ready { continuation.resume() }
        return nil
    }

    private func complete(_ sequence: UInt64) {
        lock.lock()
        completedSequence = max(completedSequence, sequence)
        let ready = takeReadyWaitersLocked()
        lock.unlock()
        for continuation in ready { continuation.resume() }
    }

    private func completeDropped(_ count: UInt64) {
        lock.lock()
        accountedDropped = Self.saturatingAdd(accountedDropped, count)
        let ready = takeReadyWaitersLocked()
        lock.unlock()
        for continuation in ready { continuation.resume() }
    }

    private func takeReadyWaitersLocked() -> [CheckedContinuation<Void, Never>] {
        var ready: [CheckedContinuation<Void, Never>] = []
        flushWaiters.removeAll { waiter in
            let isReady = completedSequence >= waiter.acceptedThrough
                && accountedDropped >= waiter.droppedThrough
            if isReady { ready.append(waiter.continuation) }
            return isReady
        }
        return ready
    }

    private static func saturatingIncrement(_ value: UInt64) -> UInt64 {
        saturatingAdd(value, 1)
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }
}
