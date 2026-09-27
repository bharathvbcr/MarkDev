# Markdown support

[Documentation](README.md) / Markdown support

MarkDev preserves Markdown source and renders it with native text and drawing APIs. Its CommonMark parser enables selected extensions, and reads Obsidian's formatting syntax so an Obsidian vault opens as it was written (see [Obsidian syntax](#obsidian-syntax)). It does not promise complete Obsidian plugin, HTML, LaTeX, Mermaid, or MDX compatibility.

| Content | What to expect |
| --- | --- |
| Headings, emphasis, lists, quotes, rules, links | Native styling with source preserved |
| GFM tables | Drawn cell grids with column alignment; source reveals as a table |
| Task lists | Checkboxes that update `- [ ]` / `- [x]` with undo; Obsidian statuses such as `[/]` and `[-]` draw as done and untick to `[ ]` |
| Footnotes | Superscript references and navigation |
| Wikilinks | Note targets, heading and `^block` anchors, and display aliases |
| Math | Inline/display math and supported LaTeX forms, rendered through SwiftMath |
| Mermaid | Supported flowchart, sequence, class, state, ER, and XY forms; unsupported input stays visible as a failure/source state |
| Code fences | Native highlighting for supported Rust, Swift, JavaScript, Python, JSON, and Bash grammars |
| Frontmatter | Structured YAML/TOML display; note indexing extracts supported metadata |
| Callouts | GitHub alerts and every Obsidian callout type, custom titles, and `+`/`-` folding |
| Definition lists, highlights, tags | Selected Markdown extensions with source-preserving styling |
| Local images | Supported raster, SVG, and PDF inputs under validation and size limits, including Obsidian `![[picture.png]]` embeds and `\|300` sizes |
| HTML | A native subset including tables, headings, formatted runs, and local image layouts; not an embedded browser |

## Compatibility boundaries

Remote images are not fetched. Keep an image alongside the document, in its `assets/` directory, or where Obsidian puts pasted pictures — the folder named by Obsidian's own **Default location for new attachments** setting (`attachmentFolderPath` in `.obsidian/app.json`), or an `attachments`, `assets`, `_attachments`, or `media` folder beside the note or in any folder above it up to the vault root (a folder holding `.obsidian` or `.git`). Inline image rendering and image ingestion have different limits; see [editor engine](editor-engine.md).

Math is constrained by the commands SwiftMath can typeset. MarkDev normalizes supported command spellings and checks delimiters so ordinary currency is less likely to become math. Unsupported expressions must not be treated as successful renders.

HTML source is parsed into supported native content; scripts and arbitrary web layouts are not executed. Opening an `.mdx` file does not provide a JSX runtime. `typescript`, `ts`, and `tsx` fences currently use the JavaScript grammar; their acceptance is not a promise of full TypeScript grammar coverage.

Smart punctuation is disabled so text offsets remain faithful to the source. The parser's subscript option is also disabled; tilde runs use its enabled strikethrough behavior. Do not infer syntax support from another Markdown editor's extension list.

Wikilink anchor navigation resolves supported headings and Obsidian block ids (`[[Note#^id]]`, `[[#^id]]`); see [vault resolution](vault-and-graph.md).

## Obsidian syntax

| Syntax | In the editor | In HTML export |
| --- | --- | --- |
| `> [!type] Title` callouts | All Obsidian types — note, abstract/summary/tldr, info, todo, tip/hint, important, success/check/done, question/help/faq, warning/caution/attention, failure/fail/missing, danger/error, bug, example, quote/cite — plus GitHub's five. Unknown types draw as a note titled by their name. The strip shows a symbol per type and the title as plain text | Coloured callout with icon and title; Markdown in the title is rendered |
| Nested callouts (`> > [!type]`) | Each level is its own callout | Nested callout boxes |
| `[[Note#Heading#Subheading]]` | Resolves the subheading inside its parent's section | Links and embeds target that section |
| `> [!type]-` / `> [!type]+` | Foldable; `-` starts folded to its title line. Click the title strip to fold or unfold (▸/▾), in live preview and reading mode; the caret entering the callout also reveals it | `<details>`: folds in the browser without script, closed for `-` and open for `+` |
| `==highlight==` | Highlighted, including around formatting and links (`==**bold**==`, `==[[Note]]==`); a pair that would cut through other formatting stays text | `<mark>`, matching the editor |
| `#tag`, `#nested/tag` | Tag pill, indexed by the vault | Tag pill |
| `%%comment%%`, inline or across lines | Hidden until the caret enters its block, then shown dimmed; nothing inside is a tag, link, or picture. An unclosed `%%` stays text | Removed |
| `^[inline footnote]` | Raised, small, accent-coloured note with its brackets collapsed | A numbered footnote |
| `text ^block-id` | The id collapses; `[[Note#^block-id]]` and `[[#^block-id]]` jump to the block | An anchor; block links navigate to it |
| `![[Note]]`, `![[Note#Heading]]`, `![[Note#^id]]` | Standing alone in a paragraph: a read-only card with the start of the note, section, or block (opens large; refreshed when the note changes). Inside a sentence: a wikilink. Always counted as a backlink | The note, section, or block transcluded in a frame (three levels deep, 2 MiB per note, 8 MiB per export, cycles become links) |
| `![[picture.png]]`, `![[picture.png\|300]]`, or a Markdown image whose alt text ends in `\|300x200` | The picture, at the requested width when it stands alone in a paragraph; found beside the note, in attachment folders, or anywhere in the vault by name | Embedded picture with `width`/`height` |
| `![[song.mp3]]`, `![[clip.mp4]]`, `![[file.pdf]]` | PDF drawn; audio and video are links that open in the system player | `<audio>` / `<video>` players and a PDF link |
| `- [/]`, `- [-]`, `- [>]`, any single status character | A done checkbox showing the status character in place of the tick; clicking unticks to `[ ]` | A checked, struck-through item |

Not supported: Dataview and other plugin query blocks, Canvas and Excalidraw files, editable transclusion (the editor's embed card is a read-only excerpt), and in-editor audio/video playback.

## Export is a separate surface

**Export as HTML…** and **Preview in Browser** (`⌥⌘P`) call the Rust HTML renderer with destination sanitization and payload limits. The page is a single self-contained file that works in current Safari, Chrome, Edge, and Firefox without script or network access:

- Local pictures referenced with Markdown image syntax are copied in as `data:` URIs when their bytes identify as SVG, PNG, JPEG, GIF, WebP, AVIF, BMP, or ICO (up to 8 MiB each, 32 MiB per export). Other files keep their relative destination; remote images are still never fetched.
- Obsidian's `![[picture.png]]` and `![[Note]]` are found the way Obsidian finds them: beside the note, in an attachments folder, or by name anywhere in the vault (the shortest path wins; the search is bounded to 50,000 files).
- Headings receive GitHub-style `id` anchors, so `#heading` links and `[[#Heading]]` wikilinks navigate within the page. Other wikilinks point at the matching `.md` file, relative to the page when the vault can find it.
- Callouts, task lists, footnotes, definition lists, tables, code fences, and the rest of the [Obsidian syntax](#obsidian-syntax) are styled for light and dark appearance and for print.

Math — `$…$`, `$$…$$`, the editor's `\(…\)` / `\[…\]` forms, and ```` ```math ```` fences — is typeset as MathML, which current Safari, Chrome, Edge, and Firefox draw natively without script, fonts, or network access. The editor's rules decide what is math, so `$5 and $10` stays prose. A formula the typesetter does not fully understand is shown as its LaTeX source rather than with error markup, and generated MathML is checked against an element and attribute allowlist before it reaches the page. The export does not include a diagram engine: Mermaid source appears as labelled text. It does not capture the native editor, so inspect exported output before sharing when exact visual fidelity matters.

Links to files a page does not embed (other notes, audio, video, PDFs) are written relative to where the page is saved; **Preview in Browser** uses absolute `file://` links because its page lives in a temporary folder.

**File → Export Vault as Website…** renders every note in the open vault into a folder you choose: each note becomes a page at the same relative path, links and embeds between notes point at each other's pages, and an `index.html` lists every page by folder. Hidden folders, `node_modules`, and the site folder itself are skipped; up to 20,000 notes are exported, and notes that cannot be read are reported rather than stopping the export.

Implementation owners: [Markdown parser](../core/src/md/parse.rs), [native rich renderer](../app/MarkDevKit/Editor/RichContentRenderer.swift), [HTML export](../core/src/html.rs).
