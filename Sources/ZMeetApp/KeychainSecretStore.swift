import Foundation
import Security
import ZMeetCore

/// Stores zMeet secrets (currently the Anthropic API key) in the macOS Keychain.
/// The only place the key is persisted — never in config.json, logs, or git.
struct KeychainSecretStore: SecretStore {
    private let service = "edu.umontana.zmeet"

    private func baseQuery(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func read(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    func write(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        // Update in place first — the existing (working) item must never be
        // destroyed by a failed write. Add only when no item exists yet.
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(baseQuery(account: account) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var attrs = baseQuery(account: account)
            attrs[kSecValueData as String] = data
            attrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            attrs[kSecAttrSynchronizable as String] = false
            status = SecItemAdd(attrs as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}
