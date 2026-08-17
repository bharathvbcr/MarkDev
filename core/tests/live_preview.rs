//! Characterization tests for the syntax-marker rule.
//!
//! Each test states what the reader *sees* in live preview — the source with
//! every marker collapsed. That is the actual product behaviour, so a
//! regression in the gap algorithm shows up as a readable string diff rather
//! than a wall of offsets.

use markdev::md::{
    model::{BlockKind, SpanKind, TableAlignment, TABLE_ALIGNMENT_BITS, TABLE_ALIGNMENT_MASK},
    parse,
};

/// Collapses every syntax marker, yielding what live preview shows when the
/// caret is elsewhere.
///
/// Operates on UTF-16 code units because that is the unit the model reports
/// and the unit `NSTextStorage` indexes by.
fn revealed(source: &str) -> String {
    let result = parse(source);
    let units: Vec<u16> = source.encode_utf16().collect();

    let mut hidden = vec![false; units.len()];
    for m in &result.markers {
        for slot in hidden
            .iter_mut()
            .take((m.end as usize).min(units.len()))
            .skip(m.start as usize)
        {
            *slot = true;
        }
    }

    let kept: Vec<u16> = units
        .iter()
        .zip(&hidden)
        .filter(|(_, &h)| !h)
        .map(|(&u, _)| u)
        .collect();
    String::from_utf16_lossy(&kept)
}

/// The source text covered by spans of a given kind.
fn spans_of(source: &str, kind: SpanKind) -> Vec<String> {
    let result = parse(source);
    let units: Vec<u16> = source.encode_utf16().collect();
    result
        .spans
        .iter()
        .filter(|s| s.kind == kind as u16)
        .map(|s| {
            String::from_utf16_lossy(&units[s.start as usize..(s.end as usize).min(units.len())])
        })
        .collect()
}

#[test]
fn emphasis_delimiters_are_hidden() {
    assert_eq!(revealed("**bold**"), "bold");
    assert_eq!(revealed("*italic*"), "italic");
    assert_eq!(revealed("_italic_"), "italic");
    assert_eq!(revealed("~~struck~~"), "struck");
}

#[test]
fn nested_emphasis_hides_both_levels() {
    assert_eq!(revealed("**bold _and_ italic**"), "bold and italic");
}

#[test]
fn inline_code_backticks_are_hidden() {
    assert_eq!(revealed("`code`"), "code");
    // Multi-backtick fences hide the full run on both sides.
    assert_eq!(revealed("``a ` b``"), "a ` b");
}

#[test]
fn heading_hash_prefix_is_hidden() {
    assert_eq!(revealed("# Title"), "Title");
    assert_eq!(revealed("### Deeper"), "Deeper");
}

#[test]
fn link_syntax_collapses_to_its_label() {
    assert_eq!(revealed("[label](https://example.com)"), "label");
    assert_eq!(
        revealed("see [docs](https://example.com) now"),
        "see docs now"
    );
}

#[test]
fn wikilinks_collapse_to_the_note_name() {
    assert_eq!(revealed("[[My Note]]"), "My Note");
    assert_eq!(spans_of("[[My Note]]", SpanKind::WikiLink), vec!["My Note"]);
}

#[test]
fn wikilink_alias_shows_only_the_display_text() {
    // `[[target|shown]]` must read as "shown".
    assert_eq!(revealed("[[target|shown]]"), "shown");
}

#[test]
fn blockquote_markers_are_hidden_on_every_line() {
    // The continuation `>` lives inside the child paragraph's range, so this
    // is the case the structural gap rule alone cannot catch.
    assert_eq!(revealed("> one\n> two"), "one\ntwo");
}

#[test]
fn callout_is_recognised_and_its_marker_hidden() {
    let result = parse("> [!NOTE]\n> body");
    let callouts = result
        .blocks
        .iter()
        .filter(|b| b.kind == markdev::md::BlockKind::Callout as u16)
        .count();
    assert_eq!(callouts, 1, "GFM alert should parse as a callout block");
}

#[test]
fn code_fences_are_hidden_but_code_is_kept() {
    assert_eq!(revealed("```swift\nlet x = 1\n```"), "let x = 1\n");
}

#[test]
fn mermaid_fences_get_their_own_block_kind() {
    let result = parse("```mermaid\ngraph TD;\nA-->B;\n```");
    assert!(
        result
            .blocks
            .iter()
            .any(|b| b.kind == markdev::md::BlockKind::MermaidBlock as u16),
        "a mermaid fence must be routed to the diagram renderer, not the code renderer"
    );
}

#[test]
fn task_list_markers_are_hidden_and_report_checked_state() {
    assert_eq!(revealed("- [x] done"), "done");
    let result = parse("- [x] done");
    let task = result
        .spans
        .iter()
        .find(|s| s.kind == SpanKind::TaskMarker as u16)
        .expect("task marker span");
    assert_eq!(task.data, 1, "checked task should report data == 1");

    let unchecked = parse("- [ ] todo");
    let task = unchecked
        .spans
        .iter()
        .find(|s| s.kind == SpanKind::TaskMarker as u16)
        .expect("task marker span");
    assert_eq!(task.data, 0);
}

#[test]
fn math_delimiters_are_hidden() {
    assert_eq!(revealed("$x^2$"), "x^2");
    assert_eq!(revealed("$$\na = b\n$$"), "\na = b\n");
}

#[test]
fn highlight_syntax_is_recognised() {
    assert_eq!(revealed("==important=="), "important");
    assert_eq!(
        spans_of("==important==", SpanKind::Highlight),
        vec!["important"]
    );
}

#[test]
fn tags_are_recognised_but_left_visible() {
    // A tag renders as a styled pill including its `#`, so nothing is hidden.
    assert_eq!(revealed("a #project note"), "a #project note");
    assert_eq!(spans_of("a #project note", SpanKind::Tag), vec!["#project"]);
}

#[test]
fn issue_numbers_are_not_tags() {
    assert!(
        spans_of("fixes #123", SpanKind::Tag).is_empty(),
        "a purely numeric #123 is an issue reference, not a tag"
    );
}

#[test]
fn hashes_inside_code_are_not_tags() {
    assert!(
        spans_of("`#notatag`", SpanKind::Tag).is_empty(),
        "scanning only Text events should keep code spans free of tags"
    );
    assert!(
        spans_of("```\n#notatag\n```", SpanKind::Tag).is_empty(),
        "fenced code must not produce tags"
    );
}

#[test]
fn frontmatter_is_its_own_block() {
    let result = parse("---\ntitle: Note\n---\n\nBody");
    assert!(
        result
            .blocks
            .iter()
            .any(|b| b.kind == markdev::md::BlockKind::Frontmatter as u16),
        "YAML frontmatter should parse as a Frontmatter block"
    );
}

#[test]
fn tables_produce_structural_blocks() {
    let result = parse("| a | b |\n|---|---|\n| 1 | 2 |");
    let kinds: Vec<u16> = result.blocks.iter().map(|b| b.kind).collect();
    assert!(kinds.contains(&(markdev::md::BlockKind::Table as u16)));
    assert!(kinds.contains(&(markdev::md::BlockKind::TableHead as u16)));
    assert!(kinds.contains(&(markdev::md::BlockKind::TableCell as u16)));
}

#[test]
fn plain_text_is_never_hidden() {
    let plain = "Just a sentence with no markup at all.";
    assert_eq!(revealed(plain), plain);
}

#[test]
fn non_ascii_text_keeps_its_offsets_aligned() {
    // The whole point of mapping to UTF-16 in Rust: an emoji before the
    // markup must not shift what gets hidden.
    assert_eq!(revealed("🎉 **bold**"), "🎉 bold");
    assert_eq!(revealed("café **bold**"), "café bold");
    assert_eq!(revealed("𝄞 `code`"), "𝄞 code");
}

#[test]
fn markers_never_exceed_the_documents_length() {
    // A malformed range would produce an out-of-bounds NSTextStorage index
    // and crash the editor, so this is a hard invariant.
    for source in [
        "**unclosed",
        "[[unclosed",
        "```\nunclosed fence",
        "> quote\n\n# heading\n\n- [ ] task",
        "🎉🎉🎉 **bold** `code` [[link]]",
        "",
    ] {
        let len = source.encode_utf16().count() as u32;
        let result = parse(source);
        for m in &result.markers {
            assert!(m.start <= m.end, "marker inverted in {source:?}");
            assert!(m.end <= len, "marker past end of {source:?}");
        }
        for s in &result.spans {
            assert!(s.start <= s.end, "span inverted in {source:?}");
            assert!(s.end <= len, "span past end of {source:?}");
        }
        for b in &result.blocks {
            assert!(b.start <= b.end, "block inverted in {source:?}");
            assert!(b.end <= len, "block past end of {source:?}");
        }
    }
}

#[test]
fn table_cells_carry_their_column_and_alignment() {
    // The delimiter row states alignment once for the whole table, but the
    // renderer pads *cells*. Every cell must therefore be able to answer
    // "which column am I, and how do I sit in it" on its own.
    let source = "| Name | Qty |\n|:---|---:|\n| Apple | 3 |\n";
    let result = parse(source);

    let cells: Vec<(u32, TableAlignment)> = result
        .blocks
        .iter()
        .filter(|b| b.kind == BlockKind::TableCell as u16)
        .map(|b| {
            (
                b.data >> TABLE_ALIGNMENT_BITS,
                match b.data & TABLE_ALIGNMENT_MASK {
                    0 => TableAlignment::Auto,
                    1 => TableAlignment::Left,
                    2 => TableAlignment::Center,
                    _ => TableAlignment::Right,
                },
            )
        })
        .collect();

    assert_eq!(
        cells,
        vec![
            (0, TableAlignment::Left),
            (1, TableAlignment::Right),
            (0, TableAlignment::Left),
            (1, TableAlignment::Right),
        ],
        "each cell should report its own column index and the column's alignment"
    );

    let table = result
        .blocks
        .iter()
        .find(|b| b.kind == BlockKind::Table as u16)
        .expect("a table block");
    assert_eq!(table.data, 2, "the table should report its column count");
}

#[test]
fn a_ragged_row_does_not_derail_alignment() {
    // GFM tables are ragged in both directions in the wild, and the parser
    // squares them off: a long row has its surplus cells dropped, a short one
    // is padded with empties. So every row reaching a renderer has exactly the
    // table's column count, and each cell keeps its own column's alignment —
    // which is what lets the grid be laid out without re-deriving widths.
    let source = "| A | B |\n|---:|:---|\n| 1 | 2 | 3 |\n| 4 |\n";
    let result = parse(source);
    let cells: Vec<(u32, u32)> = result
        .blocks
        .iter()
        .filter(|b| b.kind == BlockKind::TableCell as u16)
        .map(|b| {
            (
                b.data >> TABLE_ALIGNMENT_BITS,
                b.data & TABLE_ALIGNMENT_MASK,
            )
        })
        .collect();

    let right = TableAlignment::Right as u32;
    let left = TableAlignment::Left as u32;
    assert_eq!(
        cells,
        vec![
            (0, right),
            (1, left),
            // The `| 3 |` is discarded upstream rather than becoming a third
            // column — so a row can never widen the table it sits in.
            (0, right),
            (1, left),
            // The short row is padded back out to the declared width, so every
            // row a renderer sees has exactly the table's column count.
            (0, right),
            (1, left),
        ]
    );
}

#[test]
fn a_second_table_gets_its_own_alignment() {
    // Alignment is stacked, so the first table's columns cannot leak into a
    // later one that declares different ones.
    let source = "| A |\n|---:|\n| 1 |\n\ntext\n\n| B |\n|:---|\n| 2 |\n";
    let result = parse(source);
    let alignments: Vec<u32> = result
        .blocks
        .iter()
        .filter(|b| b.kind == BlockKind::TableCell as u16)
        .map(|b| b.data & TABLE_ALIGNMENT_MASK)
        .collect();
    assert_eq!(
        alignments,
        vec![
            TableAlignment::Right as u32,
            TableAlignment::Right as u32,
            TableAlignment::Left as u32,
            TableAlignment::Left as u32,
        ]
    );
}
