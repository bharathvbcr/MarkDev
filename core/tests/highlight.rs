//! Syntax highlighting.
//!
//! These assert the *classification* of specific tokens rather than exact
//! span counts: a grammar update legitimately changes how many spans a file
//! produces, but `fn` must never stop being a keyword.

use markdev::highlight::{highlight, languages, supports, HighlightKind};

/// The kind covering the first occurrence of `token` in `code`.
fn kind_of(language: &str, code: &str, token: &str) -> Option<HighlightKind> {
    let byte = code.find(token)?;
    let offset = code[..byte].encode_utf16().count() as u32;
    let spans = highlight(language, code);

    spans
        .iter()
        .find(|span| span.start <= offset && offset < span.end)
        .and_then(|span| match span.kind {
            0 => Some(HighlightKind::Keyword),
            1 => Some(HighlightKind::String),
            2 => Some(HighlightKind::Number),
            3 => Some(HighlightKind::Comment),
            4 => Some(HighlightKind::Function),
            5 => Some(HighlightKind::Type),
            6 => Some(HighlightKind::Constant),
            7 => Some(HighlightKind::Variable),
            8 => Some(HighlightKind::Operator),
            9 => Some(HighlightKind::Punctuation),
            10 => Some(HighlightKind::Attribute),
            _ => None,
        })
}

#[test]
fn the_expected_languages_are_available() {
    for language in ["rust", "swift", "javascript", "python", "json", "bash"] {
        assert!(supports(language), "{language} should have a grammar");
    }
    assert!(!languages().is_empty());
}

#[test]
fn language_names_are_case_and_alias_insensitive() {
    assert!(supports("RUST"));
    assert!(supports("  rs  "));
    assert!(supports("ts"));
    assert!(!supports("brainfuck"));
}

#[test]
fn rust_keywords_strings_and_comments_are_classified() {
    let code = "// note\nfn main() {\n    let s = \"hello\";\n}\n";
    assert_eq!(kind_of("rust", code, "fn"), Some(HighlightKind::Keyword));
    assert_eq!(
        kind_of("rust", code, "// note"),
        Some(HighlightKind::Comment)
    );
    assert_eq!(
        kind_of("rust", code, "\"hello\""),
        Some(HighlightKind::String)
    );
}

#[test]
fn swift_is_highlighted() {
    let code = "let editor = MarkdownTextView.make()\n";
    assert_eq!(kind_of("swift", code, "let"), Some(HighlightKind::Keyword));
}

#[test]
fn numbers_are_distinguished_from_identifiers() {
    let code = "let value = 42\n";
    assert_eq!(kind_of("swift", code, "42"), Some(HighlightKind::Number));
}

#[test]
fn raw_strings_survive_their_inner_quotes() {
    // The case a regex tokenizer gets wrong: the inner quote must not end
    // the string.
    let code = "fn f() { let s = r#\"a \"quoted\" b\"#; }\n";
    assert_eq!(
        kind_of("rust", code, "r#\""),
        Some(HighlightKind::String),
        "a raw string should be one string token"
    );
}

#[test]
fn python_and_json_and_bash_produce_spans() {
    assert!(!highlight("python", "def f(x):\n    return x + 1\n").is_empty());
    assert!(!highlight("json", "{\"a\": [1, 2, null]}").is_empty());
    assert!(!highlight("bash", "echo \"hi\" | grep x\n").is_empty());
}

#[test]
fn an_unknown_language_yields_nothing() {
    assert!(highlight("klingon", "fn main() {}").is_empty());
    assert!(highlight("", "fn main() {}").is_empty());
}

#[test]
fn empty_code_is_handled() {
    assert!(highlight("rust", "").is_empty());
}

#[test]
fn spans_are_ordered_and_within_bounds() {
    // Out-of-range offsets would crash NSTextStorage rather than mis-colour.
    let code = "fn main() {\n    let x = 1; // c\n}\n";
    let length = code.encode_utf16().count() as u32;
    let spans = highlight("rust", code);

    let mut previous = 0u32;
    for span in &spans {
        assert!(span.start < span.end, "empty or inverted span");
        assert!(span.end <= length, "span past end of code");
        assert!(span.start >= previous, "spans must be ordered");
        previous = span.start;
    }
}

#[test]
fn non_ascii_code_keeps_offsets_aligned() {
    // Offsets are UTF-16; an emoji in a comment must not shift the tokens
    // after it.
    let code = "// 🎉 party\nfn after() {}\n";
    assert_eq!(kind_of("rust", code, "fn"), Some(HighlightKind::Keyword));
}

#[test]
fn adjacent_runs_of_one_kind_are_merged() {
    // Keeps the attribute count down on long blocks.
    let code = "fn a() {}\n";
    let spans = highlight("rust", code);
    for pair in spans.windows(2) {
        assert!(
            !(pair[0].kind == pair[1].kind && pair[0].end == pair[1].start),
            "adjacent same-kind spans should have been merged"
        );
    }
}
