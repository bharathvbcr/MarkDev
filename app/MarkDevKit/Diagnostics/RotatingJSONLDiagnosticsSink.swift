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
        // `standardizedFileURL` discards a file URL's host, credentials,
        // query, and fragment. Preserve a non-local spelling so the sink's
        // throwing boundary can reject it instead of laundering it into a
        // local filesystem path.
        self.directory = BoundedRegularFileReader.hasLocalFileAuthority(directory)
            ? directory.standardizedFileURL
            : directory
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
    case unpersistableOrigin
    case recordOriginMismatch
    case incompatibleExistingSegment
    case recordExceedsFileLimit(limit: Int, actual: Int)
    case fileChangedDuringWrite

    public var errorDescription: String? {
        switch self {
        case .pathIsNotDirectory:
            return "The diagnostics directory path is not a private directory."
        case .pathIsNotRegularFile:
            return "A diagnostics generation is not a regular file."
        case .unpersistableOrigin:
            return "The diagnostics origin is not authorized for a scoped disk segment."
        case .recordOriginMismatch:
            return "The diagnostics record does not belong to this process segment."
        case .incompatibleExistingSegment:
            return "An existing diagnostics segment is incompatible and was left unchanged."
        case let .recordExceedsFileLimit(limit, actual):
            return "A \(actual)-byte diagnostics record exceeds the \(limit)-byte file limit."
        case .fileChangedDuringWrite:
            return "The diagnostics file changed while a bounded append was in progress."
        }
    }
}

struct RotatingDiagnosticsSinkTestingHooks: @unchecked Sendable {
    var beforeRotationMutation: (() throws -> Void)?
    var beforePruneMutation: ((String) throws -> Void)?

    init(
        beforeRotationMutation: (() throws -> Void)? = nil,
        beforePruneMutation: ((String) throws -> Void)? = nil
    ) {
        self.beforeRotationMutation = beforeRotationMutation
        self.beforePruneMutation = beforePruneMutation
    }

    static let none = Self()
}

public actor RotatingJSONLDiagnosticsSink: DiagnosticSink {
    private struct DirectoryFingerprint: Equatable {
        let identity: LocalFileIdentity
        let ownerID: uid_t
        let mode: mode_t
        let flags: UInt32

        init(_ status: stat) {
            identity = LocalFileIdentity(status)
            ownerID = status.st_uid
            mode = status.st_mode & mode_t(0o7777)
            flags = status.st_flags
        }
    }

    private struct ExistingFileFingerprint: Equatable {
        let identity: LocalFileIdentity
        let ownerID: uid_t
        let mode: mode_t
        let linkCount: UInt64
        let size: Int64
        let flags: UInt32
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        init(_ status: stat) {
            identity = LocalFileIdentity(status)
            ownerID = status.st_uid
            mode = status.st_mode & mode_t(0o7777)
            linkCount = UInt64(status.st_nlink)
            size = Int64(status.st_size)
            flags = status.st_flags
            modifiedSeconds = Int64(status.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(status.st_mtimespec.tv_nsec)
            changedSeconds = Int64(status.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(status.st_ctimespec.tv_nsec)
        }
    }

    private struct RecoveryPlan {
        let url: URL
        let validPrefixLength: Int?
        let fingerprint: ExistingFileFingerprint
    }

    /// A healthy run owns at most `largestSupportedFileCount` generations and
    /// a small number of crash temporaries. Refuse a directory flooded by a
    /// peer process without first materializing its entire listing.
    static let maximumInspectedDirectoryEntries = 256

    public let configuration: RotatingDiagnosticsFileConfiguration
    public nonisolated let requiredOrigin: DiagnosticOrigin
    private let directoryFingerprint: DirectoryFingerprint
    private let testingHooks: RotatingDiagnosticsSinkTestingHooks

    public init(
        configuration: RotatingDiagnosticsFileConfiguration,
        requiredOrigin: DiagnosticOrigin
    ) throws {
        let fingerprint = try Self.initializeStorage(
            configuration: configuration,
            requiredOrigin: requiredOrigin,
            testingHooks: .none)
        self.configuration = configuration
        self.requiredOrigin = requiredOrigin
        directoryFingerprint = fingerprint
        testingHooks = .none
    }

    init(
        configuration: RotatingDiagnosticsFileConfiguration,
        requiredOrigin: DiagnosticOrigin,
        testingHooks: RotatingDiagnosticsSinkTestingHooks
    ) throws {
        let fingerprint = try Self.initializeStorage(
            configuration: configuration,
            requiredOrigin: requiredOrigin,
            testingHooks: testingHooks)
        self.configuration = configuration
        self.requiredOrigin = requiredOrigin
        directoryFingerprint = fingerprint
        self.testingHooks = testingHooks
    }

    private static func initializeStorage(
        configuration: RotatingDiagnosticsFileConfiguration,
        requiredOrigin: DiagnosticOrigin,
        testingHooks: RotatingDiagnosticsSinkTestingHooks
    ) throws -> DirectoryFingerprint {
        guard BoundedRegularFileReader.hasLocalFileAuthority(configuration.directory) else {
            throw RotatingDiagnosticsFileError.pathIsNotDirectory
        }
        guard requiredOrigin.canPersistToScopedStore else {
            throw RotatingDiagnosticsFileError.unpersistableOrigin
        }
        let directoryFingerprint = try prepareDirectory(configuration.directory)
        var recoveryPlans: [RecoveryPlan] = []
        recoveryPlans.reserveCapacity(configuration.maximumFiles)
        for generation in 0..<configuration.maximumFiles {
            if let plan = try inspectFileIfPresent(
                at: configuration.fileURL(at: generation),
                byteLimit: configuration.maximumFileBytes,
                requiredOrigin: requiredOrigin)
            {
                recoveryPlans.append(plan)
            }
        }
        for plan in recoveryPlans {
            try applyRecoveryPlan(
                plan,
                byteLimit: configuration.maximumFileBytes,
                requiredOrigin: requiredOrigin)
        }
        try pruneUnknownGenerations(
            configuration: configuration,
            expectedDirectory: directoryFingerprint,
            testingHooks: testingHooks)
        return directoryFingerprint
    }

    public func write(_ record: DiagnosticRecord) async throws {
        guard record.event.origin == requiredOrigin else {
            throw RotatingDiagnosticsFileError.recordOriginMismatch
        }
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
        let directoryDescriptor = try Self.openBoundDirectory(
            configuration.directory,
            expected: directoryFingerprint)
        defer { Darwin.close(directoryDescriptor) }

        var generations: [ExistingFileFingerprint?] = []
        generations.reserveCapacity(configuration.maximumFiles)
        for generation in 0..<configuration.maximumFiles {
            generations.append(try Self.trustedFingerprintIfPresent(
                name: configuration.fileURL(at: generation).lastPathComponent,
                directoryDescriptor: directoryDescriptor))
        }

        try testingHooks.beforeRotationMutation?()
        try Self.requireDirectoryMutationAuthority(
            configuration.directory,
            descriptor: directoryDescriptor,
            expected: directoryFingerprint)

        if configuration.maximumFiles == 1 {
            try Self.unlinkExpectedEntry(
                name: configuration.fileURL(at: 0).lastPathComponent,
                expected: generations[0],
                directoryDescriptor: directoryDescriptor)
            try Self.syncDirectoryDescriptor(directoryDescriptor)
            try Self.requireDirectoryMutationAuthority(
                configuration.directory,
                descriptor: directoryDescriptor,
                expected: directoryFingerprint)
            return
        }

        let lastGeneration = configuration.maximumFiles - 1
        try Self.unlinkExpectedEntry(
            name: configuration.fileURL(at: lastGeneration).lastPathComponent,
            expected: generations[lastGeneration],
            directoryDescriptor: directoryDescriptor)
        try Self.requireDirectoryMutationAuthority(
            configuration.directory,
            descriptor: directoryDescriptor,
            expected: directoryFingerprint)
        for generation in stride(from: configuration.maximumFiles - 2, through: 0, by: -1) {
            try Self.renameExpectedEntry(
                sourceName: configuration.fileURL(at: generation).lastPathComponent,
                destinationName: configuration.fileURL(at: generation + 1).lastPathComponent,
                expected: generations[generation],
                directoryDescriptor: directoryDescriptor)
            try Self.requireDirectoryMutationAuthority(
                configuration.directory,
                descriptor: directoryDescriptor,
                expected: directoryFingerprint)
        }
        try Self.syncDirectoryDescriptor(directoryDescriptor)
        try Self.requireDirectoryMutationAuthority(
            configuration.directory,
            descriptor: directoryDescriptor,
            expected: directoryFingerprint)
    }

    private static func prepareDirectory(_ directory: URL) throws -> DirectoryFingerprint {
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

        let descriptor = directory.path.withCString { path in
            Darwin.open(
                path,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            throw RotatingDiagnosticsFileError.pathIsNotDirectory
        }
        defer { Darwin.close(descriptor) }

        guard directoryIsBoundAndOwned(directory, descriptor: descriptor),
              Darwin.fchmod(descriptor, S_IRWXU) == 0,
              Darwin.fsync(descriptor) == 0,
              let fingerprint = boundDirectoryFingerprint(
                  directory,
                  descriptor: descriptor,
                  requiringPrivateMode: true)
        else {
            throw RotatingDiagnosticsFileError.pathIsNotDirectory
        }
        return fingerprint
    }

    private static func pruneUnknownGenerations(
        configuration: RotatingDiagnosticsFileConfiguration,
        expectedDirectory: DirectoryFingerprint,
        testingHooks: RotatingDiagnosticsSinkTestingHooks
    ) throws {
        let directoryDescriptor = try openBoundDirectory(
            configuration.directory,
            expected: expectedDirectory)
        defer { Darwin.close(directoryDescriptor) }

        var candidates: [(name: String, fingerprint: ExistingFileFingerprint)] = []
        for fileName in try directoryEntryNames(descriptor: directoryDescriptor) {
            if isOwnedTemporaryFile(fileName, baseName: configuration.baseName) {
                guard let fingerprint = try trustedFingerprintIfPresent(
                    name: fileName,
                    directoryDescriptor: directoryDescriptor)
                else { throw RotatingDiagnosticsFileError.fileChangedDuringWrite }
                candidates.append((fileName, fingerprint))
                continue
            }
            if let generation = generation(for: fileName, baseName: configuration.baseName),
               generation >= configuration.maximumFiles
            {
                guard let fingerprint = try trustedFingerprintIfPresent(
                    name: fileName,
                    directoryDescriptor: directoryDescriptor)
                else { throw RotatingDiagnosticsFileError.fileChangedDuringWrite }
                candidates.append((fileName, fingerprint))
            }
        }

        for candidate in candidates {
            try testingHooks.beforePruneMutation?(candidate.name)
            try requireDirectoryMutationAuthority(
                configuration.directory,
                descriptor: directoryDescriptor,
                expected: expectedDirectory)
            try unlinkExpectedEntry(
                name: candidate.name,
                expected: candidate.fingerprint,
                directoryDescriptor: directoryDescriptor)
            try requireDirectoryMutationAuthority(
                configuration.directory,
                descriptor: directoryDescriptor,
                expected: expectedDirectory)
        }
        if !candidates.isEmpty {
            try syncDirectoryDescriptor(directoryDescriptor)
            try requireDirectoryMutationAuthority(
                configuration.directory,
                descriptor: directoryDescriptor,
                expected: expectedDirectory)
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

    private static func inspectFileIfPresent(
        at url: URL,
        byteLimit: Int,
        requiredOrigin: DiagnosticOrigin
    ) throws -> RecoveryPlan? {
        var namedStatus = stat()
        let statusResult = url.path.withCString { Darwin.lstat($0, &namedStatus) }
        if statusResult != 0 {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard isTrustedExistingFile(namedStatus) else {
            throw RotatingDiagnosticsFileError.incompatibleExistingSegment
        }
        let fingerprint = ExistingFileFingerprint(namedStatus)
        let tail = try readBoundedTail(
            of: url,
            byteLimit: byteLimit,
            expectedFingerprint: fingerprint)
        guard !tail.droppedPrefix else {
            throw RotatingDiagnosticsFileError.incompatibleExistingSegment
        }
        let validPrefixLength = try validatedPrefixLength(
            tail.data,
            requiredOrigin: requiredOrigin)
        if validPrefixLength == tail.data.count {
            return RecoveryPlan(
                url: url,
                validPrefixLength: nil,
                fingerprint: fingerprint)
        }
        return RecoveryPlan(
            url: url,
            validPrefixLength: validPrefixLength,
            fingerprint: fingerprint)
    }

    private static func applyRecoveryPlan(
        _ plan: RecoveryPlan,
        byteLimit: Int,
        requiredOrigin: DiagnosticOrigin
    ) throws {
        if let validPrefixLength = plan.validPrefixLength {
            let current = try readBoundedTail(
                of: plan.url,
                byteLimit: byteLimit,
                expectedFingerprint: plan.fingerprint)
            guard !current.droppedPrefix,
                  try validatedPrefixLength(
                      current.data,
                      requiredOrigin: requiredOrigin) == validPrefixLength
            else {
                throw RotatingDiagnosticsFileError.fileChangedDuringWrite
            }
            try SecureAtomicDiagnosticsFile.write(
                Data(current.data.prefix(validPrefixLength)),
                to: plan.url)
        } else {
            try normalizePermissions(
                at: plan.url,
                expectedFingerprint: plan.fingerprint)
        }
    }

    private static func readBoundedTail(
        of url: URL,
        byteLimit: Int,
        expectedFingerprint: ExistingFileFingerprint
    ) throws -> (data: Data, originalSize: UInt64, droppedPrefix: Bool) {
        let descriptor = url.path.withCString { path in
            Darwin.open(
                path,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | O_UNIQUE)
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard isTrustedExistingFile(status),
              ExistingFileFingerprint(status) == expectedFingerprint,
              isNameBound(
                url,
                descriptor: descriptor,
                expectedFingerprint: expectedFingerprint)
        else {
            throw RotatingDiagnosticsFileError.incompatibleExistingSegment
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
        guard offset == data.count,
              isNameBound(
                url,
                descriptor: descriptor,
                expectedFingerprint: expectedFingerprint)
        else {
            throw RotatingDiagnosticsFileError.fileChangedDuringWrite
        }
        return (data, originalSize, start > 0)
    }

    private static func normalizePermissions(
        at url: URL,
        expectedFingerprint: ExistingFileFingerprint
    ) throws {
        let descriptor = url.path.withCString { path in
            Darwin.open(
                path,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | O_UNIQUE)
        }
        guard descriptor >= 0 else {
            throw RotatingDiagnosticsFileError.fileChangedDuringWrite
        }
        defer { Darwin.close(descriptor) }
        guard isNameBound(
            url,
            descriptor: descriptor,
            expectedFingerprint: expectedFingerprint)
        else {
            throw RotatingDiagnosticsFileError.fileChangedDuringWrite
        }
        guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
              Darwin.fsync(descriptor) == 0,
              isNameBound(url, descriptor: descriptor)
        else {
            throw RotatingDiagnosticsFileError.fileChangedDuringWrite
        }
    }

    private static func isNameBound(
        _ url: URL,
        descriptor: Int32,
        expectedFingerprint: ExistingFileFingerprint? = nil
    ) -> Bool {
        var held = stat()
        var named = stat()
        guard Darwin.fstat(descriptor, &held) == 0,
              url.path.withCString({ Darwin.lstat($0, &named) }) == 0,
              isTrustedExistingFile(held),
              isTrustedExistingFile(named)
        else { return false }
        let heldFingerprint = ExistingFileFingerprint(held)
        return heldFingerprint == ExistingFileFingerprint(named)
            && (expectedFingerprint.map { heldFingerprint == $0 } ?? true)
    }

    private static func isTrustedExistingFile(_ status: stat) -> Bool {
        status.st_mode & S_IFMT == S_IFREG
            && status.st_uid == geteuid()
            && status.st_nlink == 1
            && status.st_mode & mode_t(0o022) == 0
    }

    private static func validatedPrefixLength(
        _ data: Data,
        requiredOrigin: DiagnosticOrigin
    ) throws -> Int {
        guard !data.isEmpty else { return 0 }
        var startIndex = data.startIndex
        var validPrefixLength = 0
        while startIndex < data.endIndex {
            guard let newline = data[startIndex...].firstIndex(of: 0x0A) else {
                let trailing = Data(data[startIndex...])
                guard validPrefixLength > 0,
                      isPlausiblyInterruptedJSONObject(trailing)
                else {
                    throw RotatingDiagnosticsFileError.incompatibleExistingSegment
                }
                return validPrefixLength
            }
            let line = data[startIndex..<newline]
            guard !line.isEmpty,
                  let event = try? JSONDecoder().decode(DiagnosticEvent.self, from: Data(line)),
                  event.origin == requiredOrigin
            else {
                throw RotatingDiagnosticsFileError.incompatibleExistingSegment
            }
            startIndex = data.index(after: newline)
            validPrefixLength = data.distance(from: data.startIndex, to: startIndex)
        }
        return validPrefixLength
    }

    private static func isPlausiblyInterruptedJSONObject(_ data: Data) -> Bool {
        let nonWhitespace = data.drop { byte in
            byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
        }
        guard nonWhitespace.first == 0x7B else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) == nil
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
        guard isTrustedExistingFile(status) else {
            throw RotatingDiagnosticsFileError.incompatibleExistingSegment
        }
        return UInt64(max(0, status.st_size))
    }

    private static func append(_ data: Data, to url: URL, byteLimit: Int) throws {
        let descriptor = url.path.withCString { path in
            Darwin.open(
                path,
                O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
                    | O_UNIQUE,
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
        guard isTrustedExistingFile(status),
              isNameBound(url, descriptor: descriptor)
        else {
            throw RotatingDiagnosticsFileError.fileChangedDuringWrite
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
        var finalStatus = stat()
        guard Darwin.fstat(descriptor, &finalStatus) == 0,
              UInt64(max(0, finalStatus.st_size)) == currentSize + UInt64(data.count),
              isNameBound(url, descriptor: descriptor)
        else {
            throw RotatingDiagnosticsFileError.fileChangedDuringWrite
        }
        try SecureAtomicDiagnosticsFile.syncDirectory(url.deletingLastPathComponent())
    }

    private static func directoryIsBoundAndOwned(
        _ directory: URL,
        descriptor: Int32
    ) -> Bool {
        boundDirectoryFingerprint(
            directory,
            descriptor: descriptor,
            requiringPrivateMode: false) != nil
    }

    private static func boundDirectoryFingerprint(
        _ directory: URL,
        descriptor: Int32,
        requiringPrivateMode: Bool
    ) -> DirectoryFingerprint? {
        var held = stat()
        var named = stat()
        guard Darwin.fstat(descriptor, &held) == 0,
              directory.path.withCString({ Darwin.lstat($0, &named) }) == 0,
              held.st_mode & S_IFMT == S_IFDIR,
              named.st_mode & S_IFMT == S_IFDIR,
              held.st_uid == geteuid(),
              named.st_uid == geteuid()
        else { return nil }
        let heldFingerprint = DirectoryFingerprint(held)
        let namedFingerprint = DirectoryFingerprint(named)
        guard heldFingerprint == namedFingerprint else { return nil }
        if requiringPrivateMode,
           (heldFingerprint.mode != mode_t(0o700)
               || namedFingerprint.mode != mode_t(0o700))
        {
            return nil
        }
        return heldFingerprint
    }

    private static func openBoundDirectory(
        _ directory: URL,
        expected: DirectoryFingerprint
    ) throws -> Int32 {
        let descriptor = directory.path.withCString { path in
            Darwin.open(
                path,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            throw RotatingDiagnosticsFileError.fileChangedDuringWrite
        }
        guard boundDirectoryFingerprint(
            directory,
            descriptor: descriptor,
            requiringPrivateMode: true) == expected
        else {
            _ = Darwin.close(descriptor)
            throw RotatingDiagnosticsFileError.fileChangedDuringWrite
        }
        return descriptor
    }

    private static func requireDirectoryMutationAuthority(
        _ directory: URL,
        descriptor: Int32,
        expected: DirectoryFingerprint
    ) throws {
        guard boundDirectoryFingerprint(
            directory,
            descriptor: descriptor,
            requiringPrivateMode: true) == expected
        else {
            throw RotatingDiagnosticsFileError.fileChangedDuringWrite
        }
    }

    private static func directoryEntryNames(descriptor: Int32) throws -> [String] {
        var sourceStatus = stat()
        guard Darwin.fstat(descriptor, &sourceStatus) == 0,
              sourceStatus.st_mode & S_IFMT == S_IFDIR,
              sourceStatus.st_uid == geteuid(),
              sourceStatus.st_mode & mode_t(0o7777) == mode_t(0o700)
        else {
            throw RotatingDiagnosticsFileError.incompatibleExistingSegment
        }
        let sourceFingerprint = DirectoryFingerprint(sourceStatus)

        let enumerationDescriptor = ".".withCString { name in
            Darwin.openat(
                descriptor,
                name,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
                    | O_RESOLVE_BENEATH)
        }
        guard enumerationDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var enumerationStatus = stat()
        guard Darwin.fstat(enumerationDescriptor, &enumerationStatus) == 0,
              DirectoryFingerprint(enumerationStatus) == sourceFingerprint
        else {
            _ = Darwin.close(enumerationDescriptor)
            throw RotatingDiagnosticsFileError.incompatibleExistingSegment
        }
        guard let directory = Darwin.fdopendir(enumerationDescriptor) else {
            let code = errno
            _ = Darwin.close(enumerationDescriptor)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        defer { Darwin.closedir(directory) }

        var names: [String] = []
        names.reserveCapacity(min(16, maximumInspectedDirectoryEntries))
        while true {
            errno = 0
            guard let entry = Darwin.readdir(directory) else {
                if errno != 0 {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                var finalSourceStatus = stat()
                var finalEnumerationStatus = stat()
                guard Darwin.fstat(descriptor, &finalSourceStatus) == 0,
                      Darwin.fstat(enumerationDescriptor, &finalEnumerationStatus) == 0,
                      DirectoryFingerprint(finalSourceStatus) == sourceFingerprint,
                      DirectoryFingerprint(finalEnumerationStatus) == sourceFingerprint
                else {
                    throw RotatingDiagnosticsFileError.fileChangedDuringWrite
                }
                return names.sorted()
            }
            var entryValue = entry.pointee
            let name = withUnsafePointer(to: &entryValue.d_name) { pointer -> String? in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(validatingCString: $0)
                }
            }
            guard let name else {
                throw RotatingDiagnosticsFileError.incompatibleExistingSegment
            }
            if name == "." || name == ".." { continue }
            guard names.count < maximumInspectedDirectoryEntries else {
                throw RotatingDiagnosticsFileError.incompatibleExistingSegment
            }
            names.append(name)
        }
    }

    private static func trustedFingerprintIfPresent(
        name: String,
        directoryDescriptor: Int32
    ) throws -> ExistingFileFingerprint? {
        var status = stat()
        let result = name.withCString { pointer in
            Darwin.fstatat(
                directoryDescriptor,
                pointer,
                &status,
                AT_SYMLINK_NOFOLLOW)
        }
        if result != 0 {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard isTrustedExistingFile(status) else {
            throw RotatingDiagnosticsFileError.incompatibleExistingSegment
        }
        return ExistingFileFingerprint(status)
    }

    private static func openTrustedEntry(
        name: String,
        expected: ExistingFileFingerprint,
        directoryDescriptor: Int32
    ) throws -> Int32 {
        let descriptor = name.withCString { pointer in
            Darwin.openat(
                directoryDescriptor,
                pointer,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | O_UNIQUE)
        }
        guard descriptor >= 0 else {
            throw RotatingDiagnosticsFileError.fileChangedDuringWrite
        }
        guard isEntryNameBound(
            name: name,
            directoryDescriptor: directoryDescriptor,
            descriptor: descriptor,
            expected: expected)
        else {
            _ = Darwin.close(descriptor)
            throw RotatingDiagnosticsFileError.fileChangedDuringWrite
        }
        return descriptor
    }

    private static func isEntryNameBound(
        name: String,
        directoryDescriptor: Int32,
        descriptor: Int32,
        expected: ExistingFileFingerprint? = nil
    ) -> Bool {
        var held = stat()
        var named = stat()
        guard Darwin.fstat(descriptor, &held) == 0,
              name.withCString({ pointer in
                  Darwin.fstatat(
                      directoryDescriptor,
                      pointer,
                      &named,
                      AT_SYMLINK_NOFOLLOW)
              }) == 0,
              isTrustedExistingFile(held),
              isTrustedExistingFile(named)
        else { return false }
        let heldFingerprint = ExistingFileFingerprint(held)
        return heldFingerprint == ExistingFileFingerprint(named)
            && (expected.map { heldFingerprint == $0 } ?? true)
    }

    private static func entryIsAbsent(
        name: String,
        directoryDescriptor: Int32
    ) throws -> Bool {
        var status = stat()
        let result = name.withCString { pointer in
            Darwin.fstatat(
                directoryDescriptor,
                pointer,
                &status,
                AT_SYMLINK_NOFOLLOW)
        }
        if result == 0 { return false }
        if errno == ENOENT { return true }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private static func unlinkExpectedEntry(
        name: String,
        expected: ExistingFileFingerprint?,
        directoryDescriptor: Int32
    ) throws {
        guard let expected else {
            guard try entryIsAbsent(name: name, directoryDescriptor: directoryDescriptor) else {
                throw RotatingDiagnosticsFileError.fileChangedDuringWrite
            }
            return
        }
        let descriptor = try openTrustedEntry(
            name: name,
            expected: expected,
            directoryDescriptor: directoryDescriptor)
        defer { Darwin.close(descriptor) }

        let result = name.withCString { pointer in
            Darwin.unlinkat(directoryDescriptor, pointer, 0)
        }
        guard result == 0 else {
            throw RotatingDiagnosticsFileError.fileChangedDuringWrite
        }
        var held = stat()
        guard Darwin.fstat(descriptor, &held) == 0,
              held.st_mode & S_IFMT == S_IFREG,
              held.st_uid == geteuid(),
              held.st_nlink == 0,
              LocalFileIdentity(held) == expected.identity,
              try entryIsAbsent(name: name, directoryDescriptor: directoryDescriptor)
        else {
            throw RotatingDiagnosticsFileError.fileChangedDuringWrite
        }
    }

    private static func renameExpectedEntry(
        sourceName: String,
        destinationName: String,
        expected: ExistingFileFingerprint?,
        directoryDescriptor: Int32
    ) throws {
        guard let expected else {
            guard try entryIsAbsent(
                name: sourceName,
                directoryDescriptor: directoryDescriptor)
            else {
                throw RotatingDiagnosticsFileError.fileChangedDuringWrite
            }
            return
        }
        let descriptor = try openTrustedEntry(
            name: sourceName,
            expected: expected,
            directoryDescriptor: directoryDescriptor)
        defer { Darwin.close(descriptor) }
        guard try entryIsAbsent(
            name: destinationName,
            directoryDescriptor: directoryDescriptor)
        else {
            throw RotatingDiagnosticsFileError.fileChangedDuringWrite
        }

        let result = sourceName.withCString { source in
            destinationName.withCString { destination in
                Darwin.renameatx_np(
                    directoryDescriptor,
                    source,
                    directoryDescriptor,
                    destination,
                    UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else {
            throw RotatingDiagnosticsFileError.fileChangedDuringWrite
        }
        var held = stat()
        guard Darwin.fstat(descriptor, &held) == 0,
              isTrustedExistingFile(held),
              LocalFileIdentity(held) == expected.identity,
              try entryIsAbsent(
                  name: sourceName,
                  directoryDescriptor: directoryDescriptor),
              isEntryNameBound(
                  name: destinationName,
                  directoryDescriptor: directoryDescriptor,
                  descriptor: descriptor)
        else {
            throw RotatingDiagnosticsFileError.fileChangedDuringWrite
        }
    }

    private static func syncDirectoryDescriptor(_ descriptor: Int32) throws {
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
