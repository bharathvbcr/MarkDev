//
//  HarnessInspectorView.swift
//  MarkDevKit
//
//  The Assist panel's MANVI half.
//

import SwiftUI

/// Running the local harness against the open note.
///
/// # What this panel deliberately does not show
///
/// The stream. A turn emits hundreds of events and most of them are one word of
/// the answer; rendering them is a wall of text, which is the failure this
/// panel was built to avoid. What it shows instead is three things a reader can
/// act on — what the run touched, what was refused, and the answer — and the
/// answer arrives with the edit it implies attached, rather than as a blob with
/// a Copy button.
struct HarnessInspectorView: View {
    @Bindable var assistant: HarnessAssistant
    @State private var showsSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: GlassTheme.Spacing.snug) {
            switch assistant.availability {
            case .found:
                tasks
                instructionField
                status
                activity
                answer
            case .searching, .unknown:
                HStack(spacing: GlassTheme.Spacing.tight) {
                    ProgressView().controlSize(.small)
                    Text("Looking for MANVI…").font(.caption2).foregroundStyle(.secondary)
                }
            case .missing(let reason):
                missing(reason)
            }
            settings
        }
        .onAppear {
            if assistant.availability == .unknown { assistant.refreshAvailability() }
        }
    }

    // MARK: - Asking

    @ViewBuilder
    private var tasks: some View {
        AssistSectionHeader(title: "Ask MANVI", count: nil)
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)],
            spacing: 4
        ) {
            ForEach(HarnessTask.presets) { task in
                Button { assistant.run(task) } label: {
                    Label(task.title, systemImage: task.symbol)
                        .font(.caption)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, GlassTheme.Spacing.tight)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(assistant.isRunning)
                .background(
                    RoundedRectangle(cornerRadius: GlassTheme.Radius.small)
                        .fill(Color.primary.opacity(0.05)))
                .help(task.directive)
            }
        }
    }

    private var instructionField: some View {
        HStack(spacing: GlassTheme.Spacing.tight) {
            TextField("Ask about this note…", text: $assistant.instruction)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .onSubmit { assistant.runCustom() }
            Button("Run") { assistant.runCustom() }
                .controlSize(.small)
                .disabled(
                    assistant.isRunning
                        || assistant.instruction.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    // MARK: - How it is going

    @ViewBuilder
    private var status: some View {
        switch assistant.state {
        case .idle:
            Text(assistant.settings.authority.explanation)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

        case .running(let task):
            HStack(spacing: GlassTheme.Spacing.tight) {
                ProgressView().controlSize(.small)
                Text(task.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Stop") { assistant.stop() }.controlSize(.mini)
            }

        case .finished(_, let outcome, let truncatedNote):
            VStack(alignment: .leading, spacing: 2) {
                // Never a bare "done". `manvi run` distinguishes a turn that
                // finished from one the step ceiling ended and one the output
                // cap cut off, and a panel that folds them together shows
                // unfinished work as finished.
                Label(outcome.summary, systemImage: outcome.isComplete ? "checkmark" : "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(outcome.isComplete ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                    .fixedSize(horizontal: false, vertical: true)
                if truncatedNote {
                    Text(
                        "Only the first \(HarnessPrompt.maximumNoteLength.formatted()) characters "
                            + "of the note were sent."
                    )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if assistant.transcriptTruncated {
                    Text("This run produced more output than MarkDev kept; the log is partial.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                usage
            }

        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var usage: some View {
        if assistant.inputTokens > 0 || assistant.outputTokens > 0 {
            Text(
                "\(assistant.model.isEmpty ? "" : assistant.model + " · ")"
                    + "\(assistant.inputTokens.formatted()) in, "
                    + "\(assistant.outputTokens.formatted()) out"
            )
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var activity: some View {
        if !assistant.activity.isEmpty {
            AssistSectionHeader(title: "What it did", count: assistant.activity.count)
            ForEach(assistant.activity) { row in
                HStack(alignment: .top, spacing: GlassTheme.Spacing.tight) {
                    Image(systemName: row.symbol)
                        .font(.caption2)
                        .foregroundStyle(row.isError ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
                        .frame(width: 12)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.title)
                            .font(.caption)
                            .lineLimit(2)
                        if !row.detail.isEmpty {
                            Text(row.detail)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 0)
                    if !row.isFinished {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - The answer

    @ViewBuilder
    private var answer: some View {
        if !assistant.answer.isEmpty {
            AssistSectionHeader(title: "Answer", count: nil)
            VStack(alignment: .leading, spacing: GlassTheme.Spacing.tight) {
                Text(assistant.answer)
                    .font(.caption)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: GlassTheme.Spacing.tight) {
                    if assistant.canApply {
                        Button("Replace Note") { assistant.apply() }
                            .controlSize(.small)
                            .help("Replaces the whole note. ⌘Z takes it back.")
                    }
                    if assistant.canInsert {
                        Button("Insert") { assistant.insertAtCaret() }.controlSize(.small)
                    }
                    Button("Copy") { assistant.copyAnswer() }.controlSize(.small)
                    Spacer(minLength: 0)
                }
            }
            .assistCard()
        }
    }

    // MARK: - Not installed

    private func missing(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: GlassTheme.Spacing.tight) {
            Label("MANVI isn’t available", systemImage: "cpu")
                .font(.caption.weight(.medium))
            Text(reason)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Look Again") { assistant.refreshAvailability() }
                .controlSize(.small)
        }
        .assistCard()
    }

    // MARK: - Settings

    private var settings: some View {
        HarnessSettingsView(
            settings: assistant.settings,
            location: {
                if case .found(let location) = assistant.availability { return location }
                return nil
            }(),
            isExpanded: $showsSettings,
            onBinaryChanged: { assistant.refreshAvailability() })
    }
}

/// The MANVI settings, folded away.
///
/// Its own view because ``HarnessAssistant/settings`` is a `let` — the panel
/// may change what is *in* the settings and must never swap the settings
/// object itself — and a binding into a `let` property is not something
/// `@Bindable` on the owner can give. Holding the settings directly here is
/// what makes each field editable without giving the assistant a settable
/// reference nobody wants.
private struct HarnessSettingsView: View {
    @Bindable var settings: HarnessSettings
    let location: HarnessLocation?
    @Binding var isExpanded: Bool
    let onBinaryChanged: () -> Void

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: GlassTheme.Spacing.tight) {
                if let location {
                    Text("\(location.summary): \(location.url.path)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }

                field("Binary", placeholder: "found automatically", text: $settings.binaryPath)
                    .onSubmit(onBinaryChanged)
                field("Server", placeholder: "MANVI’s own setting", text: $settings.serverURL)
                field("Model", placeholder: "MANVI’s own setting", text: $settings.model)

                Picker("Authority", selection: $settings.authority) {
                    ForEach(HarnessAuthority.allCases, id: \.self) { authority in
                        Text(authority.title).tag(authority)
                    }
                }
                .font(.caption2)
                .controlSize(.small)

                Text(settings.authority.explanation)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: GlassTheme.Spacing.tight) {
                    stepper("Steps", value: $settings.maxSteps, range: HarnessSettings.stepRange)
                    stepper(
                        "Minutes", value: $settings.timeoutMinutes,
                        range: HarnessSettings.minuteRange)
                }
            }
            .padding(.top, GlassTheme.Spacing.tight)
        } label: {
            Text("MANVI settings")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }

    private func field(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: GlassTheme.Spacing.tight) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.caption2)
        }
    }

    private func stepper(_ label: String, value: Binding<Int>, range: ClosedRange<Int>)
        -> some View
    {
        Stepper(value: value, in: range) {
            Text("\(label) \(value.wrappedValue)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .controlSize(.mini)
    }
}
