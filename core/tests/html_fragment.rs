//! Contracts for [`render_fragment`]: the embeddable body renderer.
//!
//! An embedder puts this HTML straight into its own page, under its own
//! Content-Security-Policy rather than the export's closed one, and it is
//! typically showing Markdown nobody vetted — a cloned repository's README.
//! So beyond rendering correctly, the output has to be safe *by
//! construction* for every input, which is what the property tests below
//! check: whatever the document, no element or attribute can run code or
//! reach a scheme it should not, every tag closes, and the outline names only
//! ids the HTML carries.

use std::path::PathBuf;
use std::time::{Duration, Instant};

use markdev::html::{render_fragment, ExportOptions, FileAccess, Fragment};
use proptest::prelude::*;

fn fragment(source: &str) -> Fragment {
    render_fragment(
        source,
        &ExportOptions {
            file_access: FileAccess::None,
            ..Default::default()
        },
    )
    .expect("render")
}

fn html(source: &str) -> String {
    fragment(source).html
}

// ---------------------------------------------------------------------------
// A small HTML reader, enough to audit what the renderer itself wrote. Author
// HTML is always escaped to text, so every `<` in the output opens a tag the
// renderer made; that is what lets so simple a reader be exact here.
// ---------------------------------------------------------------------------

#[derive(Debug)]
struct Tag {
    name: String,
    closing: bool,
    self_closing: bool,
    attributes: Vec<(String, String)>,
}

fn tags(html: &str) -> Vec<Tag> {
    let bytes = html.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] != b'<' {
            i += 1;
            continue;
        }
        let end = html[i..]
            .find('>')
            .map(|e| i + e)
            .expect("unterminated tag");
        let inner = &html[i + 1..end];
        let closing = inner.starts_with('/');
        let self_closing = inner.ends_with('/');
        let body = inner.trim_start_matches('/').trim_end_matches('/');
        let name_end = body.find(|c: char| c.is_whitespace()).unwrap_or(body.len());
        let name = body[..name_end].to_ascii_lowercase();
        let mut attributes = Vec::new();
        let mut rest = body[name_end..].trim_start();
        while !rest.is_empty() {
            let key_end = rest
                .find(|c: char| c == '=' || c.is_whitespace())
                .unwrap_or(rest.len());
            let key = rest[..key_end].to_ascii_lowercase();
            rest = &rest[key_end..];
            let value = if let Some(after) = rest.strip_prefix('=') {
                let after = after
                    .strip_prefix('"')
                    .expect("attribute values are double-quoted");
                let close = after.find('"').expect("closed attribute value");
                let value = after[..close].to_owned();
                rest = &after[close + 1..];
                value
            } else {
                String::new()
            };
            attributes.push((key, value));
            rest = rest.trim_start();
        }
        out.push(Tag {
            name,
            closing,
            self_closing,
            attributes,
        });
        i = end + 1;
    }
    out
}

const VOID: &[&str] = &["br", "hr", "img", "input"];

/// Elements that can run code, load a document, submit, or restyle the host
/// page. None may ever appear: the renderer has no reason to write them, so
/// one appearing means author input reached the markup.
const FORBIDDEN_ELEMENTS: &[&str] = &[
    "script",
    "style",
    "iframe",
    "frame",
    "frameset",
    "object",
    "embed",
    "applet",
    "link",
    "meta",
    "base",
    "form",
    "input-image",
    "textarea",
    "select",
    "button",
    "template",
    "foreignobject",
    "animate",
    "set",
    "use",
    "noscript",
    "portal",
];

/// Attributes whose value is a URL the browser may load or navigate to.
const URL_ATTRIBUTES: &[&str] = &[
    "href",
    "src",
    "xlink:href",
    "action",
    "formaction",
    "poster",
];

fn url_is_safe(attribute: &str, element: &str, value: &str) -> bool {
    let decoded = value.replace("&amp;", "&");
    let compact: String = decoded
        .chars()
        .filter(|c| !c.is_ascii_control() && !c.is_ascii_whitespace())
        .collect();
    let lower = compact.to_ascii_lowercase();
    let scheme = lower.find(':').and_then(|colon| {
        let boundary = lower.find(['/', '?', '#']).unwrap_or(usize::MAX);
        (colon < boundary).then(|| &lower[..colon])
    });
    match scheme {
        None => true,
        Some("http" | "https" | "mailto" | "file") => true,
        // Embedded pictures, and only on a picture.
        Some("data") => element == "img" && attribute == "src" && lower.starts_with("data:image/"),
        Some(_) => false,
    }
}

/// Typeset math is MathML, whose element names all begin with `m` (`math`,
/// `mi`, `mspace`, `mrow`, …); no HTML element the renderer writes does.
fn is_mathml(element: &str) -> bool {
    element.starts_with('m') && element != "mark" && element != "menu" && element != "meta"
}

/// Largest spacing typeset math may carry, in em — the renderer's bound.
const MAX_MATH_SPACE_EM: f32 = 8.0;

/// A CSS length the math renderer wrote, in em; `None` when it is not one.
fn length_in_em(value: &str) -> Option<f32> {
    let value = value.trim();
    let split = value.find(|c: char| c.is_ascii_alphabetic())?;
    let number: f32 = value[..split].parse().ok()?;
    let per_unit = match &value[split..] {
        "em" => 1.0,
        "mu" => 1.0 / 18.0,
        "ex" => 0.431,
        "pt" => 0.1,
        "pc" => 1.2,
        "in" => 7.227,
        "bp" => 0.100_375,
        "cm" => 2.845_276,
        "mm" => 0.284_528,
        "dd" => 0.107,
        "cc" => 1.284,
        "sp" => 0.1 / 65_536.0,
        _ => return None,
    };
    let em = number * per_unit;
    em.is_finite().then_some(em)
}

fn space_is_bounded(value: &str) -> bool {
    length_in_em(value).is_some_and(|em| em.abs() <= MAX_MATH_SPACE_EM + 1e-3)
}

/// The declarations pulldown-latex writes, and nothing else: bounded spacing
/// and numeric colours. A declaration outside this grammar means author text
/// reached a `style` attribute, or a spacing escaped its bound.
fn mathml_style_is_inert(value: &str) -> bool {
    let rgb = |v: &str| {
        v.strip_prefix("rgb(")
            .and_then(|v| v.strip_suffix(')'))
            .is_some_and(|v| {
                let parts: Vec<_> = v.split(' ').collect();
                parts.len() == 3 && parts.iter().all(|p| p.parse::<u8>().is_ok())
            })
    };
    value
        .split(';')
        .map(str::trim)
        .filter(|d| !d.is_empty())
        .all(|declaration| {
            let Some((property, v)) = declaration.split_once(':') else {
                return false;
            };
            let v = v.trim();
            match property.trim() {
                "margin-left" | "height" => space_is_bounded(v),
                "color" | "background-color" => rgb(v),
                "border" => v.strip_prefix("0.06em solid ").is_some_and(rgb),
                "border-color" => v.strip_prefix('#').is_some_and(|h| {
                    (1..=6).contains(&h.len()) && h.bytes().all(|b| b.is_ascii_hexdigit())
                }),
                _ => false,
            }
        })
}

/// Every safety invariant over one rendered body. Returns the first breach.
fn audit(html: &str) -> Result<(), String> {
    let mut stack: Vec<String> = Vec::new();
    for tag in tags(html) {
        if FORBIDDEN_ELEMENTS.contains(&tag.name.as_str()) {
            return Err(format!("forbidden element <{}>", tag.name));
        }
        for (key, value) in &tag.attributes {
            if key.starts_with("on") {
                return Err(format!("event handler {key} on <{}>", tag.name));
            }
            if key == "srcdoc" || key == "srcset" {
                return Err(format!("{key} on <{}>", tag.name));
            }
            if key == "style" {
                let ok = [
                    "text-align: left",
                    "text-align: center",
                    "text-align: right",
                ]
                .contains(&value.as_str())
                    || (is_mathml(&tag.name) && mathml_style_is_inert(value));
                if !ok {
                    return Err(format!("style={value:?} on <{}>", tag.name));
                }
            }
            if tag.name == "mspace"
                && matches!(key.as_str(), "width" | "height" | "depth")
                && !space_is_bounded(value)
            {
                return Err(format!("{key}={value:?} on <mspace>"));
            }
            if URL_ATTRIBUTES.contains(&key.as_str()) && !url_is_safe(key, &tag.name, value) {
                return Err(format!("{key}={value:?} on <{}>", tag.name));
            }
            if tag.name == "input" && key == "type" && value != "checkbox" {
                return Err(format!("input type={value:?}"));
            }
            if tag.name == "input"
                && !["type", "disabled", "checked", "data-task"].contains(&key.as_str())
            {
                return Err(format!("input attribute {key}"));
            }
        }
        if tag.name == "input" && !tag.attributes.iter().any(|(k, _)| k == "disabled") {
            return Err("an enabled input".into());
        }
        if tag.closing {
            match stack.pop() {
                Some(open) if open == tag.name => {}
                other => return Err(format!("</{}> closes {other:?}", tag.name)),
            }
        } else if !tag.self_closing && !VOID.contains(&tag.name.as_str()) {
            stack.push(tag.name);
        }
    }
    if stack.is_empty() {
        Ok(())
    } else {
        Err(format!("unclosed {stack:?}"))
    }
}

/// The outline names exactly the headings the HTML carries, by id, in order.
fn audit_outline(fragment: &Fragment) -> Result<(), String> {
    let heading_ids: Vec<String> = tags(&fragment.html)
        .into_iter()
        .filter(|t| {
            !t.closing
                && t.name.len() == 2
                && t.name.starts_with('h')
                && t.name.as_bytes()[1].is_ascii_digit()
        })
        .map(|t| {
            t.attributes
                .iter()
                .find(|(k, _)| k == "id")
                .map(|(_, v)| v.clone())
                .unwrap_or_default()
        })
        .collect();
    let outline_ids: Vec<String> = fragment.headings.iter().map(|h| h.id.clone()).collect();
    if heading_ids != outline_ids {
        return Err(format!(
            "html ids {heading_ids:?} vs outline {outline_ids:?}"
        ));
    }
    let mut seen = std::collections::HashSet::new();
    for id in &outline_ids {
        if id.is_empty() || !seen.insert(id) {
            return Err(format!("empty or duplicate heading id {id:?}"));
        }
    }
    for heading in &fragment.headings {
        if !(1..=6).contains(&heading.level) {
            return Err(format!("heading level {}", heading.level));
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Rendering: what used to go wrong when HTML was rebuilt from the editor's
// model, pinned construct by construct.
// ---------------------------------------------------------------------------

#[test]
fn inline_syntax_is_consumed_and_nesting_survives() {
    assert_eq!(
        html("Some **bold** and *em* and `code` text."),
        "<p>Some <strong>bold</strong> and <em>em</em> and <code>code</code> text.</p>\n"
    );
    assert_eq!(
        html("**bold with *nested em* inside**"),
        "<p><strong>bold with <em>nested em</em> inside</strong></p>\n"
    );
    assert_eq!(
        html("[a **bold** link](https://x.y)"),
        "<p><a href=\"https://x.y\">a <strong>bold</strong> link</a></p>\n"
    );
    assert_eq!(
        html("~~strike~~ ==hi== #tag"),
        "<p><del>strike</del> <mark>hi</mark> <span class=\"tag\">#tag</span></p>\n"
    );
}

#[test]
fn headings_carry_unique_ids_and_the_outline_names_them() {
    let rendered = fragment("# Hello **World**\n\n## Dup\n\n## Dup\n\nSetext\n======\n");
    assert!(rendered
        .html
        .starts_with("<h1 id=\"hello-world\">Hello <strong>World</strong>"));
    let outline: Vec<(u8, &str, &str)> = rendered
        .headings
        .iter()
        .map(|h| (h.level, h.text.as_str(), h.id.as_str()))
        .collect();
    assert_eq!(
        outline,
        [
            (1, "Hello World", "hello-world"),
            (2, "Dup", "dup"),
            (2, "Dup", "dup-1"),
            (1, "Setext", "setext"),
        ]
    );
    audit_outline(&rendered).unwrap();
}

#[test]
fn a_highlight_crossing_an_element_boundary_stays_nested() {
    // Found by the property test below: `==` paired across an emphasis
    // boundary wrote `<em>…<mark></em>…</mark>`.
    for source in [
        "~~_##==_**==",
        "_a==b_ c==",
        "==a *b== c*",
        "**x ==y** z==",
        "==a\n\nb==",
    ] {
        let rendered = html(source);
        audit(&rendered).unwrap_or_else(|breach| panic!("{source:?}: {breach}\n{rendered}"));
    }
    // An element wholly inside a highlight stays wrapped by one mark...
    assert_eq!(
        html("a ==b *c* d== e"),
        "<p>a <mark>b <em>c</em> d</mark> e</p>\n"
    );
    // ...and a highlight that opens inside an emphasis and closes after it is
    // split at the crossing: no `<mark>` straddles the `</em>`. (The editor
    // pairs `==` within one text run, so crossings come from delimiter runs
    // like this one.)
    assert_eq!(html("_##==_ x=="), "<p><em>##</em><mark> x</mark></p>\n");
}

#[test]
fn placeholders_never_leak_into_outline_or_alt_text() {
    let rendered = fragment("# ==Key== idea\n\n# Euler \\(e^{i}\\)\n\n![==a== b](p.png)");
    let texts: Vec<&str> = rendered.headings.iter().map(|h| h.text.as_str()).collect();
    assert_eq!(texts, ["Key idea", "Euler e^{i}"]);
    assert_eq!(rendered.headings[1].id, "euler-ei");
    assert!(rendered.html.contains("alt=\"a b\""), "{}", rendered.html);
    let private_use = |c: char| ('\u{e000}'..='\u{e003}').contains(&c);
    assert!(!rendered.html.contains(private_use), "{}", rendered.html);
    for heading in &rendered.headings {
        assert!(!heading.text.contains(private_use), "{heading:?}");
    }
}

#[test]
fn headings_inside_fences_are_not_headings() {
    let rendered = fragment("```\n# not a heading\n```\n\n~~~\n## nor this\n~~~\n");
    assert!(rendered.headings.is_empty(), "{:?}", rendered.headings);
}

#[test]
fn block_structure_nests() {
    assert_eq!(
        html("- item one\n- item **two**\n  - nested a\n  - nested b\n- three"),
        "<ul>\n<li>item one</li>\n<li>item <strong>two</strong>\n<ul>\n<li>nested a</li>\n<li>nested b</li>\n</ul>\n</li>\n<li>three</li>\n</ul>\n"
    );
    assert_eq!(
        html("3. three\n4. four"),
        "<ol start=\"3\">\n<li>three</li>\n<li>four</li>\n</ol>\n"
    );
    assert_eq!(
        html("> quoted line one\n> line two"),
        "<blockquote>\n<p>quoted line one\nline two</p>\n</blockquote>\n"
    );
    let table = html("| a | b |\n|:-|-:|\n| `x` | **y** |");
    assert!(table.contains("<thead><tr><th style=\"text-align: left\">a</th><th style=\"text-align: right\">b</th></tr></thead>"), "{table}");
    assert!(
        table.contains("<td style=\"text-align: left\"><code>x</code></td>"),
        "{table}"
    );
}

/// Found by `every_document_renders_safe_balanced_html`: pulldown-latex wrote
/// the author's spacing verbatim, so `\hspace{-1000em}` became
/// `margin-left: -1000em` and a formula could lay itself over the rest of the
/// page. Ordinary spacing must come through untouched.
#[cfg(feature = "mathml")]
#[test]
fn math_spacing_cannot_move_the_page() {
    for source in [
        r"$a\hspace{-1000em}b$",
        r"$\kern-500em x$",
        r"$a\hspace{99999999999999999999em}b$",
        r"$a\hspace{900cm}b$",
        r"$\begin{aligned}a\\[5000em]b\end{aligned}$",
    ] {
        let out = html(source);
        assert!(out.contains("<math"), "{source} should typeset: {out}");
        audit(&out).unwrap_or_else(|breach| panic!("{source}: {breach}\n{out}"));
    }
    for (source, kept) in [
        (r"$a\qquad b$", "width=\"2em\""),
        (r"$a\!b$", "margin-left: -0.16666667em"),
        (r"$a\hspace{2cm}b$", "width=\"2cm\""),
    ] {
        let out = html(source);
        assert!(out.contains(kept), "{source} lost {kept}: {out}");
    }
}

#[test]
fn callouts_tasks_breaks_footnotes_and_definitions_render() {
    let callout = html("> [!WARNING]\n> Body **b**");
    assert!(callout.contains("data-callout=\"warning\""), "{callout}");
    assert!(
        callout.contains("<p>Body <strong>b</strong></p>"),
        "{callout}"
    );
    assert!(!callout.contains("[!WARNING]"), "{callout}");

    let tasks = html("- [ ] todo\n- [x] done");
    assert!(
        tasks.contains("<input disabled=\"\" type=\"checkbox\"/>"),
        "{tasks}"
    );
    assert!(tasks.contains("checked=\"\""), "{tasks}");

    assert!(html("line two  \nhard").contains("line two<br />"));
    let notes = html("Ref[^1].\n\n[^1]: The note.");
    assert!(notes.contains("class=\"footnote-reference\""), "{notes}");
    assert!(notes.contains("class=\"footnote-definition\""), "{notes}");
    assert_eq!(
        html("Term\n: Definition"),
        "<dl>\n<dt>Term</dt>\n<dd>Definition</dd>\n</dl>\n"
    );
    assert_eq!(
        html("[ref]: https://example.com\n\nUse [ref]."),
        "<p>Use <a href=\"https://example.com\">ref</a>.</p>\n"
    );
}

#[test]
fn entities_decode_once_and_escapes_drop_their_backslash() {
    assert_eq!(
        html("a &amp; b &copy; \\*not em\\*"),
        "<p>a &amp; b © *not em*</p>\n"
    );
}

#[test]
fn frontmatter_is_returned_not_rendered() {
    let rendered = fragment("---\ntitle: x\ntags: [a, b]\n---\n# After");
    assert_eq!(
        rendered.frontmatter.as_deref(),
        Some("title: x\ntags: [a, b]\n")
    );
    assert!(!rendered.html.contains("title"), "{}", rendered.html);
    assert_eq!(rendered.headings.len(), 1);
    assert_eq!(fragment("# No frontmatter").frontmatter, None);
}

#[test]
fn code_keeps_its_language_and_drops_fence_and_indent() {
    assert_eq!(
        html("```rust\nfn main() {}\n```"),
        "<pre><code class=\"language-rust\">fn main() {}\n</code></pre>\n"
    );
    assert_eq!(html("    indented"), "<pre><code>indented</code></pre>\n");
}

// ---------------------------------------------------------------------------
// Safety.
// ---------------------------------------------------------------------------

#[test]
fn hostile_documents_never_produce_active_markup() {
    let corpus = [
        "[c](javascript:alert(1))",
        "[c](JaVaScRiPt:alert(1))",
        "[c](java\tscript:alert(1))",
        "[c](&#106;avascript:alert(1))",
        "[c](&#x6A;avascript:alert(1))",
        "[c](<javascript:alert(1)>)",
        "<javascript:alert(1)>",
        "[c](vbscript:msgbox(1))",
        "[c](data:text/html,<script>alert(1)</script>)",
        "![i](javascript:alert(1))",
        "![i](data:text/html;base64,PHNjcmlwdD4=)",
        "[[javascript:alert(1)]]",
        "![[javascript:alert(1)]]",
        "[r]\n\n[r]: javascript:alert(1)",
        "<script>alert(1)</script>",
        "<img src=x onerror=alert(1)>",
        "text <img src=x onerror=alert(1)> inline",
        "<svg onload=alert(1)>",
        "[t](https://x \"a\\\" onmouseover=\\\"alert(1)\")",
        "[t](https://x 'a\" onmouseover=\"alert(1)')",
        "```\"><script>alert(1)</script>\nx\n```",
        "# <script>alert(1)</script>",
        "Ref[^\"><script>].\n\n[^\"><script>]: note",
        "> [!NOTE] <img src=x onerror=alert(1)>\n> body",
        "> [!x\" onclick=\"alert(1)]\n> body",
        "- [\"] custom\" onclick=\"x",
        "![a|100\" onload=\"x](p.png)",
        "$\\href{javascript:alert(1)}{x}$",
        "$$\\href{javascript:alert(1)}{x}$$",
        "<style>body{display:none}</style>",
        "<iframe src=https://x></iframe>",
        "<a href=javascript:alert(1)>x</a>",
    ];
    for source in corpus {
        for remote_media in [false, true] {
            let rendered = render_fragment(
                source,
                &ExportOptions {
                    file_access: FileAccess::None,
                    remote_media,
                    ..Default::default()
                },
            )
            .unwrap();
            if let Err(breach) = audit(&rendered.html) {
                panic!(
                    "{source:?} (remote_media={remote_media}): {breach}\n{}",
                    rendered.html
                );
            }
        }
    }
}

#[test]
fn remote_pictures_load_only_when_asked_and_never_send_a_referrer() {
    let source = "![alt](https://example.com/p.png)";
    let off = html(source);
    assert!(off.contains("src=\"#\""), "{off}");
    let on = render_fragment(
        source,
        &ExportOptions {
            file_access: FileAccess::None,
            remote_media: true,
            ..Default::default()
        },
    )
    .unwrap()
    .html;
    assert!(on.contains("src=\"https://example.com/p.png\""), "{on}");
    assert!(on.contains("referrerpolicy=\"no-referrer\""), "{on}");
    // Opting into remote media widens http(s) only.
    let hostile = render_fragment(
        "![x](javascript:alert(1))",
        &ExportOptions {
            remote_media: true,
            ..Default::default()
        },
    )
    .unwrap()
    .html;
    assert!(hostile.contains("src=\"#\""), "{hostile}");
}

// ---------------------------------------------------------------------------
// File access.
// ---------------------------------------------------------------------------

const PNG: &[u8] = &[
    0x89, b'P', b'N', b'G', b'\r', b'\n', 0x1a, b'\n', 0, 0, 0, 13, b'I', b'H', b'D', b'R', 0, 0,
    0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 0x1f, 0x15, 0xc4, 0x89,
];

struct Sandbox(PathBuf);

impl Sandbox {
    fn new(label: &str) -> Self {
        let root =
            std::env::temp_dir().join(format!("markdev-fragment-{label}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("vault/docs")).unwrap();
        std::fs::create_dir_all(root.join("outside")).unwrap();
        std::fs::write(root.join("vault/docs/inside.png"), PNG).unwrap();
        std::fs::write(root.join("outside/secret.png"), PNG).unwrap();
        std::fs::write(root.join("outside/Secret.md"), "SECRET-NOTE-BODY").unwrap();
        Sandbox(root)
    }

    fn vault(&self) -> PathBuf {
        self.0.join("vault")
    }

    fn render(&self, source: &str, access: FileAccess, vault_root: bool) -> String {
        let vault = self.vault();
        let docs = vault.join("docs");
        render_fragment(
            source,
            &ExportOptions {
                asset_base: Some(&docs),
                vault_root: vault_root.then_some(vault.as_path()),
                file_access: access,
                ..Default::default()
            },
        )
        .unwrap()
        .html
    }
}

impl Drop for Sandbox {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn embeds(html: &str) -> usize {
    html.matches("src=\"data:image/").count()
}

#[test]
fn a_contained_render_embeds_pictures_inside_the_vault() {
    let sandbox = Sandbox::new("inside");
    let html = sandbox.render("![in](inside.png)", FileAccess::Vault, true);
    assert_eq!(embeds(&html), 1, "{html}");
}

#[test]
fn a_contained_render_reads_nothing_outside_the_vault() {
    let sandbox = Sandbox::new("escape");
    let outside = sandbox.0.join("outside");
    let absolute = outside.join("secret.png");
    let attempts = [
        "![x](../../outside/secret.png)".to_owned(),
        format!("![x]({})", absolute.display()),
        format!("![x](file://{})", absolute.display()),
        format!("![x](<{}>)", absolute.display()),
        "![x](..%2F..%2Foutside%2Fsecret.png)".to_owned(),
        "![[../../outside/secret.png]]".to_owned(),
        "![[../../outside/Secret]]".to_owned(),
    ];
    for source in &attempts {
        let html = sandbox.render(source, FileAccess::Vault, true);
        assert_eq!(embeds(&html), 0, "{source} embedded: {html}");
        assert!(
            !html.contains("SECRET-NOTE-BODY"),
            "{source} transcluded: {html}"
        );
        // The same document, unconfined, does read it — so the refusal above
        // is the gate's doing, not a path that simply failed to resolve.
        let unconfined = sandbox.render(source, FileAccess::Unrestricted, true);
        assert!(
            embeds(&unconfined) == 1 || unconfined.contains("SECRET-NOTE-BODY"),
            "{source} did not resolve even unconfined, so it proves nothing: {unconfined}"
        );
    }
}

#[cfg(unix)]
#[test]
fn a_contained_render_does_not_follow_a_symlink_out_of_the_vault() {
    use std::os::unix::fs::symlink;
    let sandbox = Sandbox::new("symlink");
    let docs = sandbox.vault().join("docs");
    symlink(
        sandbox.0.join("outside/secret.png"),
        docs.join("linked.png"),
    )
    .unwrap();
    symlink(sandbox.0.join("outside"), docs.join("linked-dir")).unwrap();
    symlink(sandbox.0.join("outside/Secret.md"), docs.join("Linked.md")).unwrap();
    for source in [
        "![x](linked.png)",
        "![x](linked-dir/secret.png)",
        "![[Linked]]",
    ] {
        let html = sandbox.render(source, FileAccess::Vault, true);
        assert_eq!(embeds(&html), 0, "{source}: {html}");
        assert!(!html.contains("SECRET-NOTE-BODY"), "{source}: {html}");
        let unconfined = sandbox.render(source, FileAccess::Unrestricted, true);
        assert!(
            embeds(&unconfined) == 1 || unconfined.contains("SECRET-NOTE-BODY"),
            "{source} proves nothing: {unconfined}"
        );
    }
    // A symlink that stays inside the vault is an ordinary file.
    symlink(docs.join("inside.png"), docs.join("alias.png")).unwrap();
    assert_eq!(
        embeds(&sandbox.render("![x](alias.png)", FileAccess::Vault, true)),
        1
    );
}

#[test]
fn vault_access_without_a_vault_root_and_no_access_read_nothing() {
    let sandbox = Sandbox::new("noroot");
    assert_eq!(
        embeds(&sandbox.render("![in](inside.png)", FileAccess::Vault, false)),
        0
    );
    assert_eq!(
        embeds(&sandbox.render("![in](inside.png)", FileAccess::None, true)),
        0
    );
    assert_eq!(
        embeds(&sandbox.render("![in](inside.png)", FileAccess::Unrestricted, true)),
        1
    );
}

#[test]
fn transclusion_is_confined_too_and_its_headings_stay_out_of_the_outline() {
    let sandbox = Sandbox::new("transclude");
    std::fs::write(
        sandbox.vault().join("docs/Other.md"),
        "# Theirs\n\nOTHER-BODY",
    )
    .unwrap();
    let vault = sandbox.vault();
    let docs = vault.join("docs");
    let rendered = render_fragment(
        "# Mine\n\n![[Other]]",
        &ExportOptions {
            asset_base: Some(&docs),
            vault_root: Some(&vault),
            file_access: FileAccess::Vault,
            ..Default::default()
        },
    )
    .unwrap();
    assert!(rendered.html.contains("OTHER-BODY"), "{}", rendered.html);
    let ids: Vec<_> = rendered.headings.iter().map(|h| h.id.as_str()).collect();
    assert_eq!(ids, ["mine"]);
}

// ---------------------------------------------------------------------------
// Pathological input: bounded time, well-formed output.
// ---------------------------------------------------------------------------

/// How many times slower than pulldown-cmark alone the renderer may be, on
/// top of a fixed allowance for inputs the parser finishes in microseconds.
/// Measured worst with a real baseline: 47x for 120 KiB of `\[…\]` formulas
/// in a debug build — where the quadratic this guards against took seconds.
const RENDER_OVER_PARSER: u32 = 25;

/// The fastest of `runs` calls, so a scheduling stall while the rest of the
/// suite runs in parallel does not read as the code being slow.
fn fastest<T>(runs: usize, mut call: impl FnMut() -> T) -> (T, Duration) {
    let mut best = None;
    let mut value = None;
    for _ in 0..runs {
        let started = Instant::now();
        let produced = call();
        let elapsed = started.elapsed();
        if best.is_none_or(|b| elapsed < b) {
            best = Some(elapsed);
        }
        value = Some(produced);
    }
    (
        value.expect("at least one run"),
        best.expect("at least one run"),
    )
}

fn timed(label: &str, source: &str) -> Fragment {
    let options = ExportOptions {
        file_access: FileAccess::None,
        ..Default::default()
    };
    // The bound is relative to pulldown-cmark on the same input, because the
    // renderer's own work is what this crate can promise. The parser itself
    // is super-linear on some of these inputs — alternating `*a_` quadruples
    // when it doubles — so an absolute timeout here measured the vendored
    // parser and the machine's load, not this code.
    let (_, parser) = fastest(3, || {
        let mut out = String::new();
        pulldown_cmark::html::push_html(
            &mut out,
            pulldown_cmark::Parser::new_ext(source, markdev::md::parse::options()),
        );
        out
    });
    let (rendered, ours) = fastest(3, || {
        render_fragment(source, &options).unwrap_or_else(|e| panic!("{label}: {e:?}"))
    });
    let budget = parser * RENDER_OVER_PARSER + Duration::from_millis(500);
    assert!(
        ours <= budget,
        "{label}: rendered in {ours:?}, pulldown-cmark alone in {parser:?}"
    );
    if let Err(breach) = audit(&rendered.html) {
        panic!("{label}: {breach}");
    }
    audit_outline(&rendered).unwrap_or_else(|e| panic!("{label}: {e}"));
    rendered
}

#[test]
fn pathological_documents_render_in_bounded_time_and_stay_well_formed() {
    timed("deep quotes", &">".repeat(10_000));
    timed("deep quotes per line", &"> ".repeat(5_000));
    timed(
        "deep list",
        &(0..2_000)
            .map(|d| format!("{}- x\n", "  ".repeat(d)))
            .collect::<String>(),
    );
    timed("open brackets", &"[".repeat(100_000));
    timed("open images", &"![".repeat(50_000));
    timed("asterisks", &"*".repeat(100_000));
    timed("alternating emphasis", &"*a_".repeat(10_000));
    timed("backticks", &"`".repeat(100_000));
    timed("equals", &"==".repeat(50_000));
    timed("one long line", &"word ".repeat(200_000));
    timed(
        "unterminated fence",
        &format!("```\n{}", "x\n".repeat(50_000)),
    );
    timed("many headings", &"# h\n".repeat(20_000));
    timed("many links", &"[a](b) ".repeat(30_000));
    timed("nul bytes", "a\0b\0# \0");
    timed("bom", "\u{feff}# Title\n");
    timed("crlf", &"# a\r\n\r\n- b\r\n".repeat(1_000));
    timed("lone cr", &"x\ry\r".repeat(10_000));
    timed("display formulas", &"\\[d\\] ".repeat(20_000));
    timed("display formula lines", &"\\[d\\]\n\n".repeat(15_000));
    timed("math soup", &"$a$ $$b$$ \\(c\\) \\[d\\] ".repeat(5_000));
    timed("comments", &"%%x%% ".repeat(20_000));
    timed("inline notes", &"a^[b] ".repeat(5_000));
    let headings = timed("duplicate headings", &"# Same\n".repeat(5_000));
    assert_eq!(headings.headings.len(), 5_000);
}

#[test]
fn oversized_input_is_refused_not_truncated() {
    let big = "a".repeat(markdev::html::MAX_SOURCE_BYTES + 1);
    assert!(render_fragment(&big, &ExportOptions::default()).is_err());
}

// ---------------------------------------------------------------------------
// Properties over generated documents.
// ---------------------------------------------------------------------------

const TOKENS: &[&str] = &[
    "#",
    "## ",
    "# ",
    "> ",
    ">",
    "- ",
    "1. ",
    "* ",
    "**",
    "*",
    "_",
    "__",
    "`",
    "```",
    "~~~",
    "~~",
    "==",
    "[",
    "]",
    "(",
    ")",
    "!",
    "<",
    ">",
    "&",
    "&amp;",
    "&#106;",
    "\"",
    "'",
    ":",
    "javascript:",
    "JAVASCRIPT:",
    "vbscript:",
    "data:text/html,",
    "https://x.y/p.png",
    "//evil/p.png",
    "file:///etc/passwd",
    "[[",
    "]]",
    "|",
    "^[",
    "^",
    "%%",
    "$",
    "$$",
    "\\(",
    "\\)",
    "\\[",
    "\\]",
    "\\",
    "\n",
    "\n\n",
    " ",
    "  ",
    "\t",
    "    ",
    "x",
    "word",
    "é",
    "😀",
    "\r\n",
    "\r",
    "---\n",
    "+++\n",
    "[!NOTE]",
    "[!warning]-",
    "<script>",
    "</script>",
    "onerror=",
    "onclick=\"",
    "<img src=x ",
    "<svg ",
    "| a | b |\n|-|-|\n",
    ": def",
    "[^1]",
    "[^1]: n",
    "[x]: javascript:y",
    "- [ ] ",
    "- [x] ",
    "- [/] ",
    "#tag",
    "\0",
    "\u{feff}",
    "\u{e000}",
    "\u{e002}",
];

fn document() -> impl Strategy<Value = String> {
    prop::collection::vec(prop::sample::select(TOKENS), 0..160).prop_map(|parts| parts.concat())
}

proptest! {
    #![proptest_config(ProptestConfig {
        cases: 3_000,
        failure_persistence: None,
        ..ProptestConfig::default()
    })]

    #[test]
    fn every_document_renders_safe_balanced_html(source in document(), remote in any::<bool>()) {
        let rendered = render_fragment(
            &source,
            &ExportOptions {
                file_access: FileAccess::None,
                remote_media: remote,
                ..Default::default()
            },
        )
        .expect("bounded input always renders");
        if let Err(breach) = audit(&rendered.html) {
            return Err(TestCaseError::fail(format!("{breach}\n{}", rendered.html)));
        }
        if let Err(breach) = audit_outline(&rendered) {
            return Err(TestCaseError::fail(breach));
        }
    }

    #[test]
    fn the_fragment_is_the_exported_body(source in document()) {
        // One pipeline: the fragment is exactly what the export puts in
        // <main>, so the two can never disagree about a document.
        let options = ExportOptions { file_access: FileAccess::None, ..Default::default() };
        let fragment = render_fragment(&source, &options).unwrap();
        let document = markdev::html::render_document_with_options(&source, "t", &options).unwrap();
        let body = document
            .split_once("<main>\n")
            .and_then(|(_, rest)| rest.rsplit_once("</main>"))
            .map(|(body, _)| body)
            .expect("document has a main element");
        prop_assert_eq!(body, fragment.html.as_str());
    }
}

#[test]
fn an_unconfined_render_without_an_asset_base_reads_nothing() {
    // No note folder means no relative path to read; nothing here should
    // reach the filesystem even though access is unrestricted.
    let rendered = render_fragment("![x](inside.png)", &ExportOptions::default()).unwrap();
    assert_eq!(embeds(&rendered.html), 0);
}

#[test]
fn the_embed_budget_bounds_what_one_render_copies_in() {
    let sandbox = Sandbox::new("budget");
    let vault = sandbox.vault();
    let docs = vault.join("docs");
    std::fs::write(docs.join("second.png"), PNG).unwrap();
    let source = "![a](inside.png) ![b](second.png)";
    let render = |budget: Option<usize>| {
        render_fragment(
            source,
            &ExportOptions {
                asset_base: Some(&docs),
                vault_root: Some(&vault),
                file_access: FileAccess::Vault,
                max_embedded_bytes: budget,
                ..Default::default()
            },
        )
        .unwrap()
        .html
    };
    assert_eq!(embeds(&render(None)), 2);
    // Room for one picture: the first is copied in, the second keeps its
    // relative destination rather than being dropped.
    let one = render(Some(PNG.len()));
    assert_eq!(embeds(&one), 1, "{one}");
    assert!(one.contains("src=\"second.png\""), "{one}");
    assert_eq!(embeds(&render(Some(0))), 0);
    // Asking for more than the export ceiling is clamped, not honoured.
    assert_eq!(embeds(&render(Some(usize::MAX))), 2);
}
