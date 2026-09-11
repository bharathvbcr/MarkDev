# MarkDev

A fast, native macOS Markdown editor and knowledge vault tool built with **Swift + Rust**.

**No Electron. No WebViews. Pure AppKit & TextKit 2.**

---

## Overview

MarkDev combines the safety and parsing throughput of a compiled Rust core with the fluid elegance of macOS Liquid Glass design. It is built for developers and technical writers who want a low-latency native editor and first-class developer tooling inside their note-taking workflow.

**Ecosystem.** DevCouncil is components and modules. Manvi wraps them. GitPulse uses Manvi and selected DevCouncil components for their respective jobs. MarkDev is the same kind of host: its Rust core exposes independently selectable Cargo features (GitPulse takes highlighting without the C ABI), and Assist can drive Manvi without taking the rest of DevCouncil. Update one module at a time.

```
┌────────────────────────────────────────────────────────────┐
│                        Workspace                           │
│  ┌──────────────┬──────────────────────────┬────────────┐  │
│  │  Navigator   │     Editor / Splits      │ Inspector  │  │
│  │              │                          │            │  │
│  │  • Vault     │  # MarkDev               │ • Outline  │  │
│  │  • Folders   │  Native macOS editor...  │ • Backlinks│  │
│  │  • Files     │                          │ • Mentions │  │
│  │              │  ```rust                 │            │  │
│  │              │  fn parse() -> Ast { }   │ • Graph    │  │
│  │              │  ```                     │            │  │
│  └──────────────┴──────────────────────────┴────────────┘  │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Integrated Terminal Drawer (VT100 / xterm pty)      │  │
│  └──────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────┘
```

---

## Key Features

### ⚡️ Swift + Rust Hybrid Architecture
- **Rust Core**: CommonMark parsing via `pulldown-cmark` (a runtime-detected SSSE3 scanner on supported `x86_64` CPUs and the scalar scanner on `arm64`), Tree-sitter syntax highlighting (Rust, Swift, JS/TS, Python, JSON, Bash), and inverted index vault search.
- **AppKit & SwiftUI Shell**: Native Liquid Glass chrome, macOS menu bar integration, and deep system capabilities.
- **Zero-Copy FFI Boundary**: Flat C-ABI data buffers communicating across the language seam using strict UTF-16 code unit indexing.

### 📝 Live In-Place Markdown Editing
- **Collapsed Marker Engine**: Syntax markers (e.g. `**`, `*`, `~~`, ```` ``` ````) collapse in-place to 0.01pt fonts rather than being stripped from the buffer.
- **Full Fidelity Clipboard & Undo**: Because raw Markdown remains in `NSTextStorage`, native selection, `⌘C` copy, `⌘Z` undo, and regex search operate directly on the real document.
- **Scoped Restyling**: Keystrokes restyle affected paragraph blocks instead of repainting the entire document; the performance targets and enforced gates are reported separately below.

### 🧮 Native Rich Block Rendering
- **LaTeX Math**: Rendered in pure Swift using Core Text via `SwiftMath` (no MathJax web overhead).
- **Mermaid Diagrams**: Native graph layout and rendering for flowcharts, sequence diagrams, state machines, and ER diagrams via `BeautifulMermaid`.
- **GFM Tables as Grids**: Pipe tables are drawn as a real grid with per-column alignment, without modifying raw text.
- **Interactive Checkboxes**: Clickable GFM task list checkboxes rendered directly into gutter fragments.

### 🛠️ Safety, Support, and Automation
- **Bounded HTML Export**: Notes export as browser-ready HTML through a safe Rust path that enforces payload size limits and destination-safe rendering.
- **Bounded Local Images**: Remote image fetches are refused. Local images are read from a retained no-follow descriptor, type-checked, downsampled under pixel and retained-output budgets, and rechecked after ImageIO returns.
- **Crash-Safe Saves**: Descriptor-relative transactions and a bounded two-copy recovery journal retain ambiguous save state for review rather than reporting uncertain publication as success.
- **Diagnostics Pipeline**: Privacy-preserving, bounded local diagnostics keep the current-process support report separate from inspected previous-run history.
- **AI-Assisted Editing Controls**: Writing and proofreading tools verify source-document ownership before applying model output.

### 🧠 Knowledge Vault & Link Graph

- **Saved Vaults**: Save the current folder from the File menu or sidebar, then reopen it from the sidebar's Saved Vaults list across launches. Removing a saved entry leaves its files in place.
- **Obsidian-Compatible Wikilinks**: Full `[[Note]]`, `[[Note#Heading]]`, and `[[Note|Alias]]` link resolution with deterministic tie-breaking (shallowest path first).
- **Backlinks & Unlinked Mentions**: Fast inverted index that tracks backlinks and extracts whole-word unlinked mentions across the entire vault.
- **Force-Directed Graph**: Interactive visual canvas displaying the relational link structure of your vault.

### 🖥️ Integrated Terminal Drawer
- Built-in VT100/xterm terminal drawer powered by `SwiftTerm`.
- Run compiler tools, git commands, and CLI scripts directly beneath your open notes without switching context.

### 🪟 Workspace & Productivity Tools
- **Arbitrary Split Layouts**: Recursive horizontal and vertical split panes governed by a pure value-type layout engine (`SplitLayout`).
- **Command Palette (`⌘K`)**: Unified fuzzy search over vault files, headings, and workspace actions.
- **Spacebar Quick Look & Peek**: Hover over internal links or file trees and hold Space to peek at content without opening a new tab.
- **macOS Quick Look Extension**: A sandboxed, user-selected read-only preview target, isolated from the app framework and terminal dependency. Registration can be checked exactly, but registration alone does not identify which provider Finder served.

---

## Markdown Syntax & Feature Matrix

| Feature | Syntax | Status | Design Rationale |
|---|---|---|---|
| **Tables (GFM)** | `\| A \| B \|` | Supported | Drawn as a grid with per-column alignment, without altering source text. |
| **Footnotes** | `[^1]` / `[^1]: Note` | Supported | Rendered as superscript references with bidirectional navigation. |
| **Task Lists** | `- [ ]` / `- [x]` | Supported | Interactive checkboxes in layout fragment gutters. |
| **LaTeX Math** | `$x$` / `$$\int$$` | Supported | Typeset via `SwiftMath` using Latin Modern fonts. |
| **Mermaid** | ```` ```mermaid ```` | Supported | Flowcharts, sequence, class, state, and ER diagrams. |
| **GFM Callouts** | `> [!NOTE]` | Supported | Distinct styled border panels with accent tinting. |
| **YAML Frontmatter**| `---` metadata | Supported | Scanned for tags/aliases and displayed cleanly. |
| **Definition Lists**| `Term\n: Def` | Supported | Extended multi-line definitions. |
| **Wikilinks** | `[[Note]]` | Supported | Vault-relative path resolution with alias support. |
| **Strikethrough** | `~~text~~` | Supported | Standard GFM strikethrough styling. |
| **Subscript** | `~x~` as subscript | *Excluded* | pulldown's subscript option stays off. Flanked `~x~` is GFM strikethrough, same as `~~x~~`. |
| **Smart Punctuation**| `"` → `“` | *Excluded* | Disabled so UTF-16 code unit buffer offsets never drift. |

---

## Performance Budgets

MarkDev gates performance regressions in its test suite. The target is the
frame budget; the enforced gate is what a test actually fails on, and for the
Swift paths it is deliberately looser — see
[docs/performance.md](docs/performance.md) for why.

| Measurement | Target Budget | Enforced Gate | Historical Local Sample |
|---|---|---|---|
| **Release Parse (10k lines)** | `< 16.6ms` (1 frame) | `< 16.6ms` (Release) | **~2.55ms** |
| **Prose Keystroke (10k lines)** | `< 16.6ms` (1 frame) | `< 50ms` (Debug) | **~14.0ms** |
| **Caret Navigation** | `< 2.0ms` | `< 16.6ms` (one frame) | **~0.6ms** |

Samples are observations from earlier local runs, not portable guarantees. The
Rust parser gate uses a median; Swift editor latency gates use the fastest of
several samples and print the worst sample for contention visibility.

---

## Requirements

- **macOS**: macOS 26.0 or later; Release builds from this tree are universal
  (`arm64` + `x86_64`). The already-published v0.0.4 artifact remains the
  Apple-silicon build described by its historical release notes.
- **Xcode**: Xcode 26.6 (build 17F113) for CI and release validation
- **Rust**: Rust 1.98.0 with the matching Cargo, `rustfmt`, and `clippy`, plus
  the `aarch64-apple-darwin` and `x86_64-apple-darwin` targets
- **Tools**: `just` 1.58.0 and XcodeGen 2.45.4 for CI and release validation

Install Just via [Homebrew](https://brew.sh):
```bash
brew install just
```

Install XcodeGen from its official
[2.45.4 release archive](https://github.com/yonaskolb/XcodeGen/releases/download/2.45.4/xcodegen.zip),
whose expected SHA-256 is
`090ec29491aad50aec10631bf6e62253fed733c50f3aab0f5ffc86bc170bdbef`.
MarkDev verifies the exact tool versions and fails closed if an input has
moved. Update the pins and their evidence deliberately; do not relax the check
to “latest.”

---

## Quick Start & Building

MarkDev uses `just` to orchestrate multi-language compilation between Rust and Xcode.

```bash
# Clone the repository
git clone https://github.com/bharathvbcr/MarkDev.git
cd MarkDev

# Build the Rust core and Xcode project (Debug)
just build

# Run the app locally
just run

# Run all test suites (Rust + Swift)
just test

# Run release contracts, format/lint checks, and both test suites
just check
```

### Available `just` Commands

| Command | Action |
|---|---|
| `just build` | Builds Rust core (debug) → generates Xcode project → builds app |
| `just build-release` | Verifies the pinned toolchain → builds optimized Rust core → builds Release `.app` bundle |
| `just run` | Builds and launches MarkDev |
| `just test` | Runs Rust unit/integration tests and Swift test suites |
| `just ci-local` | Runs the local CI gates, including release contracts and the release performance benchmark |
| `just check` | Runs `cargo fmt --check`, `cargo clippy --locked`, and all test suites |
| `just generate` | Re-generates `MarkDev.xcodeproj` from `project.yml` |
| `just icons` | Compiles app icon and document `.icns` from vector geometry |
| `just preview <file>` | Requires a registered MarkDev candidate, then opens the system Quick Look UI; provider attribution remains unavailable |
| `just preview-status` | Requires the exact `/Applications` Quick Look bundle registration and reports content-type resolution |

> [!NOTE]
> `MarkDev.xcodeproj` is generated by `xcodegen` and is gitignored. Always edit `project.yml` and run `just generate` rather than editing Xcode project files directly.
> The generated workspace's shared `Package.resolved` is the dependency lock. Owned build and test recipes require that resolved graph and disable package updates; keep the lock in version control when package resolution changes.

### Permissions and privacy boundary

The main app is intentionally unsandboxed because opening arbitrary user-selected vaults and hosting an interactive terminal are core features. File access is still validated at MarkDev's own boundaries, but the terminal is an explicit code-execution surface, not a sandbox.

The Quick Look extension is a separate sandboxed, application-extension-only target with only user-selected read access. It does not link `MarkDevKit` or `SwiftTerm`; it compiles a curated read-only renderer surface. The app, framework, and extension embed the same privacy manifest, which declares no tracking and no collected-data categories. See [Architecture & Security Boundaries](./docs/architecture.md) for the operational limits, diagnostics exports, and remaining same-user pathname race.

---

## Releases

See [v0.0.4 release notes](docs/releases/v0.0.4.md) for downloads, changes, and signing limitations.
The repository's local CI command is `just ci-local` (there is no npm `ci:local` script).

Release sequence: update the version/build in `project.yml` and the matching
`docs/releases/vX.Y.Z.md`, commit, run `just ci-local`, and create the matching
annotated tag on that tested commit. Run `just release-preflight vX.Y.Z`,
`just build-release`, and `just release-stage vX.Y.Z` before pushing the branch
and tag. Staging requires a clean checkout and verifies the extracted archive.

The tag workflow repeats CI and uploads a draft with the zip, checksum, and source
manifest. It never publishes automatically. Inspect the successful workflow and
verify the downloaded artifacts before publishing the draft. `just release-draft
vX.Y.Z` resumes missing uploads; an existing asset with different bytes requires
investigation and is never silently replaced. The command refuses a release it
observes as published, but GitHub has no transaction spanning the draft-state
check and a later upload/edit. Do not publish the draft concurrently with a retry.

---

## Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| `⌘ K` | Open Command Palette (files, commands, headings) |
| `⌘ N` | New Document |
| `⌘ O` | Open File |
| `⇧ ⌘ O` | Open Vault Folder |
| `⌘ S` | Save Document |
| `⇧ ⌘ S` | Save Document As… |
| `⌘ \` | Toggle File Navigator Sidebar |
| `⌥ ⌘ I` | Toggle Metadata & Backlinks Inspector |
| `⌘ J` | Toggle Terminal Drawer |
| `⌥ ⌘ G` | Toggle Vault Graph View |
| `⌘ F` | Find in Document |
| `⌥ ⌘ F` | Find and Replace |
| `⌘ G` / `⇧ ⌘ G` | Find Next / Previous Match |
| `Space` *(hold)* | Peek preview link or tree item under cursor |

---

## Repository Structure

```
MarkDev/
├── app/
│   ├── MarkDev/            # Main macOS Application entrypoint & views
│   ├── MarkDevKit/         # App framework (Editor, Vault, Terminal, Diagnostics)
│   ├── MarkDevQuickLook/   # Isolated, sandboxed read-only extension (.appex)
│   └── Tests/              # MarkDevKit unit & performance tests
├── core/
│   ├── src/
│   │   ├── md/             # Markdown parser, AST models, incremental engine
│   │   ├── highlight/      # Tree-sitter syntax highlighting
│   │   ├── vault/          # Vault indexing, graph resolution, search
│   │   └── ffi.rs          # C-compatible FFI boundary and CMarkDev header
│   └── tests/              # Rust unit, property, and benchmark tests
├── docs/                   # Comprehensive architecture & developer guides
├── tools/
│   └── icongen/            # Code-driven app icon renderer
├── project.yml             # XcodeGen project specification
└── justfile                # Multi-language build automation recipes
```

---

## Documentation

For in-depth architecture explanations and engineering guides, visit the [`docs/`](./docs) directory:

- [Getting Started & Build Setup](./docs/getting-started.md)
- [Architecture & FFI Boundary](./docs/architecture.md)
- [Embed the Rust Core](./docs/core-integration.md)
- [Editor Engine & TextKit 2 Pipeline](./docs/editor-engine.md)
- [Vault Indexing & Graph Algorithm](./docs/vault-and-graph.md)
- [Performance Budgets & Benchmarking](./docs/performance.md)

---

## Contributing

We welcome contributions! Please read our [Contributing Guide](./CONTRIBUTING.md) to understand the codebase philosophy, architectural invariants, and testing standards before submitting a pull request.

All contributors are expected to uphold our [Code of Conduct](./CODE_OF_CONDUCT.md).

---

## License

MarkDev is licensed under the [MIT License](./LICENSE).
