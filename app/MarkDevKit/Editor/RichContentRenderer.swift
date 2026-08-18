//
//  RichContentRenderer.swift
//  MarkDevKit
//
//  Math, diagrams, and images rendered to bitmaps for the editor to draw.
//

import AppKit
import BeautifulMermaid
import SwiftMath

/// Something drawn in place of a block's source text.
public struct RenderedContent: @unchecked Sendable {
    public let image: NSImage
    /// Size to draw at, in points.
    public let size: CGSize

    /// A `CGImage` for drawing straight into a `CGContext`.
    ///
    /// Layout fragments draw with Core Graphics, which cannot take an
    /// `NSImage` without going through AppKit's graphics stack — and that is
    /// not safe off the main actor.
    public let cgImage: CGImage?

    public init(image: NSImage, size: CGSize) {
        self.image = image
        self.size = size
        var rect = CGRect(origin: .zero, size: image.size)
        self.cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// Wraps a bitmap that was rasterised directly.
    ///
    /// Going back through `NSImage.cgImage(forProposedRect:)` would ask AppKit
    /// to re-derive a bitmap this initialiser already has, and the orientation
    /// of what comes back is AppKit's business rather than the caller's — for
    /// a picture whose orientation is the whole point, that is worth avoiding.
    public init(cgImage: CGImage, size: CGSize) {
        self.image = NSImage(cgImage: cgImage, size: size)
        self.size = size
        self.cgImage = cgImage
    }
}

/// Why a block could not be rendered.
///
/// Surfaced rather than swallowed: a diagram that silently fails to appear is
/// indistinguishable from one the app does not support, and the reader has no
/// way to tell which.
public struct RenderFailure: Error, Sendable, Equatable {
    public let reason: String
    public init(reason: String) { self.reason = reason }
}

/// Renders LaTeX, Mermaid, and images for the editor.
///
/// Everything is cached by content: the same formula always produces the same
/// bitmap, and typesetting or laying out a graph on every restyle would put
/// that work on the keystroke path.
@MainActor
public final class RichContentRenderer {
    public static let shared = RichContentRenderer()

    private struct Key: Hashable {
        let kind: String
        let source: String
        let scale: Int
        let dark: Bool
        /// How many bitmap pixels per point were asked for.
        ///
        /// Part of the key because it is not derivable from the others: the
        /// same diagram at the same width is a different bitmap at reading
        /// detail and at viewing detail, and without this the viewer would be
        /// served whichever of the two the editor had already cached.
        var raster: Int = 0
        /// The ink the content was drawn with, for the paths that take one.
        ///
        /// A formula is typeset in the colour the caller passes, but the key
        /// used to record only the *ambient* appearance — so two requests for
        /// the same formula in different colours collided, and the second was
        /// served the first one's bitmap. Nothing reaches that today, because
        /// the one caller derives its colour from the same appearance the key
        /// samples. That is a coincidence of the current call site rather than
        /// anything this cache enforces, which is exactly the kind of thing
        /// that stops being true quietly.
        var tint: Int = 0
    }

    /// Packs a colour into a cache key.
    ///
    /// Dynamic colours resolve against the appearance in force, so this reads
    /// the value actually used rather than the catalogue name.
    private static func tint(of color: NSColor) -> Int {
        guard let resolved = color.usingColorSpace(.sRGB) else { return color.hash }
        var packed = 0
        for component in [
            resolved.redComponent, resolved.greenComponent,
            resolved.blueComponent, resolved.alphaComponent,
        ] {
            packed = packed << 8 | Int(min(max((component * 255).rounded(), 0), 255))
        }
        return packed
    }

    private var cache: [Key: RenderedContent] = [:]
    private var failures: [Key: RenderFailure] = [:]
    private var order: [Key] = []
    private var failureOrder: [Key] = []
    /// Bounded: a long document full of diagrams should not pin every bitmap
    /// it has ever scrolled past.
    private let limit = 128

    /// Ceiling on what the cache retains, counted in bitmap pixels.
    ///
    /// A count alone stopped bounding this the moment a caller could ask for
    /// detail as well as size. Reading-size renders are a megapixel or two, so
    /// 128 of them is small; a diagram opened in the zoom viewer is rasterised
    /// up to ``maxRasterPixels``, and 128 of *those* is about 8 GB. The count
    /// still applies — this is the second of two bounds, and whichever binds
    /// first evicts.
    private let pixelBudget = 64_000_000

    /// What the cache is currently holding, in pixels.
    private(set) var cachedPixels = 0

    public init() {}

    /// Discards everything, for a theme or appearance change.
    public func invalidate() {
        cache.removeAll()
        failures.removeAll()
        order.removeAll()
        failureOrder.removeAll()
        cachedPixels = 0
    }

    /// Buckets a measurement for the cache key.
    ///
    /// `Int(_:)` traps on a NaN and on anything past `Int.max`, and every entry
    /// point here derives its key from a caller-supplied `CGFloat` *before* it
    /// validates anything. This is a public surface: a nonsense number has to
    /// come back as a render failure the caller can show, never as a crash.
    private static func bucket(_ value: CGFloat) -> Int {
        guard value.isFinite else { return 0 }
        return Int(min(max(value, -1_000_000), 1_000_000))
    }

    /// Whether a caller-supplied dimension can be drawn at all.
    private static func isDrawable(_ value: CGFloat) -> Bool {
        value.isFinite && value >= 1
    }

    // MARK: - Math

    /// Typesets `latex`, inline or display style.
    public func math(
        _ latex: String,
        fontSize: CGFloat,
        color: NSColor,
        display: Bool
    ) -> Result<RenderedContent, RenderFailure> {
        let key = Key(
            kind: display ? "math.display" : "math.inline",
            source: latex,
            scale: Self.bucket(fontSize * 10),
            dark: isDark,
            tint: Self.tint(of: color))
        if let cached = cache[key] { return .success(cached) }
        if let failed = failures[key] { return .failure(failed) }

        // Checked before the size reaches SwiftMath: a non-finite point size
        // propagates into the label's metrics, and a NaN height handed back to
        // TextKit takes the layout down somewhere far from here.
        guard Self.isDrawable(fontSize), fontSize <= 1_000 else {
            let failure = RenderFailure(reason: "Unusable font size")
            store(failure, for: key)
            return .failure(failure)
        }

        // The math font is loaded explicitly rather than relying on
        // SwiftMath's default. That default resolves through `Bundle.module`,
        // which finds nothing when the package is linked into a framework —
        // and a nil font silently typesets to zero size instead of failing.
        guard let font = MTFontManager.manager.latinModernFont(withSize: fontSize) else {
            let failure = RenderFailure(reason: "Math font unavailable")
            store(failure, for: key)
            return .failure(failure)
        }

        let label = MTMathUILabel()
        label.font = font
        label.latex = latex
        label.fontSize = fontSize
        label.textColor = color
        label.labelMode = display ? .display : .text
        label.textAlignment = .left

        // SwiftMath reports parse errors on the label rather than throwing;
        // an unreported failure would render as a blank gap.
        if let error = label.error {
            let failure = RenderFailure(
                reason: error.localizedDescription.isEmpty
                    ? "Invalid formula" : error.localizedDescription)
            store(failure, for: key)
            return .failure(failure)
        }

        // `fittingSize`, not `intrinsicContentSize`: SwiftMath overrides the
        // former on macOS and the latter only on iOS, so reading the iOS name
        // here returns NSView's default of zero and every formula looks empty.
        let size = label.fittingSize
        guard size.width > 0, size.height > 0 else {
            let failure = RenderFailure(reason: "Empty formula")
            store(failure, for: key)
            return .failure(failure)
        }

        label.frame = CGRect(origin: .zero, size: size)
        guard let rep = label.bitmapImageRepForCachingDisplay(in: label.bounds) else {
            let failure = RenderFailure(reason: "Could not rasterise formula")
            store(failure, for: key)
            return .failure(failure)
        }
        label.cacheDisplay(in: label.bounds, to: rep)

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        let rendered = RenderedContent(image: image, size: size)
        store(rendered, for: key)
        return .success(rendered)
    }

    // MARK: - Diagrams

    /// Renders a Mermaid diagram.
    ///
    /// Unsupported diagram types come back as a failure carrying the reason,
    /// so the editor can show the source with an explanation instead of an
    /// empty space.
    /// - Parameter scale: bitmap pixels per point. The default is enough for a
    ///   Retina display at reading size; the zoom viewer asks for more, because
    ///   a diagram opened large is one the reader is looking *at* rather than
    ///   past. The pixel cap below still applies, so this cannot be used to
    ///   allocate an unbounded bitmap.
    public func diagram(
        _ source: String,
        maxWidth: CGFloat,
        dark: Bool,
        scale: CGFloat = RichContentRenderer.rasterScale
    ) -> Result<RenderedContent, RenderFailure> {
        let key = Key(
            kind: "mermaid", source: source, scale: Self.bucket(maxWidth), dark: dark,
            raster: Self.bucket(scale * 10))
        if let cached = cache[key] { return .success(cached) }
        if let failed = failures[key] { return .failure(failed) }

        guard Self.isDrawable(maxWidth) else {
            let failure = RenderFailure(reason: "No room to draw a diagram")
            store(failure, for: key)
            return .failure(failure)
        }

        do {
            // The zinc presets are the neutral pair; a themed diagram should
            // sit in the document, not shout a palette of its own.
            let theme: DiagramTheme = dark ? .zincDark : .zincLight
            guard let prepared = try MermaidImageRenderer(theme: theme).prepare(from: source)
            else {
                let failure = RenderFailure(reason: "Unsupported diagram type")
                store(failure, for: key)
                return .failure(failure)
            }
            guard let rendered = rasterise(
                prepared, theme: theme, maxWidth: maxWidth, scale: scale)
            else {
                let failure = RenderFailure(reason: "Could not rasterise diagram")
                store(failure, for: key)
                return .failure(failure)
            }

            store(rendered, for: key)
            return .success(rendered)
        } catch {
            let failure = RenderFailure(reason: describe(error))
            store(failure, for: key)
            return .failure(failure)
        }
    }

    /// Rasterised at twice the drawn size, so a diagram is sharp on a Retina
    /// display without the layout fragment having to resample it.
    public static let rasterScale: CGFloat = 2

    /// An upper bound on a diagram's bitmap, in pixels.
    ///
    /// The *drawn* size is bounded by the column, but the layout is not: a
    /// graph with a few hundred nodes lays out thousands of points across, and
    /// rasterising that at full size would allocate hundreds of megabytes for
    /// a picture that is then drawn 600 points wide. Rendering at the size it
    /// will be drawn at costs nothing in quality and bounds the allocation.
    private static let maxRasterPixels: CGFloat = 16_000_000

    /// Draws a laid-out diagram into a bitmap, the right way up.
    ///
    /// BeautifulMermaid's own image path cannot be used here. Its
    /// `DiagramRenderer` draws in a top-left coordinate space — its
    /// documentation says so, and says callers must flip a `CGContext` before
    /// calling it — but on AppKit `MermaidImageRenderer._renderPrepared` never
    /// performs that flip, despite a comment claiming it does. A raw
    /// `CGContext` has its origin at the bottom left, so every diagram it
    /// returns is mirrored top to bottom: a `flowchart TD` renders bottom-up
    /// and the glyphs come out upside down. (The library's `MermaidLayer` and
    /// `MermaidView` paths do flip, so only the image path is affected.)
    ///
    /// Rendering the prepared diagram here rather than flipping the bitmap the
    /// library hands back matters for more than tidiness: a post-flip would
    /// silently invert the picture *again* the day the library is fixed, and
    /// the failure would look exactly like this bug reappearing.
    private func rasterise(
        _ prepared: PreparedDiagram,
        theme: DiagramTheme,
        maxWidth: CGFloat,
        scale requested: CGFloat
    ) -> RenderedContent? {
        let bounds = prepared.bounds
        // A layout can come back degenerate or non-finite from a malformed
        // source; `CGContext` would accept the NaN and paint nothing.
        guard bounds.width.isFinite, bounds.height.isFinite,
            bounds.minX.isFinite, bounds.minY.isFinite,
            bounds.width >= 1, bounds.height >= 1,
            maxWidth.isFinite, maxWidth >= 1
        else { return nil }

        // Wide graphs are scaled down rather than clipped: a diagram cut off
        // at the column edge is worse than a smaller readable one.
        let columnFit = min(1, maxWidth / bounds.width)
        let size = CGSize(width: bounds.width * columnFit, height: bounds.height * columnFit)

        var scale = requested.isFinite && requested >= 1 ? requested : Self.rasterScale
        let pixels = size.width * scale * size.height * scale
        if pixels > Self.maxRasterPixels {
            scale *= (Self.maxRasterPixels / pixels).squareRoot()
        }

        let pixelWidth = Int((size.width * scale).rounded())
        let pixelHeight = Int((size.height * scale).rounded())
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        guard let context = CGContext(
            data: nil, width: pixelWidth, height: pixelHeight,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return nil }

        // The renderer fills `bounds`, which rounding can leave a hair short of
        // the bitmap's edge; an unpainted sliver reads as a torn border.
        if !theme.transparent {
            context.setFillColor(theme.background.cgColor)
            context.fill(
                CGRect(x: 0, y: 0, width: CGFloat(pixelWidth), height: CGFloat(pixelHeight)))
        }

        // Become the top-left space the renderer draws in. Without this the
        // diagram is mirrored top to bottom — which is the bug above.
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: 1, y: -1)

        // Map the layout's bounds exactly onto the bitmap. Deriving the factors
        // from the rounded pixel counts rather than from `scale` keeps the
        // diagram flush with the edges it was measured against.
        context.scaleBy(
            x: CGFloat(pixelWidth) / bounds.width, y: CGFloat(pixelHeight) / bounds.height)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)

        prepared.render(context, bounds)

        guard let image = context.makeImage() else { return nil }
        return RenderedContent(cgImage: image, size: size)
    }

    /// A readable explanation for a diagram error.
    private func describe(_ error: Error) -> String {
        let text = "\(error)"
        if text.lowercased().contains("unsupported") {
            return "Unsupported diagram type"
        }
        return text.count > 120 ? String(text.prefix(120)) + "…" : text
    }

    // MARK: - Images

    /// Loads an embedded image, resolving relative paths against `base`.
    public func image(
        at source: String,
        relativeTo base: URL?,
        maxWidth: CGFloat
    ) -> Result<RenderedContent, RenderFailure> {
        let key = Key(kind: "image", source: source, scale: Self.bucket(maxWidth), dark: false)
        if let cached = cache[key] { return .success(cached) }
        if let failed = failures[key] { return .failure(failed) }

        guard Self.isDrawable(maxWidth) else {
            let failure = RenderFailure(reason: "No room to draw an image")
            store(failure, for: key)
            return .failure(failure)
        }
        guard let url = resolve(source, relativeTo: base) else {
            let failure = RenderFailure(reason: "Remote images are not loaded")
            store(failure, for: key)
            return .failure(failure)
        }
        // Both dimensions, and both finite: a file NSImage decodes to a zero or
        // NaN size scales to a NaN height, which reaches TextKit as a fragment
        // measurement and brings the layout down a long way from this line.
        guard let image = NSImage(contentsOf: url),
            Self.isDrawable(image.size.width), Self.isDrawable(image.size.height)
        else {
            let failure = RenderFailure(reason: "Missing image: \(url.lastPathComponent)")
            store(failure, for: key)
            return .failure(failure)
        }

        var size = image.size
        if size.width > maxWidth {
            size = CGSize(width: maxWidth, height: size.height * (maxWidth / size.width))
        }
        let rendered = RenderedContent(image: image, size: size)
        store(rendered, for: key)
        return .success(rendered)
    }

    /// Resolves an image reference to a local file.
    ///
    /// Only local files load. Fetching remote images from a note would make
    /// opening a document a network request, which is both a privacy leak and
    /// a way for a document to phone home when merely previewed.
    private func resolve(_ source: String, relativeTo base: URL?) -> URL? {
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() {
            return scheme == "file" ? url : nil
        }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed)
        }
        let decoded = trimmed.removingPercentEncoding ?? trimmed
        return base?.appendingPathComponent(decoded)
    }

    // MARK: - Cache

    private func store(_ content: RenderedContent, for key: Key) {
        if let replaced = cache.removeValue(forKey: key) {
            cachedPixels -= Self.pixels(of: replaced)
        } else {
            order.append(key)
        }
        cache[key] = content
        cachedPixels += Self.pixels(of: content)

        // Never past the last entry: one bitmap larger than the whole budget
        // still has to be returned to the caller who just asked for it, and a
        // cache that evicts what it is in the middle of handing back would
        // re-render it on the very next request, forever.
        while order.count > 1, cache.count > limit || cachedPixels > pixelBudget {
            let evicted = order.removeFirst()
            if let content = cache.removeValue(forKey: evicted) {
                cachedPixels -= Self.pixels(of: content)
            }
        }
    }

    /// Remembers a failure, under the same bound as a success.
    ///
    /// Unbounded, this grew with the document rather than with the cache: a
    /// note referencing a thousand missing images recorded a thousand keys
    /// that nothing would ever drop.
    private func store(_ failure: RenderFailure, for key: Key) {
        if failures.updateValue(failure, forKey: key) == nil { failureOrder.append(key) }
        while failureOrder.count > limit {
            failures.removeValue(forKey: failureOrder.removeFirst())
        }
    }

    /// What an entry costs to keep, in bitmap pixels.
    ///
    /// The rasterised size, not the drawn size: the same diagram at the same
    /// width is sixteen times the memory at the viewer's detail as at the
    /// editor's, and it is the bitmap that is being held.
    private static func pixels(of content: RenderedContent) -> Int {
        if let image = content.cgImage { return image.width * image.height }
        let area = content.size.width * content.size.height
        guard area.isFinite, area > 0 else { return 0 }
        return Int(min(area, CGFloat(Int32.max)))
    }

    private var isDark: Bool {
        NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
