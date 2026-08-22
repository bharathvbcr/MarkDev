//
//  ContentZoomViewer.swift
//  MarkDevKit
//
//  A diagram, a picture, or a formula, opened large.
//

import AppKit

/// Renders a block at viewing size rather than at reading size.
///
/// The editor draws rendered content to fit the column it is written in, which
/// is the right size to read a note at and the wrong size to *look* at a
/// twenty-node flowchart. Zooming the bitmap the fragment already holds would
/// magnify a 600-point picture and show its pixels; this re-renders the same
/// source, so a diagram opened large is drawn large — the vectors are laid out
/// again, not resampled.
///
/// Separate from the window so the sizes are assertable without one.
@MainActor
public enum ZoomedContent {
    /// Width a diagram is laid out to when opened.
    ///
    /// Generous rather than unbounded: the rasteriser doubles this for Retina
    /// and caps the result by pixel count, so a wider figure here buys detail
    /// up to that cap and nothing beyond it.
    public static let diagramWidth: CGFloat = 2000

    /// Bitmap pixels per point a diagram is rasterised at when opened.
    ///
    /// A graph's layout size is decided by the graph, not by the column, so a
    /// small diagram is already at its natural size in the editor and asking
    /// for a wider one changes nothing about it. Detail is what a viewer adds:
    /// this is what lets a reader magnify into a node's label and still find
    /// letters there.
    public static let diagramScale: CGFloat = 4

    /// Point size a formula is typeset at when opened.
    public static let mathFontSize: CGFloat = 64

    /// The most an image is scaled *down* to. Above this it is shown as it is:
    /// the viewer's job is to show the file, not to resample it.
    public static let imageWidth: CGFloat = 8000

    /// Width a vector image is laid out at when opened.
    ///
    /// A vector has no pixels to resample — magnifying one is *rendering* it,
    /// which is the whole bargain this viewer makes — so opening it large
    /// means laying it out large, and any width the note asked for is a
    /// statement about the page rather than about the file. A raster has no
    /// such freedom and keeps its own size, which is why the two are asked
    /// for differently.
    ///
    /// Rasterised at the ordinary Retina scale rather than the diagram's
    /// fourfold: here the *size* is what the viewer adds. A diagram is already
    /// at its natural size in the editor, since a graph's layout size is the
    /// graph's own, so detail is all there is to add there.
    public static let vectorWidth: CGFloat = 2000

    /// Renders `block` at viewing size.
    public static func render(
        _ block: RenderedBlock,
        documentDirectory: URL?,
        textColor: NSColor,
        dark: Bool
    ) -> Result<RenderedContent, RenderFailure> {
        switch block.kind {
        case .math:
            return RichContentRenderer.shared.math(
                block.source, fontSize: mathFontSize, color: textColor, display: true)
        case .diagram:
            return RichContentRenderer.shared.diagram(
                block.source, maxWidth: diagramWidth, dark: dark, scale: diagramScale)
        case .image(let alt):
            let scalable = RichContentRenderer.shared.isScalable(
                at: block.source, relativeTo: documentDirectory)
            return RichContentRenderer.shared.image(
                at: block.source, relativeTo: documentDirectory,
                maxWidth: scalable ? vectorWidth : imageWidth,
                width: scalable ? vectorWidth : nil
            )
            .mapError { failure in
                alt.isEmpty ? failure : RenderFailure(reason: "\(alt) — \(failure.reason)")
            }
        }
    }

    /// What the window is called.
    ///
    /// A picture is named by its file, since that is the name the reader knows
    /// it by; the other two have no name to use, so they are named by kind.
    public static func title(for block: RenderedBlock) -> String {
        switch block.kind {
        case .math: return "Formula"
        case .diagram: return "Diagram"
        case .image:
            let name = (block.source as NSString).lastPathComponent
            return name.isEmpty ? "Image" : name
        }
    }

    /// The magnification that fits `content` into `viewport`.
    ///
    /// Never above 1: opening a small picture should show it at its own size,
    /// not blown up to fill a window it was never drawn for. Zooming past that
    /// is the reader's decision, and the scroll view already offers it.
    public static func fitMagnification(content: CGSize, viewport: CGSize) -> CGFloat {
        guard content.width > 0, content.height > 0,
            viewport.width > 0, viewport.height > 0,
            content.width.isFinite, content.height.isFinite
        else { return 1 }
        return min(1, min(viewport.width / content.width, viewport.height / content.height))
    }
}

/// The window rendered content opens in.
///
/// One window, reused: clicking three diagrams in a note should not leave three
/// windows behind for the reader to close. Presenting again replaces what is on
/// show, which is also what makes the control feel like a viewer rather than
/// like a document being opened.
@MainActor
public final class ContentZoomViewer {
    public static let shared = ContentZoomViewer()

    /// Whether this process can open a window at all.
    ///
    /// A Quick Look extension cannot: it is handed a view inside Finder's own
    /// preview panel, and a window ordered front from there is at best
    /// unexpected. The editor asks this before it draws the control, so a
    /// preview does not show an affordance that would do nothing — a dead
    /// button is worse than no button.
    public static let isAvailable: Bool = !Bundle.main.bundlePath.hasSuffix(".appex")

    private var window: NSWindow?
    private var scrollView: ZoomScrollView?
    private let imageView = NSImageView()
    /// Shown in place of the picture when it cannot be rendered. A label rather
    /// than something drawn in the scroll view: the clip view fills the scroll
    /// view's bounds and paints its background over anything the scroll view
    /// draws itself, so text put there is text nobody sees.
    private let failureLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.alignment = .center
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 4
        return label
    }()

    public init() {}

    /// Where a re-render reads its ink and appearance from.
    ///
    /// A closure rather than two values because the answer can change while
    /// the window is open: the system flips appearance under it, and a bitmap
    /// rendered for light stays black-on-dark after one — the same failure
    /// the editor's fragments carry generation stamps for. The provider lets
    /// ``rerenderForCurrentAppearance()`` ask again at flip time; the editor
    /// answers through its own `resolvedInk`, so there is exactly one place
    /// ink meets an appearance.
    public typealias InkProvider = () -> (textColor: NSColor, dark: Bool)

    /// Opens `block` at viewing size, or reports why it cannot be shown.
    @discardableResult
    public func present(
        _ block: RenderedBlock,
        documentDirectory: URL?,
        textColor: NSColor,
        dark: Bool
    ) -> Bool {
        present(block, documentDirectory: documentDirectory) { (textColor, dark) }
    }

    /// Opens `block` at viewing size, with ink that can be asked again when
    /// the appearance changes underneath an open window.
    @discardableResult
    public func present(
        _ block: RenderedBlock,
        documentDirectory: URL?,
        ink: @escaping InkProvider
    ) -> Bool {
        current = (block, documentDirectory, ink)
        let title = ZoomedContent.title(for: block)
        let (textColor, dark) = ink()
        switch ZoomedContent.render(
            block, documentDirectory: documentDirectory, textColor: textColor, dark: dark)
        {
        case .success(let content):
            show(content, title: title)
            return true
        case .failure(let failure):
            // Never a blank window: the block rendered at reading size, so if
            // it cannot render at viewing size the reader is owed the reason
            // rather than an empty frame.
            show(failure: failure, title: title)
            return false
        }
    }

    /// What is on show, so an appearance change under an open window can
    /// render it again.
    private var current: (
        block: RenderedBlock, directory: URL?, ink: InkProvider
    )?

    /// Re-renders what is on show for the appearance the window now has.
    ///
    /// Called from the scroll view's appearance hook. Failure keeps the old
    /// picture on screen — a stale-but-visible diagram beats a blank window,
    /// and the reader can always close and reopen.
    private func rerenderForCurrentAppearance() {
        guard isPresented, let current else { return }
        let (textColor, dark) = current.ink()
        switch ZoomedContent.render(
            current.block, documentDirectory: current.directory,
            textColor: textColor, dark: dark)
        {
        case .success(let content) where content.cgImage != nil:
            swapImage(to: content)
        default:
            break
        }
    }

    /// Swaps the bitmap without disturbing zoom or reading position.
    ///
    /// Heights are stable across an appearance change — the same typeset
    /// metrics, different ink — so magnification carries over untouched.
    private func swapImage(to content: RenderedContent) {
        let oldFrame = imageView.frame
        let magnification = scrollView?.magnification
        let offset = scrollView?.contentView.bounds.origin

        imageView.image = content.image
        imageView.frame = CGRect(origin: .zero, size: content.size)

        if content.size != oldFrame.size {
            // Only where the picture itself changed size does the fit need
            // rethinking; same-size swaps keep whatever the reader had.
            scrollView?.documentView = imageView
            if let magnification { scrollView?.magnification = magnification }
        } else if let offset, let scrollView {
            scrollView.contentView.scroll(to: offset)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        contentSize = content.size
    }

    /// Closes the viewer, if it is open.
    public func dismiss() {
        window?.close()
    }

    /// Whether the viewer is on screen.
    public var isPresented: Bool { window?.isVisible ?? false }

    /// The size of what is currently on show, for tests and for sizing.
    private(set) var contentSize: CGSize = .zero

    /// The bitmap on show, for tests.
    var shownImageForTesting: NSImage? { imageView.image }

    /// The appearance the viewer window currently resolves to, for tests.
    var effectiveAppearanceForTesting: NSAppearance? { scrollView?.effectiveAppearance }

    private func show(_ content: RenderedContent, title: String) {
        let host = prepareWindow(titled: title)
        contentSize = content.size

        imageView.image = content.image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.frame = CGRect(origin: .zero, size: content.size)
        scrollView?.documentView = imageView

        host.setContentSize(Self.windowSize(for: content.size, on: host.screen))
        host.center()
        fitToWindow()
        present(host)
    }

    private func show(failure: RenderFailure, title: String) {
        let host = prepareWindow(titled: title)
        contentSize = .zero
        failureLabel.stringValue = failure.reason
        failureLabel.frame = CGRect(x: 0, y: 0, width: 380, height: 120)
        scrollView?.magnification = 1
        scrollView?.documentView = failureLabel
        host.setContentSize(CGSize(width: 420, height: 160))
        host.center()
        present(host)
    }

    private func present(_ host: NSWindow) {
        host.makeKeyAndOrderFront(nil)
        if let scrollView { host.makeFirstResponder(scrollView) }
        NSApp?.activate()
    }

    /// Scales the content to fit the window, as it is first shown.
    private func fitToWindow() {
        guard let scrollView, scrollView.documentView != nil else { return }
        let magnification = ZoomedContent.fitMagnification(
            content: contentSize, viewport: scrollView.contentSize)
        scrollView.magnification = magnification
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// The window, built on first use and reused after that.
    private func prepareWindow(titled title: String) -> NSWindow {
        if let window {
            window.title = title
            return window
        }

        let scroll = ZoomScrollView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        // The scroll view owns zooming: pinch, smart-magnify, and the
        // magnification bounds are all AppKit's, and a hand-rolled transform
        // beside them would be a second answer to the same question.
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.05
        scroll.maxMagnification = 12

        let host = NSWindow(
            contentRect: scroll.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        host.title = title
        // The window outlives being closed, because the viewer is reused;
        // without this AppKit deallocates it on close and the next present
        // resurrects a freed window.
        host.isReleasedWhenClosed = false
        host.contentView = scroll
        host.tabbingMode = .disallowed

        scroll.onClose = { [weak host] in host?.close() }
        scroll.onFit = { [weak self] in self?.fitToWindow() }
        scroll.onAppearanceChange = { [weak self] in
            self?.rerenderForCurrentAppearance()
        }

        window = host
        scrollView = scroll
        return host
    }

    /// A window big enough to show `content` without covering the screen.
    static func windowSize(for content: CGSize, on screen: NSScreen?) -> CGSize {
        let visible = (screen ?? NSScreen.main)?.visibleFrame.size
            ?? CGSize(width: 1440, height: 900)
        let width = min(max(content.width + 40, 360), visible.width * 0.85)
        let height = min(max(content.height + 40, 260), visible.height * 0.85)
        return CGSize(width: width.rounded(), height: height.rounded())
    }
}

/// The scroll view the zoomed content sits in.
///
/// Subclassed for two things AppKit will not do on its own: the keyboard, since
/// a window with no text field and no menu of its own receives nothing, and the
/// explanation drawn when there is no picture to show.
final class ZoomScrollView: NSScrollView {
    var onClose: (() -> Void)?
    var onFit: (() -> Void)?
    /// Fired when the appearance this window resolves to has changed, so the
    /// bitmap on show can be rendered again for it.
    var onAppearanceChange: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    override func keyDown(with event: NSEvent) {
        guard handle(event.charactersIgnoringModifiers) else {
            super.keyDown(with: event)
            return
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        if event.charactersIgnoringModifiers == "w" {
            onClose?()
            return true
        }
        return handle(event.charactersIgnoringModifiers)
    }

    /// The viewer's whole keyboard, in one place.
    ///
    /// Accepted with and without ⌘: there is nothing here to type into, so a
    /// bare `+` can only mean zoom.
    private func handle(_ characters: String?) -> Bool {
        switch characters {
        case "\u{1b}":
            onClose?()
        case "0":
            onFit?()
        case "1":
            zoom(to: 1)
        case "+", "=":
            zoom(to: magnification * 1.25)
        case "-", "_":
            zoom(to: magnification * 0.8)
        default:
            return false
        }
        return true
    }

    private func zoom(to magnification: CGFloat) {
        let clamped = min(max(magnification, minMagnification), maxMagnification)
        let centre = CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        setMagnification(clamped, centeredAt: centre)
    }
}
