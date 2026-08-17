//! MarkDev core — Markdown parsing, vault indexing, and search.
//!
//! This crate holds everything that is not AppKit. It knows nothing about
//! views, fonts, or layout; it turns Markdown text into flat, ordered data
//! that the Swift side renders. Keeping the split that strict is what lets
//! the parser be tested exhaustively without a UI.

pub mod ffi;
pub mod highlight;
pub mod md;
pub mod vault;

pub use md::{parse, BlockKind, ParseResult, SpanKind};
