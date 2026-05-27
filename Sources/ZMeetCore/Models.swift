import Foundation

public enum ZMeetError: Error, LocalizedError {
    case configMissing(URL)
    case activeSessionExists(String)
    case noActiveSession
    case sessionNotFound(String)
    case invalidCommand(String)
    case processFailed(command: String, exitCode: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .configMissing(let url):
            "No zMeet config found at \(url.path). Launch ZMeet to complete first-time setup."
        case .activeSessionExists(let id):
            "A meeting is already recording: \(id). Stop it before starting another."
        case .noActiveSession:
            "No active recording session was found."
        case .sessionNotFound(let id):
            "No meeting session found for id \(id)."
        case .invalidCommand(let command):
            "Invalid command: \(command)"
        case .processFailed(let command, let exitCode, let stderr):
            "Command failed with exit code \(exitCode): \(command)\n\(stderr)"
        }
    }
}

public enum SessionStatus: String, Codable, Equatable, Sendable {
    case recording
    case recorded
    case processed
    case failed
}

public struct MeetingSession: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var sourceApp: String?
    public var startedAt: Date
    public var endedAt: Date?
    public var status: SessionStatus
    public var audioPath: String
    public var transcriptPath: String?
    public var notePath: String?
    public var recorderLogPath: String?
    public var errorMessage: String?

    public init(
        id: String,
        title: String,
        sourceApp: String?,
        startedAt: Date,
        endedAt: Date?,
        status: SessionStatus,
        audioPath: String,
        transcriptPath: String?,
        notePath: String?,
        recorderLogPath: String?,
        errorMessage: String?
    ) {
        self.id = id
        self.title = title
        self.sourceApp = sourceApp
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
        self.audioPath = audioPath
        self.transcriptPath = transcriptPath
        self.notePath = notePath
        self.recorderLogPath = recorderLogPath
        self.errorMessage = errorMessage
    }
}

public struct AudioConfig: Codable, Equatable, Sendable {
    public var captureSystemAudio: Bool
    public var captureMicrophone: Bool
    public var sampleRate: Int
    public var bitrate: Int

    public init(
        captureSystemAudio: Bool = true,
        captureMicrophone: Bool = true,
        sampleRate: Int = 48_000,
        bitrate: Int = 128_000
    ) {
        self.captureSystemAudio = captureSystemAudio
        self.captureMicrophone = captureMicrophone
        self.sampleRate = sampleRate
        self.bitrate = bitrate
    }
}

public struct ZMeetConfig: Codable, Equatable, Sendable {
    /// Root for user-facing meeting output (one folder per meeting lives here),
    /// e.g. ~/Documents/zMeet.
    public var outputPath: String
    public var appDataPath: String
    public var audio: AudioConfig
    public var transcriptionCommand: String?
    public var summaryCommand: String?
    public var gitAutoCommit: Bool
    public var autoProcessOnStop: Bool

    public init(
        outputPath: String,
        appDataPath: String,
        audio: AudioConfig = AudioConfig(),
        transcriptionCommand: String?,
        summaryCommand: String?,
        gitAutoCommit: Bool = false,
        autoProcessOnStop: Bool = true
    ) {
        self.outputPath = outputPath
        self.appDataPath = appDataPath
        self.audio = audio
        self.transcriptionCommand = transcriptionCommand
        self.summaryCommand = summaryCommand
        self.gitAutoCommit = gitAutoCommit
        self.autoProcessOnStop = autoProcessOnStop
    }

    public static func `default`(
        outputPath: String? = nil,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ZMeetConfig {
        ZMeetConfig(
            outputPath: outputPath ?? home.appendingPathComponent("Documents/zMeet").path,
            appDataPath: home.appendingPathComponent(".zmeet").path,
            audio: AudioConfig(),
            transcriptionCommand: nil,
            summaryCommand: nil,
            gitAutoCommit: false,
            autoProcessOnStop: true
        )
    }
}
