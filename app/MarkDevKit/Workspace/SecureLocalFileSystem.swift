//
//  SecureLocalFileSystem.swift
//  MarkDevKit
//
//  Descriptor-relative, exactly-versioned local file transactions.
//

import CryptoKit
import Darwin
import Foundation

/// One path component accepted by descriptor-relative storage APIs.
///
/// A component can never change the directory a caller already opened. Paths,
/// separators, dot entries, and NUL therefore do not cross this boundary.
struct FileComponent: Hashable, Sendable {
    static let portableMaximumBytes = 255
    let rawValue: String

    init(_ rawValue: String) throws {
        guard BoundedText.acceptedUTF8ByteCount(
            rawValue, maximum: Self.portableMaximumBytes) != nil,
            !rawValue.isEmpty,
            rawValue != ".", rawValue != "..",
            !rawValue.contains("/"),
            !rawValue.unicodeScalars.contains(where: { $0.value == 0 })
        else { throw SecureLocalFileError.invalidComponent }
        self.rawValue = rawValue
    }
}

/// Process-local identity for one child name in one physical directory.
///
/// A URL path is not an authority key: aliases can spell the same parent in
/// several ways, ancestors can be renamed while a save is in flight, and a
/// case-insensitive volume can bind differently-cased names to one entry. The
/// parent inode plus a volume-aware canonical component keeps reservations and
/// retained recovery authority on the same physical namespace boundary as the
/// descriptor-relative transaction.
struct FileDestinationReservationAlias: Hashable, Sendable {
    let directoryIdentity: LocalFileIdentity
    let normalizedComponent: String
}

struct FileDestinationKey: Hashable, Sendable {
    let directoryIdentity: LocalFileIdentity
    /// Exact UTF-8 bytes passed to descriptor-relative *at syscalls. Swift
    /// String equality is canonically equivalent, so it cannot be the
    /// recovery dictionary key on a normalization-sensitive filesystem.
    let componentBytes: Data
    /// Conservative alias used only to refuse overlapping in-flight work.
    /// It must never select or transfer reusable recovery authority.
    let reservationAlias: FileDestinationReservationAlias

    init(
        directoryIdentity: LocalFileIdentity,
        component: FileComponent,
        caseSensitiveNames: Bool?
    ) {
        let canonicallyNormalized = component.rawValue.precomposedStringWithCanonicalMapping
        let normalizedComponent: String
        if caseSensitiveNames == true {
            normalizedComponent = canonicallyNormalized
        } else {
            // Unknown capability is handled conservatively: treating two
            // distinct names as one can refuse work, while treating one name
            // as two could concurrently mutate a shared destination.
            normalizedComponent = canonicallyNormalized.folding(
                options: [.caseInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            ).precomposedStringWithCanonicalMapping
        }
        self.directoryIdentity = directoryIdentity
        componentBytes = Data(component.rawValue.utf8)
        reservationAlias = FileDestinationReservationAlias(
            directoryIdentity: directoryIdentity,
            normalizedComponent: normalizedComponent)
    }
}

private struct FileVolumeCapabilitiesBuffer {
    var length: UInt32 = 0
    var capabilities = vol_capabilities_attr_t()
}

/// The exact regular-file version authorized for replacement.
///
/// Metadata catches ordinary replacement cheaply. The digest closes the case
/// where an attacker forges timestamps and byte counts, and is computed from
/// the same descriptor as the metadata rather than from a second path lookup.
struct FileVersionToken: Equatable, Sendable {
    let identity: LocalFileIdentity
    let size: Int
    let mode: mode_t
    let ownerID: uid_t
    let groupID: gid_t
    let flags: UInt32
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
    let linkCount: UInt64
    let sha256: Data

    init(stamp: LocalFileStamp, sha256: Data) {
        identity = stamp.identity
        size = stamp.size
        mode = stamp.mode
        ownerID = stamp.ownerID
        groupID = stamp.groupID
        flags = stamp.flags
        modifiedSeconds = stamp.modifiedSeconds
        modifiedNanoseconds = stamp.modifiedNanoseconds
        changedSeconds = stamp.changedSeconds
        changedNanoseconds = stamp.changedNanoseconds
        linkCount = stamp.linkCount
        self.sha256 = sha256
    }

    init?(status: stat, sha256: Data) {
        guard let stamp = LocalFileStamp(status) else { return nil }
        self.init(stamp: stamp, sha256: sha256)
    }

    /// `st_gen` is intentionally excluded. Darwin documents it as available
    /// only to superusers, so a normal app cannot use it as a stable CAS field.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.identity.device == rhs.identity.device
            && lhs.identity.inode == rhs.identity.inode
            && lhs.identity.birthSeconds == rhs.identity.birthSeconds
            && lhs.identity.birthNanoseconds == rhs.identity.birthNanoseconds
            && lhs.size == rhs.size
            && lhs.mode == rhs.mode
            && lhs.ownerID == rhs.ownerID
            && lhs.groupID == rhs.groupID
            && lhs.flags == rhs.flags
            && lhs.modifiedSeconds == rhs.modifiedSeconds
            && lhs.modifiedNanoseconds == rhs.modifiedNanoseconds
            && lhs.changedSeconds == rhs.changedSeconds
            && lhs.changedNanoseconds == rhs.changedNanoseconds
            && lhs.linkCount == rhs.linkCount
            && lhs.sha256 == rhs.sha256
    }

    /// `renameatx_np(RENAME_SWAP)` advances ctime on APFS for both inodes.
    /// Every other authority field must remain identical when validating the
    /// file displaced by that one known metadata mutation.
    func matchesAcrossRename(_ other: Self) -> Bool {
        identity.device == other.identity.device
            && identity.inode == other.identity.inode
            && identity.birthSeconds == other.identity.birthSeconds
            && identity.birthNanoseconds == other.identity.birthNanoseconds
            && size == other.size
            && mode == other.mode
            && ownerID == other.ownerID
            && groupID == other.groupID
            && flags == other.flags
            && modifiedSeconds == other.modifiedSeconds
            && modifiedNanoseconds == other.modifiedNanoseconds
            && linkCount == other.linkCount
            && sha256 == other.sha256
    }
}

enum FileTransactionExpectation: Equatable, Sendable {
    case missing
    case exact(FileVersionToken)
}

enum FileTransactionDurability: Equatable, Sendable {
    /// Publication never happened. The exact staged inode remains under the
    /// receipt's component and token because Darwin has no public
    /// identity-conditional unlink primitive.
    case notPublishedRecoveryRetained
    /// Publication never happened, but the stage name could not be proven to
    /// still identify the held inode. No recovery authority is advertised.
    case notPublishedRecoveryUnconfirmed(
        operation: SecureLocalFileOperation?,
        errno: Int32?)
    case fullySynced
    /// The new name is visible and its bytes were synced, but the directory
    /// sync failed. A power loss may therefore lose the rename.
    case committedDirectorySyncUnconfirmed(errno: Int32)
    /// Publication completed and the exact displaced version was retained
    /// intentionally. Directory durability remains an orthogonal fact.
    case recoveryRetained(directorySyncErrno: Int32?)
    /// Publication happened, but a post-publication verification could not
    /// establish every resulting name. No compensating pathname mutation is
    /// attempted because another process can reuse the hidden stage name.
    case indeterminate(operation: SecureLocalFileOperation?, errno: Int32?)
}

/// One indivisible, descriptor-relative recovery capability. Keeping the name
/// and exact token in one value makes half-authority states unrepresentable.
struct FileRecoveryAuthority: Equatable, Sendable {
    let component: FileComponent
    let version: FileVersionToken
    /// Descriptor-derived namespace scope of the destination that minted this
    /// capability. A genuine slot from another transaction cannot be
    /// transplanted to an unrelated path merely by wrapping it in a receipt.
    let destinationKey: FileDestinationKey

    fileprivate init(
        component: FileComponent,
        version: FileVersionToken,
        destinationKey: FileDestinationKey
    ) {
        self.component = component
        self.version = version
        self.destinationKey = destinationKey
    }
}

enum FileRecoveryContents: Equatable, Sendable {
    /// Exact predecessor bytes displaced by an overwrite, or retained before
    /// scratch mutation began. Missing-target publication must not consume it.
    case previousDestination
    /// Unpublished staged bytes that may safely be rewritten for a retry.
    case unpublishedScratch
}

/// Exact filesystem capability and its semantic role travel together. A
/// retry must never infer that role from the destination expectation: an
/// unpublished missing-target scratch file and an overwritten predecessor can
/// have the same name/token shape but different safe consumers.
struct FileRecoverySlot: Equatable, Sendable {
    let authority: FileRecoveryAuthority
    let contents: FileRecoveryContents
}

/// Uninhabited marker used only by the `recovery: nil` convenience receipt
/// initializer. Non-nil recovery must use the typed `FileRecoverySlot` path.
enum NoFileRecovery: Sendable {}

/// Authenticated namespace and presentation observation minted only by the
/// descriptor-relative transaction. Keeping the URL inside the binding stops
/// a receipt adapter from combining a genuine recovery slot for A with a
/// forged UI destination B.
struct FileTransactionDestinationBinding: Equatable, Sendable {
    let key: FileDestinationKey
    let presentationURL: URL

    fileprivate init(key: FileDestinationKey, presentationURL: URL) {
        self.key = key
        self.presentationURL = presentationURL.standardizedFileURL
    }
}

struct FileTransactionReceipt: Equatable, Sendable {
    let destination: URL
    let version: FileVersionToken?
    let durability: FileTransactionDurability
    /// Descriptor-derived namespace provenance when produced by the secure
    /// transaction. Test adapters that synthesize no-recovery receipts retain
    /// a URL-equality fallback at the Workspace boundary, but can never attach
    /// or transplant recovery authority without this exact scope.
    fileprivate let destinationBinding: FileTransactionDestinationBinding?
    var destinationKey: FileDestinationKey? { destinationBinding?.key }
    /// Exact authority observed at receipt construction. It is intentionally
    /// advisory across time: recovery must reacquire the parent descriptor and
    /// revalidate the complete token before reading or mutating this name.
    let recoverySlot: FileRecoverySlot?

    var recovery: FileRecoveryAuthority? { recoverySlot?.authority }
    var recoveryContents: FileRecoveryContents? { recoverySlot?.contents }
    var recoveryComponent: FileComponent? { recoverySlot?.authority.component }
    var recoveryVersion: FileVersionToken? { recoverySlot?.authority.version }

    init(
        destination: URL,
        version: FileVersionToken?,
        durability: FileTransactionDurability,
        recoverySlot: FileRecoverySlot?
    ) {
        self.destination = destination
        self.version = version
        self.durability = durability
        self.recoverySlot = recoverySlot
        destinationBinding = nil
    }

    fileprivate init(
        destination: URL,
        version: FileVersionToken?,
        durability: FileTransactionDurability,
        recoverySlot: FileRecoverySlot?,
        authoritativeDestinationKey: FileDestinationKey
    ) {
        precondition(
            recoverySlot == nil
                || recoverySlot?.authority.destinationKey == authoritativeDestinationKey)
        self.destination = destination
        self.version = version
        self.durability = durability
        self.recoverySlot = recoverySlot
        destinationBinding = FileTransactionDestinationBinding(
            key: authoritativeDestinationKey,
            presentationURL: destination)
    }

    /// Convenience for receipts that prove there is no retained recovery.
    /// The uninhabited argument type makes inventing a non-nil role impossible.
    init(
        destination: URL,
        version: FileVersionToken?,
        durability: FileTransactionDurability,
        recovery: NoFileRecovery?
    ) {
        self.init(
            destination: destination,
            version: version,
            durability: durability,
            recoverySlot: nil)
    }

    var isValidPrepublicationFailure: Bool {
        guard version == nil else { return false }
        switch durability {
        case .notPublishedRecoveryRetained:
            return recoverySlot != nil
        case .notPublishedRecoveryUnconfirmed:
            return recoverySlot == nil
        case .fullySynced, .committedDirectorySyncUnconfirmed,
            .recoveryRetained, .indeterminate:
            return false
        }
    }

    func isValidCommittedState(
        for expectation: FileTransactionExpectation
    ) -> Bool {
        guard version != nil else { return false }
        switch (expectation, durability) {
        case (.missing, .fullySynced),
            (.missing, .committedDirectorySyncUnconfirmed),
            (.exact, .fullySynced),
            (.exact, .committedDirectorySyncUnconfirmed):
            return recoverySlot == nil
        case (.exact(let expected), .recoveryRetained):
            return recoverySlot?.contents == .previousDestination
                && recoverySlot?.authority.version.matchesAcrossRename(expected) == true
        case (.missing, .recoveryRetained),
            (_, .notPublishedRecoveryRetained),
            (_, .notPublishedRecoveryUnconfirmed),
            (_, .indeterminate):
            return false
        }
    }

    func isBound(
        to authorizedKey: FileDestinationKey,
        destination authorizedDestination: URL
    ) -> Bool {
        if let destinationBinding {
            return destinationBinding.key == authorizedKey
                && destinationBinding.presentationURL == destination.standardizedFileURL
                && destinationBinding.presentationURL
                    == authorizedDestination.standardizedFileURL
        }
        // Compatibility is intentionally limited to synthetic, no-recovery
        // adapters. Filesystem recovery authority is never accepted on URL
        // spelling alone.
        return recoverySlot == nil
            && destination.standardizedFileURL == authorizedDestination.standardizedFileURL
    }

    func replacingDurability(
        _ durability: FileTransactionDurability
    ) -> FileTransactionReceipt {
        if let destinationBinding {
            return FileTransactionReceipt(
                destination: destination,
                version: version,
                durability: durability,
                recoverySlot: recoverySlot,
                authoritativeDestinationKey: destinationBinding.key)
        }
        return FileTransactionReceipt(
            destination: destination,
            version: version,
            durability: durability,
            recoverySlot: recoverySlot)
    }
}

enum SecureLocalFileOperation: String, Equatable, Sendable {
    case openDirectory
    case inspect
    case openTarget
    case createDocument
    case createStage
    case truncate
    case seek
    case write
    case metadata
    case syncFile
    case publish
    case verify
    case syncDirectory
}

/// One finite policy for syscalls that may report `EINTR` before their effect.
/// Rename and close are deliberately excluded: retrying either after an
/// interrupted return can repeat an effect whose completion is ambiguous.
private enum InterruptedSyscall {
    static let maximumAttempts = 8

    enum Outcome<Value> {
        case success(Value)
        case failure(errno: Int32)
        case cancelled
    }

    static func run<Value>(
        cancellationCheck: @Sendable () -> Bool,
        succeeds: (Value) -> Bool,
        _ operation: () -> Value
    ) -> Outcome<Value> {
        for attempt in 1...maximumAttempts {
            if cancellationCheck() { return .cancelled }
            errno = 0
            let value = operation()
            if succeeds(value) { return .success(value) }
            let code = errno == 0 ? EIO : errno
            if code != EINTR || attempt == maximumAttempts {
                return .failure(errno: code)
            }
        }
        preconditionFailure("finite retry loop exhausted without an outcome")
    }
}

private func requireSystemCall<Value>(
    _ operation: SecureLocalFileOperation,
    cancellationCheck: @Sendable () -> Bool,
    succeeds: (Value) -> Bool,
    _ body: () -> Value
) throws -> Value {
    switch InterruptedSyscall.run(
        cancellationCheck: cancellationCheck,
        succeeds: succeeds,
        body)
    {
    case .success(let value):
        return value
    case .failure(let code):
        throw SecureLocalFileError.operation(operation, errno: code)
    case .cancelled:
        throw SecureLocalFileError.cancelled
    }
}

indirect enum SecureLocalFileError: Error, Equatable, LocalizedError {
    case invalidComponent
    case unsupportedEntry
    case fileTooLarge(maximumBytes: Int)
    case hardLinkedEntry
    case unsupportedFileMode(mode_t)
    case unsupportedFileFlags(UInt32)
    case expectationMismatch
    case operation(SecureLocalFileOperation, errno: Int32)
    case cancelled
    case recoveryJournal(RecoveryJournalError)
    /// A previously retained recovery name could not be reacquired and proven
    /// to identify its exact inode before any mutation began. The old receipt
    /// is no longer reusable process authority and requires explicit review.
    case recoverySlotUnavailable(cause: SecureLocalFileError)
    /// The original failure still prevented publication, and an exact staged
    /// artifact was retained intentionally. Neither fact may hide the other.
    case prepublicationFailure(
        cause: SecureLocalFileError,
        receipt: FileTransactionReceipt)
    case indeterminate(FileTransactionReceipt)

    var errorDescription: String? {
        switch self {
        case .invalidComponent:
            "The file name is not safe to use."
        case .unsupportedEntry:
            "The destination is not a regular file or directory."
        case .fileTooLarge(let maximumBytes):
            "The existing destination exceeds the safe \(maximumBytes)-byte limit."
        case .hardLinkedEntry:
            "The destination has more than one filesystem name and cannot be replaced safely."
        case .unsupportedFileMode:
            "The destination uses file mode bits that cannot be preserved safely."
        case .unsupportedFileFlags:
            "The destination uses file flags that cannot be preserved safely."
        case .expectationMismatch:
            "The destination changed before it could be saved."
        case .operation(_, let code):
            String(cString: strerror(code))
        case .cancelled:
            "The file operation was cancelled."
        case .recoveryJournal(let error):
            "The recovery journal could not be updated: \(error.localizedDescription)"
        case .recoverySlotUnavailable:
            "The retained recovery file could not be revalidated safely."
        case .prepublicationFailure:
            "The save was not published; its temporary file outcome is reported separately."
        case .indeterminate:
            "The destination changed during save and its final state could not be verified."
        }
    }
}

/// Injectable syscall table. Tests replace individual calls to force short
/// writes, EINTR, ENOSPC, fsync failures, and publication ambiguity without relying
/// on a particular filesystem or filling the developer's disk.
struct SecureFileSyscalls: @unchecked Sendable {
    var openPath: (UnsafePointer<CChar>, Int32) -> Int32
    var openAt: (Int32, UnsafePointer<CChar>, Int32) -> Int32
    var createAt: (Int32, UnsafePointer<CChar>, Int32, mode_t) -> Int32
    var mkdirAt: (Int32, UnsafePointer<CChar>, mode_t) -> Int32
    var fstat: (Int32, UnsafeMutablePointer<stat>) -> Int32
    var fstatAt: (Int32, UnsafePointer<CChar>, UnsafeMutablePointer<stat>, Int32) -> Int32
    var ftruncate: (Int32, off_t) -> Int32
    var lseek: (Int32, off_t, Int32) -> off_t
    var pread: (Int32, UnsafeMutableRawPointer?, Int, off_t) -> Int
    var pwrite: (Int32, UnsafeRawPointer?, Int, off_t) -> Int
    var read: (Int32, UnsafeMutableRawPointer?, Int) -> Int
    var write: (Int32, UnsafeRawPointer?, Int) -> Int
    var fchmod: (Int32, mode_t) -> Int32
    var fchown: (Int32, uid_t, gid_t) -> Int32
    var fchflags: (Int32, UInt32) -> Int32
    var fsync: (Int32) -> Int32
    var renameAtX: (Int32, UnsafePointer<CChar>, Int32, UnsafePointer<CChar>, UInt32) -> Int32
    var close: (Int32) -> Int32
    var fcntlGetPath: (Int32, UnsafeMutableRawPointer) -> Int32
    var fpathconf: (Int32, Int32) -> Int

    static let live = SecureFileSyscalls(
        openPath: { Darwin.open($0, $1) },
        openAt: { Darwin.openat($0, $1, $2) },
        createAt: { Darwin.openat($0, $1, $2, $3) },
        mkdirAt: { Darwin.mkdirat($0, $1, $2) },
        fstat: { Darwin.fstat($0, $1) },
        fstatAt: { Darwin.fstatat($0, $1, $2, $3) },
        ftruncate: { Darwin.ftruncate($0, $1) },
        lseek: { Darwin.lseek($0, $1, $2) },
        pread: { Darwin.pread($0, $1, $2, $3) },
        pwrite: { Darwin.pwrite($0, $1, $2, $3) },
        read: { Darwin.read($0, $1, $2) },
        write: { Darwin.write($0, $1, $2) },
        fchmod: { Darwin.fchmod($0, $1) },
        fchown: { Darwin.fchown($0, $1, $2) },
        fchflags: { Darwin.fchflags($0, $1) },
        fsync: { Darwin.fsync($0) },
        renameAtX: { Darwin.renameatx_np($0, $1, $2, $3, $4) },
        close: { Darwin.close($0) },
        fcntlGetPath: { Darwin.fcntl($0, F_GETPATH, $1) },
        fpathconf: { Darwin.fpathconf($0, $1) })
}

/// One descriptor-coherent bounded read. The bytes, metadata stamp, digest
/// authority, and canonical URL all describe the same retained regular-file
/// descriptor; no path reopen is used to manufacture authority afterward.
struct SecureLocalFileReadSnapshot: Sendable {
    let data: Data
    let stamp: LocalFileStamp
    let version: FileVersionToken
    let canonicalURL: URL
    let destinationKey: FileDestinationKey
}

/// Exact authority returned after publishing a new empty user document.
///
/// Creation itself is irreversible once `O_EXCL` succeeds. Durability is
/// therefore reported separately instead of turning a file-sync failure into
/// a generic failure that encourages a retry under a second name.
struct SecureLocalFileCreationSnapshot: Sendable {
    let read: SecureLocalFileReadSnapshot
    let fileSyncErrno: Int32?
    let directorySyncErrno: Int32?

    var isFullyDurable: Bool {
        fileSyncErrno == nil && directorySyncErrno == nil
    }
}

enum SecureLocalFileSystem {
    /// Resolves an explicitly selected symbolic link once, then binds its
    /// canonical parent and final component by descriptor. Hard links are safe
    /// to view and retain their link count in the returned token; replacement
    /// authorization applies the stricter single-link policy separately.
    static func read(
        _ requestedURL: URL,
        maximumBytes: Int,
        syscalls: SecureFileSyscalls = .live,
        cancellationCheck: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> SecureLocalFileReadSnapshot {
        precondition(maximumBytes >= 0, "read limit must not be negative")
        if cancellationCheck() { throw SecureLocalFileError.cancelled }

        let resolved: ResolvedLocalFile
        do {
            resolved = try LocalFileSystem.resolveExisting(requestedURL)
        } catch LocalFileResolutionError.unsupportedFile {
            throw SecureLocalFileError.unsupportedEntry
        } catch LocalFileResolutionError.notAFileURL {
            throw SecureLocalFileError.operation(.openTarget, errno: EINVAL)
        } catch LocalFileResolutionError.unsafeDestination {
            throw SecureLocalFileError.expectationMismatch
        } catch LocalFileResolutionError.posix(_, let code) {
            throw SecureLocalFileError.operation(.openTarget, errno: code)
        }
        if cancellationCheck() { throw SecureLocalFileError.cancelled }
        guard resolved.stamp.size <= maximumBytes else {
            throw SecureLocalFileError.fileTooLarge(maximumBytes: maximumBytes)
        }

        let canonicalTarget = LocalFileSystem.canonicalIOURL(resolved.url)
        let directory = try SecureLocalDirectoryHandle(
            opening: canonicalTarget.deletingLastPathComponent(),
            syscalls: syscalls,
            cancellationCheck: cancellationCheck)
        let component = try FileComponent(canonicalTarget.lastPathComponent)
        try directory.validateNameLimit(component)
        let descriptor = try directory.openRegularDescriptor(
            component,
            requireUniqueLink: false,
            cancellationCheck: cancellationCheck)
        defer { _ = syscalls.close(descriptor) }

        let inspected = try SecureLocalDirectoryHandle.contents(
            descriptor: descriptor,
            maximumBytes: maximumBytes,
            retainBytes: true,
            syscalls: syscalls,
            cancellationCheck: cancellationCheck)
        guard let data = inspected.data,
            let stamp = LocalFileStamp(inspected.status),
            stamp == resolved.stamp
        else { throw SecureLocalFileError.expectationMismatch }

        // The descriptor is authoritative for bytes, while this final
        // descriptor-relative lookup proves the requested name still denotes
        // that same version. It is not a path reopen and cannot redirect
        // outside the retained parent directory.
        guard let namedStatus = try directory.entryStatus(
            component,
            cancellationCheck: cancellationCheck),
            LocalFileStamp(namedStatus) == stamp
        else { throw SecureLocalFileError.expectationMismatch }
        try directory.verifyLocation()
        if cancellationCheck() { throw SecureLocalFileError.cancelled }
        return SecureLocalFileReadSnapshot(
            data: data,
            stamp: stamp,
            version: inspected.token,
            canonicalURL: directory.destinationURL(component),
            destinationKey: try directory.destinationKey(
                component,
                cancellationCheck: cancellationCheck))
    }
}

/// A retained, verified directory descriptor. Every child lookup below is
/// relative to this fd, so renaming or replacing an ancestor cannot redirect
/// an in-flight transaction.
final class SecureLocalDirectoryHandle: @unchecked Sendable {
    enum TrustedChildDisposition: Sendable {
        case existing(expectedIdentity: LocalFileIdentity?)
        /// Creation is deliberately one-shot. An interrupted `O_EXCL` return
        /// is not retried or reconciled from a later pathname observation,
        /// because that observation cannot prove which process created it.
        case createExclusive
    }

    struct TrustedRegularChild {
        let descriptor: Int32
        let status: stat
        let identity: LocalFileIdentity
        let wasCreated: Bool
    }

    let descriptor: Int32
    let url: URL
    let syscalls: SecureFileSyscalls
    private let closeOnDeinit: Bool
    private let directoryIdentity: LocalFileIdentity
    private let caseSensitiveNames: Bool?

    init(
        opening requestedURL: URL,
        syscalls: SecureFileSyscalls = .live,
        cancellationCheck: @Sendable () -> Bool = { Task.isCancelled }
    ) throws {
        guard BoundedRegularFileReader.hasLocalFileAuthority(requestedURL) else {
            throw SecureLocalFileError.operation(.openDirectory, errno: EINVAL)
        }
        let canonical = LocalFileSystem.canonicalIOURL(requestedURL)
        let descriptor: Int32 = try requireSystemCall(
            .openDirectory,
            cancellationCheck: cancellationCheck,
            succeeds: { $0 >= 0 }
        ) {
            canonical.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else {
                    errno = EINVAL
                    return -1
                }
                return syscalls.openPath(
                    path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK)
            }
        }
        var status = stat()
        do {
            _ = try requireSystemCall(
                .openDirectory,
                cancellationCheck: cancellationCheck,
                succeeds: { $0 == 0 }
            ) {
                syscalls.fstat(descriptor, &status)
            }
        } catch {
            _ = syscalls.close(descriptor)
            throw error
        }
        guard status.st_mode & S_IFMT == S_IFDIR else {
            _ = syscalls.close(descriptor)
            throw SecureLocalFileError.operation(.openDirectory, errno: ENOTDIR)
        }
        guard let actual = Self.actualURL(for: descriptor, syscalls: syscalls) else {
            let pathError = errno == 0 ? EIO : errno
            _ = syscalls.close(descriptor)
            throw SecureLocalFileError.operation(.openDirectory, errno: pathError)
        }
        self.descriptor = descriptor
        self.syscalls = syscalls
        closeOnDeinit = true
        directoryIdentity = LocalFileIdentity(status)
        caseSensitiveNames = Self.caseSensitiveNames(for: descriptor)
        url = actual
    }

    init(
        borrowed descriptor: Int32,
        url: URL,
        syscalls: SecureFileSyscalls = .live
    ) {
        var status = stat()
        precondition(syscalls.fstat(descriptor, &status) == 0)
        precondition(status.st_mode & S_IFMT == S_IFDIR)
        self.descriptor = descriptor
        self.url = url
        self.syscalls = syscalls
        closeOnDeinit = false
        directoryIdentity = LocalFileIdentity(status)
        caseSensitiveNames = Self.caseSensitiveNames(for: descriptor)
    }

    private init(
        owned descriptor: Int32,
        url: URL,
        status: stat,
        syscalls: SecureFileSyscalls
    ) {
        self.descriptor = descriptor
        self.url = url.standardizedFileURL
        self.syscalls = syscalls
        closeOnDeinit = true
        directoryIdentity = LocalFileIdentity(status)
        caseSensitiveNames = Self.caseSensitiveNames(for: descriptor)
    }

    deinit {
        if closeOnDeinit { _ = syscalls.close(descriptor) }
    }

    func version(
        of component: FileComponent,
        maximumBytes: Int = MarkdownReadLimits.maximumDocumentBytes,
        cancellationCheck: @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> FileVersionToken {
        precondition(maximumBytes >= 0, "version limit must not be negative")
        let opened = try openRegularFile(
            component,
            maximumBytes: maximumBytes,
            cancellationCheck: cancellationCheck)
        defer { _ = syscalls.close(opened.descriptor) }
        return opened.version
    }

    func transaction(
        component: FileComponent,
        data: Data,
        expectation: FileTransactionExpectation,
        policy: FileTransaction.Policy,
        maximumBytes: Int = MarkdownReadLimits.maximumDocumentBytes,
        reusableStage: FileRecoverySlot? = nil
    ) -> FileTransaction {
        precondition(maximumBytes >= 0, "transaction limit must not be negative")
        return FileTransaction(
            directory: self,
            component: component,
            destinationKey: knownDestinationKey(component),
            data: data,
            expectation: expectation,
            policy: policy,
            maximumBytes: maximumBytes,
            reusableStage: reusableStage)
    }

    fileprivate struct OpenedRegularFile {
        let descriptor: Int32
        let status: stat
        let version: FileVersionToken
    }

    struct ExistingFileAuthorization {
        let component: FileComponent
        let version: FileVersionToken
    }

    /// Converts an existing caller spelling into the physical child spelling
    /// observed from the exact held file descriptor. The presentation lookup
    /// alone is not authority: the returned component is accepted only after a
    /// descriptor-relative status lookup proves it still names that same
    /// unique inode. Sequential case aliases can then share one recovery key
    /// without ever folding an unproven or missing destination into it.
    func authorizeExistingFile(
        _ requestedComponent: FileComponent,
        maximumBytes: Int,
        cancellationCheck: @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> ExistingFileAuthorization {
        let opened = try openRegularFile(
            requestedComponent,
            maximumBytes: maximumBytes,
            cancellationCheck: cancellationCheck)
        defer { _ = syscalls.close(opened.descriptor) }
        guard let actualURL = Self.actualURL(
            for: opened.descriptor,
            syscalls: syscalls)
        else {
            throw SecureLocalFileError.operation(
                .verify,
                errno: errno == 0 ? EIO : errno)
        }
        let physicalComponent = try FileComponent(actualURL.lastPathComponent)
        guard let namedStatus = try entryStatus(
            physicalComponent,
            cancellationCheck: cancellationCheck),
            LocalFileStamp(namedStatus) == LocalFileStamp(opened.status)
        else { throw SecureLocalFileError.expectationMismatch }
        return ExistingFileAuthorization(
            component: physicalComponent,
            version: opened.version)
    }

    fileprivate func openRegularFile(
        _ component: FileComponent,
        maximumBytes: Int,
        cancellationCheck: @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> OpenedRegularFile {
        try validateNameLimit(component)
        let descriptor = try openRegularDescriptor(
            component,
            requireUniqueLink: true,
            cancellationCheck: cancellationCheck)
        do {
            let value = try Self.version(
                descriptor: descriptor,
                maximumBytes: maximumBytes,
                syscalls: syscalls,
                cancellationCheck: cancellationCheck)
            return OpenedRegularFile(
                descriptor: descriptor, status: value.status, version: value.token)
        } catch {
            _ = syscalls.close(descriptor)
            throw error
        }
    }

    fileprivate func openRegularDescriptor(
        _ component: FileComponent,
        requireUniqueLink: Bool,
        accessMode: Int32 = O_RDONLY,
        cancellationCheck: @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> Int32 {
        try validateNameLimit(component)
        precondition(accessMode == O_RDONLY || accessMode == O_RDWR)
        var flags = accessMode | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | O_RESOLVE_BENEATH
        if requireUniqueLink { flags |= O_UNIQUE }
        do {
            return try requireSystemCall(
                .openTarget,
                cancellationCheck: cancellationCheck,
                succeeds: { $0 >= 0 }
            ) {
                component.rawValue.withCString {
                    syscalls.openAt(descriptor, $0, flags)
                }
            }
        } catch SecureLocalFileError.operation(.openTarget, let code)
            where requireUniqueLink && code == ENOTCAPABLE
        {
            throw SecureLocalFileError.hardLinkedEntry
        }
    }

    /// Opens or creates one private, fixed-name child through the same
    /// descriptor-relative no-follow and unique-link boundary used by file
    /// transactions. The caller owns the returned descriptor and must close
    /// it exactly once.
    ///
    /// Disk contents are not trusted by this operation. It establishes only
    /// the filesystem object boundary: regular file, single link, exact
    /// owner/mode, optional prior identity, and a final name-to-descriptor
    /// binding. Higher-level formats must validate their own bytes.
    func openTrustedRegularChild(
        _ component: FileComponent,
        disposition: TrustedChildDisposition,
        accessMode: Int32 = O_RDWR,
        ownerID: uid_t = geteuid(),
        permissions: mode_t = 0o600,
        cancellationCheck: @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> TrustedRegularChild {
        precondition(accessMode == O_RDONLY || accessMode == O_RDWR)
        try validateNameLimit(component)

        let childDescriptor: Int32
        let wasCreated: Bool
        switch disposition {
        case .existing:
            childDescriptor = try openRegularDescriptor(
                component,
                requireUniqueLink: true,
                accessMode: accessMode,
                cancellationCheck: cancellationCheck)
            wasCreated = false
        case .createExclusive:
            if cancellationCheck() { throw SecureLocalFileError.cancelled }
            errno = 0
            childDescriptor = component.rawValue.withCString {
                syscalls.createAt(
                    descriptor,
                    $0,
                    accessMode | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW
                        | O_NONBLOCK | O_RESOLVE_BENEATH,
                    permissions)
            }
            guard childDescriptor >= 0 else {
                throw SecureLocalFileError.operation(
                    .createStage,
                    errno: errno == 0 ? EIO : errno)
            }
            wasCreated = true
        }

        do {
            let expectedIdentity: LocalFileIdentity?
            switch disposition {
            case .existing(let identity): expectedIdentity = identity
            case .createExclusive: expectedIdentity = nil
            }
            let status = try revalidateTrustedRegularChild(
                descriptor: childDescriptor,
                component: component,
                expectedIdentity: expectedIdentity,
                ownerID: ownerID,
                permissions: permissions,
                cancellationCheck: cancellationCheck)
            return TrustedRegularChild(
                descriptor: childDescriptor,
                status: status,
                identity: LocalFileIdentity(status),
                wasCreated: wasCreated)
        } catch {
            _ = syscalls.close(childDescriptor)
            throw error
        }
    }

    /// Creates one empty user-content file beneath this retained directory.
    ///
    /// The final component is never followed and `O_EXCL` is the only name
    /// selection authority. Once creation succeeds, cancellation cannot skip
    /// verification: the namespace mutation already happened, so the method
    /// finishes deriving the exact descriptor token and reports durability.
    func createExclusiveUserContentFile(
        _ component: FileComponent,
        cancellationCheck: @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> SecureLocalFileCreationSnapshot {
        try validateNameLimit(component)
        if cancellationCheck() { throw SecureLocalFileError.cancelled }

        errno = 0
        let childDescriptor = component.rawValue.withCString {
            syscalls.createAt(
                descriptor,
                $0,
                O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW
                    | O_NONBLOCK | O_RESOLVE_BENEATH,
                0o666)
        }
        guard childDescriptor >= 0 else {
            throw SecureLocalFileError.operation(
                .createDocument,
                errno: errno == 0 ? EIO : errno)
        }
        defer { _ = syscalls.close(childDescriptor) }

        // No cancellation checks beyond publication. A cancelled caller may
        // decline the eventual UI commit, but it must not strand an
        // uninspected entry and then retry under another name.
        let inspected = try Self.contents(
            descriptor: childDescriptor,
            maximumBytes: 0,
            retainBytes: true,
            syscalls: syscalls,
            cancellationCheck: { false })
        guard inspected.data?.isEmpty == true,
            inspected.status.st_uid == geteuid(),
            inspected.status.st_nlink == 1,
            inspected.status.st_mode & S_IFMT == S_IFREG,
            inspected.status.st_mode & mode_t(0o7000) == 0
        else { throw SecureLocalFileError.unsupportedEntry }
        guard let named = try entryStatus(component, cancellationCheck: { false }),
            LocalFileStamp(named) == LocalFileStamp(inspected.status)
        else { throw SecureLocalFileError.expectationMismatch }
        try verifyLocation()

        errno = 0
        let fileSyncResult = syscalls.fsync(childDescriptor)
        let fileSyncErrno = fileSyncResult == 0 ? nil : (errno == 0 ? EIO : errno)
        errno = 0
        let directorySyncResult = syscalls.fsync(descriptor)
        let directorySyncErrno = directorySyncResult == 0 ? nil : (errno == 0 ? EIO : errno)

        // Sync failure does not relax identity. The file is returned only if
        // the name still binds the exact empty inode we created.
        let final = try Self.contents(
            descriptor: childDescriptor,
            maximumBytes: 0,
            retainBytes: true,
            syscalls: syscalls,
            cancellationCheck: { false })
        guard final.data?.isEmpty == true,
            let finalStamp = LocalFileStamp(final.status),
            let finalNamed = try entryStatus(component, cancellationCheck: { false }),
            LocalFileStamp(finalNamed) == finalStamp
        else { throw SecureLocalFileError.expectationMismatch }
        try verifyLocation()

        let canonicalURL = destinationURL(component)
        return SecureLocalFileCreationSnapshot(
            read: SecureLocalFileReadSnapshot(
                data: Data(),
                stamp: finalStamp,
                version: final.token,
                canonicalURL: canonicalURL,
                destinationKey: try destinationKey(
                    component,
                    cancellationCheck: { false })),
            fileSyncErrno: fileSyncErrno,
            directorySyncErrno: directorySyncErrno)
    }

    /// Revalidates a trusted child's held descriptor and its current name in
    /// one retained parent directory. Identity, not a presentation path,
    /// decides whether the binding survived.
    @discardableResult
    func revalidateTrustedRegularChild(
        descriptor childDescriptor: Int32,
        component: FileComponent,
        expectedIdentity: LocalFileIdentity,
        ownerID: uid_t = geteuid(),
        permissions: mode_t = 0o600,
        cancellationCheck: @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> stat {
        try revalidateTrustedRegularChild(
            descriptor: childDescriptor,
            component: component,
            expectedIdentity: Optional(expectedIdentity),
            ownerID: ownerID,
            permissions: permissions,
            cancellationCheck: cancellationCheck)
    }

    private func revalidateTrustedRegularChild(
        descriptor childDescriptor: Int32,
        component: FileComponent,
        expectedIdentity: LocalFileIdentity?,
        ownerID: uid_t,
        permissions: mode_t,
        cancellationCheck: @Sendable () -> Bool
    ) throws -> stat {
        var held = stat()
        _ = try requireSystemCall(
            .verify,
            cancellationCheck: cancellationCheck,
            succeeds: { $0 == 0 }
        ) {
            syscalls.fstat(childDescriptor, &held)
        }
        guard held.st_mode & S_IFMT == S_IFREG,
            held.st_uid == ownerID,
            held.st_mode & mode_t(0o7777) == permissions
        else { throw SecureLocalFileError.unsupportedEntry }
        guard held.st_nlink == 1 else {
            throw SecureLocalFileError.hardLinkedEntry
        }
        if let expectedIdentity,
            LocalFileIdentity(held) != expectedIdentity
        {
            throw SecureLocalFileError.expectationMismatch
        }

        guard let named = try entryStatus(
            component,
            cancellationCheck: cancellationCheck),
            named.st_mode & S_IFMT == S_IFREG,
            named.st_uid == ownerID,
            named.st_mode & mode_t(0o7777) == permissions,
            named.st_nlink == 1,
            LocalFileIdentity(named) == LocalFileIdentity(held)
        else { throw SecureLocalFileError.expectationMismatch }
        return held
    }

    func entryStatus(
        _ component: FileComponent,
        cancellationCheck: @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> stat? {
        try validateNameLimit(component)
        var status = stat()
        let outcome = InterruptedSyscall.run(
            cancellationCheck: cancellationCheck,
            succeeds: { $0 == 0 }
        ) {
            component.rawValue.withCString {
                syscalls.fstatAt(
                    descriptor, $0, &status, AT_SYMLINK_NOFOLLOW | AT_RESOLVE_BENEATH)
            }
        }
        switch outcome {
        case .success:
            return status
        case .failure(let code) where code == ENOENT:
            return nil
        case .failure(let code):
            throw SecureLocalFileError.operation(.inspect, errno: code)
        case .cancelled:
            throw SecureLocalFileError.cancelled
        }
    }

    fileprivate func validateNameLimit(_ component: FileComponent) throws {
        errno = 0
        let limit = syscalls.fpathconf(descriptor, _PC_NAME_MAX)
        let code = errno
        if limit < 0, code != 0 {
            throw SecureLocalFileError.operation(.inspect, errno: code)
        }
        guard limit < 0 || component.rawValue.utf8.count <= limit else {
            throw SecureLocalFileError.invalidComponent
        }
    }

    func destinationKey(
        _ component: FileComponent,
        cancellationCheck: @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> FileDestinationKey {
        try validateNameLimit(component)
        if cancellationCheck() { throw SecureLocalFileError.cancelled }
        return knownDestinationKey(component)
    }

    /// Opens or creates one owner-private child directory beneath this exact
    /// retained descriptor. No path traversal or rename participates. The
    /// created directory and its parent are synced before success; an existing
    /// child must still be a no-follow, owner-controlled directory whose held
    /// inode remains bound to the requested name.
    func openOrCreatePrivateDirectory(
        _ component: FileComponent,
        cancellationCheck: @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> SecureLocalDirectoryHandle {
        try openOrCreateManagedDirectory(
            component,
            policy: .privateStorage,
            cancellationCheck: cancellationCheck)
    }

    /// Opens or creates a user-visible child directory without changing an
    /// existing directory's mode, ACL, flags, or ownership. The name is still
    /// resolved relative to the retained parent with no-follow semantics, and
    /// a newly created directory plus its parent are synced before success.
    ///
    /// This is intentionally a separate entry point from private storage:
    /// callers that hold secrets cannot accidentally opt into preservation of
    /// user-controlled metadata by passing a permissive policy value.
    func openOrCreateUserDirectory(
        _ component: FileComponent,
        cancellationCheck: @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> SecureLocalDirectoryHandle {
        try openOrCreateManagedDirectory(
            component,
            policy: .userContent,
            cancellationCheck: cancellationCheck)
    }

    private enum ManagedChildDirectoryPolicy: Equatable {
        case privateStorage
        case userContent

        var creationMode: mode_t {
            switch self {
            case .privateStorage: 0o700
            case .userContent: 0o755
            }
        }
    }

    private func openOrCreateManagedDirectory(
        _ component: FileComponent,
        policy: ManagedChildDirectoryPolicy,
        cancellationCheck: @Sendable () -> Bool
    ) throws -> SecureLocalDirectoryHandle {
        try validateNameLimit(component)
        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            | O_NONBLOCK | O_RESOLVE_BENEATH

        func openChild() -> (descriptor: Int32, error: Int32) {
            errno = 0
            let child = component.rawValue.withCString {
                syscalls.openAt(descriptor, $0, flags)
            }
            return (child, child >= 0 ? 0 : (errno == 0 ? EIO : errno))
        }

        if cancellationCheck() { throw SecureLocalFileError.cancelled }
        var opened = openChild()
        var created = false
        if opened.descriptor < 0, opened.error == ENOENT {
            if cancellationCheck() { throw SecureLocalFileError.cancelled }
            errno = 0
            let createdResult = component.rawValue.withCString {
                syscalls.mkdirAt(descriptor, $0, policy.creationMode)
            }
            let createError = createdResult == 0 ? 0 : (errno == 0 ? EIO : errno)
            guard createdResult == 0 else {
                // mkdir is never retried after EINTR: the namespace effect is
                // ambiguous. EEXIST is also refused rather than blessing a
                // concurrently installed directory as our creation.
                throw SecureLocalFileError.operation(.openDirectory, errno: createError)
            }
            created = true
            opened = openChild()
        }
        guard opened.descriptor >= 0 else {
            throw SecureLocalFileError.operation(
                .openDirectory, errno: opened.error)
        }

        let childDescriptor = opened.descriptor
        do {
            var held = stat()
            _ = try requireSystemCall(
                .openDirectory,
                cancellationCheck: cancellationCheck,
                succeeds: { $0 == 0 }
            ) {
                syscalls.fstat(childDescriptor, &held)
            }
            guard held.st_mode & S_IFMT == S_IFDIR else {
                throw SecureLocalFileError.unsupportedEntry
            }

            var applied = held
            if policy == .privateStorage {
                guard held.st_uid == geteuid() else {
                    throw SecureLocalFileError.unsupportedEntry
                }
                _ = try requireSystemCall(
                    .metadata,
                    cancellationCheck: cancellationCheck,
                    succeeds: { $0 == 0 }
                ) {
                    syscalls.fchmod(childDescriptor, 0o700)
                }
                try clearAndVerifyExtendedACL(on: childDescriptor)
                _ = try requireSystemCall(
                    .verify,
                    cancellationCheck: cancellationCheck,
                    succeeds: { $0 == 0 }
                ) {
                    syscalls.fstat(childDescriptor, &applied)
                }
                guard applied.st_mode & S_IFMT == S_IFDIR,
                    applied.st_uid == geteuid(),
                    applied.st_mode & mode_t(0o7777) == 0o700
                else { throw SecureLocalFileError.expectationMismatch }
            }

            guard let named = try entryStatus(
                component,
                cancellationCheck: cancellationCheck),
                named.st_mode & S_IFMT == S_IFDIR,
                LocalFileIdentity(named) == LocalFileIdentity(applied)
            else { throw SecureLocalFileError.expectationMismatch }

            if policy == .privateStorage {
                guard named.st_uid == geteuid(),
                    named.st_mode & mode_t(0o7777) == 0o700
                else { throw SecureLocalFileError.expectationMismatch }
            }

            if created {
                _ = try requireSystemCall(
                    .syncDirectory,
                    cancellationCheck: { false },
                    succeeds: { $0 == 0 }
                ) {
                    syscalls.fsync(descriptor)
                }
            }
            guard let actual = Self.actualURL(
                for: childDescriptor,
                syscalls: syscalls)
            else {
                throw SecureLocalFileError.operation(
                    .openDirectory, errno: errno == 0 ? EIO : errno)
            }
            return SecureLocalDirectoryHandle(
                owned: childDescriptor,
                url: actual,
                status: applied,
                syscalls: syscalls)
        } catch {
            _ = syscalls.close(childDescriptor)
            throw error
        }
    }

    private func knownDestinationKey(_ component: FileComponent) -> FileDestinationKey {
        FileDestinationKey(
            directoryIdentity: directoryIdentity,
            component: component,
            caseSensitiveNames: caseSensitiveNames)
    }

    private static func caseSensitiveNames(for descriptor: Int32) -> Bool? {
        // Query the retained directory descriptor, not its presentation URL:
        // an ancestor path can be replaced after this handle was opened.
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.volattr = UInt32(ATTR_VOL_CAPABILITIES)
        var buffer = FileVolumeCapabilitiesBuffer()
        let capabilityResult = fgetattrlist(
            descriptor,
            &attributes,
            &buffer,
            MemoryLayout<FileVolumeCapabilitiesBuffer>.size,
            0)
        let formatCapabilities = buffer.capabilities.capabilities.0
        let validFormatCapabilities = buffer.capabilities.valid.0
        return capabilityResult == 0
            && validFormatCapabilities & UInt32(VOL_CAP_FMT_CASE_SENSITIVE) != 0
            ? formatCapabilities & UInt32(VOL_CAP_FMT_CASE_SENSITIVE) != 0
            : nil
    }

    func destinationURL(_ component: FileComponent) -> URL {
        url.appendingPathComponent(component.rawValue, isDirectory: false)
    }

    /// Returns the location currently bound to this retained directory
    /// descriptor. This is authority-bearing only for the instant of the
    /// `F_GETPATH` observation; callers still need the retained descriptor and
    /// an exact version token for any later mutation.
    fileprivate func currentDestinationURL(_ component: FileComponent) -> URL? {
        Self.actualURL(for: descriptor, syscalls: syscalls)?.appendingPathComponent(
            component.rawValue,
            isDirectory: false)
    }

    func verifyLocation() throws {
        guard let current = Self.actualURL(for: descriptor, syscalls: syscalls),
            current.standardizedFileURL == url.standardizedFileURL
        else {
            throw SecureLocalFileError.expectationMismatch
        }
    }

    fileprivate static func version(
        descriptor: Int32,
        maximumBytes: Int,
        syscalls: SecureFileSyscalls,
        cancellationCheck: @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> (status: stat, token: FileVersionToken) {
        let inspected = try contents(
            descriptor: descriptor,
            maximumBytes: maximumBytes,
            retainBytes: false,
            syscalls: syscalls,
            cancellationCheck: cancellationCheck)
        return (inspected.status, inspected.token)
    }

    fileprivate static func contents(
        descriptor: Int32,
        maximumBytes: Int,
        retainBytes: Bool,
        syscalls: SecureFileSyscalls,
        cancellationCheck: @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> (status: stat, token: FileVersionToken, data: Data?) {
        precondition(maximumBytes >= 0, "read limit must not be negative")
        if cancellationCheck() { throw SecureLocalFileError.cancelled }
        var before = stat()
        _ = try requireSystemCall(
            .verify,
            cancellationCheck: cancellationCheck,
            succeeds: { $0 == 0 }
        ) {
            syscalls.fstat(descriptor, &before)
        }
        guard let stamp = LocalFileStamp(before) else {
            throw SecureLocalFileError.unsupportedEntry
        }
        guard stamp.size <= maximumBytes else {
            throw SecureLocalFileError.fileTooLarge(maximumBytes: maximumBytes)
        }

        let seekResult: off_t = try requireSystemCall(
            .verify,
            cancellationCheck: cancellationCheck,
            succeeds: { $0 >= 0 }
        ) {
            syscalls.lseek(descriptor, 0, SEEK_SET)
        }
        guard seekResult == 0 else {
            throw SecureLocalFileError.operation(.verify, errno: EIO)
        }

        var hasher = SHA256()
        var data = retainBytes ? Data() : nil
        data?.reserveCapacity(min(stamp.size, 64 * 1_024))
        var count = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            if cancellationCheck() { throw SecureLocalFileError.cancelled }
            let readCount: Int = try requireSystemCall(
                .verify,
                cancellationCheck: cancellationCheck,
                succeeds: { $0 >= 0 }
            ) {
                buffer.withUnsafeMutableBytes {
                    syscalls.read(descriptor, $0.baseAddress, $0.count)
                }
            }
            if readCount > 0 {
                let (nextCount, overflow) = count.addingReportingOverflow(readCount)
                guard !overflow, nextCount <= maximumBytes else {
                    throw SecureLocalFileError.fileTooLarge(maximumBytes: maximumBytes)
                }
                count = nextCount
                let chunk = Data(buffer[0..<readCount])
                hasher.update(data: chunk)
                data?.append(chunk)
                continue
            }
            if readCount == 0 { break }
        }

        if cancellationCheck() { throw SecureLocalFileError.cancelled }

        var after = stat()
        _ = try requireSystemCall(
            .verify,
            cancellationCheck: cancellationCheck,
            succeeds: { $0 == 0 }
        ) {
            syscalls.fstat(descriptor, &after)
        }
        guard before.st_dev == after.st_dev,
            before.st_ino == after.st_ino,
            before.st_size == after.st_size,
            before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
            before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
            before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
            before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
            before.st_nlink == after.st_nlink,
            before.st_mode == after.st_mode,
            before.st_uid == after.st_uid,
            before.st_gid == after.st_gid,
            before.st_flags == after.st_flags,
            count == stamp.size,
            let token = FileVersionToken(status: after, sha256: Data(hasher.finalize()))
        else { throw SecureLocalFileError.expectationMismatch }
        return (after, token, data)
    }

    fileprivate static func refreshedVersionAfterRename(
        descriptor: Int32,
        preRename: FileVersionToken,
        maximumBytes: Int,
        syscalls: SecureFileSyscalls
    ) throws -> FileVersionToken {
        // The descriptor still owns the staged inode after publication. Hash
        // those retained bytes coherently instead of copying the pre-rename
        // digest: an equal-size in-place writer can restore mtime while ctime
        // necessarily differs because of the rename itself.
        let inspected = try contents(
            descriptor: descriptor,
            maximumBytes: maximumBytes,
            retainBytes: false,
            syscalls: syscalls,
            cancellationCheck: { false })
        guard inspected.token.matchesAcrossRename(preRename) else {
            throw SecureLocalFileError.expectationMismatch
        }
        return inspected.token
    }

    fileprivate static func actualURL(
        for descriptor: Int32,
        syscalls: SecureFileSyscalls
    ) -> URL? {
        var bytes = [CChar](repeating: 0, count: Int(PATH_MAX))
        let result = bytes.withUnsafeMutableBytes { raw -> Int32 in
            guard let base = raw.baseAddress else {
                errno = EINVAL
                return -1
            }
            return syscalls.fcntlGetPath(descriptor, base)
        }
        guard result == 0 else { return nil }
        return URL(fileURLWithPath: String(cString: bytes)).standardizedFileURL
    }
}

/// Durable observers run at the transaction's actual filesystem boundaries.
/// The callback returns only after its checkpoint is durable. Throwing aborts
/// before publication or makes an already-published result indeterminate.
enum FileTransactionLifecycleEvent: Equatable, Sendable {
    case preparing
    /// The fixed planned name now exists, but no exact descriptor-derived
    /// token has reached durable storage yet. This boundary is observable so
    /// crash tests can prove startup treats the name as evidence, never as a
    /// reusable capability.
    case stageCreatedUnobserved(FileComponent)
    case stageObserved(FileRecoverySlot)
    case staged(FileRecoverySlot)
    case publishing(FileRecoverySlot)
    case committed(FileTransactionReceipt)
}

/// One immutable staged replacement. It owns no path resolution: the parent
/// descriptor and final component were fixed before it was created.
struct FileTransaction: @unchecked Sendable {
    enum Policy: Equatable, Sendable {
        case userContent
        case privateStorage
    }

    let directory: SecureLocalDirectoryHandle
    let component: FileComponent
    let destinationKey: FileDestinationKey
    let data: Data
    let expectation: FileTransactionExpectation
    let policy: Policy
    let maximumBytes: Int
    /// Exact retained scratch authority and role from this destination's
    /// preceding live-process save. A stale or substituted authority fails
    /// closed; it is never replaced with a fresh hidden name in the same
    /// process.
    let reusableStage: FileRecoverySlot?
    var cancellationCheck: @Sendable () -> Bool = { Task.isCancelled }
    var preferredStageComponent: FileComponent? = nil
    var lifecycleObserver: (@Sendable (FileTransactionLifecycleEvent) throws -> Void)? = nil

    private static let maximumStageNameAttempts = 8
    /// These owner-settable flags describe presentation/backup policy and can
    /// be copied safely to a fresh regular inode. Kernel-managed, entitlement-
    /// gated, append-only, immutable, and system flags are refused explicitly.
    private static let preservedUserFlags = UInt32(UF_NODUMP | UF_HIDDEN)
    private static let lockedFlags = UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND)
    /// macOS may attach and immediately recreate this kernel-managed marker
    /// even after `fremovexattr` reports success. No caller-controlled or
    /// inherited attribute is allowed to survive private staging.
    private static let allowedKernelManagedResidualAttributes: Set<String> = [
        "com.apple.provenance",
    ]

    private enum InterruptedPublishOutcome {
        case noEffect
        case indeterminate(FileTransactionReceipt)
    }

    func commit() throws -> FileTransactionReceipt {
        let syscalls = directory.syscalls
        precondition(maximumBytes >= 0, "transaction limit must not be negative")
        guard data.count <= maximumBytes else {
            throw SecureLocalFileError.fileTooLarge(maximumBytes: maximumBytes)
        }
        try directory.validateNameLimit(component)
        if let reusableStage,
            reusableStage.authority.destinationKey != destinationKey
        {
            throw SecureLocalFileError.expectationMismatch
        }
        if let reusableStage, let preferredStageComponent,
            reusableStage.authority.component != preferredStageComponent
        {
            throw SecureLocalFileError.expectationMismatch
        }

        var original: SecureLocalDirectoryHandle.OpenedRegularFile?
        switch expectation {
        case .missing:
            if try directory.entryStatus(
                component,
                cancellationCheck: cancellationCheck) != nil
            {
                throw SecureLocalFileError.expectationMismatch
            }
        case .exact(let expected):
            let opened = try directory.openRegularFile(
                component,
                maximumBytes: maximumBytes,
                cancellationCheck: cancellationCheck)
            guard opened.version == expected else {
                _ = syscalls.close(opened.descriptor)
                throw SecureLocalFileError.expectationMismatch
            }
            guard opened.version.linkCount == 1 else {
                _ = syscalls.close(opened.descriptor)
                throw SecureLocalFileError.hardLinkedEntry
            }
            let specialModeBits = opened.status.st_mode
                & mode_t(S_ISUID | S_ISGID | S_ISTXT)
            guard specialModeBits == 0 else {
                _ = syscalls.close(opened.descriptor)
                throw SecureLocalFileError.unsupportedFileMode(specialModeBits)
            }
            guard opened.status.st_flags & Self.lockedFlags == 0 else {
                _ = syscalls.close(opened.descriptor)
                throw SecureLocalFileError.operation(.metadata, errno: EPERM)
            }
            let unsupportedFlags = opened.status.st_flags
                & ~(Self.preservedUserFlags | Self.lockedFlags)
            guard unsupportedFlags == 0 else {
                _ = syscalls.close(opened.descriptor)
                throw SecureLocalFileError.unsupportedFileFlags(unsupportedFlags)
            }
            original = opened
        }
        defer {
            if let original { _ = syscalls.close(original.descriptor) }
        }

        try observeLifecycle(.preparing)
        let (stage, stageDescriptor, acquiredRecoveryContents) = try acquireStage(
            syscalls: syscalls)
        defer { _ = syscalls.close(stageDescriptor) }
        var publicationOccurred = false
        var recoveryContentsOnFailure = acquiredRecoveryContents
        var stageMutationRestoreFlags: UInt32?

        do {
            if reusableStage == nil {
                try observeLifecycle(.stageCreatedUnobserved(stage))
            }
            var initialStageStatus = stat()
            _ = try requireSystemCall(
                .inspect,
                cancellationCheck: cancellationCheck,
                succeeds: { $0 == 0 }
            ) {
                syscalls.fstat(stageDescriptor, &initialStageStatus)
            }
            guard initialStageStatus.st_mode & S_IFMT == S_IFREG else {
                throw SecureLocalFileError.unsupportedEntry
            }
            guard initialStageStatus.st_nlink == 1 else {
                throw SecureLocalFileError.hardLinkedEntry
            }
            let acquiredVersion = try SecureLocalDirectoryHandle.version(
                descriptor: stageDescriptor,
                maximumBytes: maximumBytes,
                syscalls: syscalls,
                cancellationCheck: cancellationCheck).token
            try observeLifecycle(.stageObserved(
                FileRecoverySlot(
                    authority: FileRecoveryAuthority(
                        component: stage,
                        version: acquiredVersion,
                        destinationKey: destinationKey),
                    contents: acquiredRecoveryContents)))
            try prepareStageForWrite(
                stageDescriptor,
                syscalls: syscalls,
                mutationWillBegin: {
                    recoveryContentsOnFailure = .unpublishedScratch
                },
                mutationGuardDidActivate: { restoreFlags in
                    stageMutationRestoreFlags = restoreFlags
                })
            try writeAll(to: stageDescriptor, syscalls: syscalls)
            if let restoreFlags = stageMutationRestoreFlags {
                try restoreStageMutationGuard(
                    stageDescriptor,
                    flags: restoreFlags,
                    syscalls: syscalls)
                stageMutationRestoreFlags = nil
            }
            try applyMetadata(
                original: original, stageDescriptor: stageDescriptor, syscalls: syscalls)
            try verifyStage(stageDescriptor, syscalls: syscalls)
            _ = try requireSystemCall(
                .syncFile,
                cancellationCheck: cancellationCheck,
                succeeds: { $0 == 0 }
            ) {
                syscalls.fsync(stageDescriptor)
            }
            // Derive the committed version while the staged inode is retained.
            // Receipt construction after publication performs no path reopen.
            let newVersion = try SecureLocalDirectoryHandle.version(
                descriptor: stageDescriptor,
                maximumBytes: maximumBytes,
                syscalls: syscalls,
                cancellationCheck: cancellationCheck).token
            let unpublishedStage = FileRecoverySlot(
                authority: FileRecoveryAuthority(
                    component: stage,
                    version: newVersion,
                    destinationKey: destinationKey),
                contents: .unpublishedScratch)
            try observeLifecycle(.staged(unpublishedStage))

            let admittedExpected: FileVersionToken?
            switch expectation {
            case .missing:
                admittedExpected = nil
            case .exact(let expected):
                guard let original else {
                    throw SecureLocalFileError.expectationMismatch
                }
                let immediatelyBeforePublish = try SecureLocalDirectoryHandle.version(
                    descriptor: original.descriptor,
                    maximumBytes: maximumBytes,
                    syscalls: syscalls,
                    cancellationCheck: cancellationCheck).token
                guard immediatelyBeforePublish == expected else {
                    throw SecureLocalFileError.expectationMismatch
                }
                admittedExpected = immediatelyBeforePublish
            }
            try directory.verifyLocation()
            guard !cancellationCheck() else { throw SecureLocalFileError.cancelled }
            try verifyFinalStageBinding(
                stage,
                descriptor: stageDescriptor,
                expectedVersion: newVersion,
                syscalls: syscalls)
            try observeLifecycle(.publishing(unpublishedStage))

            switch expectation {
            case .missing:
                let result = rename(
                    stage,
                    component,
                    flags: UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH))
                let publishError = result == 0 ? 0 : errno
                guard result == 0 else {
                    if publishError == EINTR {
                        switch reconcileInterruptedMissingPublish(
                            stage: stage,
                            newVersion: newVersion,
                            stageDescriptor: stageDescriptor)
                        {
                        case .noEffect:
                            break
                        case .indeterminate(let receipt):
                            throw SecureLocalFileError.indeterminate(receipt)
                        }
                    }
                    throw SecureLocalFileError.operation(.publish, errno: publishError)
                }
                publicationOccurred = true
                guard publishedDescriptorIsBoundToDestination(stageDescriptor) else {
                    throw SecureLocalFileError.indeterminate(
                        transactionReceipt(
                            destination: observedDestinationURL(),
                            version: nil,
                            durability: .indeterminate(operation: .verify, errno: nil),
                            recoverySlot: nil))
                }
                let committedVersion: FileVersionToken
                do {
                    committedVersion = try SecureLocalDirectoryHandle.refreshedVersionAfterRename(
                        descriptor: stageDescriptor,
                        preRename: newVersion,
                        maximumBytes: maximumBytes,
                        syscalls: syscalls)
                } catch {
                    throw SecureLocalFileError.indeterminate(
                        transactionReceipt(
                            destination: observedDestinationURL(),
                            version: nil,
                            durability: .indeterminate(operation: .verify, errno: nil),
                            recoverySlot: nil))
                }
                // An ancestor rename after the preflight cannot redirect the
                // fd, but it can make the user-visible destination ambiguous.
                guard (try? directory.verifyLocation()) != nil else {
                    let observedDestination = directory.currentDestinationURL(component)
                    throw SecureLocalFileError.indeterminate(
                        transactionReceipt(
                            destination: observedDestination
                                ?? directory.destinationURL(component),
                            version: observedDestination == nil ? nil : committedVersion,
                            durability: .indeterminate(operation: .verify, errno: nil),
                            recoverySlot: nil))
                }
                return try finishCommitted(
                    committedReceipt(version: committedVersion, recovery: nil))

            case .exact:
                guard let admittedExpected else {
                    throw SecureLocalFileError.expectationMismatch
                }
                let result = rename(
                    stage,
                    component,
                    flags: UInt32(RENAME_SWAP | RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH))
                let publishError = result == 0 ? 0 : errno
                guard result == 0 else {
                    if publishError == EINTR {
                        switch reconcileInterruptedSwapPublish(
                            stage: stage,
                            admittedExpected: admittedExpected,
                            newVersion: newVersion,
                            stageDescriptor: stageDescriptor)
                        {
                        case .noEffect:
                            break
                        case .indeterminate(let receipt):
                            throw SecureLocalFileError.indeterminate(receipt)
                        }
                    }
                    throw SecureLocalFileError.operation(.publish, errno: publishError)
                }
                publicationOccurred = true

                guard publishedDescriptorIsBoundToDestination(stageDescriptor) else {
                    let observedDisplaced = try? directory.version(
                        of: stage,
                        maximumBytes: maximumBytes,
                        cancellationCheck: { false })
                    throw SecureLocalFileError.indeterminate(
                        transactionReceipt(
                            destination: observedDestinationURL(),
                            version: nil,
                            durability: .indeterminate(operation: .verify, errno: nil),
                            recoverySlot: observedDisplaced.flatMap { displaced in
                                displaced.matchesAcrossRename(admittedExpected)
                                    ? FileRecoverySlot(
                                        authority: FileRecoveryAuthority(
                                            component: stage,
                                            version: displaced,
                                            destinationKey: destinationKey),
                                        contents: .previousDestination)
                                    : nil
                            }))
                }

                let displaced: FileVersionToken
                do {
                    displaced = try directory.version(
                        of: stage,
                        maximumBytes: maximumBytes,
                        cancellationCheck: { false })
                } catch {
                    // The SWAP is the linearization point. A second pathname
                    // swap cannot be made safe: another process may have
                    // reused the hidden name. Without an exact displaced token
                    // the stage name is not advertised as recoverable.
                    throw SecureLocalFileError.indeterminate(
                        transactionReceipt(
                            destination: observedDestinationURL(),
                            version: nil,
                            durability: .indeterminate(operation: .verify, errno: nil),
                            recoverySlot: nil))
                }

                let committedVersion: FileVersionToken
                do {
                    committedVersion = try SecureLocalDirectoryHandle.refreshedVersionAfterRename(
                        descriptor: stageDescriptor,
                        preRename: newVersion,
                        maximumBytes: maximumBytes,
                        syscalls: syscalls)
                } catch {
                    throw SecureLocalFileError.indeterminate(
                        transactionReceipt(
                            destination: observedDestinationURL(),
                            version: nil,
                            durability: .indeterminate(operation: .verify, errno: nil),
                            recoverySlot: displaced.matchesAcrossRename(admittedExpected)
                                ? FileRecoverySlot(
                                    authority: FileRecoveryAuthority(
                                        component: stage,
                                        version: displaced,
                                        destinationKey: destinationKey),
                                    contents: .previousDestination)
                                : nil))
                }

                let displacedMatches = displaced.matchesAcrossRename(admittedExpected)
                guard (try? directory.verifyLocation()) != nil else {
                    let observedDestination = directory.currentDestinationURL(component)
                    throw SecureLocalFileError.indeterminate(
                        transactionReceipt(
                            destination: observedDestination
                                ?? directory.destinationURL(component),
                            version: observedDestination == nil ? nil : committedVersion,
                            durability: .indeterminate(operation: .verify, errno: nil),
                            recoverySlot: displacedMatches
                                ? FileRecoverySlot(
                                    authority: FileRecoveryAuthority(
                                        component: stage,
                                        version: displaced,
                                        destinationKey: destinationKey),
                                    contents: .previousDestination)
                                : nil))
                }
                guard displacedMatches else {
                    throw SecureLocalFileError.indeterminate(
                        transactionReceipt(
                            destination: observedDestinationURL(),
                            version: committedVersion,
                            durability: .indeterminate(operation: .verify, errno: nil),
                            recoverySlot: nil))
                }

                return try finishCommitted(
                    committedReceipt(
                        version: committedVersion,
                        recovery: FileRecoveryAuthority(
                            component: stage,
                            version: displaced,
                            destinationKey: destinationKey)))
            }
        } catch {
            var caughtError = error
            if let restoreFlags = stageMutationRestoreFlags {
                do {
                    try restoreStageMutationGuard(
                        stageDescriptor,
                        flags: restoreFlags,
                        syscalls: syscalls)
                    stageMutationRestoreFlags = nil
                } catch {
                    // An un-restored immutable guard is retained on disk but
                    // is never advertised as reusable authority. The registry
                    // records the resulting unconfirmed incident for review.
                    caughtError = error
                }
            }
            // Reconciliation may prove that a rename took effect even when the
            // injected call returned EINTR. Never launder that published or
            // publication-ambiguous outcome into a pre-publication failure.
            if case .indeterminate = caughtError as? SecureLocalFileError {
                throw caughtError
            }
            if publicationOccurred {
                let operation: SecureLocalFileOperation?
                let code: Int32?
                if let secureError = caughtError as? SecureLocalFileError,
                    case .operation(let failedOperation, let failedCode) = secureError
                {
                    operation = failedOperation
                    code = failedCode
                } else {
                    operation = .verify
                    code = nil
                }
                throw SecureLocalFileError.indeterminate(
                    transactionReceipt(
                        destination: observedDestinationURL(),
                        version: nil,
                        durability: .indeterminate(operation: operation, errno: code),
                        recoverySlot: nil))
            }
            let cause: SecureLocalFileError
            if let secureError = caughtError as? SecureLocalFileError {
                cause = secureError
            } else if let journalError = caughtError as? RecoveryJournalError {
                cause = .recoveryJournal(journalError)
            } else {
                cause = .operation(.verify, errno: EIO)
            }
            let recovery = stageMutationRestoreFlags == nil
                ? exactRetainedStage(
                    stage,
                    descriptor: stageDescriptor,
                    syscalls: syscalls)
                : nil
            throw SecureLocalFileError.prepublicationFailure(
                cause: cause,
                receipt: transactionReceipt(
                    destination: observedDestinationURL(),
                    version: nil,
                    durability: recovery == nil
                        ? .notPublishedRecoveryUnconfirmed(operation: .verify, errno: nil)
                        : .notPublishedRecoveryRetained,
                    recoverySlot: recovery.map {
                        FileRecoverySlot(
                            authority: $0,
                            contents: recoveryContentsOnFailure)
                    }))
        }
    }

    private func acquireStage(
        syscalls: SecureFileSyscalls
    ) throws -> (FileComponent, Int32, FileRecoveryContents) {
        guard let reusableStage else {
            let (component, descriptor) = try createStage(syscalls: syscalls)
            return (component, descriptor, .unpublishedScratch)
        }
        return try reopenReusableStage(reusableStage, syscalls: syscalls)
    }

    /// Reacquires one retained name without ever granting pathname authority
    /// from metadata alone. The read descriptor proves the complete old token;
    /// only after owner-controlled flags/mode are normalized is the same name
    /// reopened read-write and required to match the refreshed held inode.
    private func reopenReusableStage(
        _ slot: FileRecoverySlot,
        syscalls: SecureFileSyscalls
    ) throws -> (FileComponent, Int32, FileRecoveryContents) {
        let authority = slot.authority
        let stage = authority.component
        let held: Int32
        do {
            held = try directory.openRegularDescriptor(
                stage,
                requireUniqueLink: true,
                cancellationCheck: cancellationCheck)
        } catch {
            throw SecureLocalFileError.recoverySlotUnavailable(
                cause: error as? SecureLocalFileError
                    ?? .operation(.openTarget, errno: EIO))
        }
        defer { _ = syscalls.close(held) }

        do {
            let admitted = try SecureLocalDirectoryHandle.version(
                descriptor: held,
                maximumBytes: maximumBytes,
                syscalls: syscalls,
                cancellationCheck: cancellationCheck).token
            guard admitted == authority.version else {
                throw SecureLocalFileError.expectationMismatch
            }
            let named = try directory.version(
                of: stage,
                maximumBytes: maximumBytes,
                cancellationCheck: cancellationCheck)
            guard named == admitted else {
                throw SecureLocalFileError.expectationMismatch
            }
        } catch {
            throw SecureLocalFileError.recoverySlotUnavailable(
                cause: error as? SecureLocalFileError
                    ?? .operation(.verify, errno: EIO))
        }

        var recoveryContents = slot.contents
        do {
            _ = try requireSystemCall(
                .metadata,
                cancellationCheck: cancellationCheck,
                succeeds: { $0 == 0 }
            ) {
                recoveryContents = .unpublishedScratch
                return syscalls.fchflags(held, 0)
            }
            _ = try requireSystemCall(
                .metadata,
                cancellationCheck: cancellationCheck,
                succeeds: { $0 == 0 }
            ) {
                syscalls.fchmod(held, 0o600)
            }
            let normalized = try SecureLocalDirectoryHandle.version(
                descriptor: held,
                maximumBytes: maximumBytes,
                syscalls: syscalls,
                cancellationCheck: cancellationCheck).token
            let writable = try directory.openRegularDescriptor(
                stage,
                requireUniqueLink: true,
                accessMode: O_RDWR,
                cancellationCheck: cancellationCheck)
            do {
                let reopened = try SecureLocalDirectoryHandle.version(
                    descriptor: writable,
                    maximumBytes: maximumBytes,
                    syscalls: syscalls,
                    cancellationCheck: cancellationCheck).token
                guard reopened == normalized else {
                    throw SecureLocalFileError.expectationMismatch
                }
                return (stage, writable, recoveryContents)
            } catch {
                _ = syscalls.close(writable)
                throw error
            }
        } catch {
            let cause = error as? SecureLocalFileError
                ?? .operation(.verify, errno: EIO)
            let recovery = exactRetainedStage(
                stage,
                descriptor: held,
                syscalls: syscalls)
            throw SecureLocalFileError.prepublicationFailure(
                cause: cause,
                receipt: transactionReceipt(
                    destination: observedDestinationURL(),
                    version: nil,
                    durability: recovery == nil
                        ? .notPublishedRecoveryUnconfirmed(operation: .verify, errno: nil)
                        : .notPublishedRecoveryRetained,
                    recoverySlot: recovery.map {
                        FileRecoverySlot(authority: $0, contents: recoveryContents)
                    }))
        }
    }

    private func createStage(
        syscalls: SecureFileSyscalls
    ) throws -> (FileComponent, Int32) {
        var lastError = EEXIST
        let candidates: [FileComponent]
        if let preferredStageComponent {
            candidates = [preferredStageComponent]
        } else {
            candidates = try (0..<Self.maximumStageNameAttempts).map { _ in
                try FileComponent(".markdev-stage-\(UUID().uuidString.lowercased())")
            }
        }
        for stage in candidates {
            if cancellationCheck() { throw SecureLocalFileError.cancelled }
            errno = 0
            let descriptor = stage.rawValue.withCString {
                syscalls.createAt(
                    directory.descriptor,
                    $0,
                    O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC
                        | O_RESOLVE_BENEATH,
                    0o600)
            }
            if descriptor >= 0 { return (stage, descriptor) }
            lastError = errno == 0 ? EIO : errno
            if lastError == EINTR {
                // Creation may already have taken effect. Never retry this
                // component and never grant authority from a later pathname
                // lookup: a bystander may have won the name after a no-effect
                // return. Without the returned descriptor, authorship is
                // unprovable, so the possible artifact is retained but
                // deliberately not reusable.
                throw SecureLocalFileError.prepublicationFailure(
                    cause: .operation(.createStage, errno: EINTR),
                    receipt: transactionReceipt(
                        destination: observedDestinationURL(),
                        version: nil,
                        durability: .notPublishedRecoveryUnconfirmed(
                            operation: .createStage,
                            errno: EINTR),
                        recoverySlot: nil))
            }
            if lastError != EEXIST || preferredStageComponent != nil { break }
        }
        throw SecureLocalFileError.operation(.createStage, errno: lastError)
    }

    /// Makes either a fresh or previously retained inode an empty, positioned,
    /// metadata-neutral scratch file. Truncation and seeking are safe to retry:
    /// both operations repeat the same idempotent effect at offset zero.
    ///
    /// `UF_IMMUTABLE` closes the accidental hard-link attachment window around
    /// destructive byte mutation. It is defense in depth, not an authorization
    /// boundary against another process running as the same UID: that process
    /// can clear owner flags and can directly mutate the user-owned destination.
    /// Isolating a malicious equal-credential writer requires an OS credential
    /// boundary or a fresh-inode durable recovery journal, not pathname checks.
    private func prepareStageForWrite(
        _ descriptor: Int32,
        syscalls: SecureFileSyscalls,
        mutationWillBegin: () -> Void,
        mutationGuardDidActivate: (UInt32) -> Void
    ) throws {
        try removeExtendedAttributes(
            from: descriptor,
            mutationWillBegin: mutationWillBegin)
        try removeExtendedACL(
            from: descriptor,
            mutationWillBegin: mutationWillBegin)
        try activateStageMutationGuard(
            descriptor,
            syscalls: syscalls,
            mutationWillBegin: mutationWillBegin,
            didActivate: mutationGuardDidActivate)
        _ = try requireSystemCall(
            .truncate,
            cancellationCheck: cancellationCheck,
            succeeds: { $0 == 0 }
        ) {
            mutationWillBegin()
            return syscalls.ftruncate(descriptor, 0)
        }
        _ = try requireSystemCall(
            .seek,
            cancellationCheck: cancellationCheck,
            succeeds: { $0 == 0 }
        ) {
            mutationWillBegin()
            return syscalls.lseek(descriptor, 0, SEEK_SET)
        }
    }

    private func activateStageMutationGuard(
        _ descriptor: Int32,
        syscalls: SecureFileSyscalls,
        mutationWillBegin: () -> Void,
        didActivate: (UInt32) -> Void
    ) throws {
        if cancellationCheck() { throw SecureLocalFileError.cancelled }
        var before = stat()
        _ = try requireSystemCall(
            .inspect,
            cancellationCheck: cancellationCheck,
            succeeds: { $0 == 0 }
        ) {
            syscalls.fstat(descriptor, &before)
        }
        guard before.st_mode & S_IFMT == S_IFREG else {
            throw SecureLocalFileError.unsupportedEntry
        }
        guard before.st_nlink == 1 else {
            throw SecureLocalFileError.hardLinkedEntry
        }
        let restoreFlags = before.st_flags
        guard restoreFlags & Self.lockedFlags == 0 else {
            throw SecureLocalFileError.operation(.metadata, errno: EPERM)
        }
        let guardedFlags = restoreFlags | UInt32(UF_IMMUTABLE)
        mutationWillBegin()
        // From this point the call may have taken effect even if its return is
        // interrupted. Register restoration authority before crossing it.
        didActivate(restoreFlags)
        let outcome = InterruptedSyscall.run(
            cancellationCheck: { false },
            succeeds: { $0 == 0 }
        ) {
            syscalls.fchflags(descriptor, guardedFlags)
        }
        switch outcome {
        case .success:
            break
        case .failure(let code):
            // fchflags is idempotent. If every injected EINTR happened after
            // effect, descriptor state proves the requested guard despite the
            // return value; otherwise the failure remains authoritative.
            var reconciled = stat()
            guard syscalls.fstat(descriptor, &reconciled) == 0,
                reconciled.st_flags == guardedFlags
            else {
                throw SecureLocalFileError.operation(.metadata, errno: code)
            }
        case .cancelled:
            preconditionFailure("mutation-guard installation does not cancel after effect begins")
        }
        var guarded = stat()
        _ = try requireSystemCall(
            .verify,
            cancellationCheck: { false },
            succeeds: { $0 == 0 }
        ) {
            syscalls.fstat(descriptor, &guarded)
        }
        guard guarded.st_mode & S_IFMT == S_IFREG else {
            throw SecureLocalFileError.unsupportedEntry
        }
        guard guarded.st_nlink == 1 else {
            throw SecureLocalFileError.hardLinkedEntry
        }
        guard guarded.st_flags == guardedFlags else {
            throw SecureLocalFileError.expectationMismatch
        }
    }

    private func restoreStageMutationGuard(
        _ descriptor: Int32,
        flags restoreFlags: UInt32,
        syscalls: SecureFileSyscalls
    ) throws {
        var before = stat()
        _ = try requireSystemCall(
            .verify,
            cancellationCheck: { false },
            succeeds: { $0 == 0 }
        ) {
            syscalls.fstat(descriptor, &before)
        }
        guard before.st_mode & S_IFMT == S_IFREG else {
            throw SecureLocalFileError.unsupportedEntry
        }
        guard before.st_nlink == 1 else {
            throw SecureLocalFileError.hardLinkedEntry
        }
        if before.st_flags == restoreFlags { return }

        let outcome = InterruptedSyscall.run(
            cancellationCheck: { false },
            succeeds: { $0 == 0 }
        ) {
            syscalls.fchflags(descriptor, restoreFlags)
        }
        switch outcome {
        case .success:
            break
        case .failure(let code):
            var reconciled = stat()
            guard syscalls.fstat(descriptor, &reconciled) == 0,
                reconciled.st_flags == restoreFlags
            else {
                throw SecureLocalFileError.operation(.metadata, errno: code)
            }
        case .cancelled:
            preconditionFailure("mutation-guard restoration is deliberately non-cancellable")
        }

        var restored = stat()
        _ = try requireSystemCall(
            .verify,
            cancellationCheck: { false },
            succeeds: { $0 == 0 }
        ) {
            syscalls.fstat(descriptor, &restored)
        }
        guard restored.st_mode & S_IFMT == S_IFREG else {
            throw SecureLocalFileError.unsupportedEntry
        }
        guard restored.st_nlink == 1 else {
            throw SecureLocalFileError.hardLinkedEntry
        }
        guard restored.st_flags == restoreFlags else {
            throw SecureLocalFileError.expectationMismatch
        }
    }

    private func writeAll(to descriptor: Int32, syscalls: SecureFileSyscalls) throws {
        var offset = 0
        while offset < data.count {
            if cancellationCheck() { throw SecureLocalFileError.cancelled }
            let written: Int = try requireSystemCall(
                .write,
                cancellationCheck: cancellationCheck,
                succeeds: { $0 >= 0 }
            ) {
                data.withUnsafeBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return 0 }
                    return syscalls.write(
                        descriptor, base.advanced(by: offset), raw.count - offset)
                }
            }
            if written > 0 {
                let (nextOffset, overflow) = offset.addingReportingOverflow(written)
                guard !overflow, nextOffset <= data.count else {
                    throw SecureLocalFileError.operation(.write, errno: EOVERFLOW)
                }
                offset = nextOffset
                continue
            }
            throw SecureLocalFileError.operation(.write, errno: EIO)
        }
    }

    /// Last userspace binding check before the one-shot rename. The descriptor
    /// token proves the bytes being published and the name token proves that
    /// the retained parent still binds this component to that same inode.
    private func verifyFinalStageBinding(
        _ stage: FileComponent,
        descriptor: Int32,
        expectedVersion: FileVersionToken,
        syscalls: SecureFileSyscalls
    ) throws {
        let descriptorVersion = try SecureLocalDirectoryHandle.version(
            descriptor: descriptor,
            maximumBytes: maximumBytes,
            syscalls: syscalls,
            cancellationCheck: cancellationCheck).token
        guard descriptorVersion == expectedVersion else {
            throw SecureLocalFileError.expectationMismatch
        }
        let namedVersion = try directory.version(
            of: stage,
            maximumBytes: maximumBytes,
            cancellationCheck: cancellationCheck)
        guard namedVersion == descriptorVersion else {
            throw SecureLocalFileError.expectationMismatch
        }
    }

    private func applyMetadata(
        original: SecureLocalDirectoryHandle.OpenedRegularFile?,
        stageDescriptor: Int32,
        syscalls: SecureFileSyscalls
    ) throws {
        switch policy {
        case .privateStorage:
            _ = try requireSystemCall(
                .metadata,
                cancellationCheck: cancellationCheck,
                succeeds: { $0 == 0 }
            ) {
                syscalls.fchmod(stageDescriptor, 0o600)
            }
            _ = try requireSystemCall(
                .metadata,
                cancellationCheck: cancellationCheck,
                succeeds: { $0 == 0 }
            ) {
                syscalls.fchflags(stageDescriptor, 0)
            }
            try verifyAppliedMetadata(
                stageDescriptor,
                expectedMode: 0o600,
                expectedOwnerID: geteuid(),
                expectedGroupID: nil,
                expectedFlags: 0,
                syscalls: syscalls)

        case .userContent:
            guard let original else {
                // New documents default to owner-only. Existing documents keep
                // their verified mode, but Save As never widens access.
                _ = try requireSystemCall(
                    .metadata,
                    cancellationCheck: cancellationCheck,
                    succeeds: { $0 == 0 }
                ) {
                    syscalls.fchmod(stageDescriptor, 0o600)
                }
                _ = try requireSystemCall(
                    .metadata,
                    cancellationCheck: cancellationCheck,
                    succeeds: { $0 == 0 }
                ) {
                    syscalls.fchflags(stageDescriptor, 0)
                }
                try verifyAppliedMetadata(
                    stageDescriptor,
                    expectedMode: 0o600,
                    expectedOwnerID: geteuid(),
                    expectedGroupID: nil,
                    expectedFlags: 0,
                    syscalls: syscalls)
                return
            }
            // ACLs and xattrs include Finder tags and resource forks. COPYFILE
            // deliberately excludes data; timestamps are allowed to reflect the
            // save rather than being forged back to the previous value.
            let copyResult = fcopyfile(
                original.descriptor,
                stageDescriptor,
                nil,
                copyfile_flags_t(COPYFILE_ACL | COPYFILE_XATTR))
            let copyError = copyResult == 0 ? 0 : errno
            guard copyResult == 0 else {
                throw SecureLocalFileError.operation(.metadata, errno: copyError)
            }
            let status = original.status
            let chownOutcome = InterruptedSyscall.run(
                cancellationCheck: cancellationCheck,
                succeeds: { $0 == 0 }
            ) {
                syscalls.fchown(stageDescriptor, status.st_uid, status.st_gid)
            }
            if case .cancelled = chownOutcome {
                throw SecureLocalFileError.cancelled
            }
            if case .failure(let chownError) = chownOutcome {
                var stageStatus = stat()
                _ = try requireSystemCall(
                    .metadata,
                    cancellationCheck: cancellationCheck,
                    succeeds: { $0 == 0 }
                ) {
                    syscalls.fstat(stageDescriptor, &stageStatus)
                }
                guard stageStatus.st_uid == status.st_uid,
                    stageStatus.st_gid == status.st_gid
                else {
                    throw SecureLocalFileError.operation(.metadata, errno: chownError)
                }
            }
            _ = try requireSystemCall(
                .metadata,
                cancellationCheck: cancellationCheck,
                succeeds: { $0 == 0 }
            ) {
                syscalls.fchmod(stageDescriptor, status.st_mode & mode_t(0o0777))
            }
            let preservedFlags = status.st_flags & Self.preservedUserFlags
            _ = try requireSystemCall(
                .metadata,
                cancellationCheck: cancellationCheck,
                succeeds: { $0 == 0 }
            ) {
                syscalls.fchflags(stageDescriptor, preservedFlags)
            }
            try verifyAppliedMetadata(
                stageDescriptor,
                expectedMode: status.st_mode & mode_t(0o0777),
                expectedOwnerID: status.st_uid,
                expectedGroupID: status.st_gid,
                expectedFlags: preservedFlags,
                syscalls: syscalls)
        }
    }

    private func verifyAppliedMetadata(
        _ descriptor: Int32,
        expectedMode: mode_t,
        expectedOwnerID: uid_t,
        expectedGroupID: gid_t?,
        expectedFlags: UInt32,
        syscalls: SecureFileSyscalls
    ) throws {
        if cancellationCheck() { throw SecureLocalFileError.cancelled }
        var status = stat()
        _ = try requireSystemCall(
            .verify,
            cancellationCheck: cancellationCheck,
            succeeds: { $0 == 0 }
        ) {
            syscalls.fstat(descriptor, &status)
        }
        guard status.st_mode & mode_t(0o0777) == expectedMode,
            status.st_uid == expectedOwnerID,
            expectedGroupID == nil || status.st_gid == expectedGroupID,
            status.st_flags == expectedFlags
        else { throw SecureLocalFileError.expectationMismatch }
    }

    private func removeExtendedAttributes(
        from descriptor: Int32,
        mutationWillBegin: () -> Void
    ) throws {
        // These APIs are issued once rather than retried: unlike read/write,
        // their interruption semantics do not establish a safe repeat point.
        // A failure is therefore bounded and surfaced before publication.
        let names = try extendedAttributeNames(from: descriptor)
        for attribute in names {
            if cancellationCheck() { throw SecureLocalFileError.cancelled }
            let result = attribute.withCString {
                mutationWillBegin()
                return fremovexattr(descriptor, $0, 0)
            }
            let removeError = result == 0 ? 0 : errno
            guard result == 0 || removeError == ENOATTR else {
                throw SecureLocalFileError.operation(.metadata, errno: removeError)
            }
        }
        let remaining = try extendedAttributeNames(from: descriptor)
        guard Set(remaining).isSubset(of: Self.allowedKernelManagedResidualAttributes) else {
            throw SecureLocalFileError.expectationMismatch
        }
    }

    private func extendedAttributeNames(from descriptor: Int32) throws -> [String] {
        if cancellationCheck() { throw SecureLocalFileError.cancelled }
        let length = flistxattr(descriptor, nil, 0, 0)
        let lengthError = length >= 0 ? 0 : errno
        guard length >= 0 else {
            throw SecureLocalFileError.operation(.metadata, errno: lengthError)
        }
        guard length > 0 else { return [] }
        guard length <= 64 * 1_024 else {
            throw SecureLocalFileError.operation(.metadata, errno: E2BIG)
        }
        var bytes = [CChar](repeating: 0, count: length)
        let read = bytes.withUnsafeMutableBufferPointer {
            flistxattr(descriptor, $0.baseAddress, $0.count, 0)
        }
        let readError = read >= 0 ? 0 : errno
        guard read == length else {
            throw SecureLocalFileError.operation(
                .metadata, errno: readError == 0 ? EIO : readError)
        }
        var names: [String] = []
        var start = 0
        while start < bytes.count {
            if cancellationCheck() { throw SecureLocalFileError.cancelled }
            guard let end = bytes[start...].firstIndex(of: 0), end > start else {
                throw SecureLocalFileError.operation(.metadata, errno: EIO)
            }
            let terminated = Array(bytes[start..<end]) + [0]
            guard let name = terminated.withUnsafeBufferPointer({ buffer in
                buffer.baseAddress.flatMap(String.init(validatingCString:))
            }) else { throw SecureLocalFileError.operation(.metadata, errno: EILSEQ) }
            names.append(name)
            start = end + 1
        }
        return names
    }

    private func removeExtendedACL(
        from descriptor: Int32,
        mutationWillBegin: () -> Void
    ) throws {
        if cancellationCheck() { throw SecureLocalFileError.cancelled }
        guard let empty = acl_init(0) else {
            let code = errno
            throw SecureLocalFileError.operation(.metadata, errno: code)
        }
        defer { acl_free(UnsafeMutableRawPointer(empty)) }
        mutationWillBegin()
        let result = acl_set_fd_np(descriptor, empty, ACL_TYPE_EXTENDED)
        let code = result == 0 ? 0 : errno
        guard result == 0 else {
            throw SecureLocalFileError.operation(.metadata, errno: code)
        }
        errno = 0
        guard let applied = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            let readError = errno
            if readError == ENOENT { return }
            throw SecureLocalFileError.operation(.metadata, errno: readError == 0 ? EIO : readError)
        }
        defer { acl_free(UnsafeMutableRawPointer(applied)) }
        var entry: acl_entry_t?
        errno = 0
        let entryResult = acl_get_entry(applied, ACL_FIRST_ENTRY.rawValue, &entry)
        if entryResult == 0 { throw SecureLocalFileError.expectationMismatch }
        guard errno == EINVAL else {
            throw SecureLocalFileError.operation(.metadata, errno: errno == 0 ? EIO : errno)
        }
    }

    private func verifyStage(_ descriptor: Int32, syscalls: SecureFileSyscalls) throws {
        var status = stat()
        _ = try requireSystemCall(
            .verify,
            cancellationCheck: cancellationCheck,
            succeeds: { $0 == 0 }
        ) {
            syscalls.fstat(descriptor, &status)
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw SecureLocalFileError.unsupportedEntry
        }
        guard status.st_nlink == 1 else { throw SecureLocalFileError.hardLinkedEntry }
    }

    private func rename(
        _ source: FileComponent,
        _ destination: FileComponent,
        flags: UInt32
    ) -> Int32 {
        source.rawValue.withCString { sourceName in
            destination.rawValue.withCString { destinationName in
                directory.syscalls.renameAtX(
                    directory.descriptor,
                    sourceName,
                    directory.descriptor,
                    destinationName,
                    flags)
            }
        }
    }

    /// Darwin documents a failed rename as leaving both names unchanged and
    /// does not list `EINTR` for `renameatx_np`. The injectable syscall seam is
    /// intentionally stronger: a wrapper or remote implementation may report
    /// interruption after applying the mutation. Only that ambiguous error is
    /// reconciled, and no second rename is issued.
    private func reconcileInterruptedMissingPublish(
        stage: FileComponent,
        newVersion: FileVersionToken,
        stageDescriptor: Int32
    ) -> InterruptedPublishOutcome {
        let destinationVersion = try? versionIfPresent(component)
        let stageVersion = try? versionIfPresent(stage)

        if destinationVersion == nil, stageVersion == newVersion {
            return .noEffect
        }

        let committedVersion = try? SecureLocalDirectoryHandle.refreshedVersionAfterRename(
            descriptor: stageDescriptor,
            preRename: newVersion,
            maximumBytes: maximumBytes,
            syscalls: directory.syscalls)
        let published = destinationVersion.map { $0.matchesAcrossRename(newVersion) } == true
        let stageIsMissing = stageVersion == nil
        return .indeterminate(
            transactionReceipt(
                destination: observedDestinationURL(),
                version: published ? committedVersion : nil,
                durability: .indeterminate(operation: .publish, errno: EINTR),
                recoverySlot: stageIsMissing ? nil : stageVersion.flatMap { observed in
                    observed == newVersion
                        ? FileRecoverySlot(
                            authority: FileRecoveryAuthority(
                                component: stage,
                                version: observed,
                                destinationKey: destinationKey),
                            contents: .unpublishedScratch)
                        : nil
                }))
    }

    private func reconcileInterruptedSwapPublish(
        stage: FileComponent,
        admittedExpected: FileVersionToken,
        newVersion: FileVersionToken,
        stageDescriptor: Int32
    ) -> InterruptedPublishOutcome {
        let destinationVersion = try? versionIfPresent(component)
        let stageVersion = try? versionIfPresent(stage)

        if destinationVersion == admittedExpected, stageVersion == newVersion {
            return .noEffect
        }

        let committedVersion = try? SecureLocalDirectoryHandle.refreshedVersionAfterRename(
            descriptor: stageDescriptor,
            preRename: newVersion,
            maximumBytes: maximumBytes,
            syscalls: directory.syscalls)
        let published = destinationVersion.map { $0.matchesAcrossRename(newVersion) } == true
        let displacedIsRecoverable = stageVersion.map {
            $0.matchesAcrossRename(admittedExpected)
        } == true
        return .indeterminate(
            transactionReceipt(
                destination: observedDestinationURL(),
                version: published ? committedVersion : nil,
                durability: .indeterminate(operation: .publish, errno: EINTR),
                recoverySlot: displacedIsRecoverable ? stageVersion.map {
                    FileRecoverySlot(
                        authority: FileRecoveryAuthority(
                            component: stage,
                            version: $0,
                            destinationKey: destinationKey),
                        contents: .previousDestination)
                } : nil))
    }

    private func versionIfPresent(_ component: FileComponent) throws -> FileVersionToken? {
        do {
            return try directory.version(
                of: component,
                maximumBytes: maximumBytes,
                cancellationCheck: { false })
        } catch SecureLocalFileError.operation(.openTarget, let code) where code == ENOENT {
            return nil
        }
    }

    private func observeLifecycle(_ event: FileTransactionLifecycleEvent) throws {
        guard let lifecycleObserver else { return }
        do {
            try lifecycleObserver(event)
        } catch let error as SecureLocalFileError {
            throw error
        } catch let error as RecoveryJournalError {
            throw SecureLocalFileError.recoveryJournal(error)
        } catch {
            throw SecureLocalFileError.operation(.verify, errno: EIO)
        }
    }

    /// Publication has already occurred when this checkpoint runs. Preserve
    /// the exact committed and recovery authority in an indeterminate receipt
    /// if the durable journal cannot acknowledge it.
    private func finishCommitted(
        _ receipt: FileTransactionReceipt
    ) throws -> FileTransactionReceipt {
        do {
            try observeLifecycle(.committed(receipt))
            return receipt
        } catch {
            throw SecureLocalFileError.indeterminate(
                receipt.replacingDurability(
                    .indeterminate(operation: .syncFile, errno: nil)))
        }
    }

    private func transactionReceipt(
        destination: URL,
        version: FileVersionToken?,
        durability: FileTransactionDurability,
        recoverySlot: FileRecoverySlot?
    ) -> FileTransactionReceipt {
        FileTransactionReceipt(
            destination: destination,
            version: version,
            durability: durability,
            recoverySlot: recoverySlot,
            authoritativeDestinationKey: destinationKey)
    }

    private func committedReceipt(
        version: FileVersionToken,
        recovery: FileRecoveryAuthority?
    ) -> FileTransactionReceipt {
        let directorySyncError = syncDirectory(syscalls: directory.syscalls)
        if let recovery {
            return FileTransactionReceipt(
                destination: observedDestinationURL(),
                version: version,
                durability: .recoveryRetained(directorySyncErrno: directorySyncError),
                recoverySlot: FileRecoverySlot(
                    authority: recovery,
                    contents: .previousDestination),
                authoritativeDestinationKey: destinationKey)
        }
        return FileTransactionReceipt(
            destination: observedDestinationURL(),
            version: version,
            durability: directorySyncError == nil
                ? .fullySynced
                : .committedDirectorySyncUnconfirmed(errno: directorySyncError ?? EIO),
            recoverySlot: nil,
            authoritativeDestinationKey: destinationKey)
    }

    /// Proves the retained descriptor and the descriptor-relative name still
    /// identify one exact inode. It never mutates the name: Darwin offers no
    /// public identity-conditional unlink, so a failed transaction retains the
    /// exact stage instead of risking deletion of a substituted bystander.
    private func exactRetainedStage(
        _ stage: FileComponent,
        descriptor: Int32,
        syscalls: SecureFileSyscalls
    ) -> FileRecoveryAuthority? {
        guard let descriptorVersion = try? SecureLocalDirectoryHandle.version(
            descriptor: descriptor,
            maximumBytes: maximumBytes,
            syscalls: syscalls,
            cancellationCheck: { false }).token,
            let namedVersion = try? directory.version(
                of: stage,
                maximumBytes: maximumBytes,
                cancellationCheck: { false }),
            namedVersion == descriptorVersion
        else { return nil }
        guard descriptorVersion.linkCount == 1 else { return nil }
        return FileRecoveryAuthority(
            component: stage,
            version: descriptorVersion,
            destinationKey: destinationKey)
    }

    private func observedDestinationURL() -> URL {
        directory.currentDestinationURL(component) ?? directory.destinationURL(component)
    }

    /// A final name check before rename cannot make the pathname operation
    /// identity-conditional. After the one-shot mutation, compare the held
    /// inode with the descriptor-relative destination entry. Path strings,
    /// including `F_GETPATH`, are presentation data and cannot prove this
    /// binding across case folding, Unicode normalization, or parent moves.
    private func publishedDescriptorIsBoundToDestination(_ descriptor: Int32) -> Bool {
        let syscalls = directory.syscalls
        var held = stat()
        let heldOutcome = InterruptedSyscall.run(
            cancellationCheck: { false },
            succeeds: { $0 == 0 }
        ) {
            syscalls.fstat(descriptor, &held)
        }
        guard case .success = heldOutcome else { return false }

        var named = stat()
        let namedOutcome = InterruptedSyscall.run(
            cancellationCheck: { false },
            succeeds: { $0 == 0 }
        ) {
            component.rawValue.withCString {
                syscalls.fstatAt(
                    directory.descriptor,
                    $0,
                    &named,
                    AT_SYMLINK_NOFOLLOW | AT_RESOLVE_BENEATH)
            }
        }
        guard case .success = namedOutcome,
            held.st_mode & S_IFMT == S_IFREG,
            named.st_mode & S_IFMT == S_IFREG,
            held.st_nlink == 1,
            named.st_nlink == 1
        else { return false }
        return LocalFileIdentity(held) == LocalFileIdentity(named)
    }

    private func syncDirectory(syscalls: SecureFileSyscalls) -> Int32? {
        switch InterruptedSyscall.run(
            cancellationCheck: { false },
            succeeds: { $0 == 0 },
            { syscalls.fsync(directory.descriptor) })
        {
        case .success:
            return nil
        case .failure(let code):
            return code
        case .cancelled:
            return ECANCELED
        }
    }
}

extension SecureLocalFileSystem {
    /// Reacquires every persisted observation through fresh descriptor-relative
    /// opens. The decoded journal is never itself a capability: only exact
    /// identity, metadata, digest, single-link, and namespace matches can mint
    /// a process-local recovery slot.
    static func reconcileRecoveryJournalEntry(
        _ entry: RecoveryJournalEntry,
        resolvedDestinationURL: URL? = nil,
        maximumBytes: Int = MarkdownReadLimits.maximumDocumentBytes,
        syscalls: SecureFileSyscalls = .live,
        cancellationCheck: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> RecoveryJournalLiveReconciliation {
        guard maximumBytes >= 0,
            let persistedURL = entry.destination.presentationURL,
            let destinationComponent = try? entry.destination.fileComponent()
        else { return .requiresReview }
        let requestedDestinationURL = resolvedDestinationURL ?? persistedURL
        guard BoundedRegularFileReader.hasLocalFileAuthority(requestedDestinationURL) else {
            return .requiresReview
        }
        let destinationURL = requestedDestinationURL.standardizedFileURL
        guard
            Data(destinationURL.lastPathComponent.utf8)
                == entry.destination.componentBytes
        else { return .requiresReview }

        let directory: SecureLocalDirectoryHandle
        do {
            directory = try SecureLocalDirectoryHandle(
                opening: destinationURL.deletingLastPathComponent(),
                syscalls: syscalls,
                cancellationCheck: cancellationCheck)
        } catch SecureLocalFileError.cancelled {
            throw SecureLocalFileError.cancelled
        } catch {
            return .requiresReview
        }
        let liveKey: FileDestinationKey
        do {
            liveKey = try directory.destinationKey(
                destinationComponent,
                cancellationCheck: cancellationCheck)
        } catch SecureLocalFileError.cancelled {
            throw SecureLocalFileError.cancelled
        } catch {
            return .requiresReview
        }
        guard entry.destination.matches(liveKey) else {
            return .requiresReview
        }

        let destinationVersion: FileVersionToken?
        do {
            destinationVersion = try journalVersionIfPresent(
                in: directory,
                component: destinationComponent,
                maximumBytes: maximumBytes,
                cancellationCheck: cancellationCheck)
        } catch SecureLocalFileError.cancelled {
            throw SecureLocalFileError.cancelled
        } catch {
            return .requiresReview
        }

        let stageComponent: FileComponent?
        let stageVersion: FileVersionToken?
        if let stage = entry.stage {
            guard stage.isScoped(to: entry.destination),
                let component = try? stage.fileComponent()
            else { return .requiresReview }
            stageComponent = component
            do {
                stageVersion = try journalVersionIfPresent(
                    in: directory,
                    component: component,
                    maximumBytes: maximumBytes,
                    cancellationCheck: cancellationCheck)
            } catch SecureLocalFileError.cancelled {
                throw SecureLocalFileError.cancelled
            } catch {
                return .requiresReview
            }
        } else {
            stageComponent = nil
            stageVersion = nil
        }

        func exactStageSlot(contents: FileRecoveryContents) -> FileRecoverySlot? {
            guard let observation = entry.stage,
                let component = stageComponent,
                let version = stageVersion,
                observation.version.matches(version)
            else { return nil }
            return FileRecoverySlot(
                authority: FileRecoveryAuthority(
                    component: component,
                    version: version,
                    destinationKey: liveKey),
                contents: contents)
        }

        func expectationStillHolds() -> Bool {
            switch entry.expectation {
            case .missing:
                return destinationVersion == nil
            case .exact(let expected):
                return destinationVersion.map(expected.matches) == true
            }
        }

        func reconcilePublishingTopology() -> RecoveryJournalLiveReconciliation {
            guard let stage = entry.stage,
                stage.contents == .unpublishedScratch
            else { return .requiresReview }

            if expectationStillHolds(),
                let slot = exactStageSlot(contents: .unpublishedScratch)
            {
                return .reusable(slot)
            }
            guard let committed = destinationVersion,
                stage.version.matchesAcrossRename(committed)
            else { return .requiresReview }
            switch entry.expectation {
            case .missing:
                guard stageVersion == nil else { return .requiresReview }
                return .published(version: committed, recovery: nil)
            case .exact(let expected):
                guard let displaced = stageVersion,
                    expected.matchesAcrossRename(displaced),
                    let component = stageComponent
                else { return .requiresReview }
                let slot = FileRecoverySlot(
                    authority: FileRecoveryAuthority(
                        component: component,
                        version: displaced,
                        destinationKey: liveKey),
                    contents: .previousDestination)
                return .published(version: committed, recovery: slot)
            }
        }

        switch entry.phase {
        case .preparing:
            guard expectationStillHolds() else { return .requiresReview }
            guard let stage = entry.stage else {
                guard let plannedName = entry.plannedStageComponent,
                    let planned = try? FileComponent(plannedName)
                else { return .noRecovery }
                do {
                    // A planned name is an observation boundary, not inode
                    // authority. Absence proves that the one-shot create did
                    // not leave an artifact; any present object is preserved
                    // and requires review because authorship is unknowable.
                    return try journalVersionIfPresent(
                        in: directory,
                        component: planned,
                        maximumBytes: maximumBytes,
                        cancellationCheck: cancellationCheck) == nil
                        ? .noRecovery
                        : .requiresReview
                } catch SecureLocalFileError.cancelled {
                    throw SecureLocalFileError.cancelled
                } catch {
                    return .requiresReview
                }
            }
            guard let slot = exactStageSlot(contents: stage.contents.liveValue) else {
                return .requiresReview
            }
            return .reusable(slot)
        case .staged:
            guard entry.stage?.contents == .unpublishedScratch,
                expectationStillHolds(),
                let slot = exactStageSlot(contents: .unpublishedScratch)
            else { return .requiresReview }
            return .reusable(slot)
        case .publishing:
            return reconcilePublishingTopology()
        case .committed:
            guard let committedObservation = entry.committedDestinationVersion,
                let committed = destinationVersion,
                committedObservation.matches(committed)
            else { return .requiresReview }
            guard let stage = entry.stage else {
                return .published(version: committed, recovery: nil)
            }
            guard stage.contents == .previousDestination,
                let slot = exactStageSlot(contents: .previousDestination)
            else { return .requiresReview }
            return .published(version: committed, recovery: slot)
        case .indeterminate:
            if let committedObservation = entry.committedDestinationVersion,
                let committed = destinationVersion,
                committedObservation.matches(committed)
            {
                if entry.stage == nil {
                    return .published(version: committed, recovery: nil)
                }
                guard entry.stage?.contents == .previousDestination,
                    let slot = exactStageSlot(contents: .previousDestination)
                else { return .requiresReview }
                return .published(version: committed, recovery: slot)
            }
            return reconcilePublishingTopology()
        }
    }

    private static func journalVersionIfPresent(
        in directory: SecureLocalDirectoryHandle,
        component: FileComponent,
        maximumBytes: Int,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) throws -> FileVersionToken? {
        do {
            return try directory.version(
                of: component,
                maximumBytes: maximumBytes,
                cancellationCheck: cancellationCheck)
        } catch SecureLocalFileError.operation(.openTarget, let code) where code == ENOENT {
            return nil
        }
    }
}

/// User-visible files preserve their existing metadata and must be regular,
/// single-linked entries for replacement.
struct UserContentDirectory: Sendable {
    let handle: SecureLocalDirectoryHandle

    init(
        containing destination: URL,
        syscalls: SecureFileSyscalls = .live,
        cancellationCheck: @Sendable () -> Bool = { Task.isCancelled }
    ) throws {
        handle = try SecureLocalDirectoryHandle(
            opening: destination.deletingLastPathComponent(),
            syscalls: syscalls,
            cancellationCheck: cancellationCheck)
    }

    func component(for destination: URL) throws -> FileComponent {
        guard BoundedRegularFileReader.hasLocalFileAuthority(destination),
            destination.deletingLastPathComponent().standardizedFileURL == handle.url.standardizedFileURL
            || LocalFileSystem.canonicalIOURL(destination.deletingLastPathComponent())
                == handle.url.standardizedFileURL
        else { throw SecureLocalFileError.invalidComponent }
        return try FileComponent(destination.lastPathComponent)
    }

    /// Confirms the containing directory only while the retained descriptor,
    /// child name, and exact committed bytes still identify the authority the
    /// caller intends to make durable.
    func confirmDurability(
        component: FileComponent,
        expectedVersion: FileVersionToken,
        maximumBytes: Int,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) throws {
        precondition(maximumBytes >= 0, "confirmation limit must not be negative")
        try handle.verifyLocation()
        guard try handle.version(
            of: component,
            maximumBytes: maximumBytes,
            cancellationCheck: cancellationCheck) == expectedVersion
        else { throw SecureLocalFileError.expectationMismatch }
        _ = try requireSystemCall(
            .syncDirectory,
            cancellationCheck: cancellationCheck,
            succeeds: { $0 == 0 }
        ) {
            handle.syscalls.fsync(handle.descriptor)
        }
        if cancellationCheck() { throw SecureLocalFileError.cancelled }
        try handle.verifyLocation()
        guard try handle.version(
            of: component,
            maximumBytes: maximumBytes,
            cancellationCheck: cancellationCheck) == expectedVersion
        else { throw SecureLocalFileError.expectationMismatch }
    }
}

/// Private app storage enforces private directory/file modes and strips
/// inherited extended metadata from every staged file.
func clearAndVerifyExtendedACL(on descriptor: Int32) throws {
    guard let emptyACL = acl_init(0) else {
        throw SecureLocalFileError.operation(.metadata, errno: errno == 0 ? EIO : errno)
    }
    defer { acl_free(UnsafeMutableRawPointer(emptyACL)) }
    errno = 0
    let clearResult = acl_set_fd_np(descriptor, emptyACL, ACL_TYPE_EXTENDED)
    let clearError = errno
    guard clearResult == 0 else {
        throw SecureLocalFileError.operation(
            .metadata, errno: clearError == 0 ? EIO : clearError)
    }
    try verifyEmptyExtendedACL(on: descriptor)
}

func verifyEmptyExtendedACL(on descriptor: Int32) throws {
    errno = 0
    guard let appliedACL = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
        let readError = errno
        if readError == ENOENT { return }
        throw SecureLocalFileError.operation(
            .metadata, errno: readError == 0 ? EIO : readError)
    }
    defer { acl_free(UnsafeMutableRawPointer(appliedACL)) }
    var entry: acl_entry_t?
    errno = 0
    let entryResult = acl_get_entry(appliedACL, ACL_FIRST_ENTRY.rawValue, &entry)
    if entryResult == 0 { throw SecureLocalFileError.expectationMismatch }
    guard errno == EINVAL else {
        throw SecureLocalFileError.operation(.metadata, errno: errno == 0 ? EIO : errno)
    }
}

struct PrivateStorageDirectory: Sendable {
    let handle: SecureLocalDirectoryHandle

    init(existing url: URL, syscalls: SecureFileSyscalls = .live) throws {
        handle = try SecureLocalDirectoryHandle(opening: url, syscalls: syscalls)
        var status = stat()
        _ = try requireSystemCall(
            .metadata,
            cancellationCheck: { Task.isCancelled },
            succeeds: { $0 == 0 }
        ) {
            syscalls.fstat(handle.descriptor, &status)
        }
        guard status.st_mode & S_IFMT == S_IFDIR,
            status.st_uid == geteuid()
        else {
            throw SecureLocalFileError.unsupportedEntry
        }
        _ = try requireSystemCall(
            .metadata,
            cancellationCheck: { Task.isCancelled },
            succeeds: { $0 == 0 }
        ) {
            syscalls.fchmod(handle.descriptor, 0o700)
        }
        // Unsupported ACL semantics are not treated as private success;
        // callers can surface or choose a different storage location.
        try clearAndVerifyExtendedACL(on: handle.descriptor)
        var appliedStatus = stat()
        _ = try requireSystemCall(
            .metadata,
            cancellationCheck: { Task.isCancelled },
            succeeds: { $0 == 0 }
        ) {
            syscalls.fstat(handle.descriptor, &appliedStatus)
        }
        guard appliedStatus.st_mode & mode_t(0o0777) == 0o700,
            appliedStatus.st_uid == geteuid()
        else { throw SecureLocalFileError.expectationMismatch }
        try verifyEmptyExtendedACL(on: handle.descriptor)
    }
}
