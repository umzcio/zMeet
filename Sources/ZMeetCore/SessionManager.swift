import Darwin
import Foundation

public final class SessionManager {
    private let config: ZMeetConfig
    private let runner: ProcessRunner
    private let fileManager: FileManager

    private var appDataURL: URL {
        URL(fileURLWithPath: ZMeetPaths.expandTilde(config.appDataPath), isDirectory: true)
    }

    private var sessionsURL: URL {
        appDataURL.appendingPathComponent("sessions", isDirectory: true)
    }

    private var audioRootURL: URL {
        appDataURL.appendingPathComponent("audio", isDirectory: true)
    }

    private var logsURL: URL {
        appDataURL.appendingPathComponent("logs", isDirectory: true)
    }

    private var notesRepoURL: URL {
        URL(fileURLWithPath: ZMeetPaths.expandTilde(config.notesRepoPath), isDirectory: true)
    }

    public init(config: ZMeetConfig, runner: ProcessRunner = ProcessRunner(), fileManager: FileManager = .default) {
        self.config = config
        self.runner = runner
        self.fileManager = fileManager
    }

    public func start(title rawTitle: String, sourceApp: String?) throws -> MeetingSession {
        if let active = try activeSession() {
            throw ZMeetError.activeSessionExists(active.id)
        }

        try ensureRuntimeDirectories()

        let startedAt = Date()
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled Meeting" : rawTitle
        let id = try uniqueSessionID(title: title, startedAt: startedAt)
        let datedAudioDirectory = audioRootURL
            .appendingPathComponent(ZMeetDates.year(startedAt), isDirectory: true)
            .appendingPathComponent(ZMeetDates.month(startedAt), isDirectory: true)
        try ZMeetPaths.ensureDirectory(datedAudioDirectory)

        let audioURL = datedAudioDirectory.appendingPathComponent("\(id).m4a")
        let logURL = logsURL.appendingPathComponent("\(id).ffmpeg.log")

        let arguments = [
            "-nostdin",
            "-y",
            "-f", "avfoundation",
            "-i", config.ffmpegAudioInput,
            "-vn",
            "-acodec", "aac",
            "-b:a", "128k",
            audioURL.path
        ]

        let pid = try runner.startDetached(
            executable: ZMeetPaths.expandTilde(config.ffmpegPath),
            arguments: arguments,
            logURL: logURL
        )

        usleep(700_000)
        guard isProcessAlive(pid: pid) else {
            let detail = ((try? String(contentsOf: logURL, encoding: .utf8)) ?? "ffmpeg exited immediately")
                .split(separator: "\n")
                .suffix(30)
                .joined(separator: "\n")
            throw ZMeetError.recorderFailedToStart(detail)
        }

        let session = MeetingSession(
            id: id,
            title: title,
            sourceApp: sourceApp,
            startedAt: startedAt,
            endedAt: nil,
            status: .recording,
            recorderPID: pid,
            audioPath: audioURL.path,
            transcriptPath: nil,
            notePath: nil,
            ffmpegLogPath: logURL.path,
            errorMessage: nil
        )

        try save(session)
        return session
    }

    public func stop() throws -> MeetingSession {
        guard var session = try activeSession() else {
            throw ZMeetError.noActiveSession
        }

        if let pid = session.recorderPID {
            _ = Darwin.kill(pid, SIGINT)
            waitForProcessToExit(pid: pid, timeoutSeconds: 8)
            if Darwin.kill(pid, 0) == 0 {
                _ = Darwin.kill(pid, SIGTERM)
            }
        }

        session.endedAt = Date()
        session.status = .recorded
        session.recorderPID = nil
        try save(session)
        return session
    }

    @discardableResult
    public func process(id requestedID: String? = nil) throws -> MeetingSession {
        try ensureRuntimeDirectories()
        var session = try loadSessionForProcessing(id: requestedID)

        if session.status == .recording {
            throw ZMeetError.activeSessionExists(session.id)
        }

        let transcriptURL = transcriptURL(for: session)
        let noteURL = noteURL(for: session)
        try ZMeetPaths.ensureDirectory(transcriptURL.deletingLastPathComponent())
        try ZMeetPaths.ensureDirectory(noteURL.deletingLastPathComponent())

        do {
            let transcriptMarkdown = try transcribe(session: session, transcriptURL: transcriptURL)
            let summaryMarkdown = try summarize(session: session, transcriptURL: transcriptURL, transcriptMarkdown: transcriptMarkdown)
            let noteMarkdown = MarkdownRenderer().renderNote(
                session: session,
                transcriptURL: transcriptURL,
                noteURL: noteURL,
                summaryMarkdown: summaryMarkdown
            )

            try noteMarkdown.write(to: noteURL, atomically: true, encoding: .utf8)
            session.status = .processed
            session.transcriptPath = transcriptURL.path
            session.notePath = noteURL.path
            session.errorMessage = nil
            try save(session)

            if config.gitAutoCommit {
                _ = try? GitRepository(repoURL: notesRepoURL).commitAll(message: "Add meeting notes: \(session.title)")
            }

            return session
        } catch {
            session.status = .failed
            session.errorMessage = error.localizedDescription
            try? save(session)
            throw error
        }
    }

    public func status() throws -> MeetingSession? {
        try activeSession()
    }

    public func listSessions() throws -> [MeetingSession] {
        guard fileManager.fileExists(atPath: sessionsURL.path) else {
            return []
        }

        let files = try fileManager.contentsOfDirectory(at: sessionsURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }

        return try files
            .map(loadSession(from:))
            .sorted { $0.startedAt > $1.startedAt }
    }

    public func listAudioDevices() throws -> ProcessResult {
        try runner.run(
            executable: ZMeetPaths.expandTilde(config.ffmpegPath),
            arguments: ["-f", "avfoundation", "-list_devices", "true", "-i", ""]
        )
    }

    private func transcribe(session: MeetingSession, transcriptURL: URL) throws -> String {
        let values = commandValues(session: session, transcriptURL: transcriptURL, summaryURL: nil)

        if let commandTemplate = config.transcriptionCommand,
           !commandTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let command = ZMeetText.expandCommandTemplate(commandTemplate, values: values)
            let result = try runner.runShell(command, currentDirectory: notesRepoURL)
            guard result.exitCode == 0 else {
                throw ZMeetError.processFailed(command: command, exitCode: result.exitCode, stderr: result.stderr)
            }

            if fileManager.fileExists(atPath: transcriptURL.path) {
                return try String(contentsOf: transcriptURL, encoding: .utf8)
            }

            if !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try result.stdout.write(to: transcriptURL, atomically: true, encoding: .utf8)
                return result.stdout
            }

            throw ZMeetError.processFailed(
                command: command,
                exitCode: result.exitCode,
                stderr: "Transcription command succeeded but did not write \(transcriptURL.path) or stdout."
            )
        }

        let placeholder = MarkdownRenderer().renderTranscriptPlaceholder(session: session)
        try placeholder.write(to: transcriptURL, atomically: true, encoding: .utf8)
        return placeholder
    }

    private func summarize(session: MeetingSession, transcriptURL: URL, transcriptMarkdown: String) throws -> String {
        let summaryURL = appDataURL
            .appendingPathComponent("summaries", isDirectory: true)
            .appendingPathComponent("\(session.id).summary.md")
        try ZMeetPaths.ensureDirectory(summaryURL.deletingLastPathComponent())

        if let commandTemplate = config.summaryCommand,
           !commandTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let command = ZMeetText.expandCommandTemplate(
                commandTemplate,
                values: commandValues(session: session, transcriptURL: transcriptURL, summaryURL: summaryURL)
            )
            let result = try runner.runShell(command, currentDirectory: notesRepoURL)
            guard result.exitCode == 0 else {
                throw ZMeetError.processFailed(command: command, exitCode: result.exitCode, stderr: result.stderr)
            }

            if fileManager.fileExists(atPath: summaryURL.path) {
                return try String(contentsOf: summaryURL, encoding: .utf8)
            }

            if !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try result.stdout.write(to: summaryURL, atomically: true, encoding: .utf8)
                return result.stdout
            }
        }

        let defaultSummary = MarkdownRenderer().renderDefaultSummary(session: session, transcriptMarkdown: transcriptMarkdown)
        try defaultSummary.write(to: summaryURL, atomically: true, encoding: .utf8)
        return defaultSummary
    }

    private func commandValues(session: MeetingSession, transcriptURL: URL, summaryURL: URL?) -> [String: String] {
        var values = [
            "id": session.id,
            "title": session.title,
            "audio": session.audioPath,
            "transcript": transcriptURL.path,
            "transcriptBase": transcriptURL.deletingPathExtension().path,
            "notesRepo": notesRepoURL.path
        ]

        if let summaryURL {
            values["summary"] = summaryURL.path
        }

        return values
    }

    private func loadSessionForProcessing(id requestedID: String?) throws -> MeetingSession {
        if let requestedID {
            return try loadSession(id: requestedID)
        }

        if let active = try activeSession() {
            return active
        }

        if let latestRecorded = try listSessions().first(where: { $0.status == .recorded || $0.status == .failed || $0.status == .processed }) {
            return latestRecorded
        }

        throw ZMeetError.noActiveSession
    }

    private func activeSession() throws -> MeetingSession? {
        try listSessions().first { $0.status == .recording }
    }

    private func loadSession(id: String) throws -> MeetingSession {
        let url = sessionsURL.appendingPathComponent("\(id).json")
        guard fileManager.fileExists(atPath: url.path) else {
            throw ZMeetError.sessionNotFound(id)
        }

        return try loadSession(from: url)
    }

    private func loadSession(from url: URL) throws -> MeetingSession {
        let data = try Data(contentsOf: url)
        return try JSONDecoder.zmeet.decode(MeetingSession.self, from: data)
    }

    private func save(_ session: MeetingSession) throws {
        try ensureRuntimeDirectories()
        let url = sessionsURL.appendingPathComponent("\(session.id).json")
        let data = try JSONEncoder.zmeet.encode(session)
        try data.write(to: url, options: [.atomic])
    }

    private func ensureRuntimeDirectories() throws {
        try ZMeetPaths.ensureDirectory(appDataURL)
        try ZMeetPaths.ensureDirectory(sessionsURL)
        try ZMeetPaths.ensureDirectory(audioRootURL)
        try ZMeetPaths.ensureDirectory(logsURL)
        try ZMeetPaths.ensureDirectory(notesRepoURL)
    }

    private func uniqueSessionID(title: String, startedAt: Date) throws -> String {
        let base = "\(ZMeetDates.fileStamp(startedAt))-\(ZMeetText.slugify(title))"
        var candidate = base
        var suffix = 2

        while fileManager.fileExists(atPath: sessionsURL.appendingPathComponent("\(candidate).json").path) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }

        return candidate
    }

    private func transcriptURL(for session: MeetingSession) -> URL {
        notesRepoURL
            .appendingPathComponent("transcripts", isDirectory: true)
            .appendingPathComponent(ZMeetDates.year(session.startedAt), isDirectory: true)
            .appendingPathComponent(ZMeetDates.month(session.startedAt), isDirectory: true)
            .appendingPathComponent("\(session.id).transcript.md")
    }

    private func noteURL(for session: MeetingSession) -> URL {
        notesRepoURL
            .appendingPathComponent("meetings", isDirectory: true)
            .appendingPathComponent(ZMeetDates.year(session.startedAt), isDirectory: true)
            .appendingPathComponent(ZMeetDates.month(session.startedAt), isDirectory: true)
            .appendingPathComponent("\(session.id).md")
    }

    private func waitForProcessToExit(pid: Int32, timeoutSeconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if !isProcessAlive(pid: pid) {
                return
            }
            usleep(200_000)
        }
    }

    private func isProcessAlive(pid: Int32) -> Bool {
        Darwin.kill(pid, 0) == 0
    }
}
