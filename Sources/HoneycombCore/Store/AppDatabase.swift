import Foundation
import GRDB

/// The one SQLite database. Only `Store` touches it. WAL mode, foreign keys on, and every
/// migration is append-only: a shipped migration is never edited.
public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter
    public var reader: any DatabaseReader { writer }

    public enum OpenError: Error {
        /// The database was written by a newer Honeycomb. Opening it could lose data.
        case newerThanApp
    }

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        let migrator = Self.migrator
        if try writer.read({ try migrator.hasBeenSuperseded($0) }) { throw OpenError.newerThanApp }
        try migrator.migrate(writer)
    }

    public static func open(at url: URL, backups: URL) throws -> AppDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        let pool = try DatabasePool(path: url.path, configuration: config)
        try backupBeforeMigrating(pool, to: backups)
        return try AppDatabase(pool)
    }

    public static func inMemory() throws -> AppDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        return try AppDatabase(DatabaseQueue(configuration: config))
    }

    /// Copies the database before a migration runs and keeps the last 3 copies.
    private static func backupBeforeMigrating(_ pool: DatabasePool, to folder: URL) throws {
        let pending = try pool.read { db in
            try !migrator.completedMigrations(db).isEmpty && !migrator.hasCompletedMigrations(db)
        }
        guard pending else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let copy = try DatabaseQueue(path: folder.appendingPathComponent("honeycomb-\(stamp).sqlite").path)
        try pool.backup(to: copy)
        let old = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "sqlite" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .dropFirst(3)
        for url in old { try? FileManager.default.removeItem(at: url) }
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "meeting") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("title_source", .text).notNull()
                t.column("call_app_id", .text)
                t.column("start_at", .datetime)
                t.column("end_at", .datetime)
                t.column("duration_ms", .integer)
                t.column("state", .text).notNull()
                t.column("state_detail", .text)
                t.column("template_id", .text)
                t.column("current_enhanced_id", .text)
                t.column("audio_dir", .text)
                t.column("md_path", .text)
                t.column("md_hash", .text)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }
            try db.create(index: "meeting_created", on: "meeting", columns: ["created_at"])

            try db.create(table: "segment") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("meeting_id", .text).notNull().references("meeting", onDelete: .cascade).indexed()
                t.column("channel", .text).notNull()
                t.column("start_ms", .integer).notNull()
                t.column("end_ms", .integer).notNull()
                t.column("text", .text).notNull()
                t.column("pass", .text).notNull()
                t.column("engine", .text).notNull()
                t.column("is_duplicate", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "segment_time", on: "segment", columns: ["meeting_id", "pass", "start_ms"])

            try db.create(table: "gap") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("meeting_id", .text).notNull().references("meeting", onDelete: .cascade).indexed()
                t.column("start_ms", .integer).notNull()
                t.column("end_ms", .integer).notNull()
                t.column("reason", .text).notNull()
            }

            try db.create(table: "user_note") { t in
                t.primaryKey("meeting_id", .text).references("meeting", onDelete: .cascade)
                t.column("doc", .text)
                t.column("markdown", .text).notNull().defaults(to: "")
                t.column("schema_version", .integer).notNull()
                t.column("updated_at", .datetime).notNull()
            }

            try db.create(table: "enhanced") { t in
                t.primaryKey("id", .text)
                t.column("meeting_id", .text).notNull().references("meeting", onDelete: .cascade).indexed()
                t.column("template_id", .text)
                t.column("model", .text)
                t.column("doc", .text)
                t.column("markdown", .text).notNull().defaults(to: "")
                t.column("schema_version", .integer).notNull()
                t.column("status", .text).notNull()
                t.column("error_code", .text)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }

            try db.create(table: "template") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("instructions", .text).notNull()
                t.column("sections", .jsonText).notNull()
                t.column("built_in", .boolean).notNull()
                t.column("updated_at", .datetime).notNull()
            }

            try db.create(table: "recipe") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("prompt", .text).notNull()
                t.column("scope", .text).notNull()
                t.column("built_in", .boolean).notNull()
                t.column("updated_at", .datetime).notNull()
            }

            try db.create(table: "dictionary_term") { t in
                t.primaryKey("term", .text).collate(.nocase)
                t.column("kind", .text).notNull()
                t.column("created_at", .datetime).notNull()
            }

            try db.create(table: "note_source") { t in
                t.column("enhanced_id", .text).notNull().references("enhanced", onDelete: .cascade)
                t.column("block_id", .text).notNull()
                t.column("segment_id", .integer).notNull().references("segment", onDelete: .cascade)
                t.column("score", .double).notNull()
                t.primaryKey(["enhanced_id", "block_id", "segment_id"])
            }

            try db.create(table: "call_app") { t in
                t.primaryKey("bundle_id", .text)
                t.column("name", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("ask", .boolean).notNull()
                t.column("added_by", .text).notNull()
            }

            try db.create(table: "chunk") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("meeting_id", .text).notNull().references("meeting", onDelete: .cascade).indexed()
                t.column("source", .text).notNull()
                t.column("text", .text).notNull()
                t.column("start_ms", .integer)
                t.column("end_ms", .integer)
                t.column("vector", .blob)
                t.column("dims", .integer)
                t.column("embed_model", .text)
            }
            try db.create(virtualTable: "chunk_fts", using: FTS5()) { t in
                t.synchronize(withTable: "chunk")
                t.tokenizer = .porter(wrapping: .unicode61())
                t.column("text")
            }

            try db.create(table: "model") { t in
                t.primaryKey("id", .text)
                t.column("kind", .text).notNull()
                t.column("revision", .text).notNull()
                t.column("path", .text).notNull()
                t.column("size_bytes", .integer).notNull()
                t.column("sha256", .text)
                t.column("status", .text).notNull()
                t.column("last_used_at", .datetime)
            }

            try db.create(table: "job") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("meeting_id", .text).references("meeting", onDelete: .cascade).indexed()
                t.column("kind", .text).notNull()
                t.column("args", .jsonText)
                t.column("status", .text).notNull()
                t.column("attempt", .integer).notNull().defaults(to: 0)
                t.column("not_before", .datetime)
                t.column("error_code", .text)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }
            try db.create(index: "job_ready", on: "job", columns: ["status", "not_before"])
        }
        return migrator
    }
}
