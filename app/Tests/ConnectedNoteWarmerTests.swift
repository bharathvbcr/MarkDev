//
//  ConnectedNoteWarmerTests.swift
//  MarkDevKitTests
//
//  Reading ahead along a note's links: which notes, and what it does with
//  them once it has them.
//

import AppKit
import XCTest

@testable import MarkDevKit

@MainActor
final class ConnectedNoteWarmerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MarkDevWarmer-\(UUID().uuidString)")
            .appendingPathComponent("Vault")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    @discardableResult
    private func write(_ text: String, to name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func openVault() -> VaultIndex {
        let vault = VaultIndex()
        vault.open(root)
        return vault
    }

    private func context() -> RenderContext {
        RenderContext(width: 600, dark: false, mathFontSize: 16, textColor: .black)
    }

    // MARK: - Which notes

    func testTargetsAreTheNotesTheOpenOneLinksTo() throws {
        try write("# Hub\n\nSee [[Beta]] and [[Gamma]].", to: "Hub.md")
        try write("# Beta", to: "Beta.md")
        try write("# Gamma", to: "Gamma.md")
        let vault = openVault()
        let warmer = ConnectedNoteWarmer(cache: NoteTextCache(), prefetcher: ContentPrefetcher())

        let targets = warmer.targets(from: "Hub.md", in: vault)

        XCTAssertEqual(targets.map(\.lastPathComponent), ["Beta.md", "Gamma.md"])
    }

    func testBrokenLinksAndSelfLinksAreNotTargets() throws {
        // A broken link resolves to nothing, and a note is not a note to read
        // ahead of itself — it is already open.
        try write("# Hub\n\n[[Nowhere]] [[Hub]] [[Beta]]", to: "Hub.md")
        try write("# Beta", to: "Beta.md")
        let vault = openVault()
        let warmer = ConnectedNoteWarmer(cache: NoteTextCache(), prefetcher: ContentPrefetcher())

        XCTAssertEqual(
            warmer.targets(from: "Hub.md", in: vault).map(\.lastPathComponent), ["Beta.md"])
    }

    func testARepeatedLinkIsOneTarget() throws {
        try write("# Hub\n\n[[Beta]] [[Beta]] [[Beta]]", to: "Hub.md")
        try write("# Beta", to: "Beta.md")
        let vault = openVault()
        let warmer = ConnectedNoteWarmer(cache: NoteTextCache(), prefetcher: ContentPrefetcher())

        XCTAssertEqual(warmer.targets(from: "Hub.md", in: vault).count, 1)
    }

    func testTheNumberOfNotesReadAheadIsCapped() throws {
        // A hub note can link at dozens of others. Each is a read, a parse and
        // possibly several bitmaps held against a guess.
        let count = ConnectedNoteWarmer.maximumNotes + 5
        let links = (0..<count).map { "[[Note\($0)]]" }.joined(separator: " ")
        try write("# Hub\n\n\(links)", to: "Hub.md")
        for index in 0..<count {
            try write("# Note\(index)", to: "Note\(index).md")
        }
        let vault = openVault()
        let warmer = ConnectedNoteWarmer(cache: NoteTextCache(), prefetcher: ContentPrefetcher())

        XCTAssertEqual(
            warmer.targets(from: "Hub.md", in: vault).count, ConnectedNoteWarmer.maximumNotes)
    }

    func testANoteOutsideTheVaultHasNoTargets() throws {
        try write("# Hub\n\n[[Beta]]", to: "Hub.md")
        try write("# Beta", to: "Beta.md")
        let vault = openVault()
        let warmer = ConnectedNoteWarmer(cache: NoteTextCache(), prefetcher: ContentPrefetcher())

        XCTAssertTrue(warmer.targets(from: "Elsewhere.md", in: vault).isEmpty)
    }

    // MARK: - What warming does

    func testWarmingReadsLinkedNotesIntoTheCache() async throws {
        try write("# Hub\n\n[[Beta]]", to: "Hub.md")
        let beta = try write("# Beta\n\nBody.", to: "Beta.md")
        let vault = openVault()
        let cache = NoteTextCache()
        let warmer = ConnectedNoteWarmer(cache: cache, prefetcher: ContentPrefetcher())

        await warmer.warm(warmer.targets(from: "Hub.md", in: vault))

        XCTAssertNotNil(cache.cached(beta), "following the link must not need a read")
        XCTAssertEqual(warmer.notesWarmed, 1)
    }

    func testWarmingQueuesThePicturesOfALinkedNote() async throws {
        try write("# Hub\n\n[[Beta]]", to: "Hub.md")
        try write("# Beta\n\n$$\nE = mc^2\n$$\n", to: "Beta.md")
        let vault = openVault()
        let renderer = RichContentRenderer()
        let prefetcher = ContentPrefetcher(renderer: renderer)
        let warmer = ConnectedNoteWarmer(cache: NoteTextCache(), prefetcher: prefetcher)
        // The prefetcher renders connected notes in the open document's
        // context, so there has to be one.
        prefetcher.warmDocument([], in: nil, using: context())

        await warmer.warm(warmer.targets(from: "Hub.md", in: vault))
        while prefetcher.step() {}

        XCTAssertGreaterThan(prefetcher.warmed, 0, "the linked note's formula should be drawn")
    }

    func testAnUnreadableLinkedNoteIsAWarmThatSimplyDoesNotHappen() async throws {
        try write("# Hub\n\n[[Beta]]", to: "Hub.md")
        let beta = try write("# Beta", to: "Beta.md")
        let vault = openVault()
        let targets = ConnectedNoteWarmer(
            cache: NoteTextCache(), prefetcher: ContentPrefetcher()
        ).targets(from: "Hub.md", in: vault)
        // Deleted after the index read it, which is the ordinary way a vault
        // and the disk disagree.
        try FileManager.default.removeItem(at: beta)

        let cache = NoteTextCache()
        let warmer = ConnectedNoteWarmer(cache: cache, prefetcher: ContentPrefetcher())
        await warmer.warm(targets)

        XCTAssertNil(cache.cached(beta))
    }

    func testWarmingFromOutsideTheVaultCancelsRatherThanLeavingTheLastOneRunning() throws {
        try write("# Hub\n\n[[Beta]]", to: "Hub.md")
        try write("# Beta", to: "Beta.md")
        let vault = openVault()
        let warmer = ConnectedNoteWarmer(cache: NoteTextCache(), prefetcher: ContentPrefetcher())

        warmer.warm(from: root.appendingPathComponent("Hub.md"), in: vault)
        warmer.warm(from: URL(fileURLWithPath: "/elsewhere/Standalone.md"), in: vault)

        // Nothing observable but the absence of a crash and of a later warm;
        // the assertion that matters is that the second call did not queue the
        // first document's links behind a file the vault knows nothing about.
        XCTAssertTrue(warmer.targets(from: "Standalone.md", in: vault).isEmpty)
    }

    func testTheWarmerDrivesItselfAfterTheDebounce() async throws {
        try write("# Hub\n\n[[Beta]]", to: "Hub.md")
        let beta = try write("# Beta\n\nBody.", to: "Beta.md")
        let vault = openVault()
        let cache = NoteTextCache()
        let warmer = ConnectedNoteWarmer(cache: cache, prefetcher: ContentPrefetcher())

        warmer.warm(from: root.appendingPathComponent("Hub.md"), in: vault)

        let deadline = Date().addingTimeInterval(5)
        while cache.cached(beta) == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNotNil(cache.cached(beta), "the debounced warm should have run on its own")
    }
}
