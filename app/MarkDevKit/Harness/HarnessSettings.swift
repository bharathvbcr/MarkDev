//
//  HarnessSettings.swift
//  MarkDevKit
//
//  What MarkDev tells MANVI about which model to use, and how far to go.
//

import Foundation
import Observation

/// How much of the machine a run may touch.
///
/// Two values, and the difference between them is not a slider — it is which
/// of MANVI's postures the run is launched under, which decides whether the
/// write gate lets a file through.
public enum HarnessAuthority: String, CaseIterable, Sendable {
    /// Reads the vault and answers. Writes and shell commands are refused by
    /// the harness itself.
    ///
    /// Launched as `harness.posture=strict` with no task checked out, so every
    /// file write hits MANVI's `task.absent` rung — a *soft* rule, which dev
    /// posture would demote to an allow and strict refuses outright. Verified
    /// against the harness rather than assumed: a run asked to append a line
    /// came back `deny … rule task.absent`, and the run report counted the
    /// refusal.
    case advisory
    /// The harness's own default posture, where an unplanned write is recorded
    /// and allowed.
    ///
    /// Offered because it is what the terminal gets, and refusing to name it
    /// here would only mean pretending MarkDev does not know about it. It is
    /// not the default and the panel says what it means before it is used.
    case editing

    public var title: String {
        switch self {
        case .advisory: "Advisory"
        case .editing: "Can edit files"
        }
    }

    /// The `harness.posture` this maps to.
    public var posture: String {
        switch self {
        case .advisory: "strict"
        case .editing: "dev"
        }
    }

    public var explanation: String {
        switch self {
        case .advisory:
            "MANVI reads your vault and answers. It cannot write files or run commands — you "
                + "apply what it suggests."
        case .editing:
            "MANVI may write files in the folder it is run from, without asking. Your open "
                + "document is reloaded from disk when it changes."
        }
    }
}

/// Where MANVI is and what it should run against.
///
/// # Why MarkDev holds these at all
///
/// MANVI reads its own configuration — `.devcouncil/config.yaml` next to
/// wherever it was started, plus `MANVI_*` in the environment — and for a
/// terminal that is exactly right: the reader is in a directory, and the
/// harness's own rules apply. It is not right for a run MarkDev starts, for
/// two reasons found by running it.
///
/// The first is that the working directory is the *note's* folder, which is
/// almost never a project with a harness config in it, so a run there inherits
/// nothing. The second is sharper: the defaults are not a working setup. On
/// this machine `llm.local.base_url` defaults to port 8000 while the server
/// actually serving the configured model is on 11434, and the run failed with
/// a refusal naming thirteen models on the wrong server. So MarkDev states the
/// address and the model rather than hoping.
///
/// Every field left empty is left to MANVI, which is what makes this a set of
/// overrides rather than a second configuration system: a reader whose harness
/// is already configured for the vault can clear all three and nothing here
/// will contradict it.
@MainActor
@Observable
public final class HarnessSettings {
    /// Path to the binary. Empty means "find it" — see ``HarnessLocator``.
    public var binaryPath: String {
        didSet { persist(binaryPath, forKey: Keys.binaryPath) }
    }
    /// `llm.local.base_url`. Empty leaves MANVI's own value alone.
    public var serverURL: String {
        didSet { persist(serverURL, forKey: Keys.serverURL) }
    }
    /// `llm.local.model`. Empty leaves MANVI's own value alone.
    public var model: String {
        didSet { persist(model, forKey: Keys.model) }
    }
    /// Whether to force the local provider. On by default: the whole point of
    /// running MANVI from here is the model on this machine.
    public var useLocalProvider: Bool {
        didSet { persist(useLocalProvider, forKey: Keys.useLocalProvider) }
    }
    public var authority: HarnessAuthority {
        didSet { persist(authority.rawValue, forKey: Keys.authority) }
    }
    /// Step ceiling for one run.
    public var maxSteps: Int {
        didSet { persist(maxSteps, forKey: Keys.maxSteps) }
    }
    /// Wall-clock bound, in minutes.
    public var timeoutMinutes: Int {
        didSet { persist(timeoutMinutes, forKey: Keys.timeoutMinutes) }
    }

    private enum Keys {
        static let binaryPath = "harness.binaryPath"
        static let serverURL = "harness.serverURL"
        static let model = "harness.model"
        static let useLocalProvider = "harness.useLocalProvider"
        static let authority = "harness.authority"
        static let maxSteps = "harness.maxSteps"
        static let timeoutMinutes = "harness.timeoutMinutes"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        binaryPath = defaults.string(forKey: Keys.binaryPath) ?? ""
        serverURL = defaults.string(forKey: Keys.serverURL) ?? ""
        model = defaults.string(forKey: Keys.model) ?? ""
        useLocalProvider = defaults.object(forKey: Keys.useLocalProvider) as? Bool ?? true
        authority =
            HarnessAuthority(rawValue: defaults.string(forKey: Keys.authority) ?? "")
            ?? .advisory
        // Clamped on the way out as well as in, so a hand-edited preference
        // cannot ask for a run that never ends.
        maxSteps = Self.clampSteps(defaults.object(forKey: Keys.maxSteps) as? Int ?? 24)
        timeoutMinutes = Self.clampMinutes(
            defaults.object(forKey: Keys.timeoutMinutes) as? Int ?? 10)
    }

    /// Bounds on a single run.
    ///
    /// Both are ceilings on something that costs the reader real time on a
    /// local 27B — a step is a model round trip, measured here at roughly a
    /// minute each cold. They are generous rather than tight, and they exist so
    /// that a request the model misunderstands ends rather than running until
    /// somebody notices.
    public static let stepRange = 1...200
    public static let minuteRange = 1...120

    static func clampSteps(_ value: Int) -> Int {
        min(max(value, stepRange.lowerBound), stepRange.upperBound)
    }
    static func clampMinutes(_ value: Int) -> Int {
        min(max(value, minuteRange.lowerBound), minuteRange.upperBound)
    }

    /// The environment a run is launched with.
    ///
    /// Built on top of the process environment rather than replacing it: the
    /// harness needs `HOME` to find its state directory, and `PATH` to reach
    /// the Rust sidecars it forks.
    public func environment(
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base
        if useLocalProvider { environment["MANVI_LLM_PROVIDER_DEFAULT"] = "local" }
        let url = serverURL.trimmingCharacters(in: .whitespaces)
        if !url.isEmpty { environment["MANVI_LLM_LOCAL_BASE_URL"] = url }
        let name = model.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { environment["MANVI_LLM_LOCAL_MODEL"] = name }
        environment["MANVI_HARNESS_POSTURE"] = authority.posture
        return environment
    }

    private func persist(_ value: Any, forKey key: String) {
        defaults.set(value, forKey: key)
    }
}
