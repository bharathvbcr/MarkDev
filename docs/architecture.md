# MarkDev Architecture

MarkDev is structured as a two-tier hybrid system:
1. **Rust Core (`core/`)**: High-performance Markdown parsing, syntax highlighting, AST extraction, and vault indexing.
2. **Swift Front-End (`app/`)**: Native macOS application built with AppKit and SwiftUI using Liquid Glass chrome and TextKit 2.

The Rust core is independently selectable by Cargo feature so another host can take only the pieces it needs. That is the same modularity as the rest of this stack: **DevCouncil** is components and modules, **Manvi** wraps them, and **GitPulse** uses Manvi plus selected DevCouncil modules. MarkDev's Assist panel can drive Manvi without taking the DevCouncil suite.

```
┌──────────────────────────────────────────────────────────┐
│                    Swift Front-End                       │
│  ┌───────────────────────┐    ┌───────────────────────┐  │
│  │   SwiftUI Workspace   │    │ TextKit 2 Text View   │  │
│  │ (Splits, Tabs, Glass) │    │ (Fragments, Styler)   │  │
│  └───────────┬───────────┘    └───────────┬───────────┘  │
└──────────────┼────────────────────────────┼──────────────┘
               │ C-ABI / JSON queries       │ UTF-16 records
┌──────────────┼────────────────────────────┼──────────────┐
│  ┌───────────▼───────────┐    ┌───────────▼───────────┐  │
│  │  Vault Index & Graph  │    │  Markdown & Highlight │  │
│  │ (Search, Backlinks)   │    │  (pulldown-cmark, TS) │  │
│  └───────────────────────┘    └───────────────────────┘  │
│                        Rust Core                         │
└──────────────────────────────────────────────────────────┘
```

---

## 1. Rust Core Engine (`core/`)

The Rust core builds as a Rust library and a static C-ABI library (`libmarkdev.a`) that knows nothing about macOS or AppKit. Its measured thresholds and sampling rules are documented in [Performance](performance.md); no latency guarantee applies to every document.

### Key Components:

- **Markdown Parser (`src/md/parse.rs`)**:
  Built on `pulldown-cmark`. Its optional `simd` feature selects a runtime-detected SSSE3 scanner on supported `x86_64` CPUs; the `arm64` slice uses the crate's scalar scanner. It tokenizes CommonMark blocks, headings, lists, tables, code blocks, task lists, and inline formatting.
- **Incremental Engine (`src/md/incremental.rs`)**:
  Uses a guarded **shift-only** fast path. When inert prose is typed away from block markers or line-start indentation, the previous parse tree is retained and offsets are simply shifted in memory without running the parser. Any ambiguous edit safely falls back to a complete reparse.
- **HTML Export (`src/html.rs`)**:
  Renders notes to browser-ready HTML with strict bounds checking, link/image destination sanitization, and strict CSP framing for safe local consumption.
- **Tree-sitter Syntax Highlighting (`src/highlight/`)**:
  High-accuracy, AST-based syntax highlighting for fenced code blocks. Uses real grammars for Rust, Swift, JavaScript, Python, JSON, and Bash.
- **Vault Index & Graph (`src/vault/`)**:
  Extracts note metadata (headings, tags, wikilinks) into an in-memory graph. Computes backlinks, resolves Obsidian-style wikilinks (`[[Note#Anchor]]`), and performs whole-word search for unlinked mentions.
- **C-ABI FFI Layer (`src/ffi.rs`)**:
  Exposes flat C structures across the FFI. Offset calculations are mapped from Rust byte indices to **UTF-16 code units** via `Utf16Mapper` so `NSTextStorage` receives exact string bounds against the same source revision. Swift copies returned records into its own model; the boundary is not universally zero-copy.

---

## 2. Application Framework and Isolated Quick Look Target

The main application links `MarkDevKit`, which owns the editable workspace, terminal, diagnostics, and application renderer. The Quick Look extension deliberately does **not** link `MarkDevKit` or `SwiftTerm`. Instead, its target compiles a curated set of canonical parser/editor-renderer sources under `MARKDEV_QUICKLOOK`, links the Rust core plus `SwiftMath` and `BeautifulMermaid`, and removes editor mutation, pasteboard, diagnostics, background prefetch, and zoom-window surfaces at compile time.

### Modules:

| Module | Purpose |
|---|---|
| **`Core/`** | Swift models and types mapping directly to the Rust FFI structs. |
| **`Editor/`** | TextKit 2 styling, fragments, native math/diagram/image rendering, and marker collapsing. |
| **`Render/`** | Read-only preview, in-app peek, and zoom-viewer surfaces. |
| **`Splits/`** | `SplitLayout` pure value-type layout engine for recursive horizontal/vertical panes. |
| **`Vault/`** | `VaultIndex` wrapper, backlinks engine, and interactive force-directed graph canvas. |
| **`Terminal/`** | Integrated VT100/xterm pty terminal drawer built on `SwiftTerm`. |
| **`Diagnostics/`** | Bounded local event ring, OS and file sinks, support-report export, and lifecycle contracts. |
| **`Intelligence/`** | AI-powered writing/proofreading panel and services with guarded source validation before edits. |
| **`Harness/`** | Optional MANVI subprocess, executable/provider settings, bounded run lifecycle. |
| **`Workspace/`** | Documents, save transactions, session restoration, commands, and close review. |
| **`Brand/`** | Vector geometry for the MarkDev mark and icon generation logic. |

---

## 3. The TextKit 2 Editor Pipeline

MarkDev uses Apple's **TextKit 2** (`NSTextLayoutManager` and `NSTextLayoutFragment`) to achieve inline rich rendering without sacrificing raw text editing.

```
Raw Text Edit (NSTextStorage)
        │
        ▼
MarkdownStyler (Apply Attributes)
  • Collapses syntax markers to 0.01pt hidden font
  • Applies typography, colors, and line spacing
  • Styles source while preserving text and offsets
        │
        ▼
SyntaxHighlighter (Tree-sitter Spans)
  • Applies language token colors to code blocks
        │
        ▼
NSTextLayoutManagerDelegate
  • Yields custom MarkdownLayoutFragment instances
  • Draws block decorations (code panels, callout borders)
  • Draws embedded LaTeX & Mermaid bitmap renders
  • Draws table grids and gutter checkboxes
```

---

## 4. SplitLayout Value-Type Engine

Pane geometry is governed by `SplitLayout.swift` — a recursive, pure value-type tree:

`SplitLayout` is a struct containing a `SplitNode` root. A node is either
`.leaf(PaneID)` or `.split(SplitNodeGroup)`; each group owns its axis, child
array, and fractions. It is not a binary enum with `leading` and `trailing`
fields.

- Divider resizing and fraction normalization live in the model.
- Same-axis groups flatten, one-child groups collapse, and closed panes are pruned by the workspace.
- Persisted layouts use bounded decoding and validation: at most 16 panes, depth 15, and 12 direct children per split. Invalid structure is rejected or explicitly recovered according to the entry point.

The source of truth is [SplitLayout.swift](../app/MarkDevKit/Splits/SplitLayout.swift).

---

## 5. Filesystem I/O, Recovery, and Asset Ingestion

- **Bounded asynchronous I/O**: `LocalDocumentIO` admits a finite number of reads, authorizations, creates, and save transactions. Blocking filesystem work runs outside the main actor, pending work is bounded, cancellation is propagated explicitly, and `WorkspaceIOLifecycle` tokens reject completions superseded by a newer operation.
- **Descriptor-bound publication**: Save authorization retains directory authority and an expected file version. Transactions stage and publish descriptor-relatively and surface indeterminate durability rather than silently treating it as success.
- **Recovery journal**: A bounded, owner-private two-copy journal records save-transaction phases and supports one-copy degradation. Startup revalidates retained filesystem observations before reusing them; corrupt, divergent, or ambiguous state requires review and blocks ordinary saves. The journal is not an autosave copy of unsaved editor text, and its SHA-256 field is a corruption checksum rather than authentication against a hostile same-UID process.
- **Image paste/drop**: The app accepts at most 16 images, 32 MiB per input and 64 MiB per batch, validates supported image bytes (including a 16-million-pixel raster cap and bounded SVG validation), and transactionally publishes unique files under the document's `assets/` directory. File inputs must survive bounded regular-file reads; stale editor generations and failed publication refuse or roll back the inserted Markdown, except when publication itself is indeterminate and must remain visible for review.
- **Inline image rendering**: Remote fetches are refused. A local raster or vector is read from one retained, no-follow regular-file descriptor, and the requested filename extension remains the format authority even if the descriptor's canonical path changes during a rename. Raster input is capped at 64 MiB, vector input at 1 MiB, declared raster dimensions at 16 million pixels, and malformed or unsupported depth/color metadata fails closed. ImageIO receives a bounded thumbnail request; the returned bitmap is then checked against the dimension, pixel, and 64,000,000-byte decoded-row-storage ceilings before it enters the cache. These are bounds on admitted input and retained decoded output, not a hard bound on ImageIO's transient scratch allocations or total process RSS.

---

## 6. Diagnostics and Support Reporting

Diagnostics is local, typed, and bounded; it is not remote telemetry.

- `DiagnosticsEmitter` retains a fixed-capacity current-process event cut and reports retained, dropped/expired, delivery-drop, pending-write, registration-rejection, and sink-failure counts in Settings.
- **Export Support Report…** flushes through a bounded barrier and exports the current process's in-memory cut. A sink-settlement timeout is represented as a partial report with pending counts, not a clean pass.
- Rotating JSONL files preserve bounded run history under private Application Support storage. **Previous Runs** separately inspects only inactive, trusted run directories and private regular event files; active or untrusted runs are excluded. Each accepted file must decode completely and match its run origin.
- **Export Previous Runs…** writes a canonical, bounded JSON report containing origins, sanitized events, and exact included/omitted counters. Inspection caps retain an explicit uninspected count when knowable and report it as unknown otherwise; paths are never exported.
- Event codes and metadata keys are closed and sanitized. Exports exclude note text, prompts, commands, environment values, full paths, and URL credentials or queries.

---

## 7. Permissions and Privacy Manifests

- The main app is intentionally **unsandboxed**. Arbitrary user-selected vault access and a real interactive terminal are product requirements; MarkDev therefore enforces its own bounded, descriptor-based file checks but does not claim process containment.
- The Quick Look target is **sandboxed**, application-extension-only, and entitled only for user-selected read access. It is a read-only renderer and has no dependency on the app framework or terminal.
- The application, framework, and Quick Look target embed the same privacy manifest. It declares tracking disabled and no collected-data categories. That declaration documents data practice; it does not replace the runtime permission boundaries above.
- `pluginkit` registration is checked by exact extension identifier and bundle path after local installation. Registration is necessary state, not evidence that Finder selected or served MarkDev for a particular preview.

---

## 8. Embedded Terminal and Executable Trust

The `SwiftTerm` drawer hosts the user's interactive login shell and can execute arbitrary commands with the main app's user authority. Before launching a shell or the configured MANVI executable, MarkDev resolves the candidate and walks its physical path descriptor-relatively without following replacement links. It rejects unsafe mounts, non-regular or oversized executables, set-ID bits, unexpected owners, group/world-writable components, and writable allow ACLs; discovery hashes the executable and launch-time checks revalidate its device, inode, size, and nanosecond change time. MANVI is checked before `Foundation.Process` launch, and terminal startup checks again before the shell fork and immediately before sending the fixed environment-variable command.

The final execution APIs still consume a pathname rather than MarkDev's open descriptor. A hostile same-UID process that can rename or modify an owner-writable ancestor can therefore swap the path after the last validation and before `posix_spawn` or the shell reopens it. The checks substantially narrow this time-of-check/time-of-use window but do not eliminate it; the current integration has no `fexecve`/`execveat`-style launch seam.

## 9. Optional assistance and product website

`IntelligenceService` owns Foundation Models requests. Availability is explicit;
unsupported hardware, disabled intelligence, a preparing model, and unsupported
language are distinct states. Assisted replacements validate their source identity
and generation before applying results.

`HarnessRun` launches MANVI separately. `HarnessSettings` owns executable trust,
provider/model configuration, remote-provider consent, and advisory/editing
posture. The subprocess can use a configured remote provider; “on-device” applies
to the Apple Intelligence path, not every Assist engine. A local executable does
not imply local inference.

The [static product website](../website/README.md) is independent of every app
target. It introduces the product and links to canonical Markdown guides; it
adds no browser runtime or dependency to MarkDev.app.
