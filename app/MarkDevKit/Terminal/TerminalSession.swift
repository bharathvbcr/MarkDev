//
//  TerminalSession.swift
//  MarkDevKit
//
//  What shell to run, and where — decided without a view.
//

import Foundation

/// How a shell ended.
///
/// SwiftTerm's delegate calls the value it hands over `exitCode`, but it is
/// the raw `waitpid` status: `exit 7` arrives as 1792, because the code sits
/// in the high byte. Reported as-is the drawer would say "exited (1792)",
/// which is worse than saying nothing. This decodes it the way `wait(2)`
/// documents.
public enum TerminalExit: Sendable, Equatable {
    /// Ended normally, with this status code.
    case code(Int32)
    /// Killed by a signal — `^C` is `.signal(2)`.
    case signal(Int32)
    /// The pty failed rather than the child; SwiftTerm reports no status.
    case unknown

    public init(waitStatus: Int32?) {
        guard let waitStatus else {
            self = .unknown
            return
        }
        let signal = waitStatus & 0x7F
        if signal == 0 {
            self = .code((waitStatus >> 8) & 0xFF)
        } else if signal == 0x7F {
            // Stopped, not exited. Nothing has ended, so nothing is reported.
            self = .unknown
        } else {
            self = .signal(signal)
        }
    }

    /// Whether the shell ended the way a shell normally does.
    public var isClean: Bool { self == .code(0) }

    /// What to show beside the drawer's title.
    public var summary: String {
        switch self {
        case .code(0): "exited"
        case .code(let code): "exited (\(code))"
        case .signal(let signal): "killed (signal \(signal))"
        case .unknown: "ended"
        }
    }
}

/// The configuration a terminal is launched with.
///
/// Pure, and separate from the view for the same reason ``SplitLayout`` is:
/// "the shell follows the note you are editing" and "a deleted folder falls
/// back rather than failing to launch" are then tested properties of a value,
/// not behaviour that needs a running pty to observe.
public struct TerminalSession: Sendable, Equatable {
    /// Absolute path of the shell binary.
    public let shell: String
    /// Directory the shell starts in.
    public let workingDirectory: String
    /// Passed as `argv[0]`. A leading dash is how a Unix shell is told it is a
    /// *login* shell, which is what makes it read the profile that puts the
    /// user's own tools on `PATH` — without it, a coding CLI installed by
    /// Homebrew or a version manager is simply not found.
    public let argv0: String
    /// A line typed into the shell once it has started, or `nil`.
    ///
    /// Typed rather than passed as `-c`, and that is the whole reason it is a
    /// separate field instead of arguments on the launch: `zsh -c "manvi"` is
    /// not a login shell and not an interactive one, so it neither reads the
    /// profile that puts the tool on `PATH` nor leaves anything behind when
    /// the command exits. Sent into an interactive login shell instead, the
    /// command appears in the scrollback where the reader can see and re-run
    /// it, and the shell survives it.
    public let initialCommand: String?

    public init(
        shell: String,
        workingDirectory: String,
        argv0: String,
        initialCommand: String? = nil
    ) {
        self.shell = shell
        self.workingDirectory = workingDirectory
        self.argv0 = argv0
        self.initialCommand = initialCommand
    }

    /// The shell to launch.
    ///
    /// `$SHELL` first — running someone's chosen shell is the difference
    /// between a terminal they can use and a curiosity. It is verified to
    /// exist and be executable before being trusted: an environment inherited
    /// from a stale login session can name a shell that has since been
    /// uninstalled, and launching that yields a drawer that opens empty with
    /// no explanation.
    public static func resolveShell(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String {
        let fallback = "/bin/zsh"
        guard let preferred = environment["SHELL"], preferred.hasPrefix("/"),
            fileManager.isExecutableFile(atPath: preferred)
        else {
            return fileManager.isExecutableFile(atPath: fallback) ? fallback : "/bin/sh"
        }
        return preferred
    }

    /// Where the shell should start.
    ///
    /// The document's own folder first, so a CLI run from the drawer acts on
    /// the note in front of the reader; then the vault; then home. Each
    /// candidate is checked to be an existing *directory* — an unsaved
    /// document has no folder, and a vault can be renamed out from under the
    /// window while it is open.
    public static func resolveWorkingDirectory(
        document: URL?,
        vault: URL?,
        fileManager: FileManager = .default
    ) -> String {
        let candidates = [
            document?.deletingLastPathComponent(),
            vault,
            URL(fileURLWithPath: NSHomeDirectory()),
        ]
        for candidate in candidates.compactMap({ $0 }) {
            let path = candidate.standardizedFileURL.path
            if isUsableDirectory(path, fileManager: fileManager) { return path }
        }
        return NSHomeDirectory()
    }

    /// Whether a shell could actually start in `path`.
    ///
    /// Existence is not enough. A path can be a file, and a directory can be
    /// unreadable or lack the execute bit that makes it enterable — a shell
    /// launched into one of those either fails to start or lands somewhere the
    /// reader did not ask for, with no message either way.
    static func isUsableDirectory(
        _ path: String, fileManager: FileManager = .default
    ) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return false }
        // `isExecutableFile` is the search permission for a directory.
        return fileManager.isReadableFile(atPath: path)
            && fileManager.isExecutableFile(atPath: path)
    }

    /// The same session, re-checked against the filesystem as it is now.
    ///
    /// A session's directory is fixed when its tab is opened, but the tab can
    /// outlive the folder: a vault gets renamed, a worktree is removed, an
    /// external volume is ejected. Launching into a directory that has since
    /// gone fails inside the shell, where the reader can neither see the cause
    /// nor act on it. Re-resolving at launch turns that into starting at home.
    public func revalidated(fileManager: FileManager = .default) -> TerminalSession {
        let shell =
            fileManager.isExecutableFile(atPath: shell)
            ? shell : Self.resolveShell(fileManager: fileManager)
        let directory =
            Self.isUsableDirectory(workingDirectory, fileManager: fileManager)
            ? workingDirectory : NSHomeDirectory()

        guard shell != self.shell || directory != workingDirectory else { return self }
        return TerminalSession(
            shell: shell,
            workingDirectory: directory,
            argv0: "-" + (shell as NSString).lastPathComponent,
            initialCommand: initialCommand)
    }

    /// The session for a given document and vault.
    public static func resolve(
        document: URL?,
        vault: URL?,
        initialCommand: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> TerminalSession {
        let shell = resolveShell(environment: environment, fileManager: fileManager)
        return TerminalSession(
            shell: shell,
            workingDirectory: resolveWorkingDirectory(
                document: document, vault: vault, fileManager: fileManager),
            argv0: "-" + (shell as NSString).lastPathComponent,
            initialCommand: initialCommand
        )
    }
}
