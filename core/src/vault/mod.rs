//! Vault indexing: notes, the link graph, tags, and search.

pub mod graph;
pub mod index;
pub mod note;
pub mod search;

pub use graph::{Graph, GraphEdge, GraphNode, GraphQuery};
pub use index::{Backlink, Resolution, SearchHit, TagCount, UnlinkedMention, Vault};
pub use note::{Heading, Note, WikiLink};
