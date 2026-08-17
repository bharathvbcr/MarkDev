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
    }

    private var cache: [Key: RenderedContent] = [:]
    private var failures: [Key: RenderFailure] = [:]
    private var order: [Key] = []
    /// Bounded: a long document full of diagrams should not pin every bitmap
    /// it has ever scrolled past.
    private let limit = 128

    public init() {}

    /// Discards everything, for a theme or appearance change.
    public func invalidate() {
        cache.removeAll()
        failures.removeAll()
        order.removeAll()
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
            scale: Int(fontSize * 10),
            dark: isDark)
        if let cached = cache[key] { return .success(cached) }
        if let failed = failures[key] { return .failure(failed) }

        // The math font is loaded explicitly rather than relying on
        // SwiftMath's default. That default resolves through `Bundle.module`,
        // which finds nothing when the package is linked into a framework —
        // and a nil font silently typesets to zero size instead of failing.
        guard let font = MTFontManager.manager.latinModernFont(withSize: fontSize) else {
            let failure = RenderFailure(reason: "Math font unavailable")
            failures[key] = failure
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
            failures[key] = failure
            return .failure(failure)
        }

        // `fittingSize`, not `intrinsicContentSize`: SwiftMath overrides the
        // former on macOS and the latter only on iOS, so reading the iOS name
        // here returns NSView's default of zero and every formula looks empty.
        let size = label.fittingSize
        guard size.width > 0, size.height > 0 else {
            let failure = RenderFailure(reason: "Empty formula")
            failures[key] = failure
            return .failure(failure)
        }

        label.frame = CGRect(origin: .zero, size: size)
        guard let rep = label.bitmapImageRepForCachingDisplay(in: label.bounds) else {
            let failure = RenderFailure(reason: "Could not rasterise formula")
            failures[key] = failure
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
    public func diagram(
        _ source: String,
        maxWidth: CGFloat,
        dark: Bool
    ) -> Result<RenderedContent, RenderFailure> {
        let key = Key(kind: "mermaid", source: source, scale: Int(maxWidth), dark: dark)
        if let cached = cache[key] { return .success(cached) }
        if let failed = failures[key] { return .failure(failed) }

        do {
            // The zinc presets are the neutral pair; a themed diagram should
            // sit in the document, not shout a palette of its own.
            let theme: DiagramTheme = dark ? .zincDark : .zincLight
            guard let rendered = try MermaidRenderer.renderImage(source: source, theme: theme) else {
                let failure = RenderFailure(reason: "Unsupported diagram type")
                failures[key] = failure
                return .failure(failure)
            }
            let image = Self.uprighted(rendered) ?? rendered

            var size = image.size
            // Wide graphs are scaled down rather than clipped; a diagram cut
            // off at the column edge is worse than a smaller readable one.
            if size.width > maxWidth, size.width > 0 {
                let scale = maxWidth / size.width
                size = CGSize(width: maxWidth, height: size.height * scale)
            }

            let rendered = RenderedContent(image: image, size: size)
            store(rendered, for: key)
            return .success(rendered)
        } catch {
            let failure = RenderFailure(reason: describe(error))
            failures[key] = failure
            return .failure(failure)
        }
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
        let key = Key(kind: "image", source: source, scale: Int(maxWidth), dark: false)
        if let cached = cache[key] { return .success(cached) }
        if let failed = failures[key] { return .failure(failed) }

        guard let url = resolve(source, relativeTo: base) else {
            let failure = RenderFailure(reason: "Remote images are not loaded")
            failures[key] = failure
            return .failure(failure)
        }
        guard let image = NSImage(contentsOf: url), image.size.width > 0 else {
            let failure = RenderFailure(reason: "Missing image: \(url.lastPathComponent)")
            failures[key] = failure
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
        cache[key] = content
        order.append(key)
        if order.count > limit {
            let evicted = order.removeFirst()
            cache.removeValue(forKey: evicted)
        }
    }

    private var isDark: Bool {
        NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
