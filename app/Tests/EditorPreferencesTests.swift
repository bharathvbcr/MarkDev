//
//  EditorPreferencesTests.swift
//  MarkDevKitTests
//
//  Persistent editor choices have one typed owner and resolve to real UI values.
//

import AppKit
import SwiftUI
import XCTest

@testable import MarkDevKit

@MainActor
final class EditorPreferencesTests: XCTestCase {
    func testEditorModeUsesTheWorkspacesExistingPersistenceKey() {
        XCTAssertEqual(EditorPreferences.Key.mode, "shell.editorMode")
        XCTAssertEqual(EditorPreferences.defaultMode, .livePreview)
    }

    func testStoredAppearanceDecodesKnownValuesAndFailsSafeForUnknownValues() {
        let suite = "markdev.preferences.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("dark", forKey: EditorPreferences.Key.appearance)
        XCTAssertEqual(EditorPreferences.storedAppearance(in: defaults), .dark)

        defaults.set("future-value", forKey: EditorPreferences.Key.appearance)
        XCTAssertEqual(EditorPreferences.storedAppearance(in: defaults), .system)
    }

    func testEveryThemePresetResolvesToItsEditorTheme() {
        XCTAssertEqual(
            EditorPreferences.ThemePreset.standard.theme.bodyFont.fontName,
            EditorTheme.standard.bodyFont.fontName)
        XCTAssertEqual(
            EditorPreferences.ThemePreset.serif.theme.bodyFont.fontName,
            EditorTheme.serif.bodyFont.fontName)
        XCTAssertEqual(
            EditorPreferences.ThemePreset.mono.theme.bodyFont.fontName,
            EditorTheme.mono.bodyFont.fontName)

        for preset in EditorPreferences.ThemePreset.allCases {
            let editor = MarkdownEditorView(text: .constant(""), theme: preset.theme)
            XCTAssertEqual(editor.theme.bodyFont.fontName, preset.theme.bodyFont.fontName)
            XCTAssertEqual(editor.theme.bodyFont.pointSize, preset.theme.bodyFont.pointSize)
        }
    }

    func testAppearanceValuesMapToTheExpectedApplicationAppearance() {
        XCTAssertNil(EditorPreferences.Appearance.system.nsAppearanceName)
        XCTAssertEqual(EditorPreferences.Appearance.light.nsAppearanceName, .aqua)
        XCTAssertEqual(EditorPreferences.Appearance.dark.nsAppearanceName, .darkAqua)
    }

    func testAppearanceAppliesToTheApplicationAndSystemClearsTheOverride() {
        let application = NSApplication.shared
        let original = application.appearance
        defer { application.appearance = original }

        EditorPreferences.Appearance.dark.apply(to: application)
        XCTAssertEqual(application.appearance?.name, .darkAqua)

        EditorPreferences.Appearance.system.apply(to: application)
        XCTAssertNil(application.appearance)
    }
}
