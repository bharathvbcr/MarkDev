//! Markdown source → the flat [`ParseResult`] the editor renders from.
//!
//! # How syntax markers are found
//!
//! Live preview hides the literal syntax (`**`, `` ` ``, `# `, `](url)`) when
//! the caret is elsewhere. Rather than pattern-match each construct, markers
//! are derived structurally:
//!
//! > A marker is any part of a construct's source range that none of its
//! > children cover.
//!
//! `pulldown-cmark`'s [`OffsetIter`] gives a source range for every event, so
//! for `**bold**` the `Strong` range is `0..8` and its `Text` child is `2..6`,
//! leaving `0..2` and `6..8` — exactly the asterisks. The same single rule
//! yields `# ` on headings, the fence lines on code blocks, `[[`/`]]` on
//! wikilinks, and `](url)` on inline links, with no per-construct code.
//!
//! Two things this rule cannot see, handled separately below:
//! - Delimiters of *leaf* events (`` `code` ``, `$math$`) — these have no
//!   child events, so their delimiter width is computed directly.
//! - Blockquote `>` continuation markers on lines after the first, which sit
//!   *inside* the child paragraph's range rather than outside it.
//!
//! [`OffsetIter`]: pulldown_cmark::OffsetIter

use pulldown_cmark::{
    Alignment, BlockQuoteKind, CodeBlockKind, Event, LinkType, MetadataBlockKind, Options, Parser,
    Tag, TagEnd,
};
use std::ops::Range;

use super::model::{
    BlockDescriptor, BlockKind, CalloutKind, ParseResult, SpanKind, StyleSpan, SyntaxMarker,
    TableAlignment, Utf16Mapper, NO_INFO, TABLE_ALIGNMENT_BITS,
};

/// Parser options MarkDev renders with.
///
/// Deliberately excludes `ENABLE_SUBSCRIPT`/`ENABLE_SUPERSCRIPT`: subscript
/// re-reads `~x~` as subscript rather than strikethrough, which would quietly
/// change how existing notes render. Also excludes `ENABLE_SMART_PUNCTUATION`,
/// which rewrites text content and would desynchronise offsets from the
/// characters actually in the buffer.
pub fn options() -> Options {
    Options::ENABLE_TABLES
        | Options::ENABLE_FOOTNOTES
        | Options::ENABLE_STRIKETHROUGH
        | Options::ENABLE_TASKLISTS
        | Options::ENABLE_MATH
        | Options::ENABLE_GFM
        | Options::ENABLE_WIKILINKS
        | Options::ENABLE_DEFINITION_LIST
        | Options::ENABLE_YAML_STYLE_METADATA_BLOCKS
        | Options::ENABLE_PLUSES_DELIMITED_METADATA_BLOCKS
}

/// Column alignment for the table currently being walked.
///
/// `pulldown-cmark` reports alignment once, on the table's `Start` tag, but a
/// renderer needs it per *cell* — the cell is what gets padded left, centred,
/// or right. Rather than make every consumer re-find the owning table and
/// count columns, the alignments are stashed here and stamped onto each cell
/// as it opens.
///
/// A stack, not a single value: a table can sit inside a blockquote inside a
/// list, and while GFM tables cannot nest directly, a malformed document can
/// still open a second table before the first closes. Popping the wrong
/// alignment vector would silently right-align an unrelated column.
#[derive(Default)]
struct TableState {
    /// Alignment per column, innermost table last.
    tables: Vec<Vec<TableAlignment>>,
    /// Which column the next cell in the current row is.
    column: usize,
}

impl TableState {
    fn open(&mut self, alignments: &[Alignment]) {
        self.tables
            .push(alignments.iter().copied().map(alignment).collect());
        self.column = 0;
    }

    fn close(&mut self) {
        self.tables.pop();
        self.column = 0;
    }

    /// Starts a new row. Header and body rows both restart at column zero.
    fn new_row(&mut self) {
        self.column = 0;
    }

    /// Alignment for the next cell, consuming one column.
    ///
    /// A row with more cells than the delimiter row declared falls back to
    /// `Auto` rather than panicking: GFM tolerates ragged rows, and a parse
    /// must never be the thing that crashes an edit.
    fn next_cell(&mut self) -> TableAlignment {
        let alignment = self
            .tables
            .last()
            .and_then(|columns| columns.get(self.column))
            .copied()
            .unwrap_or(TableAlignment::Auto);
        self.column += 1;
        alignment
    }
}

fn alignment(a: Alignment) -> TableAlignment {
    match a {
        Alignment::None => TableAlignment::Auto,
        Alignment::Left => TableAlignment::Left,
        Alignment::Center => TableAlignment::Center,
        Alignment::Right => TableAlignment::Right,
    }
}

/// One open construct while walking the event stream.
struct Frame {
    range: Range<usize>,
    /// Byte ranges covered by children, in document order.
    covered: Vec<Range<usize>>,
    /// Index into `result.blocks` when this frame is a block, else `None`.
    block: Option<usize>,
    /// Span to emit on close, if this frame is an inline construct.
    span: Option<(SpanKind, u32)>,
    /// True for blockquote frames, which need the continuation-marker pass.
    is_block_quote: bool,
}

/// Parses `source` into the flat model the editor renders from.
pub fn parse(source: &str) -> ParseResult {
    let mapper = Utf16Mapper::new(source);
    let mut result = ParseResult::default();
    let mut stack: Vec<Frame> = Vec::new();
    // Innermost open block, so markers can be attributed to their block.
    let mut block_stack: Vec<usize> = Vec::new();
    let mut inline_depth: u16 = 0;
    // Depth of enclosing verbatim blocks (code, frontmatter, raw HTML). Their
    // contents arrive as `Text` events but must not be scanned for `#tag` or
    // `==highlight==` — a `#` inside a code fence is code, not a tag.
    let mut verbatim: usize = 0;
    let mut tables = TableState::default();

    for (event, range) in Parser::new_ext(source, options()).into_offset_iter() {
        match event {
            Event::Start(tag) => {
                if is_verbatim_tag(&tag) {
                    verbatim += 1;
                }
                let frame = open_frame(
                    &tag,
                    range,
                    source,
                    &mut result,
                    &mut block_stack,
                    inline_depth,
                    &mut tables,
                );
                if frame.span.is_some() {
                    inline_depth += 1;
                }
                stack.push(frame);
            }

            Event::End(end) => {
                if is_verbatim_end(&end) {
                    verbatim = verbatim.saturating_sub(1);
                }
                if end == TagEnd::Table {
                    tables.close();
                }
                let Some(frame) = stack.pop() else { continue };
                if frame.span.is_some() {
                    inline_depth = inline_depth.saturating_sub(1);
                }
                close_frame(frame, &end, source, &mapper, &mut result, &mut block_stack);
                // The closed construct is covered ground for its parent.
                cover(&mut stack, range);
            }

            // Leaf events whose range includes delimiters we must hide.
            Event::Code(_) => {
                emit_delimited_leaf(
                    &range,
                    source,
                    SpanKind::InlineCode,
                    delimiter_run(source, &range, b'`'),
                    &mapper,
                    &mut result,
                    &block_stack,
                    inline_depth,
                );
                cover(&mut stack, range);
            }
            Event::InlineMath(_) => {
                if inline_math_is_valid(source, &range) {
                    emit_delimited_leaf(
                        &range,
                        source,
                        SpanKind::InlineMath,
                        1,
                        &mapper,
                        &mut result,
                        &block_stack,
                        inline_depth,
                    );
                }
                cover(&mut stack, range);
            }
            Event::DisplayMath(_) => {
                if display_math_is_valid(source, &range) {
                    let block = push_block(
                        &mut result,
                        &mapper,
                        &range,
                        BlockKind::MathBlock,
                        block_stack.len() as u16,
                        0,
                        NO_INFO,
                    );
                    if block_stack.is_empty() {
                        result.top_level.push(range.clone());
                    }
                    // `$$` on both sides is syntax, the formula between is content.
                    mark(&mut result, &mapper, range.start..range.start + 2, block);
                    if range.end >= range.start + 2 {
                        mark(&mut result, &mapper, range.end - 2..range.end, block);
                    }
                }
                cover(&mut stack, range);
            }
            Event::FootnoteReference(_) => {
                // `[^label]` is entirely syntax standing in for a rendered mark.
                emit_delimited_leaf(
                    &range,
                    source,
                    SpanKind::FootnoteReference,
                    0,
                    &mapper,
                    &mut result,
                    &block_stack,
                    inline_depth,
                );
                mark_current(&mut result, &mapper, range.clone(), &block_stack);
                cover(&mut stack, range);
            }
            Event::TaskListMarker(checked) => {
                push_span(
                    &mut result,
                    &mapper,
                    &range,
                    SpanKind::TaskMarker,
                    inline_depth,
                    u32::from(checked),
                );
                // The literal `[ ]` is replaced by a drawn checkbox.
                mark_current(&mut result, &mapper, range.clone(), &block_stack);
                cover(&mut stack, range);
            }
            Event::Rule => {
                let block = push_block(
                    &mut result,
                    &mapper,
                    &range,
                    BlockKind::Rule,
                    block_stack.len() as u16,
                    0,
                    NO_INFO,
                );
                if block_stack.is_empty() {
                    result.top_level.push(range.clone());
                }
                // The `---` is replaced by a drawn line.
                mark(&mut result, &mapper, range.clone(), block);
                cover(&mut stack, range);
            }
            Event::InlineHtml(_) => {
                push_span(
                    &mut result,
                    &mapper,
                    &range,
                    SpanKind::InlineHtml,
                    inline_depth,
                    0,
                );
                cover(&mut stack, range);
            }

            // Plain content: covered, never a marker.
            Event::Text(_) => {
                if verbatim == 0 {
                    scan_text_extensions(source, &range, &mapper, &mut result, &block_stack);
                }
                cover(&mut stack, range);
            }
            Event::Html(_) | Event::SoftBreak | Event::HardBreak => {
                cover(&mut stack, range);
            }
        }
    }

    result.spans.sort_by_key(|s| (s.start, s.end));
    result.markers.sort_by_key(|m| (m.start, m.end));
    result.top_level.sort_by_key(|r| (r.start, r.end));
    result
}

/// Opens a frame for a `Start` tag, reserving a block slot where applicable.
fn open_frame(
    tag: &Tag,
    range: Range<usize>,
    source: &str,
    result: &mut ParseResult,
    block_stack: &mut Vec<usize>,
    inline_depth: u16,
    tables: &mut TableState,
) -> Frame {
    let depth = block_stack.len() as u16;
    let mut frame = Frame {
        range: range.clone(),
        covered: Vec::new(),
        block: None,
        span: None,
        is_block_quote: false,
    };

    // Block slots are reserved on open so markers can reference them, and
    // filled in on close once the full range is known.
    let reserve = |result: &mut ParseResult, kind: BlockKind, data: u32, info: u32| -> usize {
        let idx = result.blocks.len();
        result.blocks.push(BlockDescriptor {
            start: 0,
            end: 0,
            kind: kind as u16,
            depth,
            data,
            info,
        });
        idx
    };

    match tag {
        Tag::Paragraph => frame.block = Some(reserve(result, BlockKind::Paragraph, 0, NO_INFO)),
        Tag::Heading { level, .. } => {
            let lvl = *level as u32;
            frame.block = Some(reserve(result, BlockKind::Heading, lvl, NO_INFO));
            frame.span = Some((SpanKind::Heading, lvl));
        }
        Tag::BlockQuote(kind) => {
            frame.is_block_quote = true;
            frame.block = Some(match kind {
                Some(k) => reserve(result, BlockKind::Callout, callout_kind(*k) as u32, NO_INFO),
                None => reserve(result, BlockKind::BlockQuote, 0, NO_INFO),
            });
        }
        Tag::CodeBlock(kind) => {
            let (block_kind, info) = match kind {
                CodeBlockKind::Fenced(lang) => {
                    let lang = lang.split_whitespace().next().unwrap_or("");
                    let info = if lang.is_empty() {
                        NO_INFO
                    } else {
                        result.intern(lang)
                    };
                    // Routed by kind so the editor never string-compares.
                    if lang.eq_ignore_ascii_case("mermaid") {
                        (BlockKind::MermaidBlock, info)
                    } else {
                        (BlockKind::CodeBlock, info)
                    }
                }
                CodeBlockKind::Indented => (BlockKind::CodeBlock, NO_INFO),
            };
            frame.block = Some(reserve(result, block_kind, 0, info));
        }
        Tag::List(first) => {
            frame.block = Some(reserve(
                result,
                BlockKind::List,
                u32::from(first.is_some()),
                NO_INFO,
            ));
        }
        Tag::Item => frame.block = Some(reserve(result, BlockKind::ListItem, 0, NO_INFO)),
        Tag::Table(alignments) => {
            tables.open(alignments);
            // The column count rides on the table so a renderer can size the
            // grid without walking every row first.
            let columns = alignments.len() as u32;
            frame.block = Some(reserve(result, BlockKind::Table, columns, NO_INFO));
        }
        Tag::TableHead => {
            tables.new_row();
            frame.block = Some(reserve(result, BlockKind::TableHead, 0, NO_INFO));
        }
        Tag::TableRow => {
            tables.new_row();
            frame.block = Some(reserve(result, BlockKind::TableRow, 0, NO_INFO));
        }
        Tag::TableCell => {
            // The cell's column index and alignment, packed so one `data`
            // field answers both "which column am I" and "how do I sit in it".
            let column = tables.column as u32;
            let alignment = tables.next_cell() as u32;
            frame.block = Some(reserve(
                result,
                BlockKind::TableCell,
                (column << TABLE_ALIGNMENT_BITS) | alignment,
                NO_INFO,
            ));
        }
        Tag::HtmlBlock => frame.block = Some(reserve(result, BlockKind::HtmlBlock, 0, NO_INFO)),
        Tag::FootnoteDefinition(_) => {
            frame.block = Some(reserve(result, BlockKind::FootnoteDefinition, 0, NO_INFO))
        }
        Tag::DefinitionList => {
            frame.block = Some(reserve(result, BlockKind::DefinitionList, 0, NO_INFO))
        }
        Tag::DefinitionListTitle => {
            frame.block = Some(reserve(result, BlockKind::DefinitionListTitle, 0, NO_INFO))
        }
        Tag::DefinitionListDefinition => {
            frame.block = Some(reserve(
                result,
                BlockKind::DefinitionListDefinition,
                0,
                NO_INFO,
            ))
        }
        Tag::MetadataBlock(kind) => {
            let data = match kind {
                MetadataBlockKind::YamlStyle => 0,
                MetadataBlockKind::PlusesStyle => 1,
            };
            frame.block = Some(reserve(result, BlockKind::Frontmatter, data, NO_INFO));
        }

        // Inline constructs carry a span rather than a block.
        Tag::Emphasis => frame.span = Some((SpanKind::Emphasis, 0)),
        Tag::Strong => frame.span = Some((SpanKind::Strong, 0)),
        Tag::Strikethrough => frame.span = Some((SpanKind::Strikethrough, 0)),
        Tag::Superscript => frame.span = Some((SpanKind::Superscript, 0)),
        Tag::Subscript => frame.span = Some((SpanKind::Subscript, 0)),
        Tag::Link {
            link_type,
            dest_url,
            ..
        } => {
            let dest = result.intern(dest_url);
            let kind = if matches!(link_type, LinkType::WikiLink { .. }) {
                SpanKind::WikiLink
            } else {
                SpanKind::Link
            };
            frame.span = Some((kind, dest));
        }
        Tag::Image { dest_url, .. } => {
            let dest = result.intern(dest_url);
            frame.span = Some((SpanKind::Image, dest));
        }
    }

    let _ = (source, inline_depth);
    if let Some(idx) = frame.block {
        block_stack.push(idx);
    }
    frame
}

/// Closes a frame: emits its span, finalises its block, and derives markers
/// from the gaps its children left uncovered.
fn close_frame(
    frame: Frame,
    end: &TagEnd,
    source: &str,
    mapper: &Utf16Mapper,
    result: &mut ParseResult,
    block_stack: &mut Vec<usize>,
) {
    let range = frame.range.clone();

    if let Some(idx) = frame.block {
        result.blocks[idx].start = mapper.to_utf16(range.start);
        result.blocks[idx].end = mapper.to_utf16(range.end);
        block_stack.pop();
        // Emptying the stack means this block was top-level: a boundary the
        // incremental parser can safely cut on.
        if block_stack.is_empty() {
            result.top_level.push(range.clone());
        }
    }

    // Attribute markers to the innermost enclosing block: this frame if it is
    // one, otherwise whatever block still encloses it.
    let owner = frame
        .block
        .or_else(|| block_stack.last().copied())
        .unwrap_or(0) as u32;

    if let Some((kind, data)) = frame.span {
        // The span covers only the content, not the surrounding delimiters,
        // so styling never bleeds onto hidden syntax.
        let (content_start, content_end) = content_bounds(&frame.covered, &range);
        result.spans.push(StyleSpan {
            start: mapper.to_utf16(content_start),
            end: mapper.to_utf16(content_end),
            kind: kind as u16,
            depth: 0,
            data,
        });
    }

    for gap in gaps(&frame.covered, &range) {
        mark(result, mapper, gap, owner);
    }

    // A blockquote's `>` on continuation lines sits inside the child
    // paragraph's range, so the gap rule cannot see it.
    if frame.is_block_quote {
        mark_quote_prefixes(source, &range, mapper, result, owner);
    }

    let _ = end;
}

/// Byte range spanned by a frame's children, falling back to the frame itself.
fn content_bounds(covered: &[Range<usize>], range: &Range<usize>) -> (usize, usize) {
    match (covered.first(), covered.last()) {
        (Some(first), Some(last)) => (first.start, last.end),
        _ => (range.start, range.end),
    }
}

/// The parts of `range` that `covered` leaves untouched.
fn gaps(covered: &[Range<usize>], range: &Range<usize>) -> Vec<Range<usize>> {
    let mut out = Vec::new();
    let mut cursor = range.start;
    for child in covered {
        if child.start > cursor {
            out.push(cursor..child.start);
        }
        cursor = cursor.max(child.end);
    }
    if cursor < range.end {
        out.push(cursor..range.end);
    }
    out
}

/// Records `range` as covered by the innermost open frame.
fn cover(stack: &mut [Frame], range: Range<usize>) {
    if let Some(frame) = stack.last_mut() {
        frame.covered.push(range);
    }
}

/// Width of the delimiter run of `byte` at the start of `range`.
fn delimiter_run(source: &str, range: &Range<usize>, byte: u8) -> usize {
    source.as_bytes()[range.start..range.end]
        .iter()
        .take_while(|&&b| b == byte)
        .count()
}
/// Whether an inline `$…$` event should render as math rather than as the
/// literal text the reader typed.
///
/// `pulldown-cmark` pairs two `$`s whenever the first has a non-space after
/// it and the second a non-space before it — pandoc's rule, written for
/// documents that are mostly mathematics. In notes that are mostly prose it
/// eats currency: `$50-$100` pairs on the hyphen, hiding both dollars and
/// styling `50-` as math. Three refusals, each named for the prose it
/// protects:
///
/// - **Letter before plus digit after is a currency mark.** `US$5`,
///   `A$10`, `price$5` — an ASCII alphanumeric welded to the left of the
///   opener with a digit on its right is money, not LaTeX. The check is
///   ASCII-only deliberately: Chinese and Japanese are written without
///   spaces, so `其中$x$是变量` is the *normal* spelling of glued math, and
///   a Unicode-letter rule would refuse every one of those.
/// - **Nothing follows the closer but a digit.** Pandoc's own currency
///   rule: `$50-$100` closes before the second `0`, `$5 and$6` before the
///   `6`. A letter suffix is a word, so `$n$th` survives.
/// - **The pair never crosses from a link label into its destination.** A `$`
///   pair in `![chart $5](pic$a.png)` reaches across `](` because pulldown's
///   math scanner runs before images resolve. `](` alone is not enough to
///   decide that: real scientific notation routinely contains `$v[i](t)$`,
///   whose `]` matches a `[` inside the pair. A separator the pair cannot
///   account for is what refuses.
///   The same refusal guards `$$…$$`; see [`crosses_link_destination`].
///
/// The two pulldown rules — non-space after the opener, non-space before
/// the closer — are re-checked rather than trusted, so this function stays
/// correct even if the upstream pairing ever loosens.
fn inline_math_is_valid(source: &str, range: &Range<usize>) -> bool {
    let bytes = source.as_bytes();
    // Structural sanity: `$` at both ends with something between, and both
    // ends on character boundaries so the adjacency reads below cannot slice
    // mid-character however odd the caller.
    if range.len() < 3
        || range.end > bytes.len()
        || !source.is_char_boundary(range.start)
        || !source.is_char_boundary(range.end)
    {
        return false;
    }
    let (opener, closer) = (range.start, range.end - 1);
    if bytes[opener] != b'$' || bytes[closer] != b'$' {
        return false;
    }
    if bytes[opener + 1].is_ascii_whitespace() || bytes[closer - 1].is_ascii_whitespace() {
        return false;
    }
    // Currency signature: letter welded to the left, digit straight after.
    // Both halves must hold — `the$x$axis` has a digit nowhere in sight.
    if opener > 0 && bytes[opener - 1].is_ascii_alphanumeric() && bytes[opener + 1].is_ascii_digit()
    {
        return false;
    }
    if source[range.end..]
        .chars()
        .next()
        .is_some_and(|c| c.is_ascii_digit())
    {
        return false;
    }
    if crosses_link_destination(bytes, opener + 1..closer) {
        return false;
    }
    true
}

/// Whether a `$`/`$$` pair spans from a Markdown label into its destination.
///
/// Pulldown-cmark pairs dollars before images and links resolve, so a pair
/// that reaches across `](pic` has eaten an image separator — drawing it as
/// math puts a formula where the reader's sentence was. A pair is refused
/// when it cannot account for its own `](`. A `]` whose matching `[` lies
/// inside the pair is subscript-then-call notation —
/// `$v_{\text{dend}}[i](t)$`, ordinary scientific spelling. A `]` that
/// matches nothing inside the pair is debris of a construct the pairing ran
/// through, even when the surrounding brackets happen to balance
/// (`![img [inner] $5](pic$a.png)`).
///
/// `content` excludes the delimiters themselves.
fn crosses_link_destination(bytes: &[u8], content: Range<usize>) -> bool {
    let mut depth = 0usize;
    for i in content {
        match bytes[i] {
            b'[' => depth += 1,
            b']' => {
                if bytes.get(i + 1) == Some(&b'(') && depth == 0 {
                    // The `]` matches nothing inside the pair: this
                    // separator closes a bracket opened before the math.
                    return true;
                }
                depth = depth.saturating_sub(1);
            }
            _ => {}
        }
    }
    false
}

/// The same question for `$$…$$`.
///
/// Display pairing ignores whitespace entirely — pulldown-cmark only asks
/// that both delimiters be doubled — so `He gave me $$5 and I gave him $$10`
/// becomes a formula block *inside the sentence*, which the editor replaces
/// with a typeset bitmap: a hole where the sentence was. The currency rules
/// refuse it exactly as [`inline_math_is_valid`] does, and so does the
/// label-to-destination crossing: `![chart $$5](pic$$a.png)` would otherwise
/// draw its formula over the mangled image's debris, the one gap the inline
/// check's `](` refusal covered and this function lacked. Block math on its
/// own lines ends at a newline or the end of the document and passes
/// untouched; so does inline display math between words (`text $$x$$ more`),
/// which notes in the wild rely on.
fn display_math_is_valid(source: &str, range: &Range<usize>) -> bool {
    let bytes = source.as_bytes();
    // Structural sanity: `$$` at both ends with something between, on
    // character boundaries, for the same reason the inline check insists.
    if range.len() < 5
        || range.end > bytes.len()
        || !source.is_char_boundary(range.start)
        || !source.is_char_boundary(range.end)
    {
        return false;
    }
    if &bytes[range.start..range.start + 2] != b"$$" || &bytes[range.end - 2..range.end] != b"$$" {
        return false;
    }
    // Currency signature, same as inline: "word$$5 …" is slang for money
    // (`gave him $$10`), not display math.
    if range.start > 0
        && bytes[range.start - 1].is_ascii_alphanumeric()
        && bytes[range.start + 2].is_ascii_digit()
    {
        return false;
    }
    if source[range.end..]
        .chars()
        .next()
        .is_some_and(|c| c.is_ascii_digit())
    {
        return false;
    }
    if crosses_link_destination(bytes, range.start + 2..range.end - 2) {
        return false;
    }
    true
}

/// Emits a span for a leaf construct and hides its delimiters.
#[allow(clippy::too_many_arguments)]
fn emit_delimited_leaf(
    range: &Range<usize>,
    source: &str,
    kind: SpanKind,
    delim: usize,
    mapper: &Utf16Mapper,
    result: &mut ParseResult,
    block_stack: &[usize],
    inline_depth: u16,
) {
    let inner = range.start + delim..range.end.saturating_sub(delim);
    if inner.start <= inner.end {
        push_span(result, mapper, &inner, kind, inline_depth, 0);
    }
    if delim > 0 {
        mark_current(
            result,
            mapper,
            range.start..range.start + delim,
            block_stack,
        );
        mark_current(result, mapper, range.end - delim..range.end, block_stack);
    }
    let _ = source;
}

fn push_span(
    result: &mut ParseResult,
    mapper: &Utf16Mapper,
    range: &Range<usize>,
    kind: SpanKind,
    depth: u16,
    data: u32,
) {
    result.spans.push(StyleSpan {
        start: mapper.to_utf16(range.start),
        end: mapper.to_utf16(range.end),
        kind: kind as u16,
        depth,
        data,
    });
}

fn push_block(
    result: &mut ParseResult,
    mapper: &Utf16Mapper,
    range: &Range<usize>,
    kind: BlockKind,
    depth: u16,
    data: u32,
    info: u32,
) -> u32 {
    let idx = result.blocks.len() as u32;
    result.blocks.push(BlockDescriptor {
        start: mapper.to_utf16(range.start),
        end: mapper.to_utf16(range.end),
        kind: kind as u16,
        depth,
        data,
        info,
    });
    idx
}

fn mark(result: &mut ParseResult, mapper: &Utf16Mapper, range: Range<usize>, block: u32) {
    if range.start >= range.end {
        return;
    }
    result.markers.push(SyntaxMarker {
        start: mapper.to_utf16(range.start),
        end: mapper.to_utf16(range.end),
        block,
    });
}

fn mark_current(
    result: &mut ParseResult,
    mapper: &Utf16Mapper,
    range: Range<usize>,
    block_stack: &[usize],
) {
    let owner = block_stack.last().copied().unwrap_or(0) as u32;
    mark(result, mapper, range, owner);
}

/// Hides `>` (and one following space) at the start of every line inside a
/// blockquote. The first one is already caught by the gap rule; re-marking it
/// is harmless because markers are deduplicated by the editor's range set.
fn mark_quote_prefixes(
    source: &str,
    range: &Range<usize>,
    mapper: &Utf16Mapper,
    result: &mut ParseResult,
    block: u32,
) {
    let bytes = source.as_bytes();
    let mut i = range.start;
    let mut at_line_start = true;
    while i < range.end.min(bytes.len()) {
        if at_line_start {
            let mut j = i;
            // Leading indentation is layout, not syntax.
            while j < range.end && (bytes[j] == b' ' || bytes[j] == b'\t') {
                j += 1;
            }
            if j < range.end && bytes[j] == b'>' {
                let mut k = j + 1;
                if k < range.end && bytes[k] == b' ' {
                    k += 1;
                }
                mark(result, mapper, j..k, block);
                i = k;
                at_line_start = false;
                continue;
            }
        }
        at_line_start = bytes[i] == b'\n';
        i += 1;
    }
}

/// Finds constructs `pulldown-cmark` does not model: `#tag` and `==highlight==`.
///
/// Scanning only inside `Text` event ranges is what keeps a `#` in a code
/// fence or a URL fragment from being mistaken for a tag.
fn scan_text_extensions(
    source: &str,
    range: &Range<usize>,
    mapper: &Utf16Mapper,
    result: &mut ParseResult,
    block_stack: &[usize],
) {
    let text = &source[range.clone()];
    let bytes = text.as_bytes();
    let base = range.start;

    // ==highlight==
    //
    // Pairing is MarkDev's own, so the adjacency rules live here rather
    // than in a vendored parser: the opener must sit outside an ASCII word,
    // both inner flanks must be tight (`== spaced ==` is prose), nothing
    // may follow the closer but a digit, and an empty pair hides nothing.
    // Without them `x == y == z` swallowed the words between, base64 URL
    // padding paired across two URLs, and `a ==== b` hid four characters
    // and drew nothing — the pure gap this rule exists to refuse.
    let mut i = 0;
    while i + 1 < bytes.len() {
        if bytes[i] == b'=' && bytes[i + 1] == b'=' {
            if let Some(close) = find_pair(bytes, i + 2, b'=') {
                if highlight_is_valid(text, i, close) {
                    push_span(
                        result,
                        mapper,
                        &(base + i + 2..base + close),
                        SpanKind::Highlight,
                        0,
                        0,
                    );
                    mark_current(result, mapper, base + i..base + i + 2, block_stack);
                    mark_current(result, mapper, base + close..base + close + 2, block_stack);
                    i = close + 2;
                    continue;
                }
            }
        }
        i += 1;
    }

    // #tag — must start a word, and needs at least one non-digit so that
    // "#1" reads as a number rather than a tag.
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'#' && (i == 0 || is_boundary(bytes[i - 1])) {
            let start = i + 1;
            let mut j = start;
            while j < bytes.len() && is_tag_byte(bytes[j]) {
                j += 1;
            }
            if j > start && text[start..j].bytes().any(|b| !b.is_ascii_digit()) {
                push_span(result, mapper, &(base + i..base + j), SpanKind::Tag, 0, 0);
                i = j;
                continue;
            }
        }
        i += 1;
    }
}

fn find_pair(bytes: &[u8], from: usize, delim: u8) -> Option<usize> {
    let mut i = from;
    while i + 1 < bytes.len() {
        if bytes[i] == delim && bytes[i + 1] == delim {
            return Some(i);
        }
        i += 1;
    }
    None
}

/// Whether the `==` run at `open` may highlight up to the one at `close`.
///
/// Both are offsets into `text`, the `Text` event being scanned; `close`
/// is the start of the closing run, so the content is `open+2..close`.
/// The rules mirror [`inline_math_is_valid`] and exist for the same
/// reason: a pair that forms across ordinary prose hides its delimiters
/// and styles everything between, which reads as data loss.
///
/// The boundary check is ASCII-only for the reason its sibling's is:
/// Chinese and Japanese carry no spaces, so `这是==重点==内容` is normal
/// spelling, not an equals sign welded into a word.
fn highlight_is_valid(text: &str, open: usize, close: usize) -> bool {
    let bytes = text.as_bytes();
    // An empty or absent body highlights nothing — `a ==== b` must keep
    // every character it typed.
    if close <= open + 2 {
        return false;
    }
    // Tight inner flanks: `== spaced ==` is arithmetic, not emphasis.
    if bytes[open + 2].is_ascii_whitespace() || bytes[close - 1].is_ascii_whitespace() {
        return false;
    }
    // Outside an ASCII word on the left: base64 padding (`dGVzdA==`) and
    // glued comparisons (`a=b==c`) both put `==` inside a token.
    if open > 0 && bytes[open - 1].is_ascii_alphanumeric() {
        return false;
    }
    // Nothing follows the closer but a digit — the currency rule again,
    // because `==5==6` is arithmetic.
    if bytes.get(close + 2).is_some_and(|b| b.is_ascii_digit()) {
        return false;
    }
    true
}

/// Byte ranges of `#tag` occurrences in `text`.
///
/// Shared with the vault indexer so a tag means the same thing in the editor
/// and in the tag browser. Two implementations would drift the moment either
/// gained a rule.
pub fn scan_tags(text: &str) -> Vec<Range<usize>> {
    let bytes = text.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'#' && (i == 0 || is_boundary(bytes[i - 1])) {
            let start = i + 1;
            let mut j = start;
            while j < bytes.len() && is_tag_byte(bytes[j]) {
                j += 1;
            }
            if j > start && text[start..j].bytes().any(|b| !b.is_ascii_digit()) {
                out.push(i..j);
                i = j;
                continue;
            }
        }
        i += 1;
    }
    out
}

fn is_boundary(b: u8) -> bool {
    b.is_ascii_whitespace() || b == b'(' || b == b'[' || b == b'{' || b == b','
}

fn is_tag_byte(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'-' || b == b'_' || b == b'/' || !b.is_ascii()
}

/// Blocks whose text content is literal and must not be scanned for MarkDev's
/// own inline extensions.
fn is_verbatim_tag(tag: &Tag) -> bool {
    matches!(
        tag,
        Tag::CodeBlock(_) | Tag::HtmlBlock | Tag::MetadataBlock(_)
    )
}

fn is_verbatim_end(end: &TagEnd) -> bool {
    matches!(
        end,
        TagEnd::CodeBlock | TagEnd::HtmlBlock | TagEnd::MetadataBlock(_)
    )
}

fn callout_kind(k: BlockQuoteKind) -> CalloutKind {
    match k {
        BlockQuoteKind::Note => CalloutKind::Note,
        BlockQuoteKind::Tip => CalloutKind::Tip,
        BlockQuoteKind::Important => CalloutKind::Important,
        BlockQuoteKind::Warning => CalloutKind::Warning,
        BlockQuoteKind::Caution => CalloutKind::Caution,
    }
}
