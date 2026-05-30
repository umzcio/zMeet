import AppKit

/// An NSWindow that closes when the user presses Esc (the standard "cancel"
/// gesture). Plain NSWindows ignore Esc unless something in the responder chain
/// handles `cancelOperation`.
final class EscClosableWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        close()
    }
}
