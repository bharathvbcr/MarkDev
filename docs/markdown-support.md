# Markdown support

[Documentation](README.md) / Markdown support

MarkDev preserves Markdown source and renders it with native text and drawing APIs. Its CommonMark parser enables selected extensions. It does not promise complete Obsidian, HTML, LaTeX, Mermaid, or MDX compatibility.

| Content | What to expect |
| --- | --- |
| Headings, emphasis, lists, quotes, rules, links | Native styling with source preserved |
| GFM tables | Drawn cell grids with column alignment; source reveals as a table |
| Task lists | Checkboxes that update `- [ ]` / `- [x]` with undo |
| Footnotes | Superscript references and navigation |
| Wikilinks | Note targets, heading anchors, and display aliases |
| Math | Inline/display math and supported LaTeX forms, rendered through SwiftMath |
| Mermaid | Supported flowchart, sequence, class, state, ER, and XY forms; unsupported input stays visible as a failure/source state |
| Code fences | Native highlighting for supported Rust, Swift, JavaScript, Python, JSON, and Bash grammars |
| Frontmatter | Structured YAML/TOML display; note indexing extracts supported metadata |
| Callouts, definition lists, highlights | Selected Markdown extensions with source-preserving styling |
| Local images | Supported raster, SVG, and PDF inputs under validation and size limits |
| HTML | A native subset including tables, headings, formatted runs, and local image layouts; not an embedded browser |

## Compatibility boundaries

Remote images are not fetched. Keep an image alongside the document or in its `assets/` directory and use a local relative destination. Inline image rendering and image ingestion have different limits; see [editor engine](editor-engine.md).

Math is constrained by the commands SwiftMath can typeset. MarkDev normalizes supported command spellings and checks delimiters so ordinary currency is less likely to become math. Unsupported expressions must not be treated as successful renders.

HTML source is parsed into supported native content; scripts and arbitrary web layouts are not executed. Opening an `.mdx` file does not provide a JSX runtime. `typescript`, `ts`, and `tsx` fences currently use the JavaScript grammar; their acceptance is not a promise of full TypeScript grammar coverage.

Smart punctuation is disabled so text offsets remain faithful to the source. The parser's subscript option is also disabled; tilde runs use its enabled strikethrough behavior. Do not infer syntax support from another Markdown editor's extension list.

Wikilink anchor navigation resolves supported headings. Do not assume Obsidian-style block-ID navigation; see [vault resolution](vault-and-graph.md).

## Export is a separate surface

**Export as HTML…** calls the Rust HTML renderer with destination sanitization and payload limits. It does not capture the native editor or include a web math/diagram engine. Inspect exported output before sharing when exact visual fidelity matters.

Implementation owners: [Markdown parser](../core/src/md/parse.rs), [native rich renderer](../app/MarkDevKit/Editor/RichContentRenderer.swift), [HTML export](../core/src/html.rs).
