use std::path::PathBuf;

use markdev::ffi::{md_html_bytes, md_html_free, md_html_render, md_html_render_with_base};
use markdev::html::{
    render_document, render_document_with_options, slugify, sniff_image, ExportOptions,
    HTMLExportError, MAX_EMBEDDED_IMAGE_BYTES, MAX_SOURCE_BYTES, MAX_TITLE_BYTES,
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
    assert!(html.contains("<blockquote class=\"markdown-alert-warning\">"));
    assert!(html.contains("class=\"math math-display\""));
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
        )
    };
    assert!(rejected.is_null());
}
