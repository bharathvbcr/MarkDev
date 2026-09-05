//
//  DocumentAssetStore.swift
//  MarkDevKit
//
//  Bounded preparation and durable publication of pasted/dropped images.
//

import Foundation
import ImageIO
import UniformTypeIdentifiers

enum DocumentAssetError: Error, Equatable, LocalizedError, Sendable {
    case unsavedDocument
    case tooManyItems(maximum: Int)
    case inputTooLarge(maximumBytes: Int)
    case batchTooLarge(maximumBytes: Int)
    case vectorTooLarge(maximumBytes: Int)
    case rasterTooLarge(maximumPixels: Int)
    case unsupportedImage
    case unsafeSource
    case sourceChanged
    case nameCollision
    case staleInsertion
    case editRefused
    case busy
    case writeFailed
    case writeOutcomeUncertain
    case rollbackUnsafe

    /// The user-facing vocabulary is deliberately closed. Neither a dragged
    /// source path nor a destination path can leak into an alert or support
    /// screenshot through an arbitrary Foundation error description.
    var readerMessage: String {
        switch self {
        case .unsavedDocument:
            "Save this document before adding images. No file was created."
        case .tooManyItems(let maximum):
            "Add at most \(maximum) images at a time. No file was created."
        case .inputTooLarge(let maximumBytes):
            "An image exceeds the \(maximumBytes)-byte import limit. No file was created."
        case .batchTooLarge(let maximumBytes):
            "The selected images exceed the \(maximumBytes)-byte batch limit. No file was created."
        case .vectorTooLarge(let maximumBytes):
            "A vector image exceeds the \(maximumBytes)-byte drawing limit. No file was created."
        case .rasterTooLarge(let maximumPixels):
            "An image exceeds the \(maximumPixels)-pixel safety limit. No file was created."
        case .unsupportedImage:
            "That item is not a supported image. No file was created."
        case .unsafeSource:
            "The image could not be opened as a regular local file. No file was created."
        case .sourceChanged:
            "The image changed while it was being read. Try again. No file was created."
        case .nameCollision:
            "A collision prevented a safe image name from being reserved. Try again."
        case .staleInsertion:
            "The document changed before the image could be added. Try again."
        case .editRefused:
            "The image could not be inserted at the current selection. No file was created."
        case .busy:
            "Another image import is still finishing. Try again when it completes."
        case .writeFailed:
            "The image could not be saved safely. The incomplete reference was removed."
        case .writeOutcomeUncertain:
            "The image save completed with an uncertain disk result. Review the inserted image."
        case .rollbackUnsafe:
            "The image could not be saved, and its reference changed before it could be removed. Review the inserted reference."
        }
    }

    var errorDescription: String? { readerMessage }

    /// An indeterminate transaction may already have published the exact file.
    /// Removing its Markdown would manufacture an orphan, so that one outcome
    /// remains visible for explicit review. Every proven pre-publication
    /// failure rolls the just-inserted text back.
    var shouldRollbackInsertion: Bool {
        self != .writeOutcomeUncertain && self != .rollbackUnsafe
    }
}

enum DocumentAssetInput: Sendable {
    case file(URL)
    case pasteboard(data: Data, filenameExtension: String, suggestedAlt: String)
}

/// The sole write owner for images created from editor paste and drop.
///
/// Preparation reads and validates bytes on this actor's executor, never the
/// MainActor. Publication happens only after `MarkdownTextView` has approved
/// and applied the corresponding text mutation. A retained directory handle
/// binds the later write to the same physical document directory even if an
/// ancestor is renamed while decoding is in flight.
actor DocumentAssetStore {
    static let shared = DocumentAssetStore()

    static let maximumItemCount = 16
    static let maximumInputBytes = 32 * 1_024 * 1_024
    static let maximumBatchBytes = 64 * 1_024 * 1_024
    static let maximumRasterPixels = 16_000_000
    static let maximumVectorBytes = BoundedVectorImageFormat.maximumBytes
    static let maximumNameAttempts = 8

    struct PreparedAsset: Sendable {
        fileprivate let reservation: String
        let data: Data
        let filename: String
        let alt: String

        var relativePath: String { "assets/\(filename)" }

        var markdown: String {
            "![\(DocumentAssetStore.markdownEscapedAlt(alt))]"
                + "(\(DocumentAssetStore.markdownEscapedPath(relativePath)))"
        }
    }

    struct PreparedBatch: Sendable {
        let generation: UUID
        let assets: [PreparedAsset]
        fileprivate let documentDirectory: SecureLocalDirectoryHandle
    }

    private struct ValidatedAsset: Sendable {
        let data: Data
        let filenameExtension: String
        let alt: String
    }

    private let makeUUID: @Sendable () -> UUID
    private var reservedNames: Set<String> = []

    init(makeUUID: @escaping @Sendable () -> UUID = { UUID() }) {
        self.makeUUID = makeUUID
    }

    func prepare(
        _ inputs: [DocumentAssetInput],
        for documentDirectory: URL?,
        generation: UUID
    ) throws -> PreparedBatch {
        guard let documentDirectory,
            BoundedRegularFileReader.hasLocalFileAuthority(documentDirectory)
        else {
            throw DocumentAssetError.unsavedDocument
        }
        guard !inputs.isEmpty, inputs.count <= Self.maximumItemCount else {
            throw DocumentAssetError.tooManyItems(maximum: Self.maximumItemCount)
        }
        try Task.checkCancellation()

        let destination: SecureLocalDirectoryHandle
        do {
            destination = try SecureLocalDirectoryHandle(
                opening: BoundedRegularFileReader.replacingSystemCompatibilityAlias(
                    in: documentDirectory))
        } catch {
            throw DocumentAssetError.unsafeSource
        }

        var prepared: [PreparedAsset] = []
        var preparedByteCount = 0
        do {
            prepared.reserveCapacity(inputs.count)
            for input in inputs {
                try Task.checkCancellation()
                let validated = try Self.validate(input)
                let (nextByteCount, overflow) = preparedByteCount.addingReportingOverflow(
                    validated.data.count)
                guard !overflow, nextByteCount <= Self.maximumBatchBytes else {
                    throw DocumentAssetError.batchTooLarge(
                        maximumBytes: Self.maximumBatchBytes)
                }
                preparedByteCount = nextByteCount
                let filename = try reserveName(for: validated.filenameExtension)
                prepared.append(
                    PreparedAsset(
                        reservation: filename,
                        data: validated.data,
                        filename: filename,
                        alt: validated.alt))
            }
            return PreparedBatch(
                generation: generation,
                assets: prepared,
                documentDirectory: destination)
        } catch {
            for asset in prepared { reservedNames.remove(asset.reservation) }
            throw error
        }
    }

    /// Publishes exactly one already-approved image. `FileTransaction` stages
    /// with `O_EXCL`, verifies the regular inode, fsyncs bytes, and publishes
    /// descriptor-relatively under a missing-target expectation. The explicit
    /// user-directory entry point preserves existing user metadata; it cannot
    /// be selected accidentally by private app-storage callers.
    func commit(_ asset: PreparedAsset, from batch: PreparedBatch) throws {
        guard reservedNames.contains(asset.reservation),
            batch.assets.contains(where: { $0.reservation == asset.reservation })
        else { throw DocumentAssetError.staleInsertion }
        defer { reservedNames.remove(asset.reservation) }
        try Task.checkCancellation()

        do {
            let assetsDirectory = try batch.documentDirectory.openOrCreateUserDirectory(
                FileComponent("assets"))
            let component = try FileComponent(asset.filename)
            let expectation = FileTransactionExpectation.missing
            let receipt = try assetsDirectory.transaction(
                component: component,
                data: asset.data,
                expectation: expectation,
                policy: .userContent,
                maximumBytes: Self.maximumInputBytes
            ).commit()
            guard receipt.isValidCommittedState(for: expectation) else {
                throw DocumentAssetError.writeOutcomeUncertain
            }
        } catch SecureLocalFileError.expectationMismatch {
            throw DocumentAssetError.nameCollision
        } catch SecureLocalFileError.indeterminate(let receipt) {
            if receipt.version != nil {
                throw DocumentAssetError.writeOutcomeUncertain
            }
            throw DocumentAssetError.writeFailed
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DocumentAssetError {
            throw error
        } catch {
            throw DocumentAssetError.writeFailed
        }
    }

    /// Releases in-memory filename reservations. No pathname deletion is
    /// needed on a refused or stale insertion because publication never starts
    /// until after the text mutation succeeds.
    func discard(_ batch: PreparedBatch, startingAt index: Int = 0) {
        guard index >= 0, index < batch.assets.count else { return }
        for asset in batch.assets[index...] {
            reservedNames.remove(asset.reservation)
        }
    }

    private func reserveName(for filenameExtension: String) throws -> String {
        for _ in 0..<Self.maximumNameAttempts {
            let candidate = "pasted-image-\(makeUUID().uuidString.lowercased()).\(filenameExtension)"
            if reservedNames.insert(candidate).inserted { return candidate }
        }
        throw DocumentAssetError.nameCollision
    }

    private static func validate(_ input: DocumentAssetInput) throws -> ValidatedAsset {
        let data: Data
        let filenameExtension: String
        let alt: String

        switch input {
        case .file(let requestedURL):
            let canonicalExtension = try canonicalExtension(requestedURL.pathExtension)
            let snapshot: BoundedRegularFileSnapshot
            do {
                snapshot = try BoundedRegularFileReader.read(
                    requestedURL,
                    maximumBytes: Self.maximumInputBytes)
            } catch let error as BoundedRegularFileReadError {
                switch error {
                case .tooLarge:
                    throw DocumentAssetError.inputTooLarge(
                        maximumBytes: Self.maximumInputBytes)
                case .changedDuringRead:
                    throw DocumentAssetError.sourceChanged
                case .invalidLimit, .notFileURL, .notRegularFile, .systemCall:
                    throw DocumentAssetError.unsafeSource
                }
            }
            data = snapshot.data
            filenameExtension = canonicalExtension
            alt = requestedURL.deletingPathExtension().lastPathComponent
        case .pasteboard(let bytes, let hintedExtension, let suggestedAlt):
            guard bytes.count <= Self.maximumInputBytes else {
                throw DocumentAssetError.inputTooLarge(
                    maximumBytes: Self.maximumInputBytes)
            }
            data = bytes
            filenameExtension = try canonicalExtension(hintedExtension)
            alt = suggestedAlt
        }

        let vector = BoundedVectorImageFormat(filenameExtension: filenameExtension)
        if vector != nil, data.count > Self.maximumVectorBytes {
            throw DocumentAssetError.vectorTooLarge(
                maximumBytes: Self.maximumVectorBytes)
        }
        try validateImageBytes(
            data,
            filenameExtension: filenameExtension,
            enforceRasterLimit: vector == nil)
        return ValidatedAsset(
            data: data,
            filenameExtension: filenameExtension,
            alt: boundedAlt(alt))
    }

    private static func validateImageBytes(
        _ data: Data,
        filenameExtension: String,
        enforceRasterLimit: Bool
    ) throws {
        guard !data.isEmpty else { throw DocumentAssetError.unsupportedImage }
        if BoundedVectorImageFormat(filenameExtension: filenameExtension) == .svg {
            guard BoundedSVGValidator.validatesImportedAsset(
                data,
                maximumBytes: Self.maximumVectorBytes)
            else { throw DocumentAssetError.unsupportedImage }
            return
        }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
            CGImageSourceGetCount(source) > 0,
            detectedType(of: source, matches: filenameExtension)
        else { throw DocumentAssetError.unsupportedImage }

        guard enforceRasterLimit else { return }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options)
            as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value,
            width > 0,
            height > 0
        else { throw DocumentAssetError.unsupportedImage }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels <= Int64(Self.maximumRasterPixels) else {
            throw DocumentAssetError.rasterTooLarge(
                maximumPixels: Self.maximumRasterPixels)
        }
    }

    private static func detectedType(
        of source: CGImageSource,
        matches filenameExtension: String
    ) -> Bool {
        guard let identifier = CGImageSourceGetType(source),
            let detected = UTType(identifier as String),
            let declared = UTType(filenameExtension: filenameExtension)
        else { return false }
        if BoundedVectorImageFormat(filenameExtension: filenameExtension) == .pdf {
            return detected == .pdf && declared == .pdf
        }
        return detected == declared
            || detected.conforms(to: declared)
            || declared.conforms(to: detected)
    }

    private static func canonicalExtension(_ value: String) throws -> String {
        switch value.lowercased() {
        case "png": "png"
        case "jpg", "jpeg": "jpg"
        case "gif": "gif"
        case "svg": "svg"
        case "webp": "webp"
        case "pdf": "pdf"
        case "heic", "heif": "heic"
        case "tif", "tiff": "tiff"
        default: throw DocumentAssetError.unsupportedImage
        }
    }

    nonisolated static func supports(filenameExtension: String) -> Bool {
        (try? canonicalExtension(filenameExtension)) != nil
    }

    private static func boundedAlt(_ value: String) -> String {
        let oneLine = value.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) ? " " : Character(scalar)
        }
        let trimmed = String(oneLine).trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? "Image" : trimmed).prefix(160))
    }

    static func markdownEscapedAlt(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    static func markdownEscapedPath(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "/-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}
