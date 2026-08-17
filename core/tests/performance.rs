//! Parse-speed gate.
//!
//! Run in release — a debug build of the parser is roughly an order of
//! magnitude slower, so a debug measurement says nothing about what the
//! editor will actually feel like:
//!
//! ```sh
//! cargo test --release --test performance -- --nocapture
//! ```
//!
//! The budget is one 60fps frame (16.6ms) for a full parse of a large
//! document. Incremental reparse will make the common case far cheaper, but
//! the full parse still runs on open and must not stall the window.

use std::time::Instant;

/// A document shaped like real writing rather than one repeated line, since
/// headings, code fences, and inline spans all cost differently.
fn large_document(lines: usize) -> String {
    let mut out: Vec<String> = Vec::with_capacity(lines);
    let mut i = 0;
    while out.len() < lines {
        out.push(format!("## Section {i}"));
        out.push(String::new());
        out.push(format!(
            "Body with **bold**, *italic*, `code`, and [[Wiki Link {i}]]."
        ));
        out.push(format!(
            "Tagged #section{i} and ==highlighted== for good measure."
        ));
        out.push(String::new());
        out.push(format!("- [ ] task {i}"));
        out.push(format!("- item with [a link](https://example.com/{i})"));
        out.push(String::new());
        out.push("```swift".to_string());
        out.push(format!("let value{i} = {i};"));
        out.push("```".to_string());
        out.push(String::new());
        out.push("> [!NOTE]".to_string());
        out.push(format!("> A callout in section {i}."));
        out.push(String::new());
        i += 1;
    }
    out.truncate(lines);
    out.join("\n")
}

fn median_millis(iterations: usize, mut body: impl FnMut()) -> f64 {
    let mut samples: Vec<f64> = Vec::with_capacity(iterations);
    for _ in 0..iterations {
        let start = Instant::now();
        body();
        samples.push(start.elapsed().as_secs_f64() * 1000.0);
    }
    samples.sort_by(|a, b| a.partial_cmp(b).expect("no NaN timings"));
    samples[samples.len() / 2]
}

#[test]
fn full_parse_of_ten_thousand_lines_fits_in_a_frame() {
    let source = large_document(10_000);
    let median = median_millis(7, || {
        let result = markdev::parse(&source);
        // Consume the result so the optimiser cannot elide the parse.
        assert!(!result.blocks.is_empty());
    });

    println!("[perf] full parse of 10k lines: {median:.2}ms");

    if cfg!(debug_assertions) {
        // Debug builds are not the shipping configuration; assert only that
        // nothing pathological (quadratic behaviour) has crept in.
        assert!(
            median < 500.0,
            "debug parse took {median:.2}ms — suspiciously slow even for debug"
        );
    } else {
        assert!(
            median < 16.6,
            "release parse took {median:.2}ms, over one 60fps frame"
        );
    }
}

#[test]
fn parse_scales_linearly_not_quadratically() {
    // Doubling the input must not quadruple the time. This is the guard that
    // would have caught the quadratic marker lookup early.
    let small = large_document(2_000);
    let large = large_document(8_000);

    let t_small = median_millis(5, || {
        markdev::parse(&small);
    });
    let t_large = median_millis(5, || {
        markdev::parse(&large);
    });

    let ratio = t_large / t_small.max(0.0001);
    println!("[perf] 4x input cost {ratio:.2}x time ({t_small:.2}ms -> {t_large:.2}ms)");
    assert!(
        ratio < 8.0,
        "4x the input cost {ratio:.1}x the time — that is superlinear"
    );
}
