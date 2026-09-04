//
//  MermaidHTML.swift
//  MarkDevKit
//
//  GitHub README mermaid writes HTML inside node labels. BeautifulMermaid
//  draws those labels as plain text, so the tags themselves appear in the
//  picture. Rewrite the labels before layout so the reader sees the words.
//

import Foundation

/// README mermaid's HTML labels, reduced to what the native renderer can draw.
///
/// GitHub's mermaid renderer is a browser: `<b>`, `<code>` and `<br/>` become
/// formatting. BeautifulMermaid's Core Graphics path does not parse those
/// tags — it paints the source, so a GitPulse view map showed
/// `<b>Work</b> (<code>work</code>)` inside every node. Stripping the tags
/// (and turning `<br>` into a mermaid `\n`) is the honest native answer:
/// the words remain, the markup does not.
enum MermaidHTML {
    /// `source` with HTML inside quoted labels rewritten for the native
    /// renderer. Diagrams that never used HTML are returned unchanged.
    static func sanitized(_ source: String) -> String {
        guard source.contains("<") else { return source }
        return rewriteQuotedStrings(source) { sanitizeLabel($0) }
    }

    /// One label, as the native renderer should see it.
    static func sanitizeLabel(_ text: String) -> String {
        var result = text
        // A real newline inside a `[...]` label would split the mermaid line
        // and break the parse. The replacement template needs four backslashes
        // so the regex engine emits the two-character `\n` sequence that
        // mermaid's `normalizeBrTags` later turns into a line break.
        result = replace(result, #"<br\s*/?>"#, with: "\\\\n")
        result = replace(result, #"</?code\s*>"#, with: "")
        result = replace(
            result,
            #"</?(?:b|strong|i|em|u|s|del|span|font|small|mark|sub|sup)(?:\s[^>]*)?>"#,
            with: "")
        result = replace(result, #"<[^>]+>"#, with: "")
        return result
    }

    /// Rewrites the interior of every `"…"` string. Mermaid node labels,
    /// subgraph titles, and edge labels that carry HTML all arrive quoted
    /// in README diagrams; leaving unquoted tokens alone keeps `flowchart LR`
    /// and node ids untouched.
    private static func rewriteQuotedStrings(_ source: String, _ rewrite: (String) -> String)
        -> String
    {
        var result = ""
        result.reserveCapacity(source.count)
        var index = source.startIndex
        while index < source.endIndex {
            let character = source[index]
            if character == "\"" {
                let start = source.index(after: index)
                var cursor = start
                while cursor < source.endIndex, source[cursor] != "\"" {
                    cursor = source.index(after: cursor)
                }
                result.append("\"")
                if start < cursor {
                    result.append(rewrite(String(source[start..<cursor])))
                }
                if cursor < source.endIndex {
                    result.append("\"")
                    index = source.index(after: cursor)
                } else {
                    index = cursor
                }
                continue
            }
            result.append(character)
            index = source.index(after: index)
        }
        return result
    }

    private static func replace(_ text: String, _ pattern: String, with template: String) -> String
    {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(
            in: text, options: [], range: range, withTemplate: template)
    }
}
