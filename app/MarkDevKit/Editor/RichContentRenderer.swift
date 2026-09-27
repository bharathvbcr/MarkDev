//
//  RichContentRenderer.swift
//  MarkDevKit
//
//  Math, diagrams, and images rendered to bitmaps for the editor to draw.
//

import AppKit
import BeautifulMermaid
import ImageIO
import SwiftMath
import UniformTypeIdentifiers

/// Something drawn in place of a block's source text.
public struct RenderedContent: @unchecked Sendable {
    public let image: NSImage
    /// Size to draw at, in points.
    public let size: CGSize
    /// Distance from the bitmap's bottom edge to its typographic baseline.
    /// Present for math, whose visible baseline is not its image edge.
    public let baselineFromBottom: CGFloat?

    /// A `CGImage` for drawing straight into a `CGContext`.
    ///
    /// Layout fragments draw with Core Graphics, which cannot take an
    /// `NSImage` without going through AppKit's graphics stack — and that is
    /// not safe off the main actor.
    public let cgImage: CGImage?

    public init(image: NSImage, size: CGSize, baselineFromBottom: CGFloat? = nil) {
        self.image = image
        self.size = size
        self.baselineFromBottom = baselineFromBottom
        var rect = CGRect(origin: .zero, size: image.size)
        self.cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// Wraps a bitmap that was rasterised directly.
    ///
    /// Going back through `NSImage.cgImage(forProposedRect:)` would ask AppKit
    /// to re-derive a bitmap this initialiser already has, and the orientation
    /// of what comes back is AppKit's business rather than the caller's — for
    /// a picture whose orientation is the whole point, that is worth avoiding.
    public init(cgImage: CGImage, size: CGSize, baselineFromBottom: CGFloat? = nil) {
        self.image = NSImage(cgImage: cgImage, size: size)
        self.size = size
        self.baselineFromBottom = baselineFromBottom
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
    /// Display backing scale factor (e.g. 2.0 on Retina, 1.0 on standard display).
    public let scale: CGFloat

    public init(
        width: CGFloat,
        dark: Bool,
        mathFontSize: CGFloat,
        textColor: NSColor,
        scale: CGFloat = 2.0
    ) {
        self.width = width
        self.dark = dark
        self.mathFontSize = mathFontSize
        self.textColor = textColor
        self.scale = scale
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

    /// An exact, hashable identity for one scalar that influences rendering.
    ///
    /// `CGFloat` is a `Double` on supported macOS targets. Storing its bit
    /// pattern avoids the lossy integer buckets that used to make, for example,
    /// 72.1pt and 72.9pt images share a cache entry even though they were drawn
    /// at different sizes. Non-finite inputs are canonical because every render
    /// path rejects or replaces them before drawing; negative zero is likewise
    /// canonicalised to the zero actually used by arithmetic.
    private enum ScalarKey: Hashable {
        case absent
        case invalid
        case finite(UInt64)
    }

    private struct Key: Hashable {
        let kind: String
        let source: String
        let scale: ScalarKey
        let dark: Bool
        /// Descriptor-derived authority for a file-backed entry. Non-file
        /// renders and request-only failures leave this nil.
        var fileGeneration: BoundedRegularFileGeneration? = nil
        /// Intrinsic and author-requested sizes can have the same request width
        /// before the file is opened but different correct output sizes.
        var explicitImageSize = false
        /// Immutable decoder/admission authority from the requested filename.
        /// The descriptor's canonical pathname can change during a rename and
        /// must not let one format reuse another format's validated entry.
        var imageFormat = ""
        /// How many bitmap pixels per point were asked for.
        ///
        /// Part of the key because it is not derivable from the others: the
        /// same diagram at the same width is a different bitmap at reading
        /// detail and at viewing detail, and without this the viewer would be
        /// served whichever of the two the editor had already cached.
        var raster: ScalarKey = .absent
        /// The ink the content was drawn with, for the paths that take one.
        var tint: Int = 0
        /// Exact display backing scale used to choose the bitmap resolution.
        var backingScale: ScalarKey = .absent
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
    /// SwiftMath's package-global manager is mutable and nonisolated. Keep the
    /// font cache owned by this renderer instead: the renderer is MainActor-
    /// isolated, so every lookup and mutation has one enforced executor.
    private let mathFontManager = MTFontManager()
    /// Where to find the bitmap already made for a vector that proved
    /// expensive to rasterise, by file.
    ///
    /// A *key*, not a bitmap. Holding the picture here would put megapixels
    /// outside the accounting `cachedPixels` does — which is the bug
    /// ``pixelBudget`` was added to fix, reintroduced one layer up. This way
    /// the cache stays the only owner of a bitmap: if the entry has since been
    /// evicted the lookup simply misses, the picture is rasterised again, and
    /// it is measured again.
    private struct FileGenerationKey: Hashable {
        let path: String
        let generation: BoundedRegularFileGeneration
        let format: String
    }

    private var expensive: [FileGenerationKey: Key] = [:]
    private var expensiveOrder: [FileGenerationKey] = []
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

    /// Ceiling for the decoded output retained from one raster image.
    ///
    /// Kept at renderer level so tests can force real 8-, 16-, and 32-bit
    /// images through the downsampling path without allocating a production-
    /// sized fixture. Production construction always uses the 64 MB default.
    let decodedRasterByteBudget: Int

    /// Maximum UTF-8 bytes retained by success and failure cache keys.
    ///
    /// Entry counts alone are not a memory bound when a key owns authored
    /// source. Math and diagram admission cap each individual key; this second
    /// aggregate bound prevents 128 individually-valid sources from retaining
    /// an arbitrarily large multiple of that cap.
    let retainedSourceByteBudget: Int

    private static let maxRetainedSourceBytes = 1 * 1_024 * 1_024
    private(set) var retainedSourceBytes = 0

    /// Opens the descriptor used for an image render. Kept as one injectable
    /// boundary so race tests can deterministically model a pathname rename
    /// between lookup and descriptor identity capture.
    typealias ImageFileOpener = (_ url: URL, _ maximumBytes: Int) throws
        -> BoundedRegularFileLease
    private let imageFileOpener: ImageFileOpener

    /// What the cache is currently holding, in four-byte pixel equivalents.
    private(set) var cachedPixels = 0

    var cacheInventoryForTesting: (
        successes: Int, failures: Int, expensive: Int, retainedSourceBytes: Int
    ) {
        (cache.count, failures.count, expensive.count, retainedSourceBytes)
    }

    public convenience init(
        pixelBudget: Int = 64_000_000,
        expensiveRasterBudget: Duration = .milliseconds(250),
        retainedSourceByteBudget: Int = 1_048_576
    ) {
        self.init(
            pixelBudget: pixelBudget,
            expensiveRasterBudget: expensiveRasterBudget,
            decodedRasterByteBudget: Self.maxDecodedRasterBytes,
            retainedSourceByteBudget: retainedSourceByteBudget,
            imageFileOpener: { url, maximumBytes in
                try BoundedRegularFileReader.open(
                    url,
                    maximumBytes: maximumBytes,
                    cancellationCheck: { false })
            })
    }

    convenience init(
        pixelBudget: Int = 64_000_000,
        expensiveRasterBudget: Duration = .milliseconds(250),
        decodedRasterByteBudget: Int
    ) {
        self.init(
            pixelBudget: pixelBudget,
            expensiveRasterBudget: expensiveRasterBudget,
            decodedRasterByteBudget: decodedRasterByteBudget,
            retainedSourceByteBudget: Self.maxRetainedSourceBytes,
            imageFileOpener: { url, maximumBytes in
                try BoundedRegularFileReader.open(
                    url,
                    maximumBytes: maximumBytes,
                    cancellationCheck: { false })
            })
    }

    init(
        pixelBudget: Int = 64_000_000,
        expensiveRasterBudget: Duration = .milliseconds(250),
        decodedRasterByteBudget: Int = RichContentRenderer.maxDecodedRasterBytes,
        retainedSourceByteBudget: Int = RichContentRenderer.maxRetainedSourceBytes,
        imageFileOpener: @escaping ImageFileOpener
    ) {
        self.pixelBudget = pixelBudget
        self.expensiveRasterBudget = expensiveRasterBudget
        self.decodedRasterByteBudget = decodedRasterByteBudget
        self.retainedSourceByteBudget = max(0, retainedSourceByteBudget)
        self.imageFileOpener = imageFileOpener
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
        retainedSourceBytes = 0
    }

    /// Canonicalises a scalar before it enters a cache key.
    private static func scalarKey(_ value: CGFloat?) -> ScalarKey {
        guard let value else { return .absent }
        guard value.isFinite else { return .invalid }
        let canonical = value == 0 ? 0.0 : Double(value)
        return .finite(canonical.bitPattern)
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
                maxWidth: request.context.width,
                scale: request.context.scale)
        case .diagram:
            return diagram(
                request.block.source, maxWidth: request.context.width,
                dark: request.context.dark,
                scale: request.context.scale)
        case .image:
            return image(
                at: request.block.source, relativeTo: request.directory,
                maxWidth: request.context.width, width: Self.requestedWidth(for: request))
        case .htmlFlow:
            return .failure(
                RenderFailure(reason: "HTML flow is drawn, not rasterised"))
        case .htmlComment:
            return .failure(
                RenderFailure(reason: "HTML comments are hidden, not drawn"))
        }
    }

    /// The width a picture asked for: a point size, or the column when it
    /// said `width="100%"`.
    private static func requestedWidth(for request: RenderRequest) -> CGFloat? {
        request.block.fillsColumn ? request.context.width : request.block.width
    }

    /// Whether `request` is already answered, without rendering anything.
    ///
    /// A failure counts: it is a decision already taken, and re-taking it is
    /// the work this is asked in order to avoid. Used by the prefetcher to
    /// walk past what the reader has already scrolled through, which is most
    /// of a warm on a document that has been open for a while.
    public func isCached(_ request: RenderRequest) -> Bool {
        if case .image = request.block.kind {
            return isImageCached(request)
        }
        guard let key = key(for: request) else { return false }
        return cache[key] != nil || failures[key] != nil
    }

    private func isImageCached(_ request: RenderRequest) -> Bool {
        let url = resolve(request.block.source, relativeTo: request.directory)
        let asked = Self.sanitised(Self.requestedWidth(for: request))
        let bounded = Self.boundedWidth(request.context.width, asked)
        let requestKey = key(
            forImage: url?.path ?? request.block.source,
            width: bounded,
            explicit: asked != nil,
            format: url.map(Self.imageFormatAuthority) ?? "")
        guard Self.isDrawable(bounded), let url else {
            return cache[requestKey] != nil || failures[requestKey] != nil
        }

        let scalable = Self.isScalable(url)
        let maximumBytes = scalable ? Self.maxVectorBytes : Self.maxRasterBytes
        guard let lease = try? imageFileOpener(url, maximumBytes)
        else { return false }
        let key = key(
            forImage: lease.canonicalURL.path,
            width: bounded,
            explicit: asked != nil,
            format: Self.imageFormatAuthority(url),
            generation: lease.generation)
        return cache[key] != nil || failures[key] != nil
    }

    /// The cache key `request` would be answered from.
    private func key(for request: RenderRequest) -> Key? {
        switch request.block.kind {
        case .math:
            guard Self.sourceFits(request.block.source, byteLimit: Self.maxMathBytes)
            else { return nil }
            return key(
                forCanonicalMath: Self.canonicalMathSource(request.block.source),
                fontSize: request.context.mathFontSize,
                color: request.context.textColor, display: true,
                maxWidth: request.context.width, scale: request.context.scale)
        case .diagram:
            guard Self.sourceFits(request.block.source, byteLimit: Self.maxDiagramBytes)
            else { return nil }
            return key(
                forDiagram: request.block.source, maxWidth: request.context.width,
                dark: request.context.dark, scale: request.context.scale)
        case .image:
            let requested = Self.sanitised(Self.requestedWidth(for: request))
            return key(
                forImage: resolve(request.block.source, relativeTo: request.directory)?.path
                    ?? request.block.source,
                width: Self.boundedWidth(
                    request.context.width, requested),
                explicit: requested != nil,
                format: resolve(request.block.source, relativeTo: request.directory)
                    .map(Self.imageFormatAuthority) ?? "")
        case .htmlFlow:
            return Key(
                kind: "htmlFlow", source: request.block.source, scale: .absent, dark: false)
        case .htmlComment:
            return Key(kind: "htmlComment", source: "", scale: .absent, dark: false)
        }
    }

    // Key builders. Each public render method and ``isCached`` derive their
    // key from the same one: two places assembling a `Key` by hand is how a
    // probe comes to disagree with the store it is probing.

    private func key(
        forCanonicalMath source: String, fontSize: CGFloat, color: NSColor, display: Bool,
        maxWidth: CGFloat?, scale: CGFloat = RichContentRenderer.rasterScale
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
            source: source,
            scale: Self.scalarKey(fontSize),
            dark: false,
            raster: Self.scalarKey(Self.sanitised(maxWidth)),
            tint: Self.tint(of: color),
            backingScale: Self.scalarKey(Self.canonicalRasterScale(scale)))
    }

    private func key(
        forDiagram source: String, maxWidth: CGFloat, dark: Bool, scale: CGFloat
    ) -> Key {
        Key(
            kind: "mermaid", source: source, scale: Self.scalarKey(maxWidth), dark: dark,
            raster: Self.scalarKey(Self.canonicalRasterScale(scale)),
            backingScale: Self.scalarKey(Self.canonicalRasterScale(scale)))
    }

    /// - Parameter width: the drawn width from ``boundedWidth(_:_:)``, not the
    ///   raw column. An `<img width=72>` and the same file with no width are
    ///   two different pictures of one file, and in the same column — and a
    ///   vector opened in the viewer is a third, which is what makes this the
    ///   whole of what distinguishes two requests for one file.
    private func key(
        forImage file: String,
        width: CGFloat,
        explicit: Bool,
        format: String,
        generation: BoundedRegularFileGeneration? = nil
    ) -> Key {
        Key(
            kind: "image",
            source: file,
            scale: Self.scalarKey(width),
            dark: false,
            fileGeneration: generation,
            explicitImageSize: explicit,
            imageFormat: format)
    }

    private static func imageFormatAuthority(_ url: URL) -> String {
        url.pathExtension.lowercased()
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

    /// Tests whether a string fits without traversing past the admitted UTF-8
    /// prefix. This ordering matters for attacker-sized inputs: counting the
    /// whole string before refusing it would make the guard itself unbounded.
    private static func sourceFits(_ source: String, byteLimit: Int) -> Bool {
        let bytes = source.utf8
        return bytes.index(
            bytes.startIndex,
            offsetBy: byteLimit + 1,
            limitedBy: bytes.endIndex) == nil
    }

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

    /// The one canonical form of a formula's source: what the cache is keyed
    /// on, and what SwiftMath is actually handed.
    ///
    /// Two rewrites stand between authored Markdown and a drawable formula,
    /// and they compose in one order only. Character references decode first
    /// (``normalisedMathSource``), because a command spelled through them --
    /// `\operatorname&#x7b;ReLU&#x7d;` -- is not yet recognisable as a
    /// command; conventional spellings then map onto SwiftMath's table
    /// (``LaTeXNormalizer``), which tokenises the commands the first pass has
    /// just made visible.
    ///
    /// Both callers go through here rather than normalising for themselves.
    /// That is what makes the two rewrites' shared promise true: keying on the
    /// canonical form is why `\varnothing` and `\emptyset` share one bitmap
    /// instead of keeping two, and it is why ``isCached(_:)`` probes the entry
    /// `math(_:)` stored rather than one beside it.
    static func canonicalMathSource(_ source: String) -> String {
        LaTeXNormalizer.normalize(normalisedMathSource(source))
    }

    /// Decodes the bounded HTML character references generators commonly
    /// leave inside Markdown formula delimiters.
    ///
    /// Markdown resolves `&#x20;` before rendering, while SwiftMath accepts
    /// LaTeX rather than HTML. Passing the source through unchanged turns a
    /// command-terminating space (`\\le&#x20;`) into an invalid formula. This
    /// decoder is intentionally small and single-pass: numeric references and
    /// the six XML/HTML references useful in mathematics are accepted; an
    /// unknown, unterminated, overlong, control, or invalid-scalar reference is
    /// preserved literally so the ordinary visible failure path can explain
    /// it. Raw TeX ampersands, including matrix separators, are untouched.
    static func normalisedMathSource(_ source: String) -> String {
        guard source.contains("&"), source.utf8.count <= maxMathBytes else { return source }

        var output = String()
        output.reserveCapacity(source.utf8.count)
        var cursor = source.startIndex

        while cursor < source.endIndex {
            guard source[cursor] == "&" else {
                output.append(source[cursor])
                cursor = source.index(after: cursor)
                continue
            }

            // Every accepted name fits well inside sixteen characters. The
            // bound prevents one `&` from scanning the rest of an 8KB formula.
            let limit = source.index(cursor, offsetBy: 16, limitedBy: source.endIndex)
                ?? source.endIndex
            let afterAmpersand = source.index(after: cursor)
            guard let semicolon = source[afterAmpersand..<limit].firstIndex(of: ";"),
                let replacement = decodedMathEntity(
                    source[afterAmpersand..<semicolon])
            else {
                output.append("&")
                cursor = afterAmpersand
                continue
            }

            output.append(replacement)
            cursor = source.index(after: semicolon)
        }
        return output
    }

    private static func decodedMathEntity(_ body: Substring) -> String? {
        switch body {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        // A non-breaking distinction has no useful meaning inside a formula;
        // a regular space is the TeX command terminator the source intended.
        case "nbsp": return " "
        default: break
        }

        let digits: Substring
        let radix: Int
        if body.hasPrefix("#x") || body.hasPrefix("#X") {
            digits = body.dropFirst(2)
            radix = 16
        } else if body.hasPrefix("#") {
            digits = body.dropFirst()
            radix = 10
        } else {
            return nil
        }

        guard !digits.isEmpty, digits.count <= 8,
            let value = UInt32(digits, radix: radix),
            value >= 0x20, !(0x7F...0x9F).contains(value),
            let scalar = Unicode.Scalar(value)
        else { return nil }
        return String(scalar)
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
        maxWidth: CGFloat? = nil,
        scale: CGFloat = RichContentRenderer.rasterScale
    ) -> Result<RenderedContent, RenderFailure> {
        // Admission must precede canonicalisation and key construction. Both
        // retain or allocate proportional to source size, which is precisely
        // the work this boundary exists to refuse.
        guard Self.sourceFits(latex, byteLimit: Self.maxMathBytes) else {
            return .failure(
                RenderFailure(reason: "Formula too long (limit 8.0 KB)"))
        }
        let normalised = Self.canonicalMathSource(latex)
        let column = Self.sanitised(maxWidth)
        let key = key(
            forCanonicalMath: normalised,
            fontSize: fontSize,
            color: color,
            display: display,
            maxWidth: maxWidth, scale: scale)
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

        // The remaining structural bound is checked before SwiftMath sees the
        // source: the parse is where the runaway cost lives, so refusing after
        // it would be paying for the thing being refused.
        let depth = Self.nestingDepth(of: normalised)
        guard depth <= Self.maxMathDepth else {
            let failure = RenderFailure(reason: "Formula too deeply nested")
            store(failure, for: key)
            return .failure(failure)
        }

        // The math font is loaded explicitly rather than relying on
        // SwiftMath's default. That default resolves through `Bundle.module`,
        // which finds nothing when the package is linked into a framework —
        // and a nil font silently typesets to zero size instead of failing.
        guard let font = mathFontManager.font(
            withName: "latinmodern-math", size: fontSize)
        else {
            let failure = RenderFailure(reason: "Math font unavailable")
            store(failure, for: key)
            return .failure(failure)
        }

        let label = MTMathUILabel()
        label.font = font
        label.latex = normalised
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
        let naturalSize = label.fittingSize
        guard naturalSize.width > 0, naturalSize.height > 0 else {
            let failure = RenderFailure(reason: "Empty formula")
            store(failure, for: key)
            return .failure(failure)
        }
        // SwiftMath exposes the actual math-list descent. Preserve it before
        // rasterisation: an inline caller must align this baseline with prose,
        // not align either bitmap edge with the surrounding font's descender.
        label.frame = CGRect(origin: .zero, size: naturalSize)
        label.layoutSubtreeIfNeeded()
        guard let display = label.displayList, display.descent.isFinite else {
            let failure = RenderFailure(reason: "Formula baseline unavailable")
            store(failure, for: key)
            return .failure(failure)
        }
        var size = naturalSize

        // A formula wider than its column is scaled down whole, aspect ratio
        // intact — the diagram rule. Whatever remains is then bounded by the
        // same drawn-size cap a picture answers to: a formula cannot ask for
        // a fragment taller than the page either.
        if let column, size.width > column {
            let fit = column / size.width
            size = CGSize(width: size.width * fit, height: size.height * fit)
        }
        size = Self.drawable(size)
        let baselineFromBottom = display.descent * (size.height / naturalSize.height)

        // `cacheDisplay` draws the *view*, whose bounds are still zero unless
        // they are set first — measured here as ink compressed into a sliver
        // of the bitmap, which reads as a formula rendered at the wrong size.
        label.frame = CGRect(origin: .zero, size: size)
        guard let rep = Self.rasterise(label, at: size, scale: scale) else {
            let failure = RenderFailure(reason: "Could not rasterise formula")
            store(failure, for: key)
            return .failure(failure)
        }

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        let rendered = RenderedContent(
            image: image, size: size, baselineFromBottom: baselineFromBottom)
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
    private static func rasterise(
        _ label: MTMathUILabel,
        at size: CGSize,
        scale requestedScale: CGFloat = rasterScale
    ) -> NSBitmapImageRep? {
        guard size.width.isFinite, size.height.isFinite, size.width >= 1, size.height >= 1 else {
            return nil
        }
        guard let pixels = fittedPixelDimensions(for: size, scale: requestedScale)
        else { return nil }
        let pixelWidth = pixels.width
        let pixelHeight = pixels.height
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

    /// Maximum Mermaid source admitted to synchronous parsing and layout.
    ///
    /// Unlike the prefetcher's smaller opportunistic bound, this protects the
    /// on-demand path itself. BeautifulMermaid parses and lays out on the main
    /// actor with no cancellation seam; bounding its input is the only reliable
    /// pre-layout work bound available here.
    private static let maxDiagramBytes = 64 * 1_024

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
        guard Self.sourceFits(source, byteLimit: Self.maxDiagramBytes) else {
            return .failure(
                RenderFailure(reason: "Diagram too long (limit 64.0 KB)"))
        }
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
            // README mermaid writes HTML inside labels; the native renderer
            // paints those tags as text. Sanitize before layout so the
            // picture shows the words GitHub would have formatted. Packing
            // runs after layout: ELK stacks disconnected LR subgraphs into
            // a column, which is not what `flowchart LR` asked for.
            let mermaid = MermaidHTML.sanitized(source)
            let positioned = MermaidSubgraphPack.applied(
                to: try MermaidRenderer.layout(mermaid))
            guard let rendered = rasterise(
                positioned, theme: theme, maxWidth: maxWidth, scale: scale)
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

    /// Highest useful caller-selected density. Production callers use 1–4x;
    /// 8x leaves headroom for export while preventing a hostile finite scale
    /// from forcing every small render up to the full 16-megapixel ceiling.
    private static let maximumRasterScale: CGFloat = 8

    /// Decoded raster storage is bounded as well as pixel count. A high-depth
    /// decoder result can consume more than four bytes per pixel, and row
    /// padding means `width * height` alone is not a memory bound.
    private static let maxDecodedRasterBytes = 64_000_000

    /// The pixels-per-point a picture `size` points across can be rasterised
    /// at without passing ``maxRasterPixels``.
    ///
    /// Shared by the diagram and the vector-image paths, which have the same
    /// problem: neither has pixels of its own, so both would otherwise
    /// rasterise whatever their layout happens to measure. A nonsense scale
    /// falls back to ``rasterScale`` rather than failing — it reaches this
    /// from a caller-supplied number, and a picture is owed to the reader.
    private static func canonicalRasterScale(_ requested: CGFloat) -> CGFloat {
        guard requested.isFinite, requested >= 1 else { return rasterScale }
        // Canonically clamp both rendering and key identity at this ceiling.
        return min(requested, maximumRasterScale)
    }

    private static func fittedScale(_ requested: CGFloat, for size: CGSize) -> CGFloat {
        guard size.width.isFinite, size.height.isFinite,
            size.width > 0, size.height > 0
        else { return 0 }

        let requested = canonicalRasterScale(requested)
        // Divide before multiplying: hostile but finite dimensions or scales
        // must not overflow to infinity and turn the correction into NaN.
        let areaLimit = ((maxRasterPixels / size.width) / size.height).squareRoot()
        let dimensionLimit = maxRasterPixels / max(size.width, size.height)
        let fitted = min(requested, min(areaLimit, dimensionLimit))
        return fitted.isFinite && fitted > 0 ? fitted : 0
    }

    /// Converts fitted point geometry to safe integer bitmap dimensions.
    /// Rounding may put a mathematically capped area a few pixels over its
    /// ceiling, so the larger side is tightened once using integer arithmetic.
    private static func fittedPixelDimensions(
        for size: CGSize,
        scale requested: CGFloat
    ) -> (width: Int, height: Int)? {
        let scale = fittedScale(requested, for: size)
        let rawWidth = (size.width * scale).rounded()
        let rawHeight = (size.height * scale).rounded()
        guard rawWidth.isFinite, rawHeight.isFinite,
            rawWidth >= 0, rawHeight >= 0,
            rawWidth <= maxRasterPixels + 1,
            rawHeight <= maxRasterPixels + 1
        else { return nil }

        var width = max(1, Int(max(0, rawWidth)))
        var height = max(1, Int(max(0, rawHeight)))
        let limit = Int(maxRasterPixels)
        let (area, overflow) = width.multipliedReportingOverflow(by: height)
        if overflow || area > limit {
            if width >= height {
                width = max(1, limit / height)
            } else {
                height = max(1, limit / width)
            }
        }
        return (width, height)
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
    /// Rendering through `DiagramRenderer` here rather than flipping the bitmap
    /// the library's image path hands back matters for more than tidiness: a
    /// post-flip would silently invert the picture *again* the day the library
    /// is fixed, and the failure would look exactly like this bug reappearing.
    /// Going through the positioned graph also lets subgraph packing run
    /// between layout and draw.
    private func rasterise(
        _ positioned: PositionedGraph,
        theme: DiagramTheme,
        maxWidth: CGFloat,
        scale requested: CGFloat
    ) -> RenderedContent? {
        let bounds = CGRect(
            x: 0, y: 0,
            width: max(1, positioned.width),
            height: max(1, positioned.height))
        // A layout can come back degenerate or non-finite from a malformed
        // source; `CGContext` would accept the NaN and paint nothing.
        guard bounds.width.isFinite, bounds.height.isFinite,
            bounds.minX.isFinite, bounds.minY.isFinite,
            bounds.width >= 1, bounds.height >= 1,
            maxWidth.isFinite, maxWidth >= 1
        else { return nil }

        // Wide graphs are scaled down rather than clipped: a diagram cut off
        // at the column edge is worse than a smaller readable one.
        let columnFit = min(
            1,
            min(
                maxWidth / bounds.width,
                Self.maxDrawnLength / max(bounds.width, bounds.height)))
        let size = CGSize(width: bounds.width * columnFit, height: bounds.height * columnFit)

        guard let pixels = Self.fittedPixelDimensions(for: size, scale: requested)
        else { return nil }
        let pixelWidth = pixels.width
        let pixelHeight = pixels.height

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

        DiagramRenderer(theme: theme).render(positioned, in: context, bounds: bounds)

        guard let image = context.makeImage() else { return nil }
        return Self.cropDiagramCanvas(
            image, context: context, background: theme.background.cgColor,
            originalSize: size, originalFit: columnFit, maxWidth: maxWidth)
    }

    /// Removes the layout engine's minimum canvas while retaining a deliberate
    /// 2pt antialiasing guard around the diagram.
    ///
    /// BeautifulMermaid's prepared bounds are a drawing canvas, not the ink's
    /// bounds. Compact graphs routinely arrive with 30–40pt above and below
    /// their nodes; treating that canvas as document content creates blank
    /// bands even after every source line has collapsed correctly. Cropping
    /// the finished raster is authoritative because it includes labels,
    /// strokes, arrowheads, and shadows—the layout model alone does not.
    private static func cropDiagramCanvas(
        _ image: CGImage,
        context: CGContext,
        background: CGColor,
        originalSize: CGSize,
        originalFit: CGFloat,
        maxWidth: CGFloat
    ) -> RenderedContent? {
        guard let data = context.data else { return nil }
        let width = image.width
        let height = image.height
        let bytesPerRow = context.bytesPerRow
        guard width > 0, height > 0, bytesPerRow >= width * 4 else { return nil }

        let colourSpace = CGColorSpaceCreateDeviceRGB()
        let converted = background.converted(
            to: colourSpace, intent: .defaultIntent, options: nil)
        let components = converted?.components ?? background.components ?? []
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat
        if components.count >= 4 {
            red = components[0]
            green = components[1]
            blue = components[2]
            alpha = components[3]
        } else if components.count >= 2 {
            red = components[0]
            green = components[0]
            blue = components[0]
            alpha = components[1]
        } else {
            red = 0
            green = 0
            blue = 0
            alpha = 0
        }
        // The bitmap is premultiplied RGBA.
        let backgroundBytes = (
            Int((red * alpha * 255).rounded()),
            Int((green * alpha * 255).rounded()),
            Int((blue * alpha * 255).rounded()),
            Int((alpha * 255).rounded()))
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1

        for y in 0..<height {
            let row = y * bytesPerRow
            for x in 0..<width {
                let offset = row + x * 4
                let difference =
                    abs(Int(pixels[offset]) - backgroundBytes.0)
                    + abs(Int(pixels[offset + 1]) - backgroundBytes.1)
                    + abs(Int(pixels[offset + 2]) - backgroundBytes.2)
                    + abs(Int(pixels[offset + 3]) - backgroundBytes.3)
                guard difference > 16 else { continue }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        // A supported parse that paints no distinguishable content is a
        // rendering failure, not a successful blank panel.
        guard maxX >= minX, maxY >= minY else { return nil }

        let pointsPerPixelX = originalSize.width / CGFloat(width)
        let pointsPerPixelY = originalSize.height / CGFloat(height)
        // Page-level breathing room belongs to the layout fragment. Keeping
        // it here as well double-counts the gap; these two points exist only
        // so a faint shadow or antialiased stroke is never cut at the crop.
        let paddingX = max(1, Int((2 / pointsPerPixelX).rounded(.up)))
        let paddingY = max(1, Int((2 / pointsPerPixelY).rounded(.up)))
        let left = max(0, minX - paddingX)
        let top = max(0, minY - paddingY)
        let right = min(width - 1, maxX + paddingX)
        let bottom = min(height - 1, maxY + paddingY)
        let crop = CGRect(
            x: left, y: top,
            width: right - left + 1, height: bottom - top + 1)
        guard let cropped = image.cropping(to: crop) else { return nil }
        // Fit the *ink* to the column, not the larger canvas it arrived in.
        // Otherwise a graph whose prepared canvas is 400pt but whose visible
        // content is 383pt is unnecessarily left 17pt shy of a 400pt column.
        // Quantising the natural point size also makes logical geometry
        // independent of whether the reader requested a 2x or 4x raster:
        // antialiasing can move the detected edge by one pixel, but zooming
        // must add detail rather than subtly resize the graph.
        let safeFit = max(originalFit, .leastNonzeroMagnitude)
        let naturalWidth = CGFloat(cropped.width) * pointsPerPixelX / safeFit
        let naturalHeight = CGFloat(cropped.height) * pointsPerPixelY / safeFit
        let inkFit = min(1, maxWidth / naturalWidth)
        let fittedWidth = naturalWidth * inkFit
        let fittedHeight = naturalHeight * inkFit
        let croppedSize = CGSize(
            width: inkFit < 1 ? maxWidth : ceil(fittedWidth),
            height: ceil(fittedHeight))
        return RenderedContent(cgImage: cropped, size: croppedSize)
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
        let requestKey = key(
            forImage: url?.path ?? source,
            width: bounded,
            explicit: asked != nil,
            format: url.map(Self.imageFormatAuthority) ?? "")

        guard Self.isDrawable(bounded) else {
            let failure = RenderFailure(reason: "No room to draw an image")
            store(failure, for: requestKey)
            return .failure(failure)
        }
        guard let url else {
            let failure = RenderFailure(reason: "Remote images are not loaded")
            store(failure, for: requestKey)
            return .failure(failure)
        }

        // The requested extension is the immutable format authority for this
        // operation. A retained descriptor can acquire a different F_GETPATH
        // spelling during a rename; that spelling identifies the generation,
        // but must never switch byte limits or decoder branches mid-request.
        let scalable = Self.isScalable(url)
        let format = Self.imageFormatAuthority(url)
        let maximumBytes = scalable ? Self.maxVectorBytes : Self.maxRasterBytes
        let lease: BoundedRegularFileLease
        do {
            lease = try imageFileOpener(url, maximumBytes)
        } catch let error as BoundedRegularFileReadError {
            // Path/open failures are transient and have no file generation to
            // bind to. Caching one would hide a file created or replaced later.
            return .failure(
                Self.describeReadFailure(
                    error,
                    filename: url.lastPathComponent,
                    vector: scalable))
        } catch {
            return .failure(
                RenderFailure(reason: "Could not read image: \(url.lastPathComponent)"))
        }

        let openedKey = key(
            forImage: lease.canonicalURL.path,
            width: bounded,
            explicit: asked != nil,
            format: format,
            generation: lease.generation)
        if let cached = cache[openedKey] { return .success(cached) }
        if let failed = failures[openedKey] { return .failure(failed) }

        let snapshot: BoundedRegularFileSnapshot
        do {
            snapshot = try lease.read(cancellationCheck: { false })
        } catch let error as BoundedRegularFileReadError {
            // A changed descriptor is likewise transient. Its original
            // generation must not acquire a stable failure for a torn read.
            return .failure(
                Self.describeReadFailure(
                    error,
                    filename: url.lastPathComponent,
                    vector: scalable))
        } catch {
            return .failure(
                RenderFailure(reason: "Could not read image: \(url.lastPathComponent)"))
        }

        let key = key(
            forImage: snapshot.canonicalURL.path,
            width: bounded,
            explicit: asked != nil,
            format: format,
            generation: snapshot.generation)
        if key != openedKey {
            if let cached = cache[key] { return .success(cached) }
            if let failed = failures[key] { return .failure(failed) }
        }

        guard Self.detectedType(in: snapshot.data, matches: url) else {
            let failure = RenderFailure(reason: "Unreadable image: \(url.lastPathComponent)")
            store(failure, for: key)
            return .failure(failure)
        }

        if !scalable {
            return raster(
                snapshot.data,
                from: snapshot.canonicalURL,
                boundedWidth: bounded,
                requestedWidth: asked,
                key: key)
        }

        guard let image = NSImage(data: snapshot.data) else {
            let failure = RenderFailure(reason: "Unreadable image: \(url.lastPathComponent)")
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

        return vector(
            image,
            at: size,
            from: FileGenerationKey(
                path: snapshot.canonicalURL.path,
                generation: snapshot.generation,
                format: format),
            for: key)
    }

    /// Requests the first raster frame only after its declared output cost has
    /// been admitted. Creating an `NSImage` first is too late: several formats
    /// defer decoding until size or CGImage access, and either access can retain
    /// a decompressed bitmap before a caller sees its bounds. This bounds the
    /// requested and retained decoded output; ImageIO's internal scratch space
    /// and the process's peak RSS remain an operating-system decoder boundary.
    private func raster(
        _ data: Data,
        from url: URL,
        boundedWidth: CGFloat,
        requestedWidth: CGFloat?,
        key: Key
    ) -> Result<RenderedContent, RenderFailure> {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
            CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions)
                as? [CFString: Any],
            let declaredWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value,
            let declaredHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value,
            declaredWidth > 0,
            declaredHeight > 0
        else {
            let failure = RenderFailure(reason: "Unreadable image: \(url.lastPathComponent)")
            store(failure, for: key)
            return .failure(failure)
        }

        guard let thumbnailMaximum = Self.rasterThumbnailMaximumDimension(
            pixelWidth: declaredWidth,
            pixelHeight: declaredHeight,
            depth: (properties[kCGImagePropertyDepth] as? NSNumber)?.int64Value,
            colorModel: properties[kCGImagePropertyColorModel] as? String,
            hasAlpha: (properties[kCGImagePropertyHasAlpha] as? NSNumber)?.boolValue ?? true,
            indexed: (properties[kCGImagePropertyIsIndexed] as? NSNumber)?.boolValue ?? false,
            storageByteLimit: Int64(decodedRasterByteBudget))
        else {
            let failure = RenderFailure(
                reason: "Image is too large to draw: \(url.lastPathComponent)")
            store(failure, for: key)
            return .failure(failure)
        }

        // Asking ImageIO for a transformed thumbnail at the source's admitted
        // maximum dimension applies EXIF orientation while retaining all detail
        // allowed by the decoded-output budget. `ShouldCacheImmediately` makes
        // the returned CGImage own its realized pixels here; the independent
        // postcheck below refuses any output whose actual stride exceeds the
        // budget. Neither option claims to cap ImageIO's transient scratch or
        // the process's peak RSS while the system decoder is running.
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaximum,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldAllowFloat: false,
            kCGImageSourceDecodeRequest: kCGImageSourceDecodeToSDR,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary)
        else {
            let failure = RenderFailure(reason: "Unreadable image: \(url.lastPathComponent)")
            store(failure, for: key)
            return .failure(failure)
        }

        let declaredOrientation =
            (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        let orientation = (1...8).contains(declaredOrientation) ? declaredOrientation : 1
        guard Self.rasterBufferIsAdmitted(
            width: image.width,
            height: image.height,
            bytesPerRow: image.bytesPerRow,
            maximumDimension: thumbnailMaximum,
            storageByteLimit: decodedRasterByteBudget)
        else {
            let failure = RenderFailure(
                reason: "Image is too large to draw: \(url.lastPathComponent)")
            store(failure, for: key)
            return .failure(failure)
        }

        let natural = Self.rasterPointSize(
            pixelWidth: Int(declaredWidth),
            pixelHeight: Int(declaredHeight),
            dpiWidth: (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue,
            dpiHeight: (properties[kCGImagePropertyDPIHeight] as? NSNumber)?.doubleValue,
            orientation: orientation,
            decodedWidth: image.width,
            decodedHeight: image.height)
        guard natural.width.isFinite,
            natural.height.isFinite,
            natural.width > 0,
            natural.height > 0
        else {
            let failure = RenderFailure(reason: "Unreadable image: \(url.lastPathComponent)")
            store(failure, for: key)
            return .failure(failure)
        }
        let drawnWidth = requestedWidth == nil ? min(natural.width, boundedWidth) : boundedWidth
        let size = Self.drawable(
            CGSize(
                width: drawnWidth,
                height: natural.height * (drawnWidth / natural.width)))
        let rendered = RenderedContent(cgImage: image, size: size)
        store(rendered, for: key)
        return .success(rendered)
    }

    /// Returns the greatest square thumbnail dimension admitted by both the
    /// pixel and decoded-row-storage budgets. Factoring this policy keeps its
    /// overflow, metadata, alignment, and maximality contracts independently
    /// testable without asking ImageIO to allocate an enormous fixture.
    static func rasterThumbnailMaximumDimension(
        pixelWidth: Int64,
        pixelHeight: Int64,
        depth: Int64?,
        colorModel: String?,
        hasAlpha: Bool,
        indexed: Bool,
        storageByteLimit: Int64 = Int64(maxDecodedRasterBytes),
        rasterPixelLimit: Int64 = Int64(maxRasterPixels),
        rowAlignment: Int64 = 4_096
    ) -> Int? {
        let (declaredPixels, overflow) = pixelWidth.multipliedReportingOverflow(
            by: pixelHeight)
        guard pixelWidth > 0,
            pixelHeight > 0,
            let depth,
            (1...32).contains(depth),
            let colorModel,
            storageByteLimit > 0,
            rasterPixelLimit > 0,
            rowAlignment > 0,
            !overflow,
            declaredPixels <= rasterPixelLimit
        else { return nil }

        let sourceComponents: Int64
        if colorModel == (kCGImagePropertyColorModelGray as String) {
            sourceComponents = 1
        } else if colorModel == (kCGImagePropertyColorModelRGB as String)
            || colorModel == (kCGImagePropertyColorModelLab as String)
        {
            sourceComponents = 3
        } else if colorModel == (kCGImagePropertyColorModelCMYK as String) {
            sourceComponents = 4
        } else {
            return nil
        }

        // Indexed and low-component sources commonly expand to an RGBA
        // destination. CMYK with alpha can require five components. Use the
        // larger representation to cap the output requested from ImageIO, then
        // verify the realized CGImage's actual row stride after decoding.
        let decodedComponents = max(
            4,
            indexed ? 4 : sourceComponents + (hasAlpha ? 1 : 0))
        let componentBytes = (max(depth, 8) + 7) / 8
        let (bytesPerPixel, bytesPerPixelOverflow) = decodedComponents
            .multipliedReportingOverflow(by: componentBytes)
        guard !bytesPerPixelOverflow else { return nil }

        func admitted(_ dimension: Int64) -> Bool {
            let (squarePixels, squareOverflow) = dimension.multipliedReportingOverflow(
                by: dimension)
            let (rowBytes, rowOverflow) = dimension.multipliedReportingOverflow(
                by: bytesPerPixel)
            let (paddedRow, paddingOverflow) = rowBytes.addingReportingOverflow(
                rowAlignment - 1)
            guard !squareOverflow,
                squarePixels <= rasterPixelLimit,
                !rowOverflow,
                !paddingOverflow
            else { return false }
            let alignedUnits = paddedRow / rowAlignment
            let (alignedRowBytes, alignmentOverflow) = alignedUnits
                .multipliedReportingOverflow(by: rowAlignment)
            let (storageBytes, storageOverflow) = alignedRowBytes
                .multipliedReportingOverflow(by: dimension)
            return !alignmentOverflow
                && !storageOverflow
                && storageBytes <= storageByteLimit
        }

        // Binary search keeps the arithmetic bounded even when hostile
        // metadata supplies dimensions near Int64.max.
        var lower: Int64 = 1
        var upper = min(max(pixelWidth, pixelHeight), rasterPixelLimit)
        var result: Int64 = 0
        while lower <= upper {
            let middle = lower + (upper - lower) / 2
            if admitted(middle) {
                result = middle
                lower = middle + 1
            } else {
                upper = middle - 1
            }
        }
        guard result > 0, result <= Int64(Int.max) else { return nil }
        return Int(result)
    }

    /// Verifies the decoder's realized storage independently of its declared
    /// metadata. ImageIO remains a trust boundary: dimensions, row stride, and
    /// both products must all stay inside the pre-established ceilings.
    static func rasterBufferIsAdmitted(
        width: Int,
        height: Int,
        bytesPerRow: Int,
        maximumDimension: Int,
        rasterPixelLimit: Int = Int(maxRasterPixels),
        storageByteLimit: Int = maxDecodedRasterBytes
    ) -> Bool {
        guard width > 0,
            height > 0,
            bytesPerRow > 0,
            maximumDimension > 0,
            width <= maximumDimension,
            height <= maximumDimension,
            rasterPixelLimit > 0,
            storageByteLimit > 0
        else { return false }
        let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (storage, storageOverflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        return !pixelOverflow
            && pixels <= rasterPixelLimit
            && !storageOverflow
            && storage <= storageByteLimit
    }

    /// Converts admitted physical pixels into AppKit points. DPI is accepted
    /// only as a valid pair; half-corrupt metadata falls back without warping
    /// one axis. EXIF transforms across the diagonal swap the logical axes.
    static func rasterPointSize(
        pixelWidth: Int,
        pixelHeight: Int,
        dpiWidth: Double?,
        dpiHeight: Double?,
        orientation: UInt32,
        decodedWidth: Int? = nil,
        decodedHeight: Int? = nil
    ) -> CGSize {
        let swapsAxes = (5...8).contains(Int(orientation))
        let orientedPixels = swapsAxes
            ? CGSize(width: CGFloat(pixelHeight), height: CGFloat(pixelWidth))
            : CGSize(width: CGFloat(pixelWidth), height: CGFloat(pixelHeight))
        let hasValidDPI = dpiWidth?.isFinite == true
            && dpiHeight?.isFinite == true
            && (dpiWidth ?? 0) > 0
            && (dpiHeight ?? 0) > 0

        guard hasValidDPI, let dpiWidth, let dpiHeight else {
            guard let decodedWidth,
                let decodedHeight,
                decodedWidth > 0,
                decodedHeight > 0
            else { return orientedPixels }
            let decoded = CGSize(width: CGFloat(decodedWidth), height: CGFloat(decodedHeight))
            let scale = max(orientedPixels.width, orientedPixels.height)
                / max(decoded.width, decoded.height)
            let transformed = CGSize(
                width: decoded.width * scale,
                height: decoded.height * scale)
            return transformed.width.isFinite && transformed.height.isFinite
                ? transformed : orientedPixels
        }

        func points(_ pixels: Int, _ dpi: Double) -> CGFloat {
            let value = CGFloat(pixels) * 72 / CGFloat(dpi)
            return value.isFinite && value > 0 ? value : CGFloat(pixels)
        }

        let raw = CGSize(
            width: points(pixelWidth, dpiWidth),
            height: points(pixelHeight, dpiHeight))
        return swapsAxes ? CGSize(width: raw.height, height: raw.width) : raw
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
        _ image: NSImage, at size: CGSize, from file: FileGenerationKey, for key: Key
    ) -> Result<RenderedContent, RenderFailure> {
        if let already = expensive[file], let kept = cache[already], let bitmap = kept.cgImage {
            if already == key { return .success(kept) }

            let content = RenderedContent(cgImage: bitmap, size: size)
            // Move the one cache-owned bitmap to the new logical-size key.
            // The CGImage allocation is unchanged, so its pixel charge is too.
            cache.removeValue(forKey: already)
            cache[key] = content
            if let index = order.firstIndex(of: already) {
                order[index] = key
            } else {
                order.append(key)
            }
            subtractRetainedSourceBytes(Self.sourceBytes(of: already))
            addRetainedSourceBytes(Self.sourceBytes(of: key))
            expensive[file] = key
            enforceRetainedSourceBudget(protecting: key)
            if cache[key] == nil {
                expensive.removeValue(forKey: file)
                if let index = expensiveOrder.firstIndex(of: file) {
                    expensiveOrder.remove(at: index)
                }
            }
            return .success(content)
        }

        let clock = ContinuousClock()
        let started = clock.now
        guard let rendered = rasterise(image, at: size) else {
            let failure = RenderFailure(reason: "Could not rasterise image")
            store(failure, for: key)
            return .failure(failure)
        }
        // `.zero` is the deterministic test/diagnostic sentinel: even a clock
        // whose resolution reports a zero-length render must take the expensive
        // reuse path. Positive production budgets retain their measured rule.
        store(rendered, for: key)
        if (expensiveRasterBudget == .zero || clock.now - started > expensiveRasterBudget),
            cache[key] != nil
        {
            remember(key, for: file)
        }
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
    private static let maxVectorBytes = BoundedVectorImageFormat.maximumBytes

    /// Compressed raster input is bounded separately from its decompressed
    /// pixel count. This is intentionally much larger than the vector ceiling:
    /// file bytes predict vector geometry cost, while pixels and row stride
    /// predict retained raster output. The compressed input and requested and
    /// realized output are bounded; ImageIO scratch allocations and peak RSS
    /// inside the operating-system decoder are not hard-bounded here.
    private static let maxRasterBytes = 64 * 1_024 * 1_024

    /// A rasterisation slower than this marks its file as expensive to draw.
    ///
    /// Not private, and settable at construction, so a test can prove what
    /// happens past it without needing a fixture slow enough to get there —
    /// which would be a test whose meaning changed with the machine it ran on.
    let expensiveRasterBudget: Duration

    private static func describeReadFailure(
        _ error: BoundedRegularFileReadError,
        filename: String,
        vector: Bool
    ) -> RenderFailure {
        switch error {
        case .tooLarge(let maximumBytes):
            let megabytes = Double(maximumBytes) / 1_048_576
            let kind = vector ? "draw" : "load"
            return RenderFailure(
                reason: String(
                    format: "%@ is too large to %@ (limit %.1f MB)",
                    filename,
                    kind,
                    megabytes))
        case .notFileURL, .notRegularFile:
            return RenderFailure(reason: "Not a regular image: \(filename)")
        case .changedDuringRead:
            return RenderFailure(reason: "Image changed while reading: \(filename)")
        case .invalidLimit, .systemCall:
            return RenderFailure(reason: "Could not read image: \(filename)")
        }
    }

    private static func detectedType(in data: Data, matches url: URL) -> Bool {
        let vector = BoundedVectorImageFormat(filenameExtension: url.pathExtension)
        if vector == .svg {
            return BoundedSVGValidator.identifiesSVG(
                data,
                maximumBytes: maxVectorBytes)
        }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
            let identifier = CGImageSourceGetType(source),
            let detected = UTType(identifier as String),
            let declared = UTType(filenameExtension: url.pathExtension)
        else { return false }
        if vector == .pdf {
            return detected == .pdf && declared == .pdf
        }
        return detected == declared
            || detected.conforms(to: declared)
            || declared.conforms(to: detected)
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
    /// SVG and PDF have no fixed raster pixels — their declared size is a
    /// nominal one — so they are rasterised at the size they will be drawn.
    /// A raster has pixels, and enlarging them is not detail, which is why the two are
    /// sized by different rules and why ``ContentZoomViewer`` has to ask.
    public func isScalable(at source: String, relativeTo base: URL?) -> Bool {
        guard let url = resolve(source, relativeTo: base) else { return false }
        return Self.isScalable(url)
    }

    /// Read from the file's name rather than its bytes, because this is asked
    /// before anything has been loaded — it decides how a picture is *sized*,
    /// and the size decides the bitmap that is then made.
    ///
    /// The decoder's detected UTI is checked against this extension before
    /// either raster or vector rendering begins. A mislabelled file is thus a
    /// clean failure rather than a vector sized as a raster (or the reverse).
    private static func isScalable(_ url: URL) -> Bool {
        BoundedVectorImageFormat(filenameExtension: url.pathExtension) != nil
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

        guard let pixels = Self.fittedPixelDimensions(for: size, scale: Self.rasterScale)
        else { return nil }
        let pixelWidth = pixels.width
        let pixelHeight = pixels.height

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
        let decoded = trimmed.removingPercentEncoding ?? trimmed

        // Decode exactly once before classifying path syntax. Otherwise an
        // encoded `//host/path` crosses the remote boundary as a local path.
        // A trailing slash is directory intent and must not be standardized
        // into the pathname of a cached regular file.
        if decoded.hasPrefix("//") || decoded.hasSuffix("/") { return nil }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), !scheme.isEmpty {
            guard scheme == "file",
                BoundedRegularFileReader.hasLocalFileAuthority(url),
                !url.hasDirectoryPath
            else { return nil }
            return BoundedRegularFileReader.replacingSystemCompatibilityAlias(in: url)
        }
        if decoded.hasPrefix("/") {
            return BoundedRegularFileReader.replacingSystemCompatibilityAlias(
                in: URL(fileURLWithPath: decoded, isDirectory: false).standardizedFileURL)
        }
        guard let base, BoundedRegularFileReader.hasLocalFileAuthority(base) else { return nil }
        // Force a directory URL: `fileURLWithPath:relativeTo:` treats a base
        // without a trailing slash as a *file* and replaces its last
        // component, so `notes/pic.png` became `pic.png` next to `notes`.
        // `appendingPathComponent("../pic.png")` is the other trap — it keeps
        // `../pic.png` as one path component. Joining as a relative file URL
        // against an explicit directory, then standardising, makes `../` a
        // parent and `pic.png` a child.
        let folder = BoundedRegularFileReader.replacingSystemCompatibilityAlias(
            in: URL(fileURLWithPath: base.path, isDirectory: true))
        let candidate = URL(fileURLWithPath: decoded, relativeTo: folder)
            .absoluteURL.standardizedFileURL
        let resolved = BoundedRegularFileReader.replacingSystemCompatibilityAlias(in: candidate)
        if !FileManager.default.fileExists(atPath: resolved.path),
            let found = Self.attachmentFallback(for: decoded, from: folder)
        {
            return BoundedRegularFileReader.replacingSystemCompatibilityAlias(in: found)
        }
        return resolved
    }

    /// Where Obsidian would have put a picture the note names but that is
    /// not beside it.
    ///
    /// Obsidian saves pasted pictures to an attachments folder (or the vault
    /// root) and writes `![[Pasted image.png]]` by name alone, so a note in a
    /// subfolder names a file that lives elsewhere. Looks in the note's
    /// folder and each folder above it — plain, and its `attachments`,
    /// `assets`, `_attachments` or `media` subfolder — stopping at the vault
    /// root (a folder holding `.obsidian` or `.git`) and after eight levels.
    static func attachmentFallback(for relativePath: String, from folder: URL) -> URL? {
        let fileManager = FileManager.default
        func existingFile(_ candidate: URL) -> URL? {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                !isDirectory.boolValue
            else { return nil }
            return candidate
        }
        // Obsidian's own "Default location for new attachments" setting,
        // when the note sits in an Obsidian vault that sets one.
        if let configured = configuredAttachmentFolder(from: folder),
            let found = existingFile(
                URL(fileURLWithPath: relativePath, relativeTo: configured)
                    .absoluteURL.standardizedFileURL)
        {
            return found
        }
        var directory = folder
        for _ in 0...8 {
            for subfolder in ["", "attachments", "Attachments", "assets", "_attachments", "media"] {
                let base =
                    subfolder.isEmpty
                    ? directory : directory.appendingPathComponent(subfolder, isDirectory: true)
                let candidate = URL(fileURLWithPath: relativePath, relativeTo: base)
                    .absoluteURL.standardizedFileURL
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                    !isDirectory.boolValue
                {
                    return candidate
                }
            }
            let isVaultRoot =
                fileManager.fileExists(atPath: directory.appendingPathComponent(".obsidian").path)
                || fileManager.fileExists(atPath: directory.appendingPathComponent(".git").path)
            let parent = directory.deletingLastPathComponent()
            if isVaultRoot || parent.standardizedFileURL.path == directory.standardizedFileURL.path {
                break
            }
            directory = parent
        }
        return nil
    }

    /// The folder `attachmentFolderPath` in the nearest vault's
    /// `.obsidian/app.json` names: `/` is the vault root, `./sub` is relative
    /// to the note's folder, anything else is relative to the vault root.
    static func configuredAttachmentFolder(from folder: URL) -> URL? {
        let fileManager = FileManager.default
        var directory = folder
        for _ in 0...8 {
            let config = directory.appendingPathComponent(".obsidian/app.json")
            if fileManager.fileExists(atPath: config.path) {
                guard
                    let attributes = try? fileManager.attributesOfItem(atPath: config.path),
                    let size = attributes[.size] as? NSNumber, size.intValue <= 256 * 1024,
                    let data = try? Data(contentsOf: config),
                    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let raw = object["attachmentFolderPath"] as? String
                else { return nil }
                let setting = raw.trimmingCharacters(in: .whitespaces)
                guard !setting.isEmpty,
                    !setting.split(separator: "/").contains("..")
                else { return nil }
                if setting == "/" { return directory }
                if setting == "." || setting == "./" { return folder }
                if setting.hasPrefix("./") {
                    return folder.appendingPathComponent(
                        String(setting.dropFirst(2)), isDirectory: true)
                }
                let trimmed = setting.drop(while: { $0 == "/" })
                return directory.appendingPathComponent(String(trimmed), isDirectory: true)
            }
            let parent = directory.deletingLastPathComponent()
            if parent.standardizedFileURL.path == directory.standardizedFileURL.path {
                return nil
            }
            directory = parent
        }
        return nil
    }

    // MARK: - Cache

    private func store(_ content: RenderedContent, for key: Key) {
        let sourceBytes = Self.sourceBytes(of: key)
        guard sourceBytes <= retainedSourceByteBudget else { return }

        if let replaced = cache.removeValue(forKey: key) {
            cachedPixels -= Self.pixels(of: replaced)
        } else {
            order.append(key)
            addRetainedSourceBytes(sourceBytes)
        }
        cache[key] = content
        cachedPixels += Self.pixels(of: content)

        // Never past the last entry: one bitmap larger than the whole budget
        // still has to be returned to the caller who just asked for it, and a
        // cache that evicts what it is in the middle of handing back would
        // re-render it on the very next request, forever.
        while order.count > 1, cache.count > limit || cachedPixels > pixelBudget {
            evictSuccess(at: 0)
        }
        enforceRetainedSourceBudget(protecting: key)
    }

    /// Remembers a failure, under the same bound as a success.
    ///
    /// Unbounded, this grew with the document rather than with the cache: a
    /// note referencing a thousand missing images recorded a thousand keys
    /// that nothing would ever drop.
    private func store(_ failure: RenderFailure, for key: Key) {
        let sourceBytes = Self.sourceBytes(of: key)
        guard sourceBytes <= retainedSourceByteBudget else { return }

        if failures.updateValue(failure, forKey: key) == nil {
            failureOrder.append(key)
            addRetainedSourceBytes(sourceBytes)
        }
        while failureOrder.count > limit {
            evictFailure(at: 0)
        }
        enforceRetainedSourceBudget(protecting: key)
    }

    private static func sourceBytes(of key: Key) -> Int {
        key.source.utf8.count
    }

    private func addRetainedSourceBytes(_ bytes: Int) {
        let (sum, overflow) = retainedSourceBytes.addingReportingOverflow(bytes)
        retainedSourceBytes = overflow ? Int.max : sum
    }

    private func subtractRetainedSourceBytes(_ bytes: Int) {
        retainedSourceBytes = max(0, retainedSourceBytes - min(bytes, retainedSourceBytes))
    }

    /// Applies one aggregate byte ceiling across success and failure keys.
    /// Failures are evicted first because redoing a bounded parse is cheaper
    /// than throwing away an already-realised bitmap. The just-produced answer
    /// is protected when possible; a key larger than the whole budget was
    /// refused before insertion, so removing older entries must make it fit.
    private func enforceRetainedSourceBudget(protecting protected: Key) {
        while retainedSourceBytes > retainedSourceByteBudget {
            if let index = failureOrder.firstIndex(where: { $0 != protected }) {
                evictFailure(at: index)
            } else if let index = order.firstIndex(where: { $0 != protected }) {
                evictSuccess(at: index)
            } else if let index = failureOrder.firstIndex(of: protected) {
                evictFailure(at: index)
            } else if let index = order.firstIndex(of: protected) {
                evictSuccess(at: index)
            } else {
                retainedSourceBytes = 0
            }
        }
    }

    private func evictFailure(at index: Int) {
        let evicted = failureOrder.remove(at: index)
        if failures.removeValue(forKey: evicted) != nil {
            subtractRetainedSourceBytes(Self.sourceBytes(of: evicted))
        }
    }

    private func evictSuccess(at index: Int) {
        let evicted = order.remove(at: index)
        if let content = cache.removeValue(forKey: evicted) {
            cachedPixels -= Self.pixels(of: content)
            subtractRetainedSourceBytes(Self.sourceBytes(of: evicted))
        }
        forgetExpensiveReferences(to: evicted)
    }

    private func forgetExpensiveReferences(to key: Key) {
        let files = expensive.compactMap { file, cachedKey in
            cachedKey == key ? file : nil
        }
        for file in files {
            expensive.removeValue(forKey: file)
            if let index = expensiveOrder.firstIndex(of: file) {
                expensiveOrder.remove(at: index)
            }
        }
    }

    /// Notes where the bitmap for an expensive file can be found.
    ///
    /// Bounded by count alone, which is all it needs: what is stored is a key,
    /// and the pixels it points at are the cache's and are bounded there.
    /// Dropped wholesale by ``invalidate()``, along with what it points at.
    private func remember(_ key: Key, for file: FileGenerationKey) {
        if expensive.updateValue(key, forKey: file) == nil { expensiveOrder.append(file) }
        while expensiveOrder.count > limit {
            expensive.removeValue(forKey: expensiveOrder.removeFirst())
        }
    }

    /// What an entry costs to keep, in four-byte pixel equivalents.
    ///
    /// The rasterised size, not the drawn size: the same diagram at the same
    /// width is sixteen times the memory at the viewer's detail as at the
    /// editor's, and it is the bitmap that is being held. Row storage is also
    /// counted so high-depth images cannot spend more memory than the pixel
    /// ledger reports.
    private static func pixels(of content: RenderedContent) -> Int {
        if let image = content.cgImage {
            let (area, areaOverflow) = image.width.multipliedReportingOverflow(
                by: image.height)
            let (bytes, byteOverflow) = image.bytesPerRow.multipliedReportingOverflow(
                by: image.height)
            guard !areaOverflow, !byteOverflow else { return Int.max }
            let byteEquivalent = bytes / 4 + (bytes.isMultiple(of: 4) ? 0 : 1)
            return max(area, byteEquivalent)
        }
        let area = content.size.width * content.size.height
        guard area.isFinite, area > 0 else { return 0 }
        return Int(min(area, CGFloat(Int32.max)))
    }
}
