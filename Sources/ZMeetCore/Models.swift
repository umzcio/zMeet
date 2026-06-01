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
    public var mode: RecordingMode?
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
        mode: RecordingMode? = nil,
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
        self.mode = mode
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
    case hybrid
    case inPerson
}

/// Per-mode capture settings. Stored as presets in ZMeetConfig.profiles and copied
/// into the live AudioConfig + noiseSuppression when recording starts in that mode.
public struct CaptureProfile: Codable, Equatable, Sendable {
    public var captureSystemAudio: Bool
    public var micDeviceID: String?
    public var micGain: Float
    public var noiseSuppression: Bool

    public init(captureSystemAudio: Bool, micDeviceID: String?, micGain: Float, noiseSuppression: Bool) {
        self.captureSystemAudio = captureSystemAudio
        self.micDeviceID = micDeviceID
        self.micGain = micGain
        self.noiseSuppression = noiseSuppression
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        captureSystemAudio = try c.decodeIfPresent(Bool.self, forKey: .captureSystemAudio) ?? true
        micDeviceID = try c.decodeIfPresent(String.self, forKey: .micDeviceID)
        micGain = try c.decodeIfPresent(Float.self, forKey: .micGain) ?? 1.0
        noiseSuppression = try c.decodeIfPresent(Bool.self, forKey: .noiseSuppression) ?? false
    }

    public static func `default`(for mode: RecordingMode) -> CaptureProfile {
        switch mode {
        case .remote:   CaptureProfile(captureSystemAudio: true,  micDeviceID: nil, micGain: 1.0, noiseSuppression: true)
        case .hybrid:   CaptureProfile(captureSystemAudio: true,  micDeviceID: nil, micGain: 2.0, noiseSuppression: true)
        case .inPerson: CaptureProfile(captureSystemAudio: false, micDeviceID: nil, micGain: 2.0, noiseSuppression: false)
        }
    }
}

/// The three per-mode capture presets. A struct (not a dictionary) so it serializes
/// to clean keyed JSON; the subscript gives dictionary-like access by mode.
public struct CaptureProfiles: Codable, Equatable, Sendable {
    public var remote: CaptureProfile
    public var hybrid: CaptureProfile
    public var inPerson: CaptureProfile

    public init(remote: CaptureProfile, hybrid: CaptureProfile, inPerson: CaptureProfile) {
        self.remote = remote
        self.hybrid = hybrid
        self.inPerson = inPerson
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        remote = try c.decodeIfPresent(CaptureProfile.self, forKey: .remote) ?? .default(for: .remote)
        hybrid = try c.decodeIfPresent(CaptureProfile.self, forKey: .hybrid) ?? .default(for: .hybrid)
        inPerson = try c.decodeIfPresent(CaptureProfile.self, forKey: .inPerson) ?? .default(for: .inPerson)
    }

    public static func defaults() -> CaptureProfiles {
        CaptureProfiles(remote: .default(for: .remote), hybrid: .default(for: .hybrid), inPerson: .default(for: .inPerson))
    }

    public subscript(mode: RecordingMode) -> CaptureProfile {
        get {
            switch mode {
            case .remote: remote
            case .hybrid: hybrid
            case .inPerson: inPerson
            }
        }
        set {
            switch mode {
            case .remote: remote = newValue
            case .hybrid: hybrid = newValue
            case .inPerson: inPerson = newValue
            }
        }
    }
}

public struct AudioConfig: Codable, Equatable, Sendable {
    public var captureSystemAudio: Bool
    public var captureMicrophone: Bool
    public var sampleRate: Int
    public var bitrate: Int
    /// Preferred microphone input device (Core Audio / AVCaptureDevice unique id).
    /// `nil` uses the system default input.
    public var micDeviceID: String?
    /// Linear gain multiplier applied to the microphone signal pre-mix
    /// (1.0 = unchanged). Boosts a quiet mic for in-person recordings.
    public var micGain: Float

    public init(
        captureSystemAudio: Bool = true,
        captureMicrophone: Bool = true,
        sampleRate: Int = 48_000,
        bitrate: Int = 128_000,
        micDeviceID: String? = nil,
        micGain: Float = 1.0
    ) {
        self.captureSystemAudio = captureSystemAudio
        self.captureMicrophone = captureMicrophone
        self.sampleRate = sampleRate
        self.bitrate = bitrate
        self.micDeviceID = micDeviceID
        self.micGain = micGain
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        captureSystemAudio = try c.decodeIfPresent(Bool.self, forKey: .captureSystemAudio) ?? true
        captureMicrophone = try c.decodeIfPresent(Bool.self, forKey: .captureMicrophone) ?? true
        sampleRate = try c.decodeIfPresent(Int.self, forKey: .sampleRate) ?? 48_000
        bitrate = try c.decodeIfPresent(Int.self, forKey: .bitrate) ?? 128_000
        micDeviceID = try c.decodeIfPresent(String.self, forKey: .micDeviceID)
        micGain = try c.decodeIfPresent(Float.self, forKey: .micGain) ?? 1.0
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
    /// When true, recordings get an offline background-noise cleanup pass after
    /// the meeting stops (high-pass + downward expander). Default off.
    public var noiseSuppression: Bool
    /// Per-mode capture presets. Applied to the live config when a recording starts
    /// in that mode (see AppState.startRecording).
    public var profiles: CaptureProfiles

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
        useCloudSummaries: Bool = false,
        noiseSuppression: Bool = false,
        profiles: CaptureProfiles = .defaults()
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
        self.noiseSuppression = noiseSuppression
        self.profiles = profiles
    }

    /// Per-mode capture preset for the given recording mode.
    public func profile(for mode: RecordingMode) -> CaptureProfile { profiles[mode] }

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
        noiseSuppression = try c.decodeIfPresent(Bool.self, forKey: .noiseSuppression) ?? false
        // `audio` and `noiseSuppression` are decoded above so they're available to
        // migrate legacy global capture settings into per-mode profiles below.
        if let decodedProfiles = try c.decodeIfPresent(CaptureProfiles.self, forKey: .profiles) {
            profiles = decodedProfiles
        } else {
            let base = CaptureProfile(
                captureSystemAudio: true,
                micDeviceID: audio.micDeviceID,
                micGain: audio.micGain,
                noiseSuppression: noiseSuppression
            )
            var inPerson = base
            inPerson.captureSystemAudio = false
            profiles = CaptureProfiles(remote: base, hybrid: base, inPerson: inPerson)
        }
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
            useCloudSummaries: false,
            noiseSuppression: false,
            profiles: .defaults()
        )
    }
}
