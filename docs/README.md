# MarkDev Documentation

Welcome to the technical documentation for **MarkDev**. This documentation provides in-depth technical guides, architectural breakdowns, design invariants, and performance budgets for contributors and developers.

---

## Table of Contents

- [Getting Started & Setup](./getting-started.md)
  - System prerequisites and toolchain requirements
  - Building debug and release binaries with `just`
  - Xcode project generation and gotchas
  - Running automated tests and linter suites

- [Architecture & Design Invariants](./architecture.md)
  - Swift + Rust hybrid engine design
  - The C-ABI FFI boundary and UTF-16 code unit indexing
  - App framework and isolated read-only Quick Look target
  - Value-type layout engines (`SplitLayout`)
  - Sandboxing, privacy manifests, and terminal trust boundaries
  - Bounded async I/O, recovery journal, and asset ingestion
  - Current-process diagnostics and separately inspected previous-run exports

- [Editor Engine & Rendering Pipeline](./editor-engine.md)
  - TextKit 2 layout fragment architecture (`NSTextLayoutFragment`)
  - Non-destructive marker collapsing with 0.01pt fonts
  - GFM tables drawn as a grid (`TableGrid` / `TableRowLayout`)
  - Native rich block rendering (LaTeX via SwiftMath, Mermaid via BeautifulMermaid)
  - Bounded image paste/drop ingestion into document-local assets
  - Incremental shift parsing vs full reparsing
  - AI-assisted writing/proofreading panel data ownership checks

- [Vault Indexing & Knowledge Graph](./vault-and-graph.md)
  - Note metadata extraction and tag indexing
  - Obsidian-compatible wikilink resolution algorithms
  - Whole-word unlinked mention extraction
  - Deterministic tie-breaking and backlink resolution
  - Interactive force-directed graph canvas

- [Performance Budgets & Benchmarking](./performance.md)
  - Performance targets and separately documented automated gates
  - Architecture-aware Rust parser benchmark suite
  - Keystroke latency profiling in TextKit 2
  - Best runs vs median variance in CI/testing
