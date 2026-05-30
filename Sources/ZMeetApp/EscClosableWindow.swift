import AppKit

/// An NSWindow that closes when the user presses Esc (the standard "cancel"
/// gesture). Plain NSWindows ignore Esc unless something in the responder chain
/// handles `cancelOperation`.
///
/// `onEsc` lets the owner intercept first: return `true` if Esc was consumed
/// (e.g. an in-app dialog was dismissed) so the window should stay open.
final class EscClosableWindow: NSWindow {
    var onEsc: (() -> Bool)?

    override func cancelOperation(_ sender: Any?) {
        if onEsc?() == true { return }
        close()
    }
}
