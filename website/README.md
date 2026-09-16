# MarkDev product website

A standalone static product site: `index.html`, `styles.css`, and `site.js`.
It is separate from MarkDev.app and requires no framework, package install,
external fonts, analytics, or build step.

## Preview and verify

From the repository root:

```sh
just website
```

Open [the local preview](http://127.0.0.1:8000). Stop the server with Control-C.
The server binds only to loopback and serves only `website/`. If port 8000 is
busy, supply another port, or use `just website 0` and open the available address
printed by the server.

```sh
just check-docs
```

This runs the Python static site checker and existing Rust documentation
contracts. The site checker also runs through `just check` and `just ci-core`. The checker validates local assets, fragments, semantic landmarks,
unique IDs, and repository documentation destinations. It does not contact
GitHub or claim browser validation.

For browser review, inspect desktop and narrow/mobile widths; ensure no
horizontal page overflow, switch the Preview/Source example with pointer and
keyboard, follow the page navigation, and repeat with JavaScript disabled and
reduced motion enabled. The site remains readable without JavaScript.

## Page content

The product page includes a workspace illustration, feature overview, detailed
writing and vault sections, workspace tools and shortcuts, optional assistance,
first-use steps, documentation links, FAQ, and release information. The page
index links directly to the longer sections.

Technical-note source and FAQ answers use native `details`/`summary` disclosures;
they work with keyboard input and without JavaScript. Examples are illustrative
content, not screenshots or live application state. When editing them, keep
source examples consistent with their presented content.

## App theme

The site follows MarkDev's default Standard font preset and System appearance.
CSS tokens adapt the system typography and semantic colors from
[`EditorTheme.swift`](../app/MarkDevKit/Editor/EditorTheme.swift), using opaque
writing surfaces and adaptive light/dark colors. Radius values (8/12/18) and
motion durations (220/340 ms) come from
[`GlassTheme.swift`](../app/MarkDevKit/Design/GlassTheme.swift). Browser colors
and easing approximate the native semantic colors and springs; they do not
read a visitor's macOS accent or app preferences. The chevron uses the navy and
turquoise palette of `MarkDevLogo.swift`.

Glass is confined to navigation chrome. Reduced motion, increased contrast,
and reduced transparency preferences have CSS fallbacks. Review both system
color schemes when changing the website.

## Content ownership

The workspace is explicitly labeled an illustration, not an application
screenshot. Its Preview/Source buttons switch one curated note example, not a
browser implementation of the native editor. The decorative sidebar, outline,
and terminal do not impersonate working app controls.

The guide links point to canonical Markdown files on GitHub, avoiding a second
copy of the documentation. New guide destinations become publicly available
when the corresponding repository changes are published. Review link targets
against the final branch before publishing this site.

When a release is published, update the download note alongside the root README
and `docs/releases/README.md`. Confirm the artifact's CPU requirements and
signing status. Do not describe a source version as a downloadable release.

The brand is a text wordmark with a typographic chevron, not a replacement app
icon. Native app/document icon geometry remains owned by `MarkDevLogo.swift`.

## Publishing

No hosting provider or production domain is configured. Deploy the contents of
`website/` to an authorized static host; preserve relative asset paths so both
root and subdirectory hosting work. Publish the linked documentation first.
Once a real URL is selected, add its canonical/Open Graph URL metadata and
verify live assets, links, HTTPS, and mobile layout. Local preview does not
establish a deployed website.
