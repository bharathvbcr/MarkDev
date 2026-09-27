# Embed the Markdown core

[Documentation](README.md) / Core integration

`core/` builds as a Rust library and a static library, independently of the
macOS application. Cargo features select the optional highlighting, C ABI,
and MathML surfaces. Keep one canonical implementation and rebuild consuming hosts when
replacing it.

| Configuration | APIs | Native build dependencies |
| --- | --- | --- |
| `default-features = false` | Markdown parsing, HTML rendering (formulas as source), vault model | No tree-sitter grammars, C header generator, or LaTeX typesetter |
| `default-features = false, features = ["highlight"]` | Core APIs plus tree-sitter highlighting | Highlight grammars, no cbindgen |
| `default-features = false, features = ["ffi"]` | Core APIs plus C ABI | cbindgen header generation, no highlight grammars |
| `default-features = false, features = ["mathml"]` | Core APIs; HTML export typesets math as MathML | `pulldown-latex` (pure Rust) |
| Defaults | All APIs, including C highlighting ABI and MathML export | Grammars, cbindgen, and `pulldown-latex`; used by MarkDev.app |

A host that needs highlighting without the C header generator can use:

```toml
markdev = { path = "vendor/markdev", default-features = false, features = ["highlight"] }
```

The host must supply the crate at that path, or use its pinned source dependency.
Update the canonical crate and rebuild the host to replace a linked module.
If the host vendors dependencies, use its owned update command and review the
complete source snapshot; do not maintain a second parser in the host.

`just test-core` runs the complete default-feature suite. `just
test-core-features` runs the remaining three configurations, and `just ci-core`
includes both. Targets that import optional APIs declare `required-features`;
the default suite still collects them all. This makes a disabled API an explicit
configuration boundary rather than a compile failure in an unrelated test.

These Rust checks validate the reusable library. They do not establish physical
AppKit behavior or a signed/notarized application release.
