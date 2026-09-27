import Foundation

#if canImport(CMarkDev)
    import CMarkDev
#endif

/// Recoverable failures from the bounded Rust HTML renderer.
public enum HTMLExporterError: Error, Equatable, LocalizedError {
    case unsupportedLocation(URL)
    case sourceTooLarge(maximumBytes: Int)
    case titleTooLarge(maximumBytes: Int)
    case renderingFailed
    case invalidRendererOutput

    public var errorDescription: String? {
        switch self {
        case .unsupportedLocation(let url):
            "HTML can only be exported to a file on this Mac, not \(url.scheme ?? "that location")."
        case .sourceTooLarge(let maximumBytes):
            "This note is too large to export safely. The limit is \(maximumBytes / 1_048_576) MiB."
        case .titleTooLarge(let maximumBytes):
            "The export title is too large. The limit is \(maximumBytes / 1_024) KiB."
        case .renderingFailed:
            "MarkDev could not render this note as HTML."
        case .invalidRendererOutput:
            "The HTML renderer returned invalid text."
        }
    }
}

/// One safe export boundary shared by UI actions and tests.
public enum HTMLExporter {
    public static let maximumSourceBytes = MarkdownReadLimits.maximumDocumentBytes
    public static let maximumTitleBytes = 8 * 1_024
    private static let maximumOutputBytes = 64 * 1_024 * 1_024

    /// Renders `markdown` as a standalone, script-free HTML document.
    ///
    /// When `baseDirectory` is the folder the note lives in, local pictures the
    /// note references (SVG, PNG, JPEG, GIF, WebP, AVIF, BMP, ICO) are copied
    /// into the document, so the export displays correctly in any browser and
    /// from any location. Pictures are identified by their bytes; anything
    /// else keeps its original relative destination.
    public static func render(
        markdown: String, title: String, baseDirectory: URL? = nil
    ) throws -> String {
        guard markdown.utf8.count <= maximumSourceBytes else {
            throw HTMLExporterError.sourceTooLarge(maximumBytes: maximumSourceBytes)
        }
        guard title.utf8.count <= maximumTitleBytes else {
            throw HTMLExporterError.titleTooLarge(maximumBytes: maximumTitleBytes)
        }
        // Materialise only after the cheap views prove both buffers are in
        // bounds; otherwise the safety check itself doubles hostile input.
        let source = Array(markdown.utf8)
        let titleBytes = Array(title.utf8)
        // Only a strictly local folder may be read for pictures; anything else
        // renders exactly as an export without a base.
        let basePath: [UInt8] =
            baseDirectory.flatMap { url in
                BoundedRegularFileReader.hasLocalFileAuthority(url)
                    ? Array(url.standardizedFileURL.path.utf8) : nil
            } ?? []

        #if canImport(CMarkDev)
            let handle = source.withUnsafeBufferPointer { sourceBuffer in
                titleBytes.withUnsafeBufferPointer { titleBuffer in
                    basePath.withUnsafeBufferPointer { baseBuffer in
                        md_html_render_with_base(
                            sourceBuffer.baseAddress, UInt(sourceBuffer.count),
                            titleBuffer.baseAddress, UInt(titleBuffer.count),
                            baseBuffer.baseAddress, UInt(baseBuffer.count))
                    }
                }
            }
            guard let handle else { throw HTMLExporterError.renderingFailed }
            defer { md_html_free(handle) }

            var count: UInt = 0
            guard let bytes = md_html_bytes(handle, &count), count <= UInt(maximumOutputBytes) else {
                throw HTMLExporterError.invalidRendererOutput
            }
            guard let output = String(
                bytes: UnsafeBufferPointer(start: bytes, count: Int(count)), encoding: .utf8)
            else {
                throw HTMLExporterError.invalidRendererOutput
            }
            return output
        #else
            throw HTMLExporterError.renderingFailed
        #endif
    }

    /// Renders before opening the destination and then uses Foundation's
    /// atomic sibling-file replacement, so a render or write failure cannot
    /// leave a plausible-looking partial export behind.
    public static func write(
        markdown: String, title: String, baseDirectory: URL? = nil, to destination: URL
    ) throws {
        // `isFileURL` alone is insufficient: Foundation exposes the local
        // path of `file://remote-host/path`, and its write APIs silently use
        // that path while discarding the remote authority. Keep export on the
        // same strict local-file boundary as every document read.
        guard BoundedRegularFileReader.hasLocalFileAuthority(destination) else {
            throw HTMLExporterError.unsupportedLocation(destination)
        }
        let output = try render(markdown: markdown, title: title, baseDirectory: baseDirectory)
        try output.write(to: destination, atomically: true, encoding: .utf8)
    }

    /// Folder that holds browser previews. Each preview gets its own
    /// subfolder so concurrent previews of same-named notes never collide.
    public static var browserPreviewDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkDev Browser Preview", isDirectory: true)
    }

    /// Renders a note into a fresh file under ``browserPreviewDirectory`` and
    /// returns its URL, ready to hand to the default browser.
    ///
    /// Pictures are embedded, so the preview does not depend on its location
    /// relative to the note. Previews older than a day are removed first.
    public static func writeBrowserPreview(
        markdown: String, title: String, baseDirectory: URL?
    ) throws -> URL {
        let fileManager = FileManager.default
        let root = browserPreviewDirectory
        removeStalePreviews(in: root, olderThan: 24 * 60 * 60)
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(
            at: folder, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let destination = folder.appendingPathComponent(
            previewFileName(for: title), isDirectory: false)
        try write(
            markdown: markdown, title: title, baseDirectory: baseDirectory, to: destination)
        return destination
    }

    /// A safe single path component for a preview file, ending in `.html`.
    public static func previewFileName(for title: String) -> String {
        let disallowed = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        let cleaned = title.unicodeScalars
            .map { disallowed.contains($0) ? "-" : String($0) }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = String(cleaned.prefix(120))
        let safe = stem.isEmpty || stem.hasPrefix(".") ? "Document" + stem : stem
        return safe + ".html"
    }

    private static func removeStalePreviews(in root: URL, olderThan age: TimeInterval) {
        let fileManager = FileManager.default
        guard
            let entries = try? fileManager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])
        else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for entry in entries {
            let modified = try? entry.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            if let modified, modified < cutoff {
                try? fileManager.removeItem(at: entry)
            }
        }
    }
}
