//
//  WritingAssistPanel.swift
//  MarkDevKit
//
//  The contents of the inline writing popover.
//

import SwiftUI

/// The panel beside the selection: pick a rewrite, watch it arrive, keep it.
///
/// Deliberately not glass. It floats above the writing surface, but it also
/// *contains* the writer's own prose in the preview — and the whole reason the
/// canvas is flat is that refracted body text is harder to read. A popover
/// already has a material of its own; adding another is decoration on top of
/// decoration.
public struct WritingAssistPanel: View {
    @Bindable private var assistant: WritingAssistant

    public init(assistant: WritingAssistant) {
        self.assistant = assistant
    }

    private static let width: CGFloat = 400

    public var body: some View {
        VStack(alignment: .leading, spacing: GlassTheme.Spacing.snug) {
            header

            switch assistant.phase {
            case .blocked(let reason):
                notice(reason, symbol: assistant.service.state.symbol)
            case .ready:
                sourceSummary
                instructionField
                taskList
            case .running:
                resultArea
                runningControls
            case .finished:
                resultArea
                finishedControls
            case .failed(let message):
                notice(message, symbol: "exclamationmark.triangle")
                retryControls
            }
        }
        .padding(GlassTheme.Spacing.regular)
        .frame(width: Self.width)
        .onKeyPress(.escape) {
            assistant.close()
            return .handled
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: GlassTheme.Spacing.tight) {
            Image(systemName: "apple.intelligence")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(assistant.activeTask?.title ?? "Writing Tools")
                .font(.headline)
            Spacer(minLength: GlassTheme.Spacing.snug)
            if assistant.isRunning {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Working")
            }
            Button {
                assistant.close()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close writing tools")
        }
    }

    /// What the panel is about to work on.
    ///
    /// One line, truncated. Without it there is no way to tell whether the
    /// caret expanded to the paragraph you meant — which is the difference
    /// between rewriting a sentence and rewriting a section.
    private var sourceSummary: some View {
        Text(assistant.sourceText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Choosing

    private var instructionField: some View {
        HStack(spacing: GlassTheme.Spacing.tight) {
            Image(systemName: "wand.and.sparkles")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Describe an edit…", text: $assistant.customInstruction)
                .textFieldStyle(.plain)
                .onSubmit { assistant.runCustomInstruction() }
        }
        .padding(.horizontal, GlassTheme.Spacing.snug)
        .padding(.vertical, GlassTheme.Spacing.tight)
        .background(
            RoundedRectangle(cornerRadius: GlassTheme.Radius.small)
                .fill(.quaternary.opacity(0.5)))
    }

    private var taskList: some View {
        VStack(alignment: .leading, spacing: GlassTheme.Spacing.snug) {
            section("Rewrite", tasks: WritingTask.presets.filter { $0.output == .rewrite })
            section("Create", tasks: WritingTask.presets.filter { $0.output == .derived })
        }
    }

    private func section(_ title: String, tasks: [WritingTask]) -> some View {
        VStack(alignment: .leading, spacing: GlassTheme.Spacing.hairline) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)],
                spacing: 4
            ) {
                ForEach(tasks) { task in
                    Button { assistant.run(task) } label: {
                        Label(task.title, systemImage: task.symbol)
                            .font(.callout)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, GlassTheme.Spacing.tight)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(
                        RoundedRectangle(cornerRadius: GlassTheme.Radius.small)
                            .fill(.quaternary.opacity(0.35)))
                }
            }
        }
    }

    // MARK: - Result

    private var resultArea: some View {
        ScrollView {
            Text(assistant.output.isEmpty ? "…" : assistant.output)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 220)
        .accessibilityLabel("Result")
    }

    private var runningControls: some View {
        HStack {
            Spacer()
            Button("Stop") { assistant.stop() }
                .keyboardShortcut(".", modifiers: .command)
        }
    }

    private var finishedControls: some View {
        HStack(spacing: GlassTheme.Spacing.tight) {
            Button("Copy") { assistant.copyOutput() }
            Spacer(minLength: GlassTheme.Spacing.tight)
            Button("Insert Below") { assistant.insertBelow() }
                .disabled(!assistant.canApply)
            // A derived result — a summary, a list of key points — is never
            // offered as a replacement. Swapping a section for its own summary
            // deletes the section, and no one presses Summarize to do that.
            if !assistant.resultIsDerived {
                Button("Replace") { assistant.replaceSource() }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
                    .disabled(!assistant.canApply)
            }
        }
    }

    private var retryControls: some View {
        HStack {
            Spacer()
            if let task = assistant.activeTask {
                Button("Try Again") { assistant.run(task) }
            }
            Button("Close") { assistant.close() }
        }
    }

    private func notice(_ message: String, symbol: String) -> some View {
        Label {
            Text(message).font(.callout)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}
