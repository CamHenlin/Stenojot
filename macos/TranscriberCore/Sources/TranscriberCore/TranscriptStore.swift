import Foundation
import GRDB

public final class TranscriptStore: @unchecked Sendable {
    private let pool: DatabasePool

    public init(path: String) throws {
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        pool = try DatabasePool(path: path, configuration: configuration)
        try pool.write { db in
            try TranscriptSchema.create(db)
        }
    }

    public func fetchDates() throws -> [String] {
        try fetchDates(matching: nil)
    }

    /// Days that contain a visible search hit, newest first. An empty search returns every day.
    /// Anchored notes are visible only when their transcription also matches, so a day is included
    /// for a matching note only when that note is leading or its transcription matches.
    public func fetchDates(matching search: String?) throws -> [String] {
        let trimmed = search?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            return try pool.read { db in
                try String.fetchAll(db, sql: """
                SELECT DISTINCT d FROM (
                  SELECT \(Self.localDay) AS d FROM transcriptions
                  UNION
                  SELECT \(Self.localDay) AS d FROM annotations
                )
                WHERE d IS NOT NULL
                ORDER BY d DESC
                """)
            }
        }
        let pattern = "%\(trimmed)%"
        return try pool.read { db in
            try String.fetchAll(db, sql: """
            SELECT DISTINCT d FROM (
              SELECT \(Self.localDay) AS d FROM transcriptions WHERE text LIKE ?
              UNION
              SELECT date(a.timestamp, 'localtime') AS d
              FROM annotations a
              WHERE a.text LIKE ? AND (
                a.after_transcription_id IS NULL
                OR EXISTS (
                  SELECT 1 FROM transcriptions t
                  WHERE t.id = a.after_transcription_id
                    AND t.text LIKE ?
                    AND date(t.timestamp, 'localtime') = date(a.timestamp, 'localtime')
                )
              )
            )
            WHERE d IS NOT NULL
            ORDER BY d DESC
            """, arguments: [pattern, pattern, pattern])
        }
    }

    public func fetchTimeline(date: String?, search: String?) throws -> [TimelineItem] {
        try pool.read { db in
            let transcriptions = try Self.transcriptions(db, date: date, search: search, afterId: nil)
            let annotations = try Self.annotations(db, date: date, search: search, afterId: nil)
            return Timeline.merge(transcriptions: transcriptions, annotations: annotations)
        }
    }

    /// Calendar day of a stored timestamp in the Mac's local timezone.
    public func localDay(of timestamp: String) throws -> String? {
        try pool.read { db in
            try String.fetchOne(db, sql: "SELECT date(?, 'localtime')", arguments: [timestamp])
        }
    }

    public func insertTranscription(
        timestamp: String,
        text: String,
        rawOutput: String,
        speaker: String = Speaker.caller.rawValue
    ) throws -> TranscriptionRow {
        try pool.write { db in
            try db.execute(
                sql: "INSERT INTO transcriptions (timestamp, text, raw_output, speaker) VALUES (?, ?, ?, ?)",
                arguments: [timestamp, text, rawOutput, speaker]
            )
            return TranscriptionRow(
                id: db.lastInsertedRowID,
                timestamp: timestamp,
                text: text,
                speaker: speaker
            )
        }
    }

    /// The most recently stored transcript line, which is the line a new utterance follows.
    public func latestTranscription() throws -> TranscriptionRow? {
        try pool.read { db in
            try TranscriptionRow.fetchOne(db, sql: """
            SELECT id, timestamp, text, speaker FROM transcriptions
            ORDER BY id DESC
            LIMIT 1
            """)
        }
    }

    public func insertAnnotation(
        afterTranscriptionId: Int64?,
        text: String,
        timestamp: String,
        kind: AnnotationKind = .note
    ) throws -> AnnotationRow {
        try pool.write { db in
            let arguments: StatementArguments = [afterTranscriptionId, timestamp, text, kind.rawValue]
            try db.execute(
                sql: "INSERT INTO annotations (after_transcription_id, timestamp, text, kind) VALUES (?, ?, ?, ?)",
                arguments: arguments
            )
            return AnnotationRow(
                id: db.lastInsertedRowID,
                afterTranscriptionId: afterTranscriptionId,
                timestamp: timestamp,
                text: text,
                kind: kind
            )
        }
    }

    public func updateAnnotation(id: Int64, text: String) throws {
        try pool.write { db in
            try db.execute(
                sql: "UPDATE annotations SET text = ? WHERE id = ?",
                arguments: [text, id]
            )
        }
    }

    public func deleteAnnotation(id: Int64) throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM annotations WHERE id = ?", arguments: [id])
        }
    }

    public func fetchDailySummaries() throws -> [DailySummary] {
        try pool.read { db in
            try DailySummary.fetchAll(db, sql: """
            SELECT day, text, generated_at, updated_at FROM daily_summaries
            ORDER BY day DESC
            """)
        }
    }

    public func fetchDailySummary(day: String) throws -> DailySummary? {
        try pool.read { db in
            try DailySummary.fetchOne(db, sql: """
            SELECT day, text, generated_at, updated_at FROM daily_summaries
            WHERE day = ?
            """, arguments: [day])
        }
    }

    /// Inserts a generated summary. A day that already has one is left unchanged.
    @discardableResult
    public func insertDailySummaryIfAbsent(day: String, text: String, timestamp: String) throws -> Bool {
        try pool.write { db in
            try db.execute(sql: """
            INSERT INTO daily_summaries (day, text, generated_at, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(day) DO NOTHING
            """, arguments: [day, text, timestamp, timestamp])
            return db.changesCount > 0
        }
    }

    public func updateDailySummary(day: String, text: String, timestamp: String) throws {
        try pool.write { db in
            try db.execute(
                sql: "UPDATE daily_summaries SET text = ?, updated_at = ? WHERE day = ?",
                arguments: [text, timestamp, day]
            )
        }
    }

    /// Newest edits first, so the document just saved stays at the top of the list.
    public func fetchKnowledgeDocuments() throws -> [KnowledgeDocument] {
        try pool.read { db in
            try KnowledgeDocument.fetchAll(db, sql: """
            SELECT \(Self.knowledgeDocumentColumns)
            FROM knowledge_documents
            ORDER BY updated_at DESC, id DESC
            """)
        }
    }

    public func fetchKnowledgeDocument(id: Int64) throws -> KnowledgeDocument? {
        try pool.read { db in
            try KnowledgeDocument.fetchOne(db, sql: """
            SELECT \(Self.knowledgeDocumentColumns)
            FROM knowledge_documents
            WHERE id = ?
            """, arguments: [id])
        }
    }

    public func insertKnowledgeDocument(
        title: String,
        description: String,
        text: String,
        timestamp: String
    ) throws -> KnowledgeDocument {
        try pool.write { db in
            try db.execute(sql: """
            INSERT INTO knowledge_documents (title, description, text, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?)
            """, arguments: [title, description, text, timestamp, timestamp])
            return KnowledgeDocument(
                id: db.lastInsertedRowID,
                title: title,
                description: description,
                text: text,
                createdAt: timestamp,
                updatedAt: timestamp,
                allowsLLMUpdates: false
            )
        }
    }

    /// Newest archived save first.
    public func fetchKnowledgeVersions(documentID: Int64) throws -> [KnowledgeDocumentVersion] {
        try pool.read { db in
            try KnowledgeDocumentVersion.fetchAll(db, sql: """
            SELECT id, document_id, title, description, text, saved_at
            FROM knowledge_document_versions
            WHERE document_id = ?
            ORDER BY saved_at DESC, id DESC
            """, arguments: [documentID])
        }
    }

    /// Documents the model is allowed to revise, in a stable order.
    public func fetchKnowledgeDocumentsAllowingLLMUpdates() throws -> [KnowledgeDocument] {
        try pool.read { db in
            try KnowledgeDocument.fetchAll(db, sql: """
            SELECT \(Self.knowledgeDocumentColumns)
            FROM knowledge_documents
            WHERE allow_llm_updates != 0
            ORDER BY id ASC
            """)
        }
    }

    /// Turns model updates on or off without archiving a version or changing `updated_at`.
    public func setKnowledgeDocumentAllowsLLMUpdates(id: Int64, allowed: Bool) throws {
        try pool.write { db in
            try db.execute(
                sql: "UPDATE knowledge_documents SET allow_llm_updates = ? WHERE id = ?",
                arguments: [allowed ? 1 : 0, id]
            )
        }
    }

    /// Archives the current text when the edit changes it, then writes the new text. `created_at` stays on the original insert.
    /// When `expectedUpdatedAt` is set, a document saved since that timestamp is left unchanged.
    @discardableResult
    public func updateKnowledgeDocument(
        id: Int64,
        title: String,
        description: String,
        text: String,
        timestamp: String,
        expectedUpdatedAt: String? = nil
    ) throws -> KnowledgeDocumentUpdate {
        try pool.write { db in
            guard let current = try KnowledgeDocument.fetchOne(db, sql: """
            SELECT \(Self.knowledgeDocumentColumns)
            FROM knowledge_documents
            WHERE id = ?
            """, arguments: [id]) else {
                return .unchanged
            }
            if let expectedUpdatedAt, current.updatedAt != expectedUpdatedAt {
                return .unchanged
            }
            if current.title == title && current.description == description && current.text == text {
                return .unchanged
            }
            try db.execute(sql: """
            INSERT INTO knowledge_document_versions (document_id, title, description, text, saved_at)
            VALUES (?, ?, ?, ?, ?)
            """, arguments: [id, current.title, current.description, current.text, current.updatedAt])
            let version = KnowledgeDocumentVersion(
                id: db.lastInsertedRowID,
                documentId: id,
                title: current.title,
                description: current.description,
                text: current.text,
                savedAt: current.updatedAt
            )
            try db.execute(sql: """
            UPDATE knowledge_documents
            SET title = ?, description = ?, text = ?, updated_at = ?
            WHERE id = ?
            """, arguments: [title, description, text, timestamp, id])
            return .saved(version)
        }
    }

    public func deleteKnowledgeDocument(id: Int64) throws {
        try pool.write { db in
            try db.execute(
                sql: "DELETE FROM knowledge_document_versions WHERE document_id = ?",
                arguments: [id]
            )
            try db.execute(sql: "DELETE FROM knowledge_documents WHERE id = ?", arguments: [id])
        }
    }

    /// Writes a newly generated summary, replacing one already stored for that day.
    public func replaceDailySummary(day: String, text: String, timestamp: String) throws {
        try pool.write { db in
            try db.execute(sql: """
            INSERT INTO daily_summaries (day, text, generated_at, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(day) DO UPDATE SET
                text = excluded.text,
                generated_at = excluded.generated_at,
                updated_at = excluded.updated_at
            """, arguments: [day, text, timestamp, timestamp])
        }
    }

    public func fetchActionItems() throws -> [ActionItem] {
        try pool.read { db in
            let items = try ActionItem.fetchAll(
                db,
                sql: "SELECT id, timestamp, text, done FROM action_items"
            )
            return items.sorted(by: Self.actionItemIsNewer)
        }
    }

    public func fetchActionItems(onDay day: String) throws -> [ActionItem] {
        try pool.read { db in
            try ActionItem.fetchAll(db, sql: """
            SELECT id, timestamp, text, done FROM action_items
            WHERE date(timestamp, 'localtime') = ?
            ORDER BY timestamp ASC, id ASC
            """, arguments: [day])
        }
    }

    public func insertActionItem(text: String, timestamp: String) throws -> ActionItem {
        try pool.write { db in
            try Self.insertActionItem(db, text: text, timestamp: timestamp)
        }
    }

    public func setActionItemDone(id: Int64, done: Bool) throws {
        try pool.write { db in
            try db.execute(
                sql: "UPDATE action_items SET done = ? WHERE id = ?",
                arguments: [done ? 1 : 0, id]
            )
        }
    }

    public func deleteActionItem(id: Int64) throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM action_items WHERE id = ?", arguments: [id])
        }
    }

    public func fetchTranscriptions(afterId: Int64) throws -> [TranscriptionRow] {
        try pool.read { db in
            try TranscriptionRow.fetchAll(db, sql: """
            SELECT id, timestamp, text, speaker FROM transcriptions
            WHERE id > ?
            ORDER BY timestamp ASC, id ASC
            """, arguments: [afterId])
        }
    }

    /// The first time extraction is armed, mark every transcript already stored as handled
    /// so older conversations are not sent to the model.
    @discardableResult
    public func prepareActionExtractor() throws -> Int64 {
        try pool.write { db in
            if let existing = try Int64.fetchOne(
                db,
                sql: "SELECT last_transcription_id FROM action_extractor_state WHERE id = 1"
            ) {
                return existing
            }
            let maxId = try Int64.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(id), 0) FROM transcriptions"
            ) ?? 0
            try db.execute(
                sql: "INSERT INTO action_extractor_state (id, last_transcription_id) VALUES (1, ?)",
                arguments: [maxId]
            )
            return maxId
        }
    }

    public func actionExtractorWatermark() throws -> Int64 {
        try pool.read { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT last_transcription_id FROM action_extractor_state WHERE id = 1"
            ) ?? 0
        }
    }

    /// Saves extracted tasks and advances the watermark in one write.
    /// An empty list still advances the watermark, so a quiet segment is not sent again.
    public func saveExtractedActionItems(
        _ texts: [String],
        timestamp: String,
        watermark: Int64
    ) throws -> [ActionItem] {
        try pool.write { db in
            var saved: [ActionItem] = []
            for text in texts {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                saved.append(try Self.insertActionItem(db, text: trimmed, timestamp: timestamp))
            }
            try db.execute(
                sql: """
                UPDATE action_extractor_state
                SET last_transcription_id = ?
                WHERE id = 1 AND last_transcription_id < ?
                """,
                arguments: [watermark, watermark]
            )
            return saved
        }
    }

    public func applyReplacements(_ rules: [ReplacementRule]) throws -> ApplyReplacementsResult {
        try pool.write { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, text FROM transcriptions")
            var updated = 0
            var deleted = 0
            for row in rows {
                let id: Int64 = row["id"]
                let text: String = row["text"]
                let cleaned = ReplacementEngine.apply(rules, to: text)
                if cleaned == text { continue }
                if cleaned.isEmpty {
                    try db.execute(
                        sql: "DELETE FROM annotations WHERE after_transcription_id = ?",
                        arguments: [id]
                    )
                    try db.execute(sql: "DELETE FROM transcriptions WHERE id = ?", arguments: [id])
                    deleted += 1
                } else {
                    try db.execute(
                        sql: "UPDATE transcriptions SET text = ? WHERE id = ?",
                        arguments: [cleaned, id]
                    )
                }
                updated += 1
            }
            return ApplyReplacementsResult(total: rows.count, updated: updated, deleted: deleted)
        }
    }

    public func fetchModelContext(date: String?, fromId: Int64?, toId: Int64?) throws -> ModelContext {
        try pool.read { db in
            let hasRange = fromId != nil && toId != nil
            if hasRange {
                let low = min(fromId!, toId!)
                let high = max(fromId!, toId!)
                let transcriptions = try TranscriptionRow.fetchAll(db, sql: """
                SELECT id, timestamp, text, speaker FROM transcriptions
                WHERE id >= ? AND id <= ?
                ORDER BY timestamp ASC
                """, arguments: [low, high])
                let annotations = try AnnotationRow.fetchAll(db, sql: """
                SELECT id, after_transcription_id, timestamp, text, kind FROM annotations
                WHERE after_transcription_id >= ? AND after_transcription_id <= ?
                ORDER BY timestamp ASC, id ASC
                """, arguments: [low, high])
                return ModelContext(transcriptions: transcriptions, annotations: annotations)
            }

            let transcriptions = try Self.transcriptions(db, date: date, search: nil, afterId: nil)
            let annotations = try Self.annotations(db, date: date, search: nil, afterId: nil)
            return ModelContext(transcriptions: transcriptions, annotations: annotations)
        }
    }

    private static func transcriptions(
        _ db: Database,
        date: String?,
        search: String?,
        afterId: Int64?
    ) throws -> [TranscriptionRow] {
        var sql = "SELECT id, timestamp, text, speaker FROM transcriptions"
        let (clause, arguments) = filters(date: date, search: search, afterColumn: "id", afterId: afterId)
        if !clause.isEmpty {
            sql += " WHERE " + clause
        }
        sql += " ORDER BY timestamp ASC"
        return try TranscriptionRow.fetchAll(db, sql: sql, arguments: arguments)
    }

    private static func annotations(
        _ db: Database,
        date: String?,
        search: String?,
        afterId: Int64?
    ) throws -> [AnnotationRow] {
        var sql = "SELECT id, after_transcription_id, timestamp, text, kind FROM annotations"
        let (clause, arguments) = filters(date: date, search: search, afterColumn: "id", afterId: afterId)
        if !clause.isEmpty {
            sql += " WHERE " + clause
        }
        sql += " ORDER BY timestamp ASC, id ASC"
        return try AnnotationRow.fetchAll(db, sql: sql, arguments: arguments)
    }

    private static func insertActionItem(
        _ db: Database,
        text: String,
        timestamp: String
    ) throws -> ActionItem {
        try db.execute(
            sql: "INSERT INTO action_items (timestamp, text, done) VALUES (?, ?, 0)",
            arguments: [timestamp, text]
        )
        return ActionItem(
            id: db.lastInsertedRowID,
            timestamp: timestamp,
            text: text,
            done: false
        )
    }

    private static let knowledgeDocumentColumns = """
    id, title, description, text, created_at, updated_at, allow_llm_updates
    """

    /// `date(timestamp)` is the UTC day. Transcripts are stored in UTC, so the day list uses local time.
    private static let localDay = "date(timestamp, 'localtime')"

    private static func actionItemIsNewer(_ lhs: ActionItem, _ rhs: ActionItem) -> Bool {
        let left = Timestamp.parse(lhs.timestamp) ?? .distantPast
        let right = Timestamp.parse(rhs.timestamp) ?? .distantPast
        if left != right { return left > right }
        return lhs.id > rhs.id
    }

    private static func filters(
        date: String?,
        search: String?,
        afterColumn: String,
        afterId: Int64?
    ) -> (String, StatementArguments) {
        var conditions: [String] = []
        var arguments = StatementArguments()
        if let date {
            conditions.append("\(Self.localDay) = ?")
            arguments += [date]
        }
        if let search, !search.isEmpty {
            conditions.append("text LIKE ?")
            arguments += ["%\(search)%"]
        }
        if let afterId {
            conditions.append("\(afterColumn) > ?")
            arguments += [afterId]
        }
        return (conditions.joined(separator: " AND "), arguments)
    }
}
