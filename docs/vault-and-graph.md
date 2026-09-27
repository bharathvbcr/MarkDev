# Vault Indexing & Knowledge Graph

MarkDev treats folders of Markdown documents as interconnected **Knowledge Vaults**. The Rust core parses note metadata and maintains an in-memory link graph that powers backlinks, unlinked mentions, and interactive graph visualizations.

## Saving and reopening vaults

Open a folder with **File → Open Vault…** (`⇧⌘O`), then choose **File → Save Current Vault** or use **Save Current Vault** in the sidebar's **Saved Vaults** section. **File → Show Saved Vaults** reveals that section even when the sidebar is hidden. Both commands are also available in the command palette (`⌘K`).

Saved Vaults shows each folder's name and path. Click an entry to open it; use its minus button to remove it from the saved list. Removing an entry leaves the folder, its notes, and the current workspace intact. Saving remembers a folder location, not a copy or backup of its contents.

The list persists across launches and is shared by all windows. Missing folders and disconnected volumes stay listed; reopening uses the normal vault loader and reports any access failure. If a folder moves, open and save its new location and remove the old entry. Up to 50 vaults can be saved, with an explicit error if the list is full.

`SavedVaultStore` owns the list in the `vaults.saved` preference, separately from workspace session restoration and macOS Recents. It validates local URLs before normalization and bounds stored data. Invalid saved data is reported in the sidebar and retained until **Reset Saved List** is selected; resetting only clears the saved locations.

## Index and link resolution

The Rust [note parser](../core/src/vault/note.rs) extracts metadata, headings,
links, and tags. [Vault](../core/src/vault/index.rs) owns resolution, backlinks,
unlinked mentions, and the search index. Swift's `VaultIndex` coordinates disk
scans and UI updates. Vault query data crosses the C ABI as JSON; editor parse
records use flat structures.

Supported forms include `[[Note]]`, `[[Note#Heading]]`, `[[Note#^block-id]]`,
`[[Note|Label]]`, and Obsidian `![[Note]]` embeds (indexed as links, so they
appear in backlinks and the graph; `![[picture.png]]` and other media embeds
are not note links), plus relative Markdown links. Tags and links inside an
Obsidian `%%comment%%` are not indexed. Resolution uses source-relative
paths where appropriate and case-insensitive name lookup. Ambiguous name matches
are ordered by shallowest path, then alphabetically. These are MarkDev's rules,
not a guarantee of complete compatibility with another application's vault.
The Rust resolver matches anchors against heading text. A `#^blockid` anchor
resolves to the line ending in `^blockid`; a `^blockid` on its own line (after
a table or quote) resolves to the block above it.

Unlinked mentions match whole words case-insensitively against a note's names.
The current implementation omits notes already backlinking to the target and
returns the first matching name/location per remaining note. It is not an
exhaustive list of every textual occurrence. The result carries a UTF-16 offset
for editor navigation.

`Vault.update` reparses changed content and calls `reindex`; unchanged content
returns without rebuilding. Removal also rebuilds derived indexes. This keeps
cross-note dependencies coherent without separately patching each edge. No
universal rebuild-time guarantee is made.

## Disk changes and renames

The Swift watcher is paired with reconciliation to cover missed filesystem
events. Deletion requires proven absence; an unreadable note must not be treated
as a deleted note. Rename updates supported wikilinks and Markdown destinations
while protecting ranges the parser identifies as code or machine-read content.
See [architecture](architecture.md) for the I/O and recovery boundaries.

## Graph behavior

[Graph::build](../core/src/vault/graph.rs) constructs adjacency, applies focus,
depth, tag, and folder filters, and computes a deterministic force-directed
layout. Nodes start on a golden-angle spiral and use 220 iterations of pairwise
repulsion and edge attraction. This is an O(n²) repulsion pass, not Barnes–Hut.

Edges are **undirected and deduplicated** for drawing: two notes linking to one
another form one visible relationship. Unresolved destinations have no graph
node; broken-link queries report them separately.

The graph caps output at 1,500 nodes, retaining the best-connected candidates.
It carries both `total_notes` and `truncated`, so filtering and capacity limits
remain distinguishable. The legend reports displayed and total counts.

Swift's [GraphView](../app/MarkDevKit/Vault/GraphView.swift) fits the finished
coordinates into a Canvas. Hover highlights a neighborhood; clicking a node
opens its note, and clicking empty space clears selection. The current view
does not implement user zoom, pan, or node dragging. Accessible node actions are
ordered by connectivity and capped at 100; this is a subset of the graph.
