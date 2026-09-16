# Performance Budgets & Benchmarking

[Documentation](README.md) / Performance

MarkDev targets fluid **60fps / 120fps ProMotion** interaction while editing large Markdown documents. The table below separates that design target from the looser thresholds the automated suite actually enforces.

---

## Performance Budgets

Two different numbers, kept apart on purpose. The **target** is the frame budget
the design aims at. The **enforced gate** is the assertion a test actually
fails on — which, for the Swift subsystems, is deliberately looser than the
target, for reasons the tests themselves record.

Conflating them is how a budget nobody enforces comes to read as one that is.
`core/tests/docs_contract.rs` re-derives this table from those assertions, so
the gate column cannot drift from what the suite really does.

| Subsystem | Measurement Target | Enforced Gate | Enforced In | Historical Local Sample |
|---|---|---|---|---|
| **Markdown Parser** | 10,000 lines CommonMark | `< 16.6ms` (Release) | `core/tests/performance.rs` | **2.55ms** |
| **Incremental Shift** | 10,000 lines single-word edit | *correctness only — no timing gate* | `core/tests/incremental.rs` | **0.01ms** |
| **Editor Keystroke** | 10,000 lines prose edit (Swift) | `< 50ms` (Debug) | `app/Tests/EditorPerformanceTests.swift` | **14.0ms** |
| **Caret Navigation** | Movement across collapsed runs | `< 16.6ms` (one frame) | `app/Tests/EditorPerformanceTests.swift` | **0.6ms** |

The sample column records earlier observations on one development machine. It
is useful for spotting large shifts, but it is not a portable guarantee and is
not recomputed by this document.

**Why the Swift gates are loose.** `@testable import` does not link against a
Release build of the framework, so these figures are debug Swift over debug
Rust. In the recorded 14ms keystroke sample, 9.4ms was `md_document_replace` plus copying the
parse back across the FFI — neither of which that target can improve — leaving
roughly 3ms of headroom against 16.6ms. An assertion that tight fails when the
machine is busy rather than when the code is wrong, and it did exactly that on
a contended run. The gate is therefore set where it catches the failure that
matters: work that grows with the document. The quadratic marker lookup that
once cost 5,000ms fails it immediately.

The honest consequence is that **release performance for the Swift editor path
is unverified**, and this table says so rather than implying a gate that is not
there.

**Incremental Shift** is gated on *behaviour*, not time: `core/tests/incremental.rs`
asserts that typing in plain prose yields `Reparse::Shifted` — no reparse at
all. The 0.01ms figure is a recorded observation consistent with that
property; nothing asserts the duration directly.

---

## 1. Parser Performance Gate (`cargo test --locked`)

The Rust parser benchmark parses a synthetic 10,000-line Markdown document containing deep heading hierarchies, nested lists, code blocks, tables, and mixed inline formatting.

### Running the Benchmark:
```bash
cd core && cargo test --locked --release --test performance
```

> [!IMPORTANT]
> **Always run parser performance benchmarks in `--release` mode.**
> Rust debug builds omit the release optimizer and Link-Time Optimization
> (LTO), so a debug parse takes ~25ms and does not reflect the shipping
> application's behavior. Scanner selection is architecture-specific in both
> profiles: the enabled `pulldown-cmark` feature can select SSSE3 at runtime on
> supported `x86_64` CPUs, while the `arm64` slice uses the scalar scanner.

---

## 2. Editor Keystroke Performance Gate (`EditorPerformanceTests`)

The editor gate measures the full TextKit 2 restyling pass in `app/Tests/EditorPerformanceTests.swift`:
1. Simulates typing a character in a 10,000-line document.
2. Measures scoped attribute application (`MarkdownStyler`).
3. Measures Tree-sitter syntax highlighting token spans (`SyntaxHighlighter`).
4. Measures layout fragment invalidation.

```bash
just test-app MarkDevKitTests/EditorPerformanceTests
```

To isolate regressions in the Swift framework, the test subtracts the measured debug FFI parse duration so that Swift framework regressions cannot hide behind Rust variations.

---

## 3. Benchmark Sampling Methodology

The Rust and Swift gates deliberately use different sampling rules, and neither
rule should be generalized to the whole suite:

- `core/tests/performance.rs` asserts the **median** of seven full-parse samples (and five samples for the scaling ratio).
- `EditorPerformanceTests` asserts the **fastest** of several deterministic Swift samples and prints the worst sample. Background contention can add latency, so the fastest sample is used as the closest estimate of code cost for those debug-only gates.

> [!TIP]
> For Swift tests, inspect the printed `worst` latency alongside the asserted fastest latency. A large divergence on an otherwise idle machine can indicate first-keystroke cache misses or allocation spikes. For Rust, inspect the printed median and scaling ratio.

---

## 4. Incremental Parsing & Property Verification

The incremental parser in `core/src/md/incremental.rs` uses a **shift-only fast path**:
- When inert words are typed inside prose without touching block markers, the existing AST is preserved and node offsets are shifted in memory; an earlier local run observed roughly 10 microseconds, but the suite gates the selected `Reparse::Shifted` path rather than that duration.
- If any ambiguity exists (e.g. typing near fences, indentation, or list prefixes), the parser safely falls back to a complete reparse.

### Property Testing:
Before modifying incremental parsing behavior, run the 1,500-case property test suite:
```bash
cd core && cargo test --locked --test incremental
```
