import AppKit
import Combine
import SwiftUI
import ZMeetCore

/// Closes the menu-bar popover. A struct (like SwiftUI's own `DismissAction`)
/// rather than a bare closure: closures aren't comparable, so storing one in the
/// environment would invalidate every reader on every update. It's set once per
/// popover and never swapped, so all instances compare equal.
struct MenuBarPopoverCloser: Equatable {
    let close: @MainActor () -> Void
    static func == (lhs: Self, rhs: Self) -> Bool { true }
    @MainActor func callAsFunction() { close() }
}

extension EnvironmentValues {
    /// Injected by StatusItemController; the default no-op keeps previews and any
    /// other host safe.
    @Entry var closeMenuBarPopover = MenuBarPopoverCloser(close: {})
}

/// Owns zMeet's menu-bar presence: the status item (icon) and the popover that a
/// click toggles. Replaces SwiftUI's MenuBarExtra, which can't tell a right-click
/// from a left-click.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let state: AppState
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    /// When the popover last began closing — feeds StatusPopoverToggle so the
    /// click that closed a transient popover doesn't immediately reopen it.
    private var lastPopoverClose: Date?
    private var iconSubscription: AnyCancellable?

    init(state: AppState) {
        self.state = state
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        // macOS remembers the icon's menu-bar position under this name.
        statusItem.autosaveName = "zMeetStatusItem"
        configurePopover()
        configureButton()
        observeIconState()
    }

    private func configurePopover() {
        popover.behavior = .transient   // closes on an outside click
        popover.animates = true
        popover.delegate = self
        let root = MenuContentView(state: state)
            .environment(\.closeMenuBarPopover, MenuBarPopoverCloser { [weak self] in
                self?.popover.performClose(nil)
            })
        let host = NSHostingController(rootView: root)
        // Track SwiftUI's size so the popover grows/shrinks as rows come and go
        // (detected-meeting row, processing row, notices).
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// Resolve the icon from the EMITTED values: `@Published` fires in `willSet`,
    /// so reading `state.iconState` inside this sink would draw the previous state.
    private func observeIconState() {
        iconSubscription = Publishers.CombineLatest3(state.$phase, state.$meetingTracker, state.$processing)
            .sink { [weak self] phase, tracker, processing in
                let icon = StatusIconState.resolve(
                    isRecording: phase != .idle,
                    meetingDetected: tracker.current != nil,
                    isProcessing: processing.isAnyVisiblyProcessing)
                // AppState is @MainActor, so its @Published values only ever
                // change — and emit — on the main thread.
                MainActor.assumeIsolated { self?.render(icon) }
            }
    }

    private func render(_ icon: StatusIconState) {
        guard let button = statusItem.button else { return }
        let description = MenuBarIcon.accessibilityDescription(for: icon)
        button.image = MenuBarIcon.image(for: icon)
        button.toolTip = description
        button.setAccessibilityLabel(description)
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        togglePopover()
    }

    private func togglePopover() {
        switch StatusPopoverToggle.action(isShown: popover.isShown, lastClosedAt: lastPopoverClose, now: Date()) {
        case .close: popover.performClose(nil)
        case .ignore: break
        case .open: showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        state.refreshPermissions()
        // An accessory app must activate, and the popover must become key, or
        // typing in the title field goes to the previously frontmost app.
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    // MARK: NSPopoverDelegate

    func popoverWillClose(_ notification: Notification) {
        lastPopoverClose = Date()
    }
}
