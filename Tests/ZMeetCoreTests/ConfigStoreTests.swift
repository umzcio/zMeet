import Foundation
import Testing
@testable import ZMeetCore

@Test func roundTripPreservesConfig() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("zmeet-config-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    let store = ConfigStore(home: home)
    var config = try store.bootstrap()
    config.audioRetentionDays = 30
    try store.write(config)

    let loaded = try store.load()
    #expect(loaded == config)
}

@Test func oldSchemaConfigStillLoads() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("zmeet-config-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    let store = ConfigStore(home: home)
    try FileManager.default.createDirectory(at: store.configDirectory, withIntermediateDirectories: true)
    let fixture = """
    {"outputPath": "\(home.path)/out", "appDataPath": "\(home.path)/.zmeet"}
    """
    try fixture.data(using: .utf8)!.write(to: store.configURL)

    let config = try store.load()
    #expect(config.detectMeetings == true)
    #expect(config.publishToObsidian == false)
    #expect(config.profiles[.inPerson].captureSystemAudio == false)
}

@Test func legacyProfileMigration() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("zmeet-config-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    let store = ConfigStore(home: home)
    try FileManager.default.createDirectory(at: store.configDirectory, withIntermediateDirectories: true)
    let fixture = """
    {
        "outputPath": "\(home.path)/out",
        "appDataPath": "\(home.path)/.zmeet",
        "noiseSuppression": true,
        "audio": {"micGain": 2.0}
    }
    """
    try fixture.data(using: .utf8)!.write(to: store.configURL)

    let config = try store.load()
    #expect(config.profiles[.remote].noiseSuppression == true)
    #expect(config.profiles[.remote].micGain == 2.0)
    #expect(config.profiles[.inPerson].captureSystemAudio == false)
}

@Test func corruptConfigIsBackedUpNotClobbered() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("zmeet-config-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    let store = ConfigStore(home: home)
    try FileManager.default.createDirectory(at: store.configDirectory, withIntermediateDirectories: true)
    let corruptBytes = "{not json".data(using: .utf8)!
    try corruptBytes.write(to: store.configURL)

    let outcome = store.loadOrBackupAndBootstrap()
    guard case .bootstrapped(_, let backup) = outcome else {
        Issue.record("expected .bootstrapped outcome")
        return
    }
    let backupURL = try #require(backup)
    let backedUpBytes = try Data(contentsOf: backupURL)
    #expect(backedUpBytes == corruptBytes)

    let reloaded = try store.load()
    #expect(reloaded == ZMeetConfig.default(home: home))
}

@Test func missingConfigBootstrapsWithoutBackup() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("zmeet-config-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    let store = ConfigStore(home: home)

    let outcome = store.loadOrBackupAndBootstrap()
    guard case .bootstrapped(_, let backup) = outcome else {
        Issue.record("expected .bootstrapped outcome")
        return
    }
    #expect(backup == nil)

    let contents = (try? FileManager.default.contentsOfDirectory(atPath: store.configDirectory.path)) ?? []
    #expect(contents.contains { $0.contains(".bak-") } == false)
}
