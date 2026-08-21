//! Prose survival across every construct that hides or restyles text.
//!
//! The math suite owns `$`; this one owns everything else that can eat a
//! sentence — chiefly MarkDev's own `==highlight==` scanner, whose pairing
//! had no adjacency rules at all and happily swallowed comparison operators,
//! base64 URL padding, and runs of `=` with nothing between them.

use markdev::md::{
    model::{BlockKind, SpanKind},
    parse, Document,
};

/// Collapses every syntax marker, yielding what live preview shows when the
/// caret is elsewhere. Same harness as `live_preview.rs`.
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

fn spans_of(source: &str, kind: SpanKind) -> Vec<String> {
    let result = parse(source);
    let units: Vec<u16> = source.encode_utf16().collect();
    result
        .spans
        .iter()
        .filter(|s| s.kind == kind as u16)
        .map(|s| String::from_utf16_lossy(&units[s.start as usize..s.end as usize]))
        .collect()
}

// MARK: - Comparisons are prose, not highlights

#[test]
fn a_comparison_is_not_a_highlight() {
    let src = "x == y == z";
    assert_eq!(revealed(src), src, "comparisons must render unchanged");
    assert!(spans_of(src, SpanKind::Highlight).is_empty());
}

#[test]
fn two_comparisons_do_not_swallow_the_words_between() {
    let src = "if a == b and c == d";
    assert_eq!(revealed(src), src);
    assert!(spans_of(src, SpanKind::Highlight).is_empty());
}

#[test]
fn a_run_of_equals_hides_nothing() {
    // Four equals paired into an EMPTY highlight: both delimiters hidden,
    // nothing drawn — a pure gap. Whatever else it is, `a ==== b` is not
    // worth less than the characters the reader typed.
    let src = "a ==== b";
    assert_eq!(revealed(src), src);
    assert!(spans_of(src, SpanKind::Highlight).is_empty());
}

#[test]
fn base64_url_padding_does_not_pair_across_urls() {
    let src = "see https://x.com/?t=dGVzdA== and https://y.com/?t=cGFzcw==";
    assert_eq!(revealed(src), src);
    assert!(spans_of(src, SpanKind::Highlight).is_empty());
}

#[test]
fn an_equals_chain_stays_literal() {
    let src = "a=b==c";
    assert!(spans_of(src, SpanKind::Highlight).is_empty());
}

#[test]
fn spaced_highlight_is_literal() {
    // Deliberately stricter than the old scanner: `== spaced out ==` reads
    // as arithmetic or emphasis-by-accident, and markdown-it-mark refuses it
    // too. Real highlights are written tight.
    let src = "== spaced out ==";
    assert_eq!(revealed(src), src);
    assert!(spans_of(src, SpanKind::Highlight).is_empty());
}

// MARK: - Real highlighting keeps working

#[test]
fn highlight_still_recognised() {
    assert_eq!(
        revealed("this is ==important== stuff"),
        "this is important stuff"
    );
    assert_eq!(
        spans_of("this is ==important== stuff", SpanKind::Highlight),
        vec!["important"]
    );
    assert_eq!(spans_of("==100== points", SpanKind::Highlight), vec!["100"]);
    // Attached to a CJK word — no spaces in Chinese, so this is how it is
    // written — must keep working. The boundary rule is ASCII-only for
    // exactly this reason.
    assert_eq!(
        spans_of("这是==重点==内容", SpanKind::Highlight),
        vec!["重点"]
    );
    assert_eq!(revealed("这是==重点==内容"), "这是重点内容");
}

// MARK: - Spec behaviours pinned so nobody "fixes" them by accident

#[test]
fn multiplication_emphasis_is_commonmark() {
    // `3*4*5` emphasising the 4 is what every CommonMark renderer does;
    // diverging would break real documents that rely on it.
    assert_eq!(spans_of("3*4*5 grid", SpanKind::Emphasis), vec!["4"]);
}

#[test]
fn intraword_underscores_are_literal() {
    assert!(spans_of("snake_case_word", SpanKind::Emphasis).is_empty());
    assert!(spans_of("snake_case_word", SpanKind::Strong).is_empty());
}

#[test]
fn single_tilde_is_strikethrough_but_flanking_protects_prices() {
    // cmark-gfm behaviour: `~x~` strikes through, and the punctuation
    // flanking rules are what keep `~5 lbs (~2 kg)` literal.
    assert_eq!(
        spans_of("~approx~ 5", SpanKind::Strikethrough),
        vec!["approx"]
    );
    assert!(spans_of("~5 lbs (~2 kg)", SpanKind::Strikethrough).is_empty());
    assert_eq!(revealed("~5 lbs (~2 kg)"), "~5 lbs (~2 kg)");
}

#[test]
fn escapes_hide_only_the_backslash() {
    assert_eq!(revealed("\\*not italic\\*"), "*not italic*");
    assert_eq!(revealed("\\_x\\_"), "_x_");
    assert_eq!(revealed("\\# not tag"), "# not tag");
    assert_eq!(revealed("a \\\\ b"), "a \\ b");
}

#[test]
fn a_footnote_reference_without_definition_stays_literal() {
    let src = "see note[^1] end";
    assert_eq!(revealed(src), src);
}

#[test]
fn setext_heading_and_prose_table_are_spec() {
    // Both restructure blocks — deliberately; they are CommonMark/GFM.
    assert!(parse("Title\n=====")
        .blocks
        .iter()
        .any(|b| b.kind == BlockKind::Heading as u16));
    assert!(parse("yes | no\n--- | ---")
        .blocks
        .iter()
        .any(|b| b.kind == BlockKind::Table as u16));
}

// MARK: - Stress: properties over adversarial inputs

use proptest::prelude::*;
use proptest::test_runner::TestCaseError;

/// Fragments that make `==` pairs form, nearly form, and cross constructs:
/// comparisons, base64 padding, separator runs, real highlights, and the
/// dollar machinery for interaction coverage.
fn fragment() -> impl Strategy<Value = String> {
    prop::collection::vec(
        prop_oneof![
            Just("=="),
            Just("="),
            Just("5"),
            Just("0"),
            Just("a"),
            Just("A"),
            Just(" "),
            Just("\n"),
            Just("x"),
            Just("-"),
            Just("**b**"),
            Just("[t](u)"),
            Just("?t=dGVzdA=="),
            Just("==m=="),
            Just("== spaced =="),
            Just("===="),
            Just("`c`"),
            Just("$5 $10"),
            Just("$x$"),
            Just("#h "),
            Just("> q "),
            Just("| t | f |\n|---|---|\n| a | b |\n"),
            Just("\\=="),
            Just("中文"),
        ],
        0..24,
    )
    .prop_map(|parts| parts.concat())
}

/// Positions of hidden `=` characters covered by markers that also contain
/// other characters — link destinations and their kin, outside highlight's
/// contract.
fn equals_under_mixed_markers(source: &str) -> Vec<usize> {
    let result = parse(source);
    let units: Vec<u16> = source.encode_utf16().collect();
    let mut out = vec![false; units.len()];
    for m in &result.markers {
        let range = m.start as usize..(m.end as usize).min(units.len());
        if range.start >= range.end {
            continue;
        }
        if units[range.clone()].iter().any(|&u| (u as u8) != b'=') {
            for slot in out[range].iter_mut() {
                *slot = true;
            }
        }
    }
    let mut positions: Vec<usize> = out
        .iter()
        .zip(&units)
        .enumerate()
        .filter(|(_, (&hidden, &u))| hidden && (u as u8) == b'=')
        .map(|(i, _)| i)
        .collect();
    positions.sort_unstable();
    positions.dedup();
    positions
}

/// The invariant this suite exists to hold: **an equals sign may only
/// vanish from view as a validated `==highlight==` delimiter**, or inside a
/// larger syntax run such as a table's pipe row. Everything else it names —
/// comparisons, base64 padding, separator runs — must reach the page whole.
fn assert_equals_accounting(source: &str) -> Result<(), TestCaseError> {
    let result = parse(source);
    let units: Vec<u16> = source.encode_utf16().collect();
    let len = units.len();

    // Structural sanity.
    for s in &result.spans {
        prop_assert!(s.start <= s.end && s.end <= len as u32);
    }
    for m in &result.markers {
        prop_assert!(m.start <= m.end && m.end <= len as u32);
    }

    // Every marker made of nothing but `=`s must flank a highlight span.
    for m in &result.markers {
        let range = m.start as usize..(m.end as usize).min(len);
        if range.start >= range.end || !units[range.clone()].iter().all(|&u| (u as u8) == b'=') {
            continue;
        }
        let flanks = result.spans.iter().any(|s| {
            s.kind == SpanKind::Highlight as u16
                && ((m.start + 2 == s.start && m.end == s.start)
                    || (m.start == s.end && m.end == s.end + 2))
        });
        prop_assert!(
            flanks,
            "pure-equals marker {:?} in {:?} is not a highlight delimiter",
            range,
            source
        );
    }

    // And the count closes against what actually disappeared.
    let mut hidden = vec![false; len];
    for m in &result.markers {
        for slot in hidden
            .iter_mut()
            .take((m.end as usize).min(len))
            .skip(m.start as usize)
        {
            *slot = true;
        }
    }
    let mut vanished: Vec<usize> = hidden
        .iter()
        .zip(&units)
        .enumerate()
        .filter(|(_, (&h, &u))| h && (u as u8) == b'=')
        .map(|(i, _)| i)
        .collect();
    let mut expected = equals_under_mixed_markers(source);
    for s in result
        .spans
        .iter()
        .filter(|s| s.kind == SpanKind::Highlight as u16)
    {
        expected.extend([
            s.start as usize - 2,
            s.start as usize - 1,
            s.end as usize,
            s.end as usize + 1,
        ]);
    }
    expected.retain(|&i| i < len && units[i] as u8 == b'=');
    expected.sort_unstable();
    expected.dedup();
    vanished.sort_unstable();
    prop_assert_eq!(vanished, expected, "equals accounting broke for {}", source);
    Ok(())
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(2000))]

    #[test]
    fn equals_accounting_holds_for_arbitrary_documents(doc in fragment()) {
        assert_equals_accounting(&doc)?;
    }

    /// Edits into and around comparison-heavy text must keep the
    /// incremental parser agreeing with a full reparse.
    #[test]
    fn edits_to_comparisons_and_highlights_match_full_reparse(
        edits in prop::collection::vec((fragment(), 0.0f64..1.0, 0.0f64..0.3), 1..10),
    ) {
        let mut doc = Document::new(
            "if a == b and c == d\n\nthis is ==important== stuff\n\ntoken dGVzdA== ends here",
        );
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
            prop_assert_eq!(&doc.result().spans, &expected.spans, "spans at step {}", step);
            prop_assert_eq!(&doc.result().markers, &expected.markers, "markers at step {}", step);
            prop_assert_eq!(&doc.result().blocks, &expected.blocks, "blocks at step {}", step);
            assert_equals_accounting(doc.text())?;
        }
    }
}

/// Snaps a byte offset to a `char` boundary.
fn char_boundary(text: &str, mut index: usize) -> usize {
    while index < text.len() && !text.is_char_boundary(index) {
        index += 1;
    }
    index
}
