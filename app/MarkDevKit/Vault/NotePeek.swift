//
//  NotePeek.swift
//  MarkDevKit
//
//  A connected note, at a glance.
//

import AppKit
import SwiftUI

/// What a linked note looks like without opening it.
///
/// # Why a peek and not a jump
///
/// Following a `[[wikilink]]` to check one fact costs the reader their place:
/// the pane changes document, and getting back means finding the tab again.
/// Most link-follows in a vault are that check rather than a real move. The
/// peek answers them in place, and keeps the jump one click away for the ones
/// that are not.
@MainActor
public struct NotePeek: Equatable {
    public let title: String
    /// Vault-relative path, shown so two notes with the same title can be
    /// told apart.
    public let path: String
    /// The note's opening, rendered rather than raw.
    public let excerpt: NSAttributedString
    /// Headings, so the shape of the note is visible even when the excerpt
    /// only covers its first paragraph.
    public let headings: [String]
    /// How many notes link here, this one included.
    public let backlinkCount: Int

    public init(
        title: String,
        path: String,
        excerpt: NSAttributedString,
        headings: [String],
        backlinkCount: Int
    ) {
        self.title = title
        self.path = path
        self.excerpt = excerpt
        self.headings = headings
        self.backlinkCount = backlinkCount
    }

    /// How much of a note the peek shows.
    ///
    /// Enough to answer a question, not enough to be a second editor — past
    /// roughly a screenful the reader is better served by opening the note.
    public static let excerptLimit = 1200
}

/// The peek's contents, as a view.
public struct NotePeekView: View {
    public let peek: NotePeek
    public let onOpen: () -> Void

    public init(peek: NotePeek, onOpen: @escaping () -> Void) {
        self.peek = peek
        self.onOpen = onOpen
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: GlassTheme.Spacing.snug) {
            header
            if !peek.headings.isEmpty {
                headingTrail
            }
            Divider()
            AttributedText(peek.excerpt)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(GlassTheme.Spacing.regular)
        .frame(width: 380)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: GlassTheme.Spacing.tight) {
            VStack(alignment: .leading, spacing: 2) {
                Text(peek.title)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: GlassTheme.Spacing.tight) {
                    Text(peek.path)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    if peek.backlinkCount > 0 {
                        Label("\(peek.backlinkCount)", systemImage: "arrow.turn.up.left")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: GlassTheme.Spacing.snug)
            Button(action: onOpen) {
                Label("Open", systemImage: "arrow.up.forward.square")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Open this note")
        }
    }

    /// The note's headings as a single wrapped trail, which reads as a shape
    /// rather than as a second outline panel.
    private var headingTrail: some View {
        Text(peek.headings.prefix(6).joined(separator: "  ·  "))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }
}

/// Renders an `NSAttributedString` without a text view.
///
/// `Text(AttributedString(_:))` is the SwiftUI-native route, but it silently
/// drops any attribute outside its own scopes — which here means the styling
/// the preview renderer just applied. A label keeps it.
struct AttributedText: NSViewRepresentable {
    let string: NSAttributedString

    init(_ string: NSAttributedString) {
        self.string = string
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(labelWithAttributedString: string)
        field.isSelectable = true
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        // Without this the field reports its single-line width as its
        // preferred one and the popover comes out one very long line.
        field.preferredMaxLayoutWidth = 340
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        field.attributedStringValue = string
    }
}

/// Hosts ``NotePeekView`` inside the popover the editor shows.
@MainActor
final class NotePeekController: NSViewController {
    private let peek: NotePeek
    private let onOpen: () -> Void

    init(peek: NotePeek, onOpen: @escaping () -> Void) {
        self.peek = peek
        self.onOpen = onOpen
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("NotePeekController is created in code, never from a nib")
    }

    override func loadView() {
        let hosting = NSHostingView(rootView: NotePeekView(peek: peek, onOpen: onOpen))
        hosting.frame.size = hosting.fittingSize
        view = hosting
        preferredContentSize = hosting.fittingSize
    }
}
