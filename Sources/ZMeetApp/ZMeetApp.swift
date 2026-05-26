import SwiftUI

@main
struct ZMeetApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(state: state)
        } label: {
            Image(systemName: state.isRecording ? "record.circle.fill" : "mic")
        }
        .menuBarExtraStyle(.window)
    }
}
