//
//  BoundedText.swift
//  MarkDevKit
//
//  Allocation-safe admission for text crossing untrusted boundaries.
//

import Foundation

/// Shared UTF-8 admission and bounded normalization primitives.
///
/// Domain owners still choose their own limits and refusal types. This seam
/// owns the mechanics: inspect at most `maximum + 1` bytes, never segment an
/// arbitrarily large extended grapheme, and allocate only after admission.
enum BoundedText {
    enum CappedCount: Equatable, Sendable {
        case accepted(Int)
        /// The sequence contained at least this many bytes. The exact total is
        /// deliberately unknown because computing it would defeat the bound.
        case exceeded(observedAtLeast: Int)
        case invalidLimit
    }

    static func cappedCount<Bytes: Sequence>(
        _ bytes: Bytes,
        maximum: Int
    ) -> CappedCount where Bytes.Element == UInt8 {
        guard maximum >= 0, maximum < Int.max else { return .invalidLimit }
        var iterator = bytes.makeIterator()
        var count = 0
        while count <= maximum, iterator.next() != nil {
            count += 1
        }
        return count <= maximum
            ? .accepted(count)
            : .exceeded(observedAtLeast: count)
    }

    static func cappedUTF8ByteCount(_ text: String, maximum: Int) -> CappedCount {
        cappedCount(text.utf8, maximum: maximum)
    }

    static func acceptedUTF8ByteCount(_ text: String, maximum: Int) -> Int? {
        guard case .accepted(let count) = cappedUTF8ByteCount(text, maximum: maximum) else {
            return nil
        }
        return count
    }

    static func fitsUTF8(_ text: String, maximum: Int) -> Bool {
        acceptedUTF8ByteCount(text, maximum: maximum) != nil
    }

    /// A valid-Unicode prefix spending no more than `maximum` UTF-8 bytes.
    ///
    /// Iterating Unicode scalars is intentional. One Swift `Character` can be
    /// a base scalar followed by millions of combining marks; materializing it
    /// before checking its width would defeat the byte boundary.
    static func unicodeScalarPrefix(
        _ text: String, maximum: Int
    ) -> (text: String, truncated: Bool) {
        var scalars = text.unicodeScalars.makeIterator()
        guard maximum > 0 else { return ("", scalars.next() != nil) }

        var output = ""
        output.reserveCapacity(min(maximum, 4_096))
        var bytes = 0
        while let scalar = scalars.next() {
            let width = utf8Width(of: scalar)
            let (next, overflow) = bytes.addingReportingOverflow(width)
            if overflow || next > maximum { return (output, true) }
            output.unicodeScalars.append(scalar)
            bytes = next
        }
        return (output, false)
    }

    /// Collapses whitespace only when the complete input is admitted.
    static func collapsingWhitespace(_ text: String, maximum: Int) -> String? {
        guard let byteCount = acceptedUTF8ByteCount(text, maximum: maximum) else { return nil }
        var output = ""
        output.reserveCapacity(byteCount)
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace {
                pendingSpace = !output.isEmpty
            } else {
                if pendingSpace { output.append(" ") }
                output.unicodeScalars.append(scalar)
                pendingSpace = false
            }
        }
        return output
    }

    private static func utf8Width(of scalar: Unicode.Scalar) -> Int {
        switch scalar.value {
        case ...0x7F: 1
        case ...0x7FF: 2
        case ...0xFFFF: 3
        default: 4
        }
    }
}
