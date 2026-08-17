//! Flat, FFI-friendly model of a parsed Markdown document.
//!
//! The editor never walks a tree. It needs three ordered, flat arrays it can
//! turn into text attributes and layout fragments in a single pass:
//!
//! - [`StyleSpan`] — inline ranges that get character attributes.
//! - [`SyntaxMarker`] — ranges of literal syntax (`**`, `` ` ``, `](url)`)
//!   that live preview collapses when the caret is elsewhere.
//! - [`BlockDescriptor`] — block ranges that map to custom layout fragments.
//!
//! All offsets are **UTF-16 code unit offsets**, not byte offsets, because
//! that is what `NSTextStorage` indexes by. The conversion happens here, in
//! Rust, so Swift never has to think about it. See [`Utf16Mapper`].

use serde::{Deserialize, Serialize};

/// Inline construct that carries character attributes.
///
/// Discriminants are part of the FFI contract — append, never renumber.
#[repr(u16)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum SpanKind {
    Emphasis = 0,
    Strong = 1,
    Strikethrough = 2,
    Superscript = 3,
    Subscript = 4,
    InlineCode = 5,
    Link = 6,
    /// `[[Note]]` or `[[Note|alias]]`.
    WikiLink = 7,
    Image = 8,
    /// `$x$`
    InlineMath = 9,
    /// Heading text itself; `data` carries the level (1–6).
    Heading = 10,
    /// `- [ ]` / `- [x]`; `data` is 1 when checked.
    TaskMarker = 11,
    FootnoteReference = 12,
    /// `#tag`, detected by MarkDev rather than pulldown-cmark.
    Tag = 13,
    /// `==highlight==`, detected by MarkDev rather than pulldown-cmark.
    Highlight = 14,
    /// Raw inline HTML.
    InlineHtml = 15,
}

/// Block construct that maps to a custom `NSTextLayoutFragment`.
///
/// Discriminants are part of the FFI contract — append, never renumber.
#[repr(u16)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum BlockKind {
    Paragraph = 0,
    /// `data` carries the level (1–6).
    Heading = 1,
    /// Fenced or indented code; `info` indexes the language string table.
    CodeBlock = 2,
    /// A fenced block whose language is `mermaid`, split out so the editor
    /// can route it to the diagram renderer without string comparison.
    MermaidBlock = 3,
    /// `$$…$$`
    MathBlock = 4,
    Table = 5,
    TableHead = 6,
    TableRow = 7,
    TableCell = 8,
    BlockQuote = 9,
    /// GFM alert (`> [!NOTE]`); `data` carries the [`CalloutKind`].
    Callout = 10,
    /// `data` is 1 for ordered lists.
    List = 11,
    ListItem = 12,
    Rule = 13,
    /// YAML or TOML metadata block at the top of the document.
    Frontmatter = 14,
    FootnoteDefinition = 15,
    HtmlBlock = 16,
    DefinitionList = 17,
    DefinitionListTitle = 18,
    DefinitionListDefinition = 19,
}

/// GFM alert flavour, carried in [`BlockKind::Callout`]'s `data` field.
#[repr(u16)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum CalloutKind {
    Note = 0,
    Tip = 1,
    Important = 2,
    Warning = 3,
    Caution = 4,
}

/// How a table column's cells sit in their column.
///
/// Packed into [`BlockKind::TableCell`]'s `data` alongside the column index —
/// see [`BlockDescriptor::data`]. Two bits, so a column index of any plausible
/// width still fits above it.
#[repr(u32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum TableAlignment {
    /// No `:` in the delimiter row. Renders left, but is distinct from an
    /// explicit `:---` so a formatter can round-trip the source unchanged.
    Auto = 0,
    Left = 1,
    Center = 2,
    Right = 3,
}

/// Bits of a `TableCell`'s `data` given over to its alignment.
pub const TABLE_ALIGNMENT_BITS: u32 = 2;
/// Mask selecting the alignment out of a `TableCell`'s `data`.
pub const TABLE_ALIGNMENT_MASK: u32 = (1 << TABLE_ALIGNMENT_BITS) - 1;

/// An inline range carrying character attributes.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct StyleSpan {
    /// UTF-16 offset of the first code unit.
    pub start: u32,
    /// UTF-16 offset one past the last code unit.
    pub end: u32,
    pub kind: u16,
    /// Nesting depth, so the editor can resolve overlapping emphasis.
    pub depth: u16,
    /// Kind-specific payload: heading level, task checked-ness, or an index
    /// into the string table for links and wikilinks.
    pub data: u32,
}

/// A run of literal syntax characters that live preview can collapse.
///
/// Derived structurally rather than by pattern-matching each construct: a
/// marker is any part of a construct's source range not covered by its
/// children. That makes `**`, `` ` ``, `# `, `> `, ` ``` `, `[[`, and
/// `](url)` all fall out of one rule.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct SyntaxMarker {
    pub start: u32,
    pub end: u32,
    /// Index into the block array, so the reveal policy can flip every
    /// marker in the caret's block without searching.
    pub block: u32,
}

/// A block-level range that maps to a layout fragment.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct BlockDescriptor {
    pub start: u32,
    pub end: u32,
    pub kind: u16,
    pub depth: u16,
    /// Heading level, callout kind, list orderedness, or a table's column
    /// count. For [`BlockKind::TableCell`] it packs two values —
    /// `(column << TABLE_ALIGNMENT_BITS) | alignment` — because a cell needs
    /// both to be laid out and there is only one payload field.
    pub data: u32,
    /// Index into the string table (code fence language), or `u32::MAX`.
    pub info: u32,
}

/// Sentinel for "no string table entry".
pub const NO_INFO: u32 = u32::MAX;

/// The complete parse result handed across the FFI boundary.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ParseResult {
    pub spans: Vec<StyleSpan>,
    pub markers: Vec<SyntaxMarker>,
    pub blocks: Vec<BlockDescriptor>,
    /// Deduplicated strings referenced by `data`/`info` indices.
    pub strings: Vec<String>,
    /// **Byte** ranges of top-level (depth 0) blocks, in document order.
    ///
    /// Not exposed over the FFI — this exists for incremental reparsing,
    /// which needs to cut the document at boundaries CommonMark actually
    /// recognises. Blank lines are not sufficient: a loose list contains
    /// them, and cutting there would split one list into two.
    ///
    /// Byte ranges rather than UTF-16 because slicing `&str` is what they
    /// are used for.
    pub top_level: Vec<std::ops::Range<usize>>,
}

impl ParseResult {
    /// Interns `s`, returning its string-table index.
    pub fn intern(&mut self, s: &str) -> u32 {
        if let Some(i) = self.strings.iter().position(|existing| existing == s) {
            return i as u32;
        }
        self.strings.push(s.to_owned());
        (self.strings.len() - 1) as u32
    }
}

/// Converts byte offsets into UTF-16 code unit offsets.
///
/// `pulldown-cmark` reports byte offsets into the source `&str`; `NSTextStorage`
/// indexes by UTF-16 code unit. Getting this wrong only shows up once a
/// document contains non-ASCII text, which is exactly when it is most
/// confusing — so the conversion is centralised here and tested directly.
///
/// Pure-ASCII documents (the common case) skip the table entirely, since the
/// two offsets coincide.
pub struct Utf16Mapper {
    /// `None` when the source is ASCII and offsets map one-to-one.
    checkpoints: Option<Vec<(u32, u32)>>,
    len_utf16: u32,
}

impl Utf16Mapper {
    pub fn new(source: &str) -> Self {
        if source.is_ascii() {
            return Self {
                checkpoints: None,
                len_utf16: source.len() as u32,
            };
        }

        // One entry per character boundary: (byte offset, utf16 offset).
        let mut checkpoints = Vec::with_capacity(source.chars().count() + 1);
        let mut utf16 = 0u32;
        for (byte, ch) in source.char_indices() {
            checkpoints.push((byte as u32, utf16));
            utf16 += ch.len_utf16() as u32;
        }
        checkpoints.push((source.len() as u32, utf16));

        Self {
            checkpoints: Some(checkpoints),
            len_utf16: utf16,
        }
    }

    /// Total length of the source in UTF-16 code units.
    pub fn len_utf16(&self) -> u32 {
        self.len_utf16
    }

    /// Maps a byte offset to a UTF-16 offset.
    ///
    /// Byte offsets that fall inside a multi-byte character resolve to the
    /// start of that character, and offsets past the end clamp to the end,
    /// so a bad range can never produce an out-of-bounds text index.
    pub fn to_utf16(&self, byte: usize) -> u32 {
        let Some(checkpoints) = &self.checkpoints else {
            return (byte as u32).min(self.len_utf16);
        };
        match checkpoints.binary_search_by_key(&(byte as u32), |&(b, _)| b) {
            Ok(i) => checkpoints[i].1,
            // Landed inside a multi-byte character: snap to its start.
            Err(0) => 0,
            Err(i) => checkpoints[i - 1].1,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ascii_offsets_map_one_to_one() {
        let m = Utf16Mapper::new("hello world");
        assert_eq!(m.to_utf16(0), 0);
        assert_eq!(m.to_utf16(6), 6);
        assert_eq!(m.len_utf16(), 11);
    }

    #[test]
    fn multibyte_characters_shift_utf16_offsets() {
        // "é" is 2 bytes but 1 UTF-16 unit.
        let s = "aébc";
        let m = Utf16Mapper::new(s);
        assert_eq!(m.to_utf16(0), 0); // a
        assert_eq!(m.to_utf16(1), 1); // é starts
        assert_eq!(m.to_utf16(3), 2); // b — byte 3, utf16 2
        assert_eq!(m.to_utf16(4), 3); // c
        assert_eq!(m.len_utf16(), 4);
    }

    #[test]
    fn astral_characters_take_two_utf16_units() {
        // "𝄞" is 4 bytes and 2 UTF-16 units (a surrogate pair).
        let s = "a𝄞b";
        let m = Utf16Mapper::new(s);
        assert_eq!(m.to_utf16(0), 0);
        assert_eq!(m.to_utf16(1), 1); // 𝄞 starts
        assert_eq!(m.to_utf16(5), 3); // b sits after the surrogate pair
        assert_eq!(m.len_utf16(), 4);
    }

    #[test]
    fn offsets_inside_a_character_snap_to_its_start() {
        let m = Utf16Mapper::new("a𝄞b");
        // Bytes 2..4 are interior to the astral character.
        assert_eq!(m.to_utf16(2), 1);
        assert_eq!(m.to_utf16(3), 1);
    }

    #[test]
    fn offsets_past_the_end_clamp() {
        assert_eq!(Utf16Mapper::new("abc").to_utf16(99), 3);
        assert_eq!(Utf16Mapper::new("a𝄞b").to_utf16(99), 4);
    }

    #[test]
    fn interning_deduplicates() {
        let mut r = ParseResult::default();
        assert_eq!(r.intern("swift"), 0);
        assert_eq!(r.intern("rust"), 1);
        assert_eq!(r.intern("swift"), 0);
        assert_eq!(r.strings.len(), 2);
    }
}
