//! Inline and display math recognition: what turns a `$` into formatting.
//!
//! The reader's contract: an ordinary sentence containing dollar signs must
//! reach the page exactly as written — no hidden dollars, no math styling,
//! no formula drawn over prose. A `$` only becomes syntax under the adjacency
//! rules in `parse::inline_math_is_valid`, and every rule here earns its
//! place by naming the prose it protects.

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

fn math_spans(source: &str) -> Vec<String> {
    spans_of(source, SpanKind::InlineMath)
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

fn has_block(source: &str, kind: BlockKind) -> bool {
    parse(source).blocks.iter().any(|b| b.kind == kind as u16)
}

// MARK: - Prose that must never become math

#[test]
fn a_price_range_is_not_math() {
    // The reported bug: `$50-$100` pairs because `-` flanks the second `$`,
    // hiding both dollars and styling "50-" as math.
    let src = "Price $50-$100 per unit";
    assert_eq!(revealed(src), src, "a price range must render unchanged");
    assert!(math_spans(src).is_empty(), "no inline-math span");
    assert!(
        parse(src).markers.is_empty(),
        "no marker may hide a dollar in prose"
    );
}

#[test]
fn attached_currency_codes_are_not_math() {
    // `US$5 or A$10`: an ASCII letter before the opener with a digit after
    // it is a currency mark, not a delimiter.
    let src = "US$5 or A$10 shipped";
    assert_eq!(revealed(src), src);
    assert!(math_spans(src).is_empty());
}

#[test]
fn a_glued_price_is_not_math() {
    // "price$5" has no space to save it; the letter-before-plus-digit-after
    // signature is what refuses it.
    let src = "price$5 each";
    assert_eq!(revealed(src), src);
    assert!(math_spans(src).is_empty());
}

#[test]
fn parenthesised_prices_are_not_math() {
    let src = "Tickets are ($5)-($10) at the door";
    assert_eq!(revealed(src), src);
    assert!(math_spans(src).is_empty());
}

#[test]
fn a_glued_second_price_is_not_math() {
    // "and$6" has a legal closer by pulldown's rules; the digit after the
    // closing `$` is what refuses it.
    let src = "Cost $5 and$6 today";
    assert_eq!(revealed(src), src);
    assert!(math_spans(src).is_empty());
}

#[test]
fn double_dollar_prose_never_draws_a_formula() {
    // `$$5 … $$10` pairs into a MathBlock *inside the sentence*, which the
    // editor replaces with a typeset bitmap — a hole in the middle of the
    // paragraph. This is the display-math half of the same bug.
    let src = "He gave me $$5 and I gave him $$10 back";
    assert_eq!(revealed(src), src);
    assert!(
        !has_block(src, BlockKind::MathBlock),
        "prose with two `$$`s must not produce a formula block"
    );
    assert!(parse(src).markers.is_empty());
}

#[test]
fn double_dollar_prose_inside_a_list_is_not_math() {
    let src = "- he owed me $$5 and $$10 more later";
    // The `- ` marker hides; the dollars must not.
    assert_eq!(revealed(src), "he owed me $$5 and $$10 more later");
    assert!(!has_block(src, BlockKind::MathBlock));
}

#[test]
fn escaped_dollars_stay_literal() {
    let src = "\\$5 and \\$10";
    assert!(math_spans(src).is_empty());
    assert_eq!(revealed(src), "$5 and $10");
}

// MARK: - Lone dollars (characterisation: already correct, must stay so)

#[test]
fn a_lone_dollar_never_hides_or_styles_anything() {
    for src in [
        "The cost is $100",
        "a $ b",
        "five dollars $",
        "$",
        "$$",
        "$5 starts this line",
        "Cost $5 and $10 today",
        "I paid $5\nand got $2 back",
    ] {
        assert_eq!(revealed(src), src, "{src:?} must render unchanged");
        assert!(math_spans(src).is_empty(), "{src:?} must have no math span");
        assert!(parse(src).markers.is_empty(), "{src:?} must hide nothing");
    }

    // Containers hide their own markers (`- `, `> `); what matters here is
    // that the *dollar* is not among them.
    for src in ["- bullet with $5 alone", "> quote with $5 alone"] {
        let shown = revealed(src);
        assert!(
            shown.contains("$5"),
            "{src:?} must keep its dollar: {shown:?}"
        );
        assert!(math_spans(src).is_empty(), "{src:?} must have no math span");
    }
}

// MARK: - Real math keeps working

#[test]
fn inline_math_still_recognised() {
    assert_eq!(revealed("$x^2$"), "x^2");
    assert_eq!(math_spans("$x^2$"), vec!["x^2"]);
    assert_eq!(
        revealed("Euler said $e = mc^2$ loudly"),
        "Euler said e = mc^2 loudly"
    );
    assert_eq!(math_spans("sum $2 + 2$ here"), vec!["2 + 2"]);
    // A suffix straight after the closer is a word, not currency: `$n$th`.
    assert_eq!(math_spans("the $n$th term"), vec!["n"]);
    assert_eq!(revealed("the $n$th term"), "the nth term");
}

#[test]
fn math_glued_to_words_still_recognised() {
    // LaTeX prose is often written without spaces around the delimiters.
    // The currency refusal keys on letter-before-plus-digit-after, not on
    // "letter before", so these survive.
    assert_eq!(math_spans("the$x$axis"), vec!["x"]);
    assert_eq!(math_spans("a$x$b"), vec!["x"]);
    // CJK has no spaces, so glued is the *normal* spelling there. The
    // boundary check must stay ASCII-only or this breaks.
    assert_eq!(math_spans("其中$x$是变量"), vec!["x"]);
    assert_eq!(revealed("其中$x$是变量"), "其中x是变量");
}

#[test]
fn display_math_still_renders_as_a_block() {
    assert!(has_block("$$\na = b\n$$", BlockKind::MathBlock));
    assert!(has_block("$$a = b$$", BlockKind::MathBlock));
    assert_eq!(revealed("$$\na = b\n$$"), "\na = b\n");
}

#[test]
fn inline_display_math_keeps_working() {
    // Pinned deliberately: `$$…$$` inside a sentence renders a small formula
    // between the words today, and notes in the wild rely on it.
    assert!(has_block("text $$x$$ more", BlockKind::MathBlock));
}

#[test]
fn a_dollar_bearing_image_is_never_eaten_by_math() {
    // `![chart $5](pic$a.png)` is a complete image, but pulldown-cmark's
    // math scanner runs before link/image resolution and pairs the two `$`s
    // ACROSS the `](` — hiding both dollars and styling "5](pic" as math.
    // The image itself is lost upstream and cannot be recovered here; what
    // this layer owes the reader is an honest failure: every character they
    // typed stays on the page, unstyled.
    let src = "![chart $5](pic$a.png)";
    assert_eq!(revealed(src), src, "no character may vanish");
    assert!(math_spans(src).is_empty(), "no math styling over an image");
}

// MARK: - Offsets

#[test]
fn unicode_around_math_maps_to_utf16() {
    // "é" costs one UTF-16 unit for two bytes.
    let src = "héllo $x$ wörld";
    let result = parse(src);
    let span = result
        .spans
        .iter()
        .find(|s| s.kind == SpanKind::InlineMath as u16)
        .expect("math span");
    let units: Vec<u16> = src.encode_utf16().collect();
    assert_eq!(
        &units[span.start as usize..span.end as usize],
        "x".encode_utf16().collect::<Vec<_>>()
    );

    // An astral character before the opener shifts everything by two units.
    let src = "👍 $x$";
    let result = parse(src);
    let span = result
        .spans
        .iter()
        .find(|s| s.kind == SpanKind::InlineMath as u16)
        .expect("math span");
    let units: Vec<u16> = src.encode_utf16().collect();
    assert_eq!(span.start, 4);
    assert_eq!(
        &units[span.start as usize..span.end as usize],
        "x".encode_utf16().collect::<Vec<_>>()
    );
}

// MARK: - Incremental consistency

#[test]
fn typing_currency_into_a_document_matches_a_fresh_parse() {
    // Typing the digits of `$100` one keystroke at a time: every intermediate
    // state must agree with parsing the whole buffer from scratch, whichever
    // path `replace` takes.
    let mut doc = Document::new("Price $50-$100 per unit");
    assert_eq!(doc.result(), &parse(doc.text()));

    let anchor = "Price ".len();
    doc.replace(anchor..anchor, "about ");
    assert_eq!(doc.result(), &parse(doc.text()));

    // An edit inside a rejected pair must not leave stale math behind.
    let mut doc = Document::new("Cost $5 and$6 today");
    let at = doc.text().find('$').unwrap();
    doc.replace(at..at + 1, "\\");
    assert_eq!(doc.result(), &parse(doc.text()));
    assert!(math_spans(doc.text()).is_empty());
}

#[test]
fn incremental_edits_around_display_prose_match_fresh_parses() {
    let mut doc = Document::new("He gave me $$5 and I gave him $$10 back");
    let at = doc.text().find("gave him").unwrap();
    doc.replace(at.."gave him".len() + at, "kept");
    assert_eq!(doc.result(), &parse(doc.text()));
    assert!(!has_block(doc.text(), BlockKind::MathBlock));

    // And genuine math survives edits around it.
    let mut doc = Document::new("$$\na = b\n$$\nplain text below");
    let at = doc.text().find("plain").unwrap();
    doc.replace(at.."plain".len() + at, "prose");
    assert!(has_block(doc.text(), BlockKind::MathBlock));
}

#[test]
fn ffi_block_kind_contract_unchanged() {
    // The Swift side reads raw discriminants; this pins them so an accidental
    // renumber cannot ship silently.
    assert_eq!(BlockKind::MathBlock as u16, 4);
}

// MARK: - Stress: properties over adversarial inputs

use proptest::prelude::*;
use proptest::test_runner::TestCaseError;

/// Fragments chosen so pairings form, nearly form, and cross constructs:
/// currency runs, doubled dollars, markup that a `$` can pair across, and
/// genuine math to keep the positive case honest.
fn fragment() -> impl Strategy<Value = String> {
    prop::collection::vec(
        prop_oneof![
            Just("$"),
            Just("$$"),
            Just("5"),
            Just("0"),
            Just("-"),
            Just("a"),
            Just("US"),
            Just("."),
            Just(" "),
            Just("\n"),
            Just("\\"),
            Just("("),
            Just(")"),
            Just("x"),
            Just("+"),
            Just("**b**"),
            Just("[t](u)"),
            Just("![i](p.png)"),
            Just("> q "),
            Just("- l "),
            Just("# h "),
            Just("`c`"),
            Just("$x$"),
            Just("$$\ny$$\n"),
            Just("| h | k |\n|---|---|\n| $1 | b |\n"),
            Just("---\n"),
            Just("==m== "),
            Just("#tag "),
        ],
        0..24,
    )
    .prop_map(|parts| parts.concat())
}

/// Dollars hidden by markers that also cover non-dollar characters — link
/// destinations and their kin. Those are syntax runs that happen to contain
/// `$`, outside math's contract.
fn dollars_under_mixed_markers(source: &str, result: &markdev::ParseResult) -> Vec<usize> {
    let units: Vec<u16> = source.encode_utf16().collect();
    let mut out = vec![false; units.len()];
    for m in &result.markers {
        let range = m.start as usize..(m.end as usize).min(units.len());
        if range.start >= range.end {
            continue;
        }
        let has_non_dollar = units[range.clone()].iter().any(|&u| u as u8 != b'$');
        if has_non_dollar {
            for slot in out[range].iter_mut() {
                *slot = true;
            }
        }
    }
    let mut positions: Vec<usize> = out
        .iter()
        .zip(&units)
        .enumerate()
        .filter(|(_, (&hidden, &u))| hidden && u as u8 == b'$')
        .map(|(i, _)| i)
        .collect();
    positions.sort_unstable();
    positions.dedup();
    positions
}

/// The one invariant everything above is in service of: **a dollar sign may
/// only vanish from view as a validated math delimiter** (or inside a larger
/// syntax run such as a link destination). Whatever the input — currency,
/// stray dollars, malformed images — nothing else may hide one.
///
/// Combined with the adjacency rules this is stronger than it looks: it
/// forbids both halves of the reported bug at once, because hiding is what
/// makes the gap and the span is what styles what surrounds it.
fn assert_dollar_accounting(source: &str) -> Result<(), TestCaseError> {
    let result = parse(source);
    let units: Vec<u16> = source.encode_utf16().collect();

    // Structural sanity first.
    let len = units.len() as u32;
    for s in &result.spans {
        prop_assert!(s.start <= s.end && s.end <= len);
    }
    for m in &result.markers {
        prop_assert!(m.start <= m.end && m.end <= len);
    }
    prop_assert!(result.spans.windows(2).all(|w| w[0].start <= w[1].start));
    prop_assert!(result.markers.windows(2).all(|w| w[0].start <= w[1].start));

    // Every marker made of nothing but `$`s must be a math delimiter:
    // width 1 flanking an inline span, width 2 flanking a math block.
    for m in &result.markers {
        let range = m.start as usize..(m.end as usize).min(units.len());
        if range.start >= range.end || !units[range.clone()].iter().all(|&u| u as u8 == b'$') {
            continue;
        }
        let width = range.len();
        let flanks_inline = result.spans.iter().any(|s| {
            s.kind == SpanKind::InlineMath as u16
                && ((width == 1 && m.start + 1 == s.start && m.end == s.start)
                    || (width == 1 && m.start == s.end && m.end == s.end + 1))
        });
        // A math block's range includes its delimiters: `$$` at each end.
        let flanks_block = result.blocks.iter().any(|b| {
            b.kind == BlockKind::MathBlock as u16
                && ((width == 2 && m.start == b.start && m.end == b.start + 2)
                    || (width == 2 && m.start + 2 == b.end && m.end == b.end))
        });
        prop_assert!(
            flanks_inline || flanks_block,
            "pure-dollar marker {range:?} in {source:?} is not a math delimiter"
        );
    }

    // And the count closes: the dollars that vanish are exactly the math
    // delimiters plus whatever mixed syntax runs happened to swallow.
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
    let mut vanished: Vec<usize> = hidden
        .iter()
        .zip(&units)
        .enumerate()
        .filter(|(_, (&h, &u))| h && u as u8 == b'$')
        .map(|(i, _)| i)
        .collect();
    let mut expected = dollars_under_mixed_markers(source, &result);
    // Delimiter positions, derived independently from the spans and blocks.
    for s in result
        .spans
        .iter()
        .filter(|s| s.kind == SpanKind::InlineMath as u16)
    {
        if s.start > 0 {
            expected.push(s.start as usize - 1);
        }
        expected.push(s.end as usize);
    }
    for b in result
        .blocks
        .iter()
        .filter(|b| b.kind == BlockKind::MathBlock as u16)
    {
        expected.extend([b.start as usize, b.start as usize + 1]);
        if b.end >= 2 {
            expected.extend([b.end as usize - 2, b.end as usize - 1]);
        }
    }
    expected.retain(|&i| i < units.len() && units[i] as u8 == b'$');
    expected.sort_unstable();
    expected.dedup();
    vanished.sort_unstable();
    prop_assert_eq!(vanished, expected, "dollar accounting broke for {}", source);
    Ok(())
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(2000))]

    #[test]
    fn dollar_accounting_holds_for_arbitrary_documents(doc in fragment()) {
        assert_dollar_accounting(&doc)?;
    }

    /// Edits into and around dollar-heavy text must leave the incremental
    /// parser agreeing with a full reparse, whichever path `replace` takes.
    #[test]
    fn edits_to_currency_and_math_match_full_reparse(
        edits in prop::collection::vec((fragment(), 0.0f64..1.0, 0.0f64..0.3), 1..10),
    ) {
        let mut doc = Document::new("Price $50-$100\n\nEuler said $e = mc^2$ here\n\nHe gave me $$5 and $$10 back");
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
            assert_dollar_accounting(doc.text())?;
        }
    }
}

/// Snaps a byte offset to a `char` boundary, the way every caller of
/// `Document::replace` must.
fn char_boundary(text: &str, mut index: usize) -> usize {
    while index < text.len() && !text.is_char_boundary(index) {
        index += 1;
    }
    index
}
