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
        // Not derived from `quaternaryLabelColor`: that colour is already
        // heavily transparent, so tinting it again lands around 2% ink — a
        // panel too faint to read as a surface at all, which is most of why
        // code blocks looked like plain indented text.
        codeBackground: EditorTheme.adaptive(
            "codeSurface",
            light: NSColor(white: 0, alpha: 0.045),
            dark: NSColor(white: 1, alpha: 0.075)),
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

    // MARK: - Derived surfaces
    //
    // Derived rather than stored: a code panel's border is not an independent
    // design decision, it is "the code background, one step firmer". Storing
    // each one would let a theme set a border that no longer belongs to its
    // own background, and would make every call site of the initialiser churn
    // whenever the renderer learns to draw one more thing.

    /// A colour that resolves differently in light and dark appearance.
    ///
    /// The semantic `NSColor` statics are the right default for *text*, but
    /// the decoration surfaces need known ink levels: composing an alpha onto
    /// an already-translucent semantic colour multiplies the two, and the
    /// result is a panel nobody can see.
    static func adaptive(_ name: String, light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: NSColor.Name(name)) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    /// Leading between the lines of a code block.
    ///
    /// Tighter than prose, and derived rather than stored for the same reason
    /// the surfaces below are: it is not an independent decision but "prose
    /// leading, closed up". A listing is read as one object, and giving it
    /// body leading makes a five-line fence as tall as a paragraph.
    public var codeLineSpacing: CGFloat {
        (lineSpacing * 0.4).rounded()
    }

    /// Hairline around a code panel, so it reads as a card rather than a
    /// stretch of tinted paragraph.
    public var codeBorder: NSColor {
        Self.adaptive(
            "codeBorder",
            light: NSColor(white: 0, alpha: 0.11),
            dark: NSColor(white: 1, alpha: 0.14))
    }

    /// Fill behind a table's header row.
    public var tableHeaderBackground: NSColor {
        Self.adaptive(
            "tableHeader",
            light: NSColor(white: 0, alpha: 0.065),
            dark: NSColor(white: 1, alpha: 0.10))
    }

    /// Fill behind alternate body rows. Faint on purpose: banding should help
    /// the eye track across a wide row, not draw attention to itself.
    public var tableStripeBackground: NSColor {
        Self.adaptive(
            "tableStripe",
            light: NSColor(white: 0, alpha: 0.028),
            dark: NSColor(white: 1, alpha: 0.05))
    }

    /// The grid's own lines.
    public var tableBorder: NSColor {
        Self.adaptive(
            "tableBorder",
            light: NSColor(white: 0, alpha: 0.14),
            dark: NSColor(white: 1, alpha: 0.17))
    }

    /// Fill behind a block's copy or zoom chip.
    ///
    /// Nearly opaque, unlike every other surface here, because this one is not
    /// always drawn on the page: a zoom chip sits on top of whatever the
    /// picture happens to be, and a 6% tint over a photograph is a control
    /// nobody can find.
    public var controlBackground: NSColor {
        Self.adaptive(
            "controlChip",
            light: NSColor(white: 1, alpha: 0.86),
            dark: NSColor(white: 0.24, alpha: 0.9))
    }

    /// The same chip under the pointer.
    public var controlHighlight: NSColor {
        Self.adaptive(
            "controlChipHover",
            light: NSColor(white: 1, alpha: 1),
            dark: NSColor(white: 0.34, alpha: 1))
    }

    /// Hairline around a chip, so it keeps an edge on a background that
    /// happens to match its fill.
    public var controlBorder: NSColor {
        Self.adaptive(
            "controlChipBorder",
            light: NSColor(white: 0, alpha: 0.17),
            dark: NSColor(white: 1, alpha: 0.22))
    }

    /// Fill behind a `#tag` pill.
    public var tagBackground: NSColor {
        tagColor.withAlphaComponent(0.16)
    }

    /// The tick inside a checked checkbox. Always the light value, because it
    /// sits on the accent colour rather than on the page.
    public var checkmarkColor: NSColor {
        .white
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
