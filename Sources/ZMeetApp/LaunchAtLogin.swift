import Foundation
import ServiceManagement

/// Thin wrapper over SMAppService for the "Launch at login" toggle.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("zMeet: launch-at-login \(enabled ? "register" : "unregister") failed: \(error)")
        }
    }
}
