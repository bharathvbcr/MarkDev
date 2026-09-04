//
//  CommandPaletteSearchTests.swift
//  MarkDevKitTests
//
//  Bounded, render-safe palette content-search state.
//

import XCTest

@testable import MarkDevKit

final class CommandPaletteSearchStateTests: XCTestCase {
    private func result(_ name: String) -> Command {
        Command(
            title: name,
            symbol: "magnifyingglass",
            kind: .searchResult(URL(fileURLWithPath: "/vault/\(name).md"), line: 1))
    }

    func testSameQueryWithANewerIndexRevisionInvalidatesOldHits() {
        let old = CommandPaletteSearchRequest(
            query: "needle", contentRevision: 10, shouldSearch: true)
        let current = CommandPaletteSearchRequest(
            query: "needle", contentRevision: 11, shouldSearch: true)
        var state = CommandPaletteSearchState()
        let oldGeneration = state.begin(old)
        XCTAssertTrue(
            state.complete([result("Old")], for: old, generation: oldGeneration, limit: 8))

        let currentGeneration = state.begin(current)

        XCTAssertTrue(state.hits(for: current).isEmpty)
        XCTAssertTrue(state.isLoading(current))
        XCTAssertFalse(
            state.complete([result("Stale")], for: old, generation: oldGeneration, limit: 8))
        XCTAssertTrue(
            state.complete([result("Current")], for: current, generation: currentGeneration, limit: 8))
        XCTAssertEqual(state.hits(for: current).map(\.title), ["Current"])
    }

    func testEligibleSearchIsPendingBeforeItsTaskBeginsButIneligibleSearchIsNot() {
        let eligible = CommandPaletteSearchRequest(
            query: "note", contentRevision: 1, shouldSearch: true)
        let ineligible = CommandPaletteSearchRequest(
            query: "n", contentRevision: 1, shouldSearch: false)
        let state = CommandPaletteSearchState()

        XCTAssertTrue(state.isPending(eligible))
        XCTAssertFalse(state.isPending(ineligible))
    }

    func testRapidQueryReplacementRejectsTheCancelledQueryCompletion() {
        let first = CommandPaletteSearchRequest(
            query: "alpha", contentRevision: 3, shouldSearch: true)
        let second = CommandPaletteSearchRequest(
            query: "beta", contentRevision: 3, shouldSearch: true)
        var state = CommandPaletteSearchState()
        let firstGeneration = state.begin(first)
        let secondGeneration = state.begin(second)

        XCTAssertFalse(
            state.complete([result("Alpha")], for: first, generation: firstGeneration, limit: 8))
        XCTAssertTrue(state.hits(for: second).isEmpty)
        XCTAssertTrue(
            state.complete([result("Beta")], for: second, generation: secondGeneration, limit: 8))
        XCTAssertEqual(state.hits(for: second).map(\.title), ["Beta"])
    }

    func testContentHitsStayBoundedAtTheStateBoundary() {
        let request = CommandPaletteSearchRequest(
            query: "note", contentRevision: 1, shouldSearch: true)
        var state = CommandPaletteSearchState()
        let generation = state.begin(request)

        XCTAssertTrue(
            state.complete(
                (0..<100).map { result("Note \($0)") },
                for: request,
                generation: generation,
                limit: 8))
        XCTAssertEqual(state.hits(for: request).count, 8)
    }

    func testResetInvalidatesAnInFlightContentSearch() {
        let request = CommandPaletteSearchRequest(
            query: "note", contentRevision: 1, shouldSearch: true)
        var state = CommandPaletteSearchState()
        let generation = state.begin(request)

        state.reset()

        XCTAssertFalse(
            state.complete([result("Late")], for: request, generation: generation, limit: 8))
        XCTAssertTrue(state.hits(for: request).isEmpty)
        XCTAssertFalse(state.isLoading(request))
    }

    func testReadingHitsRepeatedlyDoesNotAdvanceOrMutateSearchState() {
        let request = CommandPaletteSearchRequest(
            query: "note", contentRevision: 1, shouldSearch: true)
        var state = CommandPaletteSearchState()
        let generation = state.begin(request)
        _ = state.complete([result("One")], for: request, generation: generation, limit: 8)
        let revision = state.generation

        XCTAssertEqual(state.hits(for: request).map(\.title), ["One"])
        XCTAssertEqual(state.hits(for: request).map(\.title), ["One"])
        XCTAssertEqual(state.generation, revision, "render-time reads must not mutate the cache")
    }
}
