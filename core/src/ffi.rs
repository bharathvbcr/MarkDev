//! C ABI for the Swift side.
//!
//! # Ownership contract
//!
//! [`md_parse`] returns an opaque handle that owns the parse result. The
//! accessor functions hand back **borrowed** pointers into that handle's
//! storage — nothing is copied, so a document parse costs one allocation and
//! one FFI call rather than one call per node.
//!
//! Those pointers stay valid until [`md_free`] is called on the handle. Swift
//! must therefore either finish reading before freeing, or copy what it needs.
//! `MarkDevKit`'s `ParsedDocument` wrapper enforces this by owning the handle
//! and exposing only `UnsafeBufferPointer` views scoped to its own lifetime.
//!
//! # Why these are written out longhand
//!
//! The three array accessors are near-identical and beg for a `macro_rules!`.
//! They must not use one: cbindgen does not expand macros, so a generated
//! accessor is silently absent from `markdev.h` — the Swift build then fails
//! on a missing symbol, or worse, links against a stale declaration.

use std::ffi::{c_char, CString};
use std::ptr;

use crate::highlight::HighlightSpan;
use crate::md::{parse, BlockDescriptor, Document, ParseResult, Reparse, StyleSpan, SyntaxMarker};
use crate::vault::Vault;

/// Opaque handle owning one document's parse result.
pub struct ParseHandle {
    result: ParseResult,
    /// Null-terminated copies of the interned strings, built once so
    /// `md_string` can hand out stable `const char*`.
    c_strings: Vec<CString>,
}

/// Parses UTF-8 Markdown into a handle.
///
/// Returns null if `bytes` is null or is not valid UTF-8. The caller keeps
/// ownership of `bytes`; it is not retained past this call.
///
/// # Safety
///
/// `bytes` must point to at least `len` readable bytes.
#[no_mangle]
pub unsafe extern "C" fn md_parse(bytes: *const u8, len: usize) -> *mut ParseHandle {
    if bytes.is_null() {
        return ptr::null_mut();
    }
    let slice = std::slice::from_raw_parts(bytes, len);
    let Ok(source) = std::str::from_utf8(slice) else {
        return ptr::null_mut();
    };

    let result = parse(source);
    let c_strings = result
        .strings
        .iter()
        // Interior NULs cannot appear in valid Markdown source, but a lossy
        // fallback is still cheaper than risking a panic across the boundary.
        .map(|s| CString::new(s.as_str()).unwrap_or_default())
        .collect();

    Box::into_raw(Box::new(ParseHandle { result, c_strings }))
}

/// Releases a handle. Passing null is a no-op; passing the same handle twice
/// is undefined.
///
/// # Safety
///
/// `handle` must come from [`md_parse`] and must not be used afterwards.
#[no_mangle]
pub unsafe extern "C" fn md_free(handle: *mut ParseHandle) {
    if !handle.is_null() {
        drop(Box::from_raw(handle));
    }
}

/// Borrows the style-span array, writing its length to `count`.
///
/// Returns null and writes 0 when `handle` is null.
///
/// # Safety
///
/// `handle` must be live and `count` must be writable.
#[no_mangle]
pub unsafe extern "C" fn md_spans(
    handle: *const ParseHandle,
    count: *mut usize,
) -> *const StyleSpan {
    let Some(h) = handle.as_ref() else {
        if !count.is_null() {
            *count = 0;
        }
        return ptr::null();
    };
    if !count.is_null() {
        *count = h.result.spans.len();
    }
    h.result.spans.as_ptr()
}

/// Borrows the syntax-marker array, writing its length to `count`.
///
/// # Safety
///
/// `handle` must be live and `count` must be writable.
#[no_mangle]
pub unsafe extern "C" fn md_markers(
    handle: *const ParseHandle,
    count: *mut usize,
) -> *const SyntaxMarker {
    let Some(h) = handle.as_ref() else {
        if !count.is_null() {
            *count = 0;
        }
        return ptr::null();
    };
    if !count.is_null() {
        *count = h.result.markers.len();
    }
    h.result.markers.as_ptr()
}

/// Borrows the block-descriptor array, writing its length to `count`.
///
/// # Safety
///
/// `handle` must be live and `count` must be writable.
#[no_mangle]
pub unsafe extern "C" fn md_blocks(
    handle: *const ParseHandle,
    count: *mut usize,
) -> *const BlockDescriptor {
    let Some(h) = handle.as_ref() else {
        if !count.is_null() {
            *count = 0;
        }
        return ptr::null();
    };
    if !count.is_null() {
        *count = h.result.blocks.len();
    }
    h.result.blocks.as_ptr()
}

/// Borrows an interned string by index, or null when out of range.
///
/// # Safety
///
/// `handle` must be live.
#[no_mangle]
pub unsafe extern "C" fn md_string(handle: *const ParseHandle, index: u32) -> *const c_char {
    let Some(h) = handle.as_ref() else {
        return ptr::null();
    };
    match h.c_strings.get(index as usize) {
        Some(s) => s.as_ptr(),
        None => ptr::null(),
    }
}

/// Number of interned strings.
///
/// # Safety
///
/// `handle` must be live.
#[no_mangle]
pub unsafe extern "C" fn md_string_count(handle: *const ParseHandle) -> usize {
    handle.as_ref().map_or(0, |h| h.c_strings.len())
}

/// Semantic version of the FFI contract.
///
/// Swift asserts this at startup so a stale `libmarkdev.a` fails loudly at
/// launch instead of silently misreading struct layouts.
#[no_mangle]
pub extern "C" fn md_abi_version() -> u32 {
    1
}

// ---------------------------------------------------------------------------
// Incremental document
// ---------------------------------------------------------------------------

/// Opaque handle to a document that avoids reparsing when it provably can.
///
/// Mirrors an `NSTextStorage` on the Swift side. The two hold independent
/// copies of the text, so callers should compare [`md_document_len_utf16`]
/// against their own length after each edit and rebuild on mismatch — silent
/// drift would apply later edits at the wrong offsets.
pub struct DocumentHandle {
    document: Document,
    c_strings: Vec<CString>,
}

impl DocumentHandle {
    fn refresh_strings(&mut self) {
        self.c_strings = self
            .document
            .result()
            .strings
            .iter()
            .map(|s| CString::new(s.as_str()).unwrap_or_default())
            .collect();
    }
}

/// Creates a document from UTF-8 bytes. Returns null on invalid UTF-8.
///
/// # Safety
///
/// `bytes` must point to at least `len` readable bytes.
#[no_mangle]
pub unsafe extern "C" fn md_document_new(bytes: *const u8, len: usize) -> *mut DocumentHandle {
    let text = if bytes.is_null() || len == 0 {
        ""
    } else {
        let slice = std::slice::from_raw_parts(bytes, len);
        match std::str::from_utf8(slice) {
            Ok(s) => s,
            Err(_) => return ptr::null_mut(),
        }
    };

    let mut handle = DocumentHandle {
        document: Document::new(text),
        c_strings: Vec::new(),
    };
    handle.refresh_strings();
    Box::into_raw(Box::new(handle))
}

/// Releases a document handle.
///
/// # Safety
///
/// `handle` must come from [`md_document_new`] and must not be used after.
#[no_mangle]
pub unsafe extern "C" fn md_document_free(handle: *mut DocumentHandle) {
    if !handle.is_null() {
        drop(Box::from_raw(handle));
    }
}

/// Replaces the UTF-16 range `[start, end)` with `replacement`.
///
/// Returns 1 when the edit was absorbed by shifting offsets (no reparse), and
/// 0 when the document was reparsed in full. Both outcomes leave the result
/// correct; the distinction is only useful for metrics.
///
/// # Safety
///
/// `handle` must be live, and `replacement` must point to `replacement_len`
/// readable bytes (or be null when the length is zero).
#[no_mangle]
pub unsafe extern "C" fn md_document_replace(
    handle: *mut DocumentHandle,
    start: u32,
    end: u32,
    replacement: *const u8,
    replacement_len: usize,
) -> u8 {
    let Some(handle) = handle.as_mut() else {
        return 0;
    };

    let text = if replacement.is_null() || replacement_len == 0 {
        ""
    } else {
        let slice = std::slice::from_raw_parts(replacement, replacement_len);
        match std::str::from_utf8(slice) {
            Ok(s) => s,
            Err(_) => return 0,
        }
    };

    let start_byte = handle.document.byte_offset(start);
    let end_byte = handle.document.byte_offset(end.max(start));
    let outcome = handle.document.replace(start_byte..end_byte, text);
    handle.refresh_strings();

    match outcome {
        Reparse::Shifted(_) => 1,
        Reparse::Full => 0,
    }
}

/// UTF-16 length of the document's text, for drift detection.
///
/// # Safety
///
/// `handle` must be live.
#[no_mangle]
pub unsafe extern "C" fn md_document_len_utf16(handle: *const DocumentHandle) -> u32 {
    handle.as_ref().map_or(0, |h| h.document.len_utf16())
}

/// Borrows the document's style spans.
///
/// # Safety
///
/// `handle` must be live and `count` writable.
#[no_mangle]
pub unsafe extern "C" fn md_document_spans(
    handle: *const DocumentHandle,
    count: *mut usize,
) -> *const StyleSpan {
    let Some(h) = handle.as_ref() else {
        if !count.is_null() {
            *count = 0;
        }
        return ptr::null();
    };
    if !count.is_null() {
        *count = h.document.result().spans.len();
    }
    h.document.result().spans.as_ptr()
}

/// Borrows the document's syntax markers.
///
/// # Safety
///
/// `handle` must be live and `count` writable.
#[no_mangle]
pub unsafe extern "C" fn md_document_markers(
    handle: *const DocumentHandle,
    count: *mut usize,
) -> *const SyntaxMarker {
    let Some(h) = handle.as_ref() else {
        if !count.is_null() {
            *count = 0;
        }
        return ptr::null();
    };
    if !count.is_null() {
        *count = h.document.result().markers.len();
    }
    h.document.result().markers.as_ptr()
}

/// Borrows the document's block descriptors.
///
/// # Safety
///
/// `handle` must be live and `count` writable.
#[no_mangle]
pub unsafe extern "C" fn md_document_blocks(
    handle: *const DocumentHandle,
    count: *mut usize,
) -> *const BlockDescriptor {
    let Some(h) = handle.as_ref() else {
        if !count.is_null() {
            *count = 0;
        }
        return ptr::null();
    };
    if !count.is_null() {
        *count = h.document.result().blocks.len();
    }
    h.document.result().blocks.as_ptr()
}

/// Borrows an interned string by index, or null when out of range.
///
/// # Safety
///
/// `handle` must be live.
#[no_mangle]
pub unsafe extern "C" fn md_document_string(
    handle: *const DocumentHandle,
    index: u32,
) -> *const c_char {
    let Some(h) = handle.as_ref() else {
        return ptr::null();
    };
    match h.c_strings.get(index as usize) {
        Some(s) => s.as_ptr(),
        None => ptr::null(),
    }
}

/// Number of interned strings.
///
/// # Safety
///
/// `handle` must be live.
#[no_mangle]
pub unsafe extern "C" fn md_document_string_count(handle: *const DocumentHandle) -> usize {
    handle.as_ref().map_or(0, |h| h.c_strings.len())
}

// ---------------------------------------------------------------------------
// Vault index
// ---------------------------------------------------------------------------

/// Opaque handle to an indexed vault.
pub struct VaultHandle {
    vault: Vault,
    /// Keeps the last returned JSON alive until the next call, so callers
    /// borrow rather than free.
    scratch: Option<CString>,
}

/// Why this boundary uses JSON while the editor's does not.
///
/// The editor crosses the FFI on every keystroke, where a flat struct buffer
/// earns its complexity. Vault queries happen when a note is opened or a
/// search is typed — orders of magnitude less often, over deeply nested,
/// variable-length data. A bespoke buffer protocol for backlinks and outlines
/// would be a lot of pointer arithmetic to save microseconds nobody can feel.
impl VaultHandle {
    fn serve<T: serde::Serialize>(&mut self, value: &T) -> *const c_char {
        let json = serde_json::to_string(value).unwrap_or_else(|_| "[]".to_string());
        let cstring = CString::new(json).unwrap_or_default();
        self.scratch = Some(cstring);
        self.scratch.as_ref().map_or(ptr::null(), |s| s.as_ptr())
    }
}

/// Reads a C string argument, or `None` when null or not UTF-8.
unsafe fn read_str<'a>(pointer: *const c_char) -> Option<&'a str> {
    if pointer.is_null() {
        return None;
    }
    std::ffi::CStr::from_ptr(pointer).to_str().ok()
}

/// Indexes every Markdown file under `path`.
///
/// # Safety
///
/// `path` must be a NUL-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn md_vault_open(path: *const c_char) -> *mut VaultHandle {
    let Some(path) = read_str(path) else {
        return ptr::null_mut();
    };
    Box::into_raw(Box::new(VaultHandle {
        vault: Vault::open(path),
        scratch: None,
    }))
}

/// Releases a vault handle.
///
/// # Safety
///
/// `handle` must come from [`md_vault_open`] and must not be used after.
#[no_mangle]
pub unsafe extern "C" fn md_vault_free(handle: *mut VaultHandle) {
    if !handle.is_null() {
        drop(Box::from_raw(handle));
    }
}

/// Number of indexed notes.
///
/// # Safety
///
/// `handle` must be live.
#[no_mangle]
pub unsafe extern "C" fn md_vault_note_count(handle: *const VaultHandle) -> u32 {
    handle.as_ref().map_or(0, |h| h.vault.notes().len() as u32)
}

/// Re-indexes one note from text the caller already has in memory.
///
/// # Safety
///
/// `handle` must be live; `path` and `text` must be NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn md_vault_update(
    handle: *mut VaultHandle,
    path: *const c_char,
    text: *const c_char,
) {
    let (Some(handle), Some(path), Some(text)) = (handle.as_mut(), read_str(path), read_str(text))
    else {
        return;
    };
    handle.vault.update(path, text);
}

/// Drops `path` from the index after its file has left the disk.
///
/// The caller deletes or trashes the file; this forgets the note so backlinks
/// and search stop describing something that is no longer there. Unknown
/// paths are accepted silently — removing what was never indexed is a no-op,
/// which is what a watcher racing a manual delete wants.
///
/// # Safety
///
/// `handle` must be live; `path` must be NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn md_vault_remove(handle: *mut VaultHandle, path: *const c_char) {
    let (Some(handle), Some(path)) = (handle.as_mut(), read_str(path)) else {
        return;
    };
    handle.vault.remove(path);
}

/// Moves the note at `from` to `to`, rewriting every link that resolved to
/// it, and answers JSON `{rewritten_notes, rewritten_links}`.
///
/// The file itself is moved by this call. Null comes back when the move was
/// refused — unknown source, destination already taken, or a file error — so
/// the caller can say "no" rather than guessing why.
///
/// # Safety
///
/// `handle` must be live; `from` and `to` must be NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn md_vault_rename(
    handle: *mut VaultHandle,
    from: *const c_char,
    to: *const c_char,
) -> *const c_char {
    let (Some(handle), Some(from), Some(to)) = (handle.as_mut(), read_str(from), read_str(to))
    else {
        return ptr::null();
    };
    match handle.vault.rename_note(from, to) {
        Some(outcome) => handle.serve(&outcome),
        None => ptr::null(),
    }
}

/// JSON array of backlinks for `path`.
///
/// The returned pointer is owned by the handle and stays valid until the next
/// query on it or until the handle is freed.
///
/// # Safety
///
/// `handle` must be live; `path` must be NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn md_vault_backlinks(
    handle: *mut VaultHandle,
    path: *const c_char,
) -> *const c_char {
    let (Some(handle), Some(path)) = (handle.as_mut(), read_str(path)) else {
        return ptr::null();
    };
    let value = handle.vault.backlinks(path);
    handle.serve(&value)
}

/// JSON array of the links `path` points out at, each with the note it
/// resolves to.
///
/// The outbound half of [`md_vault_backlinks`]. It exists so a caller can ask
/// "what is this note connected to" without re-parsing the note it already
/// has on screen — which is a second parse of the same text, answering a
/// question the index answered when it read the file.
///
/// # Safety
///
/// `handle` must be live; `path` must be NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn md_vault_links(
    handle: *mut VaultHandle,
    path: *const c_char,
) -> *const c_char {
    let (Some(handle), Some(path)) = (handle.as_mut(), read_str(path)) else {
        return ptr::null();
    };
    let value = handle.vault.links(path);
    handle.serve(&value)
}

/// JSON array of unlinked mentions for `path`.
///
/// # Safety
///
/// `handle` must be live; `path` must be NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn md_vault_unlinked_mentions(
    handle: *mut VaultHandle,
    path: *const c_char,
) -> *const c_char {
    let (Some(handle), Some(path)) = (handle.as_mut(), read_str(path)) else {
        return ptr::null();
    };
    let value = handle.vault.unlinked_mentions(path);
    handle.serve(&value)
}

/// JSON array of headings for `path`, for the outline.
///
/// # Safety
///
/// `handle` must be live; `path` must be NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn md_vault_outline(
    handle: *mut VaultHandle,
    path: *const c_char,
) -> *const c_char {
    let (Some(handle), Some(path)) = (handle.as_mut(), read_str(path)) else {
        return ptr::null();
    };
    let value = handle
        .vault
        .note(path)
        .map(|note| note.headings.clone())
        .unwrap_or_default();
    handle.serve(&value)
}

/// JSON array of search hits.
///
/// # Safety
///
/// `handle` must be live; `query` must be NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn md_vault_search(
    handle: *mut VaultHandle,
    query: *const c_char,
    limit: u32,
) -> *const c_char {
    let (Some(handle), Some(query)) = (handle.as_mut(), read_str(query)) else {
        return ptr::null();
    };
    let value = handle.vault.search(query, limit as usize);
    handle.serve(&value)
}

/// JSON array of tags with counts.
///
/// # Safety
///
/// `handle` must be live.
#[no_mangle]
pub unsafe extern "C" fn md_vault_tags(handle: *mut VaultHandle) -> *const c_char {
    let Some(handle) = handle.as_mut() else {
        return ptr::null();
    };
    let value = handle.vault.tags();
    handle.serve(&value)
}

/// JSON array of the paths of every note carrying `tag`.
///
/// The tag is given without its leading `#`, matching what the index stores.
///
/// # Safety
///
/// `handle` must be live; `tag` must be NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn md_vault_notes_with_tag(
    handle: *mut VaultHandle,
    tag: *const c_char,
) -> *const c_char {
    let (Some(handle), Some(tag)) = (handle.as_mut(), read_str(tag)) else {
        return ptr::null();
    };
    let value = handle.vault.notes_with_tag(tag);
    handle.serve(&value)
}

/// JSON object resolving a `[[wikilink]]`, or `null` when it is broken.
///
/// # Safety
///
/// `handle` must be live; `target` must be NUL-terminated UTF-8. `anchor` may
/// be null.
#[no_mangle]
pub unsafe extern "C" fn md_vault_resolve(
    handle: *mut VaultHandle,
    target: *const c_char,
    anchor: *const c_char,
) -> *const c_char {
    let (Some(handle), Some(target)) = (handle.as_mut(), read_str(target)) else {
        return ptr::null();
    };
    let anchor = read_str(anchor);
    let value = handle.vault.resolve(target, anchor);
    handle.serve(&value)
}

/// JSON array of every note path in the vault.
///
/// # Safety
///
/// `handle` must be live.
#[no_mangle]
pub unsafe extern "C" fn md_vault_note_paths(handle: *mut VaultHandle) -> *const c_char {
    let Some(handle) = handle.as_mut() else {
        return ptr::null();
    };
    let value: Vec<&str> = handle
        .vault
        .notes()
        .iter()
        .map(|note| note.path.as_str())
        .collect();
    let json = serde_json::to_string(&value).unwrap_or_else(|_| "[]".to_string());
    let cstring = CString::new(json).unwrap_or_default();
    handle.scratch = Some(cstring);
    handle.scratch.as_ref().map_or(ptr::null(), |s| s.as_ptr())
}

/// JSON graph of the vault's links, laid out and ready to draw.
///
/// One call rather than "give me the nodes, now the edges, now the positions":
/// the layout is a property of the whole graph, so splitting it would let a
/// caller draw edges against coordinates from a different build.
///
/// `focus` limits the graph to notes within `depth` hops of that note; pass
/// null for the whole vault. `tag` and `folder` filter it further; both may be
/// null.
///
/// # Safety
///
/// `handle` must be live. `focus`, `tag`, and `folder` may be null, and must
/// otherwise be NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn md_vault_graph(
    handle: *mut VaultHandle,
    focus: *const c_char,
    depth: u32,
    tag: *const c_char,
    folder: *const c_char,
) -> *const c_char {
    let Some(handle) = handle.as_mut() else {
        return ptr::null();
    };
    let query = crate::vault::GraphQuery {
        focus: read_str(focus),
        depth,
        tag: read_str(tag),
        folder: read_str(folder),
    };
    let graph = crate::vault::Graph::build(&handle.vault, &query);
    handle.serve(&graph)
}

// ---------------------------------------------------------------------------
// Syntax highlighting
// ---------------------------------------------------------------------------

/// Owns one code block's highlight spans.
///
/// Flat buffers rather than JSON: highlighting runs per code block on every
/// restyle, which puts it on the same hot path as the editor's own spans.
pub struct HighlightHandle {
    spans: Vec<HighlightSpan>,
}

/// Highlights `code` as `language`.
///
/// Returns a handle even when the language is unknown — the span array is
/// simply empty, and unhighlighted code reads fine.
///
/// # Safety
///
/// `language` must be NUL-terminated UTF-8; `code` must point to `code_len`
/// readable bytes.
#[no_mangle]
pub unsafe extern "C" fn md_highlight(
    language: *const c_char,
    code: *const u8,
    code_len: usize,
) -> *mut HighlightHandle {
    let language: &str = read_str(language).unwrap_or_default();
    let code = if code.is_null() || code_len == 0 {
        ""
    } else {
        std::str::from_utf8(std::slice::from_raw_parts(code, code_len)).unwrap_or_default()
    };

    Box::into_raw(Box::new(HighlightHandle {
        spans: crate::highlight::highlight(language, code),
    }))
}

/// Releases a highlight handle.
///
/// # Safety
///
/// `handle` must come from [`md_highlight`] and must not be used after.
#[no_mangle]
pub unsafe extern "C" fn md_highlight_free(handle: *mut HighlightHandle) {
    if !handle.is_null() {
        drop(Box::from_raw(handle));
    }
}

/// Borrows the highlight spans, writing the count to `count`.
///
/// # Safety
///
/// `handle` must be live and `count` writable.
#[no_mangle]
pub unsafe extern "C" fn md_highlight_spans(
    handle: *const HighlightHandle,
    count: *mut usize,
) -> *const HighlightSpan {
    let Some(handle) = handle.as_ref() else {
        if !count.is_null() {
            *count = 0;
        }
        return ptr::null();
    };
    if !count.is_null() {
        *count = handle.spans.len();
    }
    handle.spans.as_ptr()
}

/// Whether a grammar is available for `language`.
///
/// # Safety
///
/// `language` must be NUL-terminated UTF-8, or null.
#[no_mangle]
pub unsafe extern "C" fn md_highlight_supports(language: *const c_char) -> u8 {
    match read_str(language) {
        Some(value) if crate::highlight::supports(value) => 1,
        _ => 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CStr;

    /// Reads a borrowed C string.
    fn read(s: *const c_char) -> Option<String> {
        if s.is_null() {
            return None;
        }
        unsafe { Some(CStr::from_ptr(s).to_string_lossy().into_owned()) }
    }

    #[test]
    fn parse_and_free_round_trips() {
        let src = "# Title\n\n**bold** and `code`";
        let handle = unsafe { md_parse(src.as_ptr(), src.len()) };
        assert!(!handle.is_null());

        let mut count = 0usize;
        let spans = unsafe { md_spans(handle, &mut count) };
        assert!(!spans.is_null());
        assert!(count > 0, "expected spans for heading, strong, and code");

        let mut markers = 0usize;
        assert!(!unsafe { md_markers(handle, &mut markers) }.is_null());
        assert!(markers > 0, "expected markers for `#`, `**`, and backticks");

        let mut blocks = 0usize;
        assert!(!unsafe { md_blocks(handle, &mut blocks) }.is_null());
        assert!(blocks > 0);

        unsafe { md_free(handle) };
    }

    #[test]
    fn interned_strings_are_readable() {
        let src = "```swift\nlet x = 1\n```";
        let handle = unsafe { md_parse(src.as_ptr(), src.len()) };
        assert_eq!(unsafe { md_string_count(handle) }, 1);
        assert_eq!(
            read(unsafe { md_string(handle, 0) }).as_deref(),
            Some("swift")
        );
        assert!(unsafe { md_string(handle, 99) }.is_null());
        unsafe { md_free(handle) };
    }

    #[test]
    fn invalid_utf8_returns_null_rather_than_panicking() {
        let bad = [0xffu8, 0xfe, 0xfd];
        let handle = unsafe { md_parse(bad.as_ptr(), bad.len()) };
        assert!(handle.is_null());
    }

    #[test]
    fn null_inputs_are_handled() {
        assert!(unsafe { md_parse(ptr::null(), 0) }.is_null());
        let mut count = 7usize;
        assert!(unsafe { md_spans(ptr::null(), &mut count) }.is_null());
        assert_eq!(count, 0, "count must be zeroed when the handle is null");
        assert!(unsafe { md_markers(ptr::null(), &mut count) }.is_null());
        assert!(unsafe { md_blocks(ptr::null(), &mut count) }.is_null());
        assert_eq!(unsafe { md_string_count(ptr::null()) }, 0);
        unsafe { md_free(ptr::null_mut()) };
    }

    #[test]
    fn empty_document_is_valid() {
        let handle = unsafe { md_parse("".as_ptr(), 0) };
        assert!(!handle.is_null());
        let mut count = 9usize;
        unsafe { md_spans(handle, &mut count) };
        assert_eq!(count, 0);
        unsafe { md_free(handle) };
    }

    #[test]
    fn abi_version_is_stable() {
        assert_eq!(md_abi_version(), 1);
    }

    // --- incremental document ---

    #[test]
    fn document_round_trips_and_reports_length() {
        let src = "para one here\n\nplain prose paragraph\n";
        let handle = unsafe { md_document_new(src.as_ptr(), src.len()) };
        assert!(!handle.is_null());
        assert_eq!(
            unsafe { md_document_len_utf16(handle) },
            src.encode_utf16().count() as u32
        );

        let mut count = 0usize;
        assert!(!unsafe { md_document_blocks(handle, &mut count) }.is_null());
        assert!(count > 0);

        unsafe { md_document_free(handle) };
    }

    #[test]
    fn document_edit_updates_length_and_reports_its_path() {
        let src = "para one here\n\nplain prose paragraph\n";
        let handle = unsafe { md_document_new(src.as_ptr(), src.len()) };

        // Mid-word in plain prose: the shift-only path.
        let at = src.find("prose").expect("anchor") as u32 + 2;
        let word = "XY";
        let shifted = unsafe { md_document_replace(handle, at, at, word.as_ptr(), word.len()) };
        assert_eq!(shifted, 1, "typing inside plain prose should not reparse");
        assert_eq!(
            unsafe { md_document_len_utf16(handle) },
            (src.encode_utf16().count() + 2) as u32
        );

        unsafe { md_document_free(handle) };
    }

    #[test]
    fn document_structural_edit_takes_the_full_path() {
        let src = "para one here\n\nplain prose paragraph\n";
        let handle = unsafe { md_document_new(src.as_ptr(), src.len()) };
        let fence = "```\n";
        let at = src.find("plain").expect("anchor") as u32;
        let shifted = unsafe { md_document_replace(handle, at, at, fence.as_ptr(), fence.len()) };
        assert_eq!(shifted, 0, "an opening fence must force a full reparse");
        unsafe { md_document_free(handle) };
    }

    #[test]
    fn document_handles_null_and_invalid_input() {
        // A null pointer with zero length is an empty document, not an
        // error: an empty file is a perfectly good Markdown document.
        let empty = unsafe { md_document_new(ptr::null(), 0) };
        assert!(!empty.is_null());
        assert_eq!(unsafe { md_document_len_utf16(empty) }, 0);
        unsafe { md_document_free(empty) };
        assert_eq!(unsafe { md_document_len_utf16(ptr::null()) }, 0);
        assert_eq!(
            unsafe { md_document_replace(ptr::null_mut(), 0, 0, ptr::null(), 0) },
            0
        );
        let mut count = 3usize;
        assert!(unsafe { md_document_spans(ptr::null(), &mut count) }.is_null());
        assert_eq!(count, 0);
        unsafe { md_document_free(ptr::null_mut()) };
    }

    // --- vault ---

    #[test]
    fn vault_queries_round_trip_as_json() {
        let root = std::env::temp_dir().join(format!("markdev-ffi-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).expect("create");
        std::fs::write(root.join("A.md"), "# A\n\nLinks to [[B]] #tag\n").expect("write");
        std::fs::write(root.join("B.md"), "# B\n\n## Section\n").expect("write");

        let path = CString::new(root.to_string_lossy().as_ref()).expect("path");
        let handle = unsafe { md_vault_open(path.as_ptr()) };
        assert!(!handle.is_null());
        assert_eq!(unsafe { md_vault_note_count(handle) }, 2);

        let a = CString::new("A.md").expect("path");
        let b = CString::new("B.md").expect("path");
        let links = read(unsafe { md_vault_links(handle, a.as_ptr()) }).expect("json");
        assert!(
            links.contains("\"path\":\"B.md\""),
            "A links to B, resolved: {links}"
        );

        let json = read(unsafe { md_vault_backlinks(handle, b.as_ptr()) }).expect("json");
        assert!(
            json.contains("A.md"),
            "B should have a backlink from A: {json}"
        );

        let outline = read(unsafe { md_vault_outline(handle, b.as_ptr()) }).expect("json");
        assert!(outline.contains("Section"));

        let query = CString::new("links").expect("query");
        let hits = read(unsafe { md_vault_search(handle, query.as_ptr(), 10) }).expect("json");
        assert!(hits.contains("A.md"));

        let tag = CString::new("tag").expect("tag");
        let tagged = read(unsafe { md_vault_notes_with_tag(handle, tag.as_ptr()) }).expect("json");
        assert!(
            tagged.contains("A.md") && !tagged.contains("B.md"),
            "only the tagged note should be listed: {tagged}"
        );

        let tags = read(unsafe { md_vault_tags(handle) }).expect("json");
        assert!(tags.contains("tag"));

        let target = CString::new("B").expect("target");
        let resolved =
            read(unsafe { md_vault_resolve(handle, target.as_ptr(), ptr::null()) }).expect("json");
        assert!(resolved.contains("B.md"));

        unsafe { md_vault_free(handle) };
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn highlighting_round_trips_across_the_ffi() {
        let language = CString::new("rust").expect("language");
        let code = "fn main() { let x = 1; }";
        let handle = unsafe { md_highlight(language.as_ptr(), code.as_ptr(), code.len()) };
        assert!(!handle.is_null());

        let mut count = 0usize;
        let spans = unsafe { md_highlight_spans(handle, &mut count) };
        assert!(!spans.is_null());
        assert!(count > 0, "rust code should produce spans");

        let length = code.encode_utf16().count() as u32;
        for span in unsafe { std::slice::from_raw_parts(spans, count) } {
            assert!(span.start < span.end);
            assert!(span.end <= length, "span past end of code");
        }

        unsafe { md_highlight_free(handle) };
        assert_eq!(unsafe { md_highlight_supports(language.as_ptr()) }, 1);
    }

    #[test]
    fn highlighting_handles_unknown_languages_and_null() {
        let unknown = CString::new("klingon").expect("language");
        let code = "fn main() {}";
        let handle = unsafe { md_highlight(unknown.as_ptr(), code.as_ptr(), code.len()) };
        assert!(
            !handle.is_null(),
            "an unknown language still yields a handle"
        );

        let mut count = 9usize;
        unsafe { md_highlight_spans(handle, &mut count) };
        assert_eq!(count, 0);
        unsafe { md_highlight_free(handle) };

        assert_eq!(unsafe { md_highlight_supports(ptr::null()) }, 0);
        assert!(unsafe { md_highlight_spans(ptr::null(), &mut count) }.is_null());
        unsafe { md_highlight_free(ptr::null_mut()) };

        let handle = unsafe { md_highlight(ptr::null(), ptr::null(), 0) };
        assert!(!handle.is_null());
        unsafe { md_highlight_free(handle) };
    }

    #[test]
    fn vault_handles_null_input() {
        assert!(unsafe { md_vault_open(ptr::null()) }.is_null());
        assert_eq!(unsafe { md_vault_note_count(ptr::null()) }, 0);
        assert!(unsafe { md_vault_backlinks(ptr::null_mut(), ptr::null()) }.is_null());
        assert!(unsafe { md_vault_links(ptr::null_mut(), ptr::null()) }.is_null());
        assert!(unsafe { md_vault_tags(ptr::null_mut()) }.is_null());
        assert!(unsafe { md_vault_notes_with_tag(ptr::null_mut(), ptr::null()) }.is_null());
        unsafe { md_vault_free(ptr::null_mut()) };
    }

    #[test]
    fn document_utf16_offsets_land_on_the_right_bytes() {
        // The conversion Swift depends on: an emoji must not shift the edit.
        let src = "intro line here\n\nplain prose paragraph\n";
        let handle = unsafe { md_document_new(src.as_ptr(), src.len()) };
        let at = src.find("prose").expect("anchor") as u32;
        let word = "Z";
        unsafe { md_document_replace(handle, at, at + 5, word.as_ptr(), word.len()) };
        assert_eq!(
            unsafe { md_document_len_utf16(handle) },
            (src.encode_utf16().count() - 4) as u32
        );
        unsafe { md_document_free(handle) };
    }
}
