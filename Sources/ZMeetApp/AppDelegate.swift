import AppKit
import ZMeetCore

/// Owns the app's single AppState and its menu-bar presence. AppState lives here
/// (not in a SwiftUI scene) because every zMeet surface is AppKit-hosted: the
/// status item, its popover, and the Library/Settings/Setup windows.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Carries settings over from the old bundle ID. Declared before `state` so
    /// it runs first: AppState reads them (onboarding, Sparkle) as it starts.
    private let movedFromLegacyIdentity: Bool = {
        let legacy = LegacyIdentityMigration.legacyBundleID
        guard Bundle.main.bundleIdentifier != legacy else { return false }
        return LegacyIdentityMigration.migrateDefaults(
            legacy: UserDefaults.standard.persistentDomain(forName: legacy), into: .standard)
    }()
    let state = AppState(recorder: SCKAudioRecorder())
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController = StatusItemController(state: state)
        if movedFromLegacyIdentity { state.announceIdentityMove() }
    }
}
