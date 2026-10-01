use std::ptr;

use markdev::ffi::{
    md_blocks, md_document_blocks, md_document_free, md_document_len_utf16, md_document_markers,
    md_document_new, md_document_replace, md_document_spans, md_document_string,
    md_document_string_count, md_free, md_markers, md_parse, md_spans, md_string, md_string_count,
};
use markdev::md::{
    parse_checked, ParseError, MAX_DOCUMENT_BYTES, MAX_INTERNED_STRINGS, MAX_INTERNED_STRING_BYTES,
    MAX_PARSE_NESTING, MAX_STRUCTURAL_RECORDS, MAX_TOTAL_STRING_BYTES,
};

#[test]
fn panic_on_rejection_parse_is_not_exported_to_untrusted_callers() {
    let crate_root = include_str!("../src/lib.rs");
    let markdown_module = include_str!("../crates/markdev-md/src/lib.rs");
    let parser = include_str!("../crates/markdev-md/src/parse.rs");

    assert!(
        !crate_root.contains("pub use md::{parse,"),
        "the crate root must expose only the checked parser"
    );
    assert!(
        !markdown_module.contains("pub use parse::{parse,"),
        "the Markdown module must expose only the checked parser"
    );
    assert!(
        !parser.contains("pub fn parse(source:"),
        "the panic-on-refusal parser must not remain reachable through its public module"
    );
}

#[test]
fn one_shot_parse_accepts_exactly_the_limit_and_rejects_plus_one() {
    let exact = vec![b'a'; MAX_DOCUMENT_BYTES];
    let accepted = unsafe { md_parse(exact.as_ptr(), exact.len()) };
    assert!(!accepted.is_null());
    unsafe { md_free(accepted) };

    let oversized = vec![b'a'; MAX_DOCUMENT_BYTES + 1];
    let rejected = unsafe { md_parse(oversized.as_ptr(), oversized.len()) };
    assert!(rejected.is_null(), "a +1 document must not be parsed");
}

#[test]
fn parse_null_pointer_is_valid_only_for_empty_input() {
    let empty = unsafe { md_parse(ptr::null(), 0) };
    assert!(
        !empty.is_null(),
        "null plus zero is the canonical empty slice"
    );
    unsafe { md_free(empty) };

    assert!(unsafe { md_parse(ptr::null(), 1) }.is_null());
}

#[test]
fn incremental_construction_rejects_invalid_pairs_and_oversized_input() {
    let empty = unsafe { md_document_new(ptr::null(), 0) };
    assert!(!empty.is_null());
    unsafe { md_document_free(empty) };

    assert!(unsafe { md_document_new(ptr::null(), 1) }.is_null());

    let oversized = vec![b'a'; MAX_DOCUMENT_BYTES + 1];
    assert!(unsafe { md_document_new(oversized.as_ptr(), oversized.len()) }.is_null());
}

#[test]
fn incremental_plus_one_edit_is_rejected_without_mutating_the_document() {
    let exact = vec![b'a'; MAX_DOCUMENT_BYTES];
    let document = unsafe { md_document_new(exact.as_ptr(), exact.len()) };
    assert!(!document.is_null());
    let before = unsafe { md_document_len_utf16(document) };

    let replacement = b"bb";
    let status = unsafe {
        md_document_replace(
            document,
            before - 1,
            before,
            replacement.as_ptr(),
            replacement.len(),
        )
    };

    assert_eq!(status, 0, "oversized edits must report rejection");
    assert_eq!(
        unsafe { md_document_len_utf16(document) },
        before,
        "rejection must be atomic"
    );
    unsafe { md_document_free(document) };
}

#[test]
fn incremental_replacement_pointer_pairs_and_utf8_are_rejected_atomically() {
    let source = b"plain prose";
    let document = unsafe { md_document_new(source.as_ptr(), source.len()) };
    assert!(!document.is_null());
    let before = unsafe { md_document_len_utf16(document) };

    let empty_status = unsafe { md_document_replace(document, 2, 2, ptr::null(), 0) };
    assert!(
        empty_status == 1 || empty_status == 2,
        "null plus zero is a valid empty replacement"
    );
    assert_eq!(unsafe { md_document_len_utf16(document) }, before);

    assert_eq!(
        unsafe { md_document_replace(document, 2, 2, ptr::null(), 1) },
        0
    );
    assert_eq!(unsafe { md_document_len_utf16(document) }, before);

    let invalid_utf8 = [0xff_u8];
    assert_eq!(
        unsafe { md_document_replace(document, 2, 2, invalid_utf8.as_ptr(), 1) },
        0
    );
    assert_eq!(
        unsafe { md_document_len_utf16(document) },
        before,
        "every rejected replacement must preserve the old document"
    );
    unsafe { md_document_free(document) };
}

#[test]
fn parser_accepts_the_nesting_boundary_and_rejects_the_next_frame() {
    // The paragraph itself is one open frame in addition to its blockquotes.
    let exact = format!("{}text", "> ".repeat(MAX_PARSE_NESTING - 1));
    assert!(parse_checked(&exact).is_ok());

    let too_deep = format!("{}text", "> ".repeat(MAX_PARSE_NESTING));
    assert_eq!(parse_checked(&too_deep), Err(ParseError::TooDeep));
}

#[test]
fn parser_rejects_the_first_structural_record_past_the_cap() {
    // One paragraph block plus one tag span per token: the first source lands
    // exactly on the combined cap without spending marker or string records.
    let exact = format!("{}#a", "#a ".repeat(MAX_STRUCTURAL_RECORDS - 2));
    let parsed = parse_checked(&exact).expect("exact structural bound");
    assert_eq!(
        parsed.blocks.len() + parsed.spans.len() + parsed.markers.len(),
        MAX_STRUCTURAL_RECORDS
    );

    let oversized = format!("{exact} #b");
    assert_eq!(
        parse_checked(&oversized),
        Err(ParseError::TooManyRecords),
        "the first excess record must reject the whole parse"
    );
}

#[test]
fn individual_interned_strings_are_bounded_before_copying() {
    let exact_target = "a".repeat(MAX_INTERNED_STRING_BYTES);
    let exact = format!("[x]({exact_target})");
    assert!(parse_checked(&exact).is_ok());

    let oversized_target = "a".repeat(MAX_INTERNED_STRING_BYTES + 1);
    let oversized = format!("[x]({oversized_target})");
    assert_eq!(parse_checked(&oversized), Err(ParseError::StringTooLong));
}

#[test]
fn aggregate_interned_string_bytes_are_bounded() {
    fn document(string_count: usize, trailing: bool) -> String {
        let mut source = String::new();
        for index in 0..string_count {
            let prefix = format!("{index:04x}");
            let target = format!(
                "{prefix}{}",
                "a".repeat(MAX_INTERNED_STRING_BYTES - prefix.len())
            );
            source.push_str("[x](");
            source.push_str(&target);
            source.push_str(")\n");
        }
        if trailing {
            source.push_str("[x](overflow)\n");
        }
        source
    }

    let exact_count = MAX_TOTAL_STRING_BYTES / MAX_INTERNED_STRING_BYTES;
    let exact = document(exact_count, false);
    let parsed = parse_checked(&exact).expect("exact aggregate string bound");
    assert_eq!(
        parsed.strings.iter().map(String::len).sum::<usize>(),
        MAX_TOTAL_STRING_BYTES
    );

    let oversized = document(exact_count, true);
    assert_eq!(
        parse_checked(&oversized),
        Err(ParseError::TooManyStringBytes)
    );
}

#[test]
fn distinct_interned_string_count_is_bounded() {
    fn document(count: usize) -> String {
        let mut source = String::with_capacity(count * 16);
        for index in 0..count {
            source.push_str("[x](value-");
            source.push_str(&format!("{index:05x}"));
            source.push_str(")\n");
        }
        source
    }

    let exact = document(MAX_INTERNED_STRINGS);
    let parsed = parse_checked(&exact).expect("exact distinct-string bound");
    assert_eq!(parsed.strings.len(), MAX_INTERNED_STRINGS);

    let oversized = document(MAX_INTERNED_STRINGS + 1);
    assert_eq!(parse_checked(&oversized), Err(ParseError::TooManyStrings));
}

#[test]
fn nul_in_text_or_string_bearing_construct_rejects_the_whole_parse() {
    for source in [
        "before\0after",
        "[la\0bel](target)",
        "[label](before\0after)",
        "```ru\0st\ncode\n```",
    ] {
        assert_eq!(parse_checked(source), Err(ParseError::InteriorNul));
        assert!(unsafe { md_parse(source.as_ptr(), source.len()) }.is_null());
        assert!(unsafe { md_document_new(source.as_ptr(), source.len()) }.is_null());
    }
}

#[test]
fn incremental_parser_rejections_preserve_the_complete_previous_state() {
    let source = b"[x](safe)";
    let document = unsafe { md_document_new(source.as_ptr(), source.len()) };
    assert!(!document.is_null());
    let before_length = unsafe { md_document_len_utf16(document) };
    assert_eq!(unsafe { md_document_string_count(document) }, 1);

    let oversized_target = format!("[x]({})", "a".repeat(MAX_INTERNED_STRING_BYTES + 1));
    assert_eq!(
        unsafe {
            md_document_replace(
                document,
                0,
                before_length,
                oversized_target.as_ptr(),
                oversized_target.len(),
            )
        },
        0
    );
    assert_eq!(unsafe { md_document_len_utf16(document) }, before_length);

    let nul = b"before\0after";
    assert_eq!(
        unsafe { md_document_replace(document, 0, before_length, nul.as_ptr(), nul.len(),) },
        0
    );
    assert_eq!(unsafe { md_document_len_utf16(document) }, before_length);
    assert_eq!(unsafe { md_document_string_count(document) }, 1);
    let mut length = 0usize;
    let string = unsafe { md_document_string(document, 0, &mut length) };
    assert_eq!(
        unsafe { std::slice::from_raw_parts(string, length) },
        b"safe"
    );

    unsafe { md_document_free(document) };
}

#[test]
fn output_accessors_require_writable_count_or_length_pointers() {
    let source = b"[title](destination)";
    let handle = unsafe { md_parse(source.as_ptr(), source.len()) };
    assert!(!handle.is_null());
    assert!(unsafe { md_spans(handle, ptr::null_mut()) }.is_null());
    assert!(unsafe { md_markers(handle, ptr::null_mut()) }.is_null());
    assert!(unsafe { md_blocks(handle, ptr::null_mut()) }.is_null());
    assert!(unsafe { md_string(handle, 0, ptr::null_mut()) }.is_null());

    let mut count = usize::MAX;
    assert!(unsafe { md_spans(ptr::null(), &mut count) }.is_null());
    assert_eq!(count, 0);
    count = usize::MAX;
    assert!(unsafe { md_markers(ptr::null(), &mut count) }.is_null());
    assert_eq!(count, 0);
    count = usize::MAX;
    assert!(unsafe { md_blocks(ptr::null(), &mut count) }.is_null());
    assert_eq!(count, 0);
    assert_eq!(unsafe { md_string_count(ptr::null()) }, 0);
    let mut length = usize::MAX;
    assert!(unsafe { md_string(ptr::null(), 0, &mut length) }.is_null());
    assert_eq!(length, 0);
    unsafe { md_free(handle) };

    let document = unsafe { md_document_new(source.as_ptr(), source.len()) };
    assert!(!document.is_null());
    assert!(unsafe { md_document_spans(document, ptr::null_mut()) }.is_null());
    assert!(unsafe { md_document_markers(document, ptr::null_mut()) }.is_null());
    assert!(unsafe { md_document_blocks(document, ptr::null_mut()) }.is_null());
    assert!(unsafe { md_document_string(document, 0, ptr::null_mut()) }.is_null());

    count = usize::MAX;
    assert!(unsafe { md_document_spans(ptr::null(), &mut count) }.is_null());
    assert_eq!(count, 0);
    count = usize::MAX;
    assert!(unsafe { md_document_markers(ptr::null(), &mut count) }.is_null());
    assert_eq!(count, 0);
    count = usize::MAX;
    assert!(unsafe { md_document_blocks(ptr::null(), &mut count) }.is_null());
    assert_eq!(count, 0);
    assert_eq!(unsafe { md_document_string_count(ptr::null()) }, 0);
    length = usize::MAX;
    assert!(unsafe { md_document_string(ptr::null(), 0, &mut length) }.is_null());
    assert_eq!(length, 0);
    unsafe { md_document_free(document) };
}

// ---------------------------------------------------------------------------
// The ordering the Swift bridge is entitled to assume
// ---------------------------------------------------------------------------

/// Constructs whose blocks nest, which is where ordering stops being trivial.
const NESTED: &[(&str, &str)] = &[
    ("ordered list", "998. a\n999. b\n1000. c\n"),
    ("bullet list", "- one\n- two\n"),
    ("nested list", "- outer\n  - inner\n    - deeper\n"),
    ("task list", "- [ ] todo\n- [x] done\n"),
    ("table", "| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\n"),
    (
        "table in a list",
        "- item\n\n  | a | b |\n  |---|---|\n  | 1 | 2 |\n",
    ),
    ("display math", "$$\nx^2\n$$\n"),
    ("blockquote", "> quoted\n> more\n"),
    (
        "callout holding a table",
        "> [!NOTE]\n>\n> | a | b |\n> |---|---|\n> | 1 | 2 |\n",
    ),
    (
        "list holding a fence",
        "- item\n\n  ```swift\n  let x = 1\n  ```\n",
    ),
    ("footnote definition", "See[^1].\n\n[^1]: The note.\n"),
];

/// `blocks` is a pre-order walk, and the bridge decodes it on that basis.
///
/// Nothing sorts `blocks` — a descriptor is pushed when its construct *opens*
/// — so a container precedes its contents and, at a shared start, ends later
/// than the child that follows it. Swift's bridge once held blocks to the
/// `(start, end)` rule that spans and markers really are sorted by; every
/// nested construct in this list failed it, the parse was discarded whole, and
/// the editor drew an empty page for an ordinary note.
///
/// Swift now checks only what its binary searches need — that starts never go
/// backwards — because over-strictness there costs a reader their document.
/// The stronger nesting property is real, and it is asserted here instead,
/// where breaking it fails a test.
#[test]
fn blocks_are_emitted_in_pre_order_with_properly_nested_ranges() {
    for (name, source) in NESTED {
        let result = parse_checked(source).expect("nested fixture must satisfy parser contract");
        assert!(!result.blocks.is_empty(), "{name}: parsed to no blocks");

        for pair in result.blocks.windows(2) {
            let (left, right) = (&pair[0], &pair[1]);
            assert!(
                left.start <= right.start,
                "{name}: block starts went backwards ({} then {})",
                left.start,
                right.start
            );
            if left.start == right.start {
                assert!(
                    left.end >= right.end,
                    "{name}: a block sharing a start ended before the one it precedes \
                     ({}..{} then {}..{}) — the container must come first",
                    left.start,
                    left.end,
                    right.start,
                    right.end
                );
            }
        }
    }
}

/// The corpus above must actually contain the overlapping pair.
///
/// A container ending exactly where its only child does satisfies the span
/// rule by coincidence, which is why a one-item list survived the bug while a
/// two-item list did not. Without this, a parser change could stop producing
/// the shape and leave the test above asserting nothing.
#[test]
fn the_nested_corpus_really_contains_a_container_outliving_its_first_child() {
    let found = NESTED.iter().any(|(_, source)| {
        parse_checked(source)
            .expect("nested fixture must satisfy parser contract")
            .blocks
            .windows(2)
            .any(|w| w[0].start == w[1].start && w[0].end > w[1].end)
    });
    assert!(
        found,
        "no block is followed by one starting together and ending sooner — \
         the ordering these tests guard is no longer exercised"
    );
}

/// Spans and markers *are* sorted by `(start, end)`, and Swift relies on it.
#[test]
fn spans_and_markers_are_sorted_by_start_then_end() {
    for (name, source) in NESTED {
        let result = parse_checked(source).expect("nested fixture must satisfy parser contract");
        for pair in result.spans.windows(2) {
            assert!(
                (pair[0].start, pair[0].end) <= (pair[1].start, pair[1].end),
                "{name}: spans are not sorted by (start, end)"
            );
        }
        for pair in result.markers.windows(2) {
            assert!(
                (pair[0].start, pair[0].end) <= (pair[1].start, pair[1].end),
                "{name}: markers are not sorted by (start, end)"
            );
        }
    }
}
