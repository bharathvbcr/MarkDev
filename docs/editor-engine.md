# Editor Engine & TextKit 2 Pipeline

MarkDev features an in-place rich Markdown editor built on Apple's **TextKit 2** framework. It bridges the gap between raw text editors and visual WYSIWYG tools by rendering rich styling and diagrams inline while keeping the underlying Markdown source intact, including supported extensions.

---

## 1. Non-Destructive Marker Collapsing

MarkDev keeps source text and presentation separate. Rich styling must not silently rewrite the note or discard syntax.

### The 0.01pt Font Solution

MarkDev preserves the full Markdown source in `NSTextStorage` at all times. When a syntax marker is collapsed, `MarkdownStyler` applies `EditorTheme.hiddenMarkerFontSize` (0.01pt) to the marker's character range:

```swift
// Collapsed markers shrink to microscopic size rather than being deleted
let attributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: EditorTheme.hiddenMarkerFontSize),
    .foregroundColor: NSColor.clear
]
```

### Benefits:
1. **Clipboard Fidelity**: Copying a text selection preserves its Markdown source; an arbitrary partial selection is not guaranteed to form a complete Markdown construct.
2. **Native Undo**: Character insertions and deletions follow standard text undo semantics.
3. **Caret Handling**: `MarkdownTextView` inspects `HiddenRanges` to gracefully step the caret over collapsed marker runs without the cursor getting trapped.

---

## 2. Reveal Policy & Caret Interaction

In Live Preview, `RevealPolicy` reveals the blocks intersecting the selection. Revealing is per block rather than per inline marker, and touching a table reveals the whole table. Source mode reveals all blocks; Reading mode reveals none.

### Protected Markers (`markersRequiringReplacement`):
Constructs that consist *entirely* of syntax (such as `- [ ]` checkboxes and `---` horizontal rules) are never collapsed into invisibility unless a replacement view or fragment drawing is actively rendered in their place. This prevents the perception of data loss.

---

## 3. Assisted Editing and AI Safety

AI-assisted writing and proofreading features share the same document graph as native edits, but only apply changes when source identity checks still match:

- `WritingAssistant` verifies the exact snapshot before replacement.
- `DocumentAssistant` validates selection offsets before applying corrections.
- If content mutates while a model task is in-flight, the result is discarded or surfaced as stale rather than applying out-of-date edits.

---

## 4. Custom Text Layout Fragments (`MarkdownLayoutFragment`)

TextKit 2 breaks text into `NSTextLayoutFragment` instances corresponding to layout paragraphs. MarkDev provides a custom `MarkdownLayoutFragment` subclass that handles custom background panels, borders, and embedded drawings.

```
┌─────────────────────────────────────────────────────────────┐
│ Code Block Background Frame (decorationRect)               │
│                                                             │
│  fn main() {                                                │
│      println!("Hello, MarkDev!");                           │
│  }                                                          │
└─────────────────────────────────────────────────────────────┘
```

### Key Rules for Fragment Drawing:

1. **Width Must Match Container**: `layoutFragmentFrame.width` only covers the text of that specific line. Background panels must use `decorationRect` (reaching the text container margin) to prevent ragged, stepped backgrounds.
2. **Seam-Free Block Corners**: A multi-line block consists of multiple fragments. Each fragment checks its `BlockEdge` (`.first`, `.middle`, `.last`, or `.single`) so rounded corners are only drawn on the true top and bottom edges.
3. **Styler Pass Sequencing**: Syntax highlighting (`SyntaxHighlighter`) must always execute **after** `MarkdownStyler.apply`. The styler resets paragraph attributes; running highlighting earlier results in erased colors.

---

## 5. GFM Tables as a Grid

A table row's source is collapsed and its cells are drawn as a real grid (`TableGrid` / `TableRowLayout`). Kerning the `|` separators cannot wrap a cell: a row is one paragraph, `NSParagraphStyle` has one `headIndent`, and a cell wider than the container wrapped back to the row's leading edge.

Columns are solved by lowering a common ceiling until the table fits, so a table only ever takes room from its widest columns. A row that fails to resolve a layout renders as nothing, so `tableWidth` has a floor rather than a silent skip.

---

## 6. Inline LaTeX and Mermaid Rendering

For mathematical formulas (`$E=mc^2$` / `$$\int f(x)dx$$`) and Mermaid diagrams, `RichContentRenderer` renders high-resolution bitmaps directly into layout fragments.

- **LaTeX**: Rendered using Core Text via `SwiftMath` (a native typesetter).
- **Mermaid**: Rendered via `BeautifulMermaid` using layout engines ported from the Eclipse Layout Kernel (ELK).
- **Bounded Shared Cache**: Rendered bitmaps are cached using the full render context under entry and pixel budgets. On-demand rendering occurs on the main actor. Each opportunistic prefetch step performs at most one render or one image filesystem probe; cheap dictionary-only hits and refusals for non-image content may drain in the same step. The Quick Look build compiles prefetch out.
- **Relayout Invalidation**: When formula source code is edited, `invalidateFragments` forces TextKit to discard cached fragment heights and recalculate document bounds.

---

## 7. Local Inline-Image Rendering Boundary

`RichContentRenderer` refuses network image references. It opens a local file once with no symlink following, retains that descriptor through the read, and binds successful cache entries to the canonical path, descriptor generation, immutable requested format, and sizing context. Transient open or changed-file failures are not cached. An expensive vector reuses one cache-owned bitmap rather than creating an unaccounted second owner.

Raster files are limited to 64 MiB of compressed input and 16 million declared pixels; SVG and PDF files use a 1 MiB input ceiling. Raster metadata must identify supported dimensions, depth, and color model before ImageIO receives a thumbnail request. The requested maximum dimension is derived from conservative pixel and row-storage estimates, and the returned bitmap is post-checked for dimensions, pixel count, row stride, and at most 64,000,000 bytes of decoded row storage.

Those limits bound the retained descriptor input, requested thumbnail, admitted returned bitmap, and cache. They do **not** prove a ceiling on ImageIO's internal transient allocations, simultaneous compressed/decoded buffers, or total process RSS. ImageIO remains a platform trust boundary.

---

## 8. Image Paste and Drop Boundary

Image ingestion is app-only and is compiled out of the Quick Look renderer. `MarkdownTextView` snapshots a finite pasteboard representation, while `DocumentAssetStore` validates at most 16 inputs with 32 MiB per-item and 64 MiB batch limits. Local file inputs use bounded regular-file reads that detect replacement during the read; image type, raster dimensions, and bounded SVG structure are checked before a unique name is reserved.

The actor retains the document directory handle while decoding. Only after the editor accepts the Markdown mutation does it transactionally publish the corresponding file under `assets/`. Cancellation or a stale document generation discards unpublished reservations. Proven failures remove the exact pending Markdown insertion; an indeterminate publication remains visible for explicit review so MarkDev does not manufacture an orphan by guessing that no file was written.

## 9. Ownership and appearance

`MarkdownTextView` coordinates parsing, styling, reveal state, and fragment
resolution. `InlineMathTypesetter` handles both prose and table-cell formulas.
`canonicalMathSource` normalizes supported entities and command aliases for both
rendering and cache lookup. Tables reveal as a unit when source editing requires
it; cells use separately styled source copies for measurement.

Fragments share a palette store and track render generations. Resizing or
changing appearance must refresh cached grid geometry and bitmaps even when
TextKit reuses fragments. `ContentZoomViewer` requests a new render for supported
rich content; it is absent from the Quick Look build.

HTML support lives in the native HTML flow/parser/layout sources and accepts a
bounded subset. It is not browser execution. The [syntax guide](markdown-support.md)
describes user-facing limits, and [performance](performance.md) separates measured
thresholds from intended interaction budgets.
