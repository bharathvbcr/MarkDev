//
//  TableGrid.swift
//  MarkDevKit
//
//  Column geometry for a GFM table, decided without touching a view.
//

import CoreGraphics
import Foundation

/// The width a column would like, and the width it can survive at.
///
/// Both are measured from the cells as they are actually styled, so a bold or
/// code cell asks for the room it really needs rather than the room plain
/// prose of the same length would.
public struct TableColumnDemand: Sendable, Equatable {
    /// The widest cell laid out on a single line — what the column wants.
    public var natural: CGFloat
    /// The widest single unbreakable word in the column — the point below
    /// which shrinking stops buying anything, because the text cannot wrap
    /// any tighter and would simply be clipped.
    public var minimum: CGFloat
    public var alignment: TableAlignment

    public init(natural: CGFloat, minimum: CGFloat, alignment: TableAlignment = .auto) {
        // A minimum wider than the natural width is not meaningful: the
        // natural width is measured from the same text unbroken, so it is an
        // upper bound on any one word in it. Clamping here rather than
        // trusting the caller keeps the solver's invariants local.
        self.natural = max(natural, 0)
        self.minimum = min(max(minimum, 0), max(natural, 0))
        self.alignment = alignment
    }
}

/// Solved column geometry for one table.
///
/// A pure value type, holding every rule about how wide a column is and where
/// it starts — the same division `SplitLayout` makes for panes. The drawing
/// layer measures cells, asks this for the geometry, and paints; it never
/// decides a width itself. That is what lets "a table never exceeds the text
/// container" and "a column never shrinks below one word" be tested
/// properties rather than things believed about view code.
public struct TableGrid: Sendable, Equatable {
    /// A solved column: how wide, and how its cells sit in it.
    public struct Column: Sendable, Equatable {
        public var width: CGFloat
        public var alignment: TableAlignment

        public init(width: CGFloat, alignment: TableAlignment) {
            self.width = width
            self.alignment = alignment
        }
    }

    public var columns: [Column]
    /// Space between one column's text and the next column's.
    public var gap: CGFloat
    /// Whether the columns had to be squeezed below what they asked for.
    ///
    /// Not cosmetic bookkeeping: a squeezed table wraps its cells, and a row's
    /// height then depends on the solved widths rather than on the font alone.
    public var isCompressed: Bool
    /// Whether even the minimum widths did not fit, so the table is as narrow
    /// as it can be drawn and still overruns the space it was given.
    ///
    /// Carried rather than silently clamped: a caller that reports "fits" for
    /// a table that does not is the check-that-could-not-run failure mode.
    public var overflows: Bool

    /// The x offset of each column's leading edge, gaps included.
    public var offsets: [CGFloat] {
        var result: [CGFloat] = []
        result.reserveCapacity(columns.count)
        var x: CGFloat = 0
        for column in columns {
            result.append(x)
            x += column.width + gap
        }
        return result
    }

    /// Total width including the gaps between columns, but not after the last.
    public var width: CGFloat {
        guard !columns.isEmpty else { return 0 }
        return columns.reduce(0) { $0 + $1.width } + gap * CGFloat(columns.count - 1)
    }

    /// Solves column widths for `available` space.
    ///
    /// Auto table layout, in the shape every table renderer converges on:
    /// give every column what it asks for when the table fits, and when it
    /// does not, take the excess from the columns that are over their fair
    /// share, in proportion to how far over they are — never below the width
    /// of their widest unbreakable word.
    ///
    /// Taking it proportionally to *excess* rather than to width is what keeps
    /// a narrow column narrow: a label column of 80pt beside a prose column of
    /// 900pt should not lose 8% of itself to make room, because it was never
    /// the reason the table did not fit.
    public static func solve(
        demands: [TableColumnDemand],
        available: CGFloat,
        gap: CGFloat
    ) -> TableGrid {
        guard !demands.isEmpty else {
            return TableGrid(columns: [], gap: gap, isCompressed: false, overflows: false)
        }

        let gaps = gap * CGFloat(demands.count - 1)
        // What is actually left for text, once the gaps are paid for. A table
        // with many columns in a narrow container can spend more on gaps than
        // it has, so this floors at zero rather than going negative and
        // handing the solver a nonsensical budget.
        let budget = max(available - gaps, 0)

        let natural = demands.reduce(0) { $0 + $1.natural }
        if natural <= budget {
            return TableGrid(
                columns: demands.map { Column(width: $0.natural, alignment: $0.alignment) },
                gap: gap,
                isCompressed: false,
                overflows: false
            )
        }

        let floors = demands.reduce(0) { $0 + $1.minimum }
        if floors >= budget {
            // Nothing left to distribute: every column is already at the
            // narrowest it can be drawn. Report the overflow rather than
            // pretending the result fits.
            return TableGrid(
                columns: demands.map { Column(width: $0.minimum, alignment: $0.alignment) },
                gap: gap,
                isCompressed: true,
                overflows: floors > budget
            )
        }

        // Cap every column at a common ceiling, and lower the ceiling until
        // the table fits. A column narrower than the ceiling is untouched, so
        // a table only ever takes room from its widest columns — the label
        // column beside a prose column keeps every point it asked for, and the
        // prose column absorbs the whole squeeze. Sharing the deficit out in
        // proportion to each column's surplus, which is the obvious
        // alternative, shaves a few points off the label too, for no benefit:
        // it was never the reason the table did not fit.
        //
        // `width(at:)` is non-decreasing in the ceiling and runs from `floors`
        // to `natural`, and the budget is strictly between those two here, so
        // bisection converges on the ceiling that spends the budget exactly.
        func width(_ demand: TableColumnDemand, at ceiling: CGFloat) -> CGFloat {
            min(demand.natural, max(ceiling, demand.minimum))
        }
        var low: CGFloat = 0
        var high = demands.reduce(0) { max($0, $1.natural) }
        for _ in 0..<60 {
            let ceiling = (low + high) / 2
            if demands.reduce(0, { $0 + width($1, at: ceiling) }) < budget {
                low = ceiling
            } else {
                high = ceiling
            }
        }
        var widths = demands.map { width($0, at: high) }

        // Bisection lands within a rounding error of the budget, which over a
        // wide table is the difference between the last column sitting on the
        // margin and one point past it. The remainder goes to the widest
        // column that still has headroom — never past what that column asked
        // for, or a table that fits would report a column wider than its text.
        let remainder = budget - widths.reduce(0, +)
        if remainder > 0,
            let widest = widths.indices
                .filter({ widths[$0] < demands[$0].natural })
                .max(by: { widths[$0] < widths[$1] })
        {
            widths[widest] = min(widths[widest] + remainder, demands[widest].natural)
        }

        return TableGrid(
            columns: zip(widths, demands).map { Column(width: $0, alignment: $1.alignment) },
            gap: gap,
            isCompressed: true,
            overflows: false
        )
    }

    /// The rect a cell's text occupies, in the row's own coordinates.
    ///
    /// Alignment inside the column is left to the cell's paragraph style
    /// rather than baked in here as an offset: a cell that wraps has to align
    /// every one of its lines, and an offset computed from the unwrapped width
    /// aligns only the first.
    public func rect(forColumn index: Int, height: CGFloat) -> CGRect {
        guard columns.indices.contains(index) else { return .zero }
        return CGRect(
            x: offsets[index], y: 0, width: columns[index].width, height: height)
    }
}
