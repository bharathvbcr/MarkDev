//! Renaming notes with the links that point at them.

use markdev::vault::Vault;

/// Unique-per-call counter: the suite runs its tests in parallel threads,
/// and two of them sharing one directory would delete each other's vault.
static DIRECTORY: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// Builds a vault backed by a real directory: the rename moves files.
fn vault(notes: &[(&str, &str)]) -> Vault {
    let serial = DIRECTORY.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    let root = std::env::temp_dir().join(format!("markdev-rename-{}-{serial}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).unwrap();
    for (path, text) in notes {
        let file = root.join(path);
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        std::fs::write(file, text).unwrap();
    }
    Vault::open(&root)
}

#[test]
fn renaming_rewrites_wikilinks_that_resolved_to_the_note() {
    let mut vault = vault(&[
        ("Projects/Roadmap.md", "# Roadmap"),
        (
            "Welcome.md",
            "See [[Roadmap]] and [[roadmap]] and [[Projects/Roadmap]].\n",
        ),
        ("Other.md", "[[Roadmap|the plan]] plus [[Roadmap#Scope]].\n"),
    ]);

    let outcome = vault
        .rename_note("Projects/Roadmap.md", "Plans/Map.md")
        .unwrap();

    let welcome = vault.note("Welcome.md").unwrap().text.clone();
    // Bare stems keep their style — `[[Roadmap]]` becomes `[[Map]]`, whose
    // stem is exactly where the note now lives. Path spellings become paths.
    assert_eq!(
        welcome, "See [[Map]] and [[Map]] and [[Plans/Map]].\n",
        "every spelling that resolved here follows it"
    );
    assert!(vault
        .note("Other.md")
        .unwrap()
        .text
        .contains("[[Map|the plan]]"));
    assert!(vault
        .note("Other.md")
        .unwrap()
        .text
        .contains("[[Map#Scope]]"));
    assert_eq!(outcome.rewritten_notes, 2);

    // The moved note's own text is untouched by its own rename.
    assert_eq!(vault.note("Plans/Map.md").unwrap().text, "# Roadmap");
    assert!(vault.note("Projects/Roadmap.md").is_none());
    assert!(outcome.rewritten_notes == 2, "{outcome:?}");
}

#[test]
fn renaming_moves_the_file_and_creates_its_folder() {
    let mut vault = vault(&[("A.md", "# A\n[[B]]\n"), ("B.md", "# B\n")]);
    vault.rename_note("B.md", "Archive/2026/B-old.md").unwrap();

    assert!(!std::fs::exists(vault.root().join("B.md")).unwrap());
    assert!(std::fs::exists(vault.root().join("Archive/2026/B-old.md")).unwrap());
    // `[[B]]` keeps its bare-stem style: the destination's stem is "B-old",
    // which resolves uniquely, so the terse spelling survives the move.
    assert!(vault.note("A.md").unwrap().text.contains("[[B-old]]"));
}

#[test]
fn bare_links_become_full_paths_when_the_new_stem_would_be_ambiguous() {
    // "Plan" is free before the move — `[[Roadmap]]` resolves to Work alone.
    let mut vault = vault(&[
        ("Other/Plan.md", "# existing Plan"),
        ("Work/Roadmap.md", "# Roadmap"),
        ("Diary.md", "See [[Roadmap]] today.\n"),
    ]);

    vault
        .rename_note("Work/Roadmap.md", "Deep/Plan.md")
        .unwrap();

    // Rewriting to the new stem would spell `[[Plan]]` — which now answers
    // to Other/Plan first. A silent re-pointing is exactly what a rename
    // must not do, so the link is written out in full instead.
    let diary = vault.note("Diary.md").unwrap().text.clone();
    assert_eq!(diary, "See [[Deep/Plan]] today.\n");
}

#[test]
fn links_to_a_like_named_note_elsewhere_are_left_alone() {
    let mut vault = vault(&[
        ("Notes/Roadmap.md", "# Roadmap one"),
        ("Work/Roadmap.md", "# Roadmap two"),
        ("Diary.md", "The shallowest [[Roadmap]] is Notes.\n"),
    ]);

    vault
        .rename_note("Work/Roadmap.md", "Work/Plan.md")
        .unwrap();

    let diary = vault.note("Diary.md").unwrap().text.clone();
    assert!(
        diary.contains("[[Roadmap]]"),
        "a link resolving to the *other* Roadmap must not move: {diary}"
    );
}

#[test]
fn markdown_style_links_are_rewritten_with_their_anchor() {
    let mut vault = vault(&[
        ("Guide.md", "# Guide"),
        (
            "Index.md",
            "Read [the guide](Guide.md) or [deep](guide.md#setup).\n",
        ),
    ]);

    vault.rename_note("Guide.md", "Docs/Guide.md").unwrap();

    let index = vault.note("Index.md").unwrap().text.clone();
    assert!(index.contains("(Docs/Guide.md)"), "{index}");
    assert!(
        index.contains("(Docs/Guide.md#setup)"),
        "anchors ride along: {index}"
    );
    assert!(!index.contains("(Guide.md)"), "{index}");
}

#[test]
fn renaming_to_an_existing_path_is_refused() {
    let mut vault = vault(&[("A.md", "# A"), ("B.md", "# B")]);
    assert!(vault.rename_note("A.md", "B.md").is_none());
    // Nothing moved on disk either.
    assert!(std::fs::exists(vault.root().join("A.md")).unwrap());
}

#[test]
fn renaming_an_unknown_path_is_refused() {
    let mut vault = vault(&[("A.md", "# A")]);
    assert!(vault.rename_note("Missing.md", "X.md").is_none());
}

#[test]
fn unclosed_brackets_are_left_as_prose() {
    let source = "an [[unclosed thing and [[Real]] after";
    let (rewritten, count) = markdev::vault::rename::rewrite_links_in(
        source,
        &mut |target| (target == "Real").then(|| "Moved".to_string()),
        &mut |_| None,
    );
    assert_eq!(count, 1, "{rewritten}");
    assert!(rewritten.contains("[[Moved]]"), "{rewritten}");
    assert!(rewritten.contains("[[unclosed thing and "), "{rewritten}");

    // A rejected token must not swallow a valid neighbour.
    let source = "[[Nope]] then [[Real]]";
    let (rewritten, count) = markdev::vault::rename::rewrite_links_in(
        source,
        &mut |target| (target == "Real").then(|| "Moved".to_string()),
        &mut |_| None,
    );
    assert_eq!(count, 1, "{rewritten}");
    assert_eq!(rewritten, "[[Nope]] then [[Moved]]");
}

#[test]
fn markdown_suffix_and_alias_shapes_survive_a_rewrite() {
    let source = "a [x](Real.md) b [y](real) c [d](Real.md#anchor)";
    let (rewritten, count) =
        markdev::vault::rename::rewrite_links_in(source, &mut |_| None, &mut |target| {
            (target.eq_ignore_ascii_case("Real")).then(|| "New/Spot".to_string())
        });
    assert_eq!(count, 3, "{rewritten}");
    assert!(rewritten.contains("(New/Spot.md)"), "{rewritten}");
    assert!(rewritten.contains("(New/Spot) "), "{rewritten}");
    assert!(rewritten.contains("(New/Spot.md#anchor)"), "{rewritten}");
}
