//
//  BoundedSVGValidator.swift
//  MarkDevKit
//
//  Non-networking SVG identification and strict imported-asset validation.
//

import Foundation

/// Vector formats that MarkDev can render at a caller-selected size.
///
/// This is the shared filename boundary for ingestion and rendering. Keeping
/// the byte ceiling here prevents PDF from accidentally taking the raster
/// reader's much larger allowance while SVG takes the intended vector limit.
enum BoundedVectorImageFormat {
    case svg
    case pdf

    static let maximumBytes = 1_048_576

    init?(filenameExtension: String) {
        switch filenameExtension.lowercased() {
        case "svg": self = .svg
        case "pdf": self = .pdf
        default: return nil
        }
    }
}

enum BoundedSVGValidator {
    private static let svgNamespace = "http://www.w3.org/2000/svg"
    static let maximumElements = 16_384
    static let maximumAttributes = 65_536
    static let maximumDepth = 128

    /// Full validation for bytes MarkDev is about to copy into a document.
    /// The byte ceiling is checked again here so no future caller can invoke
    /// the XML parser with an unbounded buffer.
    static func validatesImportedAsset(_ data: Data, maximumBytes: Int) -> Bool {
        guard maximumBytes >= 0, data.count <= maximumBytes,
            let text = decodedXML(data)
        else { return false }

        // DTDs and entities are unnecessary for self-contained SVG and are
        // rejected before XMLParser can expand an internal entity graph.
        let folded = text.lowercased()
        guard !folded.contains("<!doctype"), !folded.contains("<!entity") else {
            return false
        }

        let delegate = Delegate(mode: .importedAsset)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        return parser.parse() && delegate.acceptedCompleteDocument
    }

    /// Identifies SVG bytes for the renderer without asking ImageIO, which
    /// reports zero frames for valid SVG on some supported macOS releases.
    /// Parsing aborts at the root element: no descendant, entity reference,
    /// script, or external resource is evaluated here. NSImage remains the
    /// renderer's compatibility/validity authority after this type check.
    static func identifiesSVG(_ data: Data, maximumBytes: Int) -> Bool {
        guard maximumBytes >= 0, data.count <= maximumBytes else { return false }
        let delegate = Delegate(mode: .identifyRootOnly)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        _ = parser.parse()
        return delegate.acceptedRoot
    }

    private static func decodedXML(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(4))
        // XMLParser can accept UTF-32, but the preflight below intentionally
        // supports only encodings it can decode itself. Otherwise a DTD could
        // be invisible to the preflight and reach the framework parser.
        if bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF])
            || bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00])
            || bytes.starts(with: [0x00, 0x00, 0x00, 0x3C])
            || bytes.starts(with: [0x3C, 0x00, 0x00, 0x00])
        {
            return nil
        }
        if bytes.starts(with: [0xFF, 0xFE]) {
            return String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        }
        if bytes.starts(with: [0xFE, 0xFF]) {
            return String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        }
        if bytes.starts(with: [0x3C, 0x00]) {
            return String(data: data, encoding: .utf16LittleEndian)
        }
        if bytes.starts(with: [0x00, 0x3C]) {
            return String(data: data, encoding: .utf16BigEndian)
        }
        return String(data: data, encoding: .utf8)
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        enum Mode { case importedAsset, identifyRootOnly }

        private let mode: Mode
        private var failed = false
        private var depth = 0
        private var elements = 0
        private var attributes = 0
        private(set) var acceptedRoot = false

        var acceptedCompleteDocument: Bool {
            acceptedRoot && !failed && depth == 0
        }

        init(mode: Mode) { self.mode = mode }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String]
        ) {
            guard !failed else { return }
            if elements == 0 {
                acceptedRoot = elementName.lowercased() == "svg"
                    && (namespaceURI == nil || namespaceURI == svgNamespace)
                guard acceptedRoot else {
                    failed = true
                    parser.abortParsing()
                    return
                }
                if mode == .identifyRootOnly {
                    parser.abortParsing()
                    return
                }
            }

            elements += 1
            attributes += attributeDict.count
            depth += 1
            guard elements <= maximumElements,
                attributes <= maximumAttributes,
                depth <= maximumDepth,
                !isActiveElement(elementName),
                attributesAreSelfContained(attributeDict)
            else {
                failed = true
                parser.abortParsing()
                return
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            depth -= 1
            if depth < 0 {
                failed = true
                parser.abortParsing()
            }
        }

        func parser(
            _ parser: XMLParser,
            foundProcessingInstructionWithTarget target: String,
            data: String?
        ) {
            failed = true
            parser.abortParsing()
        }

        func parser(
            _ parser: XMLParser,
            resolveExternalEntityName name: String,
            systemID: String?
        ) -> Data? {
            failed = true
            parser.abortParsing()
            return nil
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            // Imported SVG has no stylesheet text route: <style> is refused,
            // and rejecting @import here also closes parser/framework recovery
            // paths that might surface CSS text outside that element.
            if containsCSSImport(string) {
                failed = true
                parser.abortParsing()
            }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard let text = String(data: CDATABlock, encoding: .utf8),
                !containsCSSImport(text)
            else {
                failed = true
                parser.abortParsing()
                return
            }
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
            if mode == .importedAsset { failed = true }
        }

        private func isActiveElement(_ name: String) -> Bool {
            switch name.lowercased() {
            case "style", "base", "script", "foreignobject", "iframe", "object", "embed",
                "audio", "video", "animate", "animatemotion", "animatetransform", "set",
                "discard":
                true
            default:
                false
            }
        }

        private func attributesAreSelfContained(_ values: [String: String]) -> Bool {
            for (rawName, rawValue) in values {
                let name = rawName.split(separator: ":").last?.lowercased() ?? ""
                let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if name.hasPrefix("on") { return false }
                if name == "base", !value.isEmpty { return false }
                // Inline CSS has its own escape and tokenization grammar. A
                // substring scan cannot prove that a style is self-contained,
                // so imported SVG accepts no nonempty inline style at all.
                if name == "style", !value.isEmpty { return false }
                if name == "href" || name == "src" {
                    guard value.isEmpty || value.hasPrefix("#") else { return false }
                }
                if value.range(of: "url(", options: [.caseInsensitive]) != nil,
                    !fragmentURLsOnly(value)
                {
                    return false
                }
            }
            return true
        }

        private func containsCSSImport(_ value: String) -> Bool {
            value.range(of: "@import", options: [.caseInsensitive]) != nil
        }

        private func fragmentURLsOnly(_ value: String) -> Bool {
            var remainder = value[...]
            while let start = remainder.range(of: "url(", options: [.caseInsensitive]) {
                let afterStart = remainder[start.upperBound...]
                guard let close = afterStart.firstIndex(of: ")") else { return false }
                let target = afterStart[..<close]
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n\"'"))
                guard target.hasPrefix("#") else { return false }
                remainder = afterStart[afterStart.index(after: close)...]
            }
            return true
        }
    }
}
