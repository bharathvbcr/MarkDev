//
//  DiagnosticsSettingsModel.swift
//  MarkDevKit
//
//  Main-actor state for the Settings support surface. AppKit owns choosing a
//  destination; this type owns only safe status and the canonical export call.
//

import Foundation
import Observation

public enum DiagnosticsExportFailure: Equatable, Sendable {
    case reportTooLarge
    case destinationUnavailable
    case writeFailed

    public var message: String {
        switch self {
        case .reportTooLarge:
            "The support report exceeds its configured size limit."
        case .destinationUnavailable:
            "The selected destination is no longer available. Choose another location."
        case .writeFailed:
            "The support report could not be written. Choose another location and try again."
        }
    }
}

public enum DiagnosticsExportState: Equatable, Sendable {
    case idle
    case exporting
    case succeeded(DiagnosticExportSummary)
    case failed(DiagnosticsExportFailure)

    public var message: String {
        switch self {
        case .idle:
            ""
        case .exporting:
            "Preparing a privacy-safe support report…"
        case let .succeeded(summary):
            if summary.deliveryState == .timedOut {
                "Exported a partial report with exact pending sink counts "
                    + "(\(summary.byteCount) bytes)."
            } else if summary.omittedEventCount == 0 {
                "Exported \(summary.includedEventCount) events (\(summary.byteCount) bytes)."
            } else {
                "Exported \(summary.includedEventCount) events and omitted "
                    + "\(summary.omittedEventCount) older events to stay within the size limit."
            }
        case let .failed(failure):
            failure.message
        }
    }

    public var isExporting: Bool {
        self == .exporting
    }
}

public enum DiagnosticsHistoryAvailability: Equatable, Sendable {
    case notChecked
    case available(DiagnosticHistorySnapshot)
    case unavailable

    public var message: String {
        switch self {
        case .notChecked:
            "Not checked"
        case .available:
            "Available"
        case .unavailable:
            "Unavailable — previous-run totals could not be inspected safely."
        }
    }
}

public enum DiagnosticsHistoryExportFailure: Equatable, Sendable {
    case historyUnavailable
    case temporarilyBusy
    case reportTooLarge
    case destinationUnavailable
    case writeFailed
    case cancelled

    public var message: String {
        switch self {
        case .historyUnavailable:
            "Previous-run diagnostics could not be inspected safely."
        case .temporarilyBusy:
            "Previous-run diagnostics are busy. Try again after the current maintenance finishes."
        case .reportTooLarge:
            "The previous-runs report exceeds its configured size limit."
        case .destinationUnavailable:
            "The selected destination is no longer available. Choose another location."
        case .writeFailed:
            "The previous-runs report could not be written. Choose another location and try again."
        case .cancelled:
            "Previous-runs export was cancelled."
        }
    }
}

public enum DiagnosticsHistoryExportState: Equatable, Sendable {
    case idle
    case exporting
    case succeeded(DiagnosticHistoryExportSummary)
    case failed(DiagnosticsHistoryExportFailure)

    public var message: String {
        switch self {
        case .idle:
            ""
        case .exporting:
            "Preparing a bounded previous-runs report…"
        case let .succeeded(summary):
            historyExportMessage(summary)
        case let .failed(failure):
            failure.message
        }
    }

    public var isExporting: Bool { self == .exporting }

    private func historyExportMessage(_ summary: DiagnosticHistoryExportSummary) -> String {
        let counts = summary.inspection
        let unknownSuffix = [
            counts.runs.uninspected,
            counts.files.uninspected,
            counts.bytes.uninspected,
            counts.events.uninspected,
        ].contains(where: { $0 == nil })
            ? " Some uninspected totals are unknown."
            : ""
        return "Exported \(counts.runs.included) inactive runs and "
            + "\(counts.events.included) events (\(summary.byteCount) bytes)."
            + unknownSuffix
    }
}

@MainActor
@Observable
public final class DiagnosticsSettingsModel {
    public private(set) var health: DiagnosticsHealth?
    public private(set) var exportState: DiagnosticsExportState = .idle
    public private(set) var historyAvailability: DiagnosticsHistoryAvailability = .notChecked
    public private(set) var historyExportState: DiagnosticsHistoryExportState = .idle

    @ObservationIgnored private let emitter: DiagnosticsEmitter
    @ObservationIgnored private let metadata: DiagnosticReportMetadata
    @ObservationIgnored private let generatedAtMilliseconds: Int64?
    @ObservationIgnored private let historyApplicationSupportDirectory: URL?
    @ObservationIgnored private let historyLimits: DiagnosticsHistoryInspectionLimits
    @ObservationIgnored private var historyRefreshTask: Task<DiagnosticHistoryReport, Error>?
    @ObservationIgnored private var historyRefreshGeneration: UUID?
    @ObservationIgnored private var historyExportTask: Task<DiagnosticHistoryExportSummary, Error>?
    @ObservationIgnored private var historyExportGeneration: UUID?

    public init(
        metadata: DiagnosticReportMetadata = .current(),
        generatedAtMilliseconds: Int64? = nil
    ) {
        emitter = .shared
        self.metadata = metadata
        self.generatedAtMilliseconds = generatedAtMilliseconds
        historyApplicationSupportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first
        historyLimits = .production
    }

    public init(
        center: DiagnosticsCenter,
        metadata: DiagnosticReportMetadata = .current(),
        generatedAtMilliseconds: Int64? = nil
    ) {
        emitter = DiagnosticsEmitter(center: center)
        self.metadata = metadata
        self.generatedAtMilliseconds = generatedAtMilliseconds
        historyApplicationSupportDirectory = nil
        historyLimits = .production
    }

    init(
        emitter: DiagnosticsEmitter,
        metadata: DiagnosticReportMetadata = .current(),
        generatedAtMilliseconds: Int64? = nil,
        historyApplicationSupportDirectory: URL? = nil,
        historyLimits: DiagnosticsHistoryInspectionLimits = .production
    ) {
        self.emitter = emitter
        self.metadata = metadata
        self.generatedAtMilliseconds = generatedAtMilliseconds
        self.historyApplicationSupportDirectory = historyApplicationSupportDirectory
        self.historyLimits = historyLimits
    }

    public func refresh() async {
        let generation = UUID()
        historyRefreshTask?.cancel()
        historyRefreshTask = nil
        historyRefreshGeneration = generation
        health = await emitter.snapshot().health
        guard historyRefreshGeneration == generation,
              !Task.isCancelled
        else { return }
        guard !historyExportState.isExporting else { return }
        guard let historyApplicationSupportDirectory else {
            historyAvailability = .unavailable
            return
        }
        let generatedAtMilliseconds = generatedAtMilliseconds
        let historyLimits = historyLimits
        let operation = Task.detached {
            try DiagnosticsScopedRunStore.historyReport(
                applicationSupportDirectory: historyApplicationSupportDirectory,
                generatedAtMilliseconds: generatedAtMilliseconds,
                limits: historyLimits)
        }
        historyRefreshTask = operation
        defer {
            if historyRefreshGeneration == generation {
                historyRefreshTask = nil
            }
        }
        do {
            let report = try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: {
                operation.cancel()
            }
            guard historyRefreshGeneration == generation,
                  !Task.isCancelled
            else { return }
            historyAvailability = .available(DiagnosticHistorySnapshot(report: report))
        } catch is CancellationError {
            return
        } catch {
            guard historyRefreshGeneration == generation else { return }
            historyAvailability = .unavailable
        }
    }

    /// Exports through the diagnostics center so Settings cannot accidentally
    /// grow a second, less-redacted report format. The destination is never
    /// retained or echoed through observable state.
    @discardableResult
    public func export(to destination: URL) async -> Bool {
        guard !exportState.isExporting else { return false }
        exportState = .exporting

        do {
            let summary = try await emitter.exportSupportReport(
                to: destination,
                metadata: metadata,
                generatedAtMilliseconds: generatedAtMilliseconds)
            health = await emitter.snapshot().health
            exportState = .succeeded(summary)
            return true
        } catch {
            health = await emitter.snapshot().health
            exportState = .failed(Self.failureCategory(for: error))
            return false
        }
    }

    public func dismissExportResult() {
        guard !exportState.isExporting else { return }
        exportState = .idle
    }

    @discardableResult
    public func exportHistory(to destination: URL) async -> Bool {
        guard !historyExportState.isExporting else { return false }
        guard let historyApplicationSupportDirectory else {
            historyExportState = .failed(.historyUnavailable)
            return false
        }
        historyRefreshGeneration = nil
        historyRefreshTask?.cancel()
        historyRefreshTask = nil
        let generation = UUID()
        historyExportGeneration = generation
        historyExportState = .exporting

        let generatedAtMilliseconds = generatedAtMilliseconds
        let historyLimits = historyLimits
        let operation = Task.detached {
            try DiagnosticsScopedRunStore.exportHistoryReport(
                applicationSupportDirectory: historyApplicationSupportDirectory,
                to: destination,
                generatedAtMilliseconds: generatedAtMilliseconds,
                limits: historyLimits)
        }
        historyExportTask = operation
        defer {
            if historyExportGeneration == generation {
                historyExportTask = nil
            }
        }
        do {
            let summary = try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: {
                operation.cancel()
            }
            guard historyExportGeneration == generation,
                  !Task.isCancelled
            else { return false }
            historyAvailability = .available(DiagnosticHistorySnapshot(
                inspection: summary.inspection))
            historyExportState = .succeeded(summary)
            return true
        } catch {
            guard historyExportGeneration == generation else { return false }
            historyExportState = .failed(Self.historyFailureCategory(for: error))
            return false
        }
    }

    public func dismissHistoryExportResult() {
        guard !historyExportState.isExporting else { return }
        historyExportState = .idle
    }

    public func cancelHistoryWork() {
        historyRefreshGeneration = nil
        historyRefreshTask?.cancel()
        historyRefreshTask = nil
        historyExportGeneration = nil
        historyExportTask?.cancel()
        historyExportTask = nil
        if historyExportState.isExporting {
            historyExportState = .failed(.cancelled)
        }
    }

    private static func failureCategory(for error: Error) -> DiagnosticsExportFailure {
        guard let diagnosticsError = error as? DiagnosticsError else {
            return .writeFailed
        }
        switch diagnosticsError {
        case .reportExceedsByteLimit:
            return .reportTooLarge
        case .destinationDirectoryUnavailable:
            return .destinationUnavailable
        }
    }

    private static func historyFailureCategory(
        for error: Error
    ) -> DiagnosticsHistoryExportFailure {
        if error is CancellationError { return .cancelled }
        if let storeError = error as? DiagnosticsScopedRunStoreError {
            switch storeError {
            case .retentionLockUnavailable:
                return .temporarilyBusy
            case .untrustedOrigin,
                 .pathIsNotDirectory,
                 .untrustedFilesystemObject,
                 .filesystemChanged,
                 .retentionCapacityUnavailable,
                 .runDirectoryCollision:
                return .historyUnavailable
            }
        }
        if let diagnosticsError = error as? DiagnosticsError {
            switch diagnosticsError {
            case .reportExceedsByteLimit:
                return .reportTooLarge
            case .destinationDirectoryUnavailable:
                return .destinationUnavailable
            }
        }
        return .writeFailed
    }
}
