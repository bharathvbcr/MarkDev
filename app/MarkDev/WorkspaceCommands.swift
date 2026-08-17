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

private struct WorkspaceCommandHandlerKey: FocusedValueKey {
    typealias Value = WorkspaceCommandHandler
}

extension FocusedValues {
    var workspaceCommandHandler: WorkspaceCommandHandler? {
        get { self[WorkspaceCommandHandlerKey.self] }
        set { self[WorkspaceCommandHandlerKey.self] = newValue }
    }
}

struct WorkspaceCommands: Commands {
    @FocusedValue(\.workspaceCommandHandler)
    private var handler

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            actionButton("New Document", action: .newDocument, key: "n")
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
            // Numbered in the enum's own order, so the menu, the palette, and
            // the toolbar switcher cannot disagree about which mode is which.
            ForEach(Array(EditorMode.allCases.enumerated()), id: \.element) { index, mode in
                actionButton(
                    mode.commandTitle, action: .setMode(mode),
                    key: KeyEquivalent(Character("\(index + 1)")), modifiers: .control)
            }
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
