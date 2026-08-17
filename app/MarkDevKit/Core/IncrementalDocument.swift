//
//  IncrementalDocument.swift
//  MarkDevKit
//
//  Swift owner of a Rust `Document`, which skips reparsing when it can.
//

import Foundation

#if canImport(CMarkDev)
    import CMarkDev
#endif

/// A Markdown document that reparses only when an edit could have changed
/// something structural.
///
/// # The two copies
///
/// Rust holds its own copy of the text, and `NSTextStorage` holds another.
/// That is the price of keeping the parser off the main actor's data
/// structures, and it means the two can drift — a missed edit, an undo path
/// that bypasses the delegate — after which every later edit would be applied
/// at the wrong offsets and the styling would be quietly wrong.
///
/// Rather than trust that never happens, ``apply(range:replacement:fullText:)``
/// compares lengths after each edit and rebuilds from the authoritative Swift
/// text on mismatch. Drift then costs one full parse instead of silent
/// corruption.
public final class IncrementalDocument {
    /// The current parse.
    public private(set) var parsed: ParsedDocument = .empty

    /// Number of edits that avoided a reparse entirely, for diagnostics.
    public private(set) var shiftedEdits = 0
    /// Number of edits that required a full reparse.
    public private(set) var fullReparses = 0
    /// Number of times the Rust and Swift copies drifted and were resynced.
    public private(set) var resyncs = 0

    #if canImport(CMarkDev)
        private var handle: OpaquePointer?
    #endif

    public init(text: String) {
        rebuild(from: text)
    }

    deinit {
        #if canImport(CMarkDev)
            if let handle { md_document_free(handle) }
        #endif
    }

    /// Applies an edit and refreshes ``parsed``.
    ///
    /// - Parameters:
    ///   - range: the replaced range, in UTF-16 units of the text *before*
    ///     the edit.
    ///   - replacement: the text now occupying that range.
    ///   - fullText: the authoritative text after the edit, used to resync if
    ///     the two copies disagree.
    /// - Returns: `true` when the edit was absorbed without reparsing.
    @discardableResult
    public func apply(range: NSRange, replacement: String, fullText: String) -> Bool {
        #if canImport(CMarkDev)
            guard let handle else {
                rebuild(from: fullText)
                return false
            }

            var bytes = Array(replacement.utf8)
            let shifted = bytes.withUnsafeMutableBufferPointer { buffer in
                md_document_replace(
                    handle,
                    UInt32(range.location),
                    UInt32(range.location + range.length),
                    buffer.baseAddress,
                    UInt(buffer.count)
                )
            }

            // The drift check. A mismatch means an edit reached the text view
            // without reaching here; rebuilding is the only safe response.
            if md_document_len_utf16(handle) != UInt32((fullText as NSString).length) {
                resyncs += 1
                rebuild(from: fullText)
                return false
            }

            refresh()
            if shifted == 1 {
                shiftedEdits += 1
                return true
            }
            fullReparses += 1
            return false
        #else
            rebuild(from: fullText)
            return false
        #endif
    }

    /// Discards the incremental state and parses `text` from scratch.
    public func rebuild(from text: String) {
        #if canImport(CMarkDev)
            if let handle { md_document_free(handle) }
            var bytes = Array(text.utf8)
            handle = bytes.withUnsafeMutableBufferPointer { buffer in
                md_document_new(buffer.baseAddress, UInt(buffer.count))
            }
            fullReparses += 1
            refresh()
        #else
            parsed = .empty
        #endif
    }

    #if canImport(CMarkDev)
        private func refresh() {
            guard let handle else {
                parsed = .empty
                return
            }

            let strings = (0..<md_document_string_count(handle)).map { index -> String in
                guard let c = md_document_string(handle, UInt32(index)) else { return "" }
                return String(cString: c)
            }

            var spanCount: UInt = 0
            let spanBase = md_document_spans(handle, &spanCount)
            var markerCount: UInt = 0
            let markerBase = md_document_markers(handle, &markerCount)
            var blockCount: UInt = 0
            let blockBase = md_document_blocks(handle, &blockCount)

            parsed = ParsedDocument(
                spans: MarkdownBridge.spans(spanBase, Int(spanCount)),
                markers: MarkdownBridge.markers(markerBase, Int(markerCount)),
                blocks: MarkdownBridge.blocks(blockBase, Int(blockCount), strings: strings),
                strings: strings
            )
        }
    #endif
}
