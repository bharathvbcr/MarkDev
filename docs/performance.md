# Performance Budgets & Benchmarking

MarkDev is engineered to maintain a fluid **60fps / 120fps ProMotion** interactive experience even when editing massive, book-length Markdown documents. Every subsystem has an explicit, automated performance gate.

---

## Performance Budgets

| Subsystem | Measurement Target | Automated Gate | Current Baseline |
|---|---|---|---|
| **Markdown Parser** | 10,000 lines CommonMark | `< 16.6ms` (Release) | **2.55ms** |
| **Incremental Shift** | 10,000 lines single-word edit | `< 0.05ms` (Release) | **0.01ms** |
| **Editor Keystroke** | 10,000 lines prose edit (Swift) | `< 16.6ms` (Debug) | **14.0ms** |
| **Caret Navigation** | Movement across collapsed runs | `< 2.0ms` | **0.6ms** |

---

## 1. Parser Performance Gate (`cargo test`)

The Rust parser benchmark parses a synthetic 10,000-line Markdown document containing deep heading hierarchies, nested lists, code blocks, tables, and mixed inline formatting.

### Running the Benchmark:
```bash
cd core && cargo test --release --test performance
```

> [!IMPORTANT]
> **Always run parser performance benchmarks in `--release` mode.**
> Rust debug builds disable SIMD acceleration, inlining, and Link-Time Optimization (LTO). A debug parse takes ~25ms, which does not reflect the shipping application's behavior.

---

## 2. Editor Keystroke Performance Gate (`EditorPerformanceTests`)

The editor gate measures the full TextKit 2 restyling pass in `app/Tests/EditorPerformanceTests.swift`:
1. Simulates typing a character in a 10,000-line document.
2. Measures scoped attribute application (`MarkdownStyler`).
3. Measures Tree-sitter syntax highlighting token spans (`SyntaxHighlighter`).
4. Measures layout fragment invalidation.

```bash
xcodebuild -project MarkDev.xcodeproj -scheme MarkDev -configuration Debug -only-testing:Tests/EditorPerformanceTests test
```

To isolate regressions in the Swift framework, the test subtracts the measured debug FFI parse duration so that Swift framework regressions cannot hide behind Rust variations.

---

## 3. Benchmarking Methodology: Fastest of N Runs

MarkDev's performance tests assert against the **fastest sample out of N runs** rather than the median.

### Rationale:
- Background CPU contention (such as a parallel compile or indexing task) can only **slow down** a benchmark run.
- Using a median can cause false failures during CI or background CPU spikes, leading developers to ignore the gate.
- The fastest run represents the true, unthrottled execution time of the code under test.

> [!TIP]
> Always inspect the printed `worst` latency alongside the asserted fastest latency. A large divergence between best and worst on an otherwise idle machine indicates first-keystroke cache misses or allocation spikes.

---

## 4. Incremental Parsing & Property Verification

The incremental parser in `core/src/md/incremental.rs` uses a **shift-only fast path**:
- When inert words are typed inside prose without touching block markers, the existing AST is preserved and node offsets are shifted in memory in ~10 microseconds.
- If any ambiguity exists (e.g. typing near fences, indentation, or list prefixes), the parser safely falls back to a complete reparse.

### Property Testing:
Before modifying incremental parsing behavior, run the 1,500-case property test suite:
```bash
cd core && cargo test --test incremental
```
