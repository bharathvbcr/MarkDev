use std::path::PathBuf;

use markdev::ffi::{md_html_bytes, md_html_free, md_html_render, md_html_render_with_base};
use markdev::html::{
    render_document, render_document_with_options, slugify, sniff_image, ExportOptions,
    HTMLExportError, LinkBase, MAX_EMBEDDED_IMAGE_BYTES, MAX_SOURCE_BYTES, MAX_TITLE_BYTES,
};

#[test]
fn markdown_is_rendered_as_semantic_html() {
    let html = render_document(
        "# Heading\n\nA **strong** idea.\n\n- [x] done\n\n| A | B |\n|---|---|\n| 1 | 2 |",
        "Example",
    )
    .expect("ordinary markdown should export");

    assert!(html.contains("<h1 id=\"heading\">Heading<a class=\"anchor\" href=\"#heading\""));
    assert!(html.contains("<strong>strong</strong>"));
    assert!(html.contains("<input disabled=\"\" type=\"checkbox\" checked=\"\"/>"));
    assert!(html.contains("<table>"));
    assert!(!html.contains("<pre># Heading"));
}

#[test]
fn raw_html_and_title_markup_are_inert() {
    let html = render_document(
        "</pre><script>globalThis.owned = true</script><img src=x onerror=alert(1)>",
        "<img src=x onerror=alert(2)>",
    )
    .expect("hostile markdown should still export as text");

    assert!(!html.contains("<script>"));
    assert!(!html.contains("<img src=x"));
    assert!(html.contains("&lt;script&gt;"));
    assert!(html.contains("&lt;img src=x onerror=alert(2)&gt;"));
}

#[test]
fn active_link_schemes_are_replaced() {
    let html = render_document(
        "[js](JaVaScRiPt:alert(1)) [data](data:text/html,owned) [web](https://example.com)",
        "Links",
    )
    .expect("links should export");

    assert!(!html.to_ascii_lowercase().contains("javascript:"));
    assert!(!html.to_ascii_lowercase().contains("data:text/html"));
    assert!(html.contains("href=\"#\""));
    assert!(html.contains("href=\"https://example.com\""));
}

#[test]
fn exported_document_has_a_closed_content_security_policy() {
    let html = render_document("body", "Policy").expect("document should export");

    assert!(html.contains("default-src 'none'"));
    assert!(html.contains("object-src 'none'"));
    assert!(html.contains("base-uri 'none'"));
    assert!(html.contains("form-action 'none'"));
    assert!(html.contains("name=\"referrer\" content=\"no-referrer\""));
}

#[test]
fn nul_and_unicode_never_break_the_ffi_friendly_output() {
    let html = render_document("hello\0 🧪", "A\0β").expect("valid Rust text should export");

    assert!(!html.as_bytes().contains(&0));
    assert!(html.contains('🧪'));
    assert!(html.contains('β'));
}

#[test]
fn oversized_documents_are_refused_before_rendering() {
    let source = "x".repeat(MAX_SOURCE_BYTES + 1);
    assert_eq!(
        render_document(&source, "Large"),
        Err(HTMLExportError::SourceTooLarge {
            actual: MAX_SOURCE_BYTES + 1,
            maximum: MAX_SOURCE_BYTES,
        })
    );
}

#[test]
fn an_unbounded_title_cannot_expand_the_export_without_limit() {
    // File names are ordinarily tiny, but this is a public FFI boundary and
    // must not rely on one Swift caller continuing to supply a basename.
    // Eight KiB is already far beyond any supported filesystem component.
    let title = "t".repeat(MAX_TITLE_BYTES + 1);

    assert_eq!(
        render_document("body", &title),
        Err(HTMLExportError::TitleTooLarge {
            actual: MAX_TITLE_BYTES + 1,
            maximum: MAX_TITLE_BYTES,
        })
    );
}

#[test]
fn ffi_returns_length_delimited_utf8_and_rejects_invalid_input() {
    let source = "# FFI 🧪";
    let title = "Bridge";
    let handle =
        unsafe { md_html_render(source.as_ptr(), source.len(), title.as_ptr(), title.len()) };
    assert!(!handle.is_null());

    let mut count = 0;
    let bytes = unsafe { md_html_bytes(handle, &mut count) };
    assert!(!bytes.is_null());
    let output = unsafe { std::slice::from_raw_parts(bytes, count) };
    assert!(std::str::from_utf8(output)
        .unwrap()
        .contains("<h1 id=\"ffi-\">FFI 🧪<a"));
    unsafe { md_html_free(handle) };

    let invalid = [0xff_u8];
    let rejected = unsafe { md_html_render(invalid.as_ptr(), invalid.len(), std::ptr::null(), 0) };
    assert!(rejected.is_null());
}

/// A scratch folder unique to one test, removed when dropped.
struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Self {
        let path = std::env::temp_dir().join(format!(
            "markdev-html-{name}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&path).unwrap();
        Self(path)
    }

    fn write(&self, name: &str, bytes: &[u8]) -> PathBuf {
        let path = self.0.join(name);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).unwrap();
        }
        std::fs::write(&path, bytes).unwrap();
        path
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

const PNG_1X1: &[u8] = &[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
    0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
    0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
    0x42, 0x60, 0x82,
];

fn export_with_base(source: &str, scratch: &Scratch) -> String {
    render_document_with_options(
        source,
        "Assets",
        &ExportOptions {
            asset_base: Some(&scratch.0),
            vault_root: None,
            ..Default::default()
        },
    )
    .expect("document should export")
}

#[test]
fn headings_get_unique_github_style_anchors() {
    let html = render_document(
        "# Getting Started\n\n## Setup\n\n## Setup\n\n## Setup 1\n\n## `code` & Ünïcode!\n\n## !!!",
        "Anchors",
    )
    .unwrap();

    assert!(html.contains("<h1 id=\"getting-started\">"));
    assert!(html.contains("<h2 id=\"setup\">"));
    assert!(html.contains("<h2 id=\"setup-1\">"));
    // The literal "Setup 1" must not collide with the second "Setup".
    assert!(html.contains("<h2 id=\"setup-1-1\">"));
    assert!(html.contains("<h2 id=\"code--ünïcode\">"));
    assert!(html.contains("<h2 id=\"section\">"));
    assert!(html.contains("href=\"#getting-started\""));
}

#[test]
fn heading_markup_stays_inert_inside_anchored_headings() {
    let html = render_document("# Title <script>alert(1)</script>", "Inert").unwrap();

    assert!(!html.contains("<script>"));
    assert!(html.contains("&lt;script&gt;"));
    assert!(html.contains("<h1 id=\"title-alert1\">"));
}

#[test]
fn slugify_matches_common_browser_anchor_conventions() {
    assert_eq!(slugify("Hello, World!"), "hello-world");
    assert_eq!(slugify("  Mixed_Case-Title  "), "mixed_case-title");
    assert_eq!(slugify("Straße 2026"), "straße-2026");
    assert_eq!(slugify("\"><img>"), "img");
}

#[test]
fn wikilinks_point_at_notes_and_in_page_anchors() {
    let html = render_document(
        "[[Project Plan]] [[Plan#Next Steps|next]] [[#Local Heading]] [[diagram.svg]] [[javascript:alert(1)]]",
        "Wiki",
    )
    .unwrap();

    assert!(html.contains("href=\"Project%20Plan.md\""));
    assert!(html.contains("href=\"Plan.md#next-steps\""));
    assert!(html.contains("href=\"#local-heading\""));
    assert!(html.contains("href=\"diagram.svg\""));
    assert!(!html.to_ascii_lowercase().contains("href=\"javascript"));
}

#[test]
fn local_svg_and_raster_images_are_embedded_for_browsers() {
    let scratch = Scratch::new("embed");
    scratch.write(
        "assets/diagram.svg",
        br#"<?xml version="1.0"?><!-- a comment --><svg xmlns="http://www.w3.org/2000/svg" width="4" height="4"/>"#,
    );
    scratch.write("pixel.png", PNG_1X1);

    let html = export_with_base(
        "![Diagram](assets/diagram.svg)\n\n![Pixel](pixel.png)\n\n![Again](./pixel.png)",
        &scratch,
    );

    assert!(html.contains("src=\"data:image/svg+xml;base64,PD94bWwg"));
    assert_eq!(
        html.matches("src=\"data:image/png;base64,iVBORw0KGgo")
            .count(),
        2
    );
    assert!(!html.contains("src=\"assets/diagram.svg\""));
}

#[test]
fn embedding_identifies_images_by_content_not_by_extension() {
    let scratch = Scratch::new("sniff");
    // A PNG named .svg is embedded as what it really is.
    scratch.write("misnamed.svg", PNG_1X1);
    // A text file with an image extension is not a picture.
    scratch.write("secret.png", b"password=hunter2");
    // HTML is not SVG even when it mentions svg.
    scratch.write("page.svg", b"<html><svg></svg></html>");

    let html = export_with_base(
        "![a](misnamed.svg) ![b](secret.png) ![c](page.svg) ![d](missing.png)",
        &scratch,
    );

    assert!(html.contains("src=\"data:image/png;base64,"));
    assert!(html.contains("src=\"secret.png\""));
    assert!(!html.contains("aHVudGVyMg"));
    assert!(html.contains("src=\"page.svg\""));
    assert!(html.contains("src=\"missing.png\""));
}

#[test]
fn embedding_never_fetches_remote_images_and_respects_size_limits() {
    let scratch = Scratch::new("limits");
    let mut large = PNG_1X1.to_vec();
    large.resize(MAX_EMBEDDED_IMAGE_BYTES + 1, 0);
    scratch.write("large.png", &large);
    scratch.write("folder/pixel.png", PNG_1X1);

    let html = export_with_base(
        "![r](https://example.com/p.png) ![p](//example.com/p.png) ![l](large.png) ![d](folder/)",
        &scratch,
    );

    assert!(html.contains("src=\"#\""));
    assert!(html.contains("src=\"large.png\""));
    assert!(html.contains("src=\"folder/\""));
    assert!(!html.contains("src=\"data:image"));
}

#[test]
fn embedding_resolves_percent_encoded_absolute_and_file_url_paths() {
    let scratch = Scratch::new("paths");
    let path = scratch.write("My Pictures/pixel.png", PNG_1X1);
    let absolute = path.to_str().unwrap().replace(' ', "%20");

    let html = export_with_base(
        &format!("![a](My%20Pictures/pixel.png) ![b]({absolute}) ![c](file://{absolute})"),
        &scratch,
    );

    assert_eq!(html.matches("src=\"data:image/png;base64,").count(), 3);
}

#[test]
fn image_sniffing_covers_browser_formats() {
    assert_eq!(sniff_image(PNG_1X1), Some("image/png"));
    assert_eq!(sniff_image(&[0xFF, 0xD8, 0xFF, 0xE0]), Some("image/jpeg"));
    assert_eq!(sniff_image(b"GIF89a......"), Some("image/gif"));
    assert_eq!(sniff_image(b"RIFF\0\0\0\0WEBPVP8 "), Some("image/webp"));
    assert_eq!(
        sniff_image(b"\0\0\0\x1cftypavif\0\0\0\0"),
        Some("image/avif")
    );
    assert_eq!(
        sniff_image("\u{FEFF}<!DOCTYPE svg><svg:svg xmlns:svg=\"x\"/>".as_bytes()),
        Some("image/svg+xml")
    );
    assert_eq!(sniff_image(b"%PDF-1.7"), None);
    assert_eq!(sniff_image(b"<svgfoo/>"), None);
    assert_eq!(sniff_image(b""), None);
}

#[test]
fn exported_document_supports_dark_mode_print_and_callouts() {
    let html = render_document("> [!WARNING]\n> Careful.\n\n$$x^2$$", "Style").unwrap();

    assert!(html.contains("prefers-color-scheme: dark"));
    assert!(html.contains("@media print"));
    assert!(html.contains("<div class=\"callout\" data-callout=\"warning\""));
    assert!(html.contains("class=\"math math-display"));
    assert!(html.contains("name=\"color-scheme\""));
}

#[test]
fn ffi_with_base_embeds_images_and_empty_base_matches_plain_render() {
    let scratch = Scratch::new("ffi");
    scratch.write("pixel.png", PNG_1X1);
    let source = "![p](pixel.png)";
    let title = "Bridge";
    let base = scratch.0.to_str().unwrap();

    let render = |base: &str| unsafe {
        let handle = md_html_render_with_base(
            source.as_ptr(),
            source.len(),
            title.as_ptr(),
            title.len(),
            base.as_ptr(),
            base.len(),
            std::ptr::null(),
            0,
            std::ptr::null(),
            0,
            false,
        );
        assert!(!handle.is_null());
        let mut count = 0;
        let bytes = md_html_bytes(handle, &mut count);
        let text = std::str::from_utf8(std::slice::from_raw_parts(bytes, count))
            .unwrap()
            .to_owned();
        md_html_free(handle);
        text
    };

    assert!(render(base).contains("data:image/png;base64,"));
    assert_eq!(render(""), render_document(source, title).unwrap());

    let invalid = [0xff_u8];
    let rejected = unsafe {
        md_html_render_with_base(
            source.as_ptr(),
            source.len(),
            title.as_ptr(),
            title.len(),
            invalid.as_ptr(),
            invalid.len(),
            std::ptr::null(),
            0,
            std::ptr::null(),
            0,
            false,
        )
    };
    assert!(rejected.is_null());
}

// MARK: - Obsidian dialect

fn main_of(html: &str) -> &str {
    let start = html.find("<main>").unwrap();
    &html[start..]
}

#[test]
fn highlights_tags_and_comments_render_like_obsidian_reading_view() {
    let html = render_document(
        "A ==key== idea #project/alpha %%private note%% done.\n\n%%\nhidden block\n%%\n\n`==code== #no %%x%%`",
        "Dialect",
    )
    .unwrap();
    let body = main_of(&html);
    assert!(body.contains("<mark>key</mark>"));
    assert!(body.contains("<span class=\"tag\">#project/alpha</span>"));
    assert!(!body.contains("private note"));
    assert!(!body.contains("hidden block"));
    assert!(body.contains("<code>==code== #no %%x%%</code>"));
}

#[test]
fn obsidian_callouts_have_titles_icons_and_fold_with_details() {
    let html = render_document(
        "> [!faq]- Why **fold**?\n> Because.\n\n> [!info]\n> Plain.\n\n> [!recipe]+\n> Custom.\n\n> [!NOTE]\n> GitHub.",
        "Callouts",
    )
    .unwrap();
    let body = main_of(&html);
    assert!(body.contains(
        "<details class=\"callout\" data-callout=\"question\" data-callout-type=\"faq\">"
    ));
    assert!(body.contains("<span class=\"callout-title-inner\">Why <strong>fold</strong>?</span>"));
    assert!(
        body.contains("<div class=\"callout\" data-callout=\"info\" data-callout-type=\"info\">")
    );
    assert!(body.contains("<span class=\"callout-title-inner\">Info</span>"));
    assert!(body.contains("data-callout-type=\"recipe\" open>"));
    assert!(body.contains("<span class=\"callout-title-inner\">Recipe</span>"));
    assert!(body.contains("data-callout=\"note\" data-callout-type=\"note\""));
    assert!(body.contains("<p>Because.</p>"));
    assert!(!body.contains("[!faq]"));
    assert!(!body.contains("<blockquote"));
    assert_eq!(body.matches("<svg class=\"callout-icon\"").count(), 4);
    assert_eq!(body.matches("</details>").count(), 2);
}

#[test]
fn callout_titles_stay_inert() {
    let html = render_document("> [!note] <img src=x onerror=alert(1)>\n> body", "T").unwrap();
    assert!(!html.contains("<img src=x"));
}

#[test]
fn inline_footnotes_become_numbered_notes() {
    let html = render_document("Claim^[Source, p. 4] and more^[Second].", "Notes").unwrap();
    let body = main_of(&html);
    assert_eq!(body.matches("class=\"footnote-reference\"").count(), 2);
    assert!(body.contains("Source, p. 4"));
    assert!(!body.contains("^["));
}

#[test]
fn block_ids_become_anchors_and_block_links_target_them() {
    let html = render_document(
        "A key claim. ^claim-1\n\nSee [[#^claim-1]] and [[Other#^b2|there]].",
        "B",
    )
    .unwrap();
    let body = main_of(&html);
    assert!(body.contains("A key claim.<span class=\"block-id\" id=\"^claim-1\"></span>"));
    assert!(!body.contains("^claim-1</p>"));
    assert!(body.contains("href=\"#^claim-1\""));
    assert!(body.contains("href=\"Other.md#^b2\""));
}

#[test]
fn custom_task_statuses_render_as_checked_boxes() {
    let html = render_document(
        "- [/] started\n- [-] dropped\n- [ ] open\n- [x] done",
        "Tasks",
    )
    .unwrap();
    let body = main_of(&html);
    assert!(body.contains("data-task=\"/\"/>\nstarted"));
    assert!(body.contains("data-task=\"-\"/>\ndropped"));
    assert!(!body.contains("[/]"));
    assert_eq!(body.matches("checked=\"\"").count(), 3);
}

#[test]
fn image_sizes_and_media_embeds_follow_obsidian_syntax() {
    let html = render_document(
        "![A cat|250](cat.png) ![[pic.png|300x200]] ![[song.mp3]] ![[clip.mp4|640]] ![[Spec.pdf]]",
        "Media",
    )
    .unwrap();
    let body = main_of(&html);
    assert!(body.contains("<img src=\"cat.png\" alt=\"A cat\" width=\"250\" loading=\"lazy\" />"));
    assert!(body.contains("<img src=\"pic.png\" alt=\"\" width=\"300\" height=\"200\""));
    assert!(body.contains("<audio class=\"media-embed\" controls src=\"song.mp3\">"));
    assert!(body.contains("<video class=\"media-embed\" controls src=\"clip.mp4\" width=\"640\">"));
    assert!(body.contains("<a class=\"embed-link pdf-embed\" href=\"Spec.pdf\">Spec.pdf</a>"));
    assert!(html.contains("media-src 'self' data: file:"));
}

#[test]
fn attachments_are_found_in_vault_folders_like_obsidian() {
    let scratch = Scratch::new("vault");
    std::fs::create_dir_all(scratch.0.join(".obsidian")).unwrap();
    scratch.write("attachments/Pasted image 1.png", PNG_1X1);
    scratch.write("Deep/Down/elsewhere.png", PNG_1X1);
    let note_dir = scratch.0.join("Notes/Sub");
    std::fs::create_dir_all(&note_dir).unwrap();

    let html = render_document_with_options(
        "![[Pasted image 1.png]] ![[elsewhere.png]] ![[missing.png]]",
        "Vault",
        &ExportOptions {
            asset_base: Some(&note_dir),
            vault_root: None,
            ..Default::default()
        },
    )
    .unwrap();
    assert_eq!(html.matches("src=\"data:image/png;base64,").count(), 2);
    assert!(html.contains("src=\"missing.png\""));
}

#[test]
fn note_embeds_transclude_sections_blocks_and_stop_at_cycles() {
    let scratch = Scratch::new("transclude");
    scratch.write(
        "Plan.md",
        b"---\ntags: [x]\n---\n# Plan\n\nIntro text.\n\n## Goals\n\nShip it ==now==.\n\n## Later\n\nNot this.\n\nA quotable line. ^quote\n",
    );
    scratch.write("Loop.md", b"Loop start ![[Loop]]");
    let html = render_document_with_options(
        "![[Plan]]\n\n![[Plan#Goals]]\n\n![[Plan#^quote]]\n\n![[Loop]]\n\n![[Nowhere]]",
        "Embeds",
        &ExportOptions {
            asset_base: Some(&scratch.0),
            vault_root: None,
            ..Default::default()
        },
    )
    .unwrap();
    let body = main_of(&html);
    // Three sections of Plan, and Loop once: its embed of itself is a link.
    assert_eq!(body.matches("<div class=\"markdown-embed\">").count(), 4);
    assert!(!body.contains("tags: [x]"), "frontmatter is not shown");
    assert!(body.contains("<mark>now</mark>"));
    let goals = body.split("href=\"Plan.md#goals\"").nth(1).unwrap();
    let goals = &goals[..goals.find("</div></div>").unwrap()];
    assert!(goals.contains("Ship it") && !goals.contains("Not this"));
    let quote = body.split("href=\"Plan.md#^quote\"").nth(1).unwrap();
    let quote = &quote[..quote.find("</div></div>").unwrap()];
    assert!(quote.contains("A quotable line.") && !quote.contains("Intro"));
    assert!(body.contains("<a class=\"internal-link embed-link\" href=\"Nowhere.md\">Nowhere</a>"));
    assert_eq!(body.matches("Loop start").count(), 1);
    assert!(body.contains("<a class=\"internal-link embed-link\" href=\"Loop.md\">Loop</a>"));
}

#[test]
fn wikilinks_resolve_to_notes_in_other_folders() {
    let scratch = Scratch::new("links");
    std::fs::create_dir_all(scratch.0.join(".obsidian")).unwrap();
    scratch.write("Projects/Roadmap.md", b"# Roadmap");
    let note_dir = scratch.0.join("Daily");
    std::fs::create_dir_all(&note_dir).unwrap();
    let html = render_document_with_options(
        "[[Roadmap]] [[Roadmap#Q3 Goals|goals]]",
        "Links",
        &ExportOptions {
            asset_base: Some(&note_dir),
            vault_root: None,
            ..Default::default()
        },
    )
    .unwrap();
    assert!(html.contains("href=\"../Projects/Roadmap.md\""));
    assert!(html.contains("href=\"../Projects/Roadmap.md#q3-goals\""));
}

// MARK: - Math

#[cfg(feature = "mathml")]
#[test]
fn dollar_math_is_typeset_as_mathml() {
    let html = render_document("Euler: $e^{i\\pi}+1=0$\n\n$$\\int_0^1 x^2\\,dx$$", "Math").unwrap();
    let body = main_of(&html);
    assert!(body.contains("<span class=\"math math-inline\"><math display=\"inline\">"));
    assert!(body.contains("<mi>π</mi>"));
    assert!(body.contains("<span class=\"math math-display\"><math display=\"block\">"));
    assert!(body.contains("∫"));
    assert!(!body.contains("math-source"));
}

#[cfg(feature = "mathml")]
#[test]
fn editor_math_delimiters_and_math_fences_are_typeset_too() {
    let html = render_document(
        "Inline \\(x^2\\) here.\n\n\\[\n\\frac{a}{b}\n\\]\n\n```math\n\\sqrt{2}\n```",
        "Delimiters",
    )
    .unwrap();
    let body = main_of(&html);
    assert!(body.contains("<msup><mi>x</mi><mn>2</mn></msup>"));
    assert!(body.contains("<mfrac>"));
    assert!(body.contains("<msqrt>"));
    assert!(!body.contains("\\("), "delimiters are not left behind");
    assert!(
        !body.contains("<pre>"),
        "a typeset math fence is not a code block"
    );
}

#[cfg(feature = "mathml")]
#[test]
fn currency_is_prose_and_unknown_commands_fall_back_to_source() {
    let html = render_document(
        "It costs $5 and $10 today.\n\nBad $\\notacommand{x}$ here.",
        "Money",
    )
    .unwrap();
    let body = main_of(&html);
    assert!(body.contains("It costs $5 and $10 today."));
    assert!(body.contains("<span class=\"math math-inline math-source\">\\notacommand{x}</span>"));
    assert!(!body.contains("merror"));
}

#[cfg(feature = "mathml")]
#[test]
fn typeset_math_stays_inert() {
    let html = render_document(
        "$a<b>c$ and $\\text{<script>alert(1)</script>}$ and $\\text{</math><img src=x onerror=alert(1)>}$",
        "Inert",
    )
    .unwrap();
    let body = main_of(&html);
    assert!(!body.contains("<script"));
    assert!(!body.contains("<img"));
    assert!(body.contains("<mo>&lt;</mo>"));
    assert!(body.contains("<mo>&gt;</mo>"));
    assert_eq!(
        body.matches("<math").count(),
        body.matches("</math>").count()
    );
}

#[cfg(feature = "mathml")]
#[test]
fn math_inside_code_is_never_typeset() {
    let html = render_document("`$x^2$` and\n\n```\n\\(y\\)\n```", "Code").unwrap();
    let body = main_of(&html);
    assert!(!body.contains("<math"));
    assert!(body.contains("<code>$x^2$</code>"));
    assert!(body.contains("\\(y\\)"));
}

#[cfg(not(feature = "mathml"))]
#[test]
fn without_mathml_formulas_stay_as_source() {
    let html = render_document("$x^2$ and \\(y\\)", "Plain").unwrap();
    let body = main_of(&html);
    assert!(!body.contains("<math"));
    assert!(body.contains("<span class=\"math math-inline math-source\">x^2</span>"));
    assert!(body.contains("<span class=\"math math-inline math-source\">y</span>"));
}

// MARK: - Link bases

#[test]
fn links_point_from_where_the_page_is_saved() {
    let scratch = Scratch::new("linkbase");
    std::fs::create_dir_all(scratch.0.join(".obsidian")).unwrap();
    scratch.write("Notes/Other.md", b"# Other");
    scratch.write("Notes/media/clip.mp4", b"not really video");
    let notes = scratch.0.join("Notes");
    let out = scratch.0.join("Exports/2026");
    std::fs::create_dir_all(&out).unwrap();
    let source = "[[Other]] [md](Other.md#top) ![[clip.mp4]] [web](https://example.com) [here](#x)";

    let html = render_document_with_options(
        source,
        "L",
        &ExportOptions {
            asset_base: Some(&notes),
            link_base: LinkBase::Directory(&out),
            ..Default::default()
        },
    )
    .unwrap();
    assert!(html.contains("href=\"../../Notes/Other.md\""), "wikilink");
    assert!(
        html.contains("href=\"../../Notes/Other.md#top\""),
        "markdown link"
    );
    assert!(html.contains("src=\"../../Notes/media/clip.mp4\""), "media");
    assert!(html.contains("href=\"https://example.com\""));
    assert!(html.contains("href=\"#x\""));
}

#[test]
fn browser_previews_use_absolute_file_urls() {
    let scratch = Scratch::new("fileurl");
    scratch.write("My Notes/Other.md", b"# Other");
    let notes = scratch.0.join("My Notes");
    let html = render_document_with_options(
        "[[Other]] [x](Missing%20File.md)",
        "P",
        &ExportOptions {
            asset_base: Some(&notes),
            link_base: LinkBase::FileUrl,
            ..Default::default()
        },
    )
    .unwrap();
    let expected = format!(
        "href=\"file://{}/My%20Notes/Other.md\"",
        scratch.0.to_str().unwrap()
    );
    assert!(html.contains(&expected), "{html}");
    assert!(html.contains("/My%20Notes/Missing%20File.md\""));
}

#[test]
fn links_inside_transcluded_notes_point_from_the_page() {
    let scratch = Scratch::new("translinks");
    scratch.write("Sub/Embedded.md", b"See [[Sibling]] and ![[pic.mp3]].");
    scratch.write("Sub/Sibling.md", b"# Sibling");
    let html = render_document_with_options(
        "![[Sub/Embedded]]",
        "T",
        &ExportOptions {
            asset_base: Some(&scratch.0),
            ..Default::default()
        },
    )
    .unwrap();
    assert!(html.contains("href=\"Sub/Sibling.md\""), "{html}");
    assert!(html.contains("src=\"Sub/pic.mp3\""));
}

#[test]
fn highlights_wrap_formatting_links_and_match_the_editor() {
    let html = render_document(
        "A ==**bold**== and ==[[Note]]== and ==a *b* c==, not **x ==y** z== or `==code==`.\n\n> [!note] A ==titled== callout\n> body",
        "Marks",
    )
    .unwrap();
    let body = main_of(&html);
    assert!(body.contains("<mark><strong>bold</strong></mark>"));
    assert!(body.contains("<mark><a href=\"Note.md\">Note</a></mark>"));
    assert!(body.contains("<mark>a <em>b</em> c</mark>"));
    assert!(body.contains("<strong>x ==y</strong> z=="));
    assert!(body.contains("<code>==code==</code>"));
    assert!(body.contains("A <mark>titled</mark> callout"));
    assert_eq!(
        body.matches("<mark>").count(),
        body.matches("</mark>").count()
    );
}

#[test]
fn nested_callouts_render_inside_their_parent() {
    let html = render_document(
        "> [!note] Outer\n> text\n> > [!warning] Inner\n> > deep",
        "Nested",
    )
    .unwrap();
    let body = main_of(&html);
    let outer = body.find("data-callout=\"note\"").unwrap();
    let inner = body.find("data-callout=\"warning\"").unwrap();
    assert!(outer < inner);
    assert!(body.contains("<span class=\"callout-title-inner\">Inner</span>"));
    assert!(!body.contains("[!warning]"));
    assert!(!body.contains("<blockquote"));
}

#[test]
fn nested_heading_links_and_embeds_target_the_inner_heading() {
    let scratch = Scratch::new("nested-headings");
    scratch.write(
        "Guide.md",
        b"# Guide\n\n## Setup\n\n### macOS\n\nSetup text.\n\n## Usage\n\n### macOS\n\nUsage text.\n",
    );
    let html = render_document_with_options(
        "[[Guide#Usage#macOS|mac]]\n\n![[Guide#Usage#macOS]]",
        "N",
        &ExportOptions {
            asset_base: Some(&scratch.0),
            ..Default::default()
        },
    )
    .unwrap();
    assert!(html.contains("href=\"Guide.md#macos\""));
    let embed = main_of(&html)
        .split("markdown-embed-content")
        .nth(1)
        .unwrap();
    assert!(embed.contains("Usage text.") && !embed.contains("Setup text."));
}

#[test]
fn obsidians_attachment_folder_setting_is_honoured() {
    for (setting, stored) in [
        ("Files/Images", "Files/Images/shot.png"),
        ("./assets-here", "Notes/assets-here/shot.png"),
        ("/", "shot.png"),
    ] {
        let scratch = Scratch::new("attachment-setting");
        scratch.write(
            ".obsidian/app.json",
            format!("{{\"attachmentFolderPath\": \"{setting}\"}}").as_bytes(),
        );
        scratch.write(stored, PNG_1X1);
        // A same-named decoy on a shorter path, which the by-name search
        // alone would prefer.
        if setting != "/" {
            scratch.write("Other/shot.png", b"GIF89a\x01\x00\x01\x00\x00\x00\x00;");
        }
        let notes = scratch.0.join("Notes");
        std::fs::create_dir_all(&notes).unwrap();
        let html = render_document_with_options(
            "![[shot.png]]",
            "A",
            &ExportOptions {
                asset_base: Some(&notes),
                vault_root: Some(&scratch.0),
                ..Default::default()
            },
        )
        .unwrap();
        assert!(html.contains("src=\"data:image/png;base64,"), "{setting}");
    }
}
