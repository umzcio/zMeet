import SwiftUI
import AppKit

/// Reports right-clicks (and ⌃-clicks) within a SwiftUI view's bounds without
/// disturbing left-clicks. SwiftUI has no secondary-click gesture, and an NSView
/// hitTest overlay doesn't reliably receive right-clicks inside SwiftUI, so this
/// uses a local NSEvent monitor scoped to the view's window + bounds.
struct RightClickCatcher: NSViewRepresentable {
    let onRightClick: () -> Void

    func makeNSView(context: Context) -> NSView { CatcherView(onRightClick: onRightClick) }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CatcherView)?.onRightClick = onRightClick
    }

    final class CatcherView: NSView {
        var onRightClick: () -> Void
        private var monitor: Any?

        init(onRightClick: @escaping () -> Void) {
            self.onRightClick = onRightClick
            super.init(frame: .zero)
        }
        @available(*, unavailable) required init?(coder: NSCoder) { nil }

        // Cleanup happens here (not deinit) when the view leaves its window —
        // a nonisolated deinit can't touch the non-Sendable monitor under Swift 6.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                // Only secondary clicks: right-button, or control-held left-button.
                let isSecondary = event.type == .rightMouseDown
                    || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
                guard isSecondary else { return event }
                // Only when the click falls inside this row's bounds.
                let pointInView = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(pointInView) else { return event }
                self.onRightClick()
                return nil  // consume the event
            }
        }
    }
}
