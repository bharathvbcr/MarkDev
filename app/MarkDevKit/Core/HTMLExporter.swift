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

    public static func render(markdown: String, title: String) throws -> String {
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

        #if canImport(CMarkDev)
            let handle = source.withUnsafeBufferPointer { sourceBuffer in
                titleBytes.withUnsafeBufferPointer { titleBuffer in
                    md_html_render(
                        sourceBuffer.baseAddress, UInt(sourceBuffer.count),
                        titleBuffer.baseAddress, UInt(titleBuffer.count))
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
    public static func write(markdown: String, title: String, to destination: URL) throws {
        guard destination.isFileURL else {
            throw HTMLExporterError.unsupportedLocation(destination)
        }
        let output = try render(markdown: markdown, title: title)
        try output.write(to: destination, atomically: true, encoding: .utf8)
    }
}
