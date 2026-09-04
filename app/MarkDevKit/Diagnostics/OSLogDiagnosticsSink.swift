//
//  OSLogDiagnosticsSink.swift
//  MarkDevKit
//
//  Unified logging adapter for the already-redacted canonical event envelope.
//

import Foundation
import OSLog

public struct OSLogDiagnosticsSink: DiagnosticSink, Sendable {
    private let logger: Logger

    public init() {
        logger = Logger(subsystem: "dev.markdev.MarkDev", category: "diagnostics")
    }

    public func write(_ record: DiagnosticRecord) async throws {
        let canonicalLine = try DiagnosticsJSON.line(for: record.event)
        let message = String(decoding: canonicalLine.dropLast(), as: UTF8.self)
        logger.log(level: record.event.severity.osLogType, "\(message, privacy: .public)")
    }
}

private extension DiagnosticSeverity {
    var osLogType: OSLogType {
        switch self {
        case .debug:
            return .debug
        case .info:
            return .info
        case .notice, .warning:
            return .default
        case .error:
            return .error
        case .critical:
            return .fault
        }
    }
}
