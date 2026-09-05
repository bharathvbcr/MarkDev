//! Every MarkDev dialect-inventory construct through the shipped `parse`.
//!
//! Each case states the block/span kind the editor draws from, and the
//! collapsed-marker view live preview shows. A construct the product docs
//! call Supported that parses-but-does-not-draw, or that hides syntax with
//! nothing in its place, fails here before it fails on the page.

use markdev::md::{
    model::{BlockKind, CalloutKind, SpanKind, NO_INFO},
    parse_checked, ParseResult,
};

fn parse(source: &str) -> ParseResult {
    parse_checked(source).expect("test fixture must satisfy the parser contract")
}

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

fn has_block(source: &str, kind: BlockKind) -> bool {
    parse(source).blocks.iter().any(|b| b.kind == kind as u16)
}

fn block_data(source: &str, kind: BlockKind) -> Option<u32> {
    parse(source)
        .blocks
        .iter()
        .find(|b| b.kind == kind as u16)
        .map(|b| b.data)
}

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

fn ranges_in_bounds(source: &str) {
    let len = source.encode_utf16().count() as u32;
    let result = parse(source);
    for m in &result.markers {
        assert!(m.start <= m.end, "inverted marker in {source:?}");
        assert!(m.end <= len, "marker past end of {source:?}");
    }
    for s in &result.spans {
        assert!(s.start <= s.end, "inverted span in {source:?}");
        assert!(s.end <= len, "span past end of {source:?}");
    }
    for b in &result.blocks {
        assert!(b.start <= b.end, "inverted block in {source:?}");
        assert!(b.end <= len, "block past end of {source:?}");
    }
}

// MARK: - Headings, paragraphs, lists, quotes

#[test]
fn atx_headings_hide_the_hashes() {
    assert!(has_block("# Title", BlockKind::Heading));
    assert_eq!(block_data("# Title", BlockKind::Heading), Some(1));
    assert_eq!(revealed("# Title"), "Title");
    assert_eq!(block_data("###### Deep", BlockKind::Heading), Some(6));
    assert_eq!(revealed("###### Deep"), "Deep");
    assert_eq!(revealed("## Closed ##"), "Closed");
}

#[test]
fn setext_headings_hide_the_underline() {
    assert_eq!(block_data("Title\n=====", BlockKind::Heading), Some(1));
    assert_eq!(revealed("Title\n====="), "Title");
    assert_eq!(block_data("Subtitle\n-----", BlockKind::Heading), Some(2));
    assert_eq!(revealed("Subtitle\n-----"), "Subtitle");
}

#[test]
fn a_plain_paragraph_hides_nothing() {
    let src = "Just a sentence.";
    assert!(has_block(src, BlockKind::Paragraph));
    assert_eq!(revealed(src), src);
}

#[test]
fn bullet_markers_of_every_flavour_are_hidden() {
    assert_eq!(revealed("* star"), "star");
    assert_eq!(revealed("+ plus"), "plus");
    assert_eq!(revealed("- dash"), "dash");
    assert!(has_block("* star", BlockKind::List));
    assert!(has_block("* star", BlockKind::ListItem));
}

#[test]
fn ordered_lists_accept_dot_and_paren() {
    assert_eq!(block_data("1. first", BlockKind::List), Some(1));
    assert_eq!(revealed("1. first"), "first");
    assert_eq!(block_data("1) first", BlockKind::List), Some(1));
    assert_eq!(revealed("1) first"), "first");
}

#[test]
fn nested_lists_keep_their_items() {
    let src = "- top\n  - nested";
    assert!(has_block(src, BlockKind::List));
    let items = parse(src)
        .blocks
        .iter()
        .filter(|b| b.kind == BlockKind::ListItem as u16)
        .count();
    assert_eq!(items, 2);
}

#[test]
fn blockquote_markers_hide_on_every_line() {
    assert!(has_block("> one\n> two", BlockKind::BlockQuote));
    assert_eq!(revealed("> one\n> two"), "one\ntwo");
}

#[test]
fn every_gfm_alert_flavour_is_a_callout() {
    let cases = [
        ("> [!NOTE]\n> body", CalloutKind::Note),
        ("> [!TIP]\n> body", CalloutKind::Tip),
        ("> [!IMPORTANT]\n> body", CalloutKind::Important),
        ("> [!WARNING]\n> body", CalloutKind::Warning),
        ("> [!CAUTION]\n> body", CalloutKind::Caution),
    ];
    for (src, flavour) in cases {
        assert_eq!(
            block_data(src, BlockKind::Callout),
            Some(flavour as u32),
            "{src}"
        );
        assert_eq!(revealed(src), "body", "{src}");
    }
}

#[test]
fn a_callout_custom_title_is_interned_and_hidden() {
    let src = "> [!NOTE] Custom\n> body";
    let result = parse(src);
    let callout = result
        .blocks
        .iter()
        .find(|b| b.kind == BlockKind::Callout as u16)
        .expect("callout");
    assert_eq!(callout.data, CalloutKind::Note as u32);
    assert_ne!(callout.info, NO_INFO);
    assert_eq!(result.strings[callout.info as usize], "Custom");
    let shown = revealed(src);
    assert!(
        !shown.contains("Custom"),
        "the title belongs on the strip, not in the body: {shown:?}"
    );
    assert!(shown.contains("body"), "{shown:?}");
    ranges_in_bounds(src);
}

// MARK: - Code, rules, HTML, frontmatter

#[test]
fn backtick_and_tilde_fences_are_code() {
    assert!(has_block("```swift\nlet x = 1\n```", BlockKind::CodeBlock));
    assert_eq!(revealed("```swift\nlet x = 1\n```"), "let x = 1\n");
    assert!(has_block("~~~\nplain\n~~~", BlockKind::CodeBlock));
    assert_eq!(revealed("~~~\nplain\n~~~"), "plain\n");
}

#[test]
fn indented_code_hides_the_fence_indent() {
    // The four spaces are syntax, the same way backticks are. Leaving them
    // visible stacks a second indent on the panel the fragment already draws.
    let src = "    let x = 1\n    let y = 2\n";
    assert!(has_block(src, BlockKind::CodeBlock));
    assert_eq!(revealed(src), "let x = 1\nlet y = 2\n");
}

#[test]
fn thematic_breaks_of_every_flavour_collapse() {
    for src in ["---", "***", "___"] {
        assert!(has_block(src, BlockKind::Rule), "{src}");
        assert_eq!(revealed(src), "", "{src}");
    }
}

#[test]
fn html_blocks_keep_their_source() {
    let src = "<div>raw</div>";
    assert!(has_block(src, BlockKind::HtmlBlock));
    assert_eq!(revealed(src), src);
}

#[test]
fn a_lone_img_tag_is_still_an_html_block() {
    // The editor draws it; the parse's job is to name it HTML so the
    // renderer can decide. Hiding it is the draw path's question.
    let src = "<img src=\"pic.png\" alt=\"x\">";
    assert!(has_block(src, BlockKind::HtmlBlock));
}

#[test]
fn yaml_and_toml_frontmatter_are_their_own_block() {
    assert!(has_block(
        "---\ntitle: Note\n---\n\nBody",
        BlockKind::Frontmatter
    ));
    assert_eq!(
        block_data("---\ntitle: Note\n---\n\nBody", BlockKind::Frontmatter),
        Some(0)
    );
    assert!(has_block(
        "+++\ntitle = \"Note\"\n+++\n\nBody",
        BlockKind::Frontmatter
    ));
    assert_eq!(
        block_data("+++\ntitle = \"Note\"\n+++\n\nBody", BlockKind::Frontmatter),
        Some(1)
    );
}

// MARK: - Tables, tasks, math, mermaid

#[test]
fn gfm_tables_emit_the_grid_kinds() {
    let src = "| a | b |\n|---|---|\n| 1 | 2 |";
    let kinds: Vec<u16> = parse(src).blocks.iter().map(|b| b.kind).collect();
    assert!(kinds.contains(&(BlockKind::Table as u16)));
    assert!(kinds.contains(&(BlockKind::TableHead as u16)));
    assert!(kinds.contains(&(BlockKind::TableRow as u16)));
    assert!(kinds.contains(&(BlockKind::TableCell as u16)));
}

#[test]
fn task_markers_report_checked_state_and_hide() {
    assert_eq!(revealed("- [x] done"), "done");
    let checked_doc = parse("- [x] done");
    let checked = checked_doc
        .spans
        .iter()
        .find(|s| s.kind == SpanKind::TaskMarker as u16)
        .expect("checked task");
    assert_eq!(checked.data, 1);
    let open_doc = parse("- [ ] todo");
    let open = open_doc
        .spans
        .iter()
        .find(|s| s.kind == SpanKind::TaskMarker as u16)
        .expect("open task");
    assert_eq!(open.data, 0);
}

#[test]
fn display_math_is_its_own_block() {
    assert!(has_block("$$\na = b\n$$", BlockKind::MathBlock));
    assert_eq!(revealed("$$\na = b\n$$"), "\na = b\n");
}

#[test]
fn parenthesized_inline_and_bracketed_display_math() {
    assert_eq!(spans_of(r"\(a + b\)", SpanKind::InlineMath), vec!["a + b"]);
    assert!(has_block(r"\[a = b\]", BlockKind::MathBlock));
    assert_eq!(revealed(r"\[a = b\]"), "a = b");
    assert_eq!(
        spans_of(r"\\(a + b\\)", SpanKind::InlineMath),
        vec!["a + b"]
    );
    assert!(has_block(r"\\[a = b\\]", BlockKind::MathBlock));
    let fence = "```math\nx\n```";
    assert!(has_block(fence, BlockKind::MathBlock));
    assert!(!has_block(fence, BlockKind::CodeBlock));
    ranges_in_bounds(r"\(a + b\)");
    ranges_in_bounds(r"\[a = b\]");
    ranges_in_bounds(r"\\(a + b\\)");
    ranges_in_bounds(fence);
}

#[test]
fn math_inside_code_and_escaped_link_brackets_stay_literal() {
    assert!(spans_of(r"`\(x\)`", SpanKind::InlineMath).is_empty());
    assert!(!has_block("```\n\\[x\\]\n```", BlockKind::MathBlock));
    let link = r"[\[4\]](https://example.com/p4)";
    assert!(!has_block(link, BlockKind::MathBlock));
    assert!(!spans_of(link, SpanKind::Link).is_empty());
    ranges_in_bounds(link);
}

#[test]
fn mermaid_fences_are_not_code() {
    let src = "```mermaid\ngraph TD;\nA-->B;\n```";
    assert!(has_block(src, BlockKind::MermaidBlock));
    assert!(!has_block(src, BlockKind::CodeBlock));
}

// MARK: - Footnotes, definition lists, link reference definitions

#[test]
fn a_footnote_reference_keeps_its_label() {
    // `[^1]` is syntax around a label. Hiding the whole run leaves a hole
    // where the superscript should sit — the same class of bug a checkbox
    // without a drawn box is.
    let src = "See this[^1].\n\n[^1]: The note.";
    assert_eq!(spans_of(src, SpanKind::FootnoteReference), vec!["1", "1"]);
    assert_eq!(revealed(src), "See this1.\n1The note.");
    assert!(has_block(src, BlockKind::FootnoteDefinition));
}

#[test]
fn a_footnote_without_a_definition_stays_literal() {
    let src = "See this[^1].";
    assert_eq!(revealed(src), src);
    assert!(spans_of(src, SpanKind::FootnoteReference).is_empty());
}

#[test]
fn definition_lists_emit_term_and_definition() {
    let src = "Term\n: Definition";
    assert!(has_block(src, BlockKind::DefinitionList));
    assert!(has_block(src, BlockKind::DefinitionListTitle));
    assert!(has_block(src, BlockKind::DefinitionListDefinition));
    assert_eq!(revealed(src), "TermDefinition");
}

#[test]
fn a_link_reference_definition_is_its_own_block_and_collapses() {
    // pulldown-cmark consumes the definition internally and emits no event,
    // so without a post-pass the line sits in the document as leftover
    // source — visible syntax with no construct owning it.
    let src = "[see][foo]\n\n[foo]: https://example.com";
    assert!(has_block(src, BlockKind::LinkReferenceDefinition));
    assert_eq!(revealed(src), "see\n");
    assert_eq!(spans_of(src, SpanKind::Link), vec!["see"]);
}

#[test]
fn a_standalone_link_reference_definition_is_still_recognised() {
    let src = "[foo]: https://example.com";
    assert!(has_block(src, BlockKind::LinkReferenceDefinition));
    assert_eq!(revealed(src), "");
}

#[test]
fn a_link_reference_definition_may_put_its_destination_on_the_next_line() {
    // CommonMark: optional whitespace after the colon includes one newline.
    let src = "[see][foo]\n\n[foo]:\nhttps://example.com";
    assert!(
        has_block(src, BlockKind::LinkReferenceDefinition),
        "a destination on the following line is still a definition"
    );
    assert_eq!(spans_of(src, SpanKind::Link), vec!["see"]);
    assert_eq!(revealed(src), "see\n");
}

#[test]
fn a_link_reference_definition_may_put_its_title_on_the_next_line() {
    let src = "[see][foo]\n\n[foo]: https://example.com\n\"Title\"";
    assert!(has_block(src, BlockKind::LinkReferenceDefinition));
    assert_eq!(revealed(src), "see\n");
}

#[test]
fn a_paragraph_after_a_link_definition_is_not_swallowed() {
    let src = "[see][foo]\n\n[foo]: https://example.com\n\nNot a title";
    assert!(has_block(src, BlockKind::LinkReferenceDefinition));
    assert!(has_block(src, BlockKind::Paragraph));
    assert_eq!(revealed(src), "see\n\nNot a title");
}

/// Open order: at a shared start, the parent block precedes its children.
///
/// `MarkdownStyler.topLevel` walks this array once and takes the first block
/// whose start is past the previous top-level end. Children first at the same
/// start makes every list item (or definition title) look top-level, which
/// pays paragraph spacing per item. A link-reference-definition post-pass
/// used to sort by `(start, end)` and put the shorter child first.
fn parent_precedes_child(source: &str, parent: BlockKind, child: BlockKind) {
    let result = parse(source);
    let parent_i = result
        .blocks
        .iter()
        .position(|b| b.kind == parent as u16)
        .unwrap_or_else(|| panic!("{source:?}: missing {parent:?}"));
    let child_i = result
        .blocks
        .iter()
        .position(|b| b.kind == child as u16)
        .unwrap_or_else(|| panic!("{source:?}: missing {child:?}"));
    assert!(
        parent_i < child_i,
        "{source:?}: {parent:?} at index {parent_i} ({}..{}) must precede {child:?} at {child_i} ({}..{})",
        result.blocks[parent_i].start,
        result.blocks[parent_i].end,
        result.blocks[child_i].start,
        result.blocks[child_i].end,
    );
    assert_eq!(
        result.blocks[parent_i].start, result.blocks[child_i].start,
        "{source:?}: fixture must share a start so a (start, end) sort would invert them"
    );
}

#[test]
fn a_list_with_a_link_definition_keeps_parent_before_children() {
    parent_precedes_child(
        "- one\n- two\n\n[foo]: https://example.com",
        BlockKind::List,
        BlockKind::ListItem,
    );
}

#[test]
fn a_definition_list_with_a_link_definition_keeps_parent_before_children() {
    parent_precedes_child(
        "Term\n: Definition\n\n[foo]: https://example.com",
        BlockKind::DefinitionList,
        BlockKind::DefinitionListTitle,
    );
}

// MARK: - Inlines

#[test]
fn emphasis_strong_and_strike_hide_their_delimiters() {
    assert_eq!(revealed("*italic*"), "italic");
    assert_eq!(revealed("_italic_"), "italic");
    assert_eq!(revealed("**bold**"), "bold");
    assert_eq!(revealed("__bold__"), "bold");
    assert_eq!(revealed("~~struck~~"), "struck");
}

#[test]
fn extra_backtick_inline_code_keeps_an_inner_tick() {
    assert_eq!(revealed("``a ` b``"), "a ` b");
    assert_eq!(spans_of("``a ` b``", SpanKind::InlineCode), vec!["a ` b"]);
}

#[test]
fn inline_reference_and_angle_autolinks_are_links() {
    assert_eq!(
        spans_of("[label](https://example.com)", SpanKind::Link),
        vec!["label"]
    );
    assert_eq!(revealed("[label](https://example.com)"), "label");
    assert_eq!(
        spans_of("<https://example.com>", SpanKind::Link),
        vec!["https://example.com"]
    );
    assert_eq!(revealed("<https://example.com>"), "https://example.com");
    assert_eq!(
        spans_of("<user@example.com>", SpanKind::Link),
        vec!["user@example.com"]
    );
}

#[test]
fn wikilinks_collapse_to_display_text() {
    assert_eq!(revealed("[[My Note]]"), "My Note");
    assert_eq!(spans_of("[[My Note]]", SpanKind::WikiLink), vec!["My Note"]);
    assert_eq!(revealed("[[target|shown]]"), "shown");
    assert_eq!(revealed("[[Note#Heading]]"), "Note#Heading");
}

#[test]
fn images_keep_alt_text_and_intern_the_destination() {
    assert_eq!(spans_of("![alt](pic.png)", SpanKind::Image), vec!["alt"]);
    assert_eq!(revealed("![alt](pic.png)"), "alt");
    let result = parse("![alt](pic.png)");
    assert!(result.strings.iter().any(|s| s == "pic.png"));
}

#[test]
fn inline_math_highlight_and_tags() {
    assert_eq!(revealed("$x^2$"), "x^2");
    assert_eq!(revealed("==important=="), "important");
    assert_eq!(
        spans_of("==important==", SpanKind::Highlight),
        vec!["important"]
    );
    assert_eq!(revealed("a #project note"), "a #project note");
    assert_eq!(spans_of("a #project note", SpanKind::Tag), vec!["#project"]);
}

#[test]
fn hard_break_syntax_is_hidden_and_the_break_stays() {
    // Two trailing spaces, or a backslash, are the hard-break marker. The
    // newline is the break itself and must remain, or the two lines join.
    assert_eq!(revealed("line  \nbreak"), "line\nbreak");
    assert_eq!(revealed("line\\\nbreak"), "line\nbreak");
}

#[test]
fn exclusions_stay_literal() {
    let quoted = "\"quoted\"";
    assert_eq!(revealed(quoted), quoted);
    assert!(spans_of(quoted, SpanKind::Superscript).is_empty());
    assert!(spans_of(quoted, SpanKind::Subscript).is_empty());
}

#[test]
fn inventory_ranges_never_run_past_the_document() {
    for src in [
        "# Title",
        "Title\n=====",
        "* star\n+ plus\n- dash",
        "1) paren\n2. dot",
        "> [!WARNING]\n> body",
        "```swift\nlet x = 1\n```",
        "~~~\nplain\n~~~",
        "    indented\n",
        "---",
        "<div>raw</div>",
        "---\ntitle: Note\n---\n\nBody",
        "+++\ntitle = \"Note\"\n+++\n\nBody",
        "| a | b |\n|---|---|\n| 1 | 2 |",
        "- [x] done",
        "See this[^1].\n\n[^1]: The note.",
        "Term\n: Definition",
        "[see][foo]\n\n[foo]: https://example.com",
        "[see][foo]\n\n[foo]:\nhttps://example.com",
        "[see][foo]\n\n[foo]: https://example.com\n\"Title\"",
        "[[Note#Heading]]",
        "![alt](pic.png)",
        "$x^2$",
        "==important==",
        "line  \nbreak",
        "line\\\nbreak",
        "```mermaid\ngraph TD;\nA-->B;\n```",
        "$$\na = b\n$$",
    ] {
        ranges_in_bounds(src);
    }
}

#[test]
fn mermaid_and_tables_nest_inside_callouts() {
    let mermaid = "> [!NOTE]\n> ```mermaid\n> graph TD;\n> A-->B;\n> ```\n";
    assert!(
        has_block(mermaid, BlockKind::MermaidBlock),
        "a mermaid fence inside a callout must still be a MermaidBlock"
    );
    assert!(has_block(mermaid, BlockKind::Callout));

    let table = "> [!TIP]\n>\n> | a | b |\n> |---|---|\n> | 1 | 2 |\n";
    assert!(has_block(table, BlockKind::Table), "{table:?} blocks");
    assert!(has_block(table, BlockKind::Callout));

    let math = "- item\n\n  $$\n  x^2\n  $$\n";
    assert!(has_block(math, BlockKind::MathBlock));
}
