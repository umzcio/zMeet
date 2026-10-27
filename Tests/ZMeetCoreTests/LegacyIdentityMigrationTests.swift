import Foundation
import Testing
@testable import ZMeetCore

/// A fresh, isolated defaults domain per test.
private func scratchDefaults() -> UserDefaults {
    let name = "zmeet.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

private final class MemoryStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String]
    var failWrites = false
    init(_ items: [String: String] = [:]) { self.items = items }
    func read(account: String) -> String? { lock.withLock { items[account] } }
    func write(_ value: String, account: String) throws {
        struct WriteFailed: Error {}
        if failWrites { throw WriteFailed() }
        lock.withLock { items[account] = value }
    }
    func delete(account: String) throws { lock.withLock { items[account] = nil } }
}

// MARK: - Settings

@Test func legacySettingsTheNewDomainLacksAreCopied() {
    let current = scratchDefaults()
    current.set(2, forKey: "X")
    let ran = LegacyIdentityMigration.migrateDefaults(
        legacy: ["zmeet.onboarding.completed": true, "SUEnableAutomaticChecks": false, "X": 1], into: current)
    #expect(ran)
    #expect(current.bool(forKey: "zmeet.onboarding.completed"))
    #expect(current.object(forKey: "SUEnableAutomaticChecks") as? Bool == false)
    #expect(current.integer(forKey: "X") == 2)   // never overwrites the new domain
}

@Test func settingsMigrateOnlyOnce() {
    let current = scratchDefaults()
    #expect(LegacyIdentityMigration.migrateDefaults(legacy: ["A": 1], into: current))
    current.set(5, forKey: "A")
    #expect(!LegacyIdentityMigration.migrateDefaults(legacy: ["A": 1, "B": 2], into: current))
    #expect(current.integer(forKey: "A") == 5)
    #expect(current.object(forKey: "B") == nil)
}

@Test func noLegacySettingsIsNotAMigration() {
    let current = scratchDefaults()
    #expect(!LegacyIdentityMigration.migrateDefaults(legacy: nil, into: current))
    #expect(!LegacyIdentityMigration.migrateDefaults(legacy: [:], into: current))
}

// MARK: - Secrets

@Test func primarySecretWins() {
    let store = MigratingSecretStore(primary: MemoryStore(["k": "new"]), legacy: MemoryStore(["k": "old"]))
    #expect(store.read(account: "k") == "new")
}

@Test func legacySecretIsCopiedToPrimaryOnFirstRead() {
    // Copied, not moved: an older zMeet still installed (or a downgrade) keeps
    // working. Deleting the key in the app clears both.
    let primary = MemoryStore(), legacy = MemoryStore(["k": "old"])
    let store = MigratingSecretStore(primary: primary, legacy: legacy)
    #expect(store.read(account: "k") == "old")
    #expect(primary.read(account: "k") == "old")
    #expect(legacy.read(account: "k") == "old")
}

@Test func failedMoveKeepsTheLegacySecret() {
    let primary = MemoryStore(), legacy = MemoryStore(["k": "old"])
    primary.failWrites = true
    let store = MigratingSecretStore(primary: primary, legacy: legacy)
    #expect(store.read(account: "k") == "old")
    #expect(legacy.read(account: "k") == "old")
}

@Test func missingSecretIsNil() {
    #expect(MigratingSecretStore(primary: MemoryStore(), legacy: MemoryStore()).read(account: "k") == nil)
}

@Test func writesGoToPrimaryAndDeletesClearBoth() throws {
    let primary = MemoryStore(), legacy = MemoryStore(["k": "old"])
    let store = MigratingSecretStore(primary: primary, legacy: legacy)
    try store.write("v", account: "j")
    #expect(primary.read(account: "j") == "v")
    #expect(legacy.read(account: "j") == nil)
    try store.delete(account: "k")
    #expect(legacy.read(account: "k") == nil)
}

@Test func aLegacyFeedOverrideIsNotCarriedOver() {
    // A SUFeedURL left in the old domain (a testing override) would pin the new
    // app to that feed forever; updates must come from its Info.plist feed.
    let current = scratchDefaults()
    _ = LegacyIdentityMigration.migrateDefaults(legacy: ["SUFeedURL": "http://127.0.0.1/appcast.xml", "A": 1], into: current)
    #expect(current.object(forKey: "SUFeedURL") == nil)
    #expect(current.integer(forKey: "A") == 1)
}
