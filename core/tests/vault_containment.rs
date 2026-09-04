//! Filesystem-containment contracts for vault discovery.

use markdev::vault::{Note, Vault, VaultScanLimits};

fn sandbox(label: &str) -> std::path::PathBuf {
    std::env::temp_dir().join(format!(
        "markdev-vault-{label}-{}-{}",
        std::process::id(),
        line!()
    ))
}

#[cfg(unix)]
#[test]
fn scan_never_indexes_a_markdown_tree_outside_the_vault_through_a_symlink() {
    use std::os::unix::fs::symlink;

    let sandbox = sandbox("outside-link");
    let root = sandbox.join("vault");
    let outside = sandbox.join("outside");
    let _ = std::fs::remove_dir_all(&sandbox);
    std::fs::create_dir_all(&root).unwrap();
    std::fs::create_dir_all(&outside).unwrap();
    std::fs::write(root.join("Inside.md"), "# Inside").unwrap();
    std::fs::write(outside.join("Secret.md"), "# Secret").unwrap();
    symlink(&outside, root.join("linked-outside")).unwrap();

    let vault = Vault::open(&root);
    let paths: Vec<_> = vault
        .notes()
        .iter()
        .map(|note| note.path.as_str())
        .collect();
    let _ = std::fs::remove_dir_all(&sandbox);

    assert_eq!(paths, ["Inside.md"]);
}

#[cfg(unix)]
#[test]
fn scan_does_not_follow_self_parent_or_chained_directory_symlinks() {
    use std::os::unix::fs::symlink;

    let sandbox = sandbox("loops");
    let root = sandbox.join("vault");
    let real = root.join("real");
    let _ = std::fs::remove_dir_all(&sandbox);
    std::fs::create_dir_all(&real).unwrap();
    std::fs::write(real.join("One.md"), "# One").unwrap();
    symlink(&root, root.join("self")).unwrap();
    symlink(&sandbox, root.join("parent")).unwrap();
    symlink("chain-b", root.join("chain-a")).unwrap();
    symlink("real", root.join("chain-b")).unwrap();

    let vault = Vault::open(&root);
    let paths: Vec<_> = vault
        .notes()
        .iter()
        .map(|note| note.path.as_str())
        .collect();
    let _ = std::fs::remove_dir_all(&sandbox);

    assert_eq!(paths, ["real/One.md"]);
}

#[test]
fn scan_depth_limit_is_bounded_and_explicitly_incomplete() {
    let sandbox = sandbox("depth-bound");
    let root = sandbox.join("vault");
    let nested = root.join("one/two/three");
    let _ = std::fs::remove_dir_all(&sandbox);
    std::fs::create_dir_all(&nested).unwrap();
    std::fs::write(root.join("Top.md"), "# Top").unwrap();
    std::fs::write(root.join("one/One.md"), "# One").unwrap();
    std::fs::write(root.join("one/two/Two.md"), "# Two").unwrap();
    std::fs::write(nested.join("TooDeep.md"), "# Too deep").unwrap();

    let vault = Vault::open_with_limits(
        &root,
        VaultScanLimits {
            max_depth: 1,
            max_entries: 100,
            max_note_bytes: 1_048_576,
            max_total_bytes: 8 * 1_048_576,
        },
    );
    let paths: Vec<_> = vault
        .notes()
        .iter()
        .map(|note| note.path.as_str())
        .collect();
    let status = vault.scan_status();
    let _ = std::fs::remove_dir_all(&sandbox);

    assert_eq!(paths, ["Top.md", "one/One.md"]);
    assert!(status.hit_depth_limit);
    assert!(!status.is_complete());
}

#[test]
fn scan_huge_fanout_stops_at_the_entry_limit_and_reports_the_cap() {
    let sandbox = sandbox("fanout-bound");
    let root = sandbox.join("vault");
    let _ = std::fs::remove_dir_all(&sandbox);
    std::fs::create_dir_all(&root).unwrap();
    for index in 0..512 {
        std::fs::write(root.join(format!("Note-{index:04}.md")), "# note").unwrap();
    }

    let vault = Vault::open_with_limits(
        &root,
        VaultScanLimits {
            max_depth: 48,
            max_entries: 64,
            max_note_bytes: 1_048_576,
            max_total_bytes: 8 * 1_048_576,
        },
    );
    let status = vault.scan_status();
    let note_count = vault.notes().len();
    let _ = std::fs::remove_dir_all(&sandbox);

    assert_eq!(status.visited_entries, 64);
    assert!(note_count <= 64);
    assert!(status.hit_entry_limit);
    assert!(!status.is_complete());
}

#[test]
fn an_in_memory_build_never_claims_a_filesystem_scan_was_complete() {
    let vault = Vault::build(
        std::path::PathBuf::from("/not-scanned"),
        vec![Note::parse("Memory.md".to_string(), "# Memory")],
    );

    assert!(!vault.scan_status().scan_performed);
    assert!(!vault.scan_status().is_complete());
}

#[test]
fn scan_skips_an_oversized_note_and_reports_incomplete_coverage() {
    let sandbox = sandbox("oversized-note");
    let root = sandbox.join("vault");
    let _ = std::fs::remove_dir_all(&sandbox);
    std::fs::create_dir_all(&root).unwrap();
    std::fs::write(root.join("Small.md"), "# Small").unwrap();
    let oversized = std::fs::File::create(root.join("Huge.md")).unwrap();
    oversized.set_len(32 * 1024 * 1024).unwrap();

    let vault = Vault::open_with_limits(
        &root,
        VaultScanLimits {
            max_depth: 48,
            max_entries: 100,
            max_note_bytes: 1_048_576,
            max_total_bytes: 8 * 1_048_576,
        },
    );
    let status = vault.scan_status();
    let _ = std::fs::remove_dir_all(&sandbox);

    assert!(vault.note("Small.md").is_some());
    assert!(vault.note("Huge.md").is_none());
    assert_eq!(status.oversized_files, 1);
    assert!(!status.is_complete());
}

#[test]
fn scan_total_byte_budget_reports_discovered_selected_indexed_and_skipped() {
    let sandbox = sandbox("total-byte-bound");
    let root = sandbox.join("vault");
    let _ = std::fs::remove_dir_all(&sandbox);
    std::fs::create_dir_all(&root).unwrap();
    for name in ["A.md", "B.md", "C.md"] {
        std::fs::write(root.join(name), "12345678").unwrap();
    }

    let vault = Vault::open_with_limits(
        &root,
        VaultScanLimits {
            max_depth: 48,
            max_entries: 100,
            max_note_bytes: 1_024,
            max_total_bytes: 10,
        },
    );
    let status = vault.scan_status();
    let _ = std::fs::remove_dir_all(&sandbox);

    assert_eq!(status.discovered_files, 3);
    assert_eq!(status.discovered_bytes, 24);
    assert_eq!(status.selected_files, 1);
    assert_eq!(status.selected_bytes, 8);
    assert_eq!(status.indexed_files, 1);
    assert_eq!(status.indexed_bytes, 8);
    assert_eq!(status.skipped_files, 2);
    assert!(status.hit_total_byte_limit);
    assert!(!status.is_complete());
}
