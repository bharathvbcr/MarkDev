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
    private let origin = DiagnosticOrigin(
        validatedRunID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
        processID: 42,
        role: .testHost,
        locality: .ephemeralTest)

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
            origin: origin,
            localSequence: sequence,
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

    func testRemoteAuthorityCannotAliasALocalDiagnosticsDirectory() throws {
        let hostile = try XCTUnwrap(
            URL(string: "file://remote.example\(root.path)/"))
        let configuration = RotatingDiagnosticsFileConfiguration(directory: hostile)

        XCTAssertThrowsError(
            try RotatingJSONLDiagnosticsSink(
                configuration: configuration,
                requiredOrigin: origin)
        ) { error in
            XCTAssertEqual(
                error as? RotatingDiagnosticsFileError,
                .pathIsNotDirectory)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testDirectoryInventoryFailsClosedAtItsBoundWithoutMaterializingTheTail() throws {
        for index in 0...RotatingJSONLDiagnosticsSink.maximumInspectedDirectoryEntries {
            let created = FileManager.default.createFile(
                atPath: root.appendingPathComponent("unowned-\(index)").path,
                contents: Data())
            XCTAssertTrue(created)
        }
        let configuration = RotatingDiagnosticsFileConfiguration(directory: root)

        XCTAssertThrowsError(
            try RotatingJSONLDiagnosticsSink(
                configuration: configuration,
                requiredOrigin: origin)
        ) { error in
            XCTAssertEqual(
                error as? RotatingDiagnosticsFileError,
                .incompatibleExistingSegment)
        }
    }

    func testRotationBoundsEveryFileAndRetainsOnlyTheNewestGenerations() async throws {
        let oneLine = try record(sequence: 1).jsonLine.count
        let configuration = RotatingDiagnosticsFileConfiguration(
            directory: root,
            baseName: "events",
            maximumFileBytes: oneLine * 2,
            maximumFiles: 3)
        let sink = try RotatingJSONLDiagnosticsSink(
            configuration: configuration,
            requiredOrigin: origin)
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
                allSequences.append(try XCTUnwrap(
                    (object?["localSequence"] as? NSNumber)?.uint64Value))
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

        let sink = try RotatingJSONLDiagnosticsSink(
            configuration: configuration,
            requiredOrigin: origin)
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

        XCTAssertThrowsError(try RotatingJSONLDiagnosticsSink(
            configuration: configuration,
            requiredOrigin: origin))
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

        XCTAssertThrowsError(try RotatingJSONLDiagnosticsSink(
            configuration: configuration,
            requiredOrigin: origin))
        XCTAssertEqual(try Data(contentsOf: victim), secret)
    }

    func testHardLinkedGenerationIsRejectedWithoutChangingItsOtherName() throws {
        let configuration = RotatingDiagnosticsFileConfiguration(
            directory: root,
            baseName: "events",
            maximumFileBytes: 4_096,
            maximumFiles: 2)
        let victim = root.deletingLastPathComponent()
            .appendingPathComponent("MarkDevDiagnosticsVictim-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: victim) }
        let original = try record(sequence: 1).jsonLine
        try original.write(to: victim)
        try FileManager.default.linkItem(at: victim, to: configuration.fileURL(at: 0))

        XCTAssertThrowsError(try RotatingJSONLDiagnosticsSink(
            configuration: configuration,
            requiredOrigin: origin)) { error in
            XCTAssertEqual(
                error as? RotatingDiagnosticsFileError,
                .incompatibleExistingSegment)
        }
        XCTAssertEqual(try Data(contentsOf: victim), original)
    }

    func testHardLinkedGenerationInsertedAfterInitializationIsNeverAppended() async throws {
        let configuration = RotatingDiagnosticsFileConfiguration(
            directory: root,
            baseName: "events",
            maximumFileBytes: 4_096,
            maximumFiles: 2)
        let sink = try RotatingJSONLDiagnosticsSink(
            configuration: configuration,
            requiredOrigin: origin)
        let victim = root.deletingLastPathComponent()
            .appendingPathComponent("MarkDevDiagnosticsVictim-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: victim) }
        let original = try record(sequence: 1).jsonLine
        try original.write(to: victim)
        try FileManager.default.linkItem(at: victim, to: configuration.fileURL(at: 0))

        do {
            try await sink.write(try record(sequence: 2))
            XCTFail("a hard-linked generation must not be appended")
        } catch {
            XCTAssertEqual(
                error as? RotatingDiagnosticsFileError,
                .incompatibleExistingSegment)
        }
        XCTAssertEqual(try Data(contentsOf: victim), original)
    }

    func testRotationRefusesAReplacedDirectoryWithoutTouchingTheReplacement() async throws {
        let selected = root.appendingPathComponent("selected", isDirectory: true)
        let movedSelection = root.appendingPathComponent("moved-selected", isDirectory: true)
        let replacement = root.appendingPathComponent("replacement", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: false)
        let first = try record(sequence: 1)
        let configuration = RotatingDiagnosticsFileConfiguration(
            directory: selected,
            baseName: "events",
            maximumFileBytes: first.jsonLine.count,
            maximumFiles: 2)
        let hooks = RotatingDiagnosticsSinkTestingHooks(beforeRotationMutation: {
            try FileManager.default.moveItem(at: selected, to: movedSelection)
            try FileManager.default.moveItem(at: replacement, to: selected)
        })
        let sink = try RotatingJSONLDiagnosticsSink(
            configuration: configuration,
            requiredOrigin: origin,
            testingHooks: hooks)
        try await sink.write(first)

        do {
            try await sink.write(try record(sequence: 2))
            XCTFail("rotation must refuse a replaced diagnostics directory")
        } catch {
            XCTAssertEqual(
                error as? RotatingDiagnosticsFileError,
                .fileChangedDuringWrite)
        }

        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: selected.path).isEmpty)
        XCTAssertEqual(
            try Data(contentsOf: movedSelection.appendingPathComponent("events.jsonl")),
            first.jsonLine)
    }

    func testRotationRefusesAReplacedGenerationWithoutMovingOrDeletingIt() async throws {
        let first = try record(sequence: 1)
        let configuration = RotatingDiagnosticsFileConfiguration(
            directory: root,
            baseName: "events",
            maximumFileBytes: first.jsonLine.count,
            maximumFiles: 2)
        let active = configuration.fileURL(at: 0)
        let savedActive = root.appendingPathComponent("saved-active.jsonl")
        let replacement = root.appendingPathComponent("replacement.jsonl")
        let replacementBytes = Data("replacement-must-survive".utf8)
        let hooks = RotatingDiagnosticsSinkTestingHooks(beforeRotationMutation: {
            try FileManager.default.moveItem(at: active, to: savedActive)
            try FileManager.default.moveItem(at: replacement, to: active)
        })
        let sink = try RotatingJSONLDiagnosticsSink(
            configuration: configuration,
            requiredOrigin: origin,
            testingHooks: hooks)
        try replacementBytes.write(to: replacement)
        try await sink.write(first)

        do {
            try await sink.write(try record(sequence: 2))
            XCTFail("rotation must refuse a generation replaced after inventory")
        } catch {
            XCTAssertEqual(
                error as? RotatingDiagnosticsFileError,
                .fileChangedDuringWrite)
        }

        XCTAssertEqual(try Data(contentsOf: active), replacementBytes)
        XCTAssertEqual(try Data(contentsOf: savedActive), first.jsonLine)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: configuration.fileURL(at: 1).path))
    }

    func testOversizedRecordIsRejectedWithoutCreatingAnActiveFile() async throws {
        let oversized = try record(sequence: 1)
        let configuration = RotatingDiagnosticsFileConfiguration(
            directory: root,
            baseName: "events",
            maximumFileBytes: oversized.jsonLine.count - 1,
            maximumFiles: 2)
        let sink = try RotatingJSONLDiagnosticsSink(
            configuration: configuration,
            requiredOrigin: origin)

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

    func testInvalidCompleteLineQuarantinesTheWholeSegmentWithoutChangingBytes() throws {
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

        XCTAssertThrowsError(try RotatingJSONLDiagnosticsSink(
            configuration: configuration,
            requiredOrigin: origin)) { error in
            XCTAssertEqual(
                error as? RotatingDiagnosticsFileError,
                .incompatibleExistingSegment)
        }

        XCTAssertEqual(try Data(contentsOf: configuration.fileURL(at: 0)), damaged)
    }

    func testSinkReencodesTheEventInsteadOfTrustingInjectedRecordBytes() async throws {
        let configuration = RotatingDiagnosticsFileConfiguration(
            directory: root,
            baseName: "events",
            maximumFileBytes: 64 * 1_024,
            maximumFiles: 2)
        let sink = try RotatingJSONLDiagnosticsSink(
            configuration: configuration,
            requiredOrigin: origin)
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
        let sink = try RotatingJSONLDiagnosticsSink(
            configuration: configuration,
            requiredOrigin: origin)
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

        _ = try RotatingJSONLDiagnosticsSink(
            configuration: configuration,
            requiredOrigin: origin)

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleTemporary.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: overflowGeneration.path))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("unrelated".utf8))
    }

    func testPruningRefusesAReplacedDirectoryWithoutTouchingTheReplacement() throws {
        let selected = root.appendingPathComponent("selected", isDirectory: true)
        let movedSelection = root.appendingPathComponent("moved-selected", isDirectory: true)
        let replacement = root.appendingPathComponent("replacement", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: false)
        let overflowName = "events.9.jsonl"
        let overflow = selected.appendingPathComponent(overflowName)
        let overflowBytes = Data("owned-overflow".utf8)
        try overflowBytes.write(to: overflow)
        let configuration = RotatingDiagnosticsFileConfiguration(
            directory: selected,
            baseName: "events",
            maximumFileBytes: 4_096,
            maximumFiles: 2)
        let hooks = RotatingDiagnosticsSinkTestingHooks(beforePruneMutation: { name in
            XCTAssertEqual(name, overflowName)
            try FileManager.default.moveItem(at: selected, to: movedSelection)
            try FileManager.default.moveItem(at: replacement, to: selected)
        })

        XCTAssertThrowsError(try RotatingJSONLDiagnosticsSink(
            configuration: configuration,
            requiredOrigin: origin,
            testingHooks: hooks)) { error in
            XCTAssertEqual(
                error as? RotatingDiagnosticsFileError,
                .fileChangedDuringWrite)
        }

        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: selected.path).isEmpty)
        XCTAssertEqual(
            try Data(contentsOf: movedSelection.appendingPathComponent(overflowName)),
            overflowBytes)
    }

    func testPruningRefusesAReplacedCandidateWithoutDeletingTheNewEntry() throws {
        let overflowName = "events.9.jsonl"
        let overflow = root.appendingPathComponent(overflowName)
        let savedOverflow = root.appendingPathComponent("saved-overflow.jsonl")
        let replacement = root.appendingPathComponent("replacement.jsonl")
        let overflowBytes = Data("owned-overflow".utf8)
        let replacementBytes = Data("replacement-must-survive".utf8)
        try overflowBytes.write(to: overflow)
        try replacementBytes.write(to: replacement)
        let configuration = RotatingDiagnosticsFileConfiguration(
            directory: root,
            baseName: "events",
            maximumFileBytes: 4_096,
            maximumFiles: 2)
        let hooks = RotatingDiagnosticsSinkTestingHooks(beforePruneMutation: { name in
            XCTAssertEqual(name, overflowName)
            try FileManager.default.moveItem(at: overflow, to: savedOverflow)
            try FileManager.default.moveItem(at: replacement, to: overflow)
        })

        XCTAssertThrowsError(try RotatingJSONLDiagnosticsSink(
            configuration: configuration,
            requiredOrigin: origin,
            testingHooks: hooks)) { error in
            XCTAssertEqual(
                error as? RotatingDiagnosticsFileError,
                .fileChangedDuringWrite)
        }

        XCTAssertEqual(try Data(contentsOf: overflow), replacementBytes)
        XCTAssertEqual(try Data(contentsOf: savedOverflow), overflowBytes)
    }
}
