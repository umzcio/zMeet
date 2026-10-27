import Foundation

/// One-time carry-over from zMeet's former bundle ID. macOS keys settings and
/// Keychain items by bundle ID, so without this an update to the new ID would
/// re-run onboarding, forget Sparkle choices and lose the stored API keys.
public enum LegacyIdentityMigration {
    /// The bundle ID (and Keychain service) zMeet used through v1.18.x.
    public static let legacyBundleID = "edu.umontana.zmeet"
    static let migratedKey = "zmeet.migratedFromLegacyBundleID"
    /// Never carried over: a feed override (testing) would pin the new app to it.
    static let excludedKeys: Set<String> = ["SUFeedURL"]

    /// Copies each legacy setting the current domain doesn't have, once.
    /// Returns true only when this run carried settings over (an upgrade), so
    /// the caller can tell the user what still needs their attention.
    public static func migrateDefaults(legacy: [String: Any]?, into defaults: UserDefaults) -> Bool {
        guard !defaults.bool(forKey: migratedKey) else { return false }
        defaults.set(true, forKey: migratedKey)
        guard let legacy, !legacy.isEmpty else { return false }
        for (key, value) in legacy where defaults.object(forKey: key) == nil && !excludedKeys.contains(key) {
            defaults.set(value, forKey: key)
        }
        return true
    }
}

/// Reads through to a legacy store: a secret found only there is moved to the
/// primary store on first read (and removed from the legacy one only once that
/// write succeeds). Writes go to the primary store; deletes clear both.
public struct MigratingSecretStore: SecretStore {
    let primary: SecretStore
    let legacy: SecretStore

    public init(primary: SecretStore, legacy: SecretStore) {
        self.primary = primary
        self.legacy = legacy
    }

    public func read(account: String) -> String? {
        if let value = primary.read(account: account) { return value }
        guard let value = legacy.read(account: account) else { return nil }
        if (try? primary.write(value, account: account)) != nil {
            try? legacy.delete(account: account)
        }
        return value
    }

    public func write(_ value: String, account: String) throws {
        try primary.write(value, account: account)
    }

    public func delete(account: String) throws {
        try primary.delete(account: account)
        try? legacy.delete(account: account)
    }
}
