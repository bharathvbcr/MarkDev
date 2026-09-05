//
//  DiagnosticsSettingsTests.swift
//  MarkDevKitTests
//
//  The Settings support surface must remain useful without exposing the data
//  it is specifically designed to keep out of diagnostics.
//

import Foundation
import XCTest

@testable import MarkDevKit

@MainActor
final class DiagnosticsSettingsTests: XCTestCase {
    private struct FixedClock: DiagnosticClock {
        func millisecondsSince1970() -> Int64 { 1_700_000_000_123 }
        func uptimeNanoseconds() -> UInt64 { 99 }
    }

    func testRefreshDistinguishesUncheckedHealthFromARealSnapshot() async {
        let center = DiagnosticsCenter(sinks: [], clock: FixedClock())
        let model = DiagnosticsSettingsModel(center: center, metadata: reportMetadata)

        XCTAssertNil(model.health, "an unperformed health check must not look like a passing zero result")

        await center.record(
            severity: .notice,
            subsystem: .diagnostics,
            code: .appLaunchABIVerified)
        await model.refresh()

        XCTAssertEqual(model.health?.recordedEventCount, 1)
        XCTAssertEqual(model.health?.retainedEventCount, 1)
        XCTAssertEqual(model.health?.droppedEventCount, 0)
        XCTAssertEqual(model.health?.sinkFailureCount, 0)
    }

    func testExportPublishesSummaryAndWritesOnlyTheCanonicalRedactedReport() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let noteSeed = "PRIVATE-NOTE-SETTINGS-7F4A"
        let passwordSeed = "PASSWORD-SETTINGS-C2D3"
        let tokenSeed = "TOKEN-SETTINGS-E5F6"
        let center = DiagnosticsCenter(
            configuration: DiagnosticsConfiguration(
                memoryEventLimit: 8,
                memoryByteLimit: 64 * 1_024,
                supportReportByteLimit: 64 * 1_024),
            sinks: [],
            clock: FixedClock())
        await center.record(
            severity: .error,
            subsystem: .filesystem,
            code: .appLaunchABIVerified,
            metadata: DiagnosticMetadata([
                .fileType: .file(URL(fileURLWithPath: "/Users/alice/Secret Vault/\(noteSeed).md")),
                .endpoint: .url(try XCTUnwrap(URL(
                    string: "https://alice:\(passwordSeed)@example.test/private?token=\(tokenSeed)#fragment"))),
            ]))
        let model = DiagnosticsSettingsModel(
            center: center,
            metadata: reportMetadata,
            generatedAtMilliseconds: 1_700_000_000_999)
        let destination = root.appendingPathComponent("MarkDev Support Report.json")

        let exported = await model.export(to: destination)

        XCTAssertTrue(exported)
        guard case let .succeeded(summary) = model.exportState else {
            return XCTFail("expected a successful export state, got \(model.exportState)")
        }
        let data = try Data(contentsOf: destination)
        let text = String(decoding: data, as: UTF8.self)
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        let permissions = try XCTUnwrap((attributes[.posixPermissions] as? NSNumber)?.intValue)
        XCTAssertEqual(summary.byteCount, data.count)
        XCTAssertEqual(summary.includedEventCount, 1)
        XCTAssertEqual(summary.deliveryState, .settled)
        XCTAssertEqual(model.health?.recordedEventCount, 1)
        XCTAssertEqual(permissions & 0o777, 0o600)
        for forbidden in [
            noteSeed, passwordSeed, tokenSeed, "/Users/alice", "Secret Vault",
            "alice:", "/private", "?token=", "#fragment",
        ] {
            XCTAssertFalse(text.contains(forbidden), "Settings export leaked \(forbidden)")
        }
        XCTAssertTrue(text.contains("https://example.test"))
        XCTAssertTrue(text.contains("\"md\""))
    }

    func testExportFailureUsesAClosedCategoryAndNeverEchoesTheDestination() async {
        let privateSeed = "PRIVATE-DESTINATION-3A9B"
        let center = DiagnosticsCenter(sinks: [], clock: FixedClock())
        let model = DiagnosticsSettingsModel(center: center, metadata: reportMetadata)
        let destination = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevDiagnosticsSettings-\(UUID().uuidString)")
            .appendingPathComponent(privateSeed, isDirectory: true)
            .appendingPathComponent("report.json")

        let exported = await model.export(to: destination)

        XCTAssertFalse(exported)
        XCTAssertEqual(model.exportState, .failed(.destinationUnavailable))
        XCTAssertFalse(model.exportState.message.contains(privateSeed))
        XCTAssertFalse(model.exportState.message.contains(destination.path))
    }

    func testReportLimitFailureUsesAClosedCategoryAndLeavesNoFile() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let center = DiagnosticsCenter(
            configuration: DiagnosticsConfiguration(supportReportByteLimit: 1),
            sinks: [],
            clock: FixedClock())
        let model = DiagnosticsSettingsModel(center: center, metadata: reportMetadata)
        let destination = root.appendingPathComponent("report.json")

        let exported = await model.export(to: destination)

        XCTAssertFalse(exported)
        XCTAssertEqual(model.exportState, .failed(.reportTooLarge))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testWriteFailureUsesAClosedCategoryAndNeverEchoesTheDestination() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let privateSeed = "PRIVATE-WRITE-DESTINATION-5D7E"
        let destination = root.appendingPathComponent(privateSeed, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let center = DiagnosticsCenter(sinks: [], clock: FixedClock())
        let model = DiagnosticsSettingsModel(center: center, metadata: reportMetadata)

        let exported = await model.export(to: destination)

        XCTAssertFalse(exported)
        XCTAssertEqual(model.exportState, .failed(.writeFailed))
        XCTAssertFalse(model.exportState.message.contains(privateSeed))
        XCTAssertFalse(model.exportState.message.contains(destination.path))
    }

    func testRemoteAuthorityFileURLCannotAliasALocalSupportExport() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let localDestination = root.appendingPathComponent("report.json")
        var components = URLComponents()
        components.scheme = "file"
        components.host = "remote.example"
        components.percentEncodedPath = localDestination.path
        let remoteAuthority = try XCTUnwrap(components.url)
        XCTAssertTrue(
            remoteAuthority.isFileURL,
            "the regression requires Foundation's permissive file-URL classification")

        let center = DiagnosticsCenter(sinks: [], clock: FixedClock())
        let model = DiagnosticsSettingsModel(center: center, metadata: reportMetadata)
        let exported = await model.export(to: remoteAuthority)

        XCTAssertFalse(exported)
        XCTAssertEqual(model.exportState, .failed(.destinationUnavailable))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: localDestination.path),
            "remote file authority must not be discarded into a local write")
    }

    func testDismissExportResultDoesNotEraseTheLastHealthSnapshot() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let center = DiagnosticsCenter(sinks: [], clock: FixedClock())
        let model = DiagnosticsSettingsModel(
            center: center,
            metadata: reportMetadata,
            generatedAtMilliseconds: 1_700_000_000_999)
        let destination = root.appendingPathComponent("report.json")

        let exported = await model.export(to: destination)
        XCTAssertTrue(exported)
        let health = model.health
        model.dismissExportResult()

        XCTAssertEqual(model.exportState, .idle)
        XCTAssertEqual(model.health, health)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevDiagnosticsSettings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private var reportMetadata: DiagnosticReportMetadata {
        DiagnosticReportMetadata(
            app: DiagnosticAppMetadata(
                name: "MarkDev",
                bundleIdentifier: "dev.markdev.MarkDev"),
            build: DiagnosticBuildMetadata(
                version: "0.0.4",
                buildNumber: "10",
                sourceCommit: "0123456789abcdef0123456789abcdef01234567"),
            operatingSystem: DiagnosticOSMetadata(
                name: "macOS",
                version: "26.0.0",
                architecture: "arm64"))
    }
}
