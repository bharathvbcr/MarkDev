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
    /// Edits refused before crossing the FFI boundary because their document
    /// or UTF-16 range was outside MarkDev's bounded 32-bit contract.
    public private(set) var rejectedEdits = 0

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
        guard MarkdownReadLimits.acceptedDocumentByteCount(fullText) != nil,
            MarkdownReadLimits.acceptedDocumentByteCount(replacement) != nil,
            range.location >= 0,
            range.length >= 0
        else {
            rejectedEdits += 1
            return false
        }
        let (rangeEnd, rangeOverflow) = range.location.addingReportingOverflow(range.length)
        let fullUTF16Count = (fullText as NSString).length
        guard !rangeOverflow,
            let start = UInt32(exactly: range.location),
            let end = UInt32(exactly: rangeEnd),
            let fullLength = UInt32(exactly: fullUTF16Count)
        else {
            rejectedEdits += 1
            return false
        }

        #if canImport(CMarkDev)
            guard let handle else {
                rebuild(from: fullText)
                return false
            }
            guard end <= md_document_len_utf16(handle) else {
                rejectedEdits += 1
                return false
            }

            var bytes = Array(replacement.utf8)
            let outcome = bytes.withUnsafeMutableBufferPointer { buffer in
                md_document_replace(
                    handle,
                    start,
                    end,
                    buffer.baseAddress,
                    UInt(buffer.count)
                )
            }

            guard outcome == 1 || outcome == 2 else {
                // ABI 3 guarantees rejection is atomic. Do not refresh or
                // mistake a same-length refusal for a successful full parse.
                rejectedEdits += 1
                return false
            }

            // The drift check. A mismatch means an edit reached the text view
            // without reaching here; rebuilding is the only safe response.
            if md_document_len_utf16(handle) != fullLength {
                resyncs += 1
                rebuild(from: fullText)
                return false
            }

            guard let refreshed = MarkdownBridge.document(
                handle, documentLength: Int(fullLength))
            else {
                // A malformed accessor result is an ABI failure, not a valid
                // empty parse. Drop the now-untrusted incremental handle while
                // preserving the last complete Swift value.
                md_document_free(handle)
                self.handle = nil
                rejectedEdits += 1
                return false
            }
            parsed = refreshed
            if outcome == 1 {
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
    @discardableResult
    public func rebuild(from text: String) -> Bool {
        guard MarkdownReadLimits.acceptedDocumentByteCount(text) != nil,
            UInt32(exactly: (text as NSString).length) != nil
        else {
            rejectedEdits += 1
            return false
        }
        #if canImport(CMarkDev)
            var bytes = Array(text.utf8)
            let replacement = bytes.withUnsafeMutableBufferPointer { buffer in
                md_document_new(buffer.baseAddress, UInt(buffer.count))
            }
            guard let replacement else {
                rejectedEdits += 1
                return false
            }
            guard let replacementParse = MarkdownBridge.document(
                replacement, documentLength: (text as NSString).length)
            else {
                md_document_free(replacement)
                rejectedEdits += 1
                return false
            }
            if let handle { md_document_free(handle) }
            handle = replacement
            parsed = replacementParse
            fullReparses += 1
            return true
        #else
            parsed = .empty
            return true
        #endif
    }

}
