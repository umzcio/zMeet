import AVFoundation
import CoreGraphics
import AppKit
import Speech

enum Permissions {
    /// Microphone: returns true if authorized, requesting access if undetermined.
    static func ensureMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    static func microphoneAuthorized() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    // MARK: Speech Recognition

    static func speechAuthorized() -> Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    /// Speech Recognition: returns true if authorized, requesting if undetermined.
    static func ensureSpeech() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { status in
                    cont.resume(returning: status == .authorized)
                }
            }
        default:
            return false
        }
    }

    /// Whether the OS will only offer a deep-link (status already decided), used
    /// by onboarding to switch the button between "Grant" and "Open Settings".
    static func speechNeedsSettings() -> Bool {
        let s = SFSpeechRecognizer.authorizationStatus()
        return s == .denied || s == .restricted
    }

    static func micNeedsSettings() -> Bool {
        let s = AVCaptureDevice.authorizationStatus(for: .audio)
        return s == .denied || s == .restricted
    }

    static func openMicrophoneSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }

    static func openSpeechSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")!
        NSWorkspace.shared.open(url)
    }

    /// Screen Recording (required by ScreenCaptureKit even for audio-only).
    static func hasScreenRecording() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }
}
