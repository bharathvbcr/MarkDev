//
//  AssistInspectorView.swift
//  MarkDevKit
//
//  The inspector's Assist panel: proofreading, a structured reading of the
//  note, and the local harness.
//

import SwiftUI

/// Which model the Assist panel is driving.
///
/// Not two spellings of one feature, which is why the panel makes the reader
/// choose rather than picking for them. Apple Intelligence is on-device, free,
/// and answers in seconds about the four thousand characters in front of you.
/// MANVI drives whatever model this machine is serving, with an agent loop and
/// read access to the whole vault, and takes minutes. The questions each can
/// answer barely overlap.
public enum AssistEngine: String, CaseIterable, Sendable {
    case apple = "Apple"
    case harness = "MANVI"

    var symbol: String {
        switch self {
        case .apple: "apple.intelligence"
        case .harness: "cpu"
        }
    }
}

/// Grammar detection, a reading of the note, and the harness — beside the
/// outline and links.
///
/// The inspector rather than a floating window because these are *lists about
/// the current note*, which is precisely what the other tabs are. A
/// proofreading result is the same kind of thing as a backlink: something found
/// in the document, that you click to go to.
public struct AssistInspectorView: View {
    private let assistant: DocumentAssistant
    private let harness: HarnessAssistant
    @Binding private var engine: AssistEngine
    /// Called with a UTF-16 offset to scroll the editor to.
    private let onReveal: (Int) -> Void

    public init(
        assistant: DocumentAssistant,
        harness: HarnessAssistant,
        engine: Binding<AssistEngine>,
        onReveal: @escaping (Int) -> Void
    ) {
        self.assistant = assistant
        self.harness = harness
        self._engine = engine
        self.onReveal = onReveal
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: GlassTheme.Spacing.snug) {
            enginePicker
            switch engine {
            case .apple: appleSections
            case .harness: HarnessInspectorView(assistant: harness)
            }
        }
    }

    private var enginePicker: some View {
        Picker("", selection: $engine) {
            ForEach(AssistEngine.allCases, id: \.self) { engine in
                Label(engine.rawValue, systemImage: engine.symbol).tag(engine)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    @ViewBuilder
    private var appleSections: some View {
        if !assistant.service.state.isReady {
            unavailable
        } else {
            proofreadingSection
            Divider().opacity(0.4)
            briefSection
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
        .assistCard()
    }

    // MARK: - Proofreading

    @ViewBuilder
    private var proofreadingSection: some View {
        AssistSectionHeader(title: "Proofreading", count: assistant.issues.count)

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
    /// Pulled out as a pure function because getting it wrong is a correctness
    /// bug, not a wording one. Three different things can be true at the end of
    /// a pass — the whole document was read, only part of it was, and some of
    /// what the model said could not be used — and each of them changes what
    /// "no mistakes found" is entitled to mean.
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
            .assistCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(issue.kind.label): replace \(issue.original) with \(issue.replacement)")
    }

    // MARK: - The note, read

    @ViewBuilder
    private var briefSection: some View {
        AssistSectionHeader(title: "This Note", count: nil)

        HStack(spacing: GlassTheme.Spacing.tight) {
            if assistant.isReading {
                Button("Stop") { assistant.stopReading() }.controlSize(.small)
                ProgressView().controlSize(.small)
            } else {
                Button("Read This Note") { assistant.analyze() }.controlSize(.small)
            }
            Spacer(minLength: 0)
        }

        switch assistant.reading {
        case .idle:
            Text("Summary, key points, a title, and tags — in one pass, each with somewhere to put it.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

        case .running:
            EmptyView()

        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

        case .ready(let truncated):
            briefBody(truncated: truncated)
        }
    }

    @ViewBuilder
    private func briefBody(truncated: Bool) -> some View {
        let brief = assistant.brief

        if !brief.title.isEmpty {
            AssistField(
                label: "Title", text: brief.title,
                actions: [
                    .init(title: "Use as Heading") { assistant.applyTitle() },
                    .init(title: "Copy") { assistant.copy(brief.title) },
                ])
        }

        if !brief.summary.isEmpty {
            AssistField(
                label: "Summary", text: brief.summary,
                actions: [
                    .init(title: "Insert") { assistant.insertSummary() },
                    .init(title: "Copy") { assistant.copy(brief.summary) },
                ])
        }

        if !brief.keyPoints.isEmpty {
            AssistField(
                label: "Key points",
                bullets: brief.keyPoints,
                actions: [
                    .init(title: "Insert") { assistant.insertKeyPoints() },
                    .init(title: "Copy") { assistant.copy(brief.keyPointList) },
                ])
        }

        if !brief.tags.isEmpty {
            AssistField(
                label: "Tags",
                chips: brief.tags.map { "#" + $0 },
                actions: [
                    .init(title: "Insert") { assistant.insertTags() },
                    .init(title: "Copy") { assistant.copy(brief.tagLine) },
                ])
        }

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
    }
}

// MARK: - Shared pieces

/// A titled section rule, shared by both engines' panels.
struct AssistSectionHeader: View {
    let title: String
    let count: Int?

    var body: some View {
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

/// One labelled result with the things you can do to it.
///
/// The shape the panel was missing. A model answer with no affordance but Copy
/// is an answer the reader has to retype, so every field here arrives with the
/// edit it implies attached — a title you can make the heading, tags you can
/// insert, points you can drop in as a list.
struct AssistField: View {
    struct Action: Identifiable {
        let id = UUID()
        let title: String
        let perform: () -> Void

        init(title: String, perform: @escaping () -> Void) {
            self.title = title
            self.perform = perform
        }
    }

    let label: String
    var text: String?
    var bullets: [String] = []
    var chips: [String] = []
    let actions: [Action]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: GlassTheme.Spacing.tight) {
                Text(label.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                ForEach(actions) { action in
                    Button(action.title, action: action.perform)
                        .controlSize(.mini)
                        .buttonStyle(.bordered)
                }
            }

            if let text {
                Text(text)
                    .font(.caption)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ForEach(Array(bullets.enumerated()), id: \.offset) { _, bullet in
                HStack(alignment: .top, spacing: 6) {
                    Text("•").foregroundStyle(.tertiary)
                    Text(bullet)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }

            if !chips.isEmpty {
                AssistChipRow(chips: chips)
            }
        }
        .assistCard()
    }
}

/// Tags, wrapped rather than truncated.
///
/// A `LazyVGrid` of flexible columns would be tidier to write and is wrong for
/// this: tags are short and of wildly different lengths, and a fixed column
/// count leaves `#ai` occupying the same width as `#project-planning`. The
/// layout below gives each chip its own width and wraps when the row is full.
struct AssistChipRow: View {
    let chips: [String]

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                Text(chip)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(Color.accentColor.opacity(0.18)))
            }
        }
    }
}

/// Lays subviews out left to right, wrapping to the next line.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = self.rows(subviews: subviews, width: width)
        let height =
            rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * spacing
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var y = bounds.minY
        for row in rows(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y), anchor: .topLeading,
                    proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let projected = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if projected > width && !current.indices.isEmpty {
                rows.append(current)
                current = Row()
                current.indices = [index]
                current.width = size.width
                current.height = size.height
            } else {
                current.indices.append(index)
                current.width = projected
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

extension View {
    /// The panel's one card treatment, so a row added later cannot invent a
    /// second one.
    func assistCard() -> some View {
        padding(GlassTheme.Spacing.tight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: GlassTheme.Radius.small)
                    .fill(Color.primary.opacity(0.05)))
    }
}
