//
//  HarnessLocator.swift
//  MarkDevKit
//
//  Finding the `manvi` binary from inside a GUI app.
//

import Foundation

/// Where MANVI is, and how that was decided.
public struct HarnessLocation: Sendable, Equatable {
    public let url: URL
    /// How it was found, for the settings panel to say.
    public let origin: Origin

    public enum Origin: String, Sendable, Equatable {
        /// A path the reader set.
        case configured
        /// Found on the `PATH` this process inherited.
        case processPath
        /// Found in one of the directories tools are conventionally installed
        /// in.
        case conventional
        /// Found by asking a login shell, which is the only way to see a
        /// `PATH` set by a version manager.
        case loginShell
    }

    public var summary: String {
        switch origin {
        case .configured: "Set in MarkDev"
        case .processPath: "Found on PATH"
        case .conventional: "Found in \(url.deletingLastPathComponent().path)"
        case .loginShell: "Found by your login shell"
        }
    }
}

/// Finds the harness binary.
///
/// # Why this is more than `which`
///
/// A GUI app launched from Finder does not inherit the `PATH` a terminal has.
/// It gets the short system one, so a tool installed by Homebrew, mise, nvm, or
/// `go install` is simply not there — the same fact that makes MarkDev's
/// terminal launch a *login* shell rather than a plain one. Looking only at
/// `ProcessInfo`'s `PATH` therefore reports "MANVI is not installed" on a
/// machine where it plainly is, which is a wrong answer rather than a missing
/// one.
///
/// So the search widens in three steps, cheapest first, and every result
/// records which step found it — because "MarkDev cannot find manvi" and
/// "MarkDev found a different manvi than your shell does" are different
/// problems with different fixes, and only the origin can tell them apart.
public enum HarnessLocator {
    /// The tool's name on disk.
    public static let binaryName = "manvi"

    /// Directories a command-line tool is conventionally installed in.
    ///
    /// Absolute and few. This is not an attempt to guess where somebody keeps
    /// their source tree — a path nobody chose is a path nobody can debug —
    /// only the standard destinations of the installers that put things on a
    /// shell's `PATH` in the first place.
    static func conventionalDirectories(home: String = NSHomeDirectory()) -> [String] {
        [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/go/bin",
            "\(home)/.local/bin",
            "\(home)/bin",
        ]
    }

    /// Looks for the binary without running anything.
    ///
    /// - Parameter configured: a path the reader set, which wins when it is
    ///   usable and is *not* silently ignored when it is not — a path somebody
    ///   typed is a statement, and quietly searching past a broken one hides
    ///   the typo behind whatever else happens to be installed.
    public static func locateSynchronously(
        configured: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> HarnessLocation? {
        if let configured, !configured.trimmingCharacters(in: .whitespaces).isEmpty {
            let path = (configured as NSString).expandingTildeInPath
            guard fileManager.isExecutableFile(atPath: path) else { return nil }
            return HarnessLocation(url: URL(fileURLWithPath: path), origin: .configured)
        }

        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let path = (String(directory) as NSString).appendingPathComponent(binaryName)
            if fileManager.isExecutableFile(atPath: path) {
                return HarnessLocation(url: URL(fileURLWithPath: path), origin: .processPath)
            }
        }

        for directory in conventionalDirectories() {
            let path = (directory as NSString).appendingPathComponent(binaryName)
            if fileManager.isExecutableFile(atPath: path) {
                return HarnessLocation(url: URL(fileURLWithPath: path), origin: .conventional)
            }
        }
        return nil
    }

    /// The full search, ending with a login shell.
    ///
    /// The shell step costs a fork and is therefore last, and is skipped
    /// entirely when a cheaper step already answered. It is bounded: a login
    /// shell runs the reader's profile, and a profile that blocks — waiting on
    /// a network mount, on a prompt — would otherwise hang whatever asked.
    public static func locate(
        configured: String?,
        timeout: TimeInterval = 5
    ) async -> HarnessLocation? {
        if let found = locateSynchronously(configured: configured) { return found }
        // A configured path that does not resolve is a mistake to report, not
        // a reason to go looking elsewhere.
        if let configured, !configured.trimmingCharacters(in: .whitespaces).isEmpty { return nil }

        guard let path = await loginShellPath(timeout: timeout) else { return nil }
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return HarnessLocation(url: URL(fileURLWithPath: path), origin: .loginShell)
    }

    /// Asks a login shell where the binary is.
    private static func loginShellPath(timeout: TimeInterval) async -> String? {
        let shell = TerminalSession.resolveShell()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // `-l` reads the profile — the whole reason for going to a shell at
        // all. `command -v` is the POSIX spelling and, unlike `which`, is not
        // a separate binary that may itself be missing.
        process.arguments = ["-l", "-c", "command -v \(binaryName)"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning {
            process.terminate()
            return nil
        }

        let data = (try? output.fileHandleForReading.readToEnd()) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A profile that prints a banner leaves several lines here; the answer
        // is the last one, and only if it is an absolute path.
        guard let last = text.split(separator: "\n").last.map(String.init),
            last.hasPrefix("/")
        else { return nil }
        return last
    }
}
