# Vault Indexing & Knowledge Graph

MarkDev treats folders of Markdown documents as interconnected **Knowledge Vaults**. The Rust core parses note metadata and maintains an in-memory link graph that powers backlinks, unlinked mentions, and interactive graph visualizations.

---

## 1. Vault Index Architecture

```
Vault Directory (Local Filesystem)
        │
        ▼
core/src/vault/note.rs
  • Extracts Title & Headings Outline
  • Extracts Tags (#tag)
  • Extracts Wikilinks ([[target]]) & standard Markdown links
        │
        ▼
core/src/vault/index.rs (VaultIndex)
  • Builds Forward Link Map
  • Inverts Map into Backlinks
  • Scans for Unlinked Whole-Word Mentions
        │
        ▼
app/MarkDevKit/Vault/ (Swift Wrapper)
  • InspectorView (Outline, Backlinks, Mentions)
  • GraphView (Interactive Force-Directed Canvas)
```

---

## 2. Obsidian-Compatible Wikilink Resolution

MarkDev follows Obsidian's link resolution specification to ensure vaults are 100% portable between tools.

### Supported Wikilink Syntaxes:
- Standard: `[[Note Name]]`
- Heading Anchor: `[[Note Name#Section Heading]]`
- Block Anchor: `[[Note Name#^blockid]]`
- Custom Alias: `[[Note Name|Display Label]]`

### Resolution Rules:
1. **Case-Insensitive Match**: Links match regardless of case (`[[architecture]]` resolves to `Architecture.md`).
2. **Deterministic Tie-Breaking**: If multiple files share the same name across different subfolders, resolution selects:
   1. The match with the **shallowest folder depth** relative to the vault root.
   2. The match that is **alphabetically first** among ties.
3. **No Non-Deterministic Iteration**: Links never resolve based on filesystem directory traversal order.

---

## 3. Whole-Word Unlinked Mentions

When inspecting a note (e.g. `Compiler.md`), MarkDev searches all other notes in the vault for unlinked occurrences of the title "Compiler".

> [!NOTE]
> **Whole-Word Matching Invariant**:
> Unlinked mentions strictly match complete words with word boundary regexes (`\bCompiler\b`). Substring matching is forbidden because it floods the inspector with false positives (such as matching "Roadmap" inside "Roadmapping").

---

## 4. Rebuild Over Patching Policy

When a note is edited or saved, `VaultIndex.update()` rebuilds the entire vault graph rather than attempting incremental edge updates.

### Why?
- Editing a heading in Note A can simultaneously alter backlink targets for Note B, Note C, and Note D.
- In Rust, rebuilding an in-memory graph for a vault of 10,000 notes takes under **5 milliseconds**.
- A full rebuild eliminates entire categories of stale edge synchronization bugs.

---

## 5. Force-Directed Graph Canvas (`GraphView`)

The Vault Graph panel renders an interactive 2D physics simulation of all interconnected notes:

- **Nodes**: Notes (sized by backlink connectivity).
- **Edges**: Directed wikilink connections between notes.
- **Physics Simulation**:
  - **Repulsion Force**: Barnes-Hut n-body repulsive force keeping unrelated nodes separated.
  - **Spring Attraction**: Hooke's law spring force drawing linked notes together into topical clusters.
  - **Damping**: Friction deceleration to stabilize the layout at equilibrium.
- **Interactivity**: Zoom, pan, drag nodes, and click to immediately navigate to a document in the active editor pane.
