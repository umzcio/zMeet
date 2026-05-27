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
}

extension JSONEncoder {
    static var zmeet: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var zmeet: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
