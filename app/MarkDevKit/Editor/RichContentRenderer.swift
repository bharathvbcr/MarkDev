//
//  RichContentRenderer.swift
//  MarkDevKit
//
//  Math, diagrams, and images rendered to bitmaps for the editor to draw.
//

import AppKit
import BeautifulMermaid
import SwiftMath
import UniformTypeIdentifiers

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

/// Everything a block's appearance depends on besides the block itself.
///
/// Bundled into one value because the render cache is keyed on all of it: a
/// bitmap made at a different width, appearance, or ink is not the one the
/// caller will ask for, so a prefetch built from a *different* context fills
/// the cache with entries nothing will ever hit. Passing the context around
/// keeps that impossible to get subtly wrong.
public struct RenderContext: Equatable {
    /// The column the content has to fit, in points.
    public let width: CGFloat
    public let dark: Bool
    /// Point size a display formula is typeset at.
    public let mathFontSize: CGFloat
    /// Ink a formula is typeset in.
    public let textColor: NSColor

    public init(width: CGFloat, dark: Bool, mathFontSize: CGFloat, textColor: NSColor) {
        self.width = width
        self.dark = dark
        self.mathFontSize = mathFontSize
        self.textColor = textColor
    }
}

/// One block, and everything needed to draw it.
public struct RenderRequest: Equatable {
    public let block: RenderedBlock
    /// Directory relative image paths resolve against.
    public let directory: URL?
    public let context: RenderContext

    public init(block: RenderedBlock, directory: URL?, context: RenderContext) {
        self.block = block
        self.directory = directory
        self.context = context
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
    /// Where to find the bitmap already made for a vector that proved
    /// expensive to rasterise, by file.
    ///
    /// A *key*, not a bitmap. Holding the picture here would put megapixels
    /// outside the accounting `cachedPixels` does — which is the bug
    /// ``pixelBudget`` was added to fix, reintroduced one layer up. This way
    /// the cache stays the only owner of a bitmap: if the entry has since been
    /// evicted the lookup simply misses, the picture is rasterised again, and
    /// it is measured again.
    private var expensive: [String: Key] = [:]
    private var expensiveOrder: [String] = []
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
    ///
    /// Not private: ``ContentPrefetcher`` sizes its own ceiling as a fraction
    /// of this rather than writing down a second number that can drift out of
    /// step with it. Settable at construction for the same reason — a test
    /// that has to prove what happens at the ceiling should not have to
    /// allocate sixty megapixels to reach it.
    let pixelBudget: Int

    /// What the cache is currently holding, in pixels.
    private(set) var cachedPixels = 0

    public init(
        pixelBudget: Int = 64_000_000,
        expensiveRasterBudget: Duration = .milliseconds(250)
    ) {
        self.pixelBudget = pixelBudget
        self.expensiveRasterBudget = expensiveRasterBudget
    }

    /// Discards everything, for a theme or appearance change.
    public func invalidate() {
        cache.removeAll()
        failures.removeAll()
        order.removeAll()
        failureOrder.removeAll()
        expensive.removeAll()
        expensiveOrder.removeAll()
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

    // MARK: - Rendering one block

    /// Renders whatever `request` describes.
    ///
    /// The single mapping from "a block, here, now" to a render call. Both the
    /// layout fragment that draws a block and the prefetcher that warms it
    /// ahead of the scroll go through this, so the two cannot ask for
    /// different bitmaps of the same thing — which, since the cache is keyed
    /// on exactly these parameters, would mean the prefetch quietly warmed
    /// entries nothing would ever hit.
    public func render(_ request: RenderRequest) -> Result<RenderedContent, RenderFailure> {
        switch request.block.kind {
        case .math:
            return math(
                request.block.source,
                fontSize: request.context.mathFontSize,
                color: request.context.textColor,
                display: true,
                maxWidth: request.context.width)
        case .diagram:
            return diagram(
                request.block.source, maxWidth: request.context.width,
                dark: request.context.dark)
        case .image:
            return image(
                at: request.block.source, relativeTo: request.directory,
                maxWidth: request.context.width, width: request.block.width)
        }
    }

    /// Whether `request` is already answered, without rendering anything.
    ///
    /// A failure counts: it is a decision already taken, and re-taking it is
    /// the work this is asked in order to avoid. Used by the prefetcher to
    /// walk past what the reader has already scrolled through, which is most
    /// of a warm on a document that has been open for a while.
    public func isCached(_ request: RenderRequest) -> Bool {
        let key = key(for: request)
        return cache[key] != nil || failures[key] != nil
    }

    /// The cache key `request` would be answered from.
    private func key(for request: RenderRequest) -> Key {
        switch request.block.kind {
        case .math:
            return key(
                forMath: request.block.source, fontSize: request.context.mathFontSize,
                color: request.context.textColor, display: true,
                maxWidth: request.context.width)
        case .diagram:
            return key(
                forDiagram: request.block.source, maxWidth: request.context.width,
                dark: request.context.dark, scale: Self.rasterScale)
        case .image:
            return key(
                forImage: resolve(request.block.source, relativeTo: request.directory)?.path
                    ?? request.block.source,
                width: Self.boundedWidth(request.context.width, request.block.width))
        }
    }

    // Key builders. Each public render method and ``isCached`` derive their
    // key from the same one: two places assembling a `Key` by hand is how a
    // probe comes to disagree with the store it is probing.

    private func key(
        forMath latex: String, fontSize: CGFloat, color: NSColor, display: Bool,
        maxWidth: CGFloat?
    ) -> Key {
        // The column is part of the key for the same reason it is for a
        // diagram: a formula wider than its column is scaled down to fit, so
        // the same source at two widths draws at two sizes and one bitmap
        // must not be served for both.
        //
        // `dark` is deliberately *not* sampled here. A formula paints no
        // background — its whole appearance-dependence is the ink it is
        // drawn in, which `tint` already carries — and sampling the ambient
        // appearance made the key a function of *when* it was derived:
        // measured in a fresh process, `NSApp`'s effective appearance reads
        // light for the first call and dark for the second, which split one
        // formula into two cache entries and left ``isCached(_:)`` probing
        // beside the entry `render(_:)` had just stored.
        Key(
            kind: display ? "math.display" : "math.inline",
            source: latex,
            scale: Self.bucket(fontSize * 10),
            dark: false,
            raster: Self.bucket(Self.sanitised(maxWidth) ?? 0),
            tint: Self.tint(of: color))
    }

    private func key(
        forDiagram source: String, maxWidth: CGFloat, dark: Bool, scale: CGFloat
    ) -> Key {
        Key(
            kind: "mermaid", source: source, scale: Self.bucket(maxWidth), dark: dark,
            raster: Self.bucket(scale * 10))
    }

    /// - Parameter width: the drawn width from ``boundedWidth(_:_:)``, not the
    ///   raw column. An `<img width=72>` and the same file with no width are
    ///   two different pictures of one file, and in the same column — and a
    ///   vector opened in the viewer is a third, which is what makes this the
    ///   whole of what distinguishes two requests for one file.
    private func key(forImage file: String, width: CGFloat) -> Key {
        Key(kind: "image", source: file, scale: Self.bucket(width), dark: false)
    }

    /// The width an image is drawn at, decided before its file is opened.
    ///
    /// A width asked for — an author's `<img width=…>`, or the viewer opening
    /// a vector — is a request rather than a promise: the column still bounds
    /// it. Nonsense is dropped rather than clamped, so a `width="0"` in a note
    /// means "the file's own size" and not "no picture".
    ///
    /// Derivable from the request alone, which is what lets ``isCached(_:)``
    /// answer without reading the file.
    private static func boundedWidth(_ maxWidth: CGFloat, _ requested: CGFloat?) -> CGFloat {
        guard let requested = sanitised(requested) else { return maxWidth }
        return min(requested, maxWidth)
    }

    /// A caller-supplied width, or `nil` if it cannot mean anything.
    private static func sanitised(_ width: CGFloat?) -> CGFloat? {
        guard let width, isDrawable(width) else { return nil }
        return width
    }

    // MARK: - Math

    /// The most a formula's source may weigh before it is refused, in bytes.
    ///
    /// Typesetting is linear in the source and happens on the main actor,
    /// synchronously, while TextKit builds a fragment — measured here at
    /// roughly 6ms per kilobyte, so a 64KB "formula" costs a third of a
    /// second per layout pass before anything else runs. Real formulas are
    /// tiny: a page of dense mathematics is a few hundred bytes, and even
    /// machine-generated output past 8KB lays out tens of thousands of points
    /// wide — wider than any column, where it was previously clipped at the
    /// view edge anyway. Refusing names the problem; clipping hid it.
    private static let maxMathBytes = 8_192

    /// The deepest brace nesting a formula may reach.
    ///
    /// SwiftMath parses recursively: every group (`{…}`, a `\frac` argument,
    /// a superscript's operand) descends another stack frame in
    /// `MTMathListBuilder.buildInternal`, with no depth limit of its own.
    /// Measured here, a formula nested ~50 script levels deep — about 200
    /// bytes — overflows the stack and takes the *process* down: SIGSEGV on
    /// the guard page, uncatchable, from a note the reader merely opened.
    /// The boundary moves with build configuration and stack state (depth 49
    /// survived where 50 died), which is exactly why the bound sits far below
    /// it rather than at it. Real mathematics nests three or four levels;
    /// thirty is already generous, and KaTeX refuses far sooner than that.
    ///
    /// Depth is what drives both failure modes, not just the crash: nested
    /// `\frac`s also grow superlinearly in time (measured: 56ms at 200 deep,
    /// 774ms at 500). A brace-depth scan is one linear pass over bytes the
    /// renderer was about to walk anyway.
    private static let maxMathDepth = 30

    /// Counts the maximum simultaneous `{…}` nesting of a LaTeX source.
    ///
    /// Braces are the grouping construct every recursive descent follows —
    /// arguments, scripts, environments all arrive through them — so their
    /// nesting is the cheap proxy for the parser's recursion depth. Escaped
    /// braces (`\{`, `\}`) render as literal glyphs rather than opening
    /// groups, so they are skipped; an unterminated `{` still counts to the
    /// end, which only makes the estimate conservative.
    static func nestingDepth(of latex: String) -> Int {
        var depth = 0
        var deepest = 0
        var escaped = false
        for byte in latex.utf8 {
            if escaped {
                escaped = false
                continue
            }
            switch byte {
            case UInt8(ascii: "\\"):
                escaped = true
            case UInt8(ascii: "{"):
                depth += 1
                deepest = max(deepest, depth)
            case UInt8(ascii: "}"):
                depth = max(0, depth - 1)
            default:
                break
            }
        }
        return deepest
    }

    /// Typesets `latex`, inline or display style.
    ///
    /// - Parameter maxWidth: the column the result has to fit, when there is
    ///   one. A formula laid out wider than it is scaled down whole — the same
    ///   bargain diagrams make ("scaled down rather than clipped") — because a
    ///   wide formula drawn at its natural size ran past the view edge and was
    ///   cut off mid-symbol. `nil` draws at natural size, which is what the
    ///   zoom viewer wants; the pixel cap below still applies either way.
    public func math(
        _ latex: String,
        fontSize: CGFloat,
        color: NSColor,
        display: Bool,
        maxWidth: CGFloat? = nil
    ) -> Result<RenderedContent, RenderFailure> {
        let column = Self.sanitised(maxWidth)
        let key = key(
            forMath: latex, fontSize: fontSize, color: color, display: display,
            maxWidth: maxWidth)
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

        // Both structural bounds are checked before SwiftMath sees the source:
        // the parse is where the runaway cost lives, so refusing after it
        // would be paying for the thing being refused.
        guard latex.utf8.count <= Self.maxMathBytes else {
            let kilobytes = Double(latex.utf8.count) / 1_024
            let failure = RenderFailure(
                reason: String(format: "Formula too long (%.1f KB)", kilobytes))
            store(failure, for: key)
            return .failure(failure)
        }
        let depth = Self.nestingDepth(of: latex)
        guard depth <= Self.maxMathDepth else {
            let failure = RenderFailure(reason: "Formula too deeply nested")
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
        var size = label.fittingSize
        guard size.width > 0, size.height > 0 else {
            let failure = RenderFailure(reason: "Empty formula")
            store(failure, for: key)
            return .failure(failure)
        }

        // A formula wider than its column is scaled down whole, aspect ratio
        // intact — the diagram rule. Whatever remains is then bounded by the
        // same drawn-size cap a picture answers to: a formula cannot ask for
        // a fragment taller than the page either.
        if let column, size.width > column {
            let fit = column / size.width
            size = CGSize(width: size.width * fit, height: size.height * fit)
        }
        size = Self.drawable(size)

        // `cacheDisplay` draws the *view*, whose bounds are still zero unless
        // they are set first — measured here as ink compressed into a sliver
        // of the bitmap, which reads as a formula rendered at the wrong size.
        label.frame = CGRect(origin: .zero, size: size)
        guard let rep = Self.rasterise(label, at: size) else {
            let failure = RenderFailure(reason: "Could not rasterise formula")
            store(failure, for: key)
            return .failure(failure)
        }

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        let rendered = RenderedContent(image: image, size: size)
        store(rendered, for: key)
        return .success(rendered)
    }

    /// Draws a typeset formula into a bitmap whose pixel size is chosen here.
    ///
    /// `bitmapImageRepForCachingDisplay(in:)` — the call this replaces —
    /// sized the bitmap by whatever the main screen's backing scale happened
    /// to be, which left the allocation hostage to the display the app was
    /// launched on and unbounded in pixels: measured here, a flat 37KB source
    /// laid out 334,000 points wide and rasterised to 668,296×25 — 16.7
    /// megapixels, past ``maxRasterPixels`` and some 67MB for one line of
    /// symbols. Building the rep explicitly lets ``fittedScale`` cap the
    /// pixels the same way it caps them for diagrams and vectors, and keeps
    /// the Retina detail those paths get.
    private static func rasterise(_ label: MTMathUILabel, at size: CGSize) -> NSBitmapImageRep? {
        guard size.width.isFinite, size.height.isFinite, size.width >= 1, size.height >= 1 else {
            return nil
        }
        let scale = fittedScale(rasterScale, for: size)
        let pixelWidth = max(1, Int((size.width * scale).rounded()))
        let pixelHeight = max(1, Int((size.height * scale).rounded()))
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixelWidth, pixelsHigh: pixelHeight,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        // A hand-built rep defaults to 72dpi, which makes its *point* size its
        // pixel count — twice the view for a Retina-scale bitmap — and
        // `cacheDisplay` then maps the view into the bottom-left quarter.
        // Stating the point size is what tells AppKit the two grids differ.
        rep.size = size
        // `cacheDisplay(in:to:)` maps the view's points onto whatever pixel
        // grid the representation carries, so the formula fills the bitmap
        // whether it asked for one point or four per point.
        label.cacheDisplay(in: CGRect(origin: .zero, size: size), to: rep)
        return rep
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
        let key = key(forDiagram: source, maxWidth: maxWidth, dark: dark, scale: scale)
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

    /// The pixels-per-point a picture `size` points across can be rasterised
    /// at without passing ``maxRasterPixels``.
    ///
    /// Shared by the diagram and the vector-image paths, which have the same
    /// problem: neither has pixels of its own, so both would otherwise
    /// rasterise whatever their layout happens to measure. A nonsense scale
    /// falls back to ``rasterScale`` rather than failing — it reaches this
    /// from a caller-supplied number, and a picture is owed to the reader.
    private static func fittedScale(_ requested: CGFloat, for size: CGSize) -> CGFloat {
        var scale = requested.isFinite && requested >= 1 ? requested : rasterScale
        let pixels = size.width * scale * size.height * scale
        if pixels > maxRasterPixels {
            scale *= (maxRasterPixels / pixels).squareRoot()
        }
        return scale
    }

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

        let scale = Self.fittedScale(requested, for: size)

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
    ///
    /// - Parameters:
    ///   - width: the width to draw at whatever the file's own size — an
    ///     author's `<img width=…>`, or the viewer opening a vector. Bounded
    ///     by `maxWidth`, and ignored when it cannot mean anything. Without
    ///     one the file's own size is used, scaled down to fit.
    public func image(
        at source: String,
        relativeTo base: URL?,
        maxWidth: CGFloat,
        width requested: CGFloat? = nil
    ) -> Result<RenderedContent, RenderFailure> {
        // Keyed on the *resolved file*, not on the reference as written. Two
        // notes in different folders that both say `![](diagram.png)` mean two
        // different pictures, and a key built from the text alone served the
        // first one's bitmap for the second. Warming the notes an open one
        // links to turns that from unlucky into routine: a prefetch fills the
        // cache from directories other than the document's own.
        let url = resolve(source, relativeTo: base)
        let asked = Self.sanitised(requested)
        let bounded = Self.boundedWidth(maxWidth, asked)
        let key = key(forImage: url?.path ?? source, width: bounded)
        if let cached = cache[key] { return .success(cached) }
        if let failed = failures[key] { return .failure(failed) }

        guard Self.isDrawable(bounded) else {
            let failure = RenderFailure(reason: "No room to draw an image")
            store(failure, for: key)
            return .failure(failure)
        }
        guard let url else {
            let failure = RenderFailure(reason: "Remote images are not loaded")
            store(failure, for: key)
            return .failure(failure)
        }

        let scalable = Self.isScalable(url)
        // Weighed before it is opened, because opening it is already most of
        // the cost. See ``maxVectorBytes``.
        if scalable, let oversized = Self.tooLargeToDraw(url) {
            store(oversized, for: key)
            return .failure(oversized)
        }

        guard let image = NSImage(contentsOf: url) else {
            let failure = RenderFailure(reason: "Missing image: \(url.lastPathComponent)")
            store(failure, for: key)
            return .failure(failure)
        }
        // Both dimensions, and both finite: a file NSImage decodes to a zero or
        // NaN size scales to a NaN height, which reaches TextKit as a fragment
        // measurement and brings the layout down a long way from this line.
        guard Self.isDrawable(image.size.width), Self.isDrawable(image.size.height) else {
            let failure = RenderFailure(reason: "Unreadable image: \(url.lastPathComponent)")
            store(failure, for: key)
            return .failure(failure)
        }

        // A width the note asked for is honoured as asked; without one the
        // file's own size stands, scaled down only if it overruns the column.
        // Growing a picture is therefore always something the document said,
        // never something this decided — which is what keeps a small icon
        // small.
        let natural = image.size
        let drawnWidth = asked == nil ? min(natural.width, bounded) : bounded
        let size = Self.drawable(
            CGSize(width: drawnWidth, height: natural.height * (drawnWidth / natural.width)))

        guard scalable else {
            let rendered = RenderedContent(image: image, size: size)
            store(rendered, for: key)
            return .success(rendered)
        }
        return vector(image, at: size, from: url.path, for: key)
    }

    /// Draws a vector at `size`, or serves one already drawn if drawing it
    /// again would cost too much.
    ///
    /// A vector is rasterised at the size it is drawn, not resampled from the
    /// nominal size written in the file: that is what makes an SVG asked for
    /// at twice its nominal width sharp instead of blurred, and it is also
    /// what bounds the bitmap — a 4,000-point viewBox drawn 600 points wide
    /// would otherwise be decoded at its own scale and held at it.
    ///
    /// The exception is the file that proved expensive. Rasterising is
    /// **geometry**-bound, not pixel-bound: a path-dense SVG measured here at
    /// ~2.6ms per kilobyte costs the same second whether it is drawn at 300
    /// points or 3,000. Since a picture is re-rendered whenever the width it
    /// is drawn at changes, and the column changes with every step of a window
    /// resize, that second is otherwise paid again and again — on the main
    /// actor, where it is a stalled app rather than a slow one. So a
    /// rasterisation past ``expensiveRasterBudget`` is kept, and every later
    /// size of that file is served by scaling what is kept.
    ///
    /// That is the one place this deliberately magnifies rather than
    /// re-renders, and the trade is stated plainly: a heavy picture goes
    /// slightly soft when the column changes, instead of freezing the window
    /// every time it does.
    private func vector(
        _ image: NSImage, at size: CGSize, from file: String, for key: Key
    ) -> Result<RenderedContent, RenderFailure> {
        if let already = expensive[file], let kept = cache[already], let bitmap = kept.cgImage {
            let content = RenderedContent(cgImage: bitmap, size: size)
            store(content, for: key)
            return .success(content)
        }

        let clock = ContinuousClock()
        let started = clock.now
        guard let rendered = rasterise(image, at: size) else {
            let failure = RenderFailure(reason: "Could not rasterise image")
            store(failure, for: key)
            return .failure(failure)
        }
        if clock.now - started > expensiveRasterBudget { remember(key, for: file) }

        store(rendered, for: key)
        return .success(rendered)
    }

    /// The most a vector file may weigh before it is refused, in bytes.
    ///
    /// Rasterising one is unbounded work with no cheap way to predict it and
    /// no way to interrupt it: it happens on the main actor, synchronously,
    /// while TextKit builds a fragment. Measured on this machine, path-dense
    /// SVG costs about 2.6ms per kilobyte — 104KB drew in 0.36s and 10MB in
    /// **30 seconds**, which is not a slow app but a hung one.
    ///
    /// Bytes are a poor predictor of drawing cost and the only one available
    /// before drawing. The bound is set where it refuses almost nothing real:
    /// of 400 SVGs found on this machine the median was 1.4KB and the 99th
    /// percentile 315KB, so a megabyte is far out in the tail — and what it
    /// buys is that no note can hang the window for half a minute.
    private static let maxVectorBytes = 1_048_576

    /// A rasterisation slower than this marks its file as expensive to draw.
    ///
    /// Not private, and settable at construction, so a test can prove what
    /// happens past it without needing a fixture slow enough to get there —
    /// which would be a test whose meaning changed with the machine it ran on.
    let expensiveRasterBudget: Duration

    /// Refuses a file too heavy to rasterise, naming what it weighs.
    ///
    /// A file whose size cannot be read is *not* refused: the read is an
    /// optimisation, and failing closed on a stat error would mean a picture
    /// on a volume with awkward permissions silently stopped drawing.
    private static func tooLargeToDraw(_ url: URL) -> RenderFailure? {
        guard let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            bytes > maxVectorBytes
        else { return nil }
        let megabytes = Double(bytes) / 1_048_576
        return RenderFailure(
            reason: String(
                format: "%@ is too large to draw (%.1f MB)", url.lastPathComponent, megabytes))
    }

    /// The most either side of a drawn picture may measure, in points.
    ///
    /// A vector's aspect ratio is whatever its `viewBox` says, so a note can
    /// ask for a picture 100,000 points tall as easily as a square one — and
    /// that measurement is handed to TextKit as a fragment's height. The cap
    /// is far past any real picture: a 900x20,000 pixel screenshot drawn in a
    /// 600-point column comes to 13,333 points and is untouched.
    private static let maxDrawnLength: CGFloat = 20_000

    /// `size` brought back to something that can actually be drawn: never
    /// longer than ``maxDrawnLength`` on a side, and never thinner than a
    /// point.
    ///
    /// The floor is not defensive tidying. A hairline divider is a real thing
    /// to put in a note — a 10,000x1 `viewBox` — and in a 600-point column it
    /// comes to 0.06 points tall, which is a picture no bitmap has a row for.
    /// Refusing it would tell the reader their divider is broken; drawing it
    /// one point tall is what they asked for as nearly as the screen allows.
    /// The shape is kept while it can be, and given up rather than the
    /// picture.
    private static func drawable(_ size: CGSize) -> CGSize {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            return CGSize(width: 1, height: 1)
        }
        let excess = max(size.width, size.height) / maxDrawnLength
        let fitted = excess > 1
            ? CGSize(width: size.width / excess, height: size.height / excess) : size
        return CGSize(width: max(1, fitted.width), height: max(1, fitted.height))
    }

    /// Whether the file `source` names can be drawn at any size without
    /// losing detail.
    ///
    /// An SVG has no pixels of its own — the size in the file is a nominal
    /// one — so it is rasterised at the size it will be drawn. A raster has
    /// pixels, and enlarging them is not detail, which is why the two are
    /// sized by different rules and why ``ContentZoomViewer`` has to ask.
    public func isScalable(at source: String, relativeTo base: URL?) -> Bool {
        guard let url = resolve(source, relativeTo: base) else { return false }
        return Self.isScalable(url)
    }

    /// Read from the file's name rather than its bytes, because this is asked
    /// before anything has been loaded — it decides how a picture is *sized*,
    /// and the size decides the bitmap that is then made.
    ///
    /// The two cannot disagree in a way that matters: `NSImage(contentsOf:)`
    /// resolves a file's type from its extension as well, and measured here,
    /// it declines a file whose extension and content disagree — SVG markup in
    /// a `.png`, and a PNG in a `.svg`, both come back nil. So a mislabelled
    /// file is a clean failure rather than a vector sized as a raster.
    private static func isScalable(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .svg) ?? false
    }

    /// Draws a vector image into a bitmap of its own, at the size it will be
    /// drawn on the page.
    ///
    /// `NSImage` is asked to draw rather than to hand back a `CGImage`:
    /// `cgImage(forProposedRect:)` rasterises at the *display's* backing scale
    /// whatever is asked of it, so the detail a picture is held at would
    /// depend on which screen the app happened to be on.
    /// A vector's detail comes from the size it is laid out at rather than
    /// from a scale of its own: the viewer opens one *larger*, where it opens
    /// a diagram at the same size in more detail. So there is one scale here —
    /// the Retina one — and no knob for a caller to disagree with.
    private func rasterise(_ image: NSImage, at size: CGSize) -> RenderedContent? {
        guard Self.isDrawable(size.width), Self.isDrawable(size.height) else { return nil }

        let scale = Self.fittedScale(Self.rasterScale, for: size)
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

        // Left transparent where the picture does not paint: an SVG with no
        // background of its own belongs on the page, not on a white card.
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        image.draw(
            in: CGRect(x: 0, y: 0, width: CGFloat(pixelWidth), height: CGFloat(pixelHeight)),
            from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        guard let bitmap = context.makeImage() else { return nil }
        return RenderedContent(cgImage: bitmap, size: size)
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

    /// Notes where the bitmap for an expensive file can be found.
    ///
    /// Bounded by count alone, which is all it needs: what is stored is a key,
    /// and the pixels it points at are the cache's and are bounded there.
    /// Dropped wholesale by ``invalidate()``, along with what it points at.
    private func remember(_ key: Key, for file: String) {
        if expensive.updateValue(key, forKey: file) == nil { expensiveOrder.append(file) }
        while expensiveOrder.count > limit {
            expensive.removeValue(forKey: expensiveOrder.removeFirst())
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
}
