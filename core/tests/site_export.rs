//! Whole-vault export as a linked static site.

use std::path::{Path, PathBuf};

use markdev::site::{export_site, SiteExportError};

struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Self {
        let path = std::env::temp_dir().join(format!(
            "markdev-site-{name}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&path).unwrap();
        Self(path)
    }

    fn write(&self, name: &str, bytes: &[u8]) {
        let path = self.0.join(name);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, bytes).unwrap();
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn read(path: &Path) -> String {
    std::fs::read_to_string(path).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

const PNG_1X1: &[u8] = &[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
    0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
    0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
    0x42, 0x60, 0x82,
];

#[test]
fn every_note_becomes_a_page_linked_to_the_others() {
    let vault = Scratch::new("vault");
    vault.write(".obsidian/app.json", b"{}");
    vault.write(
        "Home.md",
        b"# Home\n\nSee [[Roadmap]], [[Roadmap#Q3|Q3]] and [the log](Daily/Log.md).\n\n![[Roadmap#Q3]]\n\n![[pixel.png]]",
    );
    vault.write(
        "Projects/Roadmap.md",
        b"# Roadmap\n\n## Q3\n\nShip ==it==.\n",
    );
    vault.write("Daily/Log.md", b"Back to [[Home]].");
    vault.write("attachments/pixel.png", PNG_1X1);
    vault.write(".trash/Old.md", b"hidden");
    let out = vault.0.join("_site");

    let report = export_site(&vault.0, &out).unwrap();
    assert_eq!(report.pages, 3, "{report:?}");
    assert!(report.skipped.is_empty());
    assert!(!report.truncated);

    let home = read(&out.join("Home.html"));
    assert!(
        home.contains("href=\"Projects/Roadmap.html\""),
        "wikilink to page"
    );
    assert!(home.contains("href=\"Projects/Roadmap.html#q3\""));
    assert!(
        home.contains("href=\"Daily/Log.html\""),
        "markdown link to page"
    );
    assert!(
        home.contains("<mark>it</mark>"),
        "embedded section is transcluded"
    );
    assert!(home.contains("src=\"data:image/png;base64,"));

    let log = read(&out.join("Daily/Log.html"));
    assert!(log.contains("href=\"../Home.html\""));

    let index = read(&report.index);
    assert!(index.contains("href=\"Home.html\""));
    assert!(index.contains("href=\"Projects/Roadmap.html\""));
    assert!(index.contains("<h2 id=\"projects\">Projects"));
    assert!(!out.join(".trash").exists());
    assert!(
        !out.join("_site").exists(),
        "the site does not export itself"
    );
}

#[test]
fn the_site_cannot_overwrite_the_vault() {
    let vault = Scratch::new("self");
    vault.write("Note.md", b"x");
    assert_eq!(
        export_site(&vault.0, &vault.0),
        Err(SiteExportError::OutputIsVault)
    );
}

#[test]
fn a_second_export_replaces_pages_in_place() {
    let vault = Scratch::new("again");
    vault.write("Note.md", b"First");
    let out = vault.0.join("site");
    export_site(&vault.0, &out).unwrap();
    vault.write("Note.md", b"Second");
    let report = export_site(&vault.0, &out).unwrap();
    assert_eq!(report.pages, 1);
    let page = read(&out.join("Note.html"));
    assert!(page.contains("Second") && !page.contains("First"));
    let leftovers = std::fs::read_dir(&out)
        .unwrap()
        .flatten()
        .filter(|e| e.file_name().to_string_lossy().ends_with(".tmp"))
        .count();
    assert_eq!(leftovers, 0);
}
