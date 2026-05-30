import AVFoundation

/// Enumerates available microphone input devices for the Settings picker.
enum AudioInputs {
    struct Device: Identifiable, Hashable {
        let id: String      // AVCaptureDevice.uniqueID (also accepted by SCStreamConfiguration.microphoneCaptureDeviceID)
        let name: String
    }

    static func available() -> [Device] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return session.devices.map { Device(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// Name for a stored device id (falls back to "System Default" / "Unknown").
    static func name(forID id: String?) -> String {
        guard let id else { return "System Default" }
        return available().first(where: { $0.id == id })?.name ?? "Unknown device"
    }
}
