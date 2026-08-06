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

@Test func unreadableConfigLeftUntouched() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("zmeet-config-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    let store = ConfigStore(home: home)
    try FileManager.default.createDirectory(at: store.configDirectory, withIntermediateDirectories: true)
    let originalBytes = "{\"outputPath\": \"\(home.path)/out\", \"appDataPath\": \"\(home.path)/.zmeet\"}".data(using: .utf8)!
    try originalBytes.write(to: store.configURL)

    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.configURL.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.configURL.path) }

    let outcome = store.loadOrBackupAndBootstrap()
    guard case .loadFailedLeftUntouched = outcome else {
        Issue.record("expected .loadFailedLeftUntouched outcome, got \(outcome)")
        return
    }

    #expect(FileManager.default.fileExists(atPath: store.configURL.path))
    let contents = (try? FileManager.default.contentsOfDirectory(atPath: store.configDirectory.path)) ?? []
    #expect(contents.contains { $0.contains(".bak-") } == false)

    // Content unchanged: restore perms to read it back and compare.
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.configURL.path)
    let unchangedBytes = try Data(contentsOf: store.configURL)
    #expect(unchangedBytes == originalBytes)
}

@Test func corruptConfigWithReadOnlyDirectoryLeftUntouched() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("zmeet-config-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    let store = ConfigStore(home: home)
    try FileManager.default.createDirectory(at: store.configDirectory, withIntermediateDirectories: true)
    let corruptBytes = "{not json".data(using: .utf8)!
    try corruptBytes.write(to: store.configURL)

    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: store.configDirectory.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: store.configDirectory.path) }

    let outcome = store.loadOrBackupAndBootstrap()
    guard case .loadFailedLeftUntouched = outcome else {
        Issue.record("expected .loadFailedLeftUntouched outcome, got \(outcome)")
        return
    }

    #expect(FileManager.default.fileExists(atPath: store.configURL.path))
    let contents = (try? FileManager.default.contentsOfDirectory(atPath: store.configDirectory.path)) ?? []
    #expect(contents.contains { $0.contains(".bak-") } == false)

    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: store.configDirectory.path)
    let unchangedBytes = try Data(contentsOf: store.configURL)
    #expect(unchangedBytes == corruptBytes)
}

/// Permission 036: `write()` must leave `config.json` owner-only (0600) and
/// `~/.zmeet` owner-only (0700) — config holds the output/app-data paths and
/// (via the vault path) hints at the user's Obsidian setup.
@Test func writeRestrictsConfigFilePermissions() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("zmeet-config-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    let store = ConfigStore(home: home)
    let config = try store.bootstrap()
    try store.write(config)

    let configPerms = (try? FileManager.default.attributesOfItem(atPath: store.configURL.path))?[.posixPermissions] as? Int
    #expect(configPerms == 0o600)
    let dirPerms = (try? FileManager.default.attributesOfItem(atPath: store.configDirectory.path))?[.posixPermissions] as? Int
    #expect(dirPerms == 0o700)
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
