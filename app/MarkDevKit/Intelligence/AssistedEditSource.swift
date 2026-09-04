//
//  AssistedEditSource.swift
//  MarkDevKit
//
//  The common ownership check for model-produced edits.
//

import Foundation

/// Binds generated text to the exact editor state that produced it.
///
/// The writing panels are window-scoped while editor surfaces are pane-scoped.
/// Merely checking that the same words still occur is insufficient: two notes
/// can contain identical paragraphs, and an edit before a captured range can
/// leave those words intact at a different meaning. The entire source snapshot
/// and object identity therefore travel together until application.
@MainActor
final class AssistedEditSource {
    enum Validation: Equatable {
        case current
        case unavailable
        case differentDocument
        case documentChanged
        case readOnly

        var message: String? {
            switch self {
            case .current:
                nil
            case .unavailable:
                "The document that produced this result is no longer open."
            case .differentDocument:
                "This result belongs to a different document. Return to it before applying."
            case .documentChanged:
                "The document changed after this result started. Run it again before applying."
            case .readOnly:
                "Switch the document to an editable view before applying this result."
            }
        }
    }

    private(set) weak var surface: MarkdownTextView?
    let markdown: String

    init(_ surface: MarkdownTextView) {
        self.surface = surface
        markdown = surface.markdown
    }

    func validate(
        attachedTo current: MarkdownTextView?,
        requiresEditing: Bool = true
    ) -> Validation {
        guard let source = surface else { return .unavailable }
        guard let current, current === source else { return .differentDocument }
        guard source.markdown == markdown else { return .documentChanged }
        guard !requiresEditing || source.acceptsAssistedEdits else { return .readOnly }
        return .current
    }

    func resolve(
        attachedTo current: MarkdownTextView?,
        requiresEditing: Bool = true
    ) -> MarkdownTextView? {
        validate(attachedTo: current, requiresEditing: requiresEditing) == .current
            ? surface : nil
    }
}
