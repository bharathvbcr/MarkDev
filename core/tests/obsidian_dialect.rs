//! Obsidian syntax through the shipped parser: what the editor draws and
//! what live preview collapses when the caret is elsewhere.

use markdev::md::{
    model::{
        BlockKind, CalloutKind, SpanKind, CALLOUT_FOLD_COLLAPSED, CALLOUT_FOLD_EXPANDED,
        CALLOUT_FOLD_SHIFT, CALLOUT_KIND_MASK, NO_INFO,
    },
    parse_checked, ParseResult,
};

fn parse(source: &str) -> ParseResult {
    parse_checked(source).expect("fixture must satisfy the parser contract")
}

fn revealed(source: &str) -> String {
    let result = parse(source);
    let units: Vec<u16> = source.encode_utf16().collect();
    let mut hidden = vec![false; units.len()];
    for m in &result.markers {
        assert!(
            (m.block as usize) < result.blocks.len(),
            "marker owner must exist"
        );
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

fn callout(source: &str) -> (CalloutKind, u32, Option<String>) {
    let result = parse(source);
    let block = result
        .blocks
        .iter()
        .find(|b| b.kind == BlockKind::Callout as u16)
        .unwrap_or_else(|| panic!("{source:?} should be a callout"));
    let kind = match block.data & CALLOUT_KIND_MASK {
        0 => CalloutKind::Note,
        1 => CalloutKind::Tip,
        2 => CalloutKind::Important,
        3 => CalloutKind::Warning,
        4 => CalloutKind::Caution,
        5 => CalloutKind::Abstract,
        6 => CalloutKind::Info,
        7 => CalloutKind::Todo,
        8 => CalloutKind::Success,
        9 => CalloutKind::Question,
        10 => CalloutKind::Failure,
        11 => CalloutKind::Danger,
        12 => CalloutKind::Bug,
        13 => CalloutKind::Example,
        14 => CalloutKind::Quote,
        other => panic!("unknown callout kind {other}"),
    };
    let title = (block.info != NO_INFO).then(|| result.strings[block.info as usize].clone());
    (kind, block.data >> CALLOUT_FOLD_SHIFT, title)
}

#[test]
fn every_obsidian_callout_type_and_alias_is_a_callout() {
    let cases = [
        ("note", CalloutKind::Note),
        ("abstract", CalloutKind::Abstract),
        ("summary", CalloutKind::Abstract),
        ("tldr", CalloutKind::Abstract),
        ("info", CalloutKind::Info),
        ("todo", CalloutKind::Todo),
        ("tip", CalloutKind::Tip),
        ("hint", CalloutKind::Tip),
        ("important", CalloutKind::Important),
        ("success", CalloutKind::Success),
        ("check", CalloutKind::Success),
        ("done", CalloutKind::Success),
        ("question", CalloutKind::Question),
        ("help", CalloutKind::Question),
        ("faq", CalloutKind::Question),
        ("warning", CalloutKind::Warning),
        ("caution", CalloutKind::Caution),
        ("attention", CalloutKind::Warning),
        ("failure", CalloutKind::Failure),
        ("fail", CalloutKind::Failure),
        ("missing", CalloutKind::Failure),
        ("danger", CalloutKind::Danger),
        ("error", CalloutKind::Danger),
        ("bug", CalloutKind::Bug),
        ("example", CalloutKind::Example),
        ("quote", CalloutKind::Quote),
        ("cite", CalloutKind::Quote),
    ];
    for (name, expected) in cases {
        for spelling in [name.to_string(), name.to_uppercase()] {
            let source = format!("> [!{spelling}]\n> body");
            assert_eq!(callout(&source).0, expected, "{source}");
            // The collapsed header keeps its line, which carries the label.
            assert_eq!(revealed(&source).trim_start(), "body", "{source}");
        }
    }
}

#[test]
fn callout_fold_signs_and_titles_are_carried() {
    let (kind, fold, title) = callout("> [!tip]- Hidden by default\n> body");
    assert_eq!(kind, CalloutKind::Tip);
    assert_eq!(fold, CALLOUT_FOLD_COLLAPSED);
    assert_eq!(title.as_deref(), Some("Hidden by default"));

    let (_, fold, title) = callout("> [!bug]+\n> body");
    assert_eq!(fold, CALLOUT_FOLD_EXPANDED);
    assert_eq!(title, None);

    // A GitHub alert that pulldown recognises keeps a zero fold state.
    assert_eq!(callout("> [!NOTE]\n> body").1, 0);
}

#[test]
fn custom_callout_types_render_as_notes_titled_by_their_type() {
    let (kind, _, title) = callout("> [!my-recipe]\n> flour");
    assert_eq!(kind, CalloutKind::Note);
    assert_eq!(title.as_deref(), Some("My recipe"));
    assert_eq!(revealed("> [!my-recipe]\n> flour").trim_start(), "flour");
}

#[test]
fn comments_collapse_whole_and_neutralise_what_they_contain() {
    let source = "Keep %%secret #tag [[Link]]%% this.";
    assert_eq!(revealed(source), "Keep  this.");
    assert_eq!(
        spans_of(source, SpanKind::Comment),
        ["%%secret #tag [[Link]]%%"]
    );
    assert!(spans_of(source, SpanKind::Tag).is_empty());
    assert!(spans_of(source, SpanKind::WikiLink).is_empty());
}

#[test]
fn block_comments_span_paragraphs_and_skip_code() {
    let source = "Before\n\n%%\nhidden\n\nstill hidden\n%%\n\nAfter `%%code%%`";
    let shown = revealed(source);
    assert!(shown.starts_with("Before"));
    assert!(!shown.contains("hidden"));
    assert!(shown.contains("After %%code%%"));
    assert_eq!(spans_of(source, SpanKind::Comment).len(), 1);
}

#[test]
fn an_unclosed_comment_marker_stays_text() {
    let source = "100%% sure %% not closed";
    // `%%` pairs, so this one *is* a comment; a lone opener is not.
    assert_eq!(spans_of(source, SpanKind::Comment).len(), 1);
    assert_eq!(revealed("Only %%opener here"), "Only %%opener here");
}

#[test]
fn note_embeds_are_wikilinks_and_media_embeds_are_images() {
    let source = "![[Project Plan#Goals]] ![[diagram.svg|300]] ![[Spec.pdf]]";
    assert_eq!(spans_of(source, SpanKind::WikiLink), ["Project Plan#Goals"]);
    assert_eq!(spans_of(source, SpanKind::Image).len(), 2);
    assert_eq!(revealed("![[Project Plan]]"), "Project Plan");
}

#[test]
fn block_ids_collapse_at_line_ends() {
    assert_eq!(revealed("A paragraph ^para-1"), "A paragraph");
    assert_eq!(revealed("- item ^li"), "item");
    assert_eq!(revealed("x^2 stays"), "x^2 stays");
    assert_eq!(revealed("`code ^id`"), "code ^id");
}

#[test]
fn inline_footnotes_collapse_their_brackets() {
    let source = "Claim^[Source, p. 4] here.";
    assert_eq!(spans_of(source, SpanKind::InlineFootnote), ["Source, p. 4"]);
    assert_eq!(revealed(source), "ClaimSource, p. 4 here.");
}

#[test]
fn custom_task_statuses_are_checked_tasks() {
    let source = "- [/] in progress\n- [-] cancelled\n- [x] done\n- [ ] open";
    let result = parse(source);
    let tasks: Vec<u32> = result
        .spans
        .iter()
        .filter(|s| s.kind == SpanKind::TaskMarker as u16)
        .map(|s| s.data)
        .collect();
    assert_eq!(tasks, [1, 1, 1, 0]);
    // Collapses exactly like the `[x]` pulldown recognises.
    assert_eq!(
        revealed(source),
        revealed("- [x] in progress\n- [x] cancelled\n- [x] done\n- [ ] open")
    );
}

#[test]
fn obsidian_constructs_inside_code_stay_literal() {
    let source = "```\n%%x%%\n- [/] no\n^id\n```";
    assert!(spans_of(source, SpanKind::Comment).is_empty());
    assert!(spans_of(source, SpanKind::TaskMarker).is_empty());
}

mod vault {
    use markdev::vault::{Note, Vault};
    use std::path::PathBuf;

    fn vault(notes: &[(&str, &str)]) -> Vault {
        Vault::build(
            PathBuf::from("/vault"),
            notes
                .iter()
                .map(|(path, text)| Note::parse(path.to_string(), text))
                .collect(),
        )
    }

    #[test]
    fn note_embeds_are_links_and_media_embeds_are_not() {
        let note = Note::parse(
            "Home.md",
            "![[Project Plan]] ![[Plan#Goals|400]] ![[photo.png]] ![[Spec.pdf]]",
        );
        let targets: Vec<(&str, Option<&str>)> = note
            .links
            .iter()
            .map(|l| (l.target.as_str(), l.anchor.as_deref()))
            .collect();
        assert_eq!(targets, [("Project Plan", None), ("Plan", Some("Goals"))]);
        assert_eq!(note.links[1].display, "Plan");
    }

    #[test]
    fn comments_hide_tags_and_links_from_the_index() {
        let note = Note::parse(
            "Home.md",
            "Visible #kept [[Seen]]\n\n%%\n#secret [[Hidden]]\n%%\n`%%` #also-kept",
        );
        assert_eq!(note.tags, ["also-kept", "kept"]);
        let targets: Vec<&str> = note.links.iter().map(|l| l.target.as_str()).collect();
        assert_eq!(targets, ["Seen"]);
    }

    #[test]
    fn block_references_resolve_to_the_block_line() {
        let text = "# Title\n\nFirst paragraph.\n\nThe key claim. ^claim\n\n| a |\n|---|\n\n^table";
        let vault = vault(&[("Target.md", text)]);
        let at = |anchor: &str| vault.resolve("Target", Some(anchor)).and_then(|r| r.offset);
        assert_eq!(at("^claim"), Some(text.find("The key").unwrap() as u32));
        assert_eq!(at("^table"), Some(text.find("|---|").unwrap() as u32));
        assert_eq!(at("^missing"), None);
        assert_eq!(at("Title"), Some(0));
    }
}
