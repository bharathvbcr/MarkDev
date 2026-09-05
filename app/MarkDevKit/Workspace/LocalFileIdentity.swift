//
//  LocalFileIdentity.swift
//  MarkDevKit
//
//  Canonical, filesystem-backed identity for document and cache boundaries.
//

import Darwin
import Foundation

/// A file's identity on one mounted filesystem.
///
/// Paths cannot provide this guarantee: symbolic links and hard links give one
/// inode several names. Generation plus birth time closes the (small, but
/// real) gap where an inode number is recycled after an atomic replacement,
/// including filesystems that leave one of those fields unavailable.
struct LocalFileIdentity: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
    let generation: UInt32
    let birthSeconds: Int64
    let birthNanoseconds: Int64

    init(_ status: stat) {
        device = UInt64(truncatingIfNeeded: status.st_dev)
        inode = UInt64(truncatingIfNeeded: status.st_ino)
        generation = status.st_gen
        birthSeconds = Int64(status.st_birthtimespec.tv_sec)
        birthNanoseconds = Int64(status.st_birthtimespec.tv_nsec)
    }
}

/// Metadata needed to decide whether cached bytes still name the exact file
/// version that was read.
struct LocalFileStamp: Equatable, Sendable {
    let identity: LocalFileIdentity
    let size: Int
    let linkCount: UInt64
    let mode: mode_t
    let ownerID: uid_t
    let groupID: gid_t
    let flags: UInt32
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    init?(_ status: stat) {
        guard status.st_mode & S_IFMT == S_IFREG,
            status.st_size >= 0,
            let size = Int(exactly: status.st_size)
        else { return nil }
        identity = LocalFileIdentity(status)
        self.size = size
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

/// Full no-follow identity approved for one move-to-Trash operation.
///
/// This is intentionally stronger than device/inode/type. Inodes can be
/// recycled, and metadata changes after confirmation must invalidate consent.
/// Every field is copied from one `fstat` on the opened final entry, so the
/// snapshot cannot combine attributes from two pathname resolutions.
public struct SecureTrashTarget: Equatable, Sendable {
    private struct Identity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let generation: UInt32
        let birthSeconds: Int64
        let birthNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64
        let mode: mode_t
        let ownerID: uid_t
        let groupID: gid_t
        let linkCount: UInt64
        let size: Int64
        let flags: UInt32

        init(_ status: stat) {
            device = UInt64(truncatingIfNeeded: status.st_dev)
            inode = UInt64(truncatingIfNeeded: status.st_ino)
            generation = status.st_gen
            birthSeconds = Int64(status.st_birthtimespec.tv_sec)
            birthNanoseconds = Int64(status.st_birthtimespec.tv_nsec)
            changedSeconds = Int64(status.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(status.st_ctimespec.tv_nsec)
            mode = status.st_mode
            ownerID = status.st_uid
            groupID = status.st_gid
            linkCount = UInt64(status.st_nlink)
            size = Int64(status.st_size)
            flags = status.st_flags
        }
    }

    public enum MutationResult: Equatable, Sendable {
        case moved
        case stale
    }

    public let url: URL
    private let identity: Identity

    public init(at url: URL) throws {
        guard BoundedRegularFileReader.hasLocalFileAuthority(url) else {
            throw LocalFileResolutionError.notAFileURL(url)
        }
        self.url = url.standardizedFileURL
        identity = try Self.captureIdentity(at: self.url)
    }

    /// Re-opens the final directory entry without following a symlink and
    /// compares the complete descriptor snapshot.
    public func matchesCurrentEntry() throws -> Bool {
        try Self.captureIdentity(at: url) == identity
    }

    /// Revalidates immediately before asking Foundation to move the path.
    ///
    /// `FileManager.trashItem` exposes no descriptor-relative or conditional
    /// mutation API. An equal-UID process can therefore still replace the
    /// pathname in the final interval between this check and Foundation's
    /// internal rename. Keeping both operations in this one synchronous seam
    /// removes application-level awaits but cannot claim OS-level atomicity.
    public func moveToTrashIfCurrent() throws -> MutationResult {
        guard try matchesCurrentEntry() else { return .stale }
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        return .moved
    }

    private static func captureIdentity(at url: URL) throws -> Identity {
        var savedErrno: Int32 = EINVAL
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            errno = 0
            let descriptor = Darwin.open(
                path,
                O_EVTONLY | O_CLOEXEC | O_NOFOLLOW)
            if descriptor < 0 { savedErrno = errno }
            return descriptor
        }
        guard descriptor >= 0 else {
            throw LocalFileResolutionError.posix(url, savedErrno)
        }
        defer { Darwin.close(descriptor) }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw LocalFileResolutionError.posix(url, errno)
        }
        let kind = status.st_mode & S_IFMT
        guard kind == S_IFREG || kind == S_IFDIR else {
            throw LocalFileResolutionError.unsupportedFile(url)
        }
        return Identity(status)
    }
}

struct ResolvedLocalFile: Sendable {
    let url: URL
    let stamp: LocalFileStamp

    var identity: LocalFileIdentity { stamp.identity }
}

enum LocalFileResolutionError: Error {
    case notAFileURL(URL)
    case unsupportedFile(URL)
    case unsafeDestination(URL)
    case posix(URL, Int32)
}

/// One resolution seam for opening, comparing, and saving local documents.
enum LocalFileSystem {
    /// Resolves every symbolic-link component and identifies the resulting
    /// regular file. Hard-linked spellings intentionally retain their paths;
    /// callers compare the returned inode identity as well.
    static func resolveExisting(_ requestedURL: URL) throws -> ResolvedLocalFile {
        guard BoundedRegularFileReader.hasLocalFileAuthority(requestedURL) else {
            throw LocalFileResolutionError.notAFileURL(requestedURL)
        }
        let requested = requestedURL.standardizedFileURL
        let physical: URL
        do {
            physical = try realPath(of: requested)
        } catch let LocalFileResolutionError.posix(_, code) {
            throw LocalFileResolutionError.posix(requested, code)
        }

        var status = stat()
        let result = physical.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.fstatat(AT_FDCWD, $0, &status, 0) } ?? -1
        }
        guard result == 0 else {
            throw LocalFileResolutionError.posix(physical, errno)
        }
        guard let stamp = LocalFileStamp(status) else {
            throw LocalFileResolutionError.unsupportedFile(physical)
        }
        // Keep Foundation's platform spelling (`/var`, for example) while
        // resolving the caller-controlled alias. Identity, not this display
        // path, is the authority used for deduplication.
        let presented = requested.resolvingSymlinksInPath().standardizedFileURL
        return ResolvedLocalFile(url: presented, stamp: stamp)
    }

    /// Resolves an existing destination to its target. For a new file, the
    /// parent is resolved first so a symlinked directory cannot create a
    /// second spelling of the same destination. A dangling/looping final
    /// symlink is rejected rather than silently replaced.
    static func resolveDestination(_ requestedURL: URL) throws -> (url: URL, identity: LocalFileIdentity?) {
        guard BoundedRegularFileReader.hasLocalFileAuthority(requestedURL) else {
            throw LocalFileResolutionError.notAFileURL(requestedURL)
        }
        let requested = requestedURL.standardizedFileURL
        do {
            let existing = try resolveExisting(requested)
            return (existing.url, existing.identity)
        } catch let LocalFileResolutionError.posix(_, code) {
            var entry = stat()
            let entryExists = requested.withUnsafeFileSystemRepresentation { path in
                path.map { Darwin.lstat($0, &entry) } ?? -1
            } == 0
            if entryExists, entry.st_mode & S_IFMT == S_IFLNK {
                throw LocalFileResolutionError.unsafeDestination(requested)
            }
            guard !entryExists, code == ENOENT else {
                throw LocalFileResolutionError.posix(requested, code)
            }

            let parent = requested.deletingLastPathComponent()
            do {
                _ = try realPath(of: parent)
            } catch let LocalFileResolutionError.posix(_, parentCode) {
                throw LocalFileResolutionError.posix(parent, parentCode)
            }
            let canonicalParent = parent.resolvingSymlinksInPath().standardizedFileURL
            return (
                canonicalParent.appendingPathComponent(requested.lastPathComponent),
                nil)
        } catch {
            throw error
        }
    }

    /// Fresh metadata without URL resource-value caching.
    static func stamp(of url: URL) -> LocalFileStamp? {
        guard BoundedRegularFileReader.hasLocalFileAuthority(url) else { return nil }
        var status = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.fstatat(AT_FDCWD, $0, &status, 0) } ?? -1
        }
        guard result == 0 else { return nil }
        return LocalFileStamp(status)
    }

    /// Physical spelling used for descriptor-based I/O. Unlike Foundation's
    /// presentation URL, this resolves macOS system aliases such as `/var` so
    /// `O_NOFOLLOW_ANY` can safely reject a later symlink substitution.
    static func canonicalIOURL(_ url: URL) -> URL {
        (try? realPath(of: url.standardizedFileURL)) ?? url.standardizedFileURL
    }

    private static func realPath(of url: URL) throws -> URL {
        var savedErrno: Int32 = EINVAL
        let resolved: String? = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return nil }
            errno = 0
            guard let pointer = Darwin.realpath(path, nil) else {
                savedErrno = errno
                return nil
            }
            defer { free(pointer) }
            return String(cString: pointer)
        }
        guard let resolved else {
            throw LocalFileResolutionError.posix(url, savedErrno)
        }
        return URL(fileURLWithPath: resolved)
    }
}
