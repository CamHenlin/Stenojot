import Foundation
import GRDB
import XCTest
@testable import TranscriberCore

final class DatabaseTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcriber-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testImportPreservesRowsAndSchema() throws {
        let source = directory.appendingPathComponent("transcriptions.db")
        let sourceDB = try DatabaseQueue(path: source.path)
        try sourceDB.write { db in
            try TranscriptSchema.create(db)
            try db.execute(
                sql: "INSERT INTO transcriptions (timestamp, text, raw_output) VALUES (?, ?, ?)",
                arguments: ["2026-09-23T15:04:05.000Z", "Hello um world", "raw"]
            )
            try db.execute(
                sql: "INSERT INTO annotations (after_transcription_id, timestamp, text) VALUES (?, ?, ?)",
                arguments: [1, "2026-09-23T15:04:06.000Z", "a note"]
            )
        }

        let destination = directory.appendingPathComponent("imported.db")
        try DatabaseImporter.importDatabase(from: source, to: destination)

        let store = try TranscriptStore(path: destination.path)
        let items = try store.fetchTimeline(date: "2026-09-23", search: nil)
        XCTAssertEqual(items.map(\.text), ["Hello um world", "a note"])
        XCTAssertEqual(try store.fetchDates(), ["2026-09-23"])

        let result = try store.applyReplacements([ReplacementRule(from: "um", to: "")])
        XCTAssertEqual(result.updated, 1)
        XCTAssertEqual(result.deleted, 0)
        XCTAssertEqual(try store.fetchTimeline(date: nil, search: nil).first?.text, "Hello world")
    }

    func testApplyAllDeletesEmptyRowsAndTheirNotes() throws {
        let url = directory.appendingPathComponent("empty-rule.db")
        try DatabaseImporter.createEmptyDatabase(at: url)
        let store = try TranscriptStore(path: url.path)
        let row = try store.insertTranscription(timestamp: "2026-09-23T15:04:05Z", text: "um", rawOutput: "raw")
        _ = try store.insertAnnotation(afterTranscriptionId: row.id, text: "note", timestamp: "2026-09-23T15:04:06Z")

        let result = try store.applyReplacements([ReplacementRule(from: "um", to: "")])
        XCTAssertEqual(result, ApplyReplacementsResult(total: 1, updated: 1, deleted: 1))
        XCTAssertTrue(try store.fetchTimeline(date: nil, search: nil).isEmpty)
    }

    func testExistingTranscriptsDefaultToCaller() throws {
        let url = directory.appendingPathComponent("legacy.db")
        let legacy = try DatabaseQueue(path: url.path)
        try legacy.write { db in
            try db.execute(sql: """
            CREATE TABLE transcriptions (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              timestamp TEXT NOT NULL,
              text TEXT NOT NULL,
              raw_output TEXT NOT NULL
            )
            """)
            try db.execute(sql: """
            CREATE TABLE annotations (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              after_transcription_id INTEGER,
              timestamp TEXT NOT NULL,
              text TEXT NOT NULL
            )
            """)
            try db.execute(
                sql: "INSERT INTO transcriptions (timestamp, text, raw_output) VALUES (?, ?, ?)",
                arguments: ["2026-09-23T15:04:05Z", "old line", ""]
            )
        }

        let store = try TranscriptStore(path: url.path)
        let items = try store.fetchTimeline(date: nil, search: nil)
        XCTAssertEqual(items.map(\.speaker), [Speaker.caller.rawValue])

        let you = try store.insertTranscription(
            timestamp: "2026-09-23T15:05:05Z",
            text: "new line",
            rawOutput: "",
            speaker: Speaker.you.rawValue
        )
        XCTAssertEqual(you.speaker, Speaker.you.rawValue)
    }

    func testLegacyAnnotationsDefaultToNote() throws {
        let url = directory.appendingPathComponent("legacy-notes.db")
        let legacy = try DatabaseQueue(path: url.path)
        try legacy.write { db in
            try db.execute(sql: """
            CREATE TABLE transcriptions (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              timestamp TEXT NOT NULL,
              text TEXT NOT NULL,
              raw_output TEXT NOT NULL
            )
            """)
            try db.execute(sql: """
            CREATE TABLE annotations (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              after_transcription_id INTEGER,
              timestamp TEXT NOT NULL,
              text TEXT NOT NULL
            )
            """)
            try db.execute(
                sql: "INSERT INTO transcriptions (timestamp, text, raw_output) VALUES (?, ?, ?)",
                arguments: ["2026-09-23T15:04:05Z", "Hello", ""]
            )
            try db.execute(
                sql: "INSERT INTO annotations (after_transcription_id, timestamp, text) VALUES (?, ?, ?)",
                arguments: [1, "2026-09-23T15:04:06Z", "old note"]
            )
        }

        let store = try TranscriptStore(path: url.path)
        let items = try store.fetchTimeline(date: nil, search: nil)
        XCTAssertEqual(items.map(\.text), ["Hello", "old note"])
        XCTAssertEqual(items.map(\.annotationKind), [nil, .note])
    }

    func testLLMNoteFollowsItsAnchor() throws {
        let url = directory.appendingPathComponent("llm-note.db")
        try DatabaseImporter.createEmptyDatabase(at: url)
        let store = try TranscriptStore(path: url.path)
        let first = try store.insertTranscription(timestamp: "2026-09-23T15:04:05Z", text: "First", rawOutput: "")
        _ = try store.insertTranscription(timestamp: "2026-09-23T15:05:05Z", text: "Second", rawOutput: "")
        _ = try store.insertAnnotation(
            afterTranscriptionId: first.id,
            text: "Summary",
            timestamp: "2026-09-23T15:04:06Z",
            kind: .llm
        )

        let items = try store.fetchTimeline(date: "2026-09-23", search: nil)
        XCTAssertEqual(items.map(\.text), ["First", "Summary", "Second"])
        XCTAssertEqual(items.map(\.annotationKind), [nil, .llm, nil])

        let context = try store.fetchModelContext(date: "2026-09-23", fromId: nil, toId: nil)
        XCTAssertEqual(context.annotations.map(\.kind), [.llm])
    }

    func testImportRejectsADatabaseMissingColumns() throws {
        let source = directory.appendingPathComponent("bad.db")
        let db = try DatabaseQueue(path: source.path)
        try db.write { db in
            try db.execute(sql: "CREATE TABLE transcriptions (id INTEGER PRIMARY KEY, timestamp TEXT, text TEXT)")
            try db.execute(sql: "CREATE TABLE annotations (id INTEGER PRIMARY KEY, timestamp TEXT, text TEXT)")
        }
        let destination = directory.appendingPathComponent("out.db")
        XCTAssertThrowsError(try DatabaseImporter.importDatabase(from: source, to: destination)) { error in
            XCTAssertTrue(error is DatabaseSchemaError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testConfigRoundTrip() throws {
        let url = directory.appendingPathComponent("config.json")
        let config = AppConfig(
            ollama: OllamaSettings(baseUrl: "http://localhost:11434", model: "gpt-oss:20b"),
            systemPrompt: "Be brief.",
            replacements: [ReplacementRule(from: "Linz", to: "LIMS")],
            summarySystemPrompt: "Keep each stretch short.",
            summaryPass2SystemPrompt: "Drop filler.",
            actionItemsSystemPrompt: "Only commitments.",
            ignoredAudioBundleIDs: ["com.apple.Music"]
        )
        try ConfigStore.save(config, to: url)
        let loaded = try ConfigStore.load(from: url)
        XCTAssertEqual(loaded, config)
    }

    func testLatestTranscriptionIsTheLastInsertedLine() throws {
        let url = directory.appendingPathComponent("latest.db")
        try DatabaseImporter.createEmptyDatabase(at: url)
        let store = try TranscriptStore(path: url.path)
        XCTAssertNil(try store.latestTranscription())
        _ = try store.insertTranscription(timestamp: "2026-09-23T15:04:05Z", text: "First", rawOutput: "")
        _ = try store.insertTranscription(timestamp: "2026-09-23T15:00:00Z", text: "Yeah", rawOutput: "")
        XCTAssertEqual(try store.latestTranscription()?.text, "Yeah")
    }

    func testSearchAndLeadingNote() throws {
        let url = directory.appendingPathComponent("search.db")
        try DatabaseImporter.createEmptyDatabase(at: url)
        let store = try TranscriptStore(path: url.path)
        _ = try store.insertAnnotation(afterTranscriptionId: nil, text: "before", timestamp: "2026-09-23T15:00:00Z")
        _ = try store.insertTranscription(timestamp: "2026-09-23T15:04:05Z", text: "Alpha meeting", rawOutput: "")
        _ = try store.insertTranscription(timestamp: "2026-09-23T15:05:05Z", text: "Beta", rawOutput: "")

        let found = try store.fetchTimeline(date: nil, search: "alpha")
        XCTAssertEqual(found.map(\.text), ["Alpha meeting"])
    }

    func testSearchDatesIncludeOnlyDaysWithVisibleHits() throws {
        let url = directory.appendingPathComponent("search-days.db")
        try DatabaseImporter.createEmptyDatabase(at: url)
        let store = try TranscriptStore(path: url.path)
        _ = try store.insertTranscription(timestamp: "2026-09-21T15:00:00Z", text: "Alpha on Monday", rawOutput: "")
        _ = try store.insertTranscription(timestamp: "2026-09-22T15:00:00Z", text: "Beta only", rawOutput: "")
        _ = try store.insertAnnotation(afterTranscriptionId: nil, text: "alpha note", timestamp: "2026-09-23T12:00:00Z")
        let hidden = try store.insertTranscription(timestamp: "2026-09-24T15:00:00Z", text: "Gamma", rawOutput: "")
        _ = try store.insertAnnotation(afterTranscriptionId: hidden.id, text: "alpha hidden", timestamp: "2026-09-24T15:01:00Z")

        XCTAssertEqual(try store.fetchDates(matching: "alpha"), ["2026-09-23", "2026-09-21"])
        XCTAssertEqual(try store.fetchDates(matching: "  "), try store.fetchDates())
        XCTAssertEqual(
            try store.fetchTimeline(date: "2026-09-23", search: "alpha").map(\.text),
            ["alpha note"]
        )
        XCTAssertTrue(try store.fetchTimeline(date: "2026-09-24", search: "alpha").isEmpty)
    }

    func testActionItemsRoundTripAndWatermarkSkipsExistingTranscripts() throws {
        let url = directory.appendingPathComponent("actions.db")
        try DatabaseImporter.createEmptyDatabase(at: url)
        let store = try TranscriptStore(path: url.path)
        let existing = try store.insertTranscription(
            timestamp: "2026-09-23T15:00:00Z",
            text: "Already stored",
            rawOutput: ""
        )

        XCTAssertEqual(try store.prepareActionExtractor(), existing.id)
        XCTAssertEqual(try store.actionExtractorWatermark(), existing.id)
        XCTAssertTrue(try store.fetchTranscriptions(afterId: existing.id).isEmpty)
        XCTAssertEqual(try store.prepareActionExtractor(), existing.id)

        let added = try store.insertTranscription(
            timestamp: "2026-09-23T15:01:00Z",
            text: "New line",
            rawOutput: ""
        )
        XCTAssertEqual(try store.fetchTranscriptions(afterId: existing.id).map(\.id), [added.id])

        let saved = try store.saveExtractedActionItems(
            ["Send the notes"],
            timestamp: added.timestamp,
            watermark: added.id
        )
        XCTAssertEqual(saved.map(\.text), ["Send the notes"])
        XCTAssertEqual(try store.actionExtractorWatermark(), added.id)
        XCTAssertTrue(try store.fetchTranscriptions(afterId: added.id).isEmpty)

        let manual = try store.insertActionItem(text: "Buy milk", timestamp: "2026-09-23T18:00:00Z")
        try store.setActionItemDone(id: manual.id, done: true)
        let listed = try store.fetchActionItems()
        XCTAssertEqual(listed.map(\.text), ["Buy milk", "Send the notes"])
        XCTAssertEqual(listed.map(\.done), [true, false])

        try store.deleteActionItem(id: manual.id)
        XCTAssertEqual(try store.fetchActionItems().map(\.text), ["Send the notes"])

        let quiet = try store.saveExtractedActionItems([], timestamp: added.timestamp, watermark: added.id)
        XCTAssertTrue(quiet.isEmpty)
        XCTAssertEqual(try store.fetchActionItems().map(\.text), ["Send the notes"])
    }

    func testDailySummaryInsertDoesNotOverwriteAnEdit() throws {
        let url = directory.appendingPathComponent("summaries.db")
        try DatabaseImporter.createEmptyDatabase(at: url)
        let store = try TranscriptStore(path: url.path)
        _ = try store.insertTranscription(timestamp: "2026-09-23T15:00:00Z", text: "Hello", rawOutput: "")
        _ = try store.insertActionItem(text: "Send the deck", timestamp: "2026-09-23T16:00:00Z")
        _ = try store.insertActionItem(text: "Tomorrow", timestamp: "2026-09-24T16:00:00Z")

        XCTAssertEqual(try store.fetchActionItems(onDay: "2026-09-23").map(\.text), ["Send the deck"])
        XCTAssertTrue(try store.insertDailySummaryIfAbsent(
            day: "2026-09-23",
            text: "First draft",
            timestamp: "2026-09-24T00:00:01Z"
        ))
        XCTAssertFalse(try store.insertDailySummaryIfAbsent(
            day: "2026-09-23",
            text: "Second draft",
            timestamp: "2026-09-25T00:00:01Z"
        ))
        try store.updateDailySummary(day: "2026-09-23", text: "Edited", timestamp: "2026-09-24T12:00:00Z")

        let stored = try store.fetchDailySummary(day: "2026-09-23")
        XCTAssertEqual(stored?.text, "Edited")
        XCTAssertEqual(stored?.generatedAt, "2026-09-24T00:00:01Z")
        XCTAssertEqual(stored?.updatedAt, "2026-09-24T12:00:00Z")
        XCTAssertEqual(try store.fetchDailySummaries().map(\.day), ["2026-09-23"])

        try store.replaceDailySummary(
            day: "2026-09-23",
            text: "Regenerated",
            timestamp: "2026-09-26T00:00:01Z"
        )
        let replaced = try store.fetchDailySummary(day: "2026-09-23")
        XCTAssertEqual(replaced?.text, "Regenerated")
        XCTAssertEqual(replaced?.generatedAt, "2026-09-26T00:00:01Z")
        XCTAssertEqual(replaced?.updatedAt, "2026-09-26T00:00:01Z")
    }

    func testDaysFollowTheLocalCalendarRatherThanUTC() throws {
        let url = directory.appendingPathComponent("local-days.db")
        try DatabaseImporter.createEmptyDatabase(at: url)
        let store = try TranscriptStore(path: url.path)
        // 7:30pm Pacific on Sunday, which is already Monday in UTC.
        let sundayNight = "2026-09-21T02:30:00+00:00"
        let mondayMorning = "2026-09-21T16:00:00Z"
        _ = try store.insertTranscription(timestamp: sundayNight, text: "Sunday night", rawOutput: "")
        _ = try store.insertTranscription(timestamp: mondayMorning, text: "Monday morning", rawOutput: "")
        _ = try store.insertActionItem(text: "From Sunday", timestamp: sundayNight)

        let sunday = try XCTUnwrap(store.localDay(of: sundayNight))
        let monday = try XCTUnwrap(store.localDay(of: mondayMorning))
        XCTAssertEqual(sunday, Timestamp.localDay(Timestamp.parse(sundayNight)!))
        XCTAssertEqual(monday, Timestamp.localDay(Timestamp.parse(mondayMorning)!))

        if sunday == monday {
            XCTAssertEqual(try store.fetchTimeline(date: sunday, search: nil).map(\.text), ["Sunday night", "Monday morning"])
            XCTAssertEqual(try store.fetchActionItems(onDay: sunday).map(\.text), ["From Sunday"])
        } else {
            XCTAssertEqual(try store.fetchDates(), [monday, sunday])
            XCTAssertEqual(try store.fetchTimeline(date: sunday, search: nil).map(\.text), ["Sunday night"])
            XCTAssertEqual(try store.fetchTimeline(date: monday, search: nil).map(\.text), ["Monday morning"])
            XCTAssertEqual(try store.fetchActionItems(onDay: sunday).map(\.text), ["From Sunday"])
            XCTAssertTrue(try store.fetchActionItems(onDay: monday).isEmpty)
        }
    }

    func testKnowledgeDocumentsRoundTripAndSortByRecentEdit() throws {
        let url = directory.appendingPathComponent("knowledge.db")
        try DatabaseImporter.createEmptyDatabase(at: url)
        let store = try TranscriptStore(path: url.path)

        let first = try store.insertKnowledgeDocument(
            title: "Runbook",
            description: "Deploy steps",
            text: "Ship the build.",
            timestamp: "2026-09-23T15:00:00Z"
        )
        let second = try store.insertKnowledgeDocument(
            title: "",
            description: "  ",
            text: "Names and terms.",
            timestamp: "2026-09-23T16:00:00Z"
        )
        XCTAssertEqual(second.displayTitle, "Untitled")
        XCTAssertEqual(try store.fetchKnowledgeDocuments().map(\.id), [second.id, first.id])

        try store.updateKnowledgeDocument(
            id: first.id,
            title: "Runbook v2",
            description: "Updated steps",
            text: "Ship the signed build.",
            timestamp: "2026-09-24T12:00:00Z"
        )
        let updated = try store.fetchKnowledgeDocument(id: first.id)
        XCTAssertEqual(updated?.title, "Runbook v2")
        XCTAssertEqual(updated?.description, "Updated steps")
        XCTAssertEqual(updated?.text, "Ship the signed build.")
        XCTAssertEqual(updated?.createdAt, "2026-09-23T15:00:00Z")
        XCTAssertEqual(updated?.updatedAt, "2026-09-24T12:00:00Z")
        XCTAssertEqual(try store.fetchKnowledgeDocuments().map(\.id), [first.id, second.id])

        try store.deleteKnowledgeDocument(id: second.id)
        XCTAssertNil(try store.fetchKnowledgeDocument(id: second.id))
        XCTAssertEqual(try store.fetchKnowledgeDocuments().map(\.id), [first.id])
    }

    func testKnowledgeDocumentsMigrateOntoAnExistingDatabase() throws {
        let url = directory.appendingPathComponent("legacy-knowledge.db")
        let legacy = try DatabaseQueue(path: url.path)
        try legacy.write { db in
            try db.execute(sql: """
            CREATE TABLE transcriptions (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              timestamp TEXT NOT NULL,
              text TEXT NOT NULL,
              raw_output TEXT NOT NULL
            )
            """)
            try db.execute(sql: """
            CREATE TABLE annotations (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              after_transcription_id INTEGER,
              timestamp TEXT NOT NULL,
              text TEXT NOT NULL
            )
            """)
        }

        let store = try TranscriptStore(path: url.path)
        let document = try store.insertKnowledgeDocument(
            title: "Glossary",
            description: "Project terms",
            text: "Stenojot writes both sides of a call.",
            timestamp: "2026-09-23T15:00:00Z"
        )
        XCTAssertEqual(try store.fetchKnowledgeDocuments(), [document])
        XCTAssertTrue(try store.fetchKnowledgeVersions(documentID: document.id).isEmpty)
    }

    func testKnowledgeDocumentUpdateKeepsThePreviousVersion() throws {
        let url = directory.appendingPathComponent("knowledge-versions.db")
        try DatabaseImporter.createEmptyDatabase(at: url)
        let store = try TranscriptStore(path: url.path)
        let document = try store.insertKnowledgeDocument(
            title: "Runbook",
            description: "Deploy steps",
            text: "Ship the build.",
            timestamp: "2026-09-23T15:00:00Z"
        )

        let first = try store.updateKnowledgeDocument(
            id: document.id,
            title: "Runbook v2",
            description: "Updated steps",
            text: "Ship the signed build.",
            timestamp: "2026-09-24T12:00:00Z"
        )
        guard case .saved(let archived) = first else {
            return XCTFail("Expected the first edit to archive the previous text")
        }
        XCTAssertEqual(archived.title, "Runbook")
        XCTAssertEqual(archived.description, "Deploy steps")
        XCTAssertEqual(archived.text, "Ship the build.")
        XCTAssertEqual(archived.savedAt, "2026-09-23T15:00:00Z")

        let same = try store.updateKnowledgeDocument(
            id: document.id,
            title: "Runbook v2",
            description: "Updated steps",
            text: "Ship the signed build.",
            timestamp: "2026-09-24T13:00:00Z"
        )
        XCTAssertEqual(same, .unchanged)
        XCTAssertEqual(try store.fetchKnowledgeDocument(id: document.id)?.updatedAt, "2026-09-24T12:00:00Z")

        let second = try store.updateKnowledgeDocument(
            id: document.id,
            title: "Runbook v2",
            description: "Updated steps",
            text: "Ship the signed build.\nCheck the logs.",
            timestamp: "2026-09-25T12:00:00Z"
        )
        guard case .saved(let later) = second else {
            return XCTFail("Expected the second edit to archive the previous text")
        }
        XCTAssertEqual(later.text, "Ship the signed build.")
        XCTAssertEqual(later.savedAt, "2026-09-24T12:00:00Z")
        XCTAssertEqual(
            try store.fetchKnowledgeVersions(documentID: document.id).map(\.text),
            ["Ship the signed build.", "Ship the build."]
        )

        let versions = try store.fetchKnowledgeVersions(documentID: document.id)
        let current = try XCTUnwrap(store.fetchKnowledgeDocument(id: document.id))
        let newestChange = KnowledgeHistory.successor(
            of: versions[0].id,
            versions: versions,
            current: current.revision,
            currentSavedAt: current.updatedAt
        )
        XCTAssertEqual(newestChange?.revision.text, "Ship the signed build.\nCheck the logs.")
        XCTAssertEqual(newestChange?.savedAt, "2026-09-25T12:00:00Z")
        let olderChange = KnowledgeHistory.successor(
            of: versions[1].id,
            versions: versions,
            current: current.revision,
            currentSavedAt: current.updatedAt
        )
        XCTAssertEqual(olderChange?.revision.text, "Ship the signed build.")
        XCTAssertEqual(olderChange?.savedAt, "2026-09-24T12:00:00Z")

        try store.deleteKnowledgeDocument(id: document.id)
        XCTAssertTrue(try store.fetchKnowledgeVersions(documentID: document.id).isEmpty)
        XCTAssertNil(try store.fetchKnowledgeDocument(id: document.id))
    }

    func testKnowledgeDocumentLLMUpdateFlagDoesNotCreateAVersion() throws {
        let url = directory.appendingPathComponent("knowledge-llm-flag.db")
        try DatabaseImporter.createEmptyDatabase(at: url)
        let store = try TranscriptStore(path: url.path)
        let document = try store.insertKnowledgeDocument(
            title: "Glossary",
            description: "Terms",
            text: "Stenojot.",
            timestamp: "2026-09-23T15:00:00Z"
        )
        XCTAssertFalse(document.allowsLLMUpdates)
        XCTAssertTrue(try store.fetchKnowledgeDocumentsAllowingLLMUpdates().isEmpty)

        try store.setKnowledgeDocumentAllowsLLMUpdates(id: document.id, allowed: true)
        let optedIn = try XCTUnwrap(store.fetchKnowledgeDocument(id: document.id))
        XCTAssertTrue(optedIn.allowsLLMUpdates)
        XCTAssertEqual(optedIn.updatedAt, "2026-09-23T15:00:00Z")
        XCTAssertTrue(try store.fetchKnowledgeVersions(documentID: document.id).isEmpty)
        XCTAssertEqual(try store.fetchKnowledgeDocumentsAllowingLLMUpdates().map(\.id), [document.id])

        let skipped = try store.updateKnowledgeDocument(
            id: document.id,
            title: "Glossary v2",
            description: "Terms",
            text: "Stenojot writes both sides.",
            timestamp: "2026-09-24T12:00:00Z",
            expectedUpdatedAt: "2026-09-24T00:00:00Z"
        )
        XCTAssertEqual(skipped, .unchanged)
        XCTAssertEqual(try store.fetchKnowledgeDocument(id: document.id)?.text, "Stenojot.")

        let saved = try store.updateKnowledgeDocument(
            id: document.id,
            title: "Glossary v2",
            description: "Terms",
            text: "Stenojot writes both sides.",
            timestamp: "2026-09-24T12:00:00Z",
            expectedUpdatedAt: document.updatedAt
        )
        guard case .saved = saved else {
            return XCTFail("Expected the edit to archive the previous text")
        }
        let updated = try XCTUnwrap(store.fetchKnowledgeDocument(id: document.id))
        XCTAssertTrue(updated.allowsLLMUpdates)
        XCTAssertEqual(updated.text, "Stenojot writes both sides.")
        XCTAssertEqual(updated.updatedAt, "2026-09-24T12:00:00Z")
        XCTAssertEqual(try store.fetchKnowledgeVersions(documentID: document.id).map(\.text), ["Stenojot."])
    }

    func testAllowLLMUpdatesColumnMigratesOntoAnExistingKnowledgeTable() throws {
        let url = directory.appendingPathComponent("knowledge-flag-migrate.db")
        let legacy = try DatabaseQueue(path: url.path)
        try legacy.write { db in
            try db.execute(sql: """
            CREATE TABLE knowledge_documents (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              title TEXT NOT NULL,
              description TEXT NOT NULL,
              text TEXT NOT NULL,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            )
            """)
            try db.execute(
                sql: """
                INSERT INTO knowledge_documents (title, description, text, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: ["Glossary", "Terms", "Stenojot.", "2026-09-23T15:00:00Z", "2026-09-23T15:00:00Z"]
            )
        }

        let store = try TranscriptStore(path: url.path)
        let document = try XCTUnwrap(store.fetchKnowledgeDocument(id: 1))
        XCTAssertFalse(document.allowsLLMUpdates)
        try store.setKnowledgeDocumentAllowsLLMUpdates(id: document.id, allowed: true)
        XCTAssertEqual(try store.fetchKnowledgeDocumentsAllowingLLMUpdates().map(\.title), ["Glossary"])
    }
}
