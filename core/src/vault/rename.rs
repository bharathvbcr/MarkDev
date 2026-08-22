//! Renaming and moving notes with the links that point at them.
//!
//! A rename that leaves every `[[Old Name]]` behind is how a link graph
//! rots: the links still *look* right, the panel calls them broken, and the
//! reader has no idea which of the two is lying. The rewrite here answers to
//! the vault's own resolution rules — a target is rewritten only when this
//! index resolves it to the note being moved, so same-stem notes elsewhere
//! keep their links.

use std::path::Path;

use super::index::Vault;
use super::note::stem;

/// The result of a successful rename.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct RenameOutcome {
    /// Notes whose text was rewritten (the moved note itself excluded).
    pub rewritten_notes: u32,
    /// Individual link occurrences rewritten across those notes.
    pub rewritten_links: u32,
}

impl Vault {
    /// Moves the note at `from` to `to`, rewriting every link that resolved
    /// to it, and re-indexes.
    ///
    /// The file is moved first; only then is the vault updated in memory. A
    /// failed move therefore leaves the index exactly as it was — reporting
    /// "renamed" while the file stayed put would be worse than refusing.
    ///
    /// Returns `None` when `from` is not a known note or the destination is
    /// taken, so callers can surface a real message instead of guessing.
    pub fn rename_note(&mut self, from: &str, to: &str) -> Option<RenameOutcome> {
        let source_index = *self.by_path.get(from)?;
        if self.by_path.contains_key(to) {
            return None;
        }
        let root = self.root.clone();
        let from_disk = root.join(from);
        let to_disk = root.join(to);

        if let Some(parent) = to_disk.parent() {
            if let Err(error) = std::fs::create_dir_all(parent) {
                eprintln!("markdev: could not create {}: {error}", parent.display());
                return None;
            }
        }
        if let Err(error) = move_file(&from_disk, &to_disk) {
            eprintln!("markdev: could not move {from} -> {to}: {error}");
            return None;
        }

        let old_stem = stem(from);
        let new_stem = stem(to);
        let new_path = without_extension(to);

        // When another note answers to the same stem the move will leave
        // behind, rewriting `[[Roadmap]]` to `[[Roadmap]]`'s twin would point
        // readers at whichever note resolution happens to prefer. Such links
        // are rewritten to the destination's full path instead — longer, but
        // unambiguous by construction.
        let stem_ambushed = self.notes.iter().enumerate().any(|(index, note)| {
            index != source_index && stem(&note.path).eq_ignore_ascii_case(&new_stem)
        });

        // Collected first against immutable state, applied after: the
        // rewrite consults `lookup`, which reads this very index, and a
        // mutation mid-scan would be the index answering questions about a
        // half-renamed world.
        let mut edits: Vec<(usize, String, u32)> = Vec::new();
        for (index, note) in self.notes.iter().enumerate() {
            if index == source_index {
                continue;
            }

            let mut resolve_wiki = |written: &str| -> Option<String> {
                if self.lookup(written) != Some(source_index) {
                    return None;
                }
                if written.eq_ignore_ascii_case(&old_stem) {
                    // Keep the reader's terse style unless ambiguity forbids.
                    (!stem_ambushed)
                        .then(|| new_stem.clone())
                        .or(Some(new_path.clone()))
                } else {
                    Some(new_path.clone())
                }
            };
            let mut resolve_markdown = |written: &str| -> Option<String> {
                if self.lookup(written) != Some(source_index) {
                    return None;
                }
                Some(new_path.clone())
            };

            let (text, links) =
                rewrite_links_in(&note.text, &mut resolve_wiki, &mut resolve_markdown);
            if links > 0 {
                edits.push((index, text, links as u32));
            }
        }

        let mut outcome = RenameOutcome {
            rewritten_notes: edits.len() as u32,
            rewritten_links: 0,
        };
        for (index, text, links) in edits {
            let path = root.join(&self.notes[index].path);
            if let Err(error) = std::fs::write(&path, &text) {
                eprintln!("markdev: could not rewrite {}: {error}", path.display());
                continue;
            }
            self.notes[index].text = text;
            outcome.rewritten_links += links;
        }

        self.notes[source_index].path = to.to_string();
        self.reindex();

        Some(outcome)
    }
}

/// `a/b/name.md` becomes `a/b/name`; a path with no extension is unchanged.
fn without_extension(path: &str) -> String {
    path.rsplit_once('.')
        .map(|(head, _)| head)
        .unwrap_or(path)
        .to_string()
}

/// Moves a file, falling back to copy-then-remove when `rename(2)` refuses —
/// vaults live on whatever volume the reader chose, and those do not always
/// agree about cross-device renames.
fn move_file(from: &Path, to: &Path) -> std::io::Result<()> {
    match std::fs::rename(from, to) {
        Ok(()) => Ok(()),
        Err(_) => {
            std::fs::copy(from, to)?;
            std::fs::remove_file(from)
        }
    }
}

/// Rewrites wikilink and Markdown-link targets in `source`.
///
/// Each closure is asked with the target exactly as written and answers:
/// `None` — leave it alone, or `Some(replacement)` — put this in its place.
/// Splitting "should change" from "change into what" is how the alias, the
/// anchor, and Markdown's `.md` suffix all survive without this function
/// knowing anything about either vault.
pub fn rewrite_links_in(
    source: &str,
    wiki: &mut dyn FnMut(&str) -> Option<String>,
    markdown: &mut dyn FnMut(&str) -> Option<String>,
) -> (String, usize) {
    let mut result = String::with_capacity(source.len());
    let mut rewritten = 0;
    let mut cursor = 0;

    while let Some(offset) = source[cursor..].find("[[") {
        let open = cursor + offset;

        match source[open..].find("]]") {
            Some(close_offset) => {
                let close = open + close_offset + 2;

                // An unclosed inner `[[` makes this outer one prose — but
                // its characters are still somebody's text. Keep them all
                // and resume one byte in, letting the scanner rediscover
                // whatever real token sits inside: `a [[b [[c]] d` must end
                // as `a [[b [[c]] d` with `[c]]` rewritten and every byte
                // of `b ` accounted for.
                if source[open + 2..close - 2].contains("[[") {
                    result.push_str(&source[cursor..=open]);
                    cursor = open + 1;
                    continue;
                }

                let token = &source[open + 2..close - 2];
                // Target is everything before `|` (alias) or `#` (anchor),
                // both of which survive a rename untouched.
                let cut = token.find(['|', '#']).unwrap_or(token.len());
                let (target, rest) = token.split_at(cut);

                if let Some(replacement) = wiki(target.trim()) {
                    result.push_str(&source[cursor..open + 2]);
                    result.push_str(&replacement);
                    result.push_str(rest);
                    result.push_str("]]");
                    rewritten += 1;
                } else {
                    // Left alone is still emitted: rejection decides *what
                    // happens to the link*, never whether its text exists.
                    result.push_str(&source[cursor..close]);
                }
                cursor = close;
            }
            None => {
                // No closing pair anywhere ahead: everything from here is
                // prose.
                break;
            }
        }
    }
    result.push_str(&source[cursor.min(source.len())..]);

    let (result, markdown_rewritten) = rewrite_markdown_targets(&result, markdown);
    rewritten += markdown_rewritten;

    (result, rewritten)
}

fn rewrite_markdown_targets(
    source: &str,
    markdown: &mut dyn FnMut(&str) -> Option<String>,
) -> (String, usize) {
    let mut result = String::with_capacity(source.len());
    let mut rewritten = 0;
    let mut cursor = 0;

    while let Some(open_offset) = source[cursor..].find("](") {
        let open = cursor + open_offset + 2;
        result.push_str(&source[cursor..open]);

        let Some(close_offset) = source[open..].find(')') else {
            break;
        };
        let close = open + close_offset;
        let raw = &source[open..close];
        let trimmed = raw.trim();

        // Anchors ride along, exactly as they do in wikilinks.
        let cut = trimmed.find('#').unwrap_or(trimmed.len());
        let (target, anchor) = trimmed.split_at(cut);
        let had_suffix = target.ends_with(".md");
        let candidate = if had_suffix {
            &target[..target.len() - 3]
        } else {
            target
        };

        if let Some(mut replacement) = markdown(candidate.trim()) {
            if had_suffix {
                replacement.push_str(".md");
            }
            result.push_str(&replacement);
            result.push_str(anchor);
            result.push(')');
            rewritten += 1;
        } else {
            result.push_str(raw);
            result.push(')');
        }
        cursor = close + 1;
    }
    result.push_str(&source[cursor.min(source.len())..]);

    (result, rewritten)
}
