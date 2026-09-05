//
//  AssetIngestionHardeningTests.swift
//  MarkDevKitTests
//
//  Hostile image paste/drop and embedded-image boundaries.
//

import AppKit
import Darwin
import XCTest

@testable import MarkDevKit

@MainActor
final class AssetIngestionHardeningTests: XCTestCase {
    @MainActor
    private final class RefusingTextDelegate: NSObject, NSTextViewDelegate {
        private(set) var attemptedChanges = 0

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            attemptedChanges += 1
            return false
        }
    }

    private func temporaryDirectory(_ label: String) throws -> URL {
        // `/var` is a compatibility symlink on macOS. Resolve the trusted
        // fixture root once so a no-follow reader exercises only the symlinks
        // this test deliberately creates.
        let temporaryPath = FileManager.default.temporaryDirectory.path
        let canonicalPath = try XCTUnwrap(
            temporaryPath.withCString { path -> String? in
                guard let resolved = Darwin.realpath(path, nil) else { return nil }
                defer { Darwin.free(resolved) }
                return String(cString: resolved)
            })
        let directory = URL(fileURLWithPath: canonicalPath, isDirectory: true)
            .appendingPathComponent("MarkDevAsset-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false)
        return directory
    }

    private func png(width: Int = 2, height: Int = 2) throws -> Data {
        let representation = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0))
        return try XCTUnwrap(representation.representation(using: .png, properties: [:]))
    }

    private func pdf() -> Data {
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 10, height: 20))
        return view.dataWithPDF(inside: view.bounds)
    }

    private func installImageOnGeneralPasteboard(_ data: Data) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setData(data, forType: .png))
        XCTAssertTrue(pasteboard.writeObjects([item]))
    }

    /// A delegate refusal means the edit did not happen. It must also mean
    /// no asset directory or file happened; otherwise every protected/read-
    /// only paste leaks an orphan into the user's document folder.
    func testPasteApprovalPrecedesEveryFilesystemSideEffect() async throws {
        let documentDirectory = try temporaryDirectory("RefusedPaste")
        defer { try? FileManager.default.removeItem(at: documentDirectory) }
        let editor = MarkdownTextView.make()
        editor.documentDirectory = documentDirectory
        let delegate = RefusingTextDelegate()
        editor.delegate = delegate
        let refused = expectation(description: "asset insertion refused")
        editor.onAssetIngestionError = { _ in refused.fulfill() }
        try installImageOnGeneralPasteboard(png())
        defer { NSPasteboard.general.clearContents() }

        editor.paste(nil)
        await fulfillment(of: [refused], timeout: 2)

        XCTAssertGreaterThan(
            delegate.attemptedChanges,
            0,
            "the fixture must reach the text mutation approval boundary")
        XCTAssertEqual(editor.markdown, "", "a refused paste must not mutate the note")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: documentDirectory.appendingPathComponent("assets").path),
            "approval must happen before creating an assets directory or file")
    }

    /// A dropped image can originate anywhere the user selected, including a
    /// prefix-confused sibling. MarkDev must copy it into the retained
    /// document directory and insert only the generated relative asset path.
    func testExternalImageIsCopiedIntoDocumentAssetsWithoutAnAbsoluteReference() async throws {
        let parent = try temporaryDirectory("Containment")
        defer { try? FileManager.default.removeItem(at: parent) }
        let documentDirectory = parent.appendingPathComponent("vault", isDirectory: true)
        let prefixSibling = parent.appendingPathComponent("vault-private", isDirectory: true)
        try FileManager.default.createDirectory(
            at: documentDirectory,
            withIntermediateDirectories: false)
        try FileManager.default.createDirectory(
            at: prefixSibling,
            withIntermediateDirectories: false)
        let source = prefixSibling.appendingPathComponent("private [draft].png")
        let bytes = try png()
        try bytes.write(to: source)

        let store = DocumentAssetStore()
        let batch = try await store.prepare(
            [.file(source)],
            for: documentDirectory,
            generation: UUID())
        let asset = try XCTUnwrap(batch.assets.first)

        XCTAssertTrue(asset.markdown.contains("(assets/"))
        XCTAssertFalse(asset.markdown.contains(source.path))
        XCTAssertFalse(asset.markdown.contains("../"))
        try await store.commit(asset, from: batch)
        let written = documentDirectory
            .appendingPathComponent("assets", isDirectory: true)
            .appendingPathComponent(asset.filename)
        XCTAssertEqual(try Data(contentsOf: written), bytes)
    }

    /// Source ingestion accepts only a regular file reached without following
    /// either a leaf or intermediate symlink. Rendering intentionally retains
    /// its established absolute/parent-relative syntax semantics; the secure
    /// boundary here is the newly written destination plus the source read.
    func testAssetPreparationRefusesLeafAndIntermediateSymlinks() async throws {
        let parent = try temporaryDirectory("Symlinks")
        defer { try? FileManager.default.removeItem(at: parent) }
        let documentDirectory = parent.appendingPathComponent("document", isDirectory: true)
        let externalDirectory = parent.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(
            at: documentDirectory,
            withIntermediateDirectories: false)
        try FileManager.default.createDirectory(
            at: externalDirectory,
            withIntermediateDirectories: false)
        let externalImage = externalDirectory.appendingPathComponent("private.png")
        try png().write(to: externalImage)

        let leaf = documentDirectory.appendingPathComponent("leaf.png")
        try FileManager.default.createSymbolicLink(at: leaf, withDestinationURL: externalImage)
        let intermediate = documentDirectory.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: intermediate,
            withDestinationURL: externalDirectory)

        let store = DocumentAssetStore()
        for source in [leaf, intermediate.appendingPathComponent("private.png")] {
            do {
                _ = try await store.prepare(
                    [.file(source)],
                    for: documentDirectory,
                    generation: UUID())
                XCTFail("ingestion followed the untrusted symlink in \(source.lastPathComponent)")
            } catch let error as DocumentAssetError {
                XCTAssertEqual(error, .unsafeSource)
                XCTAssertFalse(error.readerMessage.contains(externalDirectory.path))
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }
        var intermediateStatus = stat()
        XCTAssertEqual(Darwin.lstat(intermediate.path, &intermediateStatus), 0)
        XCTAssertEqual(intermediateStatus.st_mode & S_IFMT, S_IFLNK)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: intermediate.path),
            externalDirectory.path)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: externalDirectory.path),
            ["private.png"])
    }

    func testUnsavedPreparationCreatesNoAssetOrTemporaryOrphan() async throws {
        let sourceDirectory = try temporaryDirectory("Unsaved")
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }
        let source = sourceDirectory.appendingPathComponent("source.png")
        try png().write(to: source)

        do {
            _ = try await DocumentAssetStore().prepare(
                [.file(source)],
                for: nil,
                generation: UUID())
            XCTFail("an unsaved document acquired asset authority")
        } catch let error as DocumentAssetError {
            XCTAssertEqual(error, .unsavedDocument)
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: sourceDirectory.path),
            ["source.png"])
    }

    func testMarkdownEscapingCannotCloseTheAltOrDestination() async throws {
        let documentDirectory = try temporaryDirectory("Escaping")
        defer { try? FileManager.default.removeItem(at: documentDirectory) }
        let fixed = try XCTUnwrap(UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"))
        let store = DocumentAssetStore(makeUUID: { fixed })
        let batch = try await store.prepare(
            [
                .pasteboard(
                    data: png(),
                    filenameExtension: "png",
                    suggestedAlt: #"close] [open\name"#)
            ],
            for: documentDirectory,
            generation: UUID())
        let asset = try XCTUnwrap(batch.assets.first)

        XCTAssertEqual(
            asset.markdown,
            #"![close\] \[open\\name](assets/pasted-image-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.png)"#)
        await store.discard(batch)
    }

    /// ImageIO reports zero frames for a valid SVG on supported macOS
    /// versions. SVG admission therefore needs a bounded XML boundary rather
    /// than treating a raster decoder's compatibility gap as invalid input.
    func testMinimalValidSVGIsAcceptedWithoutImageIODecoding() async throws {
        let documentDirectory = try temporaryDirectory("MinimalSVG")
        defer { try? FileManager.default.removeItem(at: documentDirectory) }
        let svg = Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <svg xmlns="http://www.w3.org/2000/svg" width="2" height="2" viewBox="0 0 2 2">
              <rect width="2" height="2" fill="black"/>
            </svg>
            """.utf8)

        let store = DocumentAssetStore()
        let batch = try await store.prepare(
            [.pasteboard(data: svg, filenameExtension: "svg", suggestedAlt: "Vector")],
            for: documentDirectory,
            generation: UUID())

        let asset = try XCTUnwrap(batch.assets.first)
        XCTAssertTrue(asset.filename.hasSuffix(".svg"))
        try await store.commit(asset, from: batch)
        guard case .success = RichContentRenderer().image(
            at: asset.relativePath,
            relativeTo: documentDirectory,
            maxWidth: 100)
        else { return XCTFail("a validated minimal SVG did not render") }
    }

    func testImportedSVGRejectsExternalCSSAndBaseResolution() {
        let hostile = [
            #"<svg xmlns="http://www.w3.org/2000/svg"><style>@import url('https://example.invalid/x.css');</style></svg>"#,
            #"<svg xmlns="http://www.w3.org/2000/svg"><rect style="@IMPORT 'https://example.invalid/x.css'"/></svg>"#,
            #"<svg xmlns="http://www.w3.org/2000/svg"><rect fill="url(https://example.invalid/x.png)"/></svg>"#,
            ##"<svg xmlns="http://www.w3.org/2000/svg" xml:base="https://example.invalid/"><use href="#mark"/></svg>"##,
            ##"<svg xmlns="http://www.w3.org/2000/svg" base="file:///private/"><use href="#mark"/></svg>"##,
            #"<?xml-stylesheet href="https://example.invalid/x.css"?><svg xmlns="http://www.w3.org/2000/svg"/>"#,
        ]

        for source in hostile {
            XCTAssertFalse(
                BoundedSVGValidator.validatesImportedAsset(
                    Data(source.utf8),
                    maximumBytes: BoundedVectorImageFormat.maximumBytes),
                source)
        }
    }

    /// CSS has a separate escape/tokenization grammar. A literal substring
    /// scan therefore cannot prove that any nonempty inline style is
    /// self-contained, even when the spelling looks harmless.
    func testImportedSVGRejectsEscapedInlineStyleResourceReferences() {
        let hostile = [
            #"<svg xmlns="http://www.w3.org/2000/svg"><rect style="fill:red"/></svg>"#,
            #"<svg xmlns="http://www.w3.org/2000/svg"><rect style="fill:u\72 l(https://example.invalid/x.png)"/></svg>"#,
            #"<svg xmlns="http://www.w3.org/2000/svg"><rect style="fill:url\28 https://example.invalid/x.png\29 "/></svg>"#,
        ]

        for source in hostile {
            XCTAssertFalse(
                BoundedSVGValidator.validatesImportedAsset(
                    Data(source.utf8),
                    maximumBytes: BoundedVectorImageFormat.maximumBytes),
                source)
        }
    }

    func testImportedSVGRejectsDTDAndActiveContent() {
        let hostile = [
            #"<!DOCTYPE svg [<!ENTITY payload "expanded">]><svg xmlns="http://www.w3.org/2000/svg"><text>&payload;</text></svg>"#,
            #"<!DOCTYPE svg [<!ENTITY payload SYSTEM "https://example.invalid/entity">]><svg xmlns="http://www.w3.org/2000/svg"><text>&payload;</text></svg>"#,
            #"<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>"#,
            #"<svg xmlns="http://www.w3.org/2000/svg"><foreignObject><body>active</body></foreignObject></svg>"#,
            #"<svg xmlns="http://www.w3.org/2000/svg"><animate attributeName="href" to="https://example.invalid/x"/></svg>"#,
        ]

        for source in hostile {
            XCTAssertFalse(
                BoundedSVGValidator.validatesImportedAsset(
                    Data(source.utf8),
                    maximumBytes: BoundedVectorImageFormat.maximumBytes),
                source)
        }
    }

    func testImportedSVGBoundsDepthElementsAndAttributes() {
        let namespace = #" xmlns="http://www.w3.org/2000/svg""#
        let tooDeep = "<svg\(namespace)>"
            + String(repeating: "<g>", count: BoundedSVGValidator.maximumDepth)
            + String(repeating: "</g>", count: BoundedSVGValidator.maximumDepth)
            + "</svg>"
        let tooManyElements = "<svg\(namespace)>"
            + String(repeating: "<g/>", count: BoundedSVGValidator.maximumElements)
            + "</svg>"
        let eightAttributes = "<g a='1' b='2' c='3' d='4' e='5' f='6' g='7' h='8'/>"
        let tooManyAttributes = "<svg\(namespace)>"
            + String(
                repeating: eightAttributes,
                count: BoundedSVGValidator.maximumAttributes / 8)
            + "<g a='1'/></svg>"

        for source in [tooDeep, tooManyElements, tooManyAttributes] {
            let data = Data(source.utf8)
            XCTAssertLessThan(data.count, BoundedVectorImageFormat.maximumBytes)
            XCTAssertFalse(
                BoundedSVGValidator.validatesImportedAsset(
                    data,
                    maximumBytes: BoundedVectorImageFormat.maximumBytes))
        }
    }

    func testImportedSVGAcceptsUTF8AndUTF16ButRejectsAmbiguousEncodings() throws {
        let source = #"<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg"><rect width="1" height="1"/></svg>"#
        var utf8BOM = Data([0xEF, 0xBB, 0xBF])
        utf8BOM.append(Data(source.utf8))
        var utf16LE = Data([0xFF, 0xFE])
        utf16LE.append(try XCTUnwrap(source.data(using: .utf16LittleEndian)))
        var utf16BE = Data([0xFE, 0xFF])
        utf16BE.append(try XCTUnwrap(source.data(using: .utf16BigEndian)))

        for data in [Data(source.utf8), utf8BOM, utf16LE, utf16BE] {
            XCTAssertTrue(
                BoundedSVGValidator.validatesImportedAsset(
                    data,
                    maximumBytes: BoundedVectorImageFormat.maximumBytes))
        }

        var utf32LE = Data([0xFF, 0xFE, 0x00, 0x00])
        utf32LE.append(try XCTUnwrap(source.data(using: .utf32LittleEndian)))
        for data in [utf32LE, Data([0x3C, 0x73, 0x76, 0x67, 0xC0, 0xAF])] {
            XCTAssertFalse(
                BoundedSVGValidator.validatesImportedAsset(
                    data,
                    maximumBytes: BoundedVectorImageFormat.maximumBytes))
        }
    }

    func testValidPDFUsesTheBoundedVectorAdmissionAndRenderPath() async throws {
        let documentDirectory = try temporaryDirectory("MinimalPDF")
        defer { try? FileManager.default.removeItem(at: documentDirectory) }
        let data = pdf()
        XCTAssertTrue(data.starts(with: Data("%PDF-".utf8)))
        XCTAssertLessThan(data.count, DocumentAssetStore.maximumVectorBytes)

        let store = DocumentAssetStore()
        let batch = try await store.prepare(
            [.pasteboard(data: data, filenameExtension: "pdf", suggestedAlt: "PDF")],
            for: documentDirectory,
            generation: UUID())
        let asset = try XCTUnwrap(batch.assets.first)
        try await store.commit(asset, from: batch)

        let renderer = RichContentRenderer()
        XCTAssertTrue(renderer.isScalable(at: asset.relativePath, relativeTo: documentDirectory))
        guard case .success(let rendered) = renderer.image(
            at: asset.relativePath,
            relativeTo: documentDirectory,
            maxWidth: 100)
        else { return XCTFail("a validated one-page PDF did not render") }
        XCTAssertGreaterThan(rendered.size.width, 0)
        XCTAssertGreaterThan(rendered.size.height, 0)
    }

    func testPDFCannotBypassVectorSizeOrDetectedTypeChecks() async throws {
        let documentDirectory = try temporaryDirectory("PDFBounds")
        defer { try? FileManager.default.removeItem(at: documentDirectory) }
        let store = DocumentAssetStore()

        do {
            _ = try await store.prepare(
                [.pasteboard(
                    data: Data(repeating: 0x20, count: DocumentAssetStore.maximumVectorBytes + 1),
                    filenameExtension: "pdf",
                    suggestedAlt: "PDF")],
                for: documentDirectory,
                generation: UUID())
            XCTFail("PDF bypassed the shared vector byte ceiling")
        } catch let error as DocumentAssetError {
            XCTAssertEqual(
                error,
                .vectorTooLarge(maximumBytes: DocumentAssetStore.maximumVectorBytes))
        }

        for data in [Data("%PDF-1.7\n%%EOF".utf8), try png()] {
            do {
                _ = try await store.prepare(
                    [.pasteboard(data: data, filenameExtension: "pdf", suggestedAlt: "PDF")],
                    for: documentDirectory,
                    generation: UUID())
                XCTFail("malformed or mislabeled PDF was admitted")
            } catch let error as DocumentAssetError {
                XCTAssertEqual(error, .unsupportedImage)
            }
        }
    }

    func testConcurrentPreparationsReserveDistinctUUIDNames() async throws {
        let documentDirectory = try temporaryDirectory("Concurrency")
        defer { try? FileManager.default.removeItem(at: documentDirectory) }
        let bytes = try png()
        let store = DocumentAssetStore()

        let names = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<64 {
                group.addTask {
                    let batch = try await store.prepare(
                        [
                            .pasteboard(
                                data: bytes,
                                filenameExtension: "png",
                                suggestedAlt: "Image")
                        ],
                        for: documentDirectory,
                        generation: UUID())
                    return batch.assets[0].filename
                }
            }
            var collected: [String] = []
            for try await name in group { collected.append(name) }
            return collected
        }
        XCTAssertEqual(names.count, 64)
        XCTAssertEqual(Set(names).count, names.count)
    }

    func testFiniteItemAndByteBoundsFailBeforePublishing() async throws {
        let documentDirectory = try temporaryDirectory("Bounds")
        defer { try? FileManager.default.removeItem(at: documentDirectory) }
        let bytes = try png()
        let store = DocumentAssetStore()
        let exact = Array(
            repeating: DocumentAssetInput.pasteboard(
                data: bytes,
                filenameExtension: "png",
                suggestedAlt: "Image"),
            count: DocumentAssetStore.maximumItemCount)
        let accepted = try await store.prepare(
            exact,
            for: documentDirectory,
            generation: UUID())
        XCTAssertEqual(accepted.assets.count, DocumentAssetStore.maximumItemCount)
        await store.discard(accepted)

        do {
            _ = try await store.prepare(
                exact + [.pasteboard(data: bytes, filenameExtension: "png", suggestedAlt: "Image")],
                for: documentDirectory,
                generation: UUID())
            XCTFail("the item-count limit was not enforced")
        } catch let error as DocumentAssetError {
            XCTAssertEqual(
                error,
                .tooManyItems(maximum: DocumentAssetStore.maximumItemCount))
        }

        do {
            _ = try await store.prepare(
                [
                    .pasteboard(
                        data: Data(
                            repeating: 0,
                            count: DocumentAssetStore.maximumInputBytes + 1),
                        filenameExtension: "png",
                        suggestedAlt: "Image")
                ],
                for: documentDirectory,
                generation: UUID())
            XCTFail("the compressed-byte limit was not enforced")
        } catch let error as DocumentAssetError {
            XCTAssertEqual(
                error,
                .inputTooLarge(maximumBytes: DocumentAssetStore.maximumInputBytes))
        }

        do {
            _ = try await store.prepare(
                [
                    .pasteboard(
                        data: Data(
                            repeating: 0x20,
                            count: DocumentAssetStore.maximumVectorBytes + 1),
                        filenameExtension: "svg",
                        suggestedAlt: "Vector")
                ],
                for: documentDirectory,
                generation: UUID())
            XCTFail("the vector-cost limit was not enforced")
        } catch let error as DocumentAssetError {
            XCTAssertEqual(
                error,
                .vectorTooLarge(maximumBytes: DocumentAssetStore.maximumVectorBytes))
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: documentDirectory.appendingPathComponent("assets").path))
    }

    func testFiniteUUIDRetriesRefuseACollisionWithoutPublishing() async throws {
        let documentDirectory = try temporaryDirectory("NameCollision")
        defer { try? FileManager.default.removeItem(at: documentDirectory) }
        let bytes = try png()
        let fixed = try XCTUnwrap(UUID(uuidString: "00000000-1111-2222-3333-444444444444"))
        let store = DocumentAssetStore(makeUUID: { fixed })
        let first = try await store.prepare(
            [.pasteboard(data: bytes, filenameExtension: "png", suggestedAlt: "Image")],
            for: documentDirectory,
            generation: UUID())

        do {
            _ = try await store.prepare(
                [.pasteboard(data: bytes, filenameExtension: "png", suggestedAlt: "Image")],
                for: documentDirectory,
                generation: UUID())
            XCTFail("a process-local UUID collision was reserved twice")
        } catch let error as DocumentAssetError {
            XCTAssertEqual(error, .nameCollision)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: documentDirectory.appendingPathComponent("assets").path))
        await store.discard(first)
    }

    func testExclusiveDestinationCollisionRollsBackOnlyTheInsertedReference() async throws {
        let documentDirectory = try temporaryDirectory("CommitCollision")
        defer { try? FileManager.default.removeItem(at: documentDirectory) }
        let assets = documentDirectory.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: false)
        let fixed = try XCTUnwrap(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let filename = "pasted-image-\(fixed.uuidString.lowercased()).png"
        let collision = assets.appendingPathComponent(filename)
        let sentinel = Data("do-not-replace".utf8)
        try sentinel.write(to: collision)

        let editor = MarkdownTextView.make()
        editor.documentDirectory = documentDirectory
        editor.documentAssetStore = DocumentAssetStore(makeUUID: { fixed })
        let failed = expectation(description: "exclusive collision reported")
        var message = ""
        editor.onAssetIngestionError = {
            message = $0
            failed.fulfill()
        }
        try installImageOnGeneralPasteboard(png())
        defer { NSPasteboard.general.clearContents() }

        editor.paste(nil)
        await fulfillment(of: [failed], timeout: 2)

        XCTAssertEqual(editor.markdown, "")
        XCTAssertEqual(try Data(contentsOf: collision), sentinel)
        XCTAssertFalse(message.contains(documentDirectory.path))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: assets.path),
            [filename])
    }

    func testExistingUserAssetsDirectoryKeepsItsModeAndRejectsSymlinkReplacement() throws {
        let documentDirectory = try temporaryDirectory("AssetsMetadata")
        defer { try? FileManager.default.removeItem(at: documentDirectory) }
        let assets = documentDirectory.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: false)
        XCTAssertEqual(Darwin.chmod(assets.path, 0o711), 0)

        let document = try SecureLocalDirectoryHandle(opening: documentDirectory)
        _ = try document.openOrCreateUserDirectory(FileComponent("assets"))
        var status = stat()
        XCTAssertEqual(Darwin.lstat(assets.path, &status), 0)
        XCTAssertEqual(status.st_mode & mode_t(0o7777), 0o711)

        try FileManager.default.removeItem(at: assets)
        let elsewhere = try temporaryDirectory("AssetsElsewhere")
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        try FileManager.default.createSymbolicLink(at: assets, withDestinationURL: elsewhere)
        XCTAssertThrowsError(
            try document.openOrCreateUserDirectory(FileComponent("assets")))
    }
}

/// Private implementation state makes several failures observable only as a
/// hang, an orphan, or a race. These source contracts pin the canonical seam
/// that the behavioral tests above drive, and make finite bounds executable
/// without allocating a decompression bomb in the test process.
final class AssetIngestionArchitectureContractTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // app
            .deletingLastPathComponent() // repository
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8)
    }

    private func targetBlock(_ target: String, in project: String) throws -> Substring {
        let marker = "  \(target):\n"
        let start = try XCTUnwrap(project.range(of: marker)?.upperBound)
        let remainder = project[start...]
        let end = remainder.range(
            of: #"(?m)^  [A-Za-z][A-Za-z0-9]*:\n"#,
            options: .regularExpression)?.lowerBound ?? project.endIndex
        return project[start..<end]
    }

    func testEditorRoutesPasteAndDropThroughOneTransactionalAssetOwner() throws {
        let editor = try source("app/MarkDevKit/Editor/MarkdownTextView.swift")

        XCTAssertTrue(
            editor.contains("DocumentAssetStore"),
            "paste and drop need one bounded transactional owner")
        XCTAssertTrue(
            editor.contains("onAssetIngestionError"),
            "every refused or failed ingestion needs a visible error callback")
        XCTAssertTrue(editor.contains("rollbackAssetMarkdown"))
        XCTAssertTrue(editor.contains("shouldChangeText(in: insertionRange"))
        XCTAssertTrue(editor.contains("documentAssetStore.commit"))
        for forbidden in [
            "NSImage(pasteboard:",
            "documentDirectory ?? FileManager.default.temporaryDirectory",
            "ISO8601DateFormatter()",
            "url.path.hasPrefix(docDir.path)",
            "ref = url.path",
            "pngData.write(to:",
        ] {
            XCTAssertFalse(
                editor.contains(forbidden),
                "MarkdownTextView still owns unsafe asset work: \(forbidden)")
        }
    }

    func testAssetOwnerNamesEveryFiniteAndFilesystemBoundary() throws {
        let relativePath = "app/MarkDevKit/Editor/DocumentAssetStore.swift"
        let url = repositoryRoot.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return XCTFail("\(relativePath) is missing; asset ingestion has no canonical owner")
        }
        let assetStore = try source(relativePath)
        let reader = try source("app/MarkDevKit/Core/BoundedRegularFileReader.swift")
        let svgValidator = try source("app/MarkDevKit/Core/BoundedSVGValidator.swift")
        let secure = try source("app/MarkDevKit/Workspace/SecureLocalFileSystem.swift")

        for required in [
            "actor DocumentAssetStore",
            "maximumItemCount",
            "maximumInputBytes",
            "maximumBatchBytes",
            "maximumRasterPixels",
            "maximumVectorBytes",
            "maximumNameAttempts",
            "UUID",
            "BoundedRegularFileReader",
            "SecureLocalDirectoryHandle",
            "FileComponent",
            "generation",
            "markdownEscapedAlt",
            "markdownEscapedPath",
            "readerMessage",
        ] {
            XCTAssertTrue(
                assetStore.contains(required),
                "the canonical asset boundary does not name \(required)")
        }
        for required in ["O_NOFOLLOW_ANY", "O_NONBLOCK", "S_IFREG", "pread"] {
            XCTAssertTrue(
                reader.contains(required),
                "the shared bounded reader does not name \(required)")
        }
        for required in [
            "XMLParser",
            "shouldResolveExternalEntities = false",
            "externalEntityResolvingPolicy = .never",
            "maximumElements",
            "maximumAttributes",
            "maximumDepth",
        ] {
            XCTAssertTrue(
                svgValidator.contains(required),
                "the bounded SVG boundary does not name \(required)")
        }
        for required in [
            "openOrCreateUserDirectory",
            "mkdirAt",
            "O_EXCL",
            "O_RESOLVE_BENEATH",
            "FileTransactionExpectation.missing",
        ] {
            XCTAssertTrue(
                secure.contains(required) || assetStore.contains(required),
                "the descriptor-relative publication boundary does not name \(required)")
        }
        XCTAssertFalse(
            assetStore.contains("path.hasPrefix"),
            "string prefixes are not filesystem containment")
        XCTAssertFalse(
            assetStore.contains("FileManager.default.temporaryDirectory"),
            "an unsaved document must fail without writing an orphan")
    }

    func testAssetFailuresReachTheWindowsPrivacySafeErrorArbiter() throws {
        let editor = try source("app/MarkDevKit/Editor/MarkdownEditorView.swift")
        let workspace = try source("app/MarkDev/WorkspaceView.swift")

        XCTAssertTrue(editor.contains("onAssetIngestionError"))
        XCTAssertTrue(
            editor.contains("textView.onAssetIngestionError"),
            "the SwiftUI bridge must forward native editor failures")
        XCTAssertTrue(
            workspace.contains("onAssetIngestionError: { errorMessage = $0 }"),
            "asset failures must use the existing serialized transient error UI")
    }

    func testRendererPreflightsRasterCostBeforeAnyFullDecode() throws {
        let renderer = try source("app/MarkDevKit/Editor/RichContentRenderer.swift")

        XCTAssertFalse(
            renderer.contains("NSImage(contentsOf:"),
            "NSImage may fully decode a hostile raster before its dimensions are bounded")
        for required in [
            "CGImageSourceCreateWithData",
            "CGImageSourceCopyPropertiesAtIndex",
            "kCGImageSourceShouldCache",
            "kCGImagePropertyPixelWidth",
            "kCGImagePropertyPixelHeight",
            "maxRasterPixels",
            "maxVectorBytes",
        ] {
            XCTAssertTrue(
                renderer.contains(required),
                "renderer image preflight is missing \(required)")
        }
    }

    func testQuickLookKeepsOnlyTheReadSideOfTheAssetBoundary() throws {
        let project = try source("project.yml")
        let quickLook = try targetBlock("MarkDevQuickLook", in: project)

        XCTAssertFalse(quickLook.contains("DocumentAssetStore.swift"))
        XCTAssertFalse(quickLook.contains("SecureLocalFileSystem.swift"))
        XCTAssertFalse(quickLook.contains("MarkdownEditorView.swift"))
        XCTAssertFalse(quickLook.contains("SwiftTerm"))
        XCTAssertTrue(quickLook.contains("MARKDEV_QUICKLOOK"))
        XCTAssertTrue(quickLook.contains("BoundedRegularFileReader.swift"))
        XCTAssertTrue(quickLook.contains("BoundedSVGValidator.swift"))
        XCTAssertTrue(quickLook.contains("path: app/MarkDevQuickLook"))

        let renderer = try source("app/MarkDevKit/Editor/RichContentRenderer.swift")
        XCTAssertFalse(
            renderer.contains("import SwiftTerm"),
            "the shared renderer cannot pull process authority into Quick Look")
        XCTAssertFalse(
            renderer.contains("NSWorkspace.shared"),
            "the shared renderer cannot open or mutate external resources")
    }
}
