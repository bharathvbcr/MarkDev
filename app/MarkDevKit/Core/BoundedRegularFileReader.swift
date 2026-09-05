//
//  BoundedRegularFileReader.swift
//  MarkDevKit
//
//  One read-only, no-follow boundary shared by the app and Quick Look.
//

import Darwin
import Foundation

enum BoundedRegularFileReadError: Error, Equatable, LocalizedError, Sendable {
    case invalidLimit
    case notFileURL
    case notRegularFile
    case tooLarge(maximumBytes: Int)
    case changedDuringRead
    case systemCall(code: Int32)

    /// Safe for UI. Paths and underlying filesystem details deliberately stay
    /// out of the message; diagnostics can classify the typed case separately.
    var readerMessage: String {
        switch self {
        case .invalidLimit:
            "The file size limit is invalid."
        case .notFileURL, .notRegularFile:
            "Only a regular local file can be used."
        case .tooLarge(let maximumBytes):
            "The file is larger than the \(maximumBytes)-byte safety limit."
        case .changedDuringRead:
            "The file changed while it was being read. Try again."
        case .systemCall:
            "The file could not be read safely."
        }
    }

    var errorDescription: String? { readerMessage }
}

/// A stable byte snapshot from one retained regular-file descriptor.
struct BoundedRegularFileSnapshot: Sendable {
    let data: Data
    let canonicalURL: URL
    let generation: BoundedRegularFileGeneration
}

/// Everything needed to bind cached bytes to one exact regular-file version.
///
/// A path and even a device/inode pair are insufficient: atomic replacement
/// reuses the path, inode numbers can be recycled, and an in-place rewrite can
/// preserve both size and a caller-restored modification time. Every field is
/// copied from one `fstat` on the retained descriptor.
struct BoundedRegularFileGeneration: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
    let fileGeneration: UInt32
    let birthSeconds: Int64
    let birthNanoseconds: Int64
    let size: Int64
    let linkCount: UInt64
    let mode: mode_t
    let ownerID: uid_t
    let groupID: gid_t
    let flags: UInt32
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    fileprivate init(_ status: stat) {
        device = UInt64(truncatingIfNeeded: status.st_dev)
        inode = UInt64(truncatingIfNeeded: status.st_ino)
        fileGeneration = status.st_gen
        birthSeconds = Int64(status.st_birthtimespec.tv_sec)
        birthNanoseconds = Int64(status.st_birthtimespec.tv_nsec)
        size = Int64(status.st_size)
        linkCount = UInt64(status.st_nlink)
        mode = status.st_mode
        ownerID = status.st_uid
        groupID = status.st_gid
        flags = status.st_flags
        modifiedSeconds = Int64(status.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(status.st_mtimespec.tv_nsec)
        changedSeconds = Int64(status.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(status.st_ctimespec.tv_nsec)
    }
}

/// A retained no-follow descriptor used for both cache validation and reading.
///
/// Keeping the descriptor open closes the check/reopen race: an atomic rename
/// after `open` cannot make `read` consume a different file generation.
final class BoundedRegularFileLease: @unchecked Sendable {
    let canonicalURL: URL
    let generation: BoundedRegularFileGeneration
    fileprivate let descriptor: Int32
    fileprivate let maximumBytes: Int
    fileprivate let fileStatusForTesting: BoundedRegularFileReader.FileStatus?

    fileprivate init(
        descriptor: Int32,
        maximumBytes: Int,
        canonicalURL: URL,
        generation: BoundedRegularFileGeneration,
        fileStatusForTesting: BoundedRegularFileReader.FileStatus?
    ) {
        self.descriptor = descriptor
        self.maximumBytes = maximumBytes
        self.canonicalURL = canonicalURL
        self.generation = generation
        self.fileStatusForTesting = fileStatusForTesting
    }

    deinit { _ = Darwin.close(descriptor) }

    func read(
        cancellationCheck: @Sendable () -> Bool = { Task.isCancelled },
        preadForTesting: BoundedRegularFileReader.Pread? = nil
    ) throws -> BoundedRegularFileSnapshot {
        try BoundedRegularFileReader.read(
            from: self,
            cancellationCheck: cancellationCheck,
            preadForTesting: preadForTesting)
    }
}

enum BoundedRegularFileReader {
    /// Synchronous injection seams for deterministic syscall-failure tests.
    /// Production callers always leave these nil and use Darwin directly.
    typealias Open = (
        _ path: UnsafePointer<CChar>,
        _ flags: Int32
    ) -> Int32

    typealias FileStatus = (
        _ descriptor: Int32,
        _ status: UnsafeMutablePointer<stat>
    ) -> Int32

    typealias GetPath = (
        _ descriptor: Int32,
        _ buffer: UnsafeMutableRawPointer
    ) -> Int32

    typealias Pread = (
        _ descriptor: Int32,
        _ buffer: UnsafeMutableRawPointer,
        _ byteCount: Int,
        _ offset: off_t
    ) -> Int

    private static let chunkBytes = 64 * 1_024
    private static let maximumInterruptedSystemCallRetries = 8

    /// Retries a signal-interrupted syscall without permitting an unbounded,
    /// cancellation-blind loop. The initial call is followed by at most eight
    /// retries. `close` deliberately does not use this helper: retrying a
    /// failed close can close an unrelated descriptor if the number was
    /// already released and reused.
    private static func performingSystemCall<Result>(
        cancellationCheck: @Sendable () -> Bool,
        operation: () -> Result
    ) throws -> Result where Result: FixedWidthInteger & SignedInteger {
        var interruptedRetries = 0
        while true {
            let result = operation()
            guard result < 0 else { return result }

            // Capture errno immediately. Unsafe-buffer and URL wrappers are
            // free to do work after their closure returns, and cancellation
            // callbacks can also change the thread-local value.
            let failureCode = errno == 0 ? EIO : errno
            guard failureCode == EINTR else {
                throw BoundedRegularFileReadError.systemCall(code: failureCode)
            }

            if cancellationCheck() { throw CancellationError() }
            guard interruptedRetries < maximumInterruptedSystemCallRetries else {
                throw BoundedRegularFileReadError.systemCall(code: failureCode)
            }
            interruptedRetries += 1
        }
    }

    private static func fileStatus(
        _ descriptor: Int32,
        into status: inout stat,
        cancellationCheck: @Sendable () -> Bool,
        fileStatusForTesting: FileStatus?
    ) throws {
        try withUnsafeMutablePointer(to: &status) { pointer in
            _ = try performingSystemCall(cancellationCheck: cancellationCheck) {
                if let fileStatusForTesting {
                    return fileStatusForTesting(descriptor, pointer)
                }
                return Darwin.fstat(descriptor, pointer)
            }
        }
    }

    /// Whether a URL carries only local filesystem authority.
    ///
    /// Foundation exposes the local path of `file://remote-host/path`; using
    /// that path without checking its authority silently turns a hostile file
    /// URL into a local read. `localhost` is the sole explicit local host.
    static func hasLocalFileAuthority(_ url: URL) -> Bool {
        guard url.isFileURL,
            url.path.hasPrefix("/"),
            url.user == nil,
            url.password == nil,
            url.port == nil,
            url.query == nil,
            url.fragment == nil
        else { return false }
        guard let host = url.host, !host.isEmpty else { return true }
        return host.caseInsensitiveCompare("localhost") == .orderedSame
    }

    /// Rewrites only macOS's fixed compatibility aliases. It does not resolve
    /// caller-controlled symlinks: `O_NOFOLLOW_ANY` below remains authoritative
    /// for every leaf and intermediate component after this narrow rewrite.
    static func replacingSystemCompatibilityAlias(in url: URL) -> URL {
        // This helper returns a URL rather than an optional, so preserve a
        // refused value verbatim. Standardizing first would erase a remote
        // host or resolve a relative `file:` URL against the process cwd and
        // turn validation missed by a future caller into local authority.
        guard hasLocalFileAuthority(url) else { return url }
        let path = url.standardizedFileURL.path
        for (alias, physical) in [
            ("/var", "/private/var"),
            ("/tmp", "/private/tmp"),
            ("/etc", "/private/etc"),
        ] {
            if path == alias {
                return URL(fileURLWithPath: physical, isDirectory: url.hasDirectoryPath)
            }
            let prefix = alias + "/"
            if path.hasPrefix(prefix) {
                return URL(
                    fileURLWithPath: physical + String(path.dropFirst(alias.count)),
                    isDirectory: url.hasDirectoryPath)
            }
        }
        return url.standardizedFileURL
    }

    /// Opens a finite regular file without following any symlink and retains
    /// the descriptor for a generation-bound cache check or read.
    static func open(
        _ requestedURL: URL,
        maximumBytes: Int,
        cancellationCheck: @Sendable () -> Bool = { Task.isCancelled },
        openForTesting: Open? = nil,
        fileStatusForTesting: FileStatus? = nil,
        getPathForTesting: GetPath? = nil
    ) throws -> BoundedRegularFileLease {
        guard maximumBytes >= 0, maximumBytes < Int.max else {
            throw BoundedRegularFileReadError.invalidLimit
        }
        guard hasLocalFileAuthority(requestedURL) else {
            throw BoundedRegularFileReadError.notFileURL
        }
        guard !requestedURL.hasDirectoryPath else {
            throw BoundedRegularFileReadError.notRegularFile
        }
        if cancellationCheck() { throw CancellationError() }

        let url = replacingSystemCompatibilityAlias(in: requestedURL)
        let descriptor = try url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                throw BoundedRegularFileReadError.systemCall(code: EINVAL)
            }
            let flags = O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW_ANY
            return try performingSystemCall(cancellationCheck: cancellationCheck) {
                if let openForTesting {
                    return openForTesting(path, flags)
                }
                return Darwin.open(path, flags)
            }
        }
        var closeOnFailure = true
        defer {
            if closeOnFailure { _ = Darwin.close(descriptor) }
        }

        var status = stat()
        try fileStatus(
            descriptor,
            into: &status,
            cancellationCheck: cancellationCheck,
            fileStatusForTesting: fileStatusForTesting)
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw BoundedRegularFileReadError.notRegularFile
        }
        guard status.st_size >= 0, status.st_size <= off_t(maximumBytes) else {
            throw BoundedRegularFileReadError.tooLarge(maximumBytes: maximumBytes)
        }
        if cancellationCheck() { throw CancellationError() }

        var pathBytes = [CChar](repeating: 0, count: Int(PATH_MAX))
        try pathBytes.withUnsafeMutableBytes { storage in
            guard let base = storage.baseAddress else {
                throw BoundedRegularFileReadError.systemCall(code: EINVAL)
            }
            _ = try performingSystemCall(cancellationCheck: cancellationCheck) {
                if let getPathForTesting {
                    return getPathForTesting(descriptor, base)
                }
                return Darwin.fcntl(descriptor, F_GETPATH, base)
            }
        }

        let canonicalURL = replacingSystemCompatibilityAlias(
            in: URL(fileURLWithPath: String(cString: pathBytes)).standardizedFileURL)
        let lease = BoundedRegularFileLease(
            descriptor: descriptor,
            maximumBytes: maximumBytes,
            canonicalURL: canonicalURL,
            generation: BoundedRegularFileGeneration(status),
            fileStatusForTesting: fileStatusForTesting)
        closeOnFailure = false
        return lease
    }

    /// Reads a finite, stable regular file without following any symlink.
    ///
    /// `O_NONBLOCK` ensures a mistakenly supplied FIFO or device reaches the
    /// type check without waiting for another process. The second descriptor
    /// fingerprint rejects a torn snapshot if the file changes during reads.
    static func read(
        _ requestedURL: URL,
        maximumBytes: Int,
        cancellationCheck: @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> BoundedRegularFileSnapshot {
        let lease = try open(
            requestedURL,
            maximumBytes: maximumBytes,
            cancellationCheck: cancellationCheck)
        return try lease.read(cancellationCheck: cancellationCheck)
    }

    fileprivate static func read(
        from lease: BoundedRegularFileLease,
        cancellationCheck: @Sendable () -> Bool,
        preadForTesting: Pread? = nil
    ) throws -> BoundedRegularFileSnapshot {
        if cancellationCheck() { throw CancellationError() }

        // Namespace operations after `open` can legitimately change link
        // count and ctime on the retained inode. Snapshot immediately before
        // reading so an already-completed atomic replacement still yields the
        // coherent old descriptor bytes, while any mutation during `pread`
        // remains a changed-read failure.
        var before = stat()
        try fileStatus(
            lease.descriptor,
            into: &before,
            cancellationCheck: cancellationCheck,
            fileStatusForTesting: lease.fileStatusForTesting)
        guard before.st_mode & S_IFMT == S_IFREG else {
            throw BoundedRegularFileReadError.notRegularFile
        }
        guard before.st_size >= 0, before.st_size <= off_t(lease.maximumBytes) else {
            throw BoundedRegularFileReadError.tooLarge(maximumBytes: lease.maximumBytes)
        }
        let readGeneration = BoundedRegularFileGeneration(before)

        let inspectionLimit = lease.maximumBytes + 1
        var data = Data()
        data.reserveCapacity(min(lease.maximumBytes, Int(readGeneration.size)))
        var buffer = [UInt8](
            repeating: 0,
            count: min(Self.chunkBytes, inspectionLimit))

        while data.count < inspectionLimit {
            if cancellationCheck() { throw CancellationError() }
            let requested = min(buffer.count, inspectionLimit - data.count)
            let count: Int = try buffer.withUnsafeMutableBytes { storage in
                guard let base = storage.baseAddress else { return 0 }
                return try performingSystemCall(cancellationCheck: cancellationCheck) {
                    if let preadForTesting {
                        return preadForTesting(
                            lease.descriptor,
                            base,
                            requested,
                            off_t(data.count))
                    }
                    return Darwin.pread(
                        lease.descriptor,
                        base,
                        requested,
                        off_t(data.count))
                }
            }
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }

        guard data.count <= lease.maximumBytes else {
            throw BoundedRegularFileReadError.tooLarge(maximumBytes: lease.maximumBytes)
        }

        var after = stat()
        try fileStatus(
            lease.descriptor,
            into: &after,
            cancellationCheck: cancellationCheck,
            fileStatusForTesting: lease.fileStatusForTesting)
        guard BoundedRegularFileGeneration(after) == readGeneration,
            after.st_size == off_t(data.count)
        else {
            throw BoundedRegularFileReadError.changedDuringRead
        }
        if cancellationCheck() { throw CancellationError() }

        return BoundedRegularFileSnapshot(
            data: data,
            canonicalURL: lease.canonicalURL,
            generation: readGeneration)
    }
}
