//
//  DiagnosticsFileSinkTests.swift
//  MarkDevKitTests
//
//  Rotation, file permissions, and crash-tail recovery for durable JSONL.
//

import Foundation
import XCTest

@testable import MarkDevKit

final class DiagnosticsFileSinkTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevDiagnostics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func event(sequence: UInt64) -> DiagnosticEvent {
        DiagnosticEvent(
            sequence: sequence,
            timestampMilliseconds: 1_700_000_000_123,
            uptimeNanoseconds: sequence,
            severity: .info,
            subsystem: .diagnostics,
            code: .appLaunchABIVerified,
            operationID: nil,
            metadata: DiagnosticMetadata([.attemptedCount: .integer(Int64(sequence))]))
    }

    private func record(sequence: UInt64) throws -> DiagnosticRecord {
        let event = event(sequence: sequence)
        return DiagnosticRecord(event: event, jsonLine: try DiagnosticsJSON.line(for: event))
    }

    func testRotationBoundsEveryFileAndRetainsOnlyTheNewestGenerations() async throws {
        let oneLine = try record(sequence: 1).jsonLine.count
        let configuration = RotatingDiagnosticsFileConfiguration(
            directory: root,
            baseName: "events",
            maximumFileBytes: oneLine * 2,
            maximumFiles: 3)
        let sink = try RotatingJSONLDiagnosticsSink(configuration: configuration)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: root.path)
        let directoryPermissions = try XCTUnwrap(
            (directoryAttributes[.posixPermissions] as? NSNumber)?.intValue)
        XCTAssertEqual(directoryPermissions & 0o777, 0o700)

        for sequence in UInt64(1)...7 {
            try await sink.write(record(sequence: sequence))
        }

        let files = await sink.existingFiles()
        XCTAssertEqual(files.count, 3)
        var allSequences: [UInt64] = []
        for file in files {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            let size = try XCTUnwrap((attributes[.size] as? NSNumber)?.intValue)
            let permissions = try XCTUnwrap((attributes[.posixPermissions] as? NSNumber)?.intValue)
            XCTAssertLessThanOrEqual(size, configuration.maximumFileBytes)
            XCTAssertEqual(permissions & 0o777, 0o600)

            let data = try Data(contentsOf: file)
            for line in data.split(separator: 0x0A) {
                let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
                allSequences.append(try XCTUnwrap((object?["sequence"] as? NSNumber)?.uint64Value))
            }
        }
        XCTAssertTrue(allSequences.contains(7), "the newest event must survive rotation")
        XCTAssertFalse(allSequences.contains(1), "the oldest generation must be removed at the file cap")
    }

    func testPartialTailIsTruncatedBeforeTheNextAppend() async throws {
        let configuration = RotatingDiagnosticsFileConfiguration(
            directory: root,
            baseName: "events",
            maximumFileBytes: 64 * 1_024,
            maximumFiles: 2)
        let valid = try record(sequence: 1).jsonLine
        var damaged = valid
        damaged.append(Data("{\"sequence\":2,\"unterminated\"".utf8))
        try damaged.write(to: configuration.fileURL(at: 0))

        let sink = try RotatingJSONLDiagnosticsSink(configuration: configuration)
        XCTAssertEqual(try Data(contentsOf: configuration.fileURL(at: 0)), valid)

        try await sink.write(record(sequence: 2))
        let recovered = try Data(contentsOf: configuration.fileURL(at: 0))
        let lines = recovered.split(separator: 0x0A)
        XCTAssertEqual(lines.count, 2)
        for line in lines {
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line)))
        }
    }

    func testARegularFileCannotMasqueradeAsTheSinkDirectory() throws {
        let notDirectory = root.appendingPathComponent("not-a-directory")
        try Data("occupied".utf8).write(to: notDirectory)
        let configuration = RotatingDiagnosticsFileConfiguration(
            directory: notDirectory,
            baseName: "events",
            maximumFileBytes: 4_096,
            maximumFiles: 2)

        XCTAssertThrowsError(try RotatingJSONLDiagnosticsSink(configuration: configuration))
    }

    func testSymlinkGenerationIsRejectedWithoutReadingOrChangingItsTarget() throws {
        let diagnosticsDirectory = root.appendingPathComponent("diagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: diagnosticsDirectory, withIntermediateDirectories: false)
        let victim = root.appendingPathComponent("victim.txt")
        let secret = Data("PRIVATE-SYMLINK-TARGET-7F4A".utf8)
        try secret.write(to: victim)
        let configuration = RotatingDiagnosticsFileConfiguration(
            directory: diagnosticsDirectory,
            baseName: "events",
            maximumFileBytes: 4_096,
            maximumFiles: 2)
        try FileManager.default.createSymbolicLink(
            at: configuration.fileURL(at: 0),
            withDestinationURL: victim)

        XCTAssertThrowsError(try RotatingJSONLDiagnosticsSink(configuration: configuration))
        XCTAssertEqual(try Data(contentsOf: victim), secret)
    }

    func testOversizedRecordIsRejectedWithoutCreatingAnActiveFile() async throws {
        let oversized = try record(sequence: 1)
        let configuration = RotatingDiagnosticsFileConfiguration(
            directory: root,
            baseName: "events",
            maximumFileBytes: oversized.jsonLine.count - 1,
            maximumFiles: 2)
        let sink = try RotatingJSONLDiagnosticsSink(configuration: configuration)

        do {
            try await sink.write(oversized)
            XCTFail("an oversized record must be rejected")
        } catch let error as RotatingDiagnosticsFileError {
            XCTAssertEqual(
                error,
                .recordExceedsFileLimit(
                    limit: oversized.jsonLine.count - 1,
                    actual: oversized.jsonLine.count))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: configuration.fileURL(at: 0).path))
    }

    func testRecoveryStopsAtTheFirstInvalidCompleteLine() throws {
        let configuration = RotatingDiagnosticsFileConfiguration(
            directory: root,
            baseName: "events",
            maximumFileBytes: 64 * 1_024,
            maximumFiles: 2)
        let first = try record(sequence: 1).jsonLine
        let later = try record(sequence: 2).jsonLine
        var damaged = first
        damaged.append(Data("{\"invalid\":true}\n".utf8))
        damaged.append(later)
        try damaged.write(to: configuration.fileURL(at: 0))

        _ = try RotatingJSONLDiagnosticsSink(configuration: configuration)

        XCTAssertEqual(try Data(contentsOf: configuration.fileURL(at: 0)), first)
    }

    func testSinkReencodesTheEventInsteadOfTrustingInjectedRecordBytes() async throws {
        let configuration = RotatingDiagnosticsFileConfiguration(
            directory: root,
            baseName: "events",
            maximumFileBytes: 64 * 1_024,
            maximumFiles: 2)
        let sink = try RotatingJSONLDiagnosticsSink(configuration: configuration)
        let secret = "PRIVATE-INJECTED-RECORD-BYTES-9C2D"
        let untrusted = DiagnosticRecord(
            event: event(sequence: 1),
            jsonLine: Data(secret.utf8))

        try await sink.write(untrusted)

        let persisted = try Data(contentsOf: configuration.fileURL(at: 0))
        XCTAssertFalse(String(decoding: persisted, as: UTF8.self).contains(secret))
        XCTAssertEqual(
            try JSONDecoder().decode(
                DiagnosticEvent.self,
                from: Data(persisted.dropLast())),
            event(sequence: 1))
    }

    func testConcurrentWritersProduceOnlyCompleteUniqueLines() async throws {
        let configuration = RotatingDiagnosticsFileConfiguration(
            directory: root,
            baseName: "events",
            maximumFileBytes: 1 * 1_024 * 1_024,
            maximumFiles: 2)
        let sink = try RotatingJSONLDiagnosticsSink(configuration: configuration)
        let eventCount = 200
        let records = try (UInt64(1)...UInt64(eventCount)).map {
            try record(sequence: $0)
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for record in records {
                group.addTask {
                    try await sink.write(record)
                }
            }
            try await group.waitForAll()
        }

        let persisted = try Data(contentsOf: configuration.fileURL(at: 0))
        let events = try persisted.split(separator: 0x0A).map {
            try JSONDecoder().decode(DiagnosticEvent.self, from: Data($0))
        }
        XCTAssertEqual(events.count, eventCount)
        XCTAssertEqual(Set(events.map(\.sequence)), Set(UInt64(1)...UInt64(eventCount)))
    }

    func testInitializationPrunesOwnedCrashTempsAndOverflowGenerationsOnly() throws {
        let configuration = RotatingDiagnosticsFileConfiguration(
            directory: root,
            baseName: "events",
            maximumFileBytes: 4_096,
            maximumFiles: 2)
        let staleTemporary = root.appendingPathComponent(
            ".events.jsonl.AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE.tmp")
        let overflowGeneration = root.appendingPathComponent(
            "events.999999999999999999999999999999999999999999999999.jsonl")
        let unrelated = root.appendingPathComponent("keep-me.txt")
        try Data("stale".utf8).write(to: staleTemporary)
        try Data("old".utf8).write(to: overflowGeneration)
        try Data("unrelated".utf8).write(to: unrelated)

        _ = try RotatingJSONLDiagnosticsSink(configuration: configuration)

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleTemporary.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: overflowGeneration.path))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("unrelated".utf8))
    }
}
