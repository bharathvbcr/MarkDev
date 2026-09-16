# MarkDev documentation

MarkDev is a native macOS workspace for Markdown and connected notes. These guides describe the current source tree; published downloads can lag behind it. Start with the [release index](releases/README.md) when comparing versions.

## Use MarkDev

1. [User guide](user-guide.md) — open your first note, save a vault, arrange panes, and use keyboard shortcuts.
2. [Markdown support](markdown-support.md) — supported syntax, rich content, and compatibility limits.
3. [Troubleshooting](troubleshooting.md) — missing images, save conflicts, writing tools, Quick Look, and support reports.

## Build and understand it

| Guide | What it covers |
| --- | --- |
| [Getting started](getting-started.md) | Exact toolchain, build/test commands, generated inputs, and package lock |
| [Architecture](architecture.md) | Runtime owners, Swift/Rust contracts, I/O, and extension boundaries |
| [Editor engine](editor-engine.md) | Source preservation, reveal policy, fragment rendering, and rich content |
| [Vault and graph](vault-and-graph.md) | Saved roots, link resolution, indexing, deterministic graph layout |
| [Core integration](core-integration.md) | Embedding the Rust crate with selectable features |
| [Performance](performance.md) | Automated thresholds, measurement methods, and unverified paths |
| [Contributing](../CONTRIBUTING.md) | Invariants, change scope, and validation expectations |

## Maintain and release it

- [Release history](releases/README.md) distinguishes published artifacts from source milestones.
- [Release process](releasing.md) covers local validation, staging, draft upload, and publication checks.
- [Website maintenance](../website/README.md) covers local preview and publishing the static product site.
- [Security policy](../SECURITY.md) describes reporting and actual runtime boundaries.

Documentation changes should follow the source, commands, and tests they describe. Historical measurements are not current benchmarks, a registered extension is not proof of Finder delivery, and unavailable checks must remain visibly unverified.

[Back to MarkDev](../README.md)
