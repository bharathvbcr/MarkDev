//
//  LaTeXNormalizer.swift
//  MarkDevKit
//
//  Maps LaTeX that is correct by convention but outside SwiftMath's command
//  table onto the closest supported spelling, so a formula fails only when
//  its mathematics genuinely cannot be drawn.
//

import Foundation

/// Rewrites unsupported-but-conventional LaTeX commands onto SwiftMath's
/// supported subset.
///
/// SwiftMath refuses an entire formula over one command it does not know:
/// `\operatorname{softmax}` costs the whole line, red strip and all, even
/// though every other symbol in it typesets. Most refusals in real notes are
/// spellings from wider LaTeX — amsmath, amssymb, Physics-style operator
/// names — that have exact or faithful equivalents inside SwiftMath's table:
///
/// - **Exact synonyms**: `\varnothing` *is* `\emptyset`; `\implies` is
///   `\Rightarrow`; `\dfrac` is display-style `\frac`, which is what a block
///   formula already renders as.
/// - **Operator names**: `\operatorname{ReLU}` and the bare `\arcsec`-family
///   become upright `\mathrm` text — the same ink `\operatorname` produces.
/// - **ASCII stand-ins**: `\coloneqq` is `:=`.
///
/// What is deliberately *not* mapped: constructs with no honest equivalent.
/// `\substack`, `\overset`, `\cancel`, `\boxed` would each need content
/// rewritten beyond recognition, and a wrong picture of someone's algebra is
/// worse than a refusal naming the problem — the same bargain the rest of
/// this renderer makes. Those keep failing with their source on screen.
///
/// The function is total and pure: any input yields a string, malformed
/// braces pass through untouched (SwiftMath reports them with better context
/// than a rewriter could), and idempotence holds so double-normalizing is a
/// no-op. It runs before the render cache key is derived, so `\varnothing`
/// and `\emptyset` share one bitmap rather than keeping two.
public enum LaTeXNormalizer {
    /// Commands replaced outright. Keys match without braces; the value may
    /// itself be LaTeX.
    ///
    /// Every entry was probed against the linked SwiftMath before being
    /// written down here: the replacement must typeset, not merely parse.
    private static let simple: [String: String] = [
        // Amssymb spellings of symbols the table knows by other names.
        "varnothing": "\\emptyset",
        "implies": "\\Rightarrow",
        "impliedby": "\\Leftarrow",
        "leqslant": "\\leq",
        "geqslant": "\\geq",
        "smallsetminus": "\\setminus",
        "lvert": "\\vert",
        "rvert": "\\vert",
        "lVert": "\\Vert",
        "rVert": "\\Vert",
        "tfrac": "\\frac",
        "dfrac": "\\frac",
        "tbinom": "\\binom",
        "dbinom": "\\binom",
        // Delimited alternatives the table lacks under these names.
        "dots": "\\ldots",
        // ASCII stand-ins: `:=` is exactly what `\coloneqq` means.
        "coloneqq": ":=",
        "eqqcolon": "=:",
        // Binary "mod": upright text with thin space either side, the ink
        // amsmath's `\bmod` produces.
        "bmod": "\\ \\mathrm{mod}\\ ",
    ]

    // Conspicuously absent: glyph spellings such as `\therefore` mapped onto
    // their Unicode character. Measured against this SwiftMath build, its
    // parser *drops* a character it cannot name — "∴" parses to zero atoms,
    // and `p∴q` renders as "p q". A mapping into silence deletes mathematics
    // while looking like success, which is the one outcome worse than an
    // honest refusal. Those commands stay unmapped; the formula fails with
    // its source on screen.

    /// Commands that take one braced argument and rewrite around it.
    ///
    /// The value's `{}` placeholder receives the group's own contents.
    private static let braced: [String: String] = [
        // `\operatorname` and its starred variant produce upright operator
        // text; `\mathrm` is the same ink under a supported name.
        "operatorname": "\\mathrm{{}}",
        "operatorname*": "\\mathrm{{}}",
        // Bold italic vs bold roman: the weight survives, which is what the
        // author was saying when they wrote vectors as `\boldsymbol`.
        "boldsymbol": "\\mathbf{{}}",
        // An arrow over several letters draws as `\vec`'s arrow over the
        // group — shorter than a long arrow, same statement.
        "overrightarrow": "\\vec{{}}",
        // `(mod m)` — the parenthesised congruence spelling.
        "pmod": "\\ (\\mathrm{mod}\\ {})",
    ]

    /// Bare operator names that must become upright text. These read like
    /// `\sin` to SwiftMath — a word — but the table has no such entry, and an
    /// unknown command poisons everything around it.
    private static let namedOperators: Set<String> = [
        "arcsec", "arccsc", "arccot", "sech", "csch",
        "arcsinh", "arccosh", "arctanh", "arsinh", "arcosh", "artanh",
    ]

    /// Rewrites `latex` onto SwiftMath's supported subset.
    public static func normalize(_ latex: String) -> String {
        guard latex.contains("\\") else { return latex }
        var out = String()
        out.reserveCapacity(latex.count)
        let units = Array(latex)
        var i = 0

        while i < units.count {
            guard units[i] == "\\", i + 1 < units.count else {
                out.append(units[i])
                i += 1
                continue
            }

            // Read the longest run of ASCII letters after the backslash — a
            // LaTeX command name.
            var j = i + 1
            while j < units.count, units[j].isLetter, units[j].isASCII {
                j += 1
            }
            var name = String(units[(i + 1)..<j])
            // `\operatorname*`: the starred variant shares its unstarred
            // sibling's rewrite, so the star joins the name before lookup.
            if j < units.count, units[j] == "*", !name.isEmpty {
                name.append("*")
                j += 1
            }

            if name.isEmpty {
                // `\&`, `\%`: escaped punctuation. Ampersand is legal bare in
                // SwiftMath outside environments; the escaped spelling is the
                // one that fails.
                if units[j] == "&" {
                    out.append("&")
                    i += 2
                    continue
                }
                out.append(units[i])
                i += 1
                continue
            }

            if let replacement = simple[name] {
                out.append(contentsOf: replacement)
                i += name.count + 1
                continue
            }
            if name == "backslash" {
                // A literal backslash glyph has no supported spelling; leave
                // the command for SwiftMath to answer for itself.
                out.append("\\")
                out.append(contentsOf: name)
                i += name.count + 1
                continue
            }
            if let template = braced[name] {
                let argument = group(after: j, in: units) ?? token(after: j, in: units)
                if let argument {
                    out.append(
                        contentsOf: template.replacingOccurrences(of: "{}", with: argument.text))
                    i = argument.end
                    continue
                }
                // No group follows — leave the command for SwiftMath to
                // reject with its own message rather than guess.
                appendCommand(name, to: &out)
                i += name.count + 1
                continue
            }
            if namedOperators.contains(name) {
                out.append("\\mathrm{\(name)}\\ ")
                i += name.count + 1
                continue
            }
            // `\argmax`/`\argmin`: two known commands spelled as one.
            if name == "argmax" || name == "argmin" {
                let head = String(name.prefix(3))
                let tail = String(name.suffix(3))
                out.append("\\\(head)\\\(tail)")
                i += name.count + 1
                continue
            }
            appendCommand(name, to: &out)
            i += name.count + 1
        }
        return out
    }

    /// Copies `\name` through unchanged.
    private static func appendCommand(_ name: String, to out: inout String) {
        out.append("\\")
        out.append(contentsOf: name)
    }

    /// The `{…}` group starting at `offset`, honouring nesting, if one starts
    /// there. Whitespace before the brace is allowed — `\operatorname {x}` is
    /// legal LaTeX.
    private static func group(after offset: Int, in units: [Character]) -> (text: String, end: Int)? {
        var cursor = offset
        while cursor < units.count, units[cursor] == " " || units[cursor] == "\t" {
            cursor += 1
        }
        guard cursor < units.count, units[cursor] == "{" else { return nil }
        // Past the opening brace; it belongs to the rewrite, not to the text.
        cursor += 1
        var depth = 1
        var body = String()
        while cursor < units.count {
            let unit = units[cursor]
            if unit == "\\" {
                // An escaped brace is a glyph, not a delimiter.
                body.append(unit)
                cursor += 1
                guard cursor < units.count else { return nil }
                body.append(units[cursor])
                cursor += 1
                continue
            }
            if unit == "{" {
                depth += 1
                body.append(unit)
            } else if unit == "}" {
                depth -= 1
                guard depth > 0 else { return (body, cursor + 1) }
                body.append(unit)
            } else {
                body.append(unit)
            }
            cursor += 1
        }
        return nil
    }

    /// A braced command written without braces — `\pmod n` — reads its
    /// single-token argument after optional whitespace.
    ///
    /// Delimiters are refused: a `{` here means the brace group exists but is
    /// unterminated, and swallowing it as an argument would mangle the very
    /// input SwiftMath should be asked to reject.
    private static func token(
        after offset: Int, in units: [Character]
    ) -> (text: String, end: Int)? {
        var cursor = offset
        while cursor < units.count, units[cursor] == " " || units[cursor] == "\t" {
            cursor += 1
        }
        guard cursor < units.count,
            !units[cursor].isWhitespace,
            units[cursor] != "\\",
            units[cursor] != "{",
            units[cursor] != "}"
        else { return nil }
        return (String(units[cursor]), cursor + 1)
    }

    /// Whether normalizing `latex` changes it — used by tests to enumerate
    /// coverage, and cheap enough for diagnostics elsewhere.
    static func changes(_ latex: String) -> Bool {
        normalize(latex) != latex
    }
}
