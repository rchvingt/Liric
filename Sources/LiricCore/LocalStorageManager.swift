//
//  LocalStorageManager.swift
//  LiricCore
//
//  Local lyrics cache backed by SQLite (the libsqlite3 that ships with macOS).
//
//  Why SQLite (vs. JSON files vs. Core Data)?
//  ------------------------------------------
//  Workload: 5–10k songs, each with 1–3 text variants (original / romanized / translation),
//  ~2–6 KB per variant ⇒ roughly 30–150 MB on disk. Access pattern: one point lookup per
//  track change, one write per fetched song, occasional eviction.
//
//  • JSON, one big file  – must be fully decoded into RAM (tens of MB) and fully re-written on
//                           every save. Directly contradicts the low-memory goal.
//  • JSON, file per song – OK reads, but no queries (eviction by last access, "songs missing
//                           romanization", stats) without scanning 10k files; no atomic
//                           multi-variant writes; thousands of inodes.
//  • Core Data           – SQLite underneath anyway, plus a managed-object graph, context
//                           threading rules and a model file. Its strengths (object graphs,
//                           undo, CloudKit sync) are things Liric explicitly doesn't need.
//  • SQLite (chosen)     – Indexed lookup < 1 ms at 10k rows, only touched pages are loaded,
//                           page cache capped at 2 MB below, atomic transactions, single file
//                           that's trivial to back up or delete. Zero dependencies.
//
//  Schema: `tracks` (one row per song) 1—N `lyric_variants` (kind = original|romanized|
//  translation). Adding another variant later (e.g. a second romanization style) needs no
//  migration. `misses` remembers "no lyrics anywhere" so we don't hammer APIs for
//  instrumentals/obscure tracks.
//
//  Concurrency: an `actor` owns the single connection, so every statement is serialized
//  without locks (the connection is opened NOMUTEX).
//

import Foundation
import SQLite3

public actor LocalStorageManager {
    public enum Location: Sendable {
        /// ~/Library/Application Support/Liric/lyrics.sqlite
        case applicationSupport
        case file(URL)
        /// For tests and as a last-resort fallback if the disk store can't be opened.
        case inMemory
    }

    /// Re-check sources for "not found" tracks after this long (lyrics get added over time).
    public var missTTL: TimeInterval = 7 * 24 * 3600

    private let db: SQLiteDatabase
    private let maxEntries: Int
    private var savesSincePrune = 0

    public init(location: Location = .applicationSupport, maxEntries: Int = 10_000) throws {
        let path: String
        switch location {
        case .applicationSupport:
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true)
            let dir = support.appendingPathComponent("Liric", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            path = dir.appendingPathComponent("lyrics.sqlite").path
        case let .file(url):
            path = url.path
        case .inMemory:
            path = ":memory:"
        }
        // Set up fully before assigning to self (sync actor inits are nonisolated).
        let database = try SQLiteDatabase(path: path)
        try Self.migrate(database)
        self.db = database
        self.maxEntries = maxEntries
    }

    // MARK: Read

    /// Cached lyrics for a track, or nil. Also bumps the LRU timestamp.
    public func lyrics(for track: TrackInfo) throws -> Lyrics? {
        let rows = try db.query("""
            SELECT id, language, is_instrumental, source, fetched_at
            FROM tracks WHERE lookup_key = ?
            """, [.text(track.lookupKey)]) { row in
            (id: row.int(0), language: row.string(1), instrumental: row.int(2) != 0,
             source: row.string(3), fetchedAt: row.double(4))
        }
        guard let head = rows.first else { return nil }

        var variants: [LyricVariantKind: (text: LyricText, origin: String?)] = [:]
        try db.query("SELECT kind, plain, synced, origin FROM lyric_variants WHERE track_id = ?",
                     [.int(head.id)]) { row -> Void in
            guard let kind = LyricVariantKind(rawValue: row.string(0)) else { return }
            variants[kind] = (LyricText(plain: row.string(1), synced: row.optionalString(2)), row.optionalString(3))
        }

        try db.run("UPDATE tracks SET last_accessed = ? WHERE id = ?",
                   [.double(Date().timeIntervalSince1970), .int(head.id)])

        let romanized = variants[.romanized]
        return Lyrics(
            track: track, // current metadata (keeps fileURL/duration from the player)
            language: LyricLanguage(rawValue: head.language) ?? .undetermined,
            original: variants[.original]?.text ?? LyricText(plain: ""),
            romanized: romanized?.text,
            romanizationOrigin: romanized?.origin.flatMap(RomanizationOrigin.init(rawValue:)),
            translation: variants[.translation]?.text,
            isInstrumental: head.instrumental,
            source: LyricSourceID(rawValue: head.source) ?? .lrclib,
            fetchedAt: Date(timeIntervalSince1970: head.fetchedAt)
        )
    }

    /// True if every source said "not found" for this track within `missTTL`.
    public func isRecentMiss(_ track: TrackInfo) throws -> Bool {
        let cutoff = Date().addingTimeInterval(-missTTL).timeIntervalSince1970
        let hits = try db.query("SELECT 1 FROM misses WHERE lookup_key = ? AND checked_at > ?",
                                [.text(track.lookupKey), .double(cutoff)]) { _ in true }
        return !hits.isEmpty
    }

    public func count() throws -> Int {
        try db.query("SELECT COUNT(*) FROM tracks", []) { Int($0.int(0)) }.first ?? 0
    }

    // MARK: Write

    /// Inserts or replaces a song and all of its variants atomically.
    public func save(_ lyrics: Lyrics) throws {
        let now = Date().timeIntervalSince1970
        let key = lyrics.track.lookupKey
        try db.transaction {
            try db.run("""
                INSERT INTO tracks (lookup_key, title, artist, album, duration, language,
                                    is_instrumental, source, fetched_at, last_accessed)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(lookup_key) DO UPDATE SET
                    title = excluded.title, artist = excluded.artist, album = excluded.album,
                    duration = excluded.duration, language = excluded.language,
                    is_instrumental = excluded.is_instrumental, source = excluded.source,
                    fetched_at = excluded.fetched_at, last_accessed = excluded.last_accessed
                """, [
                    .text(key), .text(lyrics.track.title), .text(lyrics.track.artist),
                    lyrics.track.album.map(SQLValue.text) ?? .null,
                    lyrics.track.duration.map(SQLValue.double) ?? .null,
                    .text(lyrics.language.rawValue), .int(lyrics.isInstrumental ? 1 : 0),
                    .text(lyrics.source.rawValue), .double(lyrics.fetchedAt.timeIntervalSince1970), .double(now),
                ])
            guard let trackID = try db.query("SELECT id FROM tracks WHERE lookup_key = ?",
                                             [.text(key)], { $0.int(0) }).first else {
                throw LiricError.storage("upsert did not produce a row")
            }

            try db.run("DELETE FROM lyric_variants WHERE track_id = ?", [.int(trackID)])
            let variants: [(LyricVariantKind, LyricText?, String, String?)] = [
                (.original, lyrics.original.isEmpty ? nil : lyrics.original, lyrics.language.rawValue, nil),
                (.romanized, lyrics.romanized, "\(lyrics.language.rawValue)-Latn", lyrics.romanizationOrigin?.rawValue),
                (.translation, lyrics.translation, LyricLanguage.undetermined.rawValue, nil),
            ]
            for (kind, text, language, origin) in variants {
                guard let text else { continue }
                try db.run("""
                    INSERT INTO lyric_variants (track_id, kind, language, origin, plain, synced)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, [.int(trackID), .text(kind.rawValue), .text(language),
                          origin.map(SQLValue.text) ?? .null, .text(text.plain),
                          text.synced.map(SQLValue.text) ?? .null])
            }
            try db.run("DELETE FROM misses WHERE lookup_key = ?", [.text(key)])
        }

        savesSincePrune += 1
        if savesSincePrune >= 50 {
            savesSincePrune = 0
            try prune()
        }
    }

    public func recordMiss(_ track: TrackInfo) throws {
        try db.run("INSERT OR REPLACE INTO misses (lookup_key, checked_at) VALUES (?, ?)",
                   [.text(track.lookupKey), .double(Date().timeIntervalSince1970)])
    }

    /// LRU eviction down to `maxEntries` songs (variants cascade).
    public func prune() throws {
        try db.run("""
            DELETE FROM tracks WHERE id IN (
                SELECT id FROM tracks ORDER BY last_accessed DESC LIMIT -1 OFFSET ?)
            """, [.int(Int64(maxEntries))])
        let expired = Date().addingTimeInterval(-missTTL).timeIntervalSince1970
        try db.run("DELETE FROM misses WHERE checked_at < ?", [.double(expired)])
    }

    public func removeAll() throws {
        try db.transaction {
            try db.run("DELETE FROM tracks", [])
            try db.run("DELETE FROM misses", [])
        }
        try db.execute("VACUUM")
    }

    // MARK: Schema

    private static let schemaVersion: Int64 = 1

    private static func migrate(_ db: SQLiteDatabase) throws {
        try db.execute("""
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            PRAGMA foreign_keys = ON;
            PRAGMA cache_size = -2048;   -- cap page cache at ~2 MB
            """)
        let version = try db.query("PRAGMA user_version", []) { $0.int(0) }.first ?? 0
        if version < 1 {
            try db.transaction {
                try db.execute("""
                    CREATE TABLE IF NOT EXISTS tracks (
                        id              INTEGER PRIMARY KEY,
                        lookup_key      TEXT    NOT NULL UNIQUE,  -- normalized "artist|title"
                        title           TEXT    NOT NULL,
                        artist          TEXT    NOT NULL,
                        album           TEXT,
                        duration        REAL,
                        language        TEXT    NOT NULL,         -- ko / ja / en / und
                        is_instrumental INTEGER NOT NULL DEFAULT 0,
                        source          TEXT    NOT NULL,
                        fetched_at      REAL    NOT NULL,
                        last_accessed   REAL    NOT NULL
                    );
                    CREATE INDEX IF NOT EXISTS tracks_last_accessed ON tracks(last_accessed);
                    CREATE TABLE IF NOT EXISTS lyric_variants (
                        track_id INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
                        kind     TEXT    NOT NULL,                -- original / romanized / translation
                        language TEXT    NOT NULL,                -- e.g. ko, ko-Latn, ja-Latn
                        origin   TEXT,                            -- source / generated (romanized only)
                        plain    TEXT    NOT NULL,
                        synced   TEXT,                            -- LRC, when available
                        PRIMARY KEY (track_id, kind)
                    ) WITHOUT ROWID;
                    CREATE TABLE IF NOT EXISTS misses (
                        lookup_key TEXT PRIMARY KEY,
                        checked_at REAL NOT NULL
                    ) WITHOUT ROWID;
                    """)
                try db.execute("PRAGMA user_version = \(schemaVersion)")
            }
        }
        // Future migrations: `if version < 2 { … }`
    }
}

// MARK: - Minimal SQLite wrapper

enum SQLValue {
    case text(String)
    case int(Int64)
    case double(Double)
    case null
}

/// Read accessors for the current row of a statement. Only valid inside a `query` callback.
struct SQLRow {
    fileprivate let statement: OpaquePointer

    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
    func string(_ column: Int32) -> String { optionalString(column) ?? "" }
    func optionalString(_ column: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: cString)
    }
}

/// SQLITE_TRANSIENT: tell SQLite to copy bound strings (Swift's buffers are temporary).
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(path: String) throws {
        // NOMUTEX: the owning actor already serializes access.
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            throw LiricError.storage("open failed: \(message)")
        }
        sqlite3_busy_timeout(handle, 2_000)
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    /// Runs one or more statements without parameters.
    func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? lastError
            sqlite3_free(errorMessage)
            throw LiricError.storage(message)
        }
    }

    /// Runs a single statement with parameters, ignoring any rows.
    func run(_ sql: String, _ parameters: [SQLValue]) throws {
        try query(sql, parameters) { _ in () }
    }

    @discardableResult
    func query<T>(_ sql: String, _ parameters: [SQLValue], _ map: (SQLRow) throws -> T) throws -> [T] {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &prepared, nil) == SQLITE_OK, let statement = prepared else {
            sqlite3_finalize(prepared)
            throw LiricError.storage("prepare failed: \(lastError)")
        }
        defer { sqlite3_finalize(statement) }

        for (offset, value) in parameters.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case let .text(text): status = sqlite3_bind_text(statement, index, text, -1, SQLITE_TRANSIENT)
            case let .int(int): status = sqlite3_bind_int64(statement, index, int)
            case let .double(double): status = sqlite3_bind_double(statement, index, double)
            case .null: status = sqlite3_bind_null(statement, index)
            }
            guard status == SQLITE_OK else { throw LiricError.storage("bind failed: \(lastError)") }
        }

        var results: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                results.append(try map(SQLRow(statement: statement)))
            case SQLITE_DONE:
                return results
            default:
                throw LiricError.storage("step failed: \(lastError)")
            }
        }
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private var lastError: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no connection"
    }
}
