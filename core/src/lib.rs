//! MarkDev core — Markdown parsing, rendering, vault indexing, and search.
//!
//! This crate holds everything that is not AppKit. It knows nothing about
//! views, fonts, or layout; it turns Markdown text into flat, ordered data
//! that the Swift side renders. Keeping the split that strict is what lets
//! the parser be tested exhaustively without a UI.
//!
//! The modules are separate crates so an embedder links only what it uses:
//!
//! | Module              | Crate               | Depends on    |
//! |---------------------|---------------------|---------------|
//! | [`md`]              | `markdev-md`        | —             |
//! | [`highlight`]       | `markdev-highlight` | —             |
//! | [`html`], [`site`]  | `markdev-html`      | `markdev-md`  |
//! | [`vault`]           | `markdev-vault`     | `markdev-md`  |
//!
//! This umbrella re-exports each under the path it always had and owns the
//! C ABI, so MarkDev.app and its header are unaffected by the split.
//!
//! Feature flags:
//! - `ffi` (default): C ABI + cbindgen header generation for MarkDev.app.
//! - `highlight` (default): tree-sitter syntax highlighting.
//! - `mathml` (default): MathML typesetting in HTML export.

#[cfg(feature = "ffi")]
pub mod ffi;
#[cfg(feature = "highlight")]
pub use markdev_highlight as highlight;
pub use markdev_html as html;
pub use markdev_html::site;
pub use markdev_md as md;
pub use markdev_vault as vault;

pub use md::{parse_checked, BlockKind, ParseError, ParseResult, SpanKind};
