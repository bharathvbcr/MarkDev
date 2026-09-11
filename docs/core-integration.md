# Embed the Markdown core

`core/` is a Rust library independent of the macOS application. A host chooses
the parts it needs through Cargo features. That is the same modularity as the
rest of this stack: **DevCouncil** is independently selectable components, **Manvi**
wraps them, and **GitPulse** takes only the MarkDev and DevCouncil features it
needs. Update the canonical crate and rebuild the host; do not fork a second
parser.

| Configuration | APIs | Native build dependencies |
| --- | --- | --- |
| `default-features = false` | Markdown parsing, HTML rendering, vault model | No tree-sitter grammars or C header generator |
| `default-features = false, features = ["highlight"]` | Core APIs plus tree-sitter highlighting | Highlight grammars, no cbindgen |
| `default-features = false, features = ["ffi"]` | Core APIs plus C ABI | cbindgen header generation, no highlight grammars |
| Defaults | All APIs, including C highlighting ABI | Grammars and cbindgen; used by MarkDev.app |

For example, GitPulse links the highlighting library without running the C
header generator:

```toml
markdev = { path = "vendor/markdev", default-features = false, features = ["highlight"] }
```

The host must supply the crate at that path, or use its pinned source dependency.
Update the canonical crate and rebuild the host to replace a linked module.
GitPulse uses its own vendoring command to preserve the complete source snapshot
and hashes; do not maintain a separate parser in the consuming application.

`just test-core` runs the complete default-feature suite. `just
test-core-features` runs the remaining three configurations, and `just ci-core`
includes both. Targets that import optional APIs declare `required-features`;
the default suite still collects them all. This makes a disabled API an explicit
configuration boundary rather than a compile failure in an unrelated test.

These Rust checks validate the reusable library. They do not establish physical
AppKit behavior or a signed/notarized application release.
