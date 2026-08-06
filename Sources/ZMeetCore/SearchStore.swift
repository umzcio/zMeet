import Foundation
import SQLite3

/// SQLite "transient" destructor — tells SQLite to copy bound text immediately.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A meeting to (re)index, identified by file paths so reconcile can read the
/// authoritative content from disk.
public struct SearchIndexDoc: Sendable, Equatable {
    public let id: String
    public let title: String
    public let notePath: String?
    public let transcriptPath: String?

    public init(id: String, title: String, notePath: String?, transcriptPath: String?) {
        self.id = id
        self.title = title
        self.notePath = notePath
        self.transcriptPath = transcriptPath
    }
}

/// One search result. `snippet` carries highlight markers (U+0002 start,
/// U+0003 end) the UI maps to styled ranges. `score` is higher-is-better.
public struct SearchHit: Sendable, Equatable {
    public let sessionID: String
    public let score: Double
    public let snippet: String

    public init(sessionID: String, score: Double, snippet: String) {
        self.sessionID = sessionID
        self.score = score
        self.snippet = snippet
    }
}

public enum SearchError: Error {
    case open(String)
    case exec(String)
}

/// A persistent full-text index over meetings (title + notes + transcript),
/// backed by SQLite FTS5. The database is a derived cache of the meeting files;
/// it can be deleted and rebuilt at any time. Thread-safe: all database access is
/// serialized on a private queue.
public final class SearchStore: @unchecked Sendable {
    /// Highlight markers wrapped around matched terms in snippets.
    public static let highlightStart = "\u{02}"
    public static let highlightEnd = "\u{03}"

    private static let schemaVersion = 1

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "edu.umontana.zmeet.search")

    public init(databaseURL: URL) throws {
        try ZMeetPaths.ensurePrivateDirectory(databaseURL.deletingLastPathComponent())
        try open(at: databaseURL)
        // Best-effort: -wal/-shm siblings may not exist yet (WAL mode not
        // triggered, or a fresh open) — restrictFile no-ops on a missing path.
        ZMeetPaths.restrictFile(databaseURL)
        ZMeetPaths.restrictFile(URL(fileURLWithPath: databaseURL.path + "-wal"))
        ZMeetPaths.restrictFile(URL(fileURLWithPath: databaseURL.path + "-shm"))
    }

    deinit {
        // close_v2 defers the close until any lingering resources are released,
        // so it never fails even if a statement were somehow still open.
        if let db { sqlite3_close_v2(db) }
    }

    // MARK: Open / schema

    private func open(at url: URL) throws {
        // path(percentEncoded:) gives SQLite the real filesystem path even when
        // the home directory contains spaces or non-ASCII characters.
        let path = url.path(percentEncoded: false)
        // If the file is corrupt, start clean — the index is rebuildable.
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) != SQLITE_OK {
            sqlite3_close_v2(db); db = nil
            try? FileManager.default.removeItem(at: url)
            if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) != SQLITE_OK {
                throw SearchError.open(lastErrorMessage())
            }
        }

        // Overwrite freed pages on DELETE so removed transcripts/notes aren't
        // recoverable from the raw database file — deletion must actually erase
        // the content, not just unlink it from the index.
        try? exec("PRAGMA secure_delete=ON;")

        do {
            try exec("""
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
            CREATE VIRTUAL TABLE IF NOT EXISTS meetings_fts USING fts5(
                session_id UNINDEXED,
                title, notes, transcript,
                tokenize = 'unicode61 remove_diacritics 2'
            );
            """)
        } catch {
            // A schema we can't create (older/corrupt) — drop and recreate once.
            try? exec("DROP TABLE IF EXISTS meetings_fts;")
            try exec("""
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
            CREATE VIRTUAL TABLE meetings_fts USING fts5(
                session_id UNINDEXED,
                title, notes, transcript,
                tokenize = 'unicode61 remove_diacritics 2'
            );
            """)
        }

        // Reset the index whenever the stored schema version differs. Only record
        // the new version once the clear actually succeeds, so a failed reset
        // isn't masked as an up-to-date index.
        let stored = Int(metaValue(forKey: "schema_version") ?? "") ?? 0
        if stored != Self.schemaVersion {
            try exec("DELETE FROM meetings_fts;")
            setMeta(key: "schema_version", value: String(Self.schemaVersion))
        }
    }

    // MARK: Low-level helpers (call inside `queue`)

    private func exec(_ sql: String) throws {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            throw SearchError.exec(lastErrorMessage())
        }
    }

    private func lastErrorMessage() -> String {
        db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown sqlite error"
    }

    private func metaValue(forKey key: String) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = ?;", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: c)
    }

    private func setMeta(key: String, value: String) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?);", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, value, -1, SQLITE_TRANSIENT)
        _ = sqlite3_step(stmt)
    }

    // MARK: Public API

    /// Insert or replace a meeting's indexed content. The delete+insert runs in a
    /// transaction so a failure can't leave the meeting half-removed from the index.
    public func index(sessionID: String, title: String, notes: String, transcript: String) throws {
        try queue.sync {
            try exec("BEGIN;")
            do {
                try execStmt("DELETE FROM meetings_fts WHERE session_id = ?;") { stmt in
                    sqlite3_bind_text(stmt, 1, sessionID, -1, SQLITE_TRANSIENT)
                }
                try execStmt("INSERT INTO meetings_fts(session_id, title, notes, transcript) VALUES(?, ?, ?, ?);") { stmt in
                    sqlite3_bind_text(stmt, 1, sessionID, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 2, title, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 3, notes, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 4, transcript, -1, SQLITE_TRANSIENT)
                }
                try exec("COMMIT;")
            } catch {
                try? exec("ROLLBACK;")
                throw error
            }
        }
    }

    public func remove(sessionID: String) throws {
        try queue.sync {
            try execStmt("DELETE FROM meetings_fts WHERE session_id = ?;") { stmt in
                sqlite3_bind_text(stmt, 1, sessionID, -1, SQLITE_TRANSIENT)
            }
        }
    }

    /// Update just the title of an already-indexed meeting, leaving its notes and
    /// transcript content intact (so renaming doesn't drop a meeting's body from
    /// search). A no-op if the meeting isn't indexed.
    public func updateTitle(sessionID: String, title: String) throws {
        try queue.sync {
            try execStmt("UPDATE meetings_fts SET title = ? WHERE session_id = ?;") { stmt in
                sqlite3_bind_text(stmt, 1, title, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, sessionID, -1, SQLITE_TRANSIENT)
            }
        }
    }

    public func removeAll() throws {
        try queue.sync { try exec("DELETE FROM meetings_fts;") }
    }

    /// Prepare a statement, let the caller bind, step it once, finalize.
    private func execStmt(_ sql: String, bind: (OpaquePointer?) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SearchError.exec(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw SearchError.exec(lastErrorMessage())
        }
    }

    /// Build an FTS5 MATCH expression: alphanumeric terms, AND-ed, with the last
    /// term prefix-matched for as-you-type. Returns nil when there is no term.
    static func buildMatch(_ raw: String) -> String? {
        let parts = raw.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        var quoted = parts.map { "\"\($0)\"" }
        quoted[quoted.count - 1] += "*"   // prefix-match the final token
        return quoted.joined(separator: " ")
    }

    /// Full-text search, ranked best-first. Columns: 0 session_id, 1 title,
    /// 2 notes, 3 transcript. Title is weighted heaviest. Returns an empty array
    /// on a query with no terms, and also (defensively) if the statement fails to
    /// prepare — which would indicate a corrupt/missing index rather than "no
    /// matches"; reconcile/reopen rebuilds it.
    public func search(_ query: String, limit: Int) -> [SearchHit] {
        guard let match = Self.buildMatch(query) else { return [] }
        return queue.sync {
            let sql = """
            SELECT session_id,
                   bm25(meetings_fts, 0.0, 10.0, 4.0, 1.0) AS rank,
                   snippet(meetings_fts, 1, char(2), char(3), '…', 10) AS snip_title,
                   snippet(meetings_fts, 2, char(2), char(3), '…', 12) AS snip_notes,
                   snippet(meetings_fts, 3, char(2), char(3), '…', 14) AS snip_tx
            FROM meetings_fts
            WHERE meetings_fts MATCH ?
            ORDER BY rank
            LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, match, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(clamping: limit))

            var hits: [SearchHit] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let idC = sqlite3_column_text(stmt, 0) else { continue }
                let id = String(cString: idC)
                let rank = sqlite3_column_double(stmt, 1)
                let snipTitle = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                let snipNotes = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
                let snipTx = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
                // Prefer whichever column actually contains a highlighted match
                // (transcript → notes → title), so even a title-only hit yields a
                // highlighted snippet. Fall back to any available context text.
                let snippet: String
                if snipTx.contains(Self.highlightStart) { snippet = snipTx }
                else if snipNotes.contains(Self.highlightStart) { snippet = snipNotes }
                else if snipTitle.contains(Self.highlightStart) { snippet = snipTitle }
                else if !snipTx.isEmpty { snippet = snipTx }
                else if !snipNotes.isEmpty { snippet = snipNotes }
                else { snippet = snipTitle }
                hits.append(SearchHit(sessionID: id, score: -rank, snippet: snippet))
            }
            return hits
        }
    }

    /// Make the index match `documents`: drop rows whose meeting no longer
    /// exists, and index any document not already present (reading its content via
    /// `readFile`). Already-indexed meetings are left untouched. Failures on a
    /// single document are skipped; the next reconcile retries.
    public func reconcile(documents: [SearchIndexDoc], readFile: @Sendable (String) -> String?) {
        let current = Set(documents.map(\.id))
        let existing = (try? indexedIDs()) ?? []

        for orphan in existing.subtracting(current) {
            try? remove(sessionID: orphan)
        }
        for doc in documents where !existing.contains(doc.id) {
            let notes = doc.notePath.flatMap(readFile) ?? ""
            let transcript = doc.transcriptPath.flatMap(readFile) ?? ""
            try? index(sessionID: doc.id, title: doc.title, notes: notes, transcript: transcript)
        }
    }

    /// Reads back an integer PRAGMA value. Internal (not public API) — exists so
    /// tests can assert on connection-level settings like `secure_delete`.
    func pragmaIntValue(_ name: String) -> Int? {
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA \(name);", -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return Int(sqlite3_column_int(stmt, 0))
        }
    }

    public func indexedIDs() throws -> Set<String> {
        try queue.sync {
            var ids = Set<String>()
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT session_id FROM meetings_fts;", -1, &stmt, nil) == SQLITE_OK else {
                throw SearchError.exec(lastErrorMessage())
            }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 0) { ids.insert(String(cString: c)) }
            }
            return ids
        }
    }
}
