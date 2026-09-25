import Foundation
import GRDB

public struct DatabaseSchemaError: Error, LocalizedError, Equatable {
    public var message: String

    public init(message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

public enum TranscriptSchema {
    public static let createTranscriptions = """
    CREATE TABLE IF NOT EXISTS transcriptions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      timestamp TEXT NOT NULL,
      text TEXT NOT NULL,
      raw_output TEXT NOT NULL,
      speaker TEXT NOT NULL DEFAULT 'caller'
    )
    """

    public static let createAnnotations = """
    CREATE TABLE IF NOT EXISTS annotations (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      after_transcription_id INTEGER,
      timestamp TEXT NOT NULL,
      text TEXT NOT NULL,
      kind TEXT NOT NULL DEFAULT 'note',
      FOREIGN KEY (after_transcription_id) REFERENCES transcriptions(id)
    )
    """

    public static func create(_ db: Database) throws {
        try db.execute(sql: createTranscriptions)
        try db.execute(sql: createAnnotations)
        try migrate(db)
    }

    /// Older databases have no speaker. Those rows were recorded before call
    /// audio and the microphone were separated, so they are marked caller.
    /// Older annotations have no kind, and are ordinary notes.
    public static func migrate(_ db: Database) throws {
        if try !columnNames(db, table: "transcriptions").contains("speaker") {
            try db.execute(
                sql: "ALTER TABLE transcriptions ADD COLUMN speaker TEXT NOT NULL DEFAULT 'caller'"
            )
        }
        if try !columnNames(db, table: "annotations").contains("kind") {
            try db.execute(
                sql: "ALTER TABLE annotations ADD COLUMN kind TEXT NOT NULL DEFAULT 'note'"
            )
        }
        try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS action_items (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          timestamp TEXT NOT NULL,
          text TEXT NOT NULL,
          done INTEGER NOT NULL DEFAULT 0
        )
        """)
        try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS action_extractor_state (
          id INTEGER PRIMARY KEY CHECK (id = 1),
          last_transcription_id INTEGER NOT NULL
        )
        """)
        try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS daily_summaries (
          day TEXT PRIMARY KEY,
          text TEXT NOT NULL,
          generated_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        )
        """)
        try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS knowledge_documents (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          title TEXT NOT NULL,
          description TEXT NOT NULL,
          text TEXT NOT NULL,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          allow_llm_updates INTEGER NOT NULL DEFAULT 0
        )
        """)
        if try !columnNames(db, table: "knowledge_documents").contains("allow_llm_updates") {
            try db.execute(sql: """
            ALTER TABLE knowledge_documents
            ADD COLUMN allow_llm_updates INTEGER NOT NULL DEFAULT 0
            """)
        }
        try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS knowledge_document_versions (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          document_id INTEGER NOT NULL,
          title TEXT NOT NULL,
          description TEXT NOT NULL,
          text TEXT NOT NULL,
          saved_at TEXT NOT NULL
        )
        """)
        try db.execute(sql: """
        CREATE INDEX IF NOT EXISTS knowledge_document_versions_document
          ON knowledge_document_versions(document_id)
        """)
    }

    private static func columnNames(_ db: Database, table: String) throws -> [String] {
        let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
        return columns.map { row in
            let name: String = row["name"]
            return name
        }
    }

    public static func validate(_ db: Database) throws {
        try require(
            table: "transcriptions",
            columns: [
                "id": "INTEGER",
                "timestamp": "TEXT",
                "text": "TEXT",
                "raw_output": "TEXT",
            ],
            in: db
        )
        try require(
            table: "annotations",
            columns: [
                "id": "INTEGER",
                "after_transcription_id": "INTEGER",
                "timestamp": "TEXT",
                "text": "TEXT",
            ],
            in: db
        )
    }

    private static func require(table: String, columns expected: [String: String], in db: Database) throws {
        let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
        if rows.isEmpty {
            throw DatabaseSchemaError(message: "This database has no \(table) table.")
        }
        var found: [String: String] = [:]
        for row in rows {
            let name: String = row["name"]
            let type: String = row["type"]
            found[name] = type.uppercased()
        }
        for (name, type) in expected.sorted(by: { $0.key < $1.key }) {
            guard let actual = found[name] else {
                throw DatabaseSchemaError(message: "This database is missing \(table).\(name).")
            }
            if !actual.contains(type) {
                throw DatabaseSchemaError(
                    message: "Column \(table).\(name) is \(actual), expected \(type)."
                )
            }
        }
    }
}
