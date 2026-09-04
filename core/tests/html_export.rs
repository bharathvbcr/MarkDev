use markdev::ffi::{md_html_bytes, md_html_free, md_html_render};
use markdev::html::{render_document, HTMLExportError, MAX_SOURCE_BYTES, MAX_TITLE_BYTES};

#[test]
fn markdown_is_rendered_as_semantic_html() {
    let html = render_document(
        "# Heading\n\nA **strong** idea.\n\n- [x] done\n\n| A | B |\n|---|---|\n| 1 | 2 |",
        "Example",
    )
    .expect("ordinary markdown should export");

    assert!(html.contains("<h1>Heading</h1>"));
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
        .contains("<h1>FFI 🧪</h1>"));
    unsafe { md_html_free(handle) };

    let invalid = [0xff_u8];
    let rejected = unsafe { md_html_render(invalid.as_ptr(), invalid.len(), std::ptr::null(), 0) };
    assert!(rejected.is_null());
}
