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

/// How a meeting is captured. Remote (and hybrid) records the other participants'
/// system audio plus the mic; In-person records the room via the mic only.
public enum RecordingMode: String, Codable, Equatable, Sendable {
    case remote
    case inPerson
}

public struct AudioConfig: Codable, Equatable, Sendable {
    public var captureSystemAudio: Bool
    public var captureMicrophone: Bool
    public var sampleRate: Int
    public var bitrate: Int
    /// Preferred microphone input device (Core Audio / AVCaptureDevice unique id).
    /// `nil` uses the system default input.
    public var micDeviceID: String?

    public init(
        captureSystemAudio: Bool = true,
        captureMicrophone: Bool = true,
        sampleRate: Int = 48_000,
        bitrate: Int = 128_000,
        micDeviceID: String? = nil
    ) {
        self.captureSystemAudio = captureSystemAudio
        self.captureMicrophone = captureMicrophone
        self.sampleRate = sampleRate
        self.bitrate = bitrate
        self.micDeviceID = micDeviceID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        captureSystemAudio = try c.decodeIfPresent(Bool.self, forKey: .captureSystemAudio) ?? true
        captureMicrophone = try c.decodeIfPresent(Bool.self, forKey: .captureMicrophone) ?? true
        sampleRate = try c.decodeIfPresent(Int.self, forKey: .sampleRate) ?? 48_000
        bitrate = try c.decodeIfPresent(Int.self, forKey: .bitrate) ?? 128_000
        micDeviceID = try c.decodeIfPresent(String.self, forKey: .micDeviceID)
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
    /// Whether to watch for Zoom/Teams meetings and show the "Take notes" popup.
    public var detectMeetings: Bool
    /// Remembered recording mode (remote vs in-person) for the quick switch.
    public var recordingMode: RecordingMode
    /// Days after which a processed meeting's audio is purged (transcript + notes
    /// are always kept). 0 means never (default).
    public var audioRetentionDays: Int
    /// When true, summaries are produced via the Claude API instead of the
    /// on-device model. The API key lives in the Keychain, never here. Default off.
    public var useCloudSummaries: Bool

    public init(
        outputPath: String,
        appDataPath: String,
        audio: AudioConfig = AudioConfig(),
        transcriptionCommand: String?,
        summaryCommand: String?,
        gitAutoCommit: Bool = false,
        autoProcessOnStop: Bool = true,
        detectMeetings: Bool = true,
        recordingMode: RecordingMode = .remote,
        audioRetentionDays: Int = 0,
        useCloudSummaries: Bool = false
    ) {
        self.outputPath = outputPath
        self.appDataPath = appDataPath
        self.audio = audio
        self.transcriptionCommand = transcriptionCommand
        self.summaryCommand = summaryCommand
        self.gitAutoCommit = gitAutoCommit
        self.autoProcessOnStop = autoProcessOnStop
        self.detectMeetings = detectMeetings
        self.recordingMode = recordingMode
        self.audioRetentionDays = audioRetentionDays
        self.useCloudSummaries = useCloudSummaries
    }

    /// Lenient decoding so older/partial `config.json` files still load — any
    /// missing key falls back to its default instead of failing the whole load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let home = FileManager.default.homeDirectoryForCurrentUser
        outputPath = try c.decodeIfPresent(String.self, forKey: .outputPath)
            ?? home.appendingPathComponent("Documents/zMeet").path
        appDataPath = try c.decodeIfPresent(String.self, forKey: .appDataPath)
            ?? home.appendingPathComponent(".zmeet").path
        audio = try c.decodeIfPresent(AudioConfig.self, forKey: .audio) ?? AudioConfig()
        transcriptionCommand = try c.decodeIfPresent(String.self, forKey: .transcriptionCommand)
        summaryCommand = try c.decodeIfPresent(String.self, forKey: .summaryCommand)
        gitAutoCommit = try c.decodeIfPresent(Bool.self, forKey: .gitAutoCommit) ?? false
        autoProcessOnStop = try c.decodeIfPresent(Bool.self, forKey: .autoProcessOnStop) ?? true
        detectMeetings = try c.decodeIfPresent(Bool.self, forKey: .detectMeetings) ?? true
        recordingMode = try c.decodeIfPresent(RecordingMode.self, forKey: .recordingMode) ?? .remote
        audioRetentionDays = try c.decodeIfPresent(Int.self, forKey: .audioRetentionDays) ?? 0
        useCloudSummaries = try c.decodeIfPresent(Bool.self, forKey: .useCloudSummaries) ?? false
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
            autoProcessOnStop: true,
            detectMeetings: true,
            recordingMode: .remote,
            audioRetentionDays: 0,
            useCloudSummaries: false
        )
    }
}
