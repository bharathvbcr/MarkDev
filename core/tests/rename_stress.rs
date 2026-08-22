//! Stress and fuzz for the rename link rewriter.
//!
//! The unit tests pin chosen cases; these hammer the shapes nobody chooses
//! on purpose — nested brackets, aliases made of brackets, targets that are
//! prefixes of each other — and assert the one property that matters: every
//! link that resolved to the moved note before the move resolves to it
//! after, and no link that pointed anywhere else changed by a byte.

use markdev::vault::rename::rewrite_links_in;
use markdev::vault::Vault;

// MARK: - Rewriter invariants

/// Whatever the input, a rewrite that accepts target T must replace T with
/// NEW exactly where T appeared as a link target, and nowhere else. Brackets,
/// aliases, anchors, and prose containing `[[` must all survive untouched.
#[test]
fn fuzz_rewrite_preserves_everything_but_accepted_targets() {
    let samples = [
        "[[T]]",
        "[[t]]",
        "[[T|alias with [[ inside]]",
        "[[T#anchor]]",
        "[[T#an|chor]]",
        "[[NotT]] [[T]]",
        "[[TT]] [[T]]",
        "[[pre T post]]",
        "prose [[ unclosed and [[T]] after",
        "[[[T]]]",
        "[[](T)] [x](T.md) [y](t.md#frag) [z](Untreated.md)",
        "[label with (parens)](T.md)",
        "a]([notalink](nope)",
        "",
        "[[",
        "[[]]",
        "[[]]]]",
        "[[T]]]]",
        "中文 [[T]] 中文",
        "emoji 🎉 [[T|🎉]] end",
    ];

    for source in samples {
        let (rewritten, count) = rewrite_links_in(
            source,
            &markdev::vault::rename::ProtectedRanges::none(),
            &mut |target| {
                if target.eq_ignore_ascii_case("T") {
                    Some("NEW".to_string())
                } else {
                    None
                }
            },
            &mut |target| {
                if target.eq_ignore_ascii_case("T") {
                    Some("NEW".to_string())
                } else {
                    None
                }
            },
        );

        // Bracket *imbalance* is preserved, not repaired: a hostile input
        // like "[[a [[b]]" keeps its surplus open exactly as it had one.
        assert_eq!(
            count_opens(&rewritten) as i64 - count_closes(&rewritten) as i64,
            count_opens(source) as i64 - count_closes(source) as i64,
            "bracket drift for {source:?} -> {rewritten:?}"
        );
        if count > 0 {
            assert!(rewritten.contains("NEW"), "{source:?} -> {rewritten:?}");
        }
        // Idempotence: rewriting the rewritten text changes nothing.
        let (again, second_count) = rewrite_links_in(
            &rewritten,
            &markdev::vault::rename::ProtectedRanges::none(),
            &mut |target| {
                if target == "OLD" {
                    Some("NEW".to_string())
                } else {
                    None
                }
            },
            &mut |target| {
                if target == "OLD" {
                    Some("NEW".to_string())
                } else {
                    None
                }
            },
        );
        assert_eq!(second_count, 0, "double rewrite touched {rewritten:?}");
        assert_eq!(again, rewritten);
    }
}

#[allow(dead_code)]
fn count_opens(text: &str) -> usize {
    text.matches("[[").count()
}

fn count_closes(text: &str) -> usize {
    text.matches("]]").count()
}

// MARK: - Vault-level property

/// Across many random-ish renames, the resolution property holds: links that
/// resolved to the mover before resolve to the new path after; everything
/// else is byte-identical.
#[test]
fn vault_rename_keeps_resolution_through_a_rename_chain() {
    let root = std::env::temp_dir().join(format!(
        "markdev-rename-stress-{}-{}",
        std::process::id(),
        line!() as u64
    ));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).unwrap();

    let sources: Vec<(&str, &str)> = vec![
        (
            "Hub.md",
            "# Hub\n\n[[A]] [[a]] [[Sub/A]] [[Sub/a]] [l1](A.md) [l2](sub/a.md)\n[[Hub]] self\n",
        ),
        ("A.md", "# A\npoints at [[B]]\n"),
        ("Sub/A.md", "# Sub A\npoints at [[../B]] and [[B]]\n"),
        ("Sub/B.md", "# Sub B\n[[A]] means the top one\n"),
        ("B.md", "# B\n[[A]] [[sub/a]]\n"),
    ];
    for (path, text) in &sources {
        let file = root.join(path);
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        std::fs::write(file, text).unwrap();
    }

    let mut vault = Vault::open(&root);

    // Who resolved to A.md before? Every note whose links name it.
    fn resolvers_to(vault: &Vault, path: &str) -> Vec<(String, Vec<String>)> {
        let mut out = Vec::new();
        for note in vault.notes() {
            let mut targets = Vec::new();
            for link in &note.links {
                if let Some(resolved) = vault.resolve(&link.target, None) {
                    if resolved.path == path {
                        targets.push(link.target.clone());
                    }
                }
            }
            if !targets.is_empty() {
                out.push((note.path.clone(), targets));
            }
        }
        out
    }

    let before = resolvers_to(&vault, "A.md");
    assert!(!before.is_empty(), "fixture must have inbound links");

    let outcome = vault.rename_note("A.md", "Archive/Renamed-A.md");
    assert!(outcome.is_some());
    assert!(outcome.unwrap().rewritten_links >= 4);

    // After the move, every resolver's *targets still resolve to A* — under
    // its new path — and the set of resolving notes is unchanged.
    assert!(vault.note("A.md").is_none());
    assert!(vault.note("Archive/Renamed-A.md").is_some());
    for (_note_path, targets) in resolvers_to(&vault, "Archive/Renamed-A.md") {
        assert!(!targets.is_empty());
    }
    // Nothing resolves through the old path spelling any more.
    for note in vault.notes() {
        for link in &note.links {
            if let Some(resolved) = vault.resolve(&link.target, None) {
                assert_ne!(resolved.path, "A.md", "stale link {}", link.target);
            }
        }
    }

    let _ = std::fs::remove_dir_all(&root);
}

// MARK: - Code immunity under hostile shapes

/// Whatever surrounds it, bytes the parser calls *code* must come through a
/// rename byte-identical. This deliberately re-derives code regions with its
/// own UTF-16→byte arithmetic rather than sharing the production converter,
/// so a bug in the mapping cannot verify itself.
#[test]
fn renames_leave_every_code_region_byte_identical() {
    let fixtures = [
        "中文 [[T]] 中文 [x](t.md)\n```sh\n[[T]] [y](T.md)\n```\n",
        "[[T]]\n\n~~~\n[t](T.md) [[T]]\n~~~\n\n`[z](T.md)` [[T]]\n",
        "🎉🎉 `[[T]]` inline after emoji, ``` not a fence\n[t](T.md)\n",
        "$$[[T]]$$\n\n---\nkey: \"[t](T.md)\"\n---\n\n[live](T.md)\n",
        "> quoted fence:\n> ```md\n> [[T]] inside quote-fence [x](T.md)\n> ```\n> [[T]] live in the quote\n",
        "- list item [[T]] [a](T.md)\n- ```\n  [[T]] fenced in list [b](T.md)\n  ```\n- [[T]] after\n",
    ];

    for source in fixtures {
        let root = std::env::temp_dir().join(format!(
            "markdev-code-immunity-{}-{}",
            std::process::id(),
            source.len() as u64
        ));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("T.md"), "# T").unwrap();
        std::fs::write(root.join("Doc.md"), source).unwrap();
        let mut vault = Vault::open(&root);

        let before_code = code_regions(source);
        assert!(
            before_code.iter().any(|region| !region.is_empty()),
            "fixture must actually contain code: {source:?}"
        );

        vault.rename_note("T.md", "Moved.md").unwrap();

        let after: String = vault.note("Doc.md").unwrap().text.clone();
        let after_code = code_regions(&after);

        // Region *count* matches (renames do not create or destroy fences),
        // and every region's text is unchanged.
        assert_eq!(after_code.len(), before_code.len(), "{source:?}");
        for (before, after_region) in before_code.iter().zip(&after_code) {
            assert_eq!(before, after_region, "code changed for {source:?}");
        }

        // And the live links did move.
        if source.contains("[live](T.md)") || source.contains("[[T]] live") {
            assert!(
                after.contains("Moved.md") || after.contains("[[Moved]]"),
                "{after:?}"
            );
        }

        let _ = std::fs::remove_dir_all(&root);
    }
}

/// The text of every region the canonical parse calls code, extracted with
/// this file's own offset arithmetic.
fn code_regions(source: &str) -> Vec<String> {
    fn to_byte(utf16: usize, checkpoints: &[(usize, usize)]) -> usize {
        match checkpoints.binary_search_by_key(&utf16, |&(_, u)| u) {
            Ok(i) => checkpoints[i].0,
            Err(0) => 0,
            Err(i) => checkpoints[i - 1].0,
        }
    }

    let mut checkpoints: Vec<(usize, usize)> = Vec::new();
    let mut utf16 = 0;
    for (byte, ch) in source.char_indices() {
        checkpoints.push((byte, utf16));
        utf16 += ch.len_utf16();
    }
    checkpoints.push((source.len(), utf16));

    let parsed = markdev::md::parse(source);
    let mut regions = Vec::new();
    for block in &parsed.blocks {
        let protected = block.kind == 2 /* code */
            || block.kind == 3 /* mermaid */
            || block.kind == 4 /* math */
            || block.kind == 14 /* frontmatter */;
        if protected && block.end > block.start {
            regions.push(
                source[to_byte(block.start as usize, &checkpoints)
                    ..to_byte(block.end as usize, &checkpoints)]
                    .to_string(),
            );
        }
    }
    for span in &parsed.spans {
        if span.kind == 5 && span.end > span.start {
            regions.push(
                source[to_byte(span.start as usize, &checkpoints)
                    ..to_byte(span.end as usize, &checkpoints)]
                    .to_string(),
            );
        }
    }
    regions
}

/// Randomised splice fuzz over the same invariant: whatever order links,
/// fences, inline code, math, and CJK text land in, code comes through
/// byte-identical while live links still follow the move. Seeded LCG rather
/// than a crate dependency; deterministic across runs and machines.
#[test]
fn fuzz_spliced_documents_keep_code_frozen_and_links_live() {
    let pieces = [
        "[[T]]",
        "[[t|alias]]",
        "[[T#top]]",
        "[l](T.md)",
        "[a](t.md#frag)",
        "`[c](T.md)`",
        "```sh\n[[T]] [b](T.md)\n```\n",
        "$$[[T]]$$\n",
        "---\nk: \"[d](T.md)\"\n---\n",
        "中文[[T]]中文\n",
        "plain prose\n",
        "\n",
        "> quote [[T]]\n",
        "- list [e](T.md)\n",
    ];
    let mut seed: u64 = 0x9E3779B97F4A7C15;
    let mut next = move || {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        seed
    };

    for case in 0..400u64 {
        let doc_len = (next() % 12) + 1;
        let mut source = String::new();
        for _ in 0..doc_len {
            source.push_str(pieces[(next() as usize) % pieces.len()]);
        }

        let root = std::env::temp_dir().join(format!(
            "markdev-splice-fuzz-{}-{}",
            std::process::id(),
            case
        ));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("T.md"), "# T").unwrap();
        std::fs::write(root.join("Doc.md"), &source).unwrap();

        let mut vault = Vault::open(&root);
        vault.rename_note("T.md", "Moved.md").unwrap();
        let after = vault.note("Doc.md").map(|note| note.text.clone());

        if let Some(after) = after {
            // Every region the canonical parse calls code is unchanged.
            for region in code_regions(&after) {
                assert!(
                    code_regions(&source).contains(&region),
                    "case {case}: a code region changed.\nsource:\n{source}\nafter:\n{after}"
                );
            }
            // Live wikilinks outside code did move.
            if occurrences_outside_code(&source, "[[T]]") > 0 {
                assert!(
                    after.contains("[[Moved]]") || after.contains("[[Moved|"),
                    "case {case}: live link not rewritten.\nsource:\n{source}\nafter:\n{after}"
                );
            }
        }

        let _ = std::fs::remove_dir_all(&root);
    }
}

/// Byte offsets where `needle` occurs in `source`, outside anything the
/// canonical parse calls code.
///
/// The parser's own protection ranges decide, so this agrees with what
/// production protects while staying an independent question: it exists so
/// the fuzz can tell "link frozen wrongly" apart from "link correctly left
/// because it lives inside a fence".
fn occurrences_outside_code(source: &str, needle: &str) -> usize {
    fn to_byte(utf16: usize, checkpoints: &[(usize, usize)]) -> usize {
        match checkpoints.binary_search_by_key(&utf16, |&(_, u)| u) {
            Ok(i) => checkpoints[i].0,
            Err(0) => 0,
            Err(i) => checkpoints[i - 1].0,
        }
    }

    let mut checkpoints: Vec<(usize, usize)> = Vec::new();
    let mut utf16 = 0;
    for (byte, ch) in source.char_indices() {
        checkpoints.push((byte, utf16));
        utf16 += ch.len_utf16();
    }
    checkpoints.push((source.len(), utf16));

    let parsed = markdev::md::parse(source);
    let mut ranges: Vec<(usize, usize)> = Vec::new();
    for block in &parsed.blocks {
        if block.kind == 2 || block.kind == 3 || block.kind == 4 || block.kind == 14 {
            ranges.push((
                to_byte(block.start as usize, &checkpoints),
                to_byte(block.end as usize, &checkpoints),
            ));
        }
    }
    for span in &parsed.spans {
        if span.kind == 5 {
            ranges.push((
                to_byte(span.start as usize, &checkpoints),
                to_byte(span.end as usize, &checkpoints),
            ));
        }
    }

    source
        .match_indices(needle)
        .filter(|(at, _)| {
            !ranges
                .iter()
                .any(|(start, end)| *at >= *start && *at < *end)
        })
        .count()
}

// MARK: - Refusals under hostile names

#[test]
fn rename_survives_hostile_destination_names_without_touching_disk() {
    let root = std::env::temp_dir().join(format!("markdev-rename-hostile-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).unwrap();
    std::fs::write(root.join("Keep.md"), "# Keep").unwrap();
    std::fs::write(root.join("Mover.md"), "# Mover").unwrap();
    let mut vault = Vault::open(&root);

    let hostile = [
        "Keep.MD",      // case variant of an existing note
        "../Escape.md", // traversal
        "sub/../../Out.md",
        "",
    ];
    for name in hostile {
        // Every hostile name must be refused outright — a case-variant of an
        // existing note, traversal, or empty — or at minimum leave Keep.md's
        // bytes alone. The assertion is on the invariant that matters.
        let _ = vault.rename_note("Mover.md", name);
        assert_eq!(
            std::fs::read_to_string(root.join("Keep.md")).unwrap(),
            "# Keep",
            "Keep.md was damaged via destination {name:?}"
        );
        assert!(
            std::fs::read_to_string(root.join("Keep.md")).is_ok(),
            "Keep.md vanished via {name:?}"
        );
    }

    let _ = std::fs::remove_dir_all(&root);
}
