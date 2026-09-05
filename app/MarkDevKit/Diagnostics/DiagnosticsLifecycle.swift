//
//  DiagnosticsLifecycle.swift
//  MarkDevKit
//
//  Typed lifecycle events and bounded shutdown settlement.
//

import Foundation

public enum DiagnosticsTerminationDrainOutcome: String, Equatable, Sendable {
    case settled
    case timedOut = "timed-out"
    case cancelled
    case failed
}

/// Gives an approved application termination one finite chance to settle
/// diagnostics that were already admitted by the non-blocking emitter.
///
/// Shutdown must never wait forever for a stalled file or future sink. The
/// timeout is normalized at construction, and every outcome remains distinct
/// so the app can report an incomplete drain without presenting it as success.
public struct DiagnosticsTerminationDrainPolicy: Sendable {
    public static let defaultTimeoutNanoseconds: UInt64 = 2_000_000_000
    public static let maximumTimeoutNanoseconds: UInt64 = 10_000_000_000

    private let timeoutNanoseconds: UInt64
    private let drain: @Sendable (DiagnosticDeadline) async throws -> DiagnosticsBarrierReceipt

    public init(
        emitter: DiagnosticsEmitter = .shared,
        timeoutNanoseconds: UInt64 = defaultTimeoutNanoseconds
    ) {
        self.init(timeoutNanoseconds: timeoutNanoseconds) { deadline in
            try await emitter.flush(deadline: deadline)
        }
    }

    init(
        timeoutNanoseconds: UInt64,
        drain: @escaping @Sendable (DiagnosticDeadline) async throws
            -> DiagnosticsBarrierReceipt
    ) {
        self.timeoutNanoseconds = min(
            max(1, timeoutNanoseconds),
            Self.maximumTimeoutNanoseconds)
        self.drain = drain
    }

    public func drainForTermination() async -> DiagnosticsTerminationDrainOutcome {
        do {
            let receipt = try await drain(.after(nanoseconds: timeoutNanoseconds))
            try Task.checkCancellation()
            return receipt.isFullySettled ? .settled : .failed
        } catch is CancellationError {
            return .cancelled
        } catch DiagnosticsBarrierError.deadlineExceeded {
            return .timedOut
        } catch {
            return .failed
        }
    }
}

public extension DiagnosticsEmitter {
    /// Called only after the native core ABI precondition returns successfully.
    /// There is deliberately no metadata parameter: launch diagnostics must not
    /// become a shortcut for capturing arguments, environment, or paths.
    func recordVerifiedABILaunch() {
        emit(
            severity: .notice,
            subsystem: .app,
            code: .appLaunchABIVerified)
    }
}
