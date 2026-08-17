//
//  MarkDevLogoView.swift
//  MarkDevKit
//
//  The logo as a live SwiftUI view.
//

import SwiftUI

/// Draws `MarkDevLogo` at whatever size it is given.
///
/// A view rather than an image asset so the brand chrome and the app icon
/// share one definition — see the note in `MarkDevLogo`. `Canvas` hands the
/// geometry a `CGContext` in SwiftUI's y-down space, which is exactly what
/// `MarkDevLogo.draw` expects.
public struct MarkDevLogoView: View {
    private let style: MarkDevLogo.Style

    public init(style: MarkDevLogo.Style = .app) {
        self.style = style
    }

    public var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            context.withCGContext { cgContext in
                MarkDevLogo.draw(in: cgContext, size: size, style: style)
            }
        }
        .accessibilityLabel("MarkDev")
    }
}

#Preview {
    HStack(spacing: 24) {
        MarkDevLogoView().frame(width: 128, height: 128)
        MarkDevLogoView(style: .mark).frame(width: 128, height: 128)
        MarkDevLogoView().frame(width: 32, height: 32)
        MarkDevLogoView().frame(width: 16, height: 16)
    }
    .padding()
}
