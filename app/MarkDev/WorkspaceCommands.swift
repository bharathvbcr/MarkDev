//
//  WorkspaceCommands.swift
//  MarkDev
//
//  Native menu-bar commands routed to whichever workspace scene is focused.
//

import AppKit
import MarkDevKit
import SwiftUI

struct WorkspaceCommandHandler {
    let perform: (CommandAction) -> Void
}

/// The focused pane's tabs, for the Go-to-Tab menu items.
///
/// The shortcuts ⌘1–9 existed before the menu did — invisible buttons in the
/// pane — which meant the feature was undiscoverable: nothing to click, read,
/// or see disabled. The switcher carries enough state for the menu to render
/// real entries with real titles, and one closure so selection goes through
/// the same path a mouse click takes.
struct TabSwitcher {
    struct Entry: Identifiable {
        let id: OpenDocument.ID
        let title: String
        /// Whether this entry is the pane's current tab; the menu marks it.
        let isCurrent: Bool
    }

    /// At most nine; ⌘0 is nobody's friend here.
    let tabs: [Entry]
    /// Called with a zero-based index. Out-of-range is a no-op, so a stale
    /// menu racing a close can never select into nothing.
    let select: (Int) -> Void
}

private struct WorkspaceCommandHandlerKey: FocusedValueKey {
    typealias Value = WorkspaceCommandHandler
}

private struct TabSwitcherKey: FocusedValueKey {
    typealias Value = TabSwitcher
}

extension FocusedValues {
    var workspaceCommandHandler: WorkspaceCommandHandler? {
        get { self[WorkspaceCommandHandlerKey.self] }
        set { self[WorkspaceCommandHandlerKey.self] = newValue }
    }

    var tabSwitcher: TabSwitcher? {
        get { self[TabSwitcherKey.self] }
        set { self[TabSwitcherKey.self] = newValue }
    }
}

struct WorkspaceCommands: Commands {
    @FocusedValue(\.workspaceCommandHandler)
    private var handler
    @FocusedValue(\.tabSwitcher)
    private var tabSwitcher
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            actionButton("New Document", action: .newDocument, key: "n")
            Button("New Window") {
                openWindow(id: MarkDevApp.workspaceWindowID)
            }
            // No key equivalent: ⌘N belongs to New Document, and a second
            // window is an occasional act rather than a typing-loop one.
        }

        CommandGroup(after: .newItem) {
            actionButton("Open File…", action: .openFile, key: "o")
            actionButton(
                "Open Vault…", action: .openVault, key: "o", modifiers: [.command, .shift])
        }

        CommandGroup(before: .saveItem) {
            actionButton("Save", action: .save, key: "s")
            actionButton(
                "Save As…", action: .saveAs, key: "s", modifiers: [.command, .shift])
        }

        // Find travels the responder chain to whichever text view is first
        // responder, rather than through the workspace handler: the editor is
        // an `NSTextView` and already owns a find bar, so the menu's whole job
        // is to give those built-in actions a key equivalent. Without these
        // items ⌘F does nothing at all — a menu item is what turns a find bar
        // that exists into one a reader can reach.
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Find…") { performFindAction(.showFindInterface) }
                .keyboardShortcut("f")
            Button("Find and Replace…") { performFindAction(.showReplaceInterface) }
                .keyboardShortcut("f", modifiers: [.command, .option])
            Button("Find Next") { performFindAction(.nextMatch) }
                .keyboardShortcut("g")
            Button("Find Previous") { performFindAction(.previousMatch) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Button("Use Selection for Find") { performFindAction(.setSearchString) }
                .keyboardShortcut("e")
        }

        CommandMenu("Editor") {
            actionButton("Command Palette…", action: .toggleCommandPalette, key: "k")
            Divider()
            actionButton(
                "Toggle Sidebar", action: .toggleSidebar, key: "\\")
            actionButton(
                "Toggle Inspector", action: .toggleInspector, key: "i",
                modifiers: [.command, .option])
            actionButton("Toggle Terminal", action: .toggleTerminal, key: "j")
            actionButton(
                "Graph View", action: .toggleGraph, key: "g", modifiers: [.command, .shift])
            Divider()
            actionButton(SplitEdge.trailing.commandTitle, action: .splitRight)
            actionButton(SplitEdge.bottom.commandTitle, action: .splitDown)
            actionButton(
                "Close Pane", action: .closePane, key: "w", modifiers: [.control, .command])
            actionButton(
                "Focus Next Pane", action: .focusNextPane, key: .rightArrow,
                modifiers: [.option, .command])
            actionButton(
                "Focus Previous Pane", action: .focusPreviousPane, key: .leftArrow,
                modifiers: [.option, .command])
            Divider()
            // ⌘1–9 made visible. These replace the hidden shortcut buttons
            // that used to live in each pane: same keys, now something a
            // reader can find, and greyed rather than absent past the last
            // tab so the range is legible at a glance.
            if let tabSwitcher, !tabSwitcher.tabs.isEmpty {
                ForEach(Array(tabSwitcher.tabs.enumerated()), id: \.element.id) {
                    index, tab in
                    Button(tab.isCurrent ? "✓ \(tab.title)" : tab.title) {
                        tabSwitcher.select(index)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                }
            }
            Divider()
            // Numbered in the enum's own order, so the menu, the palette, and
            // the toolbar switcher cannot disagree about which mode is which.
            ForEach(Array(EditorMode.allCases.enumerated()), id: \.element) { index, mode in
                actionButton(
                    mode.commandTitle, action: .setMode(mode),
                    key: KeyEquivalent(Character("\(index + 1)")), modifiers: .control)
            }
        }

        // Its own menu rather than items inside Editor: these are the actions
        // people go looking for by name, and burying "Proofread" under a menu
        // called Editor is how a feature ships and is never found.
        CommandMenu("Writing Tools") {
            actionButton(
                "Rewrite Selection…", action: .writingTools, key: "e",
                modifiers: [.command, .shift])
            Divider()
            actionButton(
                "Proofread Document", action: .proofreadDocument, key: "p",
                modifiers: [.command, .shift])
            actionButton("Clear Proofreading Marks", action: .clearProofreading)
            Divider()
            actionButton("Read This Note", action: .analyzeNote)
            Divider()
            actionButton("Ask MANVI…", action: .askHarness)
            actionButton("Run MANVI in a Terminal", action: .openHarnessTerminal)
        }
    }

    /// Sends one of AppKit's find actions down the responder chain.
    ///
    /// `performTextFinderAction(_:)` reads the *sender's* tag to decide which
    /// action was asked for, so the sender has to be an object carrying one.
    /// A detached `NSMenuItem` is the smallest thing that qualifies; the alarm
    /// bell is that passing `nil`, or any sender without a tag, silently
    /// performs `showFindInterface` no matter which item was chosen.
    private func performFindAction(_ action: NSTextFinder.Action) {
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        NSApp?.sendAction(
            #selector(NSResponder.performTextFinderAction(_:)), to: nil, from: sender)
    }

    @ViewBuilder
    private func actionButton(
        _ title: String,
        action: CommandAction,
        key: KeyEquivalent? = nil,
        modifiers: EventModifiers = .command
    ) -> some View {
        Button(title) { handler?.perform(action) }
            .disabled(handler == nil)
            .optionalKeyboardShortcut(key, modifiers: modifiers)
    }
}

private extension View {
    @ViewBuilder
    func optionalKeyboardShortcut(
        _ key: KeyEquivalent?, modifiers: EventModifiers
    ) -> some View {
        if let key {
            keyboardShortcut(key, modifiers: modifiers)
        } else {
            self
        }
    }
}
