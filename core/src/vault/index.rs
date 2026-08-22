//! The vault: notes, the link graph between them, tags, and search.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use super::note::Note;
use super::search::SearchIndex;

/// A link pointing at a note, with the line it came from.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Backlink {
    /// Vault-relative path of the note containing the link.
    pub path: String,
    pub title: String,
    /// The line as written, for context in the panel.
    pub context: String,
    pub line: u32,
    /// Where in the source note the link sits, for jump-to-source.
    pub offset: u32,
}

/// A note that names this one without linking to it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct UnlinkedMention {
    pub path: String,
    pub title: String,
    pub context: String,
    pub line: u32,
    /// UTF-16 offset of the mention in its note, so it can be turned into a
    /// link — and jumped to, since the editor indexes by UTF-16.
    pub offset: u32,
}

/// A search hit.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SearchHit {
    pub path: String,
    pub title: String,
    pub context: String,
    pub line: u32,
    pub score: u32,
}

/// A tag and how many notes carry it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TagCount {
    pub tag: String,
    pub count: u32,
}

/// A link a note points *out* at, with where it lands.
///
/// The mirror of [`Backlink`], and it carries the resolution rather than
/// leaving the caller to ask again: "which notes is this one connected to"
/// is one question, and answering it in two calls invites a caller to pair
/// a link with a resolution made against a different index state.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OutgoingLink {
    /// The target as written, without the `#anchor` or `|alias`.
    pub target: String,
    /// Heading anchor, when the link was `[[Note#Heading]]`.
    pub anchor: Option<String>,
    /// What the reader sees — the alias when there is one.
    pub display: String,
    pub line: u32,
    /// UTF-16 offset of the link in this note.
    pub offset: u32,
    /// Vault-relative path of the note it resolves to, or `None` when the
    /// link is broken. A broken link is reported rather than dropped: a note
    /// linking at something that does not exist yet is ordinary in a vault,
    /// and a caller that wants only the live ones can filter.
    pub path: Option<String>,
}

/// A resolved link destination.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Resolution {
    pub path: String,
    /// UTF-16 offset of the anchored heading, when the link had one.
    pub offset: Option<u32>,
}

/// An indexed vault.
#[derive(Debug, Default)]
pub struct Vault {
    // `pub(crate)`: rename.rs is part of this vault's own machinery — moving
    // a note means touching its file, every link that resolved to it, and
    // then the index, which no public accessor sequence can express.
    pub(crate) root: PathBuf,
    pub(crate) notes: Vec<Note>,
    /// Vault-relative path to index in `notes`.
    pub(crate) by_path: HashMap<String, usize>,
    /// Lowercased name (stem, title, or alias) to the notes answering to it.
    by_name: HashMap<String, Vec<usize>>,
    /// Target note index to the links pointing at it.
    backlinks: HashMap<usize, Vec<(usize, usize)>>,
    search: SearchIndex,
}

impl Vault {
    /// Reads and indexes every Markdown file under `root`.
    pub fn open(root: impl AsRef<Path>) -> Vault {
        let root = root.as_ref().to_path_buf();
        let mut notes = Vec::new();
        collect(&root, &root, &mut notes);
        Vault::build(root, notes)
    }

    /// Builds a vault from notes already in memory. Used by tests, and by
    /// callers that have the text but not the files.
    pub fn build(root: PathBuf, notes: Vec<Note>) -> Vault {
        let mut vault = Vault {
            root,
            notes,
            ..Default::default()
        };
        vault.reindex();
        vault
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn notes(&self) -> &[Note] {
        &self.notes
    }

    pub fn note(&self, path: &str) -> Option<&Note> {
        self.by_path.get(path).map(|&index| &self.notes[index])
    }

    /// Replaces one note's content and rebuilds the derived indexes.
    ///
    /// The link graph is global — editing one note can create or break
    /// backlinks anywhere — so the graph is rebuilt rather than patched. At
    /// personal-vault scale that is microseconds, and it removes a whole
    /// class of stale-edge bugs.
    pub fn update(&mut self, path: &str, source: &str) {
        let note = Note::parse(path.to_string(), source);
        match self.by_path.get(path) {
            Some(&index) => self.notes[index] = note,
            None => self.notes.push(note),
        }
        self.reindex();
    }

    pub fn remove(&mut self, path: &str) {
        self.notes.retain(|note| note.path != path);
        self.reindex();
    }

    pub(crate) fn reindex(&mut self) {
        self.notes.sort_by(|a, b| a.path.cmp(&b.path));

        self.by_path = self
            .notes
            .iter()
            .enumerate()
            .map(|(index, note)| (note.path.clone(), index))
            .collect();

        self.by_name.clear();
        for (index, note) in self.notes.iter().enumerate() {
            for name in note.names() {
                self.by_name
                    .entry(name.to_lowercase())
                    .or_default()
                    .push(index);
            }
            // The relative path without its extension also resolves, so
            // `[[Projects/Roadmap]]` works alongside `[[Roadmap]]`.
            let without_extension = note
                .path
                .rsplit_once('.')
                .map(|(head, _)| head.to_string())
                .unwrap_or_else(|| note.path.clone());
            self.by_name
                .entry(without_extension.to_lowercase())
                .or_default()
                .push(index);
        }
        for targets in self.by_name.values_mut() {
            targets.sort_unstable();
            targets.dedup();
        }

        self.backlinks.clear();
        for (source_index, note) in self.notes.iter().enumerate() {
            for (link_index, link) in note.links.iter().enumerate() {
                if let Some(target) = self.lookup(&link.target) {
                    self.backlinks
                        .entry(target)
                        .or_default()
                        .push((source_index, link_index));
                }
            }
        }

        self.search = SearchIndex::build(&self.notes);
    }

    /// Index of the note a link target names.
    ///
    /// Ambiguity resolves to the shallowest path, then alphabetically — the
    /// same rule Obsidian uses, so a vault moved between the two behaves the
    /// same way. Returning "the first match found" instead would make link
    /// resolution depend on directory iteration order.
    pub(crate) fn lookup(&self, target: &str) -> Option<usize> {
        let key = target.trim().trim_start_matches("./").to_lowercase();
        if key.is_empty() {
            return None;
        }
        let candidates = self
            .by_name
            .get(&key)
            .or_else(|| self.by_name.get(&format!("{key}.md")))?;

        candidates.iter().copied().min_by_key(|&index| {
            let path = &self.notes[index].path;
            (path.matches('/').count(), path.clone())
        })
    }

    /// Resolves a `[[wikilink]]` target, with its heading anchor if any.
    pub fn resolve(&self, target: &str, anchor: Option<&str>) -> Option<Resolution> {
        let index = self.lookup(target)?;
        let note = &self.notes[index];
        let offset = anchor.and_then(|anchor| {
            note.headings
                .iter()
                .find(|heading| heading.text.eq_ignore_ascii_case(anchor.trim()))
                .map(|heading| heading.offset)
        });
        Some(Resolution {
            path: note.path.clone(),
            offset,
        })
    }

    /// The links `path` points out at, in the order they appear in the note.
    ///
    /// Duplicates are kept — a note may link the same target three times, and
    /// which occurrence a caller cares about is the caller's business.
    pub fn links(&self, path: &str) -> Vec<OutgoingLink> {
        let Some(&index) = self.by_path.get(path) else {
            return Vec::new();
        };
        self.notes[index]
            .links
            .iter()
            .map(|link| OutgoingLink {
                target: link.target.clone(),
                anchor: link.anchor.clone(),
                display: link.display.clone(),
                line: link.line,
                offset: link.offset,
                path: self
                    .lookup(&link.target)
                    .map(|target| self.notes[target].path.clone()),
            })
            .collect()
    }

    /// Links pointing at `path`, newest-path-first is not meaningful here so
    /// they come in vault order.
    pub fn backlinks(&self, path: &str) -> Vec<Backlink> {
        let Some(&target) = self.by_path.get(path) else {
            return Vec::new();
        };
        let Some(sources) = self.backlinks.get(&target) else {
            return Vec::new();
        };

        sources
            .iter()
            .map(|&(source_index, link_index)| {
                let source = &self.notes[source_index];
                let link = &source.links[link_index];
                Backlink {
                    path: source.path.clone(),
                    title: source.title.clone(),
                    context: line_text(&source.text, link.line),
                    line: link.line,
                    offset: link.offset,
                }
            })
            .collect()
    }

    /// Notes that mention this note's name in prose without linking to it.
    ///
    /// Only whole-word, case-insensitive matches count. Substring matching
    /// would report "Roadmap" inside "Roadmapping" and fill the panel with
    /// noise, which is how this feature usually gets turned off.
    pub fn unlinked_mentions(&self, path: &str) -> Vec<UnlinkedMention> {
        let Some(&target) = self.by_path.get(path) else {
            return Vec::new();
        };

        let linked: HashSet<usize> = self
            .backlinks
            .get(&target)
            .map(|sources| sources.iter().map(|&(index, _)| index).collect())
            .unwrap_or_default();

        let names = self.notes[target].names();
        let mut mentions = Vec::new();

        for (index, note) in self.notes.iter().enumerate() {
            if index == target || linked.contains(&index) {
                continue;
            }
            for name in &names {
                if let Some(offset) = find_whole_word(&note.text, name) {
                    let line = line_number(&note.text, offset);
                    mentions.push(UnlinkedMention {
                        path: note.path.clone(),
                        title: note.title.clone(),
                        context: line_text(&note.text, line),
                        line,
                        // The editor consumes UTF-16; the search runs in bytes.
                        offset: super::note::utf16_offset(&note.text, offset),
                    });
                    break;
                }
            }
        }

        mentions
    }

    /// Full-text search across the vault.
    pub fn search(&self, query: &str, limit: usize) -> Vec<SearchHit> {
        self.search.query(query, &self.notes, limit)
    }

    /// Every tag with the number of notes carrying it, most used first.
    pub fn tags(&self) -> Vec<TagCount> {
        let mut counts: BTreeMap<&str, u32> = BTreeMap::new();
        for note in &self.notes {
            for tag in &note.tags {
                *counts.entry(tag.as_str()).or_default() += 1;
            }
        }
        let mut tags: Vec<TagCount> = counts
            .into_iter()
            .map(|(tag, count)| TagCount {
                tag: tag.to_string(),
                count,
            })
            .collect();
        tags.sort_by(|a, b| b.count.cmp(&a.count).then_with(|| a.tag.cmp(&b.tag)));
        tags
    }

    /// Notes carrying `tag`.
    pub fn notes_with_tag(&self, tag: &str) -> Vec<String> {
        self.notes
            .iter()
            .filter(|note| note.tags.iter().any(|existing| existing == tag))
            .map(|note| note.path.clone())
            .collect()
    }

    /// Link targets that resolve to nothing, so broken links can be surfaced.
    pub fn broken_links(&self) -> Vec<(String, String)> {
        let mut broken = Vec::new();
        for note in &self.notes {
            for link in &note.links {
                if self.lookup(&link.target).is_none() {
                    broken.push((note.path.clone(), link.target.clone()));
                }
            }
        }
        broken
    }
}

/// Walks `directory`, reading every Markdown file into a note.
fn collect(root: &Path, directory: &Path, notes: &mut Vec<Note>) {
    let Ok(entries) = std::fs::read_dir(directory) else {
        // An unreadable directory contributes nothing rather than aborting
        // the whole index; permissions vary across a vault.
        return;
    };

    for entry in entries.flatten() {
        let path = entry.path();
        let name = entry.file_name().to_string_lossy().to_string();

        if name.starts_with('.') || IGNORED.contains(&name.as_str()) {
            continue;
        }

        if path.is_dir() {
            collect(root, &path, notes);
        } else if is_markdown(&path) {
            let Ok(text) = std::fs::read_to_string(&path) else {
                continue;
            };
            let relative = path
                .strip_prefix(root)
                .unwrap_or(&path)
                .to_string_lossy()
                .replace('\\', "/");
            notes.push(Note::parse(relative, &text));
        }
    }
}

const IGNORED: &[&str] = &["node_modules", "DerivedData", "target", ".build"];

fn is_markdown(path: &Path) -> bool {
    matches!(
        path.extension()
            .and_then(|extension| extension.to_str())
            .map(str::to_ascii_lowercase)
            .as_deref(),
        Some("md" | "markdown" | "mdown" | "mdx" | "mkd")
    )
}

/// The text of a 1-based line, trimmed for display.
fn line_text(text: &str, line: u32) -> String {
    text.lines()
        .nth(line.saturating_sub(1) as usize)
        .unwrap_or("")
        .trim()
        .to_string()
}

fn line_number(text: &str, byte: usize) -> u32 {
    text[..byte.min(text.len())]
        .bytes()
        .filter(|&b| b == b'\n')
        .count() as u32
        + 1
}

/// Byte offset of `needle` in `haystack` as a whole word, case-insensitively.
///
/// The search cannot simply run on a lowercased copy: folding can change
/// byte length ('İ' lowers to i plus a combining dot), which shifts every
/// offset after it onto the wrong character — and the offset is the one
/// thing this function exists to produce. It therefore lowercases once into
/// a parallel string that remembers, for each of its own bytes, the byte of
/// `haystack` it came from; matches are found in the copy and mapped back,
/// and word boundaries are checked on the original.
fn find_whole_word(haystack: &str, needle: &str) -> Option<usize> {
    if needle.is_empty() {
        return None;
    }
    let mut lowered = String::with_capacity(haystack.len());
    let mut origins: Vec<usize> = Vec::with_capacity(haystack.len() + 1);
    for (byte, ch) in haystack.char_indices() {
        for folded in ch.to_lowercase() {
            // One entry per *byte* of the folded character: the map is
            // indexed by `lowered`'s byte offsets, and a fold such as the
            // combining dot above occupies two.
            let mut encoded = [0u8; 4];
            for _ in folded.encode_utf8(&mut encoded).as_bytes() {
                origins.push(byte);
            }
            lowered.push(folded);
        }
    }
    origins.push(haystack.len());

    let lower_needle = needle.to_lowercase();
    let mut from = 0usize;
    while let Some(found) = lowered[from..].find(&lower_needle) {
        let start = from + found;
        let end = start + lower_needle.len();
        let orig_start = origins[start];
        let orig_end = origins[end];

        let before_ok = orig_start == 0
            || !haystack[..orig_start]
                .chars()
                .next_back()
                .is_some_and(|c| c.is_alphanumeric() || c == '_');
        let after_ok = orig_end >= haystack.len()
            || !haystack[orig_end..]
                .chars()
                .next()
                .is_some_and(|c| c.is_alphanumeric() || c == '_');

        if before_ok && after_ok {
            return Some(orig_start);
        }
        from = start + lower_needle.len().max(1);
        if from >= lowered.len() {
            break;
        }
    }
    None
}
