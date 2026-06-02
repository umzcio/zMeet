import Foundation

/// Reads Obsidian's known-vaults registry so zMeet can offer them in a dropdown.
public enum ObsidianVaults {
    public struct Vault: Sendable, Equatable { public let name: String; public let path: String }

    /// Default location of Obsidian's vault registry on macOS.
    public static func registryURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
    }

    /// Detected vaults whose directory still exists, sorted by name.
    public static func detected(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Vault] {
        guard let data = try? Data(contentsOf: registryURL(home: home)) else { return [] }
        return parse(jsonData: data) { FileManager.default.fileExists(atPath: $0) }
    }

    /// Pure parse, with an injected existence check for testing.
    public static func parse(jsonData: Data, exists: (String) -> Bool) -> [Vault] {
        guard let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let vaults = obj["vaults"] as? [String: Any] else { return [] }
        var out: [Vault] = []
        for (_, v) in vaults {
            guard let dict = v as? [String: Any], let path = dict["path"] as? String, exists(path) else { continue }
            out.append(Vault(name: (path as NSString).lastPathComponent, path: path))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
