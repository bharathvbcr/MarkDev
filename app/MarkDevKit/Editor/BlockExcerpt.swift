//
//  BlockExcerpt.swift
//  MarkDevKit
//
//  One block's content, lifted out of the document to be read on its own.
//

import SwiftUI

/// A code or diagram block, pulled out of the flow so it can be read whole.
///
/// # Why a pop-out and not a wider editor
///
/// The writing surface wraps: it is a column of prose, and that is what makes
/// it comfortable to write in. A wide diagram or a long line of code is the
/// one thing that column cannot show — wrapping a Mermaid graph mid-edge, or a
/// 200-column log line, destroys the only structure it had. Rather than let
/// one block dictate the measure for the whole document, the block gets its
/// own surface, where it may scroll in both directions and wrap in neither.
public struct BlockExcerpt: Identifiable, Equatable, Sendable {
    public let id = UUID()
    /// The fence's info string, when it had one.
    public let language: String?
    /// A `mermaid` fence, whose content describes a picture.
    public let isDiagram: Bool
    public let content: String

    public init(language: String?, isDiagram: Bool, content: String) {
        self.language = language
        self.isDiagram = isDiagram
        self.content = content
    }

    public var title: String {
        if isDiagram { return "Diagram" }
        guard let language, !language.isEmpty else { return "Code Block" }
        return language.uppercased()
    }

    public var lineCount: Int {
        content.isEmpty ? 0 : content.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    /// The longest line, which is what decides whether the block was ever
    /// going to fit the writing column.
    public var widestLine: Int {
        content.split(separator: "\n", omittingEmptySubsequences: false)
            .map(\.count)
            .max() ?? 0
    }
}

/// The pop-out surface: the block's content, scrollable in both directions.
public struct BlockExcerptView: View {
    public let excerpt: BlockExcerpt
    public let onClose: () -> Void

    @State private var scale: CGFloat = 1
    @State private var copied = false

    /// Bounds on zoom. Below half size a diagram is unreadable; above triple
    /// it, scrolling to find anything costs more than it gains.
    private static let scaleRange: ClosedRange<CGFloat> = 0.5...3.0

    public init(excerpt: BlockExcerpt, onClose: @escaping () -> Void) {
        self.excerpt = excerpt
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 520, idealWidth: 820, minHeight: 320, idealHeight: 560)
    }

    private var header: some View {
        HStack(spacing: GlassTheme.Spacing.snug) {
            Image(systemName: excerpt.isDiagram ? "flowchart" : "chevron.left.forwardslash.chevron.right")
                .foregroundStyle(.secondary)
            Text(excerpt.title)
                .font(.headline)
            Text("\(excerpt.lineCount) lines · \(excerpt.widestLine) columns")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)

            Spacer(minLength: GlassTheme.Spacing.regular)

            zoomControls
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(excerpt.content, forType: .string)
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .disabled(copied)
            Button("Done", action: onClose)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, GlassTheme.Spacing.regular)
        .padding(.vertical, GlassTheme.Spacing.snug)
    }

    private var zoomControls: some View {
        HStack(spacing: GlassTheme.Spacing.tight) {
            Button {
                scale = max(Self.scaleRange.lowerBound, scale - 0.25)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .disabled(scale <= Self.scaleRange.lowerBound)

            Text("\(Int(scale * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 42)

            Button {
                scale = min(Self.scaleRange.upperBound, scale + 0.25)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .disabled(scale >= Self.scaleRange.upperBound)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Zoom")
    }

    /// Both axes scroll, and nothing wraps. That is the whole point: a line
    /// too long for the writing column stays one line here.
    private var content: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(excerpt.content)
                .font(.system(size: 13 * scale, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(nil)
                .fixedSize(horizontal: true, vertical: true)
                .padding(GlassTheme.Spacing.regular)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color.primary.opacity(0.04))
    }
}
