import AppKit

/// Owns the app's single AppState and its menu-bar presence. AppState lives here
/// (not in a SwiftUI scene) because every zMeet surface is AppKit-hosted: the
/// status item, its popover, and the Library/Settings/Setup windows.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState(recorder: SCKAudioRecorder())
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController = StatusItemController(state: state)
    }
}
