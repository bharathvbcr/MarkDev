//
//  EditorTheme.swift
//  MarkDevKit
//
//  Typography and colour for the writing surface.
//

import AppKit

/// Visual configuration for the editor.
///
/// The writing surface is deliberately *not* glass. Liquid Glass belongs to
/// the navigation layer floating above content; behind body text it costs
/// contrast and legibility for decoration. Chrome gets the glass, this gets
/// a flat, high-contrast background.
///
/// Colours are `NSColor` semantic or dynamic values so the same theme tracks
/// light and dark without a second definition.
@MainActor
public struct EditorTheme {
    // Typography
    public var bodyFont: NSFont
    public var monoFont: NSFont
    /// Multipliers for H1…H6.
    public var headingScale: [CGFloat]
    public var lineSpacing: CGFloat
    public var paragraphSpacing: CGFloat
    /// Reading measure. Long lines are the most common reason a Markdown
    /// editor is tiring to write in.
    public var contentWidth: CGFloat
    public var insets: NSSize

    // Colour
    public var textColor: NSColor
    public var secondaryColor: NSColor
    public var accentColor: NSColor
    public var codeColor: NSColor
    public var codeBackground: NSColor
    public var linkColor: NSColor
    public var tagColor: NSColor
    public var highlightBackground: NSColor
    public var quoteColor: NSColor
    /// Colour of revealed syntax markers, dimmed so they read as scaffolding
    /// rather than content.
    public var markerColor: NSColor

    public static let standard = EditorTheme(
        bodyFont: .systemFont(ofSize: 15),
        monoFont: .monospacedSystemFont(ofSize: 13.5, weight: .regular),
        headingScale: [1.9, 1.55, 1.3, 1.15, 1.05, 1.0],
        lineSpacing: 5,
        paragraphSpacing: 12,
        contentWidth: 720,
        insets: NSSize(width: 32, height: 28),
        textColor: .labelColor,
        secondaryColor: .secondaryLabelColor,
        accentColor: .controlAccentColor,
        codeColor: .systemPink,
        codeBackground: NSColor.quaternaryLabelColor.withAlphaComponent(0.18),
        linkColor: .linkColor,
        tagColor: .systemTeal,
        highlightBackground: NSColor.systemYellow.withAlphaComponent(0.28),
        quoteColor: .secondaryLabelColor,
        markerColor: .tertiaryLabelColor
    )

    public init(
        bodyFont: NSFont,
        monoFont: NSFont,
        headingScale: [CGFloat],
        lineSpacing: CGFloat,
        paragraphSpacing: CGFloat,
        contentWidth: CGFloat,
        insets: NSSize,
        textColor: NSColor,
        secondaryColor: NSColor,
        accentColor: NSColor,
        codeColor: NSColor,
        codeBackground: NSColor,
        linkColor: NSColor,
        tagColor: NSColor,
        highlightBackground: NSColor,
        quoteColor: NSColor,
        markerColor: NSColor
    ) {
        self.bodyFont = bodyFont
        self.monoFont = monoFont
        self.headingScale = headingScale
        self.lineSpacing = lineSpacing
        self.paragraphSpacing = paragraphSpacing
        self.contentWidth = contentWidth
        self.insets = insets
        self.textColor = textColor
        self.secondaryColor = secondaryColor
        self.accentColor = accentColor
        self.codeColor = codeColor
        self.codeBackground = codeBackground
        self.linkColor = linkColor
        self.tagColor = tagColor
        self.highlightBackground = highlightBackground
        self.quoteColor = quoteColor
        self.markerColor = markerColor
    }

    /// Bold heading font for `level` (1–6).
    public func headingFont(level: Int) -> NSFont {
        let index = min(max(level, 1), headingScale.count) - 1
        return .boldSystemFont(ofSize: bodyFont.pointSize * headingScale[index])
    }

    /// Point size that collapses a syntax marker to visually nothing.
    ///
    /// Not zero: a zero-size font produces degenerate metrics in layout.
    /// This is small enough to be invisible while remaining a real glyph, so
    /// the characters stay in text storage where selection, copy, and undo
    /// still see them.
    public static let hiddenMarkerFontSize: CGFloat = 0.01

    /// The font used for collapsed markers.
    public var hiddenMarkerFont: NSFont {
        .systemFont(ofSize: Self.hiddenMarkerFontSize)
    }
}
