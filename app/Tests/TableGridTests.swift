//
//  TableGridTests.swift
//  MarkDevKitTests
//
//  The column solver's rules, asserted as properties.
//
//  These are the guarantees the drawing layer relies on and cannot check for
//  itself: a table never exceeds the width it was given, a column never
//  shrinks below the word that cannot be broken, and a narrow column does not
//  pay for a wide one's greed.
//

import XCTest

@testable import MarkDevKit

final class TableGridTests: XCTestCase {
    private func demand(
        _ natural: CGFloat, min minimum: CGFloat, _ alignment: TableAlignment = .auto
    ) -> TableColumnDemand {
        TableColumnDemand(natural: natural, minimum: minimum, alignment: alignment)
    }

    // MARK: - Fitting

    func testATableThatFitsGetsExactlyWhatItAsksFor() {
        let grid = TableGrid.solve(
            demands: [demand(100, min: 40), demand(200, min: 50)],
            available: 500, gap: 18)

        XCTAssertEqual(grid.columns.map(\.width), [100, 200])
        XCTAssertFalse(grid.isCompressed)
        XCTAssertFalse(grid.overflows)
    }

    func testGapsCountAgainstTheBudget() {
        // 100 + 200 = 300 of text, plus one 18pt gap, is 318. At 317 the table
        // no longer fits and has to be squeezed, even though the text alone
        // would have.
        let fits = TableGrid.solve(
            demands: [demand(100, min: 10), demand(200, min: 10)], available: 318, gap: 18)
        XCTAssertFalse(fits.isCompressed)

        let squeezed = TableGrid.solve(
            demands: [demand(100, min: 10), demand(200, min: 10)], available: 317, gap: 18)
        XCTAssertTrue(squeezed.isCompressed)
    }

    // MARK: - Squeezing

    func testASqueezedTableFitsTheSpaceItWasGiven() {
        let grid = TableGrid.solve(
            demands: [demand(120, min: 60), demand(900, min: 80)],
            available: 400, gap: 18)

        XCTAssertEqual(grid.width, 400, accuracy: 0.01)
        XCTAssertTrue(grid.isCompressed)
        XCTAssertFalse(grid.overflows)
    }

    func testTheWideColumnGivesUpTheRoomAndTheNarrowOneKeepsIt() {
        // The label column is not why the table overflows, so it should come
        // out close to what it asked for while the prose column absorbs the
        // squeeze. Shrinking in proportion to *width* rather than to excess
        // is what this rules out — that would take 8% off the label too.
        let grid = TableGrid.solve(
            demands: [demand(120, min: 110), demand(900, min: 80)],
            available: 400, gap: 18)

        // Untouched, not merely nearly untouched: the ceiling never drops to
        // where this column lives.
        XCTAssertEqual(grid.columns[0].width, 120, accuracy: 0.01)
        XCTAssertLessThan(grid.columns[1].width, 300)
    }

    func testNoColumnShrinksBelowItsWidestUnbreakableWord() {
        let grid = TableGrid.solve(
            demands: [demand(400, min: 90), demand(400, min: 150)],
            available: 260, gap: 18)

        XCTAssertGreaterThanOrEqual(grid.columns[0].width, 90)
        XCTAssertGreaterThanOrEqual(grid.columns[1].width, 150)
    }

    func testATableThatCannotFitEvenAtItsMinimumsSaysSo() {
        let grid = TableGrid.solve(
            demands: [demand(400, min: 200), demand(400, min: 200)],
            available: 300, gap: 18)

        XCTAssertEqual(grid.columns.map(\.width), [200, 200])
        XCTAssertTrue(grid.overflows)
        XCTAssertTrue(grid.isCompressed)
    }

    func testGapsWiderThanTheSpaceDoNotProduceNegativeColumns() {
        // Six columns at 18pt of gap is 90pt of gap alone, in 40pt of space.
        let grid = TableGrid.solve(
            demands: Array(repeating: demand(50, min: 20), count: 6),
            available: 40, gap: 18)

        XCTAssertTrue(grid.columns.allSatisfy { $0.width >= 0 })
        XCTAssertTrue(grid.overflows)
    }

    // MARK: - Geometry

    func testOffsetsFollowTheWidthsAndTheGaps() {
        let grid = TableGrid.solve(
            demands: [demand(100, min: 10), demand(50, min: 10), demand(80, min: 10)],
            available: 1000, gap: 20)

        XCTAssertEqual(grid.offsets, [0, 120, 190])
        XCTAssertEqual(grid.width, 270)
    }

    func testAnEmptyTableHasNoGeometry() {
        let grid = TableGrid.solve(demands: [], available: 500, gap: 18)
        XCTAssertEqual(grid.width, 0)
        XCTAssertTrue(grid.offsets.isEmpty)
        XCTAssertFalse(grid.overflows)
    }

    // MARK: - Geometry of a column

    func testAColumnsRectFollowsItsOffsetAndWidth() {
        let grid = TableGrid.solve(
            demands: [demand(100, min: 10), demand(60, min: 10)],
            available: 1000, gap: 20)

        XCTAssertEqual(grid.rect(forColumn: 0, height: 30), CGRect(x: 0, y: 0, width: 100, height: 30))
        XCTAssertEqual(grid.rect(forColumn: 1, height: 30), CGRect(x: 120, y: 0, width: 60, height: 30))
    }

    func testAnOutOfRangeColumnHasNoRect() {
        let grid = TableGrid.solve(demands: [demand(100, min: 10)], available: 500, gap: 0)
        XCTAssertEqual(grid.rect(forColumn: 7, height: 30), .zero)
    }

    func testAlignmentIsCarriedThroughToTheSolvedColumns() {
        let grid = TableGrid.solve(
            demands: [
                demand(100, min: 10, .left),
                demand(100, min: 10, .center),
                demand(100, min: 10, .right),
                demand(100, min: 10, .auto),
            ],
            available: 1000, gap: 0)

        XCTAssertEqual(grid.columns.map(\.alignment), [.left, .center, .right, .auto])
    }

    // MARK: - Properties

    func testTheSolverNeverExceedsItsBudgetAndNeverBreachesAFloor() {
        var generator = SeededGenerator(seed: 20_260_817)

        for _ in 0..<2000 {
            let count = Int.random(in: 1...7, using: &generator)
            let demands = (0..<count).map { _ -> TableColumnDemand in
                let minimum = CGFloat(Int.random(in: 0...120, using: &generator))
                let natural = minimum + CGFloat(Int.random(in: 0...900, using: &generator))
                return TableColumnDemand(natural: natural, minimum: minimum)
            }
            let available = CGFloat(Int.random(in: 0...1200, using: &generator))
            let gap = CGFloat([0, 8, 18].randomElement(using: &generator)!)

            let grid = TableGrid.solve(demands: demands, available: available, gap: gap)

            XCTAssertEqual(grid.columns.count, demands.count)

            for (column, demand) in zip(grid.columns, demands) {
                XCTAssertGreaterThanOrEqual(
                    column.width, demand.minimum - 0.01,
                    "a column was squeezed below its unbreakable word")
                XCTAssertLessThanOrEqual(
                    column.width, demand.natural + 0.01,
                    "a column was given more than it asked for")
            }

            // The whole point: unless it declared that it could not fit, it fits.
            if !grid.overflows {
                XCTAssertLessThanOrEqual(
                    grid.width, available + 0.01,
                    "a table overran its container without reporting it")
            }
        }
    }
}
