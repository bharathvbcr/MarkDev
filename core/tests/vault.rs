//! Vault indexing: link resolution, backlinks, unlinked mentions, search.

use markdev::vault::{Note, Vault};
use std::path::PathBuf;

/// Builds a vault from in-memory notes, so tests do not touch the disk.
fn vault(notes: &[(&str, &str)]) -> Vault {
    Vault::build(
        PathBuf::from("/vault"),
        notes
            .iter()
            .map(|(path, text)| Note::parse(path.to_string(), text))
            .collect(),
    )
}

const WELCOME: &str = "\
# Welcome

Links to [[Architecture]] and [[Projects/Roadmap|the roadmap]].
Tagged #markdown and #swift.
";

const ARCHITECTURE: &str = "\
---
tags: [design, core]
aliases: [Design Notes]
---

# Architecture

The core owns parsing. See [[Welcome]].

## Parsing

Details here.
";

const ROADMAP: &str = "\
# Roadmap

Roadmap items. Mentions Architecture without linking to it.
";

fn demo() -> Vault {
    vault(&[
        ("Welcome.md", WELCOME),
        ("Architecture.md", ARCHITECTURE),
        ("Projects/Roadmap.md", ROADMAP),
    ])
}

// MARK: - Note metadata

#[test]
fn title_comes_from_the_first_heading() {
    let note = Note::parse("Some File.md", "# Real Title\n\nbody");
    assert_eq!(note.title, "Real Title");
}

#[test]
fn title_falls_back_to_the_file_name() {
    let note = Note::parse("Projects/Some File.md", "no heading here");
    assert_eq!(note.title, "Some File");
}

#[test]
fn headings_are_collected_with_levels() {
    let note = Note::parse("a.md", "# One\n\n## Two\n\n### Three\n");
    let levels: Vec<u8> = note.headings.iter().map(|h| h.level).collect();
    let texts: Vec<&str> = note.headings.iter().map(|h| h.text.as_str()).collect();
    assert_eq!(levels, vec![1, 2, 3]);
    assert_eq!(texts, vec!["One", "Two", "Three"]);
}

#[test]
fn wikilinks_capture_target_alias_and_anchor() {
    let note = Note::parse(
        "a.md",
        "[[Plain]] [[Target|shown]] [[Note#Heading]] [[Note#Head|alias]]",
    );
    let targets: Vec<&str> = note.links.iter().map(|l| l.target.as_str()).collect();
    assert_eq!(targets, vec!["Plain", "Target", "Note", "Note"]);

    let displays: Vec<&str> = note.links.iter().map(|l| l.display.as_str()).collect();
    assert_eq!(displays, vec!["Plain", "shown", "Note#Heading", "alias"]);

    assert_eq!(note.links[2].anchor.as_deref(), Some("Heading"));
    assert_eq!(note.links[0].anchor, None);
}

#[test]
fn tags_come_from_body_and_frontmatter() {
    let note = Note::parse("a.md", ARCHITECTURE);
    assert!(note.tags.contains(&"design".to_string()));
    assert!(note.tags.contains(&"core".to_string()));
}

#[test]
fn tags_inside_code_are_ignored() {
    // The same rule the editor uses; a `#` in a fence is code.
    let note = Note::parse("a.md", "```\n#notatag\n```\n\n#realtag\n");
    assert_eq!(note.tags, vec!["realtag".to_string()]);
}

#[test]
fn aliases_are_read_from_frontmatter() {
    let note = Note::parse("Architecture.md", ARCHITECTURE);
    assert!(note.aliases.contains(&"Design Notes".to_string()));
    assert!(note.names().contains(&"Design Notes".to_string()));
}

#[test]
fn block_style_frontmatter_lists_parse() {
    let note = Note::parse("a.md", "---\ntags:\n  - alpha\n  - beta\n---\n\n# T\n");
    assert!(note.tags.contains(&"alpha".to_string()));
    assert!(note.tags.contains(&"beta".to_string()));
}

// MARK: - Resolution

#[test]
fn links_resolve_by_file_name() {
    let vault = demo();
    let resolved = vault.resolve("Architecture", None).expect("resolves");
    assert_eq!(resolved.path, "Architecture.md");
}

#[test]
fn links_resolve_by_relative_path() {
    let vault = demo();
    let resolved = vault.resolve("Projects/Roadmap", None).expect("resolves");
    assert_eq!(resolved.path, "Projects/Roadmap.md");
}

#[test]
fn links_resolve_by_bare_name_in_a_subfolder() {
    let vault = demo();
    let resolved = vault.resolve("Roadmap", None).expect("resolves");
    assert_eq!(resolved.path, "Projects/Roadmap.md");
}

#[test]
fn links_resolve_by_alias() {
    let vault = demo();
    let resolved = vault.resolve("Design Notes", None).expect("resolves");
    assert_eq!(resolved.path, "Architecture.md");
}

#[test]
fn resolution_is_case_insensitive() {
    let vault = demo();
    assert_eq!(
        vault.resolve("architecture", None).map(|r| r.path),
        Some("Architecture.md".to_string())
    );
}

#[test]
fn anchors_resolve_to_a_heading_offset() {
    let vault = demo();
    let resolved = vault
        .resolve("Architecture", Some("Parsing"))
        .expect("resolves");
    assert!(
        resolved.offset.is_some(),
        "an anchor should carry an offset"
    );

    let missing = vault
        .resolve("Architecture", Some("Nonexistent"))
        .expect("resolves");
    assert_eq!(
        missing.offset, None,
        "an unknown anchor still opens the note"
    );
}

#[test]
fn ambiguous_names_prefer_the_shallowest_path() {
    // Iteration order must not decide which note a link opens.
    let vault = vault(&[
        ("Deep/Nested/Note.md", "# Note"),
        ("Note.md", "# Note"),
        ("Other/Note.md", "# Note"),
    ]);
    assert_eq!(
        vault.resolve("Note", None).map(|r| r.path),
        Some("Note.md".to_string())
    );
}

#[test]
fn unresolvable_links_are_reported_as_broken() {
    let vault = vault(&[("a.md", "# A\n\n[[Nowhere]]")]);
    let broken = vault.broken_links();
    assert_eq!(broken, vec![("a.md".to_string(), "Nowhere".to_string())]);
    assert!(vault.resolve("Nowhere", None).is_none());
}

// MARK: - Outgoing links

#[test]
fn outgoing_links_carry_the_note_they_resolve_to() {
    let vault = demo();
    let links = vault.links("Welcome.md");
    assert_eq!(links.len(), 2);
    assert_eq!(links[0].target, "Architecture");
    assert_eq!(links[0].path.as_deref(), Some("Architecture.md"));
    // The alias is what the reader sees; the target is what resolves.
    assert_eq!(links[1].display, "the roadmap");
    assert_eq!(links[1].path.as_deref(), Some("Projects/Roadmap.md"));
}

#[test]
fn outgoing_links_report_a_broken_target_rather_than_dropping_it() {
    // Dropped instead, a caller counting links would report a note as having
    // none — which is a different fact from "all of them are broken".
    let vault = vault(&[("a.md", "# A\n\n[[Nowhere]] and [[A]]")]);
    let links = vault.links("a.md");
    assert_eq!(links.len(), 2);
    assert_eq!(links[0].target, "Nowhere");
    assert_eq!(links[0].path, None);
    assert_eq!(links[1].path.as_deref(), Some("a.md"));
}

#[test]
fn outgoing_links_keep_anchors_and_repeats() {
    let vault = vault(&[
        ("a.md", "[[B#Section]]\n\n[[B]] again [[B]]"),
        ("b.md", "# B\n\n## Section\n"),
    ]);
    let links = vault.links("a.md");
    assert_eq!(links.len(), 3, "a repeated link is three occurrences");
    assert_eq!(links[0].anchor.as_deref(), Some("Section"));
    assert!(links
        .iter()
        .all(|link| link.path.as_deref() == Some("b.md")));
}

#[test]
fn a_note_outside_the_vault_has_no_outgoing_links() {
    let vault = demo();
    assert!(vault.links("Nothing/Here.md").is_empty());
}

#[test]
fn outgoing_links_follow_an_edit() {
    let mut vault = vault(&[("a.md", "# A"), ("b.md", "# B")]);
    assert!(vault.links("a.md").is_empty());
    vault.update("a.md", "# A\n\n[[b]]");
    assert_eq!(vault.links("a.md")[0].path.as_deref(), Some("b.md"));
}

// MARK: - Backlinks

#[test]
fn backlinks_find_linking_notes_with_context() {
    let vault = demo();
    let backlinks = vault.backlinks("Architecture.md");
    assert_eq!(backlinks.len(), 1);
    assert_eq!(backlinks[0].path, "Welcome.md");
    assert!(
        backlinks[0].context.contains("Architecture"),
        "the panel needs the line the link came from"
    );
}

#[test]
fn aliased_links_still_produce_backlinks() {
    let vault = demo();
    let backlinks = vault.backlinks("Projects/Roadmap.md");
    assert_eq!(backlinks.len(), 1);
    assert_eq!(backlinks[0].path, "Welcome.md");
}

#[test]
fn a_note_with_no_inbound_links_has_none() {
    let vault = vault(&[("a.md", "# A"), ("b.md", "# B")]);
    assert!(vault.backlinks("a.md").is_empty());
}

#[test]
fn backlinks_update_when_a_note_changes() {
    // Editing one note can create or break edges anywhere, so the graph must
    // reflect the edit immediately.
    let mut vault = vault(&[("a.md", "# A"), ("b.md", "# B")]);
    assert!(vault.backlinks("a.md").is_empty());

    vault.update("b.md", "# B\n\nnow links to [[A]]");
    assert_eq!(vault.backlinks("a.md").len(), 1);

    vault.update("b.md", "# B\n\nlink removed");
    assert!(vault.backlinks("a.md").is_empty());
}

#[test]
fn removing_a_note_drops_its_links() {
    let mut vault = demo();
    assert_eq!(vault.backlinks("Architecture.md").len(), 1);
    vault.remove("Welcome.md");
    assert!(vault.backlinks("Architecture.md").is_empty());
}

// MARK: - Unlinked mentions

#[test]
fn unlinked_mentions_find_names_without_links() {
    let vault = demo();
    let mentions = vault.unlinked_mentions("Architecture.md");
    assert_eq!(mentions.len(), 1);
    assert_eq!(mentions[0].path, "Projects/Roadmap.md");
}

#[test]
fn notes_that_already_link_are_not_reported_as_unlinked() {
    let vault = demo();
    let mentions = vault.unlinked_mentions("Architecture.md");
    assert!(
        !mentions.iter().any(|m| m.path == "Welcome.md"),
        "Welcome links to Architecture, so it is a backlink not a mention"
    );
}

#[test]
fn unlinked_mentions_require_whole_words() {
    // Substring matching would report "Roadmapping" and make the panel
    // useless, which is how this feature gets switched off.
    let vault = vault(&[
        ("Roadmap.md", "# Roadmap"),
        ("other.md", "# Other\n\nWe discussed Roadmapping strategy."),
    ]);
    assert!(vault.unlinked_mentions("Roadmap.md").is_empty());

    let real = vault_with_mention();
    assert_eq!(real.unlinked_mentions("Roadmap.md").len(), 1);
}

fn vault_with_mention() -> Vault {
    vault(&[
        ("Roadmap.md", "# Roadmap"),
        ("other.md", "# Other\n\nWe discussed the Roadmap today."),
    ])
}

#[test]
fn a_note_never_mentions_itself() {
    let vault = vault(&[("Roadmap.md", "# Roadmap\n\nRoadmap Roadmap Roadmap")]);
    assert!(vault.unlinked_mentions("Roadmap.md").is_empty());
}

/// The editor indexes by UTF-16 code units, and the click on a mention jumps
/// with this offset. A byte offset lands short once anything non-ASCII sits
/// before the mention: "héllo " is 7 bytes but 6 units.
#[test]
fn unlinked_mention_offsets_are_utf16_not_bytes() {
    let vault = vault(&[
        ("Target.md", "# Target"),
        ("other.md", "# Other\n\nhéllo Target world"),
    ]);
    let mentions = vault.unlinked_mentions("Target.md");
    assert_eq!(mentions.len(), 1);
    // "# Other\n\n" is ASCII (9 either way); "héllo " is 7 bytes but 6
    // units — so the mention sits at unit 15 where its byte offset is 16.
    assert_eq!(mentions[0].offset, 15);
}

/// Case folding can change length — 'İ' lowers to i plus a combining dot —
/// so searching a lowercased copy shifts every offset after it onto the
/// wrong character.
#[test]
fn unlinked_mention_offsets_survive_case_folding() {
    // Bytes: prefix(9) + İ(2) stanbul(7) space(1) → "Roadmap" at byte 19;
    // UTF-16: 9 + 1 + 7 + 1 → unit 18.
    let vault = vault(&[
        ("Roadmap.md", "# Roadmap"),
        ("other.md", "# Other\n\nİstanbul Roadmap"),
    ]);
    let mentions = vault.unlinked_mentions("Roadmap.md");
    assert_eq!(mentions.len(), 1);
    assert_eq!(mentions[0].offset, 18);
}

// MARK: - Tags

#[test]
fn tags_are_counted_across_the_vault() {
    let vault = vault(&[
        ("a.md", "# A\n\n#shared #alpha"),
        ("b.md", "# B\n\n#shared"),
    ]);
    let tags = vault.tags();
    assert_eq!(tags[0].tag, "shared", "most used tag comes first");
    assert_eq!(tags[0].count, 2);
    assert!(tags.iter().any(|t| t.tag == "alpha" && t.count == 1));
}

#[test]
fn notes_can_be_listed_by_tag() {
    let vault = demo();
    assert_eq!(vault.notes_with_tag("design"), vec!["Architecture.md"]);
}

// MARK: - Search

#[test]
fn search_finds_notes_by_body_text() {
    let vault = demo();
    let hits = vault.search("parsing", 10);
    assert!(hits.iter().any(|h| h.path == "Architecture.md"));
    assert!(!hits[0].context.is_empty(), "a hit needs a snippet");
}

#[test]
fn search_ands_its_terms() {
    // `rust parser` should mean notes about a Rust parser, not either word.
    let vault = vault(&[
        ("both.md", "# Both\n\nrust parser here"),
        ("one.md", "# One\n\nrust only"),
    ]);
    let hits = vault.search("rust parser", 10);
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].path, "both.md");
}

#[test]
fn search_matches_the_last_token_as_a_prefix() {
    // Results should narrow while the query is still being typed.
    let vault = vault(&[("a.md", "# A\n\nincremental parsing")]);
    assert!(!vault.search("increm", 10).is_empty());
}

#[test]
fn search_ranks_title_matches_first() {
    let vault = vault(&[
        (
            "body.md",
            "# Unrelated\n\nthe word architecture appears here",
        ),
        ("Architecture.md", "# Architecture\n\nsomething else"),
    ]);
    let hits = vault.search("architecture", 10);
    assert_eq!(hits[0].path, "Architecture.md");
}

#[test]
fn search_respects_its_limit_and_empty_queries() {
    let vault = demo();
    assert!(vault.search("", 10).is_empty());
    assert!(vault.search("zzzznotfound", 10).is_empty());
    assert!(vault.search("a", 2).len() <= 2);
}

// MARK: - Robustness

#[test]
fn an_empty_vault_answers_every_query() {
    let vault = vault(&[]);
    assert!(vault.notes().is_empty());
    assert!(vault.backlinks("missing.md").is_empty());
    assert!(vault.unlinked_mentions("missing.md").is_empty());
    assert!(vault.search("anything", 10).is_empty());
    assert!(vault.tags().is_empty());
    assert!(vault.resolve("anything", None).is_none());
}

#[test]
fn non_ascii_titles_and_links_work() {
    let vault = vault(&[
        ("Café.md", "# Café\n\nnotes"),
        ("other.md", "# Other\n\nSee [[Café]] and 🎉 emoji."),
    ]);
    assert_eq!(
        vault.resolve("Café", None).map(|r| r.path),
        Some("Café.md".to_string())
    );
    assert_eq!(vault.backlinks("Café.md").len(), 1);
}

#[test]
fn reading_a_real_directory_indexes_it() {
    let root = std::env::temp_dir().join(format!("markdev-vault-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(root.join("Projects")).expect("create");
    std::fs::create_dir_all(root.join(".hidden")).expect("create");
    std::fs::write(root.join("Welcome.md"), WELCOME).expect("write");
    std::fs::write(root.join("Projects/Roadmap.md"), ROADMAP).expect("write");
    std::fs::write(root.join("ignore.txt"), "not markdown").expect("write");
    std::fs::write(root.join(".hidden/secret.md"), "# Secret").expect("write");

    let vault = Vault::open(&root);
    let paths: Vec<&str> = vault.notes().iter().map(|n| n.path.as_str()).collect();

    assert!(paths.contains(&"Welcome.md"));
    assert!(paths.contains(&"Projects/Roadmap.md"));
    assert!(!paths.iter().any(|p| p.ends_with(".txt")));
    assert!(
        !paths.iter().any(|p| p.contains(".hidden")),
        "dot directories stay out of the index"
    );

    let _ = std::fs::remove_dir_all(&root);
}
