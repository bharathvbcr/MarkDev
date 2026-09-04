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
            if summary.omittedEventCount == 0 {
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

@MainActor
@Observable
public final class DiagnosticsSettingsModel {
    public private(set) var health: DiagnosticsHealth?
    public private(set) var exportState: DiagnosticsExportState = .idle

    @ObservationIgnored private let center: DiagnosticsCenter
    @ObservationIgnored private let metadata: DiagnosticReportMetadata
    @ObservationIgnored private let generatedAtMilliseconds: Int64?

    public init(
        center: DiagnosticsCenter = .shared,
        metadata: DiagnosticReportMetadata = .current(),
        generatedAtMilliseconds: Int64? = nil
    ) {
        self.center = center
        self.metadata = metadata
        self.generatedAtMilliseconds = generatedAtMilliseconds
    }

    public func refresh() async {
        health = await center.snapshot().health
    }

    /// Exports through the diagnostics center so Settings cannot accidentally
    /// grow a second, less-redacted report format. The destination is never
    /// retained or echoed through observable state.
    @discardableResult
    public func export(to destination: URL) async -> Bool {
        guard !exportState.isExporting else { return false }
        exportState = .exporting

        do {
            let summary = try await center.exportSupportReport(
                to: destination,
                metadata: metadata,
                generatedAtMilliseconds: generatedAtMilliseconds)
            health = await center.snapshot().health
            exportState = .succeeded(summary)
            return true
        } catch {
            health = await center.snapshot().health
            exportState = .failed(Self.failureCategory(for: error))
            return false
        }
    }

    public func dismissExportResult() {
        guard !exportState.isExporting else { return }
        exportState = .idle
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
}
