import SwiftUI

@main
struct ZMeetApp: App {
    @StateObject private var state = AppState(recorder: SCKAudioRecorder())

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(state: state)
        } label: {
            Image(nsImage: MenuBarIcon.image(recording: state.isRecording))
        }
        .menuBarExtraStyle(.window)
    }
}
