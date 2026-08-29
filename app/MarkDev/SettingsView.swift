//
//  SettingsView.swift
//  MarkDev
//
//  Application Preferences and Settings window.
//

import AppKit
import MarkDevKit
import SwiftUI

public struct SettingsView: View {
    @AppStorage("markdev.themePreset") private var themePreset: String = "standard"
    @AppStorage("markdev.appearanceOverride") private var appearanceOverride: String = "system"
    @AppStorage("markdev.defaultMode") private var defaultMode: String = "livePreview"

    public init() {}

    public var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            editorTab
                .tabItem {
                    Label("Editor", systemImage: "text.cursor")
                }

            shortcutsTab
                .tabItem {
                    Label("Shortcuts", systemImage: "keyboard")
                }
        }
        .frame(width: 480, height: 320)
        .padding()
    }

    private var generalTab: some View {
        Form {
            Section("Appearance") {
                Picker("Theme Style", selection: $appearanceOverride) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                .onChange(of: appearanceOverride) { _, newValue in
                    switch newValue {
                    case "light":
                        NSApp.appearance = NSAppearance(named: .aqua)
                    case "dark":
                        NSApp.appearance = NSAppearance(named: .darkAqua)
                    default:
                        NSApp.appearance = nil
                    }
                }

                Text("Controls whether the application follows system appearance or forces light/dark mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var editorTab: some View {
        Form {
            Section("Typography & Theme") {
                Picker("Font Preset", selection: $themePreset) {
                    Text("Standard (San Francisco)").tag("standard")
                    Text("Serif (Georgia)").tag("serif")
                    Text("Monospace (SF Mono)").tag("mono")
                }

                Picker("Default View Mode", selection: $defaultMode) {
                    Text("Live Preview").tag("livePreview")
                    Text("Reading").tag("reading")
                    Text("Source").tag("source")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var shortcutsTab: some View {
        List {
            shortcutRow("Command Palette", "⌘K")
            shortcutRow("New Document", "⌘N")
            shortcutRow("Open File / Vault", "⌘O / ⇧⌘O")
            shortcutRow("Save / Save As", "⌘S / ⇧⌘S")
            shortcutRow("Export HTML / Print", "Menu / ⌘P")
            shortcutRow("Zoom In / Out / Reset", "⌘+ / ⌘- / ⌘0")
            shortcutRow("Toggle Sidebar / Terminal", "⌘\\ / ⌘J")
            shortcutRow("Toggle Inspector / Graph", "⌥⌘I / ⇧⌘G")
            shortcutRow("Split Right / Down", "Menu")
            shortcutRow("Switch Panes / Tabs", "⌥⌘← / ⌥⌘→ / ⌘1–9")
        }
        .listStyle(.inset)
    }

    private func shortcutRow(_ description: String, _ key: String) -> some View {
        HStack {
            Text(description)
            Spacer()
            Text(key)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}
