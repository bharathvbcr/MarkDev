//! Syntax highlighting for fenced code blocks.
//!
//! Real tree-sitter grammars rather than a regex tokenizer. Raw strings,
//! nested template literals, and regex-vs-division ambiguity are exactly the
//! cases a pattern-based highlighter gets wrong, and they show up constantly
//! in the code people paste into notes.
//!
//! Offsets are UTF-16 and relative to the code block's own text, matching the
//! rest of the FFI so Swift never converts anything.

use std::collections::HashMap;
use std::sync::OnceLock;

use serde::{Deserialize, Serialize};
use tree_sitter_highlight::{HighlightConfiguration, HighlightEvent, Highlighter};

/// A highlighted token class.
///
/// Deliberately small: a palette with forty distinct colours is noise. These
/// are the distinctions a reader actually uses to scan code.
///
/// Discriminants are part of the FFI contract — append, never renumber.
#[repr(u16)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum HighlightKind {
    Keyword = 0,
    String = 1,
    Number = 2,
    Comment = 3,
    Function = 4,
    Type = 5,
    Constant = 6,
    Variable = 7,
    Operator = 8,
    Punctuation = 9,
    Attribute = 10,
}

/// A highlighted range within a code block.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct HighlightSpan {
    /// UTF-16 offset from the start of the code, not the document.
    pub start: u32,
    pub end: u32,
    pub kind: u16,
    pub _padding: u16,
}

/// Capture names requested from each grammar, in priority order.
///
/// tree-sitter resolves a capture to the *first* matching entry, so more
/// specific names must come before their prefixes — `function.builtin` before
/// `function`, or every builtin would resolve as a plain function.
const CAPTURES: &[(&str, HighlightKind)] = &[
    ("attribute", HighlightKind::Attribute),
    ("comment.documentation", HighlightKind::Comment),
    ("comment", HighlightKind::Comment),
    ("constant.builtin", HighlightKind::Constant),
    ("constant", HighlightKind::Constant),
    ("constructor", HighlightKind::Type),
    ("escape", HighlightKind::String),
    ("function.builtin", HighlightKind::Function),
    ("function.method", HighlightKind::Function),
    ("function", HighlightKind::Function),
    ("keyword", HighlightKind::Keyword),
    ("label", HighlightKind::Constant),
    ("number", HighlightKind::Number),
    ("operator", HighlightKind::Operator),
    ("property", HighlightKind::Variable),
    ("punctuation.bracket", HighlightKind::Punctuation),
    ("punctuation.delimiter", HighlightKind::Punctuation),
    ("punctuation.special", HighlightKind::Punctuation),
    ("string.special", HighlightKind::String),
    ("string", HighlightKind::String),
    ("tag", HighlightKind::Type),
    ("type.builtin", HighlightKind::Type),
    ("type", HighlightKind::Type),
    ("variable.builtin", HighlightKind::Constant),
    ("variable.parameter", HighlightKind::Variable),
    ("variable", HighlightKind::Variable),
];

fn capture_names() -> Vec<String> {
    CAPTURES.iter().map(|(name, _)| name.to_string()).collect()
}

/// Builds the per-language configurations once.
///
/// Grammar loading parses a query file, which is slow enough that doing it
/// per code block would be visible while scrolling a document full of code.
fn configurations() -> &'static HashMap<&'static str, HighlightConfiguration> {
    static CONFIGS: OnceLock<HashMap<&'static str, HighlightConfiguration>> = OnceLock::new();
    CONFIGS.get_or_init(|| {
        let names = capture_names();
        let mut map = HashMap::new();

        let mut add = |keys: &[&'static str],
                       language: tree_sitter::Language,
                       highlights: &str,
                       injections: &str,
                       locals: &str| {
            // Configurations are neither cloneable nor shareable, so each
            // alias builds its own from a fresh clone of the language.
            for key in keys {
                let Ok(mut config) = HighlightConfiguration::new(
                    language.clone(),
                    *key,
                    highlights,
                    injections,
                    locals,
                ) else {
                    // A grammar that fails to configure simply offers no
                    // highlighting; the block still renders as plain text.
                    continue;
                };
                config.configure(&names);
                map.insert(*key, config);
            }
        };

        add(
            &["rust", "rs"],
            tree_sitter_rust::LANGUAGE.into(),
            tree_sitter_rust::HIGHLIGHTS_QUERY,
            tree_sitter_rust::INJECTIONS_QUERY,
            "",
        );
        add(
            &["swift"],
            tree_sitter_swift::LANGUAGE.into(),
            tree_sitter_swift::HIGHLIGHTS_QUERY,
            "",
            tree_sitter_swift::LOCALS_QUERY,
        );
        add(
            &["javascript", "js", "jsx", "typescript", "ts", "tsx"],
            tree_sitter_javascript::LANGUAGE.into(),
            tree_sitter_javascript::HIGHLIGHT_QUERY,
            tree_sitter_javascript::INJECTIONS_QUERY,
            tree_sitter_javascript::LOCALS_QUERY,
        );
        add(
            &["python", "py"],
            tree_sitter_python::LANGUAGE.into(),
            tree_sitter_python::HIGHLIGHTS_QUERY,
            "",
            "",
        );
        add(
            &["json", "jsonc"],
            tree_sitter_json::LANGUAGE.into(),
            tree_sitter_json::HIGHLIGHTS_QUERY,
            "",
            "",
        );
        add(
            &["bash", "sh", "shell", "zsh"],
            tree_sitter_bash::LANGUAGE.into(),
            tree_sitter_bash::HIGHLIGHT_QUERY,
            "",
            "",
        );

        map
    })
}

/// Whether a language has a grammar available.
pub fn supports(language: &str) -> bool {
    configurations().contains_key(language.trim().to_lowercase().as_str())
}

/// Languages MarkDev can highlight, for diagnostics and tests.
pub fn languages() -> Vec<&'static str> {
    let mut names: Vec<&'static str> = configurations().keys().copied().collect();
    names.sort_unstable();
    names
}

/// Highlights `code`, returning UTF-16 ranges relative to it.
///
/// Returns empty for an unknown language or a grammar error — code without
/// highlighting reads fine, so failing soft is right here.
pub fn highlight(language: &str, code: &str) -> Vec<HighlightSpan> {
    let key = language.trim().to_lowercase();
    let Some(config) = configurations().get(key.as_str()) else {
        return Vec::new();
    };

    let mut highlighter = Highlighter::new();
    let Ok(events) = highlighter.highlight(config, code.as_bytes(), None, |_| None) else {
        return Vec::new();
    };

    let mapper = ByteToUtf16::new(code);
    let mut spans: Vec<HighlightSpan> = Vec::new();
    // tree-sitter nests highlights; the innermost is the one that should win,
    // so the stack's top is applied to any source between events.
    let mut stack: Vec<HighlightKind> = Vec::new();

    for event in events.flatten() {
        match event {
            HighlightEvent::HighlightStart(highlight) => {
                if let Some((_, kind)) = CAPTURES.get(highlight.0) {
                    stack.push(*kind);
                }
            }
            HighlightEvent::HighlightEnd => {
                stack.pop();
            }
            HighlightEvent::Source { start, end } => {
                let Some(kind) = stack.last().copied() else {
                    continue;
                };
                if start >= end {
                    continue;
                }
                let span = HighlightSpan {
                    start: mapper.to_utf16(start),
                    end: mapper.to_utf16(end),
                    kind: kind as u16,
                    _padding: 0,
                };
                // Adjacent runs of the same kind merge, which keeps the
                // attribute count down on long code blocks.
                match spans.last_mut() {
                    Some(last) if last.kind == span.kind && last.end == span.start => {
                        last.end = span.end;
                    }
                    _ => spans.push(span),
                }
            }
        }
    }

    spans
}

/// Byte to UTF-16 offset mapping, with an ASCII fast path.
struct ByteToUtf16 {
    checkpoints: Option<Vec<(u32, u32)>>,
    len: u32,
}

impl ByteToUtf16 {
    fn new(text: &str) -> Self {
        if text.is_ascii() {
            return Self {
                checkpoints: None,
                len: text.len() as u32,
            };
        }
        let mut checkpoints = Vec::with_capacity(text.chars().count() + 1);
        let mut utf16 = 0u32;
        for (byte, ch) in text.char_indices() {
            checkpoints.push((byte as u32, utf16));
            utf16 += ch.len_utf16() as u32;
        }
        checkpoints.push((text.len() as u32, utf16));
        Self {
            checkpoints: Some(checkpoints),
            len: utf16,
        }
    }

    fn to_utf16(&self, byte: usize) -> u32 {
        let Some(checkpoints) = &self.checkpoints else {
            return (byte as u32).min(self.len);
        };
        match checkpoints.binary_search_by_key(&(byte as u32), |&(b, _)| b) {
            Ok(index) => checkpoints[index].1,
            Err(0) => 0,
            Err(index) => checkpoints[index - 1].1,
        }
    }
}
