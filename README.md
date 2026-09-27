# MarkDev

[![Website](https://img.shields.io/badge/website-markdev.vbcr.dev-B91C1C?style=flat&logo=safari&logoColor=white)](https://markdev.vbcr.dev/)

**A native home for Markdown, connected notes, and the work around them.**

Write in a single document or open a folder as a vault. MarkDev brings in-place Markdown editing, native math and diagrams, backlinks, split panes, and a terminal into one macOS workspace. Your notes stay ordinary files.

[Start using MarkDev](docs/user-guide.md) · [Documentation](docs/README.md) · [Published releases](https://github.com/bharathvbcr/MarkDev/releases) · [Website source](website/README.md)

## Write, connect, and build

- **Keep the source.** Live preview styles Markdown in place; Source and Reading modes give you different views of the same text. Copy, find, and undo operate on that source.
- **Make technical notes readable.** Render tables, task lists, LaTeX, supported Mermaid diagrams, local images, and a supported subset of HTML without a browser renderer in the app.
- **Work across notes.** Open a folder, save it to Saved Vaults, follow wikilinks and relative Markdown links, inspect backlinks, and explore a filtered link graph.
- **Arrange your workspace.** Use tabs, split panes, a command palette, and an integrated terminal that can sit below or beside your document.
- **Use assistance when you choose.** Apple Intelligence writing tools run on-device when available. Optional MANVI integration uses your configured harness and provider; its permissions and data destination are separate choices.

The application is built with SwiftUI, AppKit, TextKit 2, and a Rust core. The product website is a separate static site; it is not part of the editor runtime.

## Get MarkDev

MarkDev requires **macOS 26 or later**. Check the architecture and signing notes attached to the artifact you download.

| Channel | What it contains |
| --- | --- |
| [Published v0.0.3](https://github.com/bharathvbcr/MarkDev/releases/tag/v0.0.3) | Apple silicon only; ad-hoc signed and not notarized. Latest published release verified on 2026-09-13. |
| Current source | App version **0.0.5, build 11** in `project.yml`; Release recipes build `arm64` and `x86_64` slices. Source changes may not be in a published download. |

See the [release index](docs/releases/README.md) for version history and the [user guide](docs/user-guide.md) for first steps. A successful local build or Quick Look registration does not establish Gatekeeper acceptance or Finder preview delivery on another Mac.

## Build from source

Use the [build guide](docs/getting-started.md) to install the exact tools required by this checkout. Build and test commands live in the [justfile](justfile).

```sh
git clone https://github.com/bharathvbcr/MarkDev.git
cd MarkDev
just build
just run
```

| Command | Purpose |
| --- | --- |
| `just test` | Rust and Swift tests |
| `just check` | Release contracts, Rust formatting/lints, and both test suites |
| `just ci-local` | Pinned toolchain, core/feature/performance checks, Swift tests, and universal Release build |
| `just generate` | Regenerate Xcode project and plist inputs from `project.yml` |
| `just check-docs` | Documentation contracts and static website link checks |
| `just website` | Serve the product site locally on port 8000 |

Do not edit the generated Xcode project or plists. The tracked SwiftPM `Package.resolved` is retained as the transitive dependency lock. See [Contributing](CONTRIBUTING.md) before changing dependencies or build inputs.

## Performance, with explicit gates

These are test thresholds, not a promise about every keystroke or Mac. The [performance guide](docs/performance.md) explains sampling, historical measurements, and remaining verification limits.

| Measurement | Target Budget | Enforced Gate |
| --- | --- | --- |
| **Release Parse (10k lines)** | `< 16.6ms` | `< 16.6ms` (Release) |
| **Prose Keystroke (10k lines)** | `< 16.6ms` | `< 50ms` (Debug) |
| **Caret Navigation** | `< 2.0ms` | `< 16.6ms` (one frame) |

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
| `⌥ ⌘ G` | Toggle Vault Graph View |
| `⌥ ⌘ P` | Preview Note in Browser |
| `⌘ F` | Find in Document |
| `⌥ ⌘ F` | Find and Replace |
| `⌘ G` / `⇧ ⌘ G` | Find Next / Previous Match |
| `Space` *(hold)* | Peek preview link or tree item under cursor |

## Learn the workspace

| For | Start here |
| --- | --- |
| Writers | [User guide and shortcuts](docs/user-guide.md), [Markdown support](docs/markdown-support.md) |
| Contributors | [Build setup](docs/getting-started.md), [architecture](docs/architecture.md), [editor pipeline](docs/editor-engine.md) |
| Vault and integration work | [Vault and graph](docs/vault-and-graph.md), [embed the Rust core](docs/core-integration.md) |
| Troubleshooting and releases | [Support](docs/troubleshooting.md), [release process](docs/releasing.md), [security policy](SECURITY.md) |

MarkDev's core can be embedded independently through Cargo features. MANVI is optional; neither it nor the rest of the DevCouncil ecosystem is required to write notes.

[MIT license](LICENSE) · [Code of conduct](CODE_OF_CONDUCT.md)
