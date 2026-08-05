import Foundation

public final class SessionManager {
    private var config: ZMeetConfig
    private let recorder: MeetingRecorder
    private let fileManager: FileManager

    /// Full-text index over processed meetings. Optional: if the database can't
    /// be opened, search is disabled but everything else works.
    public let searchStore: SearchStore?

    private var appDataURL: URL {
        URL(fileURLWithPath: ZMeetPaths.expandTilde(config.appDataPath), isDirectory: true)
    }

    private var sessionsURL: URL {
        appDataURL.appendingPathComponent("sessions", isDirectory: true)
    }

    private var logsURL: URL {
        appDataURL.appendingPathComponent("logs", isDirectory: true)
    }

    /// Root for all user-facing meeting output (e.g. ~/Documents/zMeet).
    private var outputURL: URL {
        URL(fileURLWithPath: ZMeetPaths.expandTilde(config.outputPath), isDirectory: true)
    }

    public init(
        config: ZMeetConfig,
        recorder: MeetingRecorder,
        fileManager: FileManager = .default
    ) {
        self.config = config
        self.recorder = recorder
        self.fileManager = fileManager
        let searchDBURL = URL(fileURLWithPath: ZMeetPaths.expandTilde(config.appDataPath), isDirectory: true)
            .appendingPathComponent("search.db")
        self.searchStore = try? SearchStore(databaseURL: searchDBURL)
    }

    /// Apply a new configuration in place. Lets callers propagate settings
    /// changes without recreating the manager (which would reopen the search
    /// DB). Callers MUST recreate the manager instead when appDataPath or
    /// outputPath change, since those determine the on-disk layout and the
    /// search DB location.
    public func updateConfig(_ newConfig: ZMeetConfig) {
        config = newConfig
    }

    public func start(title rawTitle: String, sourceApp: String?, mode: RecordingMode? = nil) throws -> MeetingSession {
        if let active = try activeSession() {
            throw ZMeetError.activeSessionExists(active.id)
        }

        try ensureRuntimeDirectories()

        let startedAt = Date()
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled Meeting" : rawTitle
        let id = try uniqueSessionID(title: title, startedAt: startedAt)
        // One folder per meeting (Zoom-style), holding the recording, transcript,
        // and notes together under the output root.
        let meetingFolder = uniqueMeetingFolderURL(title: title, startedAt: startedAt)
        try ZMeetPaths.ensureDirectory(meetingFolder)

        let audioURL = meetingFolder.appendingPathComponent("recording.m4a")
        let logURL = logsURL.appendingPathComponent("\(id).recorder.log")

        // Start capture first; only persist a `.recording` session if it succeeds,
        // so a synchronous start failure never leaves a dangling session.
        try recorder.start(to: audioURL, logURL: logURL, audio: config.audio)

        let session = MeetingSession(
            id: id,
            title: title,
            sourceApp: sourceApp,
            mode: mode,
            startedAt: startedAt,
            endedAt: nil,
            status: .recording,
            audioPath: audioURL.path,
            transcriptPath: nil,
            notePath: nil,
            recorderLogPath: logURL.path,
            errorMessage: nil
        )

        try save(session)
        return session
    }

    // `nonisolated(nonsending)` so this runs in the caller's isolation domain
    // (the main actor in the app, the test's context in tests) rather than
    // hopping to a nonisolated executor. Without it, awaiting this from the
    // @MainActor `AppState` would "send" the non-Sendable manager off-actor —
    // a data race. The recorder seam is `Sendable`, so awaiting `recorder.stop()`
    // below is still free to run off the caller's actor.
    public nonisolated(nonsending) func stop() async throws -> MeetingSession {
        guard var session = try activeSession() else {
            throw ZMeetError.noActiveSession
        }

        do {
            try await recorder.stop()
        } catch {
            session.status = .failed
            session.errorMessage = error.localizedDescription
            session.endedAt = Date()
            try? save(session)
            throw error
        }

        session.endedAt = Date()
        session.status = .recorded
        try save(session)
        return session
    }

    /// Returns the session with the given id (callers need its audio path/title
    /// before producing a transcript).
    public func session(id: String) throws -> MeetingSession {
        try loadSession(id: id)
    }

    /// Writes an externally-produced transcript + summary into the meeting folder,
    /// renders the note, and marks the session processed. Used by the app's
    /// on-device transcription/summarization path (keeps async work out of Core).
    @discardableResult
    public func applyProcessedText(id: String, transcript: String, summary: String, engine: SummaryEngine = .onDevice) throws -> MeetingSession {
        var session = try loadSession(id: id)
        // Don't finalize a session that's still recording.
        guard session.status != .recording else {
            throw ZMeetError.activeSessionExists(session.id)
        }
        let priorStatus = session.status
        let transcriptURL = transcriptURL(for: session)
        let noteURL = noteURL(for: session)
        try ZMeetPaths.ensureDirectory(transcriptURL.deletingLastPathComponent())

        do {
            try transcript.write(to: transcriptURL, atomically: true, encoding: .utf8)
            let note = MarkdownRenderer().renderProcessedNote(
                session: session,
                transcriptURL: transcriptURL,
                noteURL: noteURL,
                summaryMarkdown: summary,
                summaryEngine: engine
            )
            try note.write(to: noteURL, atomically: true, encoding: .utf8)
            session.status = .processed
            session.transcriptPath = transcriptURL.path
            session.notePath = noteURL.path
            session.errorMessage = nil
            try save(session)
            // Index the title-free summary as the notes column (not the full
            // rendered note, which embeds the title/frontmatter/paths) so the
            // title lives only in the title column and rename can update it cleanly.
            try? searchStore?.index(
                sessionID: session.id, title: session.title,
                notes: summary, transcript: transcript
            )
            if config.gitAutoCommit {
                _ = try? GitRepository(repoURL: outputURL).commitAll(message: "Add meeting notes: \(session.title)")
            }
            return session
        } catch {
            // A failed re-process of an already-processed meeting must not hide
            // notes that are still intact on disk — only downgrade a session that
            // wasn't processed yet.
            session.status = (priorStatus == .processed) ? .processed : .failed
            session.errorMessage = error.localizedDescription
            try? save(session)
            throw error
        }
    }

    /// Renames a meeting's display title in place. The on-disk folder name (fixed
    /// at creation time) is intentionally left unchanged so existing file paths
    /// stay valid; only the session record's title is updated.
    @discardableResult
    public func setTitle(id: String, to rawTitle: String) throws -> MeetingSession {
        var session = try loadSession(id: id)
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        session.title = title.isEmpty ? "Untitled Meeting" : title
        try save(session)
        // Update only the indexed title, preserving the meeting's notes/transcript
        // in the index (a no-op if it isn't indexed). The old title leaves search;
        // the body stays searchable.
        try? searchStore?.updateTitle(sessionID: session.id, title: session.title)
        return session
    }

    /// Records the base filename last published to the Obsidian vault, so a later
    /// republish under a different name (after a rename) can remove the old pair.
    @discardableResult
    public func setObsidianBaseName(id: String, to base: String) throws -> MeetingSession {
        var session = try loadSession(id: id)
        session.obsidianBaseName = base
        try save(session)
        return session
    }

    /// Deletes a meeting: removes its on-disk folder (recording, transcript, note)
    /// and the session record. Missing files are ignored so a partial delete still
    /// clears the session.
    public func delete(id: String) throws {
        let session = try loadSession(id: id)
        // Never delete a meeting that's still recording — the recorder is writing
        // to its folder.
        guard session.status != .recording else {
            throw ZMeetError.activeSessionExists(session.id)
        }
        let folder = meetingFolderURL(for: session)
        // Only remove the folder when it sits strictly under our output root
        // (trailing slash so a sibling like ".../zMeetOther" can't match).
        if folder.standardizedFileURL.path.hasPrefix(outputURL.standardizedFileURL.path + "/") {
            try? fileManager.removeItem(at: folder)
        }
        try? fileManager.removeItem(at: sessionsURL.appendingPathComponent("\(id).json"))
        try? searchStore?.remove(sessionID: id)
    }

    /// Purge audio for processed meetings older than `config.audioRetentionDays`.
    /// Deletes only the recording file; transcript, notes, folder, and the session
    /// record are kept. No-op when retention is 0 (never). Returns the count purged.
    @discardableResult
    public func purgeExpiredAudio(referenceDate: Date = Date()) -> Int {
        let days = config.audioRetentionDays
        guard days > 0 else { return 0 }
        let cutoff = Double(days) * 86_400
        var purged = 0
        for session in (try? listSessions()) ?? [] where session.status == .processed {
            let age = referenceDate.timeIntervalSince(session.endedAt ?? session.startedAt)
            guard age > cutoff else { continue }
            if removeAudioFile(for: session) { purged += 1 }
        }
        return purged
    }

    /// Manually purge a single processed meeting's audio (keeps transcript/notes).
    /// No-op if the meeting isn't processed or has no audio file.
    public func deleteAudio(id: String) throws {
        let session = try loadSession(id: id)
        guard session.status == .processed else { return }
        _ = removeAudioFile(for: session)
    }

    /// Total bytes of audio that could be reclaimed (processed meetings only).
    public func reclaimableAudioBytes() -> Int64 {
        var total: Int64 = 0
        for session in (try? listSessions()) ?? [] where session.status == .processed {
            let size = (try? fileManager.attributesOfItem(atPath: session.audioPath))?[.size] as? NSNumber
            total += size?.int64Value ?? 0
        }
        return total
    }

    /// Deletes a session's audio file if present and inside our output root.
    /// Returns true if a file was actually removed.
    @discardableResult
    private func removeAudioFile(for session: MeetingSession) -> Bool {
        let url = URL(fileURLWithPath: session.audioPath)
        // Trailing slash on the root so a sibling dir (e.g. ".../zMeetOther") can't
        // satisfy the prefix check against ".../zMeet".
        let root = outputURL.standardizedFileURL.path + "/"
        guard url.standardizedFileURL.path.hasPrefix(root) else { return false }
        // Also drop any leftover diarization tracks in the meeting folder (best-effort)
        // so deleting/purging audio reclaims them too, not just the mixed recording.
        let folder = url.deletingLastPathComponent()
        for track in ["mic.m4a", "system.m4a"] {
            try? fileManager.removeItem(at: folder.appendingPathComponent(track))
        }
        guard fileManager.fileExists(atPath: url.path) else { return false }
        do { try fileManager.removeItem(at: url); return true } catch { return false }
    }

    /// Test-only: overwrite a session record (e.g. to backdate it).
    func overwriteSessionForTesting(_ session: MeetingSession) throws {
        try save(session)
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

    /// Processed meetings as lightweight, Sendable docs the app uses to reconcile
    /// the search index off the main thread.
    public func searchIndexDocuments() -> [SearchIndexDoc] {
        let sessions = (try? listSessions()) ?? []
        return sessions.filter { $0.status == .processed }.map {
            SearchIndexDoc(id: $0.id, title: $0.title, notePath: $0.notePath, transcriptPath: $0.transcriptPath)
        }
    }

    /// Finalizes sessions left in `.recording` by a crash or force-quit. A session
    /// whose audio file exists and is non-empty becomes `.recorded`; otherwise it
    /// becomes `.failed`. Returns the sessions whose status changed.
    @discardableResult
    public func recoverInterruptedSessions() throws -> [MeetingSession] {
        var recovered: [MeetingSession] = []

        for var session in try listSessions() where session.status == .recording {
            let attributes = try? fileManager.attributesOfItem(atPath: session.audioPath)
            let size = (attributes?[.size] as? UInt64) ?? 0

            if size > 0 {
                session.status = .recorded
            } else {
                session.status = .failed
                session.errorMessage = "Recording was interrupted before any audio was captured."
            }
            session.endedAt = session.endedAt ?? Date()

            try save(session)
            recovered.append(session)
        }

        return recovered
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
        try ZMeetPaths.ensureDirectory(logsURL)
        try ZMeetPaths.ensureDirectory(outputURL)
    }

    /// A unique per-meeting folder like `2026-05-26 1755 Weekly Sync` under the
    /// output root, disambiguated with a numeric suffix if it already exists.
    private func uniqueMeetingFolderURL(title: String, startedAt: Date) -> URL {
        let base = "\(ZMeetDates.folderStamp(startedAt)) \(ZMeetText.sanitizeFileName(title))"
        var name = base
        var suffix = 2
        while fileManager.fileExists(atPath: outputURL.appendingPathComponent(name).path) {
            name = "\(base) (\(suffix))"
            suffix += 1
        }
        return outputURL.appendingPathComponent(name, isDirectory: true)
    }

    /// The meeting folder for an existing session, derived from its stored audio path.
    private func meetingFolderURL(for session: MeetingSession) -> URL {
        URL(fileURLWithPath: session.audioPath).deletingLastPathComponent()
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
        meetingFolderURL(for: session).appendingPathComponent("transcript.md")
    }

    private func noteURL(for session: MeetingSession) -> URL {
        meetingFolderURL(for: session).appendingPathComponent("notes.md")
    }
}
