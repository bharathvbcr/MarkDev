//
//  SettingsView.swift
//  MarkDev
//
//  Application Preferences and Settings window.
//

import AppKit
import MarkDevKit
import SwiftUI
import UniformTypeIdentifiers

public struct SettingsView: View {
    @AppStorage(EditorPreferences.Key.themePreset)
    private var themePreset: EditorPreferences.ThemePreset = EditorPreferences.defaultThemePreset
    @AppStorage(EditorPreferences.Key.appearance)
    private var appearanceOverride: EditorPreferences.Appearance = EditorPreferences.defaultAppearance
    @AppStorage(EditorPreferences.Key.mode)
    private var defaultMode: EditorMode = EditorPreferences.defaultMode
    @State private var diagnosticsModel = DiagnosticsSettingsModel()

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

            diagnosticsTab
                .tabItem {
                    Label("Support", systemImage: "stethoscope")
                }
        }
        .frame(width: 480, height: 360)
        .padding()
    }

    private var generalTab: some View {
        Form {
            Section("Appearance") {
                Picker("Theme Style", selection: $appearanceOverride) {
                    Text("System").tag(EditorPreferences.Appearance.system)
                    Text("Light").tag(EditorPreferences.Appearance.light)
                    Text("Dark").tag(EditorPreferences.Appearance.dark)
                }
                .pickerStyle(.segmented)
                .onChange(of: appearanceOverride) { _, newValue in
                    newValue.apply(to: NSApp)
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
                    Text("Standard (San Francisco)").tag(EditorPreferences.ThemePreset.standard)
                    Text("Serif (Georgia)").tag(EditorPreferences.ThemePreset.serif)
                    Text("Monospace (SF Mono)").tag(EditorPreferences.ThemePreset.mono)
                }

                Picker("Default View Mode", selection: $defaultMode) {
                    Text("Live Preview").tag(EditorMode.livePreview)
                    Text("Reading").tag(EditorMode.reading)
                    Text("Source").tag(EditorMode.source)
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
            shortcutRow("Toggle Inspector / Graph", "⌥⌘I / ⌥⌘G")
            shortcutRow("Split Right / Down", "Menu")
            shortcutRow("Switch Panes / Tabs", "⌥⌘← / ⌥⌘→ / ⌘1–9")
        }
        .listStyle(.inset)
    }

    private var diagnosticsTab: some View {
        Form {
            Section("Diagnostics Health") {
                if let health = diagnosticsModel.health {
                    LabeledContent("Recorded", value: String(health.recordedEventCount))
                        .accessibilityIdentifier("diagnostics.health.recorded")
                    LabeledContent(
                        "Retained in Memory",
                        value: "\(health.retainedEventCount) events · "
                            + ByteCountFormatter.string(
                                fromByteCount: Int64(health.retainedByteCount),
                                countStyle: .memory))
                    LabeledContent("Dropped or Expired", value: String(health.droppedEventCount))
                        .accessibilityIdentifier("diagnostics.health.dropped")
                    LabeledContent("Sink Write Failures", value: String(health.sinkFailureCount))
                        .accessibilityIdentifier("diagnostics.health.sinkFailures")
                } else {
                    LabeledContent("Status", value: "Not checked")
                        .foregroundStyle(.secondary)
                }

                Button {
                    Task { await diagnosticsModel.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            }

            Section("Support Report") {
                Text(
                    "Exports event codes, counts, and app/build/OS details. It excludes note text, "
                        + "prompts, commands, environment values, full paths, and URL credentials or queries.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button("Export Support Report…", action: chooseSupportReportDestination)
                        .disabled(diagnosticsModel.exportState.isExporting)
                        .accessibilityIdentifier("diagnostics.export")

                    if diagnosticsModel.exportState.isExporting {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Exporting support report")
                    }
                }

                if !diagnosticsModel.exportState.message.isEmpty,
                   !diagnosticsModel.exportState.isExporting
                {
                    Label(
                        diagnosticsModel.exportState.message,
                        systemImage: exportStatusSymbol)
                        .font(.caption)
                        .foregroundStyle(exportStatusStyle)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("diagnostics.export.status")
                }
            }
        }
        .formStyle(.grouped)
        .task {
            await diagnosticsModel.refresh()
        }
    }

    private var exportStatusSymbol: String {
        switch diagnosticsModel.exportState {
        case .succeeded:
            "checkmark.circle.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        case .idle, .exporting:
            "info.circle"
        }
    }

    private var exportStatusStyle: Color {
        switch diagnosticsModel.exportState {
        case .failed:
            .red
        case .idle, .exporting, .succeeded:
            .secondary
        }
    }

    @MainActor
    private func chooseSupportReportDestination() {
        diagnosticsModel.dismissExportResult()
        let panel = NSSavePanel()
        panel.title = "Export Support Report"
        panel.nameFieldStringValue = "MarkDev Support Report.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task {
            _ = await diagnosticsModel.export(to: destination)
        }
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
