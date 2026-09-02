# MarkDev

A blazingly fast, native macOS Markdown editor and knowledge vault tool built with **Swift + Rust**. 

**No Electron. No WebViews. Pure AppKit & TextKit 2.**

---

## Overview

MarkDev combines the safety and parsing throughput of a compiled Rust core with the fluid elegance of macOS Liquid Glass design. It is built from the ground up for developers and technical writers who want instant startup, sub-frame typing latency, and first-class developer tooling inside their note-taking workflow.

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
- **Rust Core**: SIMD-accelerated CommonMark parsing (`pulldown-cmark`), Tree-sitter syntax highlighting (Rust, Swift, JS/TS, Python, JSON, Bash), and inverted index vault search.
- **AppKit & SwiftUI Shell**: Native Liquid Glass chrome, macOS menu bar integration, and deep system capabilities.
- **Zero-Copy FFI Boundary**: Flat C-ABI data buffers communicating across the language seam using strict UTF-16 code unit indexing.

### 📝 Live In-Place Markdown Editing
- **Collapsed Marker Engine**: Syntax markers (e.g. `**`, `*`, `~~`, ```` ``` ````) collapse in-place to 0.01pt fonts rather than being stripped from the buffer.
- **Full Fidelity Clipboard & Undo**: Because raw Markdown remains in `NSTextStorage`, native selection, `⌘C` copy, `⌘Z` undo, and regex search operate directly on the real document.
- **Scoped Restyling**: Keystrokes only restyle affected paragraph blocks, preserving 60fps rendering even in 10,000+ line documents.

### 🧮 Native Rich Block Rendering
- **LaTeX Math**: Rendered in pure Swift using Core Text via `SwiftMath` (no MathJax web overhead).
- **Mermaid Diagrams**: Native graph layout and rendering for flowcharts, sequence diagrams, state machines, and ER diagrams via `BeautifulMermaid`.
- **Dynamic Kerning Tables**: Markdown pipe tables auto-align columns in real time using font kerning without modifying raw text.
- **Interactive Checkboxes**: Clickable GFM task list checkboxes rendered directly into gutter fragments.

### 🧠 Knowledge Vault & Link Graph
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
- **macOS Quick Look Extension**: Seamless Spacebar previews of Markdown files directly within macOS Finder.

---

## Markdown Syntax & Feature Matrix

| Feature | Syntax | Status | Design Rationale |
|---|---|---|---|
| **Tables (GFM)** | `\| A \| B \|` | Supported | Auto-aligned via kerning without altering source text. |
| **Footnotes** | `[^1]` / `[^1]: Note` | Supported | Rendered as superscript references with bidirectional navigation. |
| **Task Lists** | `- [ ]` / `- [x]` | Supported | Interactive checkboxes in layout fragment gutters. |
| **LaTeX Math** | `$x$` / `$$\int$$` | Supported | Typeset via `SwiftMath` using Latin Modern fonts. |
| **Mermaid** | ```` ```mermaid ```` | Supported | Flowcharts, sequence, class, state, and ER diagrams. |
| **GFM Callouts** | `> [!NOTE]` | Supported | Distinct styled border panels with accent tinting. |
| **YAML Frontmatter**| `---` metadata | Supported | Scanned for tags/aliases and displayed cleanly. |
| **Definition Lists**| `Term\n: Def` | Supported | Extended multi-line definitions. |
| **Wikilinks** | `[[Note]]` | Supported | Vault-relative path resolution with alias support. |
| **Strikethrough** | `~~text~~` | Supported | Standard GFM strikethrough styling. |
| **Subscript / Tilde**| `~x~` | *Excluded* | Kept literal so `~x~` is not ambiguous with strikethrough. |
| **Smart Punctuation**| `"` → `“` | *Excluded* | Disabled so UTF-16 code unit buffer offsets never drift. |

---

## Performance Budgets

MarkDev gates performance regressions in its test suite. The target is the
frame budget; the enforced gate is what a test actually fails on, and for the
Swift paths it is deliberately looser — see
[docs/performance.md](docs/performance.md) for why.

| Measurement | Target Budget | Enforced Gate | Measured |
|---|---|---|---|
| **Release Parse (10k lines)** | `< 16.6ms` (1 frame) | `< 16.6ms` (Release) | **~2.55ms** |
| **Prose Keystroke (10k lines)** | `< 16.6ms` (1 frame) | `< 50ms` (Debug) | **~14.0ms** |
| **Caret Navigation** | `< 2.0ms` | `< 16.6ms` (one frame) | **~0.6ms** |

---

## Requirements

- **macOS**: macOS 26.0 or later (release downloads are for Apple silicon)
- **Xcode**: Xcode 26.x
- **Rust**: Rust toolchain 1.80+ (with `cargo`, `rustfmt`, `clippy`)
- **Tools**: `just` (command runner) and `xcodegen`

To install prerequisites via [Homebrew](https://brew.sh):
```bash
brew install just xcodegen
```

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

# Run code formatters and linters
just check
```

### Available `just` Commands

| Command | Action |
|---|---|
| `just build` | Builds Rust core (debug) → generates Xcode project → builds app |
| `just build-release` | Builds optimized Rust core → builds Release `.app` bundle |
| `just run` | Builds and launches MarkDev |
| `just test` | Runs Rust unit/integration tests and Swift test suites |
| `just ci-local` | Runs the local CI gates, including release contracts and the release performance benchmark |
| `just check` | Runs `cargo fmt --check`, `cargo clippy`, and all test suites |
| `just generate` | Re-generates `MarkDev.xcodeproj` from `project.yml` |
| `just icons` | Compiles app icon and document `.icns` from vector geometry |
| `just preview <file>` | Previews a markdown file through the Quick Look extension |

> [!NOTE]
> `MarkDev.xcodeproj` is generated by `xcodegen` and is gitignored. Always edit `project.yml` and run `just generate` rather than editing Xcode project files directly.

---

## Releases

See [v0.0.3 release notes](docs/releases/v0.0.3.md) for downloads, changes, and signing limitations.
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
investigation and is never silently replaced.

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
| `⇧ ⌘ G` | Toggle Vault Graph View |
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
│   ├── MarkDevKit/         # Shared framework (Editor, Vault, Terminal, Brand)
│   ├── MarkDevQuickLook/   # macOS Quick Look extension (.appex)
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
