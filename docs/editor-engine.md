# Editor Engine & TextKit 2 Pipeline

MarkDev features an in-place rich Markdown editor built on Apple's **TextKit 2** framework. It bridges the gap between raw text editors and visual WYSIWYG tools by rendering rich styling and diagrams inline while keeping the underlying text buffer 100% standard CommonMark.

---

## 1. Non-Destructive Marker Collapsing

Most visual Markdown editors strip markdown syntax markers (such as `**`, `_`, ```` ``` ````, or `#`) from their internal text models. This creates severe drawbacks:
- Copying text (`⌘C`) copies stripped plain text instead of Markdown.
- Find and replace breaks on formatting syntax.
- The document cannot be safely edited by external tools while open.

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
1. **Clipboard Fidelity**: Copying any selection places valid CommonMark onto the pasteboard.
2. **Native Undo**: Character insertions and deletions follow standard text undo semantics.
3. **Caret Handling**: `MarkdownTextView` inspects `HiddenRanges` to gracefully step the caret over collapsed marker runs without the cursor getting trapped.

---

## 2. Reveal Policy & Caret Interaction

When the user moves the insertion caret inside a formatted run (e.g. inside `**bold text**`), the `RevealPolicy` temporarily expands the surrounding markers to normal font size so the syntax can be edited.

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

- **LaTeX**: Rendered using Core Text via `SwiftMath` (pure Swift).
- **Mermaid**: Rendered via `BeautifulMermaid` using layout engines ported from the Eclipse Layout Kernel (ELK).
- **Asynchronous Cache**: Rendered bitmaps are cached by content hash.
- **Relayout Invalidation**: When formula source code is edited, `invalidateFragments` forces TextKit to discard cached fragment heights and recalculate document bounds.
