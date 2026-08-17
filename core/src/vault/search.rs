//! Full-text search over the vault.
//!
//! A hand-rolled inverted index rather than a search-engine dependency. A
//! personal vault is thousands of notes, not millions of documents; at that
//! scale this is instant, and it keeps the crate free of a large dependency
//! whose features would go unused.

use std::collections::{HashMap, HashSet};

use super::index::SearchHit;
use super::note::Note;

/// Token to the notes containing it.
#[derive(Debug, Default)]
pub struct SearchIndex {
    postings: HashMap<String, HashSet<usize>>,
}

impl SearchIndex {
    pub fn build(notes: &[Note]) -> SearchIndex {
        let mut postings: HashMap<String, HashSet<usize>> = HashMap::new();
        for (index, note) in notes.iter().enumerate() {
            for token in tokenize(&note.text) {
                postings.entry(token).or_default().insert(index);
            }
            // Titles are indexed separately so a note is findable by name
            // even when the name never appears in its body.
            for token in tokenize(&note.title) {
                postings.entry(token).or_default().insert(index);
            }
        }
        SearchIndex { postings }
    }

    /// Notes matching every token in `query`, best first.
    ///
    /// Terms are ANDed: searching `rust parser` should mean notes about a
    /// Rust parser, not every note mentioning either word. The last token is
    /// matched as a prefix so results narrow while still being typed.
    pub fn query(&self, query: &str, notes: &[Note], limit: usize) -> Vec<SearchHit> {
        let tokens = tokenize(query);
        if tokens.is_empty() {
            return Vec::new();
        }

        let mut candidates: Option<HashSet<usize>> = None;
        for (position, token) in tokens.iter().enumerate() {
            let is_last = position == tokens.len() - 1;
            let matches = if is_last {
                self.prefix_matches(token)
            } else {
                self.postings.get(token).cloned().unwrap_or_default()
            };

            candidates = Some(match candidates {
                None => matches,
                Some(existing) => existing.intersection(&matches).copied().collect(),
            });

            if candidates.as_ref().is_some_and(HashSet::is_empty) {
                return Vec::new();
            }
        }

        let mut hits: Vec<SearchHit> = candidates
            .unwrap_or_default()
            .into_iter()
            .filter_map(|index| {
                let note = notes.get(index)?;
                let (line, context) = snippet(&note.text, &tokens)?;
                let mut score = 0u32;
                // A title match is a much stronger signal than a body match.
                let title = note.title.to_lowercase();
                for token in &tokens {
                    if title.contains(token.as_str()) {
                        score += 40;
                    }
                    score += note
                        .text
                        .to_lowercase()
                        .matches(token.as_str())
                        .count()
                        .min(20) as u32;
                }
                Some(SearchHit {
                    path: note.path.clone(),
                    title: note.title.clone(),
                    context,
                    line,
                    score,
                })
            })
            .collect();

        hits.sort_by(|a, b| b.score.cmp(&a.score).then_with(|| a.path.cmp(&b.path)));
        hits.truncate(limit);
        hits
    }

    fn prefix_matches(&self, prefix: &str) -> HashSet<usize> {
        // Exact hits are the common case and avoid scanning the vocabulary.
        if let Some(exact) = self.postings.get(prefix) {
            if prefix.len() > 3 {
                return exact.clone();
            }
        }
        let mut matches = HashSet::new();
        for (token, notes) in &self.postings {
            if token.starts_with(prefix) {
                matches.extend(notes.iter().copied());
            }
        }
        matches
    }
}

/// Splits text into lowercase alphanumeric tokens.
fn tokenize(text: &str) -> Vec<String> {
    text.split(|c: char| !c.is_alphanumeric() && c != '_' && c != '-')
        .filter(|token| !token.is_empty())
        .map(|token| token.to_lowercase())
        .collect()
}

/// The first line containing any of `tokens`, with its 1-based line number.
fn snippet(text: &str, tokens: &[String]) -> Option<(u32, String)> {
    for (index, line) in text.lines().enumerate() {
        let lower = line.to_lowercase();
        if tokens.iter().any(|token| lower.contains(token.as_str())) {
            let trimmed = line.trim();
            let context = if trimmed.chars().count() > 160 {
                trimmed.chars().take(160).collect::<String>() + "…"
            } else {
                trimmed.to_string()
            };
            return Some((index as u32 + 1, context));
        }
    }
    // A title-only match still deserves a result, just without a body line.
    Some((1, text.lines().next().unwrap_or("").trim().to_string()))
}
