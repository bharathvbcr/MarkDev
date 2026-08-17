//
//  MarkDevApp.swift
//  MarkDev
//

import MarkDevKit
import SwiftUI

@main
struct MarkDevApp: App {
    @NSApplicationDelegateAdaptor(MarkDevApplicationDelegate.self)
    private var applicationDelegate

    init() {
        // A stale libmarkdev.a would misread struct layouts and produce
        // subtly wrong text ranges. Fail at launch instead.
        MarkDevCore.verifyABI()
    }

    var body: some Scene {
        WindowGroup {
            WorkspaceView()
                .frame(
                    minWidth: GlassTheme.minimumTwoPaneWindowWidth,
                    minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .commands { WorkspaceCommands() }
    }
}
