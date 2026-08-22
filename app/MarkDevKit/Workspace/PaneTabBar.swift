//
//  PaneTabBar.swift
//  MarkDevKit
//
//  The tab strip at the top of each pane.
//

import AppKit
import SwiftUI

/// How a split direction presents itself in the chrome.
///
/// The same owner-per-name rule the writing modes follow: the pane control,
/// the menu item, and the palette row all read from here, so a tooltip cannot
/// promise one thing while the menu calls it another.
extension SplitEdge {
    /// The name used in the menu bar and the palette.
    public var commandTitle: String {
        switch self {
        case .leading: "Split Left"
        case .trailing: "Split Right"
        case .top: "Split Up"
        case .bottom: "Split Down"
        }
    }

    public var symbol: String {
        switch self {
        case .leading, .trailing: "rectangle.split.2x1"
        case .top, .bottom: "rectangle.split.1x2"
        }
    }

    /// Tooltip text: what pressing the control *does*, rather than what the
    /// control is called. "Split right" beside a split-right glyph tells a
    /// first-time reader nothing the glyph did not; what they cannot guess is
    /// that the new pane arrives showing the document they are already in.
    public var controlHelp: String {
        switch self {
        case .leading: "Split left — this document opens again in a new pane to the left"
        case .trailing: "Split right — this document opens again in a new pane beside this one"
        case .top: "Split up — this document opens again in a new pane above"
        case .bottom: "Split down — this document opens again in a new pane below"
        }
    }
}

/// Tabs for the documents open in one pane.
public struct PaneTabBar: View {
    public let state: PaneState
    public let isFocused: Bool
    /// Whether the window holds more than one pane. Gates the control that
    /// only means something in a split.
    public let isSplit: Bool
    public let onSelect: (OpenDocument.ID) -> Void
    public let onClose: (OpenDocument.ID) -> Void
    public let onSplit: (SplitEdge) -> Void
    public let onClosePane: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glass

    public init(
        state: PaneState,
        isFocused: Bool,
        isSplit: Bool,
        onSelect: @escaping (OpenDocument.ID) -> Void,
        onClose: @escaping (OpenDocument.ID) -> Void,
        onSplit: @escaping (SplitEdge) -> Void,
        onClosePane: @escaping () -> Void
    ) {
        self.state = state
        self.isFocused = isFocused
        self.isSplit = isSplit
        self.onSelect = onSelect
        self.onClose = onClose
        self.onSplit = onSplit
        self.onClosePane = onClosePane
    }

    public var body: some View {
        GlassEffectContainer(spacing: GlassTheme.Spacing.tight) {
            HStack(spacing: GlassTheme.Spacing.tight) {
                ScrollView(.horizontal) {
                    HStack(spacing: GlassTheme.Spacing.tight) {
                        ForEach(Array(state.documents.enumerated()), id: \.element.id) {
                            index, document in
                            TabChip(
                                document: document,
                                isCurrent: document.id == state.current?.id,
                                position: index + 1,
                                tabCount: state.documents.count,
                                showClose: state.documents.count > 1,
                                reduceMotion: reduceMotion,
                                onSelect: { onSelect(document.id) },
                                onClose: { onClose(document.id) }
                            )
                            .glassEffectID(document.id, in: glass)
                            .transition(
                                reduceMotion
                                    ? .opacity
                                    : .asymmetric(
                                        insertion: .scale(scale: 0.8).combined(with: .opacity),
                                        removal: .scale(scale: 0.8).combined(with: .opacity)))
                        }
                    }
                    .padding(.horizontal, 2)
                    // Keyed on the tab identities rather than the count, so
                    // replacing the pristine tab with an opened file animates
                    // too — that swap keeps the count unchanged.
                    .animation(
                        GlassTheme.motion(GlassTheme.quickSpring, reduceMotion: reduceMotion),
                        value: state.documents.map(\.id))
                }
                .scrollIndicators(.never)

                Spacer(minLength: GlassTheme.Spacing.tight)
                paneControls
            }
        }
        .padding(.horizontal, GlassTheme.Spacing.snug)
        .padding(.vertical, GlassTheme.Spacing.tight)
        // The focused pane is brighter; without a cue, a multi-pane window
        // gives no clue where typing will land.
        .opacity(isFocused ? 1 : 0.62)
        .animation(
            GlassTheme.motion(GlassTheme.quickSpring, reduceMotion: reduceMotion),
            value: isFocused)
    }

    /// Split and close for this pane.
    ///
    /// Close appears only once there is a split: offering it beside the last
    /// pane advertises something the layout refuses to do.
    private var paneControls: some View {
        HStack(spacing: GlassTheme.Spacing.hairline) {
            ForEach([SplitEdge.trailing, .bottom], id: \.self) { edge in
                PaneControl(
                    symbol: edge.symbol,
                    label: edge.commandTitle,
                    help: edge.controlHelp,
                    reduceMotion: reduceMotion,
                    action: { onSplit(edge) })
            }

            if isSplit {
                Divider().frame(height: 12).opacity(0.4)

                PaneControl(
                    symbol: "xmark",
                    label: "Close Pane",
                    help: "Close this pane (⌃⌘W) — its tabs close with it",
                    reduceMotion: reduceMotion,
                    action: onClosePane)
            }
        }
        .padding(.horizontal, GlassTheme.Spacing.tight)
        .padding(.vertical, 3)
        .glassEffect(.regular.interactive(), in: .capsule)
        .animation(
            GlassTheme.motion(GlassTheme.quickSpring, reduceMotion: reduceMotion),
            value: isSplit)
    }
}

/// One pane control: a glyph with a real hit target under it.
///
/// The glyphs used to be bare `Image`s inside a shared capsule, which made the
/// tappable area the glyph itself — around 9pt of ink for a control sitting
/// beside a scrolling tab strip. The padding here is the target; the
/// background only appears under the pointer.
private struct PaneControl: View {
    let symbol: String
    /// The control's name, spoken by VoiceOver and matching the menu item.
    let label: String
    /// The tooltip, and the spoken hint behind the name.
    let help: String
    let reduceMotion: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption)
                .frame(width: 15, height: 15)
                .padding(4)
                .foregroundStyle(.secondary)
                .background {
                    Circle().fill(isHovering ? Color.primary.opacity(0.12) : .clear)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityHint(help)
        .onHover { isHovering = $0 }
        .animation(
            GlassTheme.motion(GlassTheme.quickSpring, reduceMotion: reduceMotion),
            value: isHovering)
    }
}

/// A single tab.
///
/// A real button, with its position spoken ("tab 2 of 5") and closing
/// reachable three ways without the pointer: the hover-only ✕ is invisible
/// to VoiceOver, so the chip carries a Close accessibility action, a context
/// menu, and — as every Mac browser teaches — a middle-click.
private struct TabChip: View {
    let document: OpenDocument
    let isCurrent: Bool
    /// One-based position in the strip, for the spoken label.
    let position: Int
    let tabCount: Int
    let showClose: Bool
    let reduceMotion: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: GlassTheme.Spacing.tight) {
            Text(document.title)
                .font(.caption)
                .lineLimit(1)

            if document.hasUnsavedChanges {
                // A dot, not a close button that turns into a dot on hover:
                // unsaved state should never be ambiguous.
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel("Unsaved changes")
            }

            if showClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        // The glyph is tiny; the target around it should not
                        // be, or closing a tab becomes a game of aim. The
                        // frame and shape are inside the label, which is what
                        // makes them count towards the hit region at all.
                        .frame(width: 12, height: 12)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                // Faded rather than absent when idle: an absent control is
                // absent from the accessibility tree too, which left every
                // background tab unclosable by anything but the pointer.
                .opacity(isHovering || isCurrent ? 1 : 0)
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel("Close \(document.title)")
            }
        }
        .padding(.horizontal, GlassTheme.Spacing.snug)
        .padding(.vertical, 5)
        .glassEffect(
            isCurrent ? .regular.tint(.accentColor.opacity(0.28)).interactive() : .regular,
            in: .capsule
        )
        .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
        // Selecting a tab must work anywhere on the chip, including the gap
        // beside a short title, not only on the glyphs the tap lands on.
        .contentShape(.capsule)
        // A hovered tab lifts slightly, so a strip of similar capsules says
        // which one the pointer is actually on before it is clicked.
        .scaleEffect(isHovering && !isCurrent ? 1.04 : 1)
        .onHover { isHovering = $0 }
        .onTapGesture(perform: onSelect)
        .animation(
            GlassTheme.motion(GlassTheme.quickSpring, reduceMotion: reduceMotion),
            value: isHovering)
        .animation(
            GlassTheme.motion(GlassTheme.quickSpring, reduceMotion: reduceMotion),
            value: isCurrent)
        .animation(
            GlassTheme.motion(GlassTheme.quickSpring, reduceMotion: reduceMotion),
            value: document.hasUnsavedChanges)
        .contextMenu { tabMenu }
        .modifier(MiddleClickCatcher(action: onClose))
        // One accessible element: activation selects, the named action closes
        // — which is how a keyboard or screen-reader reader reaches a
        // background tab's close that the pointer-only ✕ used to hide.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(document.title), tab \(position) of \(tabCount)")
        .accessibilityHint(isCurrent ? "Current tab" : "Activates this tab")
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : [.isButton])
        .accessibilityAction(named: "Close Tab") { onClose() }
    }

    @ViewBuilder
    private var tabMenu: some View {
        Button("Close Tab") { onClose() }
        if document.url != nil {
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    document.url?.path ?? "", forType: .string)
            }
            Button("Reveal in Finder") {
                if let url = document.url {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
    }
}


/// Closes (or otherwise acts) on a middle-click over `content`.
///
/// One *shared* window monitor serves every catcher: N monitors for N tabs
/// meant every middle-click in the app walked a list that grew with open
/// tabs, and each carried its own lifetime to get wrong. The dispatcher owns
/// the single monitor per window; catchers only register frames.
struct MiddleClickCatcher: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        content.overlay(MiddleClickRepresentable(action: action))
    }
}

/// Bridges ``MiddleClickView`` into SwiftUI.
struct MiddleClickRepresentable: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> MiddleClickView {
        MiddleClickView(action: action)
    }

    func updateNSView(_ nsView: MiddleClickView, context: Context) {}
}

/// A registered region and what a middle-click there should do.
struct MiddleClickTarget {
    weak var view: MiddleClickView?
    let action: () -> Void
}

/// The AppKit half of ``MiddleClickCatcher``.
///
/// The view itself is hit-test transparent — it exists so SwiftUI gives it
/// a frame inside the right chip. Registration with the shared
/// ``MiddleClickDispatcher`` is keyed on window attachment, which is also
/// where unregistration happens, so a tab strip torn down mid-session
/// cannot leave ghosts behind.
final class MiddleClickView: NSView {
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Never in the responder chain; the dispatcher is what sees middle
        // clicks, and nothing here can swallow a left click.
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let attached = window != nil
        let registerSelf = { [weak self] in
            guard let self else { return }
            if attached {
                MiddleClickDispatcher.shared.register(self, action: self.action)
            } else {
                MiddleClickDispatcher.shared.unregister(self)
            }
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated { registerSelf() }
        } else {
            DispatchQueue.main.async(execute: registerSelf)
        }
    }
}

/// One local event monitor per window, dispatching middle-clicks by frame.
@MainActor
final class MiddleClickDispatcher {
    static let shared = MiddleClickDispatcher()

    private var targets: [ObjectIdentifier: MiddleClickTarget] = [:]
    private var monitors: [ObjectIdentifier: Any] = [:]  // keyed by window
    private var observers: [ObjectIdentifier: NSObjectProtocol] = [:]

    func register(_ view: MiddleClickView, action: @escaping () -> Void) {
        targets[ObjectIdentifier(view)] = MiddleClickTarget(view: view, action: action)
        if let window = view.window { installMonitor(for: window) }
    }

    func unregister(_ view: MiddleClickView) {
        targets.removeValue(forKey: ObjectIdentifier(view))
        prune()
    }

    /// Whether `location` (in `window` coordinates) hits a target, running
    /// its action if so.
    ///
    /// Split out from the monitor closure because it is the entire decision:
    /// containment, window match, and first-registered-wins on overlap are
    /// all assertable without synthesising an NSEvent.
    @discardableResult
    func dispatch(locationInWindow point: NSPoint, window: NSWindow?) -> Bool {
        prune()
        guard let window else { return false }
        for (_, target) in targets.sorted(by: { $0.key < $1.key }) {
            guard let view = target.view, view.window === window else { continue }
            let local = view.convert(point, from: nil)
            if view.bounds.contains(local) {
                target.action()
                return true
            }
        }
        return false
    }

    #if DEBUG
        var targetCount: Int {
            prune()
            return targets.count
        }

        var monitorCount: Int { monitors.count }
        var observerCount: Int { observers.count }

        func removeAllForTesting() {
            for (_, monitor) in monitors { NSEvent.removeMonitor(monitor) }
            monitors.removeAll()
            for (_, observer) in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            observers.removeAll()
            targets.removeAll()
        }
    #endif

    /// Drops entries whose view has left the hierarchy. Weak refs alone are
    /// not enough: the object can still be alive while no longer on screen.
    private func prune() {
        targets = targets.filter { entry in
            guard let view = entry.value.view else { return false }
            return view.window != nil
        }
    }

    private func installMonitor(for window: NSWindow) {
        let key = ObjectIdentifier(window)
        guard monitors[key] == nil else { return }
        monitors[key] = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) {
            [weak self, weak window] event in
            guard event.buttonNumber == 2 else { return event }
            guard let self, let window, event.window === window else { return event }
            if self.dispatch(locationInWindow: event.locationInWindow, window: window) {
                return nil  // consumed
            }
            return event
        }
        // Windows do not outlive their content here; when one goes, drop its
        // monitor *and this observer*, which would otherwise outlive both.
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] note in
            guard let closing = note.object as? NSWindow else { return }
            let key = ObjectIdentifier(closing)
            if let monitor = self?.monitors.removeValue(forKey: key) {
                NSEvent.removeMonitor(monitor)
            }
            if let ownObserver = self?.observers.removeValue(forKey: key) {
                NotificationCenter.default.removeObserver(ownObserver)
            }
        }
        observers[key] = observer
    }
}
