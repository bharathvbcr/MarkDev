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

    /// Opens a workspace window when a file arrives with nowhere to show it.
    ///
    /// A Mac app keeps running with every window closed, and Launch Services
    /// goes on delivering double-clicked documents to it. Without a way to ask
    /// for a window, those files are queued for a surface that will never come
    /// — which is the app bouncing in the Dock and showing nothing.
    @Environment(\.openWindow) private var openWindow

    /// Identifies the one window group, so a window can be asked for by name.
    static let workspaceWindowID = "workspace"

    init() {
        // A stale libmarkdev.a would misread struct layouts and produce
        // subtly wrong text ranges. Fail at launch instead.
        MarkDevCore.verifyABI()
    }

    var body: some Scene {
        WindowGroup(id: Self.workspaceWindowID) {
            WorkspaceView()
                .frame(
                    minWidth: GlassTheme.minimumTwoPaneWindowWidth,
                    minHeight: 640)
                // Installed from a view because the action is only usable once
                // the scene exists. Every workspace sets the same closure, so
                // which one ran last does not matter.
                .onAppear {
                    DocumentInbox.shared.windowProvider = openWorkspaceWindow
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands { WorkspaceCommands() }
    }

    private func openWorkspaceWindow() {
        openWindow(id: Self.workspaceWindowID)
    }
}
