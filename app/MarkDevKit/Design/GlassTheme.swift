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
    public static let sidebar = PanelSizeRange(preferred: 260, minimum: 180, maximum: 420)
    /// Width rules for the inspector, on the trailing edge. Wider than the
    /// navigator because backlink context is prose, and prose in a 180pt
    /// column wraps into an unreadable ribbon.
    public static let inspector = PanelSizeRange(preferred: 300, minimum: 220, maximum: 460)

    /// The narrowest editor column that still reads like prose rather than a
    /// vertical ribbon. The window minimum is sized for the common two-pane
    /// workspace with both side panels visible; otherwise Split Right can
    /// succeed while leaving each editor too narrow to use.
    public static let minimumEditorPaneWidth: CGFloat = 340
    public static let minimumTwoPaneWindowWidth: CGFloat =
        sidebar.preferred + inspector.preferred
        + (dividerHitWidth * 3)
        + (minimumEditorPaneWidth * 2)

    /// Height rules for the terminal drawer, along the bottom edge.
    ///
    /// The minimum is deliberately generous: a shell shorter than about ten
    /// rows cannot show a compiler error or a CLI's progress output without
    /// scrolling it away, which makes the drawer worse than no drawer.
    public static let terminal = PanelSizeRange(preferred: 260, minimum: 160, maximum: 720)

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

/// The sizes a panel may take along its resizable axis, and the size it
/// returns to.
///
/// Named for size rather than width because the same rules govern the terminal
/// drawer's *height*: the axis is the caller's business, the clamping is not.
///
/// A pure value for the same reason ``SplitLayout`` is one: "a panel can never
/// be dragged shut" is then a tested property of the model rather than a clamp
/// copied into every view that draws a drag handle.
public struct PanelSizeRange: Sendable, Equatable {
    /// The size a fresh window opens at, and that a double-click restores.
    public let preferred: CGFloat
    public let minimum: CGFloat
    public let maximum: CGFloat

    public init(preferred: CGFloat, minimum: CGFloat, maximum: CGFloat) {
        precondition(
            minimum <= preferred && preferred <= maximum,
            "A panel's preferred size must lie inside its own range.")
        self.preferred = preferred
        self.minimum = minimum
        self.maximum = maximum
    }

    /// `size` brought inside the range.
    ///
    /// A non-finite size falls back to ``preferred``. Drag arithmetic divides
    /// by container sizes that are momentarily zero during window setup, and a
    /// NaN reaching `frame(width:)` corrupts the whole layout pass rather than
    /// failing where it was produced.
    public func clamping(_ size: CGFloat) -> CGFloat {
        guard size.isFinite else { return preferred }
        return min(max(size, minimum), maximum)
    }
}

/// Applies a glass surface with MarkDev's standard shape and padding.
public struct GlassPanel: ViewModifier {
    var radius: CGFloat
    var tint: Color?
    var interactive: Bool
    var padding: EdgeInsets

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public func body(content: Content) -> some View {
        if reduceTransparency {
            return AnyView(
                content
                    .padding(padding)
                    .background(
                        RoundedRectangle(cornerRadius: radius)
                            .fill(Color(nsColor: .windowBackgroundColor))
                    )
            )
        }

        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }

        return AnyView(
            content
                .padding(padding)
                .glassEffect(glass, in: .rect(cornerRadius: radius))
        )
    }
}

extension View {
    /// Pads a control's content and claims the padded area as its hit target.
    ///
    /// **Apply this inside a `Button`'s (or `Menu`'s) label, never to the
    /// button itself.** Padding applied outside decides where a control
    /// *sits*, not where it *responds*: with `.buttonStyle(.plain)` the
    /// interactive region is the label's own shape, so
    ///
    /// ```swift
    /// Button { … } label: { Image(systemName: "sidebar.leading") }
    ///     .buttonStyle(.plain)
    ///     .padding(10)              // ← grows the glass, not the target
    ///     .glassEffect(.regular, in: .circle)
    /// ```
    ///
    /// draws a 36pt circle that only answers to the 15pt glyph at its centre.
    /// The ring around it looks exactly as pressable and does nothing, which
    /// reads as an app that intermittently ignores clicks. Padding inside the
    /// label, then naming the padded shape, makes the whole glass live.
    public func controlTarget<S: Shape>(_ shape: S, padding: EdgeInsets) -> some View {
        self.padding(padding).contentShape(shape)
    }

    /// ``controlTarget(_:padding:)`` with the same inset on every side.
    public func controlTarget<S: Shape>(
        _ shape: S, padding: CGFloat = GlassTheme.Spacing.snug
    ) -> some View {
        controlTarget(
            shape,
            padding: EdgeInsets(
                top: padding, leading: padding, bottom: padding, trailing: padding))
    }

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
