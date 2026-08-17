# MarkDev Architecture

MarkDev is structured as a two-tier hybrid system:
1. **Rust Core (`core/`)**: High-performance Markdown parsing, syntax highlighting, AST extraction, and vault indexing.
2. **Swift Front-End (`app/`)**: Native macOS application built with AppKit and SwiftUI using Liquid Glass chrome and TextKit 2.

```
┌──────────────────────────────────────────────────────────┐
│                    Swift Front-End                       │
│  ┌───────────────────────┐    ┌───────────────────────┐  │
│  │   SwiftUI Workspace   │    │ TextKit 2 Text View   │  │
│  │ (Splits, Tabs, Glass) │    │ (Fragments, Styler)   │  │
│  └───────────┬───────────┘    └───────────┬───────────┘  │
└──────────────┼────────────────────────────┼──────────────┘
               │ C-ABI / Flat Buffers       │ UTF-16 Offsets
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

The Rust core is a pure static library (`libmarkdev.a`) that knows nothing about macOS or AppKit. It is designed for single-digit millisecond latency on documents exceeding 10,000 lines.

### Key Components:

- **Markdown Parser (`src/md/parse.rs`)**:
  Built on `pulldown-cmark` with SIMD acceleration enabled. It tokenizes CommonMark blocks, headings, lists, tables, code blocks, task lists, and inline formatting.
- **Incremental Engine (`src/md/incremental.rs`)**:
  Features a provably safe **shift-only** fast path. When inert prose is typed away from block markers or line-start indentation, the previous parse tree is retained and offsets are simply shifted in memory without running the parser. Any ambiguous edit safely falls back to a complete reparse.
- **Tree-sitter Syntax Highlighting (`src/highlight/`)**:
  High-accuracy, AST-based syntax highlighting for fenced code blocks. Uses real grammars for Rust, Swift, JavaScript/TypeScript, Python, JSON, and Bash.
- **Vault Index & Graph (`src/vault/`)**:
  Extracts note metadata (headings, tags, wikilinks) into an in-memory graph. Computes backlinks, resolves Obsidian-style wikilinks (`[[Note#Anchor]]`), and performs whole-word search for unlinked mentions.
- **C-ABI FFI Layer (`src/ffi.rs`)**:
  Exposes flat C structures across the FFI. Offset calculations are mapped from Rust byte indices to **UTF-16 code units** via `Utf16Mapper` so `NSTextStorage` receives exact string bounds without decoding overhead.

---

## 2. Shared Framework (`app/MarkDevKit/`)

Both the main application (`app/MarkDev/`) and the Quick Look extension (`app/MarkDevQuickLook/`) link against `MarkDevKit`.

### Modules:

| Module | Purpose |
|---|---|
| **`Core/`** | Swift models and types mapping directly to the Rust FFI structs. |
| **`Editor/`** | TextKit 2 styling, `NSTextLayoutFragment` subclasses, and marker collapsing. |
| **`Render/`** | LaTeX formula rendering via `SwiftMath`, Mermaid diagram rendering via `BeautifulMermaid`. |
| **`Splits/`** | `SplitLayout` pure value-type layout engine for recursive horizontal/vertical panes. |
| **`Vault/`** | `VaultIndex` wrapper, backlinks engine, and interactive force-directed graph canvas. |
| **`Terminal/`** | Integrated VT100/xterm pty terminal drawer built on `SwiftTerm`. |
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
  • Applies kerning offsets for table alignment
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
  • Draws gutter checkboxes
```

---

## 4. SplitLayout Value-Type Engine

Pane geometry is governed by `SplitLayout.swift` — a recursive, pure value-type tree:

```swift
public enum SplitLayout: Equatable, Sendable {
    case leaf(PaneID)
    case split(axis: Axis, fraction: Double, leading: SplitLayout, trailing: SplitLayout)
}
```

### Architectural Guarantees:
- **No Zero-Size Panes**: Divider clamping logic lives entirely within `SplitLayout.adjustDivider()`.
- **Automatic Tree Flattening**: Nested splits on the same axis are automatically flattened.
- **Orphan Pruning**: When panes are closed, `Workspace.pruneOrphanedPanes()` cleans up associated document models to prevent memory leaks.

---

## 5. Embedded Terminal Drawer

The terminal drawer is built on `SwiftTerm` and provides a true VT100/xterm pty session:
- Spawns user's default login shell (`$SHELL` or `/bin/zsh`).
- Supports ANSI escape codes, full color output, and interactive CLI programs (`git`, `cargo`, `vim`, `gh`).
- Docked seamlessly at the bottom of the workspace with configurable slide animation and height persistence.
