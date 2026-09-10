import Observation
import XCTest

@testable import MarkDevKit

@MainActor
final class SavedVaultStoreTests: XCTestCase {
    private func makeDefaults() throws -> UserDefaults {
        let name = "MarkDev.SavedVaultTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testSavedFoldersSurviveRelaunchWithoutChangingSessionOrFiles() throws {
        let defaults = try makeDefaults()
        defaults.set("existing session", forKey: "session.workspace")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SavedVault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let note = root.appendingPathComponent("Note.md")
        try "# Keep me".write(to: note, atomically: true, encoding: .utf8)

        let store = SavedVaultStore(defaults: defaults)
        XCTAssertTrue(store.vaults.isEmpty)
        try store.save(root)
        let reloaded = SavedVaultStore(defaults: defaults)
        XCTAssertEqual(reloaded.vaults, store.vaults)
        let saved = try XCTUnwrap(reloaded.vaults.first)
        XCTAssertEqual(saved.name, root.lastPathComponent)
        XCTAssertTrue(reloaded.contains(root))
        try reloaded.remove(saved)
        XCTAssertTrue(SavedVaultStore(defaults: defaults).vaults.isEmpty)
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "# Keep me")
        XCTAssertEqual(defaults.string(forKey: "session.workspace"), "existing session")
    }

    func testDuplicateSpellingsAreIdempotentAndSameNamesRemainDistinct() throws {
        let store = SavedVaultStore(defaults: try makeDefaults())
        try store.save(URL(fileURLWithPath: "/Users/test/Work/Notes"))
        try store.save(URL(fileURLWithPath: "/Users/test/Work/./Notes/"))
        try store.save(try XCTUnwrap(URL(string: "file:///Users//test/Work/Notes/")))
        try store.save(try XCTUnwrap(URL(string: "file:///Users/test/Work/Temp/../Notes/")))
        try store.save(URL(fileURLWithPath: "/Users/test/Personal/Notes"))
        XCTAssertEqual(store.vaults.count, 2)
        XCTAssertEqual(Set(store.vaults.map(\.name)), ["Notes"])
        XCTAssertEqual(Set(store.vaults.map(\.id)).count, 2)
        let before = store.vaults
        try store.save(URL(fileURLWithPath: "/Users/test/Work/Notes/"))
        XCTAssertEqual(store.vaults, before, "saving twice must not reorder or duplicate entries")
    }

    func testMissingFoldersRemainSavedAcrossRelaunch() throws {
        let defaults = try makeDefaults()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = SavedVaultStore(defaults: defaults)
        try store.save(root)
        try FileManager.default.removeItem(at: root)
        XCTAssertEqual(SavedVaultStore(defaults: defaults).vaults, store.vaults)
    }

    func testPersistedFolderReopensThroughTheVaultRegistryAndMissingFolderFails() async throws {
        let defaults = try makeDefaults()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "# Reopened".write(
            to: root.appendingPathComponent("Reopened.md"), atomically: true, encoding: .utf8)
        let index = try await VaultIndexRegistry().indexAsync(for: root)
        try SavedVaultStore(defaults: defaults).save(try XCTUnwrap(index.root))

        let restored = SavedVaultStore(defaults: defaults)
        let saved = try XCTUnwrap(restored.vaults.first)
        let reopened = try await VaultIndexRegistry().indexAsync(for: saved.url)
        XCTAssertEqual(reopened.root, saved.url)
        XCTAssertEqual(reopened.notePaths(), ["Reopened.md"])

        try FileManager.default.removeItem(at: root)
        do {
            _ = try await VaultIndexRegistry().indexAsync(for: saved.url)
            XCTFail("a saved location must not make a missing folder appear to open")
        } catch {
            XCTAssertTrue(restored.contains(saved.url), "failure must retain the saved entry")
        }
    }

    func testInvalidAuthoritiesAreRejectedBeforeNormalizationWithoutChangingStorage() throws {
        let defaults = try makeDefaults()
        let store = SavedVaultStore(defaults: defaults)
        try store.save(URL(fileURLWithPath: "/Users/test/Notes"))
        let before = defaults.data(forKey: SavedVaultStore.key)
        for raw in [
            "https://example.com/vault", "file://remote.example/Users/test/Notes",
            "file:relative", "file:///tmp/Notes?query=1", "file:///tmp/Notes#fragment",
            "file:///tmp/Bad%00Name", "file://user@localhost/tmp/Notes",
        ] {
            let url = try XCTUnwrap(URL(string: raw))
            XCTAssertThrowsError(try store.save(url), raw)
            XCTAssertFalse(store.contains(url), raw)
            XCTAssertEqual(defaults.data(forKey: SavedVaultStore.key), before)
        }
    }

    func testLimitRejectsAdditionalVaultWithoutEvictingAnExistingOne() throws {
        let defaults = try makeDefaults()
        let store = SavedVaultStore(defaults: defaults)
        for index in 0..<SavedVaultStore.maximumVaults {
            try store.save(URL(fileURLWithPath: "/Users/test/Vault-\(index)"))
        }
        let before = store.vaults
        XCTAssertThrowsError(try store.save(URL(fileURLWithPath: "/Users/test/OneMore")))
        XCTAssertEqual(store.vaults, before)
        try store.save(try XCTUnwrap(store.vaults.first).url)
        XCTAssertEqual(store.vaults, before)
        try store.remove(try XCTUnwrap(store.vaults.last))
        try store.save(URL(fileURLWithPath: "/Users/test/OneMore"))
        XCTAssertEqual(SavedVaultStore(defaults: defaults).vaults.count, SavedVaultStore.maximumVaults)
    }

    func testLiteralPercentEscapesAndUnicodeFolderNamesRoundTrip() throws {
        let defaults = try makeDefaults()
        let root = URL(fileURLWithPath: "/Users/test/研究 %00 Notes", isDirectory: true)
        let store = SavedVaultStore(defaults: defaults)
        try store.save(root)
        XCTAssertEqual(store.vaults.first?.url, root)
        XCTAssertEqual(SavedVaultStore(defaults: defaults).vaults, store.vaults)
    }

    func testCorruptOrOversizedStorageIsReportedAndPreservedUntilExplicitReset() throws {
        let defaults = try makeDefaults()
        let invalidPayloads: [Data] = [
            Data("not json".utf8),
            Data(repeating: 32, count: SavedVaultStore.maximumEncodedBytes + 1),
            try JSONEncoder().encode(["file://remote.example/tmp/Notes"]),
            try JSONEncoder().encode(["file:///tmp/Bad%00Name"]),
            try JSONEncoder().encode(Array(repeating: "file:///tmp/Vault/", count: SavedVaultStore.maximumVaults + 1)),
            try JSONEncoder().encode(["file:///tmp/" + String(repeating: "a", count: SavedVaultStore.maximumURLBytes)]),
        ]
        for data in invalidPayloads {
            defaults.set(data, forKey: SavedVaultStore.key)
            let store = SavedVaultStore(defaults: defaults)
            XCTAssertNotNil(store.loadError)
            XCTAssertTrue(store.vaults.isEmpty)
            XCTAssertThrowsError(try store.save(URL(fileURLWithPath: "/tmp/Replacement")))
            XCTAssertEqual(defaults.data(forKey: SavedVaultStore.key), data)
            store.reset()
            XCTAssertNil(store.loadError)
            XCTAssertNil(defaults.object(forKey: SavedVaultStore.key))
            try store.save(URL(fileURLWithPath: "/tmp/Replacement"))
            XCTAssertEqual(store.vaults.count, 1)
        }
        defaults.set("wrong type", forKey: SavedVaultStore.key)
        XCTAssertNotNil(SavedVaultStore(defaults: defaults).loadError)
    }

    func testLoadingDeduplicatesCanonicalURLs() throws {
        let defaults = try makeDefaults()
        defaults.set(try JSONEncoder().encode([
            "file:///Users/test/Notes/", "file:///Users/test/./Notes",
            "file:///Users/test/Other/",
        ]), forKey: SavedVaultStore.key)
        let store = SavedVaultStore(defaults: defaults)
        XCTAssertNil(store.loadError)
        XCTAssertEqual(store.vaults.map(\.name), ["Notes", "Other"])
    }

    func testSharedStorePublishesChangesToObservingWindows() throws {
        let store = SavedVaultStore(defaults: try makeDefaults())
        let changed = expectation(description: "another window observes the saved list")
        withObservationTracking {
            _ = store.vaults
        } onChange: {
            changed.fulfill()
        }
        try store.save(URL(fileURLWithPath: "/Users/test/Notes"))
        wait(for: [changed], timeout: 1)
    }
}
