import XCTest
@testable import TranscriberCore

final class DailySummaryTests: XCTestCase {
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testCompletedDaysSkipTodayAndBackfillOnlyWhileRunning() {
        let calendar = utcCalendar
        let morning = Timestamp.parse("2026-09-24T15:00:00Z")!
        XCTAssertEqual(
            DailySummarySchedule.completedDays(since: "2026-09-24", now: morning, calendar: calendar),
            []
        )
        XCTAssertEqual(
            DailySummarySchedule.completedDays(since: "2026-09-23", now: morning, calendar: calendar),
            ["2026-09-23"]
        )
        XCTAssertEqual(
            DailySummarySchedule.completedDays(since: "2026-09-21", now: morning, calendar: calendar),
            ["2026-09-21", "2026-09-22", "2026-09-23"]
        )
        XCTAssertEqual(
            DailySummarySchedule.completedDays(since: "not-a-day", now: morning, calendar: calendar),
            []
        )
    }

    func testNextMidnightIsTheFollowingLocalDay() {
        let calendar = utcCalendar
        let afternoon = Timestamp.parse("2026-09-23T15:00:00Z")!
        let midnight = Timestamp.parse("2026-09-24T00:00:00Z")!
        XCTAssertEqual(
            DailySummarySchedule.nextMidnight(after: afternoon, calendar: calendar),
            midnight
        )
        XCTAssertEqual(
            DailySummarySchedule.nextMidnight(after: midnight, calendar: calendar),
            Timestamp.parse("2026-09-25T00:00:00Z")
        )
    }

    func testChunksSplitOnlyAfterMoreThanOneMinute() {
        let together = DailySummaryDocument.chunks(
            transcriptions: [
                line(1, "2026-09-23T15:00:00Z", "Hello"),
                line(2, "2026-09-23T15:00:30Z", "Still one stretch"),
                line(3, "2026-09-23T15:01:00Z", "Exactly one minute"),
            ],
            annotations: []
        )
        XCTAssertEqual(together.map { $0.transcriptions.map(\.id) }, [[1, 2, 3]])

        let split = DailySummaryDocument.chunks(
            transcriptions: [
                line(1, "2026-09-23T15:00:00Z", "Hello"),
                line(2, "2026-09-23T15:01:01Z", "After the gap"),
            ],
            annotations: []
        )
        XCTAssertEqual(split.map { $0.transcriptions.map(\.id) }, [[1], [2]])
    }

    func testChunkKeepsNotesWithTheirTranscript() {
        let transcriptions = [
            line(1, "2026-09-23T15:00:00Z", "Hello"),
            line(2, "2026-09-23T15:00:10Z", "Still here"),
            line(3, "2026-09-23T15:02:00Z", "Next stretch"),
        ]
        let notes = [
            AnnotationRow(id: 10, afterTranscriptionId: nil, timestamp: "2026-09-23T14:59:00Z", text: "Before"),
            AnnotationRow(id: 11, afterTranscriptionId: 1, timestamp: "2026-09-23T15:00:05Z", text: "During first"),
            AnnotationRow(id: 12, afterTranscriptionId: nil, timestamp: "2026-09-23T15:01:00Z", text: "In the gap"),
            AnnotationRow(id: 13, afterTranscriptionId: 3, timestamp: "2026-09-23T15:02:05Z", text: "During second"),
        ]
        let grouped = DailySummaryDocument.chunks(transcriptions: transcriptions, annotations: notes)
        XCTAssertEqual(grouped.map { $0.transcriptions.map(\.id) }, [[1, 2], [3]])
        XCTAssertEqual(grouped[0].notes.map(\.text), ["Before", "During first", "In the gap"])
        XCTAssertEqual(grouped[1].notes.map(\.text), ["During second"])
    }

    func testNotesOnlyDayIsOneChunk() {
        let notes = [
            AnnotationRow(id: 2, afterTranscriptionId: nil, timestamp: "2026-09-23T12:00:00Z", text: "Later"),
            AnnotationRow(id: 1, afterTranscriptionId: nil, timestamp: "2026-09-23T11:00:00Z", text: "Earlier"),
        ]
        let grouped = DailySummaryDocument.chunks(transcriptions: [], annotations: notes)
        XCTAssertEqual(grouped.count, 1)
        XCTAssertTrue(grouped[0].transcriptions.isEmpty)
        XCTAssertEqual(grouped[0].notes.map(\.text), ["Earlier", "Later"])
    }

    func testChunkPromptAllowsBackToBackConversationsAndDoesNotCopyTheTranscript() {
        let chunk = DailySummaryChunk(
            transcriptions: [
                line(1, "2026-09-23T15:00:00Z", "Hello", speaker: Speaker.you.rawValue),
                line(2, "2026-09-23T15:00:20Z", "Hi there"),
            ],
            notes: [
                AnnotationRow(id: 8, afterTranscriptionId: 1, timestamp: "2026-09-23T15:00:10Z", text: "Remember this"),
            ]
        )
        let prompt = DailySummaryDocument.chunkPrompt(chunk, index: 1, count: 2)
        XCTAssertTrue(prompt.contains("more than one conversation"))
        XCTAssertTrue(prompt.contains("Do not copy the transcript"))
        XCTAssertTrue(prompt.contains("- [note] Remember this"))
        XCTAssertTrue(prompt.contains("] You: Hello"))
        XCTAssertTrue(DailySummaryDocument.chunkSystemPrompt.contains("less than a minute"))
        XCTAssertTrue(DailySummaryDocument.chunkSystemPrompt.contains("Do not reproduce the transcript"))
        XCTAssertEqual(
            DailySummaryDocument.chunkSystemPrompt(stored: "  "),
            DailySummaryDocument.chunkSystemPrompt
        )
        XCTAssertEqual(DailySummaryDocument.chunkSystemPrompt(stored: "Be brief."), "Be brief.")
    }

    func testAssembledDocumentUsesSummariesAndExtractedActionItems() {
        let first = Timestamp.formatTime("2026-09-23T15:00:00Z")
        let second = Timestamp.formatTime("2026-09-23T16:00:00Z")
        let document = DailySummaryDocument.assemble(
            day: "2026-09-23",
            sections: [
                DailySummaryDocument.section(heading: "\(first)–\(second)", summary: "Talked about the deck."),
            ],
            actionItems: [
                ActionItem(id: 2, timestamp: "2026-09-23T18:00:00Z", text: "Buy milk", done: true),
                ActionItem(id: 1, timestamp: "2026-09-23T16:00:00Z", text: "Send the deck"),
            ]
        )
        XCTAssertTrue(document.contains("Wednesday, Sep 23, 2026"))
        XCTAssertTrue(document.contains("Talked about the deck."))
        XCTAssertFalse(document.contains("Hello"))
        let deck = document.range(of: "Send the deck")
        let milk = document.range(of: "Buy milk")
        XCTAssertNotNil(deck)
        XCTAssertNotNil(milk)
        XCTAssertLessThan(deck!.lowerBound, milk!.lowerBound)
        XCTAssertTrue(document.contains("- [open]"))
        XCTAssertTrue(document.contains("- [done]"))
        XCTAssertFalse(
            DailySummaryDocument.hasMaterial(transcriptions: [], annotations: [], actionItems: [])
        )
    }

    private func line(
        _ id: Int64,
        _ timestamp: String,
        _ text: String,
        speaker: String = Speaker.caller.rawValue
    ) -> TranscriptionRow {
        TranscriptionRow(id: id, timestamp: timestamp, text: text, speaker: speaker)
    }
}
