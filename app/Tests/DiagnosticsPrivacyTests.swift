//
//  DiagnosticsPrivacyTests.swift
//  MarkDevKitTests
//
//  A support report is useful only if it is safe to hand to somebody else.
//

import Foundation
import XCTest

@testable import MarkDevKit

final class DiagnosticsPrivacyTests: XCTestCase {
    private struct FixedClock: DiagnosticClock {
        func millisecondsSince1970() -> Int64 { 1_700_000_000_123 }
        func uptimeNanoseconds() -> UInt64 { 99 }
    }

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevSupport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        unsetenv("MARKDEV_DIAGNOSTICS_TEST_SECRET")
        try? FileManager.default.removeItem(at: root)
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

    func testSupportReportIsDeterministicAndContainsNoSeededSecretsPathsOrURLCredentials() async throws {
        let noteSeed = "PRIVATE-NOTE-CONTENT-7F4A"
        let environmentSeed = "ENVIRONMENT-SECRET-8B91"
        let passwordSeed = "PASSWORD-CREDENTIAL-C2D3"
        let tokenSeed = "sk-token-seed-E5F6"
        setenv("MARKDEV_DIAGNOSTICS_TEST_SECRET", environmentSeed, 1)

        let fullPath = URL(fileURLWithPath: "/Users/alice/Private Vault/\(noteSeed).md")
        let credentialURL = try XCTUnwrap(
            URL(string: "https://alice:\(passwordSeed)@example.test/private/\(noteSeed)?token=\(tokenSeed)#fragment"))
        let center = DiagnosticsCenter(
            configuration: DiagnosticsConfiguration(
                memoryEventLimit: 16,
                memoryByteLimit: 128 * 1_024,
                supportReportByteLimit: 128 * 1_024),
            clock: FixedClock())

        let operationUUID = try XCTUnwrap(
            UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        await center.record(
            severity: .error,
            subsystem: .filesystem,
            code: .appLaunchABIVerified,
            operationID: DiagnosticOperationID(operationUUID),
            metadata: DiagnosticMetadata([
                .fileType: .file(fullPath),
                .endpoint: .url(credentialURL),
                .failedCount: .integer(1),
                .truncated: .boolean(false),
            ]))

        let first = try await center.supportReportData(
            metadata: reportMetadata,
            generatedAtMilliseconds: 1_700_000_000_999)
        let second = try await center.supportReportData(
            metadata: reportMetadata,
            generatedAtMilliseconds: 1_700_000_000_999)
        XCTAssertEqual(first, second, "identical state and metadata must produce identical bytes")

        let bytes = String(decoding: first, as: UTF8.self)
        for forbidden in [
            noteSeed, environmentSeed, passwordSeed, tokenSeed,
            "/Users/alice", "Private Vault", "alice:", "/private/", "?token=", "#fragment",
        ] {
            XCTAssertFalse(bytes.contains(forbidden), "support report leaked \(forbidden)")
        }
        XCTAssertTrue(bytes.contains("https://example.test"), "the safe URL origin remains useful")
        XCTAssertTrue(bytes.contains("\"md\""), "only the non-sensitive file extension is retained")
        XCTAssertTrue(bytes.contains("0123456789abcdef0123456789abcdef01234567"))
    }

    func testExportIsAtomicPrivateAndByteBounded() async throws {
        let center = DiagnosticsCenter(
            configuration: DiagnosticsConfiguration(
                memoryEventLimit: 100,
                memoryByteLimit: 128 * 1_024,
                supportReportByteLimit: 4_096),
            clock: FixedClock())
        for value in 0..<100 {
            await center.record(
                severity: .debug,
                subsystem: .diagnostics,
                code: .appLaunchABIVerified,
                metadata: DiagnosticMetadata([.attemptedCount: .integer(Int64(value))]))
        }

        let destination = root.appendingPathComponent("MarkDev Support.json")
        let summary = try await center.exportSupportReport(
            to: destination,
            metadata: reportMetadata,
            generatedAtMilliseconds: 1_700_000_000_999)
        let data = try Data(contentsOf: destination)
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        let permissions = try XCTUnwrap((attributes[.posixPermissions] as? NSNumber)?.intValue)

        XCTAssertEqual(data.count, summary.byteCount)
        XCTAssertLessThanOrEqual(data.count, 4_096)
        XCTAssertGreaterThan(summary.omittedEventCount, 0)
        XCTAssertEqual(permissions & 0o777, 0o600)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
    }

    func testCurrentMetadataNeverReadsEnvironmentValues() throws {
        let secret = "CURRENT-METADATA-MUST-NOT-READ-THIS"
        setenv("MARKDEV_DIAGNOSTICS_TEST_SECRET", secret, 1)

        let metadata = DiagnosticReportMetadata.current()
        let data = try DiagnosticsJSON.data(for: metadata)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(secret))
        XCTAssertFalse(metadata.app.name.isEmpty)
        XCTAssertFalse(metadata.operatingSystem.version.isEmpty)
        XCTAssertFalse(metadata.operatingSystem.architecture.isEmpty)
    }

    func testUnknownCodeCannotSmuggleASecretThroughDecodedInput() async throws {
        let secret = "sk-private-code-token-7f4a"
        let encodedCode = try JSONEncoder().encode(secret)
        let decodedCode = try JSONDecoder().decode(DiagnosticCode.self, from: encodedCode)
        XCTAssertEqual(decodedCode, .invalid)

        let center = DiagnosticsCenter(sinks: [], clock: FixedClock())
        await center.record(
            severity: .error,
            subsystem: .diagnostics,
            code: decodedCode)

        let report = try await center.supportReportData(
            metadata: reportMetadata,
            generatedAtMilliseconds: 1_700_000_000_999)
        let text = String(decoding: report, as: UTF8.self)
        XCTAssertFalse(text.contains(secret))
        XCTAssertTrue(text.contains("diagnostics.invalid-code"))
    }

    func testDecodedFileTypeAndMismatchedMetadataCannotSmuggleStrings() throws {
        let secret = "privateextension"
        let encodedFileType = Data(
            "{\"file_type\":{\"kind\":\"file_extension\",\"value\":\"\(secret)\"}}".utf8)
        let decoded = try JSONDecoder().decode(DiagnosticMetadata.self, from: encodedFileType)
        let decodedText = String(decoding: try DiagnosticsJSON.data(for: decoded), as: UTF8.self)
        XCTAssertFalse(decodedText.contains(secret))
        XCTAssertTrue(decodedText.contains("other"))

        let mismatched = DiagnosticMetadata([
            .failedCount: .file(URL(fileURLWithPath: "/Users/alice/private.md"))
        ])
        let mismatchedText = String(
            decoding: try DiagnosticsJSON.data(for: mismatched),
            as: UTF8.self)
        XCTAssertEqual(mismatchedText, "{}")

        let craftedMismatch = Data(
            "{\"failed_count\":{\"kind\":\"boolean\",\"value\":true}}".utf8)
        XCTAssertThrowsError(
            try JSONDecoder().decode(DiagnosticMetadata.self, from: craftedMismatch))
    }

    func testOversizedDecodedStringsCollapseBeforeNormalizationOrExport() throws {
        let oversized = String(repeating: "private", count: 2_048)
        let decodedCode = try JSONDecoder().decode(
            DiagnosticCode.self,
            from: try JSONEncoder().encode(oversized))
        XCTAssertEqual(decodedCode, .invalid)

        let encodedMetadata = try JSONSerialization.data(withJSONObject: [
            "endpoint": [
                "kind": "url_origin",
                "value": "https://example.test/\(oversized)",
            ],
            "file_type": [
                "kind": "file_extension",
                "value": oversized,
            ],
        ])
        let metadata = try JSONDecoder().decode(DiagnosticMetadata.self, from: encodedMetadata)
        let canonical = String(
            decoding: try DiagnosticsJSON.data(for: metadata),
            as: UTF8.self)

        XCTAssertFalse(canonical.contains(oversized))
        XCTAssertTrue(canonical.contains("invalid"))
        XCTAssertTrue(canonical.contains("other"))
    }

    func testTinyReportLimitTruncatesThousandsOfEventsWithExactAccounting() async throws {
        let eventCount = 4_096
        let center = DiagnosticsCenter(
            configuration: DiagnosticsConfiguration(
                memoryEventLimit: eventCount,
                memoryByteLimit: 4 * 1_024 * 1_024,
                supportReportByteLimit: 2_048),
            sinks: [],
            clock: FixedClock())
        for value in 0..<eventCount {
            await center.record(
                severity: .debug,
                subsystem: .diagnostics,
                code: .appLaunchABIVerified,
                metadata: DiagnosticMetadata([.attemptedCount: .integer(Int64(value))]))
        }

        let data = try await center.supportReportData(
            metadata: reportMetadata,
            generatedAtMilliseconds: 1_700_000_000_999)
        let report = try JSONDecoder().decode(DiagnosticSupportReport.self, from: data)

        XCTAssertLessThanOrEqual(data.count, 2_048)
        XCTAssertGreaterThan(report.omittedEventCount, 0)
        XCTAssertEqual(report.includedEventCount + report.omittedEventCount, eventCount)
        XCTAssertEqual(report.events.count, report.includedEventCount)
        XCTAssertEqual(report.events.last?.sequence, UInt64(eventCount))
    }
}
