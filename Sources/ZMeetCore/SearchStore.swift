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
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try open(at: databaseURL)
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: Open / schema

    private func open(at url: URL) throws {
        // If the file is corrupt, start clean — the index is rebuildable.
        if sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) != SQLITE_OK {
            sqlite3_close(db); db = nil
            try? FileManager.default.removeItem(at: url)
            if sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) != SQLITE_OK {
                throw SearchError.open(lastErrorMessage())
            }
        }

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
            CREATE VIRTUAL TABLE meetings_fts USING fts5(
                session_id UNINDEXED,
                title, notes, transcript,
                tokenize = 'unicode61 remove_diacritics 2'
            );
            """)
        }

        // Reset the index whenever the stored schema version differs.
        let stored = Int(metaValue(forKey: "schema_version") ?? "") ?? 0
        if stored != Self.schemaVersion {
            try? exec("DELETE FROM meetings_fts;")
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
