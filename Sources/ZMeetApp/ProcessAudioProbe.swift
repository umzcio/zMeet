import CoreAudio
import Foundation

/// Detects whether a known meeting app (Teams / Zoom) is currently moving audio, via
/// macOS 14.4+ Core Audio per-process state. This is the reliable "you're in a call"
/// signal — present once admitted, gone when the call ends, and (per Core Audio)
/// unaffected by mute. Reading these properties needs no extra permission. zMeet's own
/// capture doesn't pollute it: we query the *meeting app's* process, not the device.
struct ProcessAudioProbe {
    /// bundle-ID prefix → human app name. Teams audio runs in `.helper` processes, so
    /// prefix matching catches them; Zoom is `us.zoom.xos` and helpers.
    private static let meetingApps: [(prefix: String, name: String)] = [
        ("com.microsoft.teams", "Microsoft Teams"),
        ("us.zoom", "Zoom"),
    ]

    /// The human name of a meeting app currently running audio IO (input or output),
    /// or nil if none is. If several match, returns the first.
    func activeMeetingApp() -> String? {
        for object in Self.processObjectList() {
            guard let bundle = Self.stringProperty(object, kAudioProcessPropertyBundleID),
                  let app = Self.meetingApps.first(where: { bundle.hasPrefix($0.prefix) })?.name
            else { continue }
            let input = Self.boolProperty(object, kAudioProcessPropertyIsRunningInput) ?? false
            let output = Self.boolProperty(object, kAudioProcessPropertyIsRunningOutput) ?? false
            if input || output { return app }
        }
        return nil
    }

    // MARK: Core Audio plumbing

    private static var systemObject: AudioObjectID { AudioObjectID(kAudioObjectSystemObject) }

    private static func processObjectList() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func boolProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }
}
