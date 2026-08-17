//
//  AssistInspectorView.swift
//  MarkDevKit
//
//  The inspector's third panel: proofreading results and document questions.
//

import SwiftUI

/// Grammar detection and whole-document tools, beside the outline and links.
///
/// The inspector rather than a floating window because this is a *list about
/// the current note*, which is precisely what the other two tabs are. A
/// proofreading result is the same kind of thing as a backlink: something
/// found in the document, that you click to go to.
public struct AssistInspectorView: View {
    private let assistant: DocumentAssistant
    /// Called with a UTF-16 offset to scroll the editor to.
    private let onReveal: (Int) -> Void

    public init(assistant: DocumentAssistant, onReveal: @escaping (Int) -> Void) {
        self.assistant = assistant
        self.onReveal = onReveal
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: GlassTheme.Spacing.snug) {
            if !assistant.service.state.isReady {
                unavailable
            } else {
                proofreadingSection
                Divider().opacity(0.4)
                insightSection
            }
        }
    }

    private var unavailable: some View {
        VStack(alignment: .leading, spacing: GlassTheme.Spacing.tight) {
            Label(assistant.service.state.headline, systemImage: assistant.service.state.symbol)
                .font(.caption.weight(.medium))
            Text(assistant.service.state.guidance)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Check Again") { assistant.service.refreshAvailability() }
                .controlSize(.small)
        }
        .padding(GlassTheme.Spacing.tight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: GlassTheme.Radius.small)
                .fill(Color.primary.opacity(0.05)))
    }

    // MARK: - Proofreading

    @ViewBuilder
    private var proofreadingSection: some View {
        header("Proofreading", count: assistant.issues.count)

        HStack(spacing: GlassTheme.Spacing.tight) {
            if assistant.isReviewing {
                Button("Stop") { assistant.stopReview() }
                    .controlSize(.small)
            } else {
                Button("Check Document") { assistant.proofread() }
                    .controlSize(.small)
            }
            if !assistant.issues.isEmpty {
                Button("Fix All") { assistant.fixAll() }
                    .controlSize(.small)
                Button("Clear") { assistant.clearIssues() }
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
        }

        reviewStatus

        ForEach(assistant.issues.issues) { issue in
            issueRow(issue)
        }
    }

    @ViewBuilder
    private var reviewStatus: some View {
        switch assistant.review {
        case .idle:
            Text("Checks spelling, grammar, and punctuation on this Mac. Nothing leaves the device.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

        case .running(let checked, let total):
            HStack(spacing: GlassTheme.Spacing.tight) {
                ProgressView(value: Double(checked), total: Double(max(total, 1)))
                    .controlSize(.small)
                Text("\(checked) of \(total)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

        case .done(let checked, let total, let found, let unplaced):
            // Every number, always. A pass that stopped at the twelfth section
            // of forty and reported "no mistakes found" would be claiming
            // something it never looked at.
            Text(Self.summary(checked: checked, total: total, found: found, unplaced: unplaced))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The sentence describing a finished pass.
    ///
    /// Pulled out as a pure function because getting it wrong is a
    /// correctness bug, not a wording one. Three different things can be true
    /// at the end of a pass — the whole document was read, only part of it
    /// was, and some of what the model said could not be used — and each of
    /// them changes what "no mistakes found" is entitled to mean.
    static func summary(checked: Int, total: Int, found: Int, unplaced: Int) -> String {
        if total == 0 { return "Nothing to check." }

        let mistakes =
            found == 0
            ? "No mistakes found"
            : "\(found) \(found == 1 ? "mistake" : "mistakes") found"

        var sentence =
            checked < total
            ? "\(mistakes) in the first \(checked) of \(total) sections. "
                + "Fix these, then run the check again for the rest."
            : "\(mistakes)."

        if unplaced > 0 {
            sentence +=
                " \(unplaced) further \(unplaced == 1 ? "suggestion" : "suggestions") "
                + "couldn’t be matched to the text and \(unplaced == 1 ? "was" : "were") skipped."
        }
        return sentence
    }

    private func issueRow(_ issue: ProofreadingIssue) -> some View {
        Button {
            onReveal(issue.range.location)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: GlassTheme.Spacing.tight) {
                    Image(systemName: issue.kind.symbol)
                        .font(.caption2)
                        .foregroundStyle(Color(issue.kind.tint))
                    Text(issue.kind.label)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Fix") { assistant.fix(issue) }
                        .controlSize(.mini)
                        .buttonStyle(.bordered)
                }
                HStack(spacing: 4) {
                    Text(issue.original)
                        .strikethrough()
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(issue.replacement)
                        .foregroundStyle(.primary)
                }
                .font(.caption)
                .lineLimit(2)
                if !issue.explanation.isEmpty {
                    Text(issue.explanation)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            .padding(GlassTheme.Spacing.tight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: GlassTheme.Radius.small)
                    .fill(Color.primary.opacity(0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(issue.kind.label): replace \(issue.original) with \(issue.replacement)")
    }

    // MARK: - Insights

    @ViewBuilder
    private var insightSection: some View {
        header("This Note", count: nil)

        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)],
            spacing: 4
        ) {
            ForEach(WritingTask.documentPresets) { task in
                Button { assistant.generate(task) } label: {
                    Label(task.title, systemImage: task.symbol)
                        .font(.caption)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, GlassTheme.Spacing.tight)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: GlassTheme.Radius.small)
                        .fill(Color.primary.opacity(0.05)))
            }
        }

        insightResult
    }

    @ViewBuilder
    private var insightResult: some View {
        switch assistant.insight {
        case .idle:
            EmptyView()

        case .running(let task):
            VStack(alignment: .leading, spacing: GlassTheme.Spacing.tight) {
                HStack(spacing: GlassTheme.Spacing.tight) {
                    ProgressView().controlSize(.small)
                    Text(task.title).font(.caption2).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Stop") { assistant.stopThinking() }.controlSize(.mini)
                }
                if !assistant.insightText.isEmpty { resultText }
            }

        case .ready(_, let truncated):
            VStack(alignment: .leading, spacing: GlassTheme.Spacing.tight) {
                resultText
                if truncated {
                    // Never let a partial reading pass for a complete one.
                    Label(
                        "Based on the first \(AssistScope.maximumLength.formatted()) characters.",
                        systemImage: "info.circle"
                    )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: GlassTheme.Spacing.tight) {
                    Button("Copy") { assistant.copyInsight() }.controlSize(.small)
                    Button("Insert at Top") { assistant.insertInsightAtTop() }.controlSize(.small)
                    Spacer(minLength: 0)
                }
            }

        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var resultText: some View {
        Text(assistant.insightText)
            .font(.caption)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(GlassTheme.Spacing.tight)
            .background(
                RoundedRectangle(cornerRadius: GlassTheme.Radius.small)
                    .fill(Color.primary.opacity(0.05)))
    }

    private func header(_ title: String, count: Int?) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            if let count, count > 0 {
                Text("\(count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }
}
