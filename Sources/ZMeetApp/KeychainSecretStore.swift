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
        // Delete any existing item first so write is an upsert.
        SecItemDelete(baseQuery(account: account) as CFDictionary)
        var attrs = baseQuery(account: account)
        attrs[kSecValueData as String] = data
        let status = SecItemAdd(attrs as CFDictionary, nil)
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
