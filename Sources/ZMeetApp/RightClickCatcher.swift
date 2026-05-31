import SwiftUI
import AppKit

/// A transparent overlay that reports right-clicks (and ⌃-clicks) while letting
/// normal left-clicks fall through to the SwiftUI view beneath. SwiftUI has no
/// secondary-click gesture, so this bridges to AppKit.
struct RightClickCatcher: NSViewRepresentable {
    let onRightClick: () -> Void

    func makeNSView(context: Context) -> NSView { CatcherView(onRightClick: onRightClick) }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CatcherView)?.onRightClick = onRightClick
    }

    final class CatcherView: NSView {
        var onRightClick: () -> Void
        init(onRightClick: @escaping () -> Void) {
            self.onRightClick = onRightClick
            super.init(frame: .zero)
        }
        @available(*, unavailable) required init?(coder: NSCoder) { nil }

        /// Claim the hit only for secondary clicks; pass everything else through
        /// (return nil) so the SwiftUI row button still gets left-clicks.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let isSecondary = event.type == .rightMouseDown
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return isSecondary ? self : nil
        }

        override func rightMouseDown(with event: NSEvent) { onRightClick() }
        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { onRightClick() }
            else { super.mouseDown(with: event) }
        }
    }
}
