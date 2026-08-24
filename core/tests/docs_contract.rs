//! The documentation is a declaration layer, and nothing was checking it.
//!
//! A number in prose compiles no matter what it says, and goes on reading
//! correctly long after the thing it describes has moved. For a performance
//! table the drift is worse than cosmetic: a budget nobody enforces reads
//! exactly like one that is enforced, and the first person to trust it is the
//! one who ships the regression.
//!
//! That had happened here. `docs/performance.md` was headed "Every subsystem
//! has an explicit, automated performance gate" over a column called
//! "Automated Gate", and three of its four rows named a gate the suite does not
//! apply:
//!
//!   * Incremental Shift claimed `< 0.05ms` (Release). No timing assertion
//!     exists anywhere; `incremental.rs` gates the *behaviour* — that a prose
//!     edit yields `Reparse::Shifted` — and never the duration.
//!   * Editor Keystroke claimed `< 16.6ms` (Debug). The test asserts `< 0.050`,
//!     fifty milliseconds, and its own comment says the frame budget is
//!     "deliberately *not* asserted" and that release performance is
//!     "currently **unverified**".
//!   * Caret Navigation claimed `< 2.0ms`. The test asserts one frame budget,
//!     16.6ms — eight times looser.
//!
//! In every case the *code* was the honest one. The tests explain at length why
//! they cannot assert the frame budget; only the document claimed they did.
//!
//! So the table is now derived from the assertions rather than maintained
//! beside them. Each row names the file and the literal that enforces it, and
//! this test reads both.

use std::fs;
use std::path::{Path, PathBuf};

/// The Rust crate sits one level below the repository root.
///
/// The path is baked into the test binary at compile time, so a `target/`
/// carried across a move of this repository serves binaries pointing at a
/// directory that no longer exists. Name the path when that happens —
/// `NotFound` alone reads as a missing checkout.
fn repo_root() -> PathBuf {
    let manifest = Path::new(env!("CARGO_MANIFEST_DIR"));
    manifest
        .join("..")
        .canonicalize()
        .unwrap_or_else(|e| panic!("repository root above {}: {e}", manifest.display()))
}

fn read(rel: &str) -> String {
    let p = repo_root().join(rel);
    fs::read_to_string(&p).unwrap_or_else(|e| panic!("read {}: {e}", p.display()))
}

/// One row of the performance table, and the assertion that backs it.
struct Gate {
    /// The subsystem name as the table spells it.
    subsystem: &'static str,
    /// The gate the table states, verbatim, or None for a row that declares
    /// itself ungated.
    documented: Option<&'static str>,
    /// The file the table names as enforcing it.
    enforced_in: &'static str,
    /// A literal that must appear in that file for the gate to be real. For the
    /// ungated row this is the behavioural assertion standing in for a timing
    /// one.
    assertion: &'static str,
}

const GATES: &[Gate] = &[
    Gate {
        subsystem: "Markdown Parser",
        documented: Some("`< 16.6ms` (Release)"),
        enforced_in: "core/tests/performance.rs",
        assertion: "median < 16.6",
    },
    Gate {
        subsystem: "Incremental Shift",
        documented: None,
        enforced_in: "core/tests/incremental.rs",
        assertion: "Reparse::Shifted",
    },
    Gate {
        subsystem: "Editor Keystroke",
        documented: Some("`< 50ms` (Debug)"),
        enforced_in: "app/Tests/EditorPerformanceTests.swift",
        assertion: "keystroke.best, 0.050",
    },
    Gate {
        subsystem: "Caret Navigation",
        documented: Some("`< 16.6ms` (one frame)"),
        enforced_in: "app/Tests/EditorPerformanceTests.swift",
        assertion: "caret.best, Self.frameBudget",
    },
];

/// Pull one row out of the performance table by its subsystem name.
fn table_row(body: &str, subsystem: &str) -> String {
    let needle = format!("| **{subsystem}** |");
    body.lines()
        .find(|l| l.starts_with(&needle))
        .unwrap_or_else(|| {
            panic!(
                "docs/performance.md has no row for {subsystem:?}; \
                 the table was restructured and this guard no longer reads it"
            )
        })
        .to_string()
}

/// Every documented gate must be the gate the suite actually applies.
#[test]
fn each_documented_gate_is_the_one_the_suite_enforces() {
    let doc = read("docs/performance.md");

    for gate in GATES {
        let row = table_row(&doc, gate.subsystem);

        // The row must point at the file it claims enforces it.
        assert!(
            row.contains(gate.enforced_in),
            "{}: the table does not name {} as its enforcing file:\n  {row}",
            gate.subsystem,
            gate.enforced_in
        );

        // And that file must actually carry the assertion.
        let source = read(gate.enforced_in);
        assert!(
            source.contains(gate.assertion),
            "{}: {} no longer contains `{}` — the gate moved or was removed, \
             so the table is now describing a check that does not run",
            gate.subsystem,
            gate.enforced_in,
            gate.assertion
        );

        match gate.documented {
            Some(text) => assert!(
                row.contains(text),
                "{}: the table states a gate other than {text:?}:\n  {row}",
                gate.subsystem
            ),
            None => assert!(
                row.contains("no timing gate"),
                "{}: this subsystem has no timing assertion, so its row must say \
                 so rather than name a budget:\n  {row}",
                gate.subsystem
            ),
        }
    }
}

/// A row must never claim a gate tighter than the assertion behind it.
///
/// This is the direction that actually hurts. A doc claiming a *looser* gate
/// than reality is merely modest; one claiming a tighter gate invites a reader
/// to rely on a guarantee nothing produces. Both of the Swift rows were wrong
/// in exactly that direction before this file existed — 2.0ms documented
/// against 16.6ms enforced, and 16.6ms documented against 50ms enforced.
#[test]
fn no_row_claims_a_tighter_gate_than_is_enforced() {
    let doc = read("docs/performance.md");

    // (subsystem, documented ms, enforced ms) — the enforced figure is read
    // from source below rather than trusted from here.
    let checks: &[(&str, f64, &str, &str)] = &[
        (
            "Markdown Parser",
            16.6,
            "core/tests/performance.rs",
            "median < ",
        ),
        (
            "Editor Keystroke",
            50.0,
            "app/Tests/EditorPerformanceTests.swift",
            "keystroke.best, ",
        ),
    ];

    for (subsystem, documented_ms, file, prefix) in checks {
        let row = table_row(&doc, subsystem);
        assert!(
            row.contains(&format!("{documented_ms}")) || row.contains("16.6"),
            "{subsystem}: the row no longer states {documented_ms}ms:\n  {row}"
        );

        let source = read(file);
        let idx = source
            .find(prefix)
            .unwrap_or_else(|| panic!("{file} no longer contains {prefix:?}"));
        let tail: String = source[idx + prefix.len()..]
            .chars()
            .take_while(|c| c.is_ascii_digit() || *c == '.')
            .collect();
        let enforced: f64 = tail
            .parse()
            .unwrap_or_else(|e| panic!("{file}: cannot read a number after {prefix:?}: {e}"));

        // Swift asserts in seconds, Rust in milliseconds.
        let enforced_ms = if file.ends_with(".swift") {
            enforced * 1000.0
        } else {
            enforced
        };

        assert!(
            *documented_ms <= enforced_ms + f64::EPSILON,
            "{subsystem}: the table documents a {documented_ms}ms gate while the suite \
             enforces {enforced_ms}ms — a reader would rely on a bound nothing produces"
        );
    }
}

/// The README and the performance doc must agree on the *gate*.
///
/// The same table lives in both, and two copies of a number drift the moment
/// one is edited — the README being the copy most people read.
///
/// The comparison is column-wise on purpose. A first draft matched any
/// `< Nms` token in either row and immediately failed on a correct pair,
/// because both tables carry a Target Budget column as well as an Enforced
/// Gate column, and `16.6ms` appears in one of each for different reasons.
/// Comparing whole rows conflates the two numbers this change exists to
/// separate.
fn gate_cell(row: &str, index: usize) -> String {
    row.split('|')
        .map(str::trim)
        .filter(|c| !c.is_empty())
        .nth(index)
        .unwrap_or_else(|| panic!("row has no column {index}: {row}"))
        .to_string()
}

#[test]
fn the_readme_and_the_performance_doc_agree() {
    let readme = read("README.md");
    let doc = read("docs/performance.md");

    // README:  Measurement | Target Budget | Enforced Gate | Measured
    // docs:    Subsystem | Measurement Target | Enforced Gate | Enforced In | Baseline
    const README_GATE: usize = 2;
    const DOC_GATE: usize = 2;

    for (readme_row, doc_subsystem) in [
        ("Release Parse (10k lines)", "Markdown Parser"),
        ("Prose Keystroke (10k lines)", "Editor Keystroke"),
        ("Caret Navigation", "Caret Navigation"),
    ] {
        let r = gate_cell(&table_row(&readme, readme_row), README_GATE);
        let d = gate_cell(&table_row(&doc, doc_subsystem), DOC_GATE);
        assert_eq!(
            r, d,
            "README gives {readme_row} a gate of {r:?} while docs/performance.md \
             gives {doc_subsystem} {d:?}"
        );
    }
}

/// Relative links must resolve.
#[test]
fn every_relative_link_resolves() {
    let root = repo_root();
    let mut docs: Vec<String> = vec!["README.md".into()];
    for entry in fs::read_dir(root.join("docs")).expect("docs/").flatten() {
        let name = entry.file_name().to_string_lossy().to_string();
        if name.ends_with(".md") {
            docs.push(format!("docs/{name}"));
        }
    }
    assert!(docs.len() >= 5, "only {} documents found", docs.len());

    let mut checked = 0usize;
    let mut broken: Vec<String> = Vec::new();

    for rel in &docs {
        let body = read(rel);
        let base = root.join(rel).parent().expect("parent").to_path_buf();
        let chars: Vec<char> = body.chars().collect();
        let mut i = 0usize;
        while i < chars.len() {
            if chars[i] != '[' {
                i += 1;
                continue;
            }
            let Some(close) = (i + 1..chars.len()).find(|&j| chars[j] == ']') else {
                break;
            };
            if close + 1 >= chars.len() || chars[close + 1] != '(' {
                i += 1;
                continue;
            }
            let Some(end) =
                (close + 2..chars.len()).find(|&j| chars[j] == ')' || chars[j].is_whitespace())
            else {
                break;
            };
            if chars[end] != ')' {
                i = close + 1;
                continue;
            }
            let target: String = chars[close + 2..end].iter().collect();
            i = end + 1;

            let path = target.split('#').next().unwrap_or("");
            if path.is_empty()
                || path.starts_with("http://")
                || path.starts_with("https://")
                || path.starts_with("mailto:")
            {
                continue;
            }
            checked += 1;
            if !base.join(path).exists() {
                broken.push(format!("{rel}: {target}"));
            }
        }
    }

    assert!(
        checked >= 5,
        "only {checked} relative links checked; this guard is not reading the docs"
    );
    assert!(broken.is_empty(), "links that point at nothing: {broken:?}");
}
