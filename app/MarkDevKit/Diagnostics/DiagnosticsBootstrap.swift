//
//  DiagnosticsBootstrap.swift
//  MarkDevKit
//
//  Fail-closed process identity and scoped diagnostics storage selection.
//

import Foundation

enum DiagnosticsBootstrap {
    static func currentOrigin(
        bundle: Bundle = .main,
        processInfo: ProcessInfo = .processInfo,
        runID: UUID = UUID()
    ) -> DiagnosticOrigin {
        origin(
            bundleIdentifier: bundle.bundleIdentifier,
            isRunningTests: DiagnosticsCenter.isRunningTests,
            runID: runID,
            processID: processInfo.processIdentifier)
    }

    static func origin(
        bundleIdentifier: String?,
        isRunningTests: Bool,
        runID: UUID,
        processID: Int32
    ) -> DiagnosticOrigin {
        guard processID > 0 else {
            return DiagnosticOrigin(
                validatedRunID: runID,
                processID: 0,
                role: .unknown,
                locality: .unknown)
        }
        if isRunningTests {
            return DiagnosticOrigin(
                validatedRunID: runID,
                processID: processID,
                role: .testHost,
                locality: .ephemeralTest)
        }

        switch bundleIdentifier {
        case "dev.markdev.MarkDev":
            return DiagnosticOrigin(
                validatedRunID: runID,
                processID: processID,
                role: .app,
                locality: .productionUser)
        case "dev.markdev.MarkDev.QuickLook":
            return DiagnosticOrigin(
                validatedRunID: runID,
                processID: processID,
                role: .quickLookExtension,
                locality: .productionUser)
        default:
            return DiagnosticOrigin(
                validatedRunID: runID,
                processID: processID,
                role: .unknown,
                locality: .unknown)
        }
    }

    static func scopedDirectory(
        applicationSupportDirectory: URL,
        origin: DiagnosticOrigin
    ) -> URL? {
        guard origin.isTrustedProduction else { return nil }
        let processSegment = runDirectoryName(origin: origin)
        return applicationSupportDirectory
            .appendingPathComponent("MarkDev", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("v2", isDirectory: true)
            .appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent(processSegment, isDirectory: true)
    }

    static func runRoot(applicationSupportDirectory: URL) -> URL {
        applicationSupportDirectory
            .appendingPathComponent("MarkDev", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("v2", isDirectory: true)
            .appendingPathComponent("runs", isDirectory: true)
    }

    static func runDirectoryName(origin: DiagnosticOrigin) -> String {
        origin.role.storageComponent + "-" + origin.runID.uuidString.lowercased()
            + "-" + String(origin.processID)
    }
}

private extension DiagnosticProcessRole {
    var storageComponent: String {
        switch self {
        case .app:
            return "app"
        case .quickLookExtension:
            return "quick-look-extension"
        case .testHost:
            return "test-host"
        case .unknown:
            return "unknown"
        }
    }
}
