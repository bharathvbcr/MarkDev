//
//  DiagnosticsLifecycle.swift
//  MarkDevKit
//
//  Typed lifecycle events whose call sites must not accept arbitrary payloads.
//

public extension DiagnosticsCenter {
    /// Called only after the native core ABI precondition returns successfully.
    /// There is deliberately no metadata parameter: launch diagnostics must not
    /// become a shortcut for capturing arguments, environment, or paths.
    func recordVerifiedABILaunch() async {
        await record(
            severity: .notice,
            subsystem: .app,
            code: .appLaunchABIVerified)
    }
}
