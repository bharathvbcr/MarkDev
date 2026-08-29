//
//  StatusBar.swift
//  MarkDevKit
//
//  The readout under each pane: what this document is, and how long it is.
//

import SwiftUI

/// Location and length of the document in one pane.
///
/// # Why this is not glass
///
/// Everything else in the chrome floats above the canvas and refracts it. This
/// sits *against* body text at the foot of the column, and a refracting band
/// there competes with the last line the writer is looking at. It is a flat
/// strip under a hairline — the same reasoning that keeps the writing surface
/// itself plain, applied to the one piece of chrome that touches it.
///
/// # Why the counts arrive rather than being computed here
///
/// Counting words walks the whole document. On the keystroke path that is a
/// per-character cost proportional to document length, which is exactly the
/// shape of stall the editor's performance gates exist to prevent. The owner
/// debounces the count off the main actor and hands the result down.
public struct StatusBar: View {
    /// Where the document lives, already shortened for display — a
    /// vault-relative path, a file name, or `nil` for an unsaved document.
    public let location: String?
    public let hasUnsavedChanges: Bool
    public let stats: DocumentStats
    public let selectedWords: Int?
    public let selectedCharacters: Int?
    public let hoveredLink: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        location: String?,
        hasUnsavedChanges: Bool,
        stats: DocumentStats,
        selectedWords: Int? = nil,
        selectedCharacters: Int? = nil,
        hoveredLink: String? = nil
    ) {
        self.location = location
        self.hasUnsavedChanges = hasUnsavedChanges
        self.stats = stats
        self.selectedWords = selectedWords
        self.selectedCharacters = selectedCharacters
        self.hoveredLink = hoveredLink
    }

    public var body: some View {
        HStack(spacing: GlassTheme.Spacing.tight) {
            if let hoveredLink, !hoveredLink.isEmpty {
                Image(systemName: "link")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)

                Text(hoveredLink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: location == nil ? "doc" : "doc.text")
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)

                Text(location ?? "Unsaved document")
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(.secondary)
                    .help(location ?? "This document has never been saved.")

                if hasUnsavedChanges {
                    Text("Edited")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(Color.primary.opacity(0.07)))
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                }
            }

            Spacer(minLength: GlassTheme.Spacing.snug)

            if let selectedWords, selectedWords > 0 {
                Text("\(selectedWords) of \(stats.words) words")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                // A pane in a four-way split is narrow. Rather than truncating the
                // counts — which turns a number into a lie — drop whole measures
                // until what is left fits.
                ViewThatFits(in: .horizontal) {
                    counts(showingCharacters: true, showingReadingTime: true)
                    counts(showingCharacters: false, showingReadingTime: true)
                    counts(showingCharacters: false, showingReadingTime: false)
                    Text(compactWordCount)
                }
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                // Counts arrive on a debounce, in jumps. Rolling the digits shows
                // that the number moved rather than swapping one still frame for
                // another at the corner of the eye.
                .contentTransition(.numericText())
                .fixedSize()
            }
        }
        .font(.caption)
        .animation(
            GlassTheme.motion(GlassTheme.quickSpring, reduceMotion: reduceMotion),
            value: stats.words)
        .animation(
            GlassTheme.motion(GlassTheme.quickSpring, reduceMotion: reduceMotion),
            value: hasUnsavedChanges)
        .padding(.horizontal, GlassTheme.Spacing.snug)
        .frame(height: GlassTheme.statusBarHeight)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: GlassTheme.dividerLineWidth)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private func counts(showingCharacters: Bool, showingReadingTime: Bool) -> some View {
        var parts = [measure(stats.words, singular: "word", plural: "words")]
        if showingCharacters {
            parts.append(measure(stats.characters, singular: "character", plural: "characters"))
        }
        if showingReadingTime, stats.readingMinutes > 0 {
            parts.append("\(stats.readingMinutes) min read")
        }
        return Text(parts.joined(separator: " · ")).lineLimit(1)
    }

    private var compactWordCount: String {
        "\(stats.words.formatted(.number)) w"
    }

    private var accessibilityDescription: String {
        var description = location ?? "Unsaved document"
        if hasUnsavedChanges { description += ", edited" }
        description += ", \(measure(stats.words, singular: "word", plural: "words"))"
        if stats.readingMinutes > 0 {
            description += ", \(stats.readingMinutes) minute read"
        }
        return description
    }

    /// Grouped digits, so a long document reads as `12,480` rather than
    /// `12480`, in whatever grouping the reader's locale uses.
    private func measure(_ value: Int, singular: String, plural: String) -> String {
        "\(value.formatted(.number)) \(value == 1 ? singular : plural)"
    }
}
