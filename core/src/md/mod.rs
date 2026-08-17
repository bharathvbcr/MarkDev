//! Markdown parsing into the flat model the TextKit 2 editor renders from.

pub mod incremental;
pub mod model;
pub mod parse;

pub use incremental::{Document, Reparse};
pub use model::{
    BlockDescriptor, BlockKind, CalloutKind, ParseResult, SpanKind, StyleSpan, SyntaxMarker,
    Utf16Mapper, NO_INFO,
};
pub use parse::parse;
