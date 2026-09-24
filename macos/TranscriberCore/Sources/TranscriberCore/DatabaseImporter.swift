import Foundation
import GRDB

public enum DatabaseImporter {
    public static func importDatabase(from sourceURL: URL, to destinationURL: URL) throws {
        if sourceURL.standardizedFileURL == destinationURL.standardizedFileURL {
            throw DatabaseSchemaError(message: "Choose a database that is not already the app database.")
        }

        var sourceConfig = Configuration()
        sourceConfig.readonly = true
        let source = try DatabaseQueue(path: sourceURL.path, configuration: sourceConfig)
        try source.read { db in
            try TranscriptSchema.validate(db)
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporary = destinationURL.appendingPathExtension("importing")
        try removeDatabaseFiles(at: temporary)

        do {
            let destination = try DatabaseQueue(path: temporary.path)
            try source.backup(to: destination)
        }

        try removeDatabaseFiles(at: destinationURL)
        try fileManager.moveItem(at: temporary, to: destinationURL)
    }

    public static func createEmptyDatabase(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try removeDatabaseFiles(at: url)
        let database = try DatabaseQueue(path: url.path)
        try database.write { db in
            try TranscriptSchema.create(db)
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
    }

    public static func removeDatabaseFiles(at url: URL) throws {
        let fileManager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let path = url.path + suffix
            if fileManager.fileExists(atPath: path) {
                try fileManager.removeItem(atPath: path)
            }
        }
    }
}
