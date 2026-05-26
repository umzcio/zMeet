import Foundation

public enum ZMeetError: Error, LocalizedError {
    case configMissing(URL)
    case activeSessionExists(String)
    case noActiveSession
    case sessionNotFound(String)
    case invalidCommand(String)
    case recorderFailedToStart(String)
    case processFailed(command: String, exitCode: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .configMissing(let url):
            "No zMeet config found at \(url.path). Run `zmeet init` first."
        case .activeSessionExists(let id):
            "A meeting is already recording: \(id). Stop it before starting another."
        case .noActiveSession:
            "No active recording session was found."
        case .sessionNotFound(let id):
            "No meeting session found for id \(id)."
        case .invalidCommand(let command):
            "Invalid command: \(command)"
        case .recorderFailedToStart(let detail):
            "Recorder failed to start: \(detail)"
        case .processFailed(let command, let exitCode, let stderr):
            "Command failed with exit code \(exitCode): \(command)\n\(stderr)"
        }
    }
}

public enum SessionStatus: String, Codable, Equatable {
    case recording
    case recorded
    case processed
    case failed
}

public struct MeetingSession: Codable, Equatable {
    public var id: String
    public var title: String
    public var sourceApp: String?
    public var startedAt: Date
    public var endedAt: Date?
    public var status: SessionStatus
    public var recorderPID: Int32?
    public var audioPath: String
    public var transcriptPath: String?
    public var notePath: String?
    public var ffmpegLogPath: String
    public var errorMessage: String?

    public init(
        id: String,
        title: String,
        sourceApp: String?,
        startedAt: Date,
        endedAt: Date?,
        status: SessionStatus,
        recorderPID: Int32?,
        audioPath: String,
        transcriptPath: String?,
        notePath: String?,
        ffmpegLogPath: String,
        errorMessage: String?
    ) {
        self.id = id
        self.title = title
        self.sourceApp = sourceApp
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
        self.recorderPID = recorderPID
        self.audioPath = audioPath
        self.transcriptPath = transcriptPath
        self.notePath = notePath
        self.ffmpegLogPath = ffmpegLogPath
        self.errorMessage = errorMessage
    }
}

public struct ZMeetConfig: Codable, Equatable {
    public var notesRepoPath: String
    public var appDataPath: String
    public var ffmpegPath: String
    public var ffmpegAudioInput: String
    public var transcriptionCommand: String?
    public var summaryCommand: String?
    public var gitAutoCommit: Bool

    public init(
        notesRepoPath: String,
        appDataPath: String,
        ffmpegPath: String,
        ffmpegAudioInput: String,
        transcriptionCommand: String?,
        summaryCommand: String?,
        gitAutoCommit: Bool
    ) {
        self.notesRepoPath = notesRepoPath
        self.appDataPath = appDataPath
        self.ffmpegPath = ffmpegPath
        self.ffmpegAudioInput = ffmpegAudioInput
        self.transcriptionCommand = transcriptionCommand
        self.summaryCommand = summaryCommand
        self.gitAutoCommit = gitAutoCommit
    }

    public static func `default`(
        notesRepoPath: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ZMeetConfig {
        let defaultFFmpeg = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/ffmpeg")
            ? "/opt/homebrew/bin/ffmpeg"
            : "ffmpeg"

        return ZMeetConfig(
            notesRepoPath: notesRepoPath,
            appDataPath: home.appendingPathComponent(".zmeet").path,
            ffmpegPath: defaultFFmpeg,
            ffmpegAudioInput: ":0",
            transcriptionCommand: nil,
            summaryCommand: nil,
            gitAutoCommit: true
        )
    }
}
