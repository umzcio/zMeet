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

@Test func profilesSubscriptGetsAndSets() {
    var profiles = CaptureProfiles.defaults()
    #expect(profiles[.inPerson].captureSystemAudio == false)
    profiles[.inPerson].micGain = 4.0
    #expect(profiles[.inPerson].micGain == 4.0)
    #expect(profiles[.remote].micGain == 1.0)  // others untouched
}

@Test func configProfilesRoundTripAndAccessor() throws {
    var config = ZMeetConfig.default(outputPath: "/tmp/zmeet-output")
    config.profiles[.hybrid].micGain = 4.0
    let data = try JSONEncoder.zmeet.encode(config)
    let decoded = try JSONDecoder.zmeet.decode(ZMeetConfig.self, from: data)
    #expect(decoded.profiles[.hybrid].micGain == 4.0)
    #expect(decoded.profile(for: .hybrid).micGain == 4.0)
}

@Test func legacyConfigMigratesGlobalsIntoProfiles() throws {
    let legacy = """
    {
      "outputPath": "/tmp/out",
      "appDataPath": "/tmp/data",
      "audio": { "captureSystemAudio": true, "captureMicrophone": true, "sampleRate": 48000, "bitrate": 128000, "micDeviceID": "dev-x", "micGain": 2.0 },
      "gitAutoCommit": false,
      "autoProcessOnStop": false,
      "noiseSuppression": true,
      "recordingMode": "remote"
    }
    """.data(using: .utf8)!
    let decoded = try JSONDecoder.zmeet.decode(ZMeetConfig.self, from: legacy)
    #expect(decoded.profiles[.remote].captureSystemAudio == true)
    #expect(decoded.profiles[.inPerson].captureSystemAudio == false)
    #expect(decoded.profiles[.remote].micGain == 2.0)
    #expect(decoded.profiles[.remote].micDeviceID == "dev-x")
    #expect(decoded.profiles[.inPerson].noiseSuppression == true)
}
