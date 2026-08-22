//! Renaming and moving notes with the links that point at them.
//!
//! A rename that leaves every `[[Old Name]]` behind is how a link graph
//! rots: the links still *look* right, the panel calls them broken, and the
//! reader has no idea which of the two is lying. The rewrite here answers to
//! the vault's own resolution rules — a target is rewritten only when this
//! index resolves it to the note being moved, so same-stem notes elsewhere
//! keep their links.

use std::io::Write;
use std::ops::Range;
use std::path::Path;

use super::index::Vault;
use super::note::stem;
use crate::md::model::{BlockKind, SpanKind, Utf16Mapper};
use crate::md::parse;

/// Byte ranges of a document holding code or machine-read text, not prose.
///
/// A rename rewrites *links* — and only links. Fenced code blocks, indented
/// code, inline code spans, math and Mermaid sources, and frontmatter all
/// contain text that merely looks like `[x](Note.md)` or `[[Note]]`; it is
/// sample content the reader marked as literal, and editing it is silent
/// data corruption. Ranges come from the canonical parse rather than a
/// second fence scanner, so what this protects is exactly what the editor
/// renders as code — one owner per behaviour.
#[derive(Debug, Clone, Default)]
pub struct ProtectedRanges(Vec<Range<usize>>);

impl ProtectedRanges {
    /// Protects nothing — for callers rewriting structure-free text.
    pub fn none() -> Self {
        Self(Vec::new())
    }

    /// Derives protection from the same parse the editor uses.
    ///
    /// The parser reports UTF-16 offsets; the scanner works in bytes, so
    /// every range crosses `Utf16Mapper` on the way in.
    pub fn for_document(source: &str) -> Self {
        let parsed = parse(source);
        let mapper = Utf16Mapper::new(source);
        let mut ranges: Vec<Range<usize>> = Vec::new();

        for block in &parsed.blocks {
            let protected = block.kind == BlockKind::CodeBlock as u16
                || block.kind == BlockKind::MermaidBlock as u16
                || block.kind == BlockKind::MathBlock as u16
                || block.kind == BlockKind::Frontmatter as u16;
            if protected && block.end > block.start {
                ranges.push(mapper.to_byte(block.start)..mapper.to_byte(block.end));
            }
        }
        for span in &parsed.spans {
            if span.kind == SpanKind::InlineCode as u16 && span.end > span.start {
                ranges.push(mapper.to_byte(span.start)..mapper.to_byte(span.end));
            }
        }

        // The parse yields document-order, mostly disjoint ranges; sort and
        // merge so `is_protected` can binary-search. Overlap between an
        // inline span and its enclosing block would otherwise be harmless,
        // but merging keeps the invariant explicit.
        ranges.sort_by_key(|range| range.start);
        let mut merged: Vec<Range<usize>> = Vec::with_capacity(ranges.len());
        for range in ranges {
            match merged.last_mut() {
                Some(last) if range.start <= last.end => last.end = last.end.max(range.end),
                _ => merged.push(range),
            }
        }
        Self(merged)
    }

    /// Whether `position` falls inside any protected region.
    ///
    /// A token starting exactly at a region's end is *not* protected: the
    /// boundary belongs to the live document.
    fn covers(&self, position: usize) -> bool {
        let index = self.0.partition_point(|range| range.end <= position);
        self.0
            .get(index)
            .is_some_and(|range| range.start <= position)
    }
}

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

        // The index cannot referee this: it stores exact-case paths, and the
        // filesystem may be case-insensitive — asking it to move
        // `Notes/A.md` onto indexed `Work/a.md` by renaming to `Work/A.md`
        // would overwrite a note the index still believes exists. The
        // *filesystem* is the authority on whether anything is already there.
        // A case-only rename of the file onto itself (`A.md` → `a.md`) is
        // allowed through: same directory entry, nothing to lose.
        if std::fs::symlink_metadata(&to_disk).is_ok() {
            let same_file = std::fs::canonicalize(&from_disk)
                .ok()
                .zip(std::fs::canonicalize(&to_disk).ok())
                .is_some_and(|(a, b)| a == b);
            if !same_file {
                return None;
            }
        }

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

            let (text, links) = {
                // One parse per candidate note: a rename is a user-visible
                // action measured in clicks, not per keystroke, and the
                // protection must describe this exact text.
                let protected = ProtectedRanges::for_document(&note.text);
                rewrite_links_in(
                    &note.text,
                    &protected,
                    &mut resolve_wiki,
                    &mut resolve_markdown,
                )
            };
            if links > 0 {
                edits.push((index, text, links as u32));
            }
        }

        let mut outcome = RenameOutcome {
            rewritten_notes: 0,
            rewritten_links: 0,
        };
        for (index, text, links) in edits {
            let path = root.join(&self.notes[index].path);
            // Atomic replace, matching what the app's own saves do: a crash
            // mid-write must leave the old note, never a truncated one.
            if let Err(error) = write_atomically(&path, &text) {
                eprintln!("markdev: could not rewrite {}: {error}", path.display());
                continue;
            }
            self.notes[index].text = text;
            outcome.rewritten_notes += 1;
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

/// Writes `text` to `path` via a sibling temporary file and a rename, so an
/// interrupted write leaves the original untouched rather than a truncated
/// note. The temp file shares the destination's directory so the final
/// rename stays within one filesystem.
fn write_atomically(path: &Path, text: &str) -> std::io::Result<()> {
    let file_name = path
        .file_name()
        .map(|name| name.to_string_lossy().to_string())
        .unwrap_or_else(|| "note.md".to_string());
    let temp = path.with_file_name(format!(".{file_name}.markdev-tmp"));
    // Sync before the rename: `rename(2)` is atomic against *visibility*,
    // not against power loss — without the flush a crash can leave the new
    // name over an empty or partial file, which is precisely what this
    // dance exists to prevent.
    let mut file = std::fs::File::create(&temp)?;
    file.write_all(text.as_bytes())?;
    file.sync_all()?;
    drop(file);
    match std::fs::rename(&temp, path) {
        Ok(()) => Ok(()),
        Err(error) => {
            let _ = std::fs::remove_file(&temp);
            Err(error)
        }
    }
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
    protected: &ProtectedRanges,
    wiki: &mut dyn FnMut(&str) -> Option<String>,
    markdown: &mut dyn FnMut(&str) -> Option<String>,
) -> (String, usize) {
    let mut result = String::with_capacity(source.len());
    let mut rewritten = 0;
    let mut cursor = 0;

    while let Some(offset) = source[cursor..].find("[[") {
        let open = cursor + offset;

        // Code first, before anything about the token is decided: a `[[`
        // inside a fence is sample text, and scanning into it at all risks
        // the scanner's opinion outranking the reader's.
        if protected.covers(open) {
            // Emit up to the marker verbatim and step past it; the next
            // iteration resumes the search *after* this opener, so a fence
            // full of brackets costs one skip each rather than a rescan.
            result.push_str(&source[cursor..open + 2]);
            cursor = open + 2;
            continue;
        }

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

    // The markdown pass scans the *rewritten* text, whose offsets moved
    // wherever a wikilink was replaced with a path of a different length.
    // Protection therefore comes from a fresh parse of exactly what this
    // pass is about to scan — the parse of the original describes a string
    // nobody is holding any more. Replacements are note paths and stems,
    // so they cannot themselves introduce fences or math; the fresh parse
    // sees the same code regions at their new positions.
    let markdown_protected = ProtectedRanges::for_document(&result);
    let (result, markdown_rewritten) =
        rewrite_markdown_targets(&result, &markdown_protected, markdown);
    rewritten += markdown_rewritten;

    (result, rewritten)
}

fn rewrite_markdown_targets(
    source: &str,
    protected: &ProtectedRanges,
    markdown: &mut dyn FnMut(&str) -> Option<String>,
) -> (String, usize) {
    let mut result = String::with_capacity(source.len());
    let mut rewritten = 0;
    let mut cursor = 0;

    while let Some(open_offset) = source[cursor..].find("](") {
        let open = cursor + open_offset + 2;

        // Same rule as the wiki scanner: inside code, `](Note.md)` is
        // sample text. Emit through the paren and move past it.
        if protected.covers(open) {
            result.push_str(&source[cursor..open]);
            cursor = open;
            continue;
        }

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
