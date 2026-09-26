import SwiftUI

@main
struct ZMeetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // zMeet lives in the menu bar (StatusItemController, created by AppDelegate).
        // SwiftUI still needs one scene: this empty Settings scene exists only so the
        // App lifecycle keeps providing the default main menu — Edit ⌘C/⌘V/⌘A in text
        // fields and Quit — whenever a window makes the app `.regular`. Its Settings
        // command is replaced so "Settings…" / ⌘, opens the real Settings window,
        // never this empty one.
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { appDelegate.state.openSettings() }
                        .keyboardShortcut(",")
                }
            }
    }
}
