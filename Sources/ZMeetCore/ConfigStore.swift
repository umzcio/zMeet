import Foundation

public final class ConfigStore {
    public let home: URL
    public let configDirectory: URL
    public let configURL: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
        self.configDirectory = home.appendingPathComponent(".zmeet", isDirectory: true)
        self.configURL = configDirectory.appendingPathComponent("config.json")
    }

    public func load() throws -> ZMeetConfig {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw ZMeetError.configMissing(configURL)
        }

        let data = try Data(contentsOf: configURL)
        return try JSONDecoder.zmeet.decode(ZMeetConfig.self, from: data)
    }

    public func write(_ config: ZMeetConfig) throws {
        try ZMeetPaths.ensureDirectory(configDirectory)
        let data = try JSONEncoder.zmeet.encode(config)
        try data.write(to: configURL, options: [.atomic])
    }

    public func bootstrap(outputPath rawOutputPath: String? = nil) throws -> ZMeetConfig {
        let outputPath = rawOutputPath.map { ZMeetPaths.expandTilde($0, home: home) }
        let config = ZMeetConfig.default(outputPath: outputPath, home: home)

        try write(config)
        try ZMeetPaths.ensureDirectory(URL(fileURLWithPath: config.appDataPath, isDirectory: true))
        try ZMeetPaths.ensureDirectory(URL(fileURLWithPath: config.outputPath, isDirectory: true))

        return config
    }

    /// Result of loading with corruption handling: the config, plus the backup
    /// URL when an unreadable file was set aside.
    public enum LoadOutcome {
        case loaded(ZMeetConfig)
        case bootstrapped(ZMeetConfig, corruptBackup: URL?)
        /// The file exists but couldn't be read (I/O error) or couldn't be set
        /// aside safely — defaults are used IN MEMORY ONLY; nothing on disk was
        /// touched, so the user's settings survive for a later relaunch.
        case loadFailedLeftUntouched(ZMeetConfig, reason: String)
    }

    /// Load the config; if the file exists but cannot be decoded, move it to
    /// `config.json.bak-<timestamp>` (never overwrite user data) and bootstrap
    /// a fresh default. A missing file bootstraps without a backup. A file
    /// that exists but can't be read (I/O error), or a corrupt file that can't
    /// be moved aside safely, is left untouched on disk — only in-memory
    /// defaults are used, so nothing on disk is ever overwritten without a
    /// successful backup first.
    public func loadOrBackupAndBootstrap() -> LoadOutcome {
        do {
            return .loaded(try load())
        } catch ZMeetError.configMissing {
            let fresh = (try? bootstrap()) ?? ZMeetConfig.default(home: home)
            return .bootstrapped(fresh, corruptBackup: nil)
        } catch let error as DecodingError {
            // Exists but undecodable: preserve it, then bootstrap.
            _ = error
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let backupURL = configDirectory.appendingPathComponent("config.json.bak-\(stamp)")
            try? FileManager.default.moveItem(at: configURL, to: backupURL)
            let backedUp = FileManager.default.fileExists(atPath: backupURL.path)
            guard backedUp else {
                // Couldn't set the corrupt file aside — do NOT bootstrap, that
                // would write config.json over the un-backed-up original.
                return .loadFailedLeftUntouched(
                    ZMeetConfig.default(home: home),
                    reason: "couldn't set the unreadable file aside"
                )
            }
            let fresh = (try? bootstrap()) ?? ZMeetConfig.default(home: home)
            return .bootstrapped(fresh, corruptBackup: backupURL)
        } catch {
            // I/O error (locked file, permissions, EIO, ...) or anything else:
            // no move, no write — leave the file exactly as it is.
            return .loadFailedLeftUntouched(ZMeetConfig.default(home: home), reason: error.localizedDescription)
        }
    }
}

extension JSONEncoder {
    // Shared singleton, not a per-call instance: JSONEncoder isn't safe for
    // CONCURRENT use, but this codebase only ever touches it from one thread
    // (single-threaded usage contract), so reusing one instance is safe and
    // avoids allocating a fresh encoder per file.
    static let zmeet: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

extension JSONDecoder {
    // Same contract as JSONEncoder.zmeet above: single-threaded usage only.
    static let zmeet: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
