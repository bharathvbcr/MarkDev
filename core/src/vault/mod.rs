//! Vault indexing: notes, the link graph, tags, and search.

pub mod index;
pub mod note;
pub mod search;

pub use index::{Backlink, Resolution, SearchHit, TagCount, UnlinkedMention, Vault};
pub use note::{Heading, Note, WikiLink};
