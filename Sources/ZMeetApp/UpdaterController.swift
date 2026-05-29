import Foundation
import Combine
import Sparkle

/// Wraps Sparkle's updater. Auto-checks on a schedule and exposes a manual
/// "Check for Updates…" action. The feed URL + EdDSA public key live in
/// Info.plist (SUFeedURL / SUPublicEDKey), set by the build script.
@MainActor
final class UpdaterController: ObservableObject {
    private let controller: SPUStandardUpdaterController

    /// Whether a manual check can run right now (drives menu enable state).
    @Published var canCheck: Bool = true

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheck)
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}
