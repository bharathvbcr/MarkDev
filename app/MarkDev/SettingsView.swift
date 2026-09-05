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
    private struct SupportPanelLease {
        let id: UUID
        let generation: TransientPresentationCoordinator.Generation
        let panel: NSSavePanel
    }

    @AppStorage(EditorPreferences.Key.themePreset)
    private var themePreset: EditorPreferences.ThemePreset = EditorPreferences.defaultThemePreset
    @AppStorage(EditorPreferences.Key.appearance)
    private var appearanceOverride: EditorPreferences.Appearance = EditorPreferences.defaultAppearance
    @AppStorage(EditorPreferences.Key.mode)
    private var defaultMode: EditorMode = EditorPreferences.defaultMode
    @State private var diagnosticsModel = DiagnosticsSettingsModel()
    @State private var supportPresentation = TransientPresentationCoordinator()
    @State private var supportSavePanel: NSSavePanel?

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
        .frame(width: 500, height: 520)
        .padding()
        .onDisappear(perform: settingsDidDisappear)
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
                    LabeledContent(
                        "Delivery Drops",
                        value: String(health.sinkDeliveryDroppedEventCount))
                        .accessibilityIdentifier("diagnostics.health.deliveryDropped")
                    LabeledContent(
                        "Pending Sink Writes",
                        value: String(pendingDiagnosticEventCount(health)))
                        .accessibilityIdentifier("diagnostics.health.pending")
                    LabeledContent(
                        "Rejected Sink Registrations",
                        value: String(health.rejectedSinkRegistrationCount))
                        .accessibilityIdentifier("diagnostics.health.rejectedSinks")
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
                        .disabled(
                            diagnosticsModel.exportState.isExporting
                                || diagnosticsModel.historyExportState.isExporting
                                || supportPanelIsPresented)
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


            Section("Previous Runs") {
                switch diagnosticsModel.historyAvailability {
                case .notChecked:
                    LabeledContent("Status", value: "Not checked")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("diagnostics.history.status")
                case .unavailable:
                    LabeledContent("Status", value: "Unavailable")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("diagnostics.history.status")
                    Text("Previous-run totals could not be inspected safely. Refresh to retry.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                case let .available(snapshot):
                    historyCounts(snapshot.inspection)
                }

                Text(
                    "Exports only bounded, validated events from inactive runs. Active or untrusted "
                        + "runs are excluded, and unknown totals remain explicitly unknown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button("Export Previous Runs…", action: chooseHistoryReportDestination)
                        .disabled(
                            !historyIsAvailable
                                || diagnosticsModel.historyExportState.isExporting
                                || diagnosticsModel.exportState.isExporting
                                || supportPanelIsPresented)
                        .accessibilityIdentifier("diagnostics.history.export")

                    if diagnosticsModel.historyExportState.isExporting {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Exporting previous-run diagnostics")
                    }
                }

                if !diagnosticsModel.historyExportState.message.isEmpty,
                   !diagnosticsModel.historyExportState.isExporting
                {
                    Label(
                        diagnosticsModel.historyExportState.message,
                        systemImage: historyExportStatusSymbol)
                        .font(.caption)
                        .foregroundStyle(historyExportStatusStyle)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("diagnostics.history.export.status")
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

    private var supportPanelIsPresented: Bool {
        supportSavePanel != nil || supportPresentation.active != nil
    }

    private var historyIsAvailable: Bool {
        if case .available = diagnosticsModel.historyAvailability { return true }
        return false
    }

    private var historyExportStatusSymbol: String {
        switch diagnosticsModel.historyExportState {
        case .succeeded:
            "checkmark.circle.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        case .idle, .exporting:
            "info.circle"
        }
    }

    private var historyExportStatusStyle: Color {
        switch diagnosticsModel.historyExportState {
        case .failed:
            .red
        case .idle, .exporting, .succeeded:
            .secondary
        }
    }

    @ViewBuilder
    private func historyCounts(_ inspection: DiagnosticHistoryInspection) -> some View {
        LabeledContent("Inactive Runs", value: historyCountValue(inspection.runs))
            .accessibilityIdentifier("diagnostics.history.runs")
        LabeledContent("Files", value: historyCountValue(inspection.files))
            .accessibilityIdentifier("diagnostics.history.files")
        LabeledContent("Events", value: historyCountValue(inspection.events))
            .accessibilityIdentifier("diagnostics.history.events")
        LabeledContent("Source Data", value: historyByteValue(inspection.bytes))
            .accessibilityIdentifier("diagnostics.history.bytes")
    }

    private func historyCountValue(_ counts: DiagnosticHistoryDimensionCounts) -> String {
        "\(counts.included) included · \(counts.omitted) omitted · "
            + (counts.uninspected.map { "\($0) uninspected" } ?? "uninspected unknown")
    }

    private func historyByteValue(_ counts: DiagnosticHistoryDimensionCounts) -> String {
        let included = ByteCountFormatter.string(
            fromByteCount: Int64(counts.included),
            countStyle: .memory)
        let omitted = ByteCountFormatter.string(
            fromByteCount: Int64(counts.omitted),
            countStyle: .memory)
        let uninspected = counts.uninspected.map {
            ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory)
        } ?? "unknown"
        return "\(included) included · \(omitted) omitted · \(uninspected) uninspected"
    }

    private func pendingDiagnosticEventCount(_ health: DiagnosticsHealth) -> Int {
        health.sinks.reduce(0) { partial, sink in
            let (sum, overflow) = partial.addingReportingOverflow(
                sink.outstandingEventCount)
            return overflow ? Int.max : sum
        }
    }

    @MainActor
    private func beginSupportPanel(_ panel: NSSavePanel) -> SupportPanelLease? {
        guard !diagnosticsModel.exportState.isExporting,
            !diagnosticsModel.historyExportState.isExporting,
            !supportPanelIsPresented
        else { return nil }

        let id = UUID()
        let result = supportPresentation.present(.nativePanel(id), restoringFocusTo: nil)
        let generation: TransientPresentationCoordinator.Generation
        switch result {
        case .presented(let value), .replaced(previous: _, current: let value):
            generation = value
        case .alreadyPresented, .deferredError, .refused:
            return nil
        }
        supportSavePanel = panel
        return SupportPanelLease(id: id, generation: generation, panel: panel)
    }

    @MainActor
    private func supportPanelIsCurrent(_ lease: SupportPanelLease) -> Bool {
        guard let active = supportPresentation.active,
            let panel = supportSavePanel
        else { return false }
        return active.generation == lease.generation
            && active.presentation == .nativePanel(lease.id)
            && panel === lease.panel
    }

    @MainActor
    private func finishSupportPanel(_ lease: SupportPanelLease) {
        guard supportPanelIsCurrent(lease) else { return }
        supportSavePanel = nil
        _ = supportPresentation.dismiss(lease.generation)
    }

    @MainActor
    private func chooseSupportReportDestination() {
        guard !diagnosticsModel.exportState.isExporting,
            !diagnosticsModel.historyExportState.isExporting,
            !supportPanelIsPresented
        else { return }
        diagnosticsModel.dismissExportResult()
        let panel = NSSavePanel()
        panel.title = "Export Support Report"
        panel.nameFieldStringValue = "MarkDev Support Report.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard let lease = beginSupportPanel(panel) else { return }

        panel.begin { response in
            guard supportPanelIsCurrent(lease) else { return }
            guard response == .OK, let destination = panel.url else {
                finishSupportPanel(lease)
                return
            }
            Task { @MainActor in
                guard supportPanelIsCurrent(lease) else { return }
                defer { finishSupportPanel(lease) }
                _ = await diagnosticsModel.export(to: destination)
            }
        }
    }

    @MainActor
    private func chooseHistoryReportDestination() {
        guard historyIsAvailable,
            !diagnosticsModel.exportState.isExporting,
            !diagnosticsModel.historyExportState.isExporting,
            !supportPanelIsPresented
        else { return }
        diagnosticsModel.dismissHistoryExportResult()
        let panel = NSSavePanel()
        panel.title = "Export Previous Runs"
        panel.nameFieldStringValue = "MarkDev Previous Runs.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard let lease = beginSupportPanel(panel) else { return }

        panel.begin { response in
            guard supportPanelIsCurrent(lease) else { return }
            guard response == .OK, let destination = panel.url else {
                finishSupportPanel(lease)
                return
            }
            Task { @MainActor in
                guard supportPanelIsCurrent(lease) else { return }
                defer { finishSupportPanel(lease) }
                _ = await diagnosticsModel.exportHistory(to: destination)
            }
        }
    }

    @MainActor
    private func settingsDidDisappear() {
        diagnosticsModel.cancelHistoryWork()
        supportPresentation.invalidateAll()
        supportSavePanel?.cancel(nil)
        supportSavePanel = nil
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
