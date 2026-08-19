//
//  WritingTools.swift
//  MarkDevKit
//
//  The writing tools belonging to one window.
//

import Foundation

/// Apple Intelligence for one window: model access, the inline panel, and the
/// inspector's document panel.
///
/// Exists to answer two questions once instead of at every call site. The
/// first is *which service*: both panels have to share one
/// ``IntelligenceService``, because two would poll availability twice and warm
/// the model up twice for no benefit. The second is *which editor*: with split
/// panes there are several, and both panels must always be pointed at the same
/// one or ⌘⇧E rewrites a paragraph in a pane the reader is not looking at.
///
/// Not `@Observable` itself — it holds nothing that changes. Its three parts
/// are observable, and SwiftUI tracks whichever of them a view actually reads.
@MainActor
public final class WritingTools {
    public let service: IntelligenceService
    /// The panel that appears beside the selection.
    public let inline: WritingAssistant
    /// Proofreading and whole-document questions, shown in the inspector.
    public let document: DocumentAssistant
    /// The local harness, shown beside them in the same panel.
    ///
    /// Here rather than in its own owner for the same "which editor" reason the
    /// other two are: with split panes there are several surfaces, and a run
    /// that applied its answer to a pane the reader is not looking at would
    /// overwrite the wrong note.
    public let harness: HarnessAssistant

    public init() {
        let service = IntelligenceService()
        self.service = service
        inline = WritingAssistant(service: service)
        document = DocumentAssistant(service: service)
        harness = HarnessAssistant()
    }

    /// Points every panel at the editor the reader is working in.
    public func attach(to surface: MarkdownTextView) {
        inline.surface = surface
        document.attach(to: surface)
        harness.attach(to: surface)
    }
}
