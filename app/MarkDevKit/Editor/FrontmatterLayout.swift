//
//  FrontmatterLayout.swift
//  MarkDevKit
//
//  YAML / TOML frontmatter drawn as a key/value panel in place of its fence.
//

import AppKit
import CoreText

/// One top-level frontmatter field, parsed just enough to draw.
///
/// Sequences (`tags: [a, b]` or `- item` lines) keep their items so the panel
/// can list them rather than dump the fence as one string. Nested collections
/// stay a verbatim scalar — this is a viewer, not a YAML implementation.
struct FrontmatterEntry: Equatable, Sendable {
    let key: String
    let value: String
    let items: [String]
}

enum FrontmatterFormat: Sendable {
    case yaml
    case toml
}

/// A finished key/value grid, safe to paint from a layout fragment.
///
/// Same bargain as ``TableRowLayout``: TextKit may ask a fragment to draw from
/// anywhere, so this holds `CTLine`s rather than an AppKit text system.
struct FrontmatterLayout: @unchecked Sendable {
    struct Row {
        let key: CTLine
        let values: [CTLine]
        let height: CGFloat
        let y: CGFloat
    }

    let rows: [Row]
    let height: CGFloat
    let keyColumnWidth: CGFloat
    let entries: [FrontmatterEntry]

    enum Metrics {
        static let columnGap: CGFloat = 16
        static let rowGap: CGFloat = 6
        static let verticalPadding: CGFloat = 10
        static let itemIndent: CGFloat = 12
    }

    /// Best-effort parse of a fence body. Unknown YAML/TOML is shown as
    /// scalars rather than guessed at.
    static func parse(_ raw: String, format: FrontmatterFormat) -> [FrontmatterEntry] {
        switch format {
        case .yaml: parseYaml(raw)
        case .toml: parseToml(raw)
        }
    }

    @MainActor
    static func make(
        entries: [FrontmatterEntry],
        availableWidth: CGFloat,
        theme: EditorTheme,
        keyColor: CGColor,
        valueColor: CGColor
    ) -> FrontmatterLayout {
        let keyFont = CTFontCreateUIFontForLanguage(.emphasizedSystem, 12, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let valueFont = CTFontCreateUIFontForLanguage(.system, theme.bodyFont.pointSize * 0.92, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, theme.bodyFont.pointSize * 0.92, nil)

        let measuredKeys: [(line: CTLine, width: CGFloat, ascent: CGFloat, descent: CGFloat)] =
            entries.map { entry in
                measure(entry.key, font: keyFont, color: keyColor)
            }
        let widestKey = measuredKeys.map(\.width).max() ?? 0
        let width = max(availableWidth, 1)
        let keyColumn = min(max(widestKey, 48), width * 0.42)
        let valueWidth = max(width - keyColumn - Metrics.columnGap, 40)

        var rows: [Row] = []
        var y = Metrics.verticalPadding
        for (index, entry) in entries.enumerated() {
            let key = measuredKeys[index]
            let texts: [String]
            if entry.items.isEmpty {
                texts = entry.value.isEmpty ? [""] : [entry.value]
            } else {
                texts = entry.items.map { "· \($0)" }
            }
            var valueLines: [CTLine] = []
            var valueHeight: CGFloat = 0
            for text in texts {
                let wrapped = wrap(
                    text, font: valueFont, color: valueColor, width: valueWidth,
                    lineSpacing: theme.lineSpacing)
                valueLines.append(contentsOf: wrapped.lines)
                valueHeight += wrapped.height
            }
            let rowHeight = max(key.ascent + key.descent, valueHeight, 14)
            rows.append(Row(key: key.line, values: valueLines, height: rowHeight, y: y))
            y += rowHeight + Metrics.rowGap
        }
        if !rows.isEmpty {
            y -= Metrics.rowGap
        }
        y += Metrics.verticalPadding
        return FrontmatterLayout(
            rows: rows,
            height: max(y, 28),
            keyColumnWidth: keyColumn,
            entries: entries)
    }

    func draw(in context: CGContext, at origin: CGPoint) {
        context.saveGState()
        defer { context.restoreGState() }
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for row in rows {
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            _ = CTLineGetTypographicBounds(row.key, &ascent, &descent, nil)
            context.textPosition = CGPoint(
                x: origin.x, y: origin.y + row.y + ascent)
            CTLineDraw(row.key, context)

            var valueY = row.y
            for line in row.values {
                var lineAscent: CGFloat = 0
                var lineDescent: CGFloat = 0
                var leading: CGFloat = 0
                _ = CTLineGetTypographicBounds(line, &lineAscent, &lineDescent, &leading)
                context.textPosition = CGPoint(
                    x: origin.x + keyColumnWidth + Metrics.columnGap,
                    y: origin.y + valueY + lineAscent)
                CTLineDraw(line, context)
                valueY += lineAscent + lineDescent + leading
            }
        }
    }

    // MARK: - Parse

    private static func parseYaml(_ raw: String) -> [FrontmatterEntry] {
        var entries: [(key: String, value: String, items: [String])] = []
        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            if (trimmed == "-" || trimmed.hasPrefix("- ")), !entries.isEmpty {
                let item = unquote(
                    String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                if !item.isEmpty { entries[entries.count - 1].items.append(item) }
                continue
            }

            if (line.first == " " || line.first == "\t"), !entries.isEmpty {
                let prev = entries[entries.count - 1].value
                entries[entries.count - 1].value = prev.isEmpty ? trimmed : "\(prev) \(trimmed)"
                continue
            }

            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }

            if let flowItems = flowSequenceItems(value) {
                entries.append((key, "", flowItems))
                continue
            }

            if blockScalarIndicators.contains(value) {
                value = ""
            } else if value.first != "\"", value.first != "'",
                let comment = value.range(of: " #")
            {
                value = value[..<comment.lowerBound].trimmingCharacters(in: .whitespaces)
            }
            entries.append((key, unquote(value), []))
        }
        return entries.map { entry in
            FrontmatterEntry(
                key: entry.key,
                value: entry.items.isEmpty ? entry.value : entry.items.joined(separator: ", "),
                items: entry.items)
        }
    }

    private static func parseToml(_ raw: String) -> [FrontmatterEntry] {
        var entries: [FrontmatterEntry] = []
        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("[") { continue }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            if let items = flowSequenceItems(value) {
                entries.append(
                    FrontmatterEntry(
                        key: key, value: items.joined(separator: ", "), items: items))
            } else {
                entries.append(FrontmatterEntry(key: key, value: unquote(value), items: []))
            }
        }
        return entries
    }

    private static let blockScalarIndicators: Set<String> = ["|", "|-", "|+", ">", ">-", ">+"]

    private static func flowSequenceItems(_ value: String) -> [String]? {
        guard value.hasPrefix("["), value.hasSuffix("]") else { return nil }
        let inner = String(value.dropFirst().dropLast())
        guard !inner.contains("["), !inner.contains("{") else { return nil }
        var items: [String] = []
        var current = ""
        var quote: Character?
        for ch in inner {
            if let q = quote {
                current.append(ch)
                if ch == q { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
                current.append(ch)
            } else if ch == "," {
                items.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        items.append(current)
        return items
            .map { unquote($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2,
            let first = value.first,
            first == value.last,
            first == "\"" || first == "'"
        else { return value }
        return String(value.dropFirst().dropLast())
    }

    // MARK: - Measure

    private static func measure(_ text: String, font: CTFont, color: CGColor) -> (
        line: CTLine, width: CGFloat, ascent: CGFloat, descent: CGFloat
    ) {
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color,
        ]
        let attributed = CFAttributedStringCreate(
            nil, text as CFString, attributes as CFDictionary)
            ?? CFAttributedStringCreate(nil, "" as CFString, nil)!
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        return (line, width, ascent, descent)
    }

    private static func wrap(
        _ text: String, font: CTFont, color: CGColor, width: CGFloat, lineSpacing: CGFloat
    ) -> (lines: [CTLine], height: CGFloat) {
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color,
        ]
        let attributed = CFAttributedStringCreate(
            nil, text as CFString, attributes as CFDictionary)
            ?? CFAttributedStringCreate(nil, "" as CFString, nil)!
        let length = CFAttributedStringGetLength(attributed)
        guard length > 0, width >= 1 else { return ([], 0) }
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        var lines: [CTLine] = []
        var start = 0
        var height: CGFloat = 0
        while start < length {
            var count = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
            if count <= 0 { count = 1 }
            let range = CFRange(location: start, length: min(count, length - start))
            let line = CTTypesetterCreateLine(typesetter, range)
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            lines.append(line)
            height += ascent + descent + leading + lineSpacing
            start = range.location + range.length
        }
        height = max(height - lineSpacing, 0)
        return (lines, height)
    }
}
