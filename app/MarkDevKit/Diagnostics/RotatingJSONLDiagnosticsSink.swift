//
//  RotatingJSONLDiagnosticsSink.swift
//  MarkDevKit
//
//  Private, bounded, append-only JSONL persistence with crash-tail repair.
//

import Darwin
import Foundation

public struct RotatingDiagnosticsFileConfiguration: Equatable, Sendable {
    public static let largestSupportedFile = 64 * 1_024 * 1_024
    public static let largestSupportedFileCount = 32

    public let directory: URL
    public let baseName: String
    public let maximumFileBytes: Int
    public let maximumFiles: Int

    public init(
        directory: URL,
        baseName: String = "events",
        maximumFileBytes: Int = 1 * 1_024 * 1_024,
        maximumFiles: Int = 4
    ) {
        self.directory = directory.standardizedFileURL
        self.baseName = Self.sanitizeBaseName(baseName)
        self.maximumFileBytes = min(max(1, maximumFileBytes), Self.largestSupportedFile)
        self.maximumFiles = min(max(1, maximumFiles), Self.largestSupportedFileCount)
    }

    public func fileURL(at generation: Int) -> URL {
        let safeGeneration = max(0, generation)
        let suffix = safeGeneration == 0 ? ".jsonl" : ".\(safeGeneration).jsonl"
        return directory.appendingPathComponent(baseName + suffix, isDirectory: false)
    }

    private static func sanitizeBaseName(_ value: String) -> String {
        guard !value.isEmpty,
              value.utf8.count <= 48,
              value.utf8.allSatisfy({ byte in
                  (0x30...0x39).contains(byte)
                      || (0x41...0x5A).contains(byte)
                      || (0x61...0x7A).contains(byte)
                      || byte == 0x2D
                      || byte == 0x5F
              })
        else {
            return "events"
        }
        return value
    }
}

public enum RotatingDiagnosticsFileError: Error, Equatable, LocalizedError {
    case pathIsNotDirectory
    case pathIsNotRegularFile
    case recordExceedsFileLimit(limit: Int, actual: Int)
    case fileChangedDuringWrite

    public var errorDescription: String? {
        switch self {
        case .pathIsNotDirectory:
            return "The diagnostics directory path is not a private directory."
        case .pathIsNotRegularFile:
            return "A diagnostics generation is not a regular file."
        case let .recordExceedsFileLimit(limit, actual):
            return "A \(actual)-byte diagnostics record exceeds the \(limit)-byte file limit."
        case .fileChangedDuringWrite:
            return "The diagnostics file changed while a bounded append was in progress."
        }
    }
}

public actor RotatingJSONLDiagnosticsSink: DiagnosticSink {
    public let configuration: RotatingDiagnosticsFileConfiguration

    public init(configuration: RotatingDiagnosticsFileConfiguration) throws {
        self.configuration = configuration
        try Self.prepareDirectory(configuration.directory)
        try Self.pruneUnknownGenerations(configuration: configuration)
        for generation in 0..<configuration.maximumFiles {
            try Self.recoverFileIfPresent(
                at: configuration.fileURL(at: generation),
                byteLimit: configuration.maximumFileBytes)
        }
    }

    public func write(_ record: DiagnosticRecord) async throws {
        let line = try DiagnosticsJSON.line(for: record.event)
        guard line.count <= configuration.maximumFileBytes else {
            throw RotatingDiagnosticsFileError.recordExceedsFileLimit(
                limit: configuration.maximumFileBytes,
                actual: line.count)
        }
        let active = configuration.fileURL(at: 0)
        let currentSize = try Self.regularFileSizeIfPresent(at: active)
        if currentSize > 0, currentSize + UInt64(line.count) > UInt64(configuration.maximumFileBytes) {
            try rotate()
        }

        do {
            try Self.append(
                line,
                to: active,
                byteLimit: configuration.maximumFileBytes)
        } catch {
            try? Self.recoverFileIfPresent(
                at: active,
                byteLimit: configuration.maximumFileBytes)
            throw error
        }
    }

    public func existingFiles() -> [URL] {
        (0..<configuration.maximumFiles).compactMap { generation in
            let url = configuration.fileURL(at: generation)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    private func rotate() throws {
        if configuration.maximumFiles == 1 {
            try Self.unlinkIfPresent(configuration.fileURL(at: 0))
            try SecureAtomicDiagnosticsFile.syncDirectory(configuration.directory)
            return
        }

        try Self.unlinkIfPresent(configuration.fileURL(at: configuration.maximumFiles - 1))
        for generation in stride(from: configuration.maximumFiles - 2, through: 0, by: -1) {
            let source = configuration.fileURL(at: generation)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let destination = configuration.fileURL(at: generation + 1)
            try Self.rename(source, to: destination)
        }
        try SecureAtomicDiagnosticsFile.syncDirectory(configuration.directory)
    }

    private static func prepareDirectory(_ directory: URL) throws {
        var status = stat()
        let result = directory.path.withCString { path in
            Darwin.lstat(path, &status)
        }

        if result == 0 {
            guard status.st_mode & S_IFMT == S_IFDIR else {
                throw RotatingDiagnosticsFileError.pathIsNotDirectory
            }
        } else if errno == ENOENT {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let chmodResult = directory.path.withCString { path in
            Darwin.chmod(path, S_IRWXU)
        }
        guard chmodResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func pruneUnknownGenerations(
        configuration: RotatingDiagnosticsFileConfiguration
    ) throws {
        let contents = try FileManager.default.contentsOfDirectory(
            at: configuration.directory,
            includingPropertiesForKeys: nil,
            options: [])
        for url in contents {
            let fileName = url.lastPathComponent
            if isOwnedTemporaryFile(fileName, baseName: configuration.baseName) {
                try unlinkIfPresent(url)
                continue
            }
            if let generation = generation(for: fileName, baseName: configuration.baseName),
               generation >= configuration.maximumFiles
            {
                try unlinkIfPresent(url)
            }
        }
    }

    private static func generation(for fileName: String, baseName: String) -> Int? {
        if fileName == "\(baseName).jsonl" { return 0 }
        let prefix = "\(baseName)."
        let suffix = ".jsonl"
        guard fileName.hasPrefix(prefix), fileName.hasSuffix(suffix) else { return nil }
        let start = fileName.index(fileName.startIndex, offsetBy: prefix.count)
        let end = fileName.index(fileName.endIndex, offsetBy: -suffix.count)
        guard start < end else { return nil }
        let digits = fileName[start..<end]
        guard digits.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
        return Int(digits) ?? .max
    }

    private static func isOwnedTemporaryFile(_ fileName: String, baseName: String) -> Bool {
        guard fileName.first == ".", fileName.hasSuffix(".tmp") else { return false }
        let components = fileName.dropFirst().split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 4,
              components[components.count - 1] == "tmp",
              UUID(uuidString: String(components[components.count - 2])) != nil
        else {
            return false
        }
        let destinationName = components.dropLast(2).joined(separator: ".")
        return generation(for: destinationName, baseName: baseName) != nil
    }

    private static func recoverFileIfPresent(at url: URL, byteLimit: Int) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let tail = try readBoundedTail(of: url, byteLimit: byteLimit)
        let recovered = recoverCompleteJSONLines(
            tail.data,
            droppedPrefix: tail.droppedPrefix,
            byteLimit: byteLimit)
        if tail.originalSize != UInt64(recovered.count) || recovered != tail.data {
            try SecureAtomicDiagnosticsFile.write(recovered, to: url)
        } else {
            let result = url.path.withCString { path in
                Darwin.chmod(path, S_IRUSR | S_IWUSR)
            }
            guard result == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    private static func readBoundedTail(
        of url: URL,
        byteLimit: Int
    ) throws -> (data: Data, originalSize: UInt64, droppedPrefix: Bool) {
        let descriptor = url.path.withCString { path in
            Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw RotatingDiagnosticsFileError.pathIsNotRegularFile
        }

        let originalSize = UInt64(max(0, status.st_size))
        let desiredCount = min(originalSize, UInt64(byteLimit))
        let start = originalSize - desiredCount
        guard Darwin.lseek(descriptor, off_t(start), SEEK_SET) >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var data = Data(count: Int(desiredCount))
        var offset = 0
        try data.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            while offset < rawBuffer.count {
                let readCount = Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset)
                if readCount < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                if readCount == 0 { break }
                offset += readCount
            }
        }
        if offset < data.count {
            data.removeSubrange(offset..<data.count)
        }
        return (data, originalSize, start > 0)
    }

    private static func recoverCompleteJSONLines(
        _ data: Data,
        droppedPrefix: Bool,
        byteLimit: Int
    ) -> Data {
        var startIndex = data.startIndex
        if droppedPrefix {
            guard let firstNewline = data[startIndex...].firstIndex(of: 0x0A) else {
                return Data()
            }
            startIndex = data.index(after: firstNewline)
        }

        var recovered = Data()
        while startIndex < data.endIndex {
            guard let newline = data[startIndex...].firstIndex(of: 0x0A) else { break }
            let line = data[startIndex..<newline]
            guard !line.isEmpty,
                  let event = try? JSONDecoder().decode(DiagnosticEvent.self, from: Data(line)),
                  let canonicalLine = try? DiagnosticsJSON.line(for: event),
                  recovered.count + canonicalLine.count <= byteLimit
            else {
                break
            }
            recovered.append(canonicalLine)
            startIndex = data.index(after: newline)
        }
        return recovered
    }

    private static func regularFileSizeIfPresent(at url: URL) throws -> UInt64 {
        var status = stat()
        let result = url.path.withCString { path in
            Darwin.lstat(path, &status)
        }
        if result != 0 {
            if errno == ENOENT { return 0 }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw RotatingDiagnosticsFileError.pathIsNotRegularFile
        }
        return UInt64(max(0, status.st_size))
    }

    private static func append(_ data: Data, to url: URL, byteLimit: Int) throws {
        let descriptor = url.path.withCString { path in
            Darwin.open(
                path,
                O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw RotatingDiagnosticsFileError.pathIsNotRegularFile
        }
        let currentSize = UInt64(max(0, status.st_size))
        guard currentSize + UInt64(data.count) <= UInt64(byteLimit) else {
            throw RotatingDiagnosticsFileError.fileChangedDuringWrite
        }
        guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try SecureAtomicDiagnosticsFile.writeAll(data, descriptor: descriptor)
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try SecureAtomicDiagnosticsFile.syncDirectory(url.deletingLastPathComponent())
    }

    private static func unlinkIfPresent(_ url: URL) throws {
        let result = url.path.withCString { path in
            Darwin.unlink(path)
        }
        if result != 0, errno != ENOENT {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func rename(_ source: URL, to destination: URL) throws {
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
