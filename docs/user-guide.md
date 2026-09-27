# Using MarkDev

[Documentation](README.md) / User guide

This guide describes the current source tree. For downloads, architecture requirements, and signing status, see [releases](releases/README.md). The app requires macOS 26 or later.

## Your first note

Choose **File → New Document** (`⌘N`), write a heading and a few lines, then choose **File → Save** (`⌘S`) and pick a location. **Open File…** (`⌘O`) opens an existing Markdown file. You can work on a single file without opening a vault.

Use the editor mode control (**Live**, **Source**, **Read**) or the Editor menu (**Live Preview**, **Source Mode**, **Reading Mode**) to switch views. Live Preview reveals syntax around the caret so you can edit it. Reading is read-only. The underlying document remains Markdown in every mode.

Use **Save As…** (`⇧⌘S`) for another destination. MarkDev checks for changes on disk before saving. If a conflict or recovery warning appears, review it before continuing; the recovery journal is not a backup of unsaved typing.

## Turn a folder into a vault

Choose **File → Open Vault…** (`⇧⌘O`) and select a folder containing notes. The sidebar lists the vault's files. The command palette (`⌘K`) offers files, headings, and workspace actions.

Choose **File → Save Current Vault** to remember the folder. Reopen it from **Saved Vaults** in the sidebar; **File → Show Saved Vaults** reveals the list. Saving a vault remembers its location, not a copy of its contents. Removing a saved entry leaves your files intact. Missing or disconnected folders remain listed so you can reconnect them.

Use `[[Note Name]]` to connect notes, `[[Note Name#Heading]]` for a section, or `[[Note Name|Label]]` for different display text. Relative Markdown destinations work too. The inspector shows outline and link information. Use **Editor → Graph View** (`⌥⌘G`) to inspect connections and open notes from the graph. See [vault and graph](vault-and-graph.md) for resolution and filtering details.

## Keep related work beside your note

Use **Editor → Split Right** or **Split Down** to create another pane. Each pane has its own tabs. Drag a divider to adjust space; use **Focus Next Pane** and **Focus Previous Pane** to move between panes. The layout supports at most 16 panes.

Open the terminal with `⌘J`. It can be placed at the bottom or in the inspector. Moving the terminal preserves its sessions; changing the active note does not change a running shell's directory. A terminal executes real commands with your user account's permissions.

Hold **Space** over a supported link or navigator item to peek at its content. Finder's Space-bar preview is a separate Quick Look extension and depends on installation and system provider selection.

## Technical writing

Tables, task lists, local images, math, and supported Mermaid diagrams render in the editor, and so does Obsidian's formatting syntax — callouts, highlights, comments, embeds, block references, inline footnotes, and custom task statuses. See [Obsidian syntax](markdown-support.md#obsidian-syntax). Click a task checkbox to update its Markdown; the edit is undoable. Rich blocks offer controls where available, such as copying a code listing or opening a rendered picture at a larger size.

Save your note before adding image assets. Image paste/drop validates supported inputs and publishes them under the document's `assets/` directory. Remote images are not fetched while reading a note. See [Markdown support](markdown-support.md) for limitations.

Choose **File → Export as HTML…** to export a note through the bounded HTML renderer, **File → Preview in Browser** (`⌥⌘P`) to open the same rendering in your default browser, or **Print…** (`⌘P`) to print. Exported pages embed the note's local pictures (SVG, PNG, JPEG, GIF, WebP, AVIF, BMP, ICO), follow the system light or dark appearance, and give every heading a link anchor. Math is typeset for the browser as MathML. The HTML export is a separate rendering path, so math may look slightly different from the editor, and Mermaid diagrams appear as source.

## Optional writing assistance

**Writing Tools → Rewrite Selection…** (`⇧⌘E`) works on selected text. **Proofread Document** (`⇧⌘P`) and **Read This Note** provide document assistance. Apple Intelligence must be supported, enabled, and ready; the panel explains when it is unavailable. Runs can cover bounded excerpts or passages, and the UI reports those limits. Review proposed changes before applying them.

The Assist panel also offers **MANVI**, installed and configured separately. Choose its executable, provider/model, and authority in Settings. Advisory and file-editing authority are different modes. Provider configuration can allow remote processing after confirmation, so MANVI is not covered by the on-device Apple Intelligence description.

## Keyboard reference

| Shortcut | Action |
| --- | --- |
| `⌘N` / `⌘O` / `⇧⌘O` | New document / open file / open vault |
| `⌘S` / `⇧⌘S` | Save / Save As |
| `⌘K` | Command palette |
| `⌘\` | Toggle sidebar |
| `⌥⌘I` / `⌘J` / `⌥⌘G` | Inspector / terminal / graph |
| `⌘F` / `⌥⌘F` | Find / find and replace |
| `⌘G` / `⇧⌘G` | Next / previous match |
| `⌘E` | Use selection for Find |
| `⌘1`–`⌘9` | Select a tab in the focused pane |
| `⌥⌘→` / `⌥⌘←` | Next / previous pane |
| `⌃⌘W` | Close pane |
| `⌘=` / `⌘-` / `⌘0` | Zoom in / out / actual size |
| `⌘P` / `⌥⌘P` | Print / preview in browser |
| `⇧⌘E` / `⇧⌘P` | Rewrite selection / proofread document |
| Hold `Space` | Peek over a supported link or tree item |

Menus disable actions when the focused workspace cannot perform them. The mode commands also show their Control-number shortcuts in the Editor menu.

[Get help](troubleshooting.md) · [Build from source](getting-started.md)
