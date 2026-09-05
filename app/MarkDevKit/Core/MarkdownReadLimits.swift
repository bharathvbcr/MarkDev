//
//  MarkdownReadLimits.swift
//  MarkDevKit
//
//  Shared allocation bounds for Markdown crossing storage/UI boundaries.
//

import Foundation

/// Memory ceilings for Markdown that crosses from the file system into a UI.
///
/// This policy lives in Core so the app and extension-safe renderers can share
/// exact boundaries without importing cache or workspace implementation.
public enum MarkdownReadLimits {
    public static let maximumDocumentBytes = 16 * 1_024 * 1_024
    public static let maximumPreviewBytes = 4 * 1_024 * 1_024

    /// Returns the UTF-8 byte count only when the whole document is safe to
    /// hand to the editor and the Rust ABI.
    public static func acceptedDocumentByteCount(_ text: String) -> Int? {
        BoundedText.acceptedUTF8ByteCount(text, maximum: maximumDocumentBytes)
    }

    /// Bounded observation used when a refusal must report honest coverage.
    /// An oversized value reports only `limit + 1`, never a fabricated exact
    /// total obtained by scanning the rest of caller-owned input.
    static func cappedDocumentByteCount(_ text: String) -> BoundedText.CappedCount {
        BoundedText.cappedUTF8ByteCount(text, maximum: maximumDocumentBytes)
    }
}
