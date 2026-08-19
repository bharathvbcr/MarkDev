//
//  TerminalPlacement.swift
//  MarkDevKit
//
//  Which panel the terminal is drawn in.
//

import Foundation

/// Where the shell lives in the window.
///
/// # Why this is a choice rather than two terminals
///
/// The drawer along the bottom is right for a build log — wide, short, and out
/// of the way. It is wrong for anything that reads as a conversation, which is
/// what an agent run is: a coding CLI in a 260-point drawer shows six lines at
/// a time. Down the right-hand side it gets the window's full height beside the
/// note being worked on, which is the shape that work actually has.
///
/// Both places draw the *same* sessions, and moving between them re-parents one
/// `NSView` rather than building a second — so nothing restarts. That is the
/// property this whole enum depends on, and it is why ``TerminalProcessHost``
/// exists; without it "move the terminal" would mean "throw away whatever it
/// was running".
public enum TerminalPlacement: String, CaseIterable, Sendable {
    /// Along the bottom, under every pane.
    case drawer
    /// In the inspector, on the trailing edge.
    case inspector

    public var other: TerminalPlacement {
        self == .drawer ? .inspector : .drawer
    }

    /// The symbol on the control that moves it.
    var moveSymbol: String {
        switch self {
        case .drawer: "arrow.right.to.line"
        case .inspector: "arrow.down.to.line"
        }
    }

    var moveHelp: String {
        switch self {
        case .drawer: "Move the terminal to the sidebar"
        case .inspector: "Move the terminal to the drawer"
        }
    }

    /// The symbol on the control that hides it. A chevron pointing the way the
    /// panel goes: down for the drawer, right for the sidebar.
    var hideSymbol: String {
        switch self {
        case .drawer: "chevron.down"
        case .inspector: "chevron.right"
        }
    }
}
