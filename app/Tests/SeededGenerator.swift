//
//  SeededGenerator.swift
//  MarkDevKitTests
//
//  The deterministic generator the stress tests share.
//

import Foundation

/// SplitMix64 — a seeded generator, so a failing storm can be replayed
/// exactly and a failure names the seed that reproduces it.
///
/// `SystemRandomNumberGenerator` would make every run a different test, and a
/// randomised failure nobody can reproduce is worse than no test at all.
///
/// Lives in its own file because more than one suite needs it. It was declared
/// twice — once in the editor stress tests and once in the terminal ones —
/// which compiled in each branch alone and collided the moment both were on
/// the same target.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    /// - Parameter seed: any value. Zero is folded to the golden-ratio
    ///   constant: splitmix64 recovers from a zero state on its own, but a
    ///   seed of 0 usually means "nobody chose one", and giving it the same
    ///   stream as an explicit 0 hides that.
    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
