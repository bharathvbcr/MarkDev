//
//  PeekPanel.swift
//  MarkDevKit
//
//  Hold Space in the navigator; a rendered note floats over the workspace.
//

import AppKit
import SwiftUI

/// A floating read-only preview of one note.
///
/// The in-app half of Quick Look. It renders through the same reading-mode
/// editor the Finder extension uses, so Space in the sidebar and Space in
/// Finder show the same note the same way — which is the whole reason the
/// preview is not a second renderer. See ``MarkdownPreviewController``.
public struct PeekPanel: View {
    public let url: URL
    /// Opens the note properly, dismissing the peek.
    public var onOpen: (() -> Void)?
    /// Dismisses without opening.
    public var onDismiss: (() -> Void)?

    @State private var content: Result<String, PeekLoadFailure>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        url: URL,
        onOpen: (() -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.url = url
        self.onOpen = onOpen
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            body(for: content)
            Divider().opacity(0.4)
            footer
        }
        .frame(maxWidth: 760, maxHeight: 620)
        .glassPanel(radius: GlassTheme.Radius.large, padding: EdgeInsets())
        .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
        .padding(GlassTheme.Spacing.loose)
        // Loading is keyed on the URL so arrowing through the sidebar with
        // Space held swaps the note rather than showing the first one forever.
        .task(id: url) { await load() }
        .accessibilityLabel("Preview of \(url.lastPathComponent)")
    }

    private var header: some View {
        HStack(spacing: GlassTheme.Spacing.tight) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
            Text(url.deletingPathExtension().lastPathComponent)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: GlassTheme.Spacing.snug)
            if case .success(let text) = content {
                let stats = DocumentStats(text)
                Text("\(stats.words.formatted(.number)) words")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, GlassTheme.Spacing.regular)
        .padding(.vertical, GlassTheme.Spacing.snug)
    }

    @ViewBuilder
    private func body(for content: Result<String, PeekLoadFailure>?) -> some View {
        switch content {
        case .none:
            // No spinner: a local note loads in a frame or two, and a control
            // that flashes on every peek is worse than a still panel.
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        case .success(let text):
            MarkdownEditorView(
                text: .constant(text),
                mode: .reading,
                documentDirectory: url.deletingLastPathComponent()
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failure(let failure):
            VStack(spacing: GlassTheme.Spacing.tight) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                Text(failure.reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(GlassTheme.Spacing.loose)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack(spacing: GlassTheme.Spacing.snug) {
            Label("Release Space to close", systemImage: "space")
                .labelStyle(.titleAndIcon)
            Spacer(minLength: 0)
            if onOpen != nil {
                Button("Open") { onOpen?() }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, GlassTheme.Spacing.regular)
        .padding(.vertical, GlassTheme.Spacing.tight)
    }

    private func load() async {
        content = nil
        let target = url
        let result = await Task.detached(priority: .userInitiated) {
            PeekLoader.read(target)
        }.value
        // The panel may have moved on to another note while this was reading.
        guard target == url else { return }
        content = result
    }
}

/// Why a note could not be peeked.
public struct PeekLoadFailure: Error, Equatable, Sendable {
    public let reason: String
    public init(reason: String) { self.reason = reason }
}

/// Reads a note for preview.
///
/// Separate from the view so the rules that matter — what is too large to
/// peek, what happens to a file that is not text — are testable without a
/// window.
public enum PeekLoader {
    /// Notes above this are opened rather than peeked.
    ///
    /// A peek is meant to be instant. Reading and laying out a multi-megabyte
    /// file on a key-down is not, and the reader is left holding a key while
    /// nothing happens.
    public static let maximumBytes = 4 * 1024 * 1024

    public static func read(_ url: URL) -> Result<String, PeekLoadFailure> {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maximumBytes else {
            let readable = ByteCountFormatter.string(
                fromByteCount: Int64(size), countStyle: .file)
            return .failure(PeekLoadFailure(reason: "Too large to preview (\(readable))"))
        }

        guard let data = try? Data(contentsOf: url) else {
            return .failure(PeekLoadFailure(reason: "Could not read \(url.lastPathComponent)"))
        }
        // Latin-1 as a fallback, matching the Quick Look extension: a note
        // from an older tool is still worth reading.
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
        else {
            return .failure(PeekLoadFailure(reason: "\(url.lastPathComponent) is not text"))
        }
        return .success(text)
    }
}
