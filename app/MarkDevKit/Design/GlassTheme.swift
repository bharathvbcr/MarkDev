//
//  GlassTheme.swift
//  MarkDevKit
//
//  Design tokens and glass surfaces for the navigation layer.
//

import SwiftUI

/// Shared spacing, radii, and motion for MarkDev's chrome.
///
/// # Where glass belongs
///
/// Apple's guidance is that Liquid Glass is the *navigation layer floating
/// above content*. MarkDev follows that literally: the sidebar, tab strip,
/// toolbar, inspector, and palette are glass; the writing surface never is.
/// Glass behind body text trades legibility for decoration, and a Markdown
/// editor is a reading tool first.
public enum GlassTheme {
    // MARK: Metrics

    public enum Spacing {
        public static let hairline: CGFloat = 2
        public static let tight: CGFloat = 6
        public static let snug: CGFloat = 10
        public static let regular: CGFloat = 14
        public static let loose: CGFloat = 20
    }

    public enum Radius {
        public static let small: CGFloat = 8
        public static let medium: CGFloat = 12
        public static let large: CGFloat = 18
    }

    /// Width of a divider's grab area.
    ///
    /// The visible line is 1pt, but a 1pt target is unhittable. Ten points is
    /// the smallest band that stays comfortable without the cursor flickering
    /// between panes.
    public static let dividerHitWidth: CGFloat = 10
    public static let dividerLineWidth: CGFloat = 1
    /// Thickness the line grows to under the pointer or during a drag.
    public static let dividerActiveLineWidth: CGFloat = 3
    /// The grip that appears at the seam's midpoint while it is active.
    public static let dividerGripLength: CGFloat = 26
    public static let dividerGripThickness: CGFloat = 5

    /// Width rules for the navigator, on the leading edge.
    public static let sidebar = PanelWidthRange(preferred: 260, minimum: 180, maximum: 420)
    /// Width rules for the inspector, on the trailing edge. Wider than the
    /// navigator because backlink context is prose, and prose in a 180pt
    /// column wraps into an unreadable ribbon.
    public static let inspector = PanelWidthRange(preferred: 300, minimum: 220, maximum: 460)

    /// The narrowest editor column that still reads like prose rather than a
    /// vertical ribbon. The window minimum is sized for the common two-pane
    /// workspace with both side panels visible; otherwise Split Right can
    /// succeed while leaving each editor too narrow to use.
    public static let minimumEditorPaneWidth: CGFloat = 340
    public static let minimumTwoPaneWindowWidth: CGFloat =
        sidebar.preferred + inspector.preferred
        + (dividerHitWidth * 3)
        + (minimumEditorPaneWidth * 2)

    /// Height of the status readout under each pane.
    public static let statusBarHeight: CGFloat = 26

    // MARK: Motion

    /// Standard spring for chrome that moves.
    public static let spring = Animation.spring(response: 0.34, dampingFraction: 0.82)
    /// Quicker spring for small, frequent transitions.
    public static let quickSpring = Animation.spring(response: 0.22, dampingFraction: 0.86)

    /// Returns `animation` unless the viewer has asked for reduced motion.
    ///
    /// A glass interface leans on movement to explain itself, which is
    /// exactly why it has to stop when someone turns motion off — for
    /// vestibular sensitivity this is not a preference but a usability floor.
    public static func motion(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}

/// The widths a side panel may take, and the width it returns to.
///
/// A pure value for the same reason ``SplitLayout`` is one: "a panel can never
/// be dragged shut" is then a tested property of the model rather than a clamp
/// copied into every view that draws a drag handle.
public struct PanelWidthRange: Sendable, Equatable {
    /// The width a fresh window opens at, and that a double-click restores.
    public let preferred: CGFloat
    public let minimum: CGFloat
    public let maximum: CGFloat

    public init(preferred: CGFloat, minimum: CGFloat, maximum: CGFloat) {
        precondition(
            minimum <= preferred && preferred <= maximum,
            "A panel's preferred width must lie inside its own range.")
        self.preferred = preferred
        self.minimum = minimum
        self.maximum = maximum
    }

    /// `width` brought inside the range.
    ///
    /// A non-finite width falls back to ``preferred``. Drag arithmetic divides
    /// by container sizes that are momentarily zero during window setup, and a
    /// NaN reaching `frame(width:)` corrupts the whole layout pass rather than
    /// failing where it was produced.
    public func clamping(_ width: CGFloat) -> CGFloat {
        guard width.isFinite else { return preferred }
        return min(max(width, minimum), maximum)
    }
}

/// Applies a glass surface with MarkDev's standard shape and padding.
public struct GlassPanel: ViewModifier {
    var radius: CGFloat
    var tint: Color?
    var interactive: Bool
    var padding: EdgeInsets

    public func body(content: Content) -> some View {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }

        return
            content
            .padding(padding)
            .glassEffect(glass, in: .rect(cornerRadius: radius))
    }
}

extension View {
    /// Wraps the view in a glass surface.
    ///
    /// Reserved for chrome. Applying it to the editor canvas is a bug, not a
    /// style choice — see ``GlassTheme``.
    public func glassPanel(
        radius: CGFloat = GlassTheme.Radius.medium,
        tint: Color? = nil,
        interactive: Bool = false,
        padding: EdgeInsets = EdgeInsets(
            top: GlassTheme.Spacing.snug,
            leading: GlassTheme.Spacing.regular,
            bottom: GlassTheme.Spacing.snug,
            trailing: GlassTheme.Spacing.regular)
    ) -> some View {
        modifier(
            GlassPanel(radius: radius, tint: tint, interactive: interactive, padding: padding))
    }

    /// Applies `animation` unless reduced motion is requested.
    public func glassMotion(_ animation: Animation = GlassTheme.spring, reduceMotion: Bool)
        -> some View
    {
        self.animation(GlassTheme.motion(animation, reduceMotion: reduceMotion), value: reduceMotion)
    }
}
