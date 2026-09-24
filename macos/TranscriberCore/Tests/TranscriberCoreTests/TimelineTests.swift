import XCTest
@testable import TranscriberCore

final class TimelineTests: XCTestCase {
    private let utc = TimeZone(secondsFromGMT: 0)!

    func testParsePythonAndJavaScriptTimestamps() {
        let python = Timestamp.parse("2026-09-23T15:04:05.123456+00:00")
        let javascript = Timestamp.parse("2026-09-23T15:04:05.123Z")
        XCTAssertNotNil(python)
        XCTAssertNotNil(javascript)
        XCTAssertEqual(Timestamp.formatTime("2026-09-23T15:04:05.123Z", timeZone: utc), "15:04:05")
    }

    func testDateLabels() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let now = Timestamp.parse("2026-09-23T18:00:00Z")!
        XCTAssertEqual(Timestamp.formatDateLabel("2026-09-23", now: now, calendar: calendar), "Today")
        XCTAssertEqual(Timestamp.formatDateLabel("2026-09-22", now: now, calendar: calendar), "Yesterday")
        XCTAssertEqual(Timestamp.formatDateLabel("2026-09-21", now: now, calendar: calendar), "Mon, Sep 21")
    }

    func testNoteTimestampStaysOnTheRequestedDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: -7 * 3600)!
        let now = Timestamp.parse("2026-09-24T15:00:00Z")!
        XCTAssertEqual(
            Timestamp.noteTimestamp(onDay: "2026-09-24", now: now, calendar: calendar),
            Timestamp.nowISO8601(now)
        )
        XCTAssertEqual(
            Timestamp.noteTimestamp(onDay: "2026-09-23", now: now, calendar: calendar),
            "2026-09-24T06:59:59.000Z"
        )
        XCTAssertEqual(Timestamp.noteTimestamp(onDay: nil, now: now, calendar: calendar), Timestamp.nowISO8601(now))
    }

    func testInterleavesNotesAndCopyText() {
        let transcriptions = [
            TranscriptionRow(id: 1, timestamp: "2026-09-23T15:04:05Z", text: "First"),
            TranscriptionRow(id: 2, timestamp: "2026-09-23T15:04:08Z", text: "Second"),
        ]
        let annotations = [
            AnnotationRow(id: 10, afterTranscriptionId: nil, timestamp: "2026-09-23T15:04:01Z", text: "Top"),
            AnnotationRow(id: 11, afterTranscriptionId: 1, timestamp: "2026-09-23T15:04:06Z", text: "Between"),
            AnnotationRow(
                id: 12,
                afterTranscriptionId: 1,
                timestamp: "2026-09-23T15:04:07Z",
                text: "Summary",
                kind: .llm
            ),
        ]
        let items = Timeline.merge(transcriptions: transcriptions, annotations: annotations)
        XCTAssertEqual(items.map(\.text), ["Top", "First", "Between", "Summary", "Second"])
        XCTAssertEqual(items.map(\.annotationKind), [AnnotationKind.note, nil, .note, .llm, nil])

        let copied = Timeline.copyText(items: items, fromId: 2, toId: 1)
        let first = Timestamp.formatTime("2026-09-23T15:04:05Z")
        let second = Timestamp.formatTime("2026-09-23T15:04:08Z")
        XCTAssertEqual(
            copied,
            CopyText(
                text: "\(first)  Others: First\n[note] Between\n[LLM note] Summary\n\(second)  Others: Second",
                count: 2
            )
        )
        XCTAssertEqual(items.first(where: { $0.text == "Summary" })?.annotationKind, .llm)
    }

    func testSearchRangesAreCaseInsensitive() {
        let text = "Hello hello"
        let ranges = Timeline.searchRanges(in: text, search: "HELLO")
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(String(text[ranges[0]]), "Hello")
        XCTAssertEqual(String(text[ranges[1]]), "hello")
    }
}
