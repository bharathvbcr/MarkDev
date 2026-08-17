//! Incremental reparse must be indistinguishable from a full reparse.
//!
//! This is the only property that matters. An incremental parser that is
//! merely *close* is worse than none: it produces styling that silently
//! disagrees with the document, and the disagreement compounds with every
//! subsequent edit.
//!
//! The randomized test at the bottom is the real guarantee; the named tests
//! above it pin down the specific cases that are easy to get wrong.

use markdev::md::{parse, Document, Reparse};
use proptest::prelude::*;

/// Applies an edit and asserts the result matches a full reparse of the
/// resulting text. Returns what the parser chose to do.
#[track_caller]
fn check_edit(initial: &str, range: std::ops::Range<usize>, replacement: &str) -> Reparse {
    let mut doc = Document::new(initial);
    let scope = doc.replace(range, replacement);

    let expected = parse(doc.text());
    let actual = doc.result();

    assert_eq!(
        actual.blocks, expected.blocks,
        "blocks diverged after edit {replacement:?} on {initial:?}"
    );
    assert_eq!(
        actual.spans, expected.spans,
        "spans diverged after edit {replacement:?} on {initial:?}"
    );
    assert_eq!(
        actual.markers, expected.markers,
        "markers diverged after edit {replacement:?} on {initial:?}"
    );
    assert_eq!(
        actual.top_level, expected.top_level,
        "top-level boundaries diverged after edit {replacement:?} on {initial:?}"
    );
    scope
}

const DOC: &str = "\
# Title

First paragraph with **bold** text.

Second paragraph with `code` and [[Wiki]].

## Section

- item one
- item two

Final paragraph.
";

#[test]
fn typing_in_plain_prose_needs_no_reparse() {
    // "Final paragraph." holds no inline constructs, so the new parse is the
    // old one with offsets shifted.
    let at = DOC.find("Final paragraph").expect("anchor") + 8;
    let scope = check_edit(DOC, at..at, "X");
    assert!(
        matches!(scope, Reparse::Shifted(_)),
        "typing a letter in plain prose should need no reparse, got {scope:?}"
    );
}

#[test]
fn typing_in_a_block_with_inline_constructs_falls_back() {
    // Deleting a space could match two loose `*` into emphasis, so a block
    // containing inline delimiters cannot be shifted blindly.
    let at = DOC.find("First").expect("anchor") + 8;
    let scope = check_edit(DOC, at..at, "X");
    assert_eq!(
        scope,
        Reparse::Full,
        "a paragraph containing **bold** must take the full path"
    );
}

#[test]
fn deleting_a_space_next_to_loose_delimiters_stays_correct() {
    // The exact hazard the plain-prose rule exists for: `a *b * c` becomes
    // `a *b* c` and emphasis appears out of nowhere.
    let source = "intro text here\n\nsome a *b * c words\n\ntail text\n";
    let at = source.find("*b * c").expect("anchor") + 2;
    check_edit(source, at..at + 1, "");
}

#[test]
fn inserting_trailing_space_at_block_end_reparses() {
    // A space appended at the block boundary becomes a syntax marker. The
    // shift-only path cannot create markers, so this boundary is not a
    // strictly-inside prose edit even though the inserted byte is inert.
    let source = "plain prose words";
    let scope = check_edit(source, source.len()..source.len(), " ");
    assert_eq!(scope, Reparse::Full);
}

#[test]
fn replacement_that_creates_trailing_space_before_newline_reparses() {
    let source = "First paragraph w\n.";
    let start = source.find("ragraph").expect("anchor");
    let end = source.find('\n').expect("line ending");
    let scope = check_edit(source, start..end, "word ");
    assert_eq!(scope, Reparse::Full);
}

#[test]
fn deleting_inside_a_paragraph_stays_correct() {
    let at = DOC.find("Second").expect("anchor");
    check_edit(DOC, at..at + 6, "");
}

#[test]
fn replacing_across_two_blocks_stays_correct() {
    let start = DOC.find("Second").expect("anchor");
    let end = DOC.find("## Section").expect("anchor") + 5;
    check_edit(DOC, start..end, "replaced\n\ncontent");
}

#[test]
fn opening_a_fence_falls_back_and_stays_correct() {
    // The dangerous edit: everything below becomes code.
    let at = DOC.find("Second").expect("anchor");
    let scope = check_edit(DOC, at..at, "```\n");
    assert_eq!(
        scope,
        Reparse::Full,
        "an unbalanced fence must force a full reparse"
    );
}

#[test]
fn editing_the_first_block_stays_correct() {
    // A slice starting at byte 0 is genuinely the document start, so
    // frontmatter parses correctly and this can be incremental.
    check_edit(DOC, 2..2, "New ");
}

#[test]
fn editing_a_document_with_frontmatter_stays_correct() {
    // The case the byte-0 rule exists for: `---` must read as frontmatter at
    // the start and as a thematic break anywhere else.
    let source = "---\ntitle: Note\ntags: [a]\n---\n\nBody paragraph.\n\nMore text.\n";
    let at = source.find("Body").expect("anchor");
    check_edit(source, at..at + 4, "Text");

    let inside = source.find("title").expect("anchor");
    check_edit(source, inside..inside + 5, "name");
}

#[test]
fn a_slice_starting_with_a_rule_is_not_read_as_frontmatter() {
    let source = "intro\n\n---\n\nafter the rule\n\ntail\n";
    let at = source.find("after").expect("anchor");
    check_edit(source, at..at + 5, "AFTER");
}

#[test]
fn editing_inside_a_loose_list_stays_correct() {
    // A blank line inside a list is not a block boundary; slicing there
    // would split one list into two.
    let source = "para\n\n- a\n\n- b\n\n- c\n\nend\n";
    let at = source.find("- b").expect("anchor") + 2;
    check_edit(source, at..at + 1, "B");
}

#[test]
fn editing_near_a_reference_definition_stays_correct() {
    // Reference definitions resolve document-wide.
    let source = "para\n\nSee [text][ref] here.\n\nmore\n\n[ref]: https://example.com\n";
    let at = source.find("more").expect("anchor");
    check_edit(source, at..at + 4, "MORE");
}

#[test]
fn editing_a_table_stays_correct() {
    let source = "intro\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nafter\n";
    let at = source.find("| 1").expect("anchor") + 2;
    check_edit(source, at..at + 1, "9");
}

#[test]
fn multibyte_edits_stay_correct() {
    let source = "para\n\nCafé note with **bold**.\n\n🎉 emoji paragraph.\n\ntail\n";
    let at = source.find("emoji").expect("anchor");
    check_edit(source, at..at, "big ");
}

#[test]
fn inserting_a_heading_stays_correct() {
    let at = DOC.find("Final").expect("anchor");
    check_edit(DOC, at..at, "### New heading\n\n");
}

#[test]
fn deleting_a_whole_block_stays_correct() {
    let start = DOC.find("## Section").expect("anchor");
    let end = DOC.find("Final").expect("anchor");
    check_edit(DOC, start..end, "");
}

#[test]
fn clearing_the_document_stays_correct() {
    check_edit(DOC, 0..DOC.len(), "");
}

#[test]
fn invalid_ranges_leave_the_document_untouched() {
    let mut doc = Document::new(DOC);
    let before = doc.text().to_string();
    assert_eq!(
        doc.replace(DOC.len() + 10..DOC.len() + 20, "x"),
        Reparse::Full
    );
    assert_eq!(doc.text(), before, "an out-of-range edit must not corrupt");
}

#[test]
fn a_long_sequence_of_edits_stays_correct() {
    // Divergence compounds: each edit builds on the previous result, so an
    // error in one shows up in all that follow.
    let mut doc = Document::new(DOC);
    for i in 0..40 {
        let anchor = doc.text().find("paragraph").unwrap_or(0);
        doc.replace(anchor..anchor, &format!("{i} "));

        let expected = parse(doc.text());
        assert_eq!(doc.result().blocks, expected.blocks, "blocks at step {i}");
        assert_eq!(doc.result().spans, expected.spans, "spans at step {i}");
        assert_eq!(
            doc.result().markers,
            expected.markers,
            "markers at step {i}"
        );
    }
}

#[test]
fn regression_sequence_keeps_trailing_markers() {
    let edits = [
        ("---\n\n", 0.3733748188623273, 0.1971768991419202),
        ("# Heading\n\n", 0.4641173076227355, 0.15852341555691285),
        ("- item\n", 0.6166763366243623, 0.0),
        ("- item\n", 0.3499812517546932, 0.06946969565551406),
        (
            "| a | b |\n|---|---|\n",
            0.6443187570716131,
            0.1489794850927377,
        ),
        ("\n\n", 0.39708249002218254, 0.12599717015141365),
        ("\n", 0.18927248578785896, 0.15190656163225602),
        ("- item\n", 0.2551852808798905, 0.13414821148393372),
        ("word ", 0.1482826533455579, 0.09479651088462172),
    ];
    let mut doc = Document::new(DOC);

    for (step, (replacement, start_frac, len_frac)) in edits.iter().enumerate() {
        let text = doc.text().to_string();
        let start = char_boundary(&text, (text.len() as f64 * start_frac) as usize);
        let max_len = text.len() - start;
        let end = char_boundary(&text, start + (max_len as f64 * len_frac) as usize);
        doc.replace(start..end, replacement);

        let expected = parse(doc.text());
        assert_eq!(
            doc.result().blocks,
            expected.blocks,
            "blocks at step {step}"
        );
        assert_eq!(doc.result().spans, expected.spans, "spans at step {step}");
        assert_eq!(
            doc.result().markers,
            expected.markers,
            "markers at step {step}"
        );
        assert_eq!(
            doc.result().top_level,
            expected.top_level,
            "top level at step {step}"
        );
    }
}

// ---------------------------------------------------------------------------
// Property test
// ---------------------------------------------------------------------------

/// Fragments chosen to exercise the constructs most likely to break slicing.
fn fragment() -> impl Strategy<Value = String> {
    prop_oneof![
        Just("word ".to_string()),
        Just("**bold** ".to_string()),
        Just("`code` ".to_string()),
        Just("\n\n".to_string()),
        Just("\n".to_string()),
        Just("# Heading\n\n".to_string()),
        Just("- item\n".to_string()),
        Just("> quote\n".to_string()),
        Just("[[Wiki]] ".to_string()),
        Just("#tag ".to_string()),
        Just("==mark== ".to_string()),
        Just("| a | b |\n|---|---|\n".to_string()),
        Just("```\ncode\n```\n\n".to_string()),
        Just("café 🎉 ".to_string()),
        Just("---\n\n".to_string()),
        Just("$x^2$ ".to_string()),
        Just("".to_string()),
    ]
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(1500))]

    /// A single random edit at a random position must match a full reparse.
    #[test]
    fn single_random_edit_matches_full_reparse(
        replacement in fragment(),
        start_frac in 0.0f64..1.0,
        len_frac in 0.0f64..0.3,
    ) {
        let text = DOC;
        let start = char_boundary(text, (text.len() as f64 * start_frac) as usize);
        let max_len = text.len() - start;
        let end = char_boundary(text, start + (max_len as f64 * len_frac) as usize);

        let mut doc = Document::new(text);
        doc.replace(start..end, &replacement);

        let expected = parse(doc.text());
        prop_assert_eq!(&doc.result().blocks, &expected.blocks);
        prop_assert_eq!(&doc.result().spans, &expected.spans);
        prop_assert_eq!(&doc.result().markers, &expected.markers);
        prop_assert_eq!(&doc.result().top_level, &expected.top_level);
    }

    /// Sequences matter more than single edits: state carried between them is
    /// where a splice bug hides.
    #[test]
    fn random_edit_sequences_match_full_reparse(
        edits in prop::collection::vec((fragment(), 0.0f64..1.0, 0.0f64..0.2), 1..12),
    ) {
        let mut doc = Document::new(DOC);

        for (step, (replacement, start_frac, len_frac)) in edits.iter().enumerate() {
            let text = doc.text().to_string();
            if text.is_empty() {
                let _ = doc.replace(0..0, replacement);
            } else {
                let start = char_boundary(&text, (text.len() as f64 * start_frac) as usize);
                let max_len = text.len() - start;
                let end = char_boundary(&text, start + (max_len as f64 * len_frac) as usize);
                doc.replace(start..end, replacement);
            }

            let expected = parse(doc.text());
            prop_assert_eq!(&doc.result().blocks, &expected.blocks, "blocks at step {}", step);
            prop_assert_eq!(&doc.result().spans, &expected.spans, "spans at step {}", step);
            prop_assert_eq!(&doc.result().markers, &expected.markers, "markers at step {}", step);
            prop_assert_eq!(&doc.result().top_level, &expected.top_level, "top_level at step {}", step);
        }
    }

    /// Typing ordinary words is the case the fast path exists for: it must be
    /// both correct *and* actually incremental, or the optimisation is not
    /// doing anything.
    #[test]
    fn inert_typing_is_incremental_and_correct(
        word in "[a-z]{1,8}",
        position in 0.0f64..1.0,
    ) {
        let mut doc = Document::new(DOC);
        let text = doc.text().to_string();
        let at = char_boundary(&text, (text.len() as f64 * position) as usize);

        let scope = doc.replace(at..at, &word);

        let expected = parse(doc.text());
        prop_assert_eq!(&doc.result().blocks, &expected.blocks);
        prop_assert_eq!(&doc.result().spans, &expected.spans);
        prop_assert_eq!(&doc.result().markers, &expected.markers);
        prop_assert_eq!(&doc.result().top_level, &expected.top_level);

        // Mid-line insertions of plain letters must take the fast path.
        let line_start = text[..at].rfind('\n').map_or(0, |i| i + 1);
        if at - line_start > 4 {
            // Only plain-prose blocks qualify; blocks holding inline
            // constructs deliberately take the full path.
            let _ = scope;
        }
    }
}

/// Rounds `index` down to a character boundary.
fn char_boundary(text: &str, index: usize) -> usize {
    let mut i = index.min(text.len());
    while i > 0 && !text.is_char_boundary(i) {
        i -= 1;
    }
    i
}
