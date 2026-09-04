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
            "MarkDev requests MANVI’s strict posture and only offers its answer for review. "
                + "MANVI is an external executable, not a sandbox, so only use a binary you trust."
        case .editing:
            "MANVI may run commands and change any files your macOS account can access without "
                + "asking. The working folder is context, not a security boundary."
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
        didSet {
            persist(binaryPath, forKey: Keys.binaryPath)
            guard Self.normalized(binaryPath) != Self.normalized(oldValue) else { return }
            boundExecutableFingerprint = nil
            clearEditingConsent()
            clearRemoteConsent()
            binarySelectionDidChange?()
        }
    }
    /// `llm.local.base_url`. Empty leaves MANVI's own value alone.
    public var serverURL: String {
        didSet {
            if let normalized = Self.endpointContext(for: serverURL).normalizedValue {
                persist(normalized, forKey: Keys.serverURL)
            } else {
                defaults.removeObject(forKey: Keys.serverURL)
            }
            if Self.remoteContextFingerprint(
                serverURL: serverURL, useLocalProvider: useLocalProvider)
                != Self.remoteContextFingerprint(
                    serverURL: oldValue, useLocalProvider: useLocalProvider)
            {
                clearRemoteConsent()
            }
        }
    }
    /// `llm.local.model`. Empty leaves MANVI's own value alone.
    public var model: String {
        didSet {
            if let normalized = Self.normalizedModel(model) {
                persist(normalized, forKey: Keys.model)
            } else {
                defaults.removeObject(forKey: Keys.model)
            }
        }
    }
    /// Whether to force the local provider. On by default: the whole point of
    /// running MANVI from here is the model on this machine.
    public var useLocalProvider: Bool {
        didSet {
            persist(useLocalProvider, forKey: Keys.useLocalProvider)
            if Self.remoteContextFingerprint(
                serverURL: serverURL, useLocalProvider: useLocalProvider)
                != Self.remoteContextFingerprint(
                    serverURL: serverURL, useLocalProvider: oldValue)
            {
                clearRemoteConsent()
            }
        }
    }
    public var authority: HarnessAuthority {
        didSet {
            persist(authority.rawValue, forKey: Keys.authority)
            if authority != oldValue { clearEditingConsent() }
        }
    }
    /// A separate acknowledgement for MANVI's editing posture. Selecting the
    /// posture describes the desired capability; this flag confirms that the
    /// reader accepts its machine-wide implications for the current setting.
    public var allowEditing: Bool {
        get {
            guard authority == .editing, let current = boundExecutableFingerprint else {
                return false
            }
            return editingConsentFingerprint == current
        }
        set {
            guard newValue, authority == .editing,
                let current = boundExecutableFingerprint
            else {
                clearEditingConsent()
                return
            }
            editingConsentFingerprint = current
            defaults.set(current, forKey: Keys.editingConsentFingerprint)
        }
    }
    /// Consent to send note content to the currently configured non-loopback
    /// provider. Changing either the endpoint or provider mode revokes it.
    public var allowRemoteServer: Bool {
        get {
            guard let current = remoteAuthorizationFingerprint else { return false }
            return remoteConsentFingerprint == current
        }
        set {
            guard newValue, let current = remoteAuthorizationFingerprint else {
                clearRemoteConsent()
                return
            }
            remoteConsentFingerprint = current
            defaults.set(current, forKey: Keys.remoteConsentFingerprint)
        }
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
        static let legacyAllowEditing = "harness.allowEditing"
        static let legacyAllowRemoteServer = "harness.allowRemoteServer"
        static let editingConsentFingerprint = "harness.editingConsentFingerprint.v1"
        static let legacyRemoteConsentFingerprint = "harness.remoteConsentFingerprint.v1"
        static let remoteConsentFingerprint = "harness.remoteConsentFingerprint.v2"
        static let maxSteps = "harness.maxSteps"
        static let timeoutMinutes = "harness.timeoutMinutes"
    }

    private let defaults: UserDefaults
    private let diagnostics: DiagnosticsEmitter
    private var editingConsentFingerprint: String?
    private var remoteConsentFingerprint: String?
    private var boundExecutableFingerprint: String?
    @ObservationIgnored var binarySelectionDidChange: (() -> Void)?

    public init(
        defaults: UserDefaults = .standard,
        diagnostics: DiagnosticsEmitter = .shared
    ) {
        self.defaults = defaults
        self.diagnostics = diagnostics
        let persistedServerURL = defaults.string(forKey: Keys.serverURL) ?? ""
        let persistedModel = defaults.string(forKey: Keys.model) ?? ""
        binaryPath = defaults.string(forKey: Keys.binaryPath) ?? ""
        serverURL = Self.endpointContext(for: persistedServerURL).normalizedValue ?? ""
        model = Self.normalizedModel(persistedModel) ?? ""
        useLocalProvider = defaults.object(forKey: Keys.useLocalProvider) as? Bool ?? true
        authority =
            HarnessAuthority(rawValue: defaults.string(forKey: Keys.authority) ?? "")
            ?? .advisory
        editingConsentFingerprint = defaults.string(forKey: Keys.editingConsentFingerprint)
        remoteConsentFingerprint = defaults.string(forKey: Keys.remoteConsentFingerprint)
        boundExecutableFingerprint = nil
        // Clamped on the way out as well as in, so a hand-edited preference
        // cannot ask for a run that never ends.
        maxSteps = Self.clampSteps(defaults.object(forKey: Keys.maxSteps) as? Int ?? 24)
        timeoutMinutes = Self.clampMinutes(
            defaults.object(forKey: Keys.timeoutMinutes) as? Int ?? 10)
        // Context-free booleans from older builds cannot prove what executable
        // or endpoint was accepted. They deliberately do not migrate.
        defaults.removeObject(forKey: Keys.legacyAllowEditing)
        defaults.removeObject(forKey: Keys.legacyAllowRemoteServer)
        defaults.removeObject(forKey: Keys.legacyRemoteConsentFingerprint)
        if serverURL != persistedServerURL {
            if serverURL.isEmpty {
                defaults.removeObject(forKey: Keys.serverURL)
            } else {
                defaults.set(serverURL, forKey: Keys.serverURL)
            }
        }
        if model != persistedModel {
            if model.isEmpty {
                defaults.removeObject(forKey: Keys.model)
            } else {
                defaults.set(model, forKey: Keys.model)
            }
        }
    }

    /// Binds the editing acknowledgement to the executable discovery currently
    /// shown by the assistant. A different binary invalidates the old grant;
    /// temporarily unbinding during a refresh merely makes it unavailable.
    func bindExecutable(_ location: HarnessLocation?) {
        guard let location, location.matches(configured: binaryPath) else {
            boundExecutableFingerprint = nil
            return
        }
        let current = location.editingConsentFingerprint
        boundExecutableFingerprint = current
        if let stored = editingConsentFingerprint, stored != current {
            clearEditingConsent()
        }
        if let stored = remoteConsentFingerprint,
            stored != remoteAuthorizationFingerprint
        {
            clearRemoteConsent()
        }
    }

    func revokeExecutableConsent() {
        // Emitted here rather than at the three call sites, so a fourth cannot
        // withdraw consent without leaving a trace. Nothing identifying goes
        // with it: the fingerprint is a digest of a private path's contents,
        // and the diagnostics payload vocabulary deliberately has nowhere to
        // put a free string.
        let hadConsent = boundExecutableFingerprint != nil
        boundExecutableFingerprint = nil
        clearEditingConsent()
        clearRemoteConsent()
        guard hadConsent else { return }
        diagnostics.emit(
            severity: .warning,
            subsystem: .permissions,
            code: .permissionsHarnessExecutableRevoked,
            operationID: DiagnosticOperationID())
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
    static let maximumServerURLBytes = 2 * 1_024
    static let maximumModelBytes = 256

    static func clampSteps(_ value: Int) -> Int {
        min(max(value, stepRange.lowerBound), stepRange.upperBound)
    }
    static func clampMinutes(_ value: Int) -> Int {
        min(max(value, minuteRange.lowerBound), minuteRange.upperBound)
    }

    /// Why a run cannot begin with the current authority and provider choices.
    ///
    /// The checks live here rather than in the view so keyboard submission and
    /// future callers cannot bypass the same boundary. An empty URL delegates
    /// endpoint selection to MANVI, but only while MarkDev is forcing MANVI's
    /// local provider.
    public var runBlocker: String? {
        guard Self.normalizedModel(model) != nil else {
            return "Enter a valid MANVI model name within 256 bytes and without control characters."
        }

        let endpoint = endpointPolicy
        switch endpoint {
        case .remoteInsecure:
            return "Remote MANVI servers must use HTTPS."
        case .invalid:
            return "Enter a valid HTTP or HTTPS MANVI base URL without credentials or a query."
        case .inherited, .loopback, .remoteSecure:
            break
        }

        if authority == .editing, !allowEditing {
            return "Confirm that MANVI may run commands and edit files before starting."
        }

        switch endpoint {
        case .inherited:
            if !allowRemoteServer {
                return "Confirm that this note may be sent to MANVI’s configured provider."
            }
        case .loopback:
            if !useLocalProvider, !allowRemoteServer {
                return "Confirm that this note may be sent to MANVI’s configured provider."
            }
        case .remoteSecure:
            if !allowRemoteServer {
                return "Confirm that this note may be sent to the remote MANVI server."
            }
        case .remoteInsecure, .invalid:
            preconditionFailure("invalid endpoint policies returned before consent checks")
        }
        return nil
    }

    /// Whether the settings UI should present the remote-content consent.
    public var requiresRemoteServerConsent: Bool {
        remoteAuthorizationFingerprint != nil
    }

    private enum EndpointPolicy {
        case inherited
        case loopback
        case remoteSecure
        case remoteInsecure
        case invalid
    }

    private struct EndpointContext {
        let policy: EndpointPolicy
        /// Empty means intentionally inherited; nil means structurally invalid.
        let normalizedValue: String?
    }

    private var endpointPolicy: EndpointPolicy {
        Self.endpointContext(for: serverURL).policy
    }

    private static func endpointContext(for rawValue: String) -> EndpointContext {
        guard let value = boundedNormalized(rawValue, maximumBytes: maximumServerURLBytes) else {
            return EndpointContext(policy: .invalid, normalizedValue: nil)
        }
        guard !value.isEmpty else {
            return EndpointContext(policy: .inherited, normalizedValue: "")
        }
        guard let schemeDelimiter = value.range(of: "://") else {
            return EndpointContext(policy: .invalid, normalizedValue: nil)
        }
        let authorityTail = value[schemeDelimiter.upperBound...]
        let authorityEnd = authorityTail.firstIndex { character in
            character == "/" || character == "?" || character == "#"
        } ?? value.endIndex
        let rawAuthority = value[schemeDelimiter.upperBound..<authorityEnd]
        guard !rawAuthority.isEmpty,
            rawAuthority.utf8.allSatisfy(Self.isCanonicalAuthorityByte)
        else { return EndpointContext(policy: .invalid, normalizedValue: nil) }
        guard
            let components = URLComponents(string: value),
            components.url != nil,
            components.user == nil,
            components.password == nil,
            components.fragment == nil,
            components.query == nil,
            let rawScheme = components.scheme,
            let rawHost = components.host,
            !rawHost.isEmpty
        else { return EndpointContext(policy: .invalid, normalizedValue: nil) }

        let scheme = rawScheme.lowercased()
        guard scheme == "http" || scheme == "https" else {
            return EndpointContext(policy: .invalid, normalizedValue: nil)
        }
        if let port = components.port, !(1...65_535).contains(port) {
            return EndpointContext(policy: .invalid, normalizedValue: nil)
        }
        let rawLowercaseHost = rawHost.lowercased()
        let host =
            rawLowercaseHost.hasPrefix("[") && rawLowercaseHost.hasSuffix("]")
            ? String(rawLowercaseHost.dropFirst().dropLast()) : rawLowercaseHost
        let loopback =
            host == "localhost" || host.hasSuffix(".localhost") || host == "::1"
            || Self.isCanonicalIPv4Loopback(host)
        let policy: EndpointPolicy
        if loopback {
            policy = .loopback
        } else {
            policy = scheme == "https" ? .remoteSecure : .remoteInsecure
        }
        return EndpointContext(policy: policy, normalizedValue: value)
    }

    private static func isCanonicalAuthorityByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 48...57, 65...90, 97...122, 45, 46, 58, 91, 93:
            return true
        default:
            return false
        }
    }

    /// The environment a run is launched with.
    ///
    /// Only ordinary process-discovery and locale values are inherited. GUI
    /// launchers often carry cloud keys, agent sockets, signing credentials,
    /// and dynamic-loader variables; forwarding all of them to a configurable
    /// executable would silently grant it unrelated authority.
    public func environment(
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        let exactAllowlist: Set<String> = [
            "HOME", "PATH", "TMPDIR", "SHELL", "USER", "LOGNAME", "LANG", "TERM",
            "LC_ALL", "LC_COLLATE", "LC_CTYPE", "LC_MESSAGES", "LC_MONETARY", "LC_NUMERIC",
            "LC_TIME",
        ]
        var environment = base.filter { key, _ in exactAllowlist.contains(key) }
        if useLocalProvider { environment["MANVI_LLM_PROVIDER_DEFAULT"] = "local" }
        if let url = Self.endpointContext(for: serverURL).normalizedValue, !url.isEmpty {
            environment["MANVI_LLM_LOCAL_BASE_URL"] = url
        }
        if let name = Self.normalizedModel(model), !name.isEmpty {
            environment["MANVI_LLM_LOCAL_MODEL"] = name
        }
        environment["MANVI_HARNESS_POSTURE"] = authority.posture
        return environment
    }

    private func persist(_ value: Any, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    private var remoteAuthorizationFingerprint: String? {
        guard let executable = boundExecutableFingerprint else { return nil }
        let context = Self.endpointContext(for: serverURL)
        switch context.policy {
        case .invalid, .remoteInsecure:
            return nil
        case .loopback where useLocalProvider:
            return nil
        case .inherited, .loopback, .remoteSecure:
            return Self.remoteContextFingerprint(
                serverURL: context.normalizedValue ?? "",
                useLocalProvider: useLocalProvider,
                executableFingerprint: executable)
        }
    }

    private static func remoteContextFingerprint(
        serverURL: String,
        useLocalProvider: Bool,
        executableFingerprint: String? = nil
    ) -> String {
        let context = endpointContext(for: serverURL)
        let endpoint: String
        if let value = context.normalizedValue {
            endpoint = value.isEmpty ? "inherited" : value
        } else {
            endpoint = "invalid"
        }
        return HarnessLocator.stableFingerprint([
            "markdev.harness.remote-consent.v2",
            endpoint,
            useLocalProvider ? "forced-local" : "provider-inherited",
            executableFingerprint ?? "unbound",
        ])
    }

    private static func normalizedModel(_ value: String) -> String? {
        boundedNormalized(value, maximumBytes: maximumModelBytes)
    }

    /// Bounds before trimming so hostile values cannot force an unbounded copy.
    /// A small allowance preserves the UI's historical edge-whitespace cleanup.
    private static func boundedNormalized(_ value: String, maximumBytes: Int) -> String? {
        let rawLimit = maximumBytes + 256
        guard value.utf8.prefix(rawLimit + 1).count <= rawLimit else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.utf8.prefix(maximumBytes + 1).count <= maximumBytes,
            normalized.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
            })
        else { return nil }
        return normalized
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isCanonicalIPv4Loopback(_ host: String) -> Bool {
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        var values: [Int] = []
        values.reserveCapacity(4)
        for octet in octets {
            guard !octet.isEmpty,
                octet.utf8.allSatisfy({ (48...57).contains(Int($0)) }),
                octet.count == 1 || octet.first != "0",
                let value = Int(octet),
                (0...255).contains(value)
            else { return false }
            values.append(value)
        }
        return values[0] == 127
    }

    private func clearEditingConsent() {
        editingConsentFingerprint = nil
        defaults.removeObject(forKey: Keys.editingConsentFingerprint)
    }

    private func clearRemoteConsent() {
        remoteConsentFingerprint = nil
        defaults.removeObject(forKey: Keys.remoteConsentFingerprint)
    }
}
