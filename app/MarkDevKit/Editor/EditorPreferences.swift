//
//  EditorPreferences.swift
//  MarkDevKit
//
//  Typed values and stable persistence keys for application-wide editor choices.
//

import AppKit
import Foundation

/// The single persistence contract shared by settings and every editor window.
public enum EditorPreferences {
    /// Stable user-defaults keys. Keep these strings unchanged across releases.
    public enum Key {
        public static let mode = "shell.editorMode"
        public static let themePreset = "markdev.themePreset"
        public static let appearance = "markdev.appearanceOverride"
    }

    public static let defaultMode: EditorMode = .livePreview
    public static let defaultThemePreset: ThemePreset = .standard
    public static let defaultAppearance: Appearance = .system

    public enum ThemePreset: String, CaseIterable, Identifiable, Sendable {
        case standard
        case serif
        case mono

        public var id: String { rawValue }

        @MainActor
        public var theme: EditorTheme {
            switch self {
            case .standard: .standard
            case .serif: .serif
            case .mono: .mono
            }
        }
    }

    public enum Appearance: String, CaseIterable, Identifiable, Sendable {
        case system
        case light
        case dark

        public var id: String { rawValue }

        public var nsAppearanceName: NSAppearance.Name? {
            switch self {
            case .system: nil
            case .light: .aqua
            case .dark: .darkAqua
            }
        }

        @MainActor
        public func apply(to application: NSApplication = .shared) {
            application.appearance = nsAppearanceName.flatMap(NSAppearance.init(named:))
        }
    }

    /// Reads the launch value through the same validation used by the typed UI.
    /// Unknown values fail back to the system appearance instead of pinning a
    /// stale or future spelling indefinitely.
    public static func storedAppearance(in defaults: UserDefaults = .standard) -> Appearance {
        guard let rawValue = defaults.string(forKey: Key.appearance) else {
            return defaultAppearance
        }
        return Appearance(rawValue: rawValue) ?? defaultAppearance
    }
}
