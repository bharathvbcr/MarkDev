//
//  ScrollingTextView.swift
//  MarkDevKit
//
//  The geometry contract between a text view and the scroll view hosting it.
//

@preconcurrency import AppKit

/// An `NSTextView` that grows with its content inside an `NSScrollView`.
///
/// `init(frame:textContainer:)` is the only initialiser that accepts a
/// pre-built TextKit 2 stack, so it is the only one a subclass can use — and
/// it derives `minSize` **and `maxSize`** from the frame it is handed. Built
/// with a `.zero` frame, as a view whose size comes from its superview must
/// be, that leaves `maxSize` at zero height. `isVerticallyResizable` then has
/// nothing to resize into: the document view stays pinned to the viewport no
/// matter how much text it holds, so there is never anything to scroll and
/// the scroller never appears.
///
/// Nothing reports an error while this is wrong. `scrollRangeToVisible`
/// returns, the scroll view is wired up, the text lays out — the document is
/// simply never taller than the window. That is why the contract lives in a
/// base class instead of at each call site: it is invisible when forgotten.
///
/// On top of that this class holds two smaller guarantees:
///
/// - **The surface is never shorter than its viewport.** A three-line note
///   otherwise leaves a dead strip below the text where a click reaches the
///   clip view and the caret does not move.
/// - **The viewport never ends up past the end of the document.** Replacing a
///   long note with a short one, or deleting most of a file, shrinks the
///   document under a viewport that is still scrolled into what used to be
///   there, which paints as a blank editor.
@MainActor
public class ScrollingTextView: NSTextView {

    // MARK: - Construction

    public override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        applyScrollGeometry()
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        applyScrollGeometry()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        applyScrollGeometry()
    }

    /// Establishes the sizing contract, from every initialiser.
    ///
    /// Applied unconditionally rather than only on the paths known to be
    /// broken: the defaults differ between initialisers, and a rule that holds
    /// everywhere is one nobody has to remember the exceptions to.
    private func applyScrollGeometry() {
        // Height follows the text; width follows the viewport, so lines
        // rewrap on resize instead of scrolling sideways.
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]

        minSize = NSSize(width: 0, height: 0)
        maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)

        // The container must be free to grow with the text for the same
        // reason `maxSize` must: a bounded container silently truncates
        // layout instead of failing.
        textContainer?.widthTracksTextView = true
        textContainer?.heightTracksTextView = false
        textContainer?.size = NSSize(
            width: textContainer?.size.width ?? 0,
            height: CGFloat.greatestFiniteMagnitude)
    }

    // MARK: - Geometry

    /// Floors the height at the viewport, then pulls the viewport back inside
    /// the document if this call made it shorter.
    ///
    /// This is the hook rather than a notification because it is the single
    /// funnel every height change passes through — content edits, document
    /// replacement, restyling, and live resize alike. Clamping only on the way
    /// *down* leaves ordinary scrolling and rubber-band overscroll untouched.
    public override func setFrameSize(_ newSize: NSSize) {
        let previousHeight = frame.height

        var size = newSize
        if let viewportHeight = enclosingScrollView?.contentView.bounds.height,
            viewportHeight.isFinite
        {
            size.height = max(size.height, viewportHeight)
        }

        super.setFrameSize(size)

        if size.height < previousHeight { clampViewportIntoDocument() }
    }

    /// Scrolls back to the last valid position if the viewport is showing
    /// space the document no longer occupies.
    ///
    /// A no-op when the view is detached, which is how it behaves under test
    /// and in the Quick Look extension's first layout pass.
    public func clampViewportIntoDocument() {
        guard let scrollView = enclosingScrollView else { return }
        let clipView = scrollView.contentView

        let overscroll = max(0, frame.height - clipView.bounds.height)
        let origin = clipView.bounds.origin
        // A half-point tolerance: backing-store rounding routinely leaves the
        // origin a hair past the limit, and correcting that would fight the
        // scroll view on every frame of a live resize.
        guard origin.y > overscroll + 0.5 else { return }

        clipView.setBoundsOrigin(NSPoint(x: origin.x, y: overscroll))
        scrollView.reflectScrolledClipView(clipView)
    }

    // MARK: - Hosting

    /// Wraps a text view in a scroll view configured to host it.
    ///
    /// Paired with the geometry above deliberately: a correctly sized document
    /// view still cannot scroll if the scroll view around it is wrong, and the
    /// two halves of that arrangement drift apart the moment they are written
    /// out separately at each call site.
    public static func scrollView(hosting textView: ScrollingTextView) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        // The width tracks the viewport, so a horizontal scroller could only
        // ever be dead chrome.
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        // TextKit 2 lays out the visible viewport and extends as it moves;
        // without bounds-change notifications the layout controller is never
        // told the viewport moved, and scrolling reveals blank space.
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentView.postsFrameChangedNotifications = true
        scrollView.documentView = textView
        return scrollView
    }
}
