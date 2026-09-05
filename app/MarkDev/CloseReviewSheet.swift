//
//  CloseReviewSheet.swift
//  MarkDev
//
//  Non-blocking close decisions for document persistence and live terminals.
//

import MarkDevKit
import SwiftUI

struct CloseReviewSheet: View {
    let prompt: CloseReviewPrompt
    let respondToDocument: (UUID, DocumentCloseReviewAction) -> Void
    let respondToTerminals: (UUID, TerminalCloseReviewAction) -> Void
    let respondToVaultTrash: (UUID, VaultTrashReviewAction) -> Void

    var body: some View {
        AdaptiveCloseReviewSheetLayout {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(.yellow)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 7) {
                        Text(headline)
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("close-review.headline")
                        Text(detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("close-review.detail")
                    }
                }

                if case .terminals(_, let presentation) = prompt,
                    presentation.risks.count > 1
                {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(presentation.risks) { risk in
                            Label(risk.title, systemImage: "apple.terminal")
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .accessibilityIdentifier(
                                    "close-review.terminal.\(risk.id.sessionID.uuidString)")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 42)
                }

                CloseReviewActionLayout(spacing: 10) {
                    buttons
                }
                .frame(maxWidth: .infinity)
            }
            .padding(22)
        }
        .interactiveDismissDisabled()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("close-review.sheet")
    }

    private var headline: String {
        switch prompt {
        case .document(_, let presentation): presentation.headline
        case .terminals(_, let presentation): presentation.headline
        case .vaultTrash(_, let presentation): presentation.headline
        }
    }

    private var detail: String {
        switch prompt {
        case .document(_, let presentation): presentation.detail
        case .terminals(_, let presentation): presentation.detail
        case .vaultTrash(_, let presentation): presentation.detail
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch prompt {
        case .document(let promptID, let presentation):
            ForEach(Array(presentation.actions.reversed()), id: \.self) { action in
                documentButton(action, promptID: promptID)
            }
        case .terminals(let promptID, let presentation):
            ForEach(Array(presentation.actions.reversed()), id: \.self) { action in
                terminalButton(action, promptID: promptID)
            }
        case .vaultTrash(let promptID, let presentation):
            ForEach(Array(presentation.actions.reversed()), id: \.self) { action in
                vaultTrashButton(action, promptID: promptID)
            }
        }
    }

    @ViewBuilder
    private func documentButton(
        _ action: DocumentCloseReviewAction,
        promptID: UUID
    ) -> some View {
        Button(role: documentRole(action)) {
            respondToDocument(promptID, action)
        } label: {
            Text(action.label)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .keyboardShortcut(
            action == .cancel ? .cancelAction : action == primaryDocumentAction ? .defaultAction : nil)
        .accessibilityIdentifier("close-review.document.\(actionIdentifier(action))")
    }

    @ViewBuilder
    private func terminalButton(
        _ action: TerminalCloseReviewAction,
        promptID: UUID
    ) -> some View {
        Button(role: action == .cancel ? .cancel : .destructive) {
            respondToTerminals(promptID, action)
        } label: {
            Text(action.label)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .keyboardShortcut(action == .cancel ? .cancelAction : .defaultAction)
        .accessibilityIdentifier("close-review.terminal.\(terminalActionIdentifier(action))")
    }

    @ViewBuilder
    private func vaultTrashButton(
        _ action: VaultTrashReviewAction,
        promptID: UUID
    ) -> some View {
        Button(role: action == .cancel ? .cancel : .destructive) {
            respondToVaultTrash(promptID, action)
        } label: {
            Text(action.label)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .keyboardShortcut(action == .cancel ? .cancelAction : .defaultAction)
        .accessibilityIdentifier("close-review.trash.\(vaultTrashActionIdentifier(action))")
    }

    private var primaryDocumentAction: DocumentCloseReviewAction? {
        guard case .document(_, let presentation) = prompt else { return nil }
        return presentation.actions.first
    }

    private func documentRole(_ action: DocumentCloseReviewAction) -> ButtonRole? {
        switch action {
        case .closeAnyway: .destructive
        case .cancel: .cancel
        case .save, .retryDurability, .saveAgain: nil
        }
    }

    private func actionIdentifier(_ action: DocumentCloseReviewAction) -> String {
        switch action {
        case .save: "save"
        case .retryDurability: "retry-durability"
        case .saveAgain: "save-again"
        case .closeAnyway: "close-anyway"
        case .cancel: "cancel"
        }
    }

    private func terminalActionIdentifier(_ action: TerminalCloseReviewAction) -> String {
        switch action {
        case .stopAndClose: "stop-and-close"
        case .stopAndRestart: "stop-and-restart"
        case .cancel: "cancel"
        }
    }

    private func vaultTrashActionIdentifier(_ action: VaultTrashReviewAction) -> String {
        switch action {
        case .moveToTrash: "move"
        case .cancel: "cancel"
        }
    }
}

/// Applies the sheet's pure width policy to the actual parent proposal.
private struct AdaptiveCloseReviewSheetLayout: Layout {
    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let width = CloseReviewSheetLayout.width(availableWidth: proposal.width)
        let size = content.sizeThatFits(
            ProposedViewSize(width: width, height: proposal.height))
        return CGSize(width: width, height: size.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let content = subviews.first else { return }
        content.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// Keeps actions on one trailing row when they fit and stacks them when real
/// fitted labels (including accessibility sizes) would overflow.
private struct CloseReviewActionLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let intrinsic = subviews.map { $0.sizeThatFits(.unspecified) }
        let naturalWidth = intrinsic.map(\.width).reduce(0, +)
            + spacing * CGFloat(max(0, intrinsic.count - 1))
        let availableWidth = proposal.width ?? naturalWidth
        let axis = CloseReviewSheetLayout.actionAxis(
            availableContentWidth: availableWidth,
            buttonWidths: intrinsic.map(\.width),
            spacing: spacing)
        switch axis {
        case .horizontal:
            return CGSize(
                width: availableWidth,
                height: intrinsic.map(\.height).max() ?? 0)
        case .vertical:
            let fitted = subviews.map {
                $0.sizeThatFits(ProposedViewSize(width: availableWidth, height: nil))
            }
            return CGSize(
                width: availableWidth,
                height: fitted.map(\.height).reduce(0, +)
                    + spacing * CGFloat(max(0, fitted.count - 1)))
        }
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let intrinsic = subviews.map { $0.sizeThatFits(.unspecified) }
        let axis = CloseReviewSheetLayout.actionAxis(
            availableContentWidth: bounds.width,
            buttonWidths: intrinsic.map(\.width),
            spacing: spacing)
        switch axis {
        case .horizontal:
            let total = intrinsic.map(\.width).reduce(0, +)
                + spacing * CGFloat(max(0, intrinsic.count - 1))
            var x = bounds.maxX - total
            for (subview, size) in zip(subviews, intrinsic) {
                subview.place(
                    at: CGPoint(x: x, y: bounds.midY),
                    anchor: .leading,
                    proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        case .vertical:
            var y = bounds.minY
            for subview in subviews {
                let size = subview.sizeThatFits(
                    ProposedViewSize(width: bounds.width, height: nil))
                subview.place(
                    at: CGPoint(x: bounds.maxX, y: y),
                    anchor: .topTrailing,
                    proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
                y += size.height + spacing
            }
        }
    }
}
