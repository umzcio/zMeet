import Foundation
import Testing
@testable import ZMeetCore

@Test func recordingModeHasThreeCases() {
    #expect(RecordingMode(rawValue: "remote") == .remote)
    #expect(RecordingMode(rawValue: "hybrid") == .hybrid)
    #expect(RecordingMode(rawValue: "inPerson") == .inPerson)
}

@Test func captureProfileDefaultsPerMode() {
    let remote = CaptureProfile.default(for: .remote)
    #expect(remote.captureSystemAudio == true)
    #expect(remote.micGain == 1.0)
    #expect(remote.noiseSuppression == true)

    let hybrid = CaptureProfile.default(for: .hybrid)
    #expect(hybrid.captureSystemAudio == true)
    #expect(hybrid.micGain == 2.0)
    #expect(hybrid.noiseSuppression == true)

    let inPerson = CaptureProfile.default(for: .inPerson)
    #expect(inPerson.captureSystemAudio == false)
    #expect(inPerson.micGain == 2.0)
    #expect(inPerson.noiseSuppression == false)
}

@Test func captureProfileRoundTrips() throws {
    let p = CaptureProfile(captureSystemAudio: false, micDeviceID: "dev-1", micGain: 4.0, noiseSuppression: true)
    let data = try JSONEncoder.zmeet.encode(p)
    let decoded = try JSONDecoder.zmeet.decode(CaptureProfile.self, from: data)
    #expect(decoded == p)
}
