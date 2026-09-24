import XCTest
@testable import TranscriberCore

final class ActionItemTests: XCTestCase {
    func testSegmentsSplitOnAThirtySecondGap() {
        let rows = [
            line(1, "2026-09-23T15:00:00Z", "Start"),
            line(2, "2026-09-23T15:00:20Z", "Still going"),
            line(3, "2026-09-23T15:00:50Z", "After the pause"),
            line(4, "2026-09-23T15:01:10Z", "Same run"),
        ]
        let segments = ActionItems.segments(rows)
        XCTAssertEqual(segments.map { $0.map(\.id) }, [[1, 2], [3, 4]])
    }

    func testSegmentsStayTogetherJustUnderTheGap() {
        let rows = [
            line(1, "2026-09-23T15:00:00Z", "Start"),
            line(2, "2026-09-23T15:00:29Z", "Almost"),
        ]
        XCTAssertEqual(ActionItems.segments(rows).map { $0.map(\.id) }, [[1, 2]])
    }

    func testClosedSegmentsLeaveTheOpenTail() {
        let rows = [
            line(1, "2026-09-23T15:00:00Z", "Earlier"),
            line(2, "2026-09-23T15:00:10Z", "Still earlier"),
            line(3, "2026-09-23T15:00:50Z", "Just started"),
        ]
        let now = Timestamp.parse("2026-09-23T15:00:55Z")!
        let closed = ActionItems.closedSegments(rows, now: now)
        XCTAssertEqual(closed.segments.map { $0.map(\.id) }, [[1, 2]])
        XCTAssertEqual(closed.throughId, 2)
    }

    func testClosedSegmentsIncludeTheTailAfterTheGap() {
        let rows = [
            line(1, "2026-09-23T15:00:00Z", "Earlier"),
            line(2, "2026-09-23T15:00:40Z", "Finished"),
        ]
        let now = Timestamp.parse("2026-09-23T15:01:10Z")!
        let closed = ActionItems.closedSegments(rows, now: now)
        XCTAssertEqual(closed.segments.map { $0.map(\.id) }, [[1], [2]])
        XCTAssertEqual(closed.throughId, 2)
    }

    func testClosedSegmentsAreEmptyWithoutRows() {
        let closed = ActionItems.closedSegments([], now: Date())
        XCTAssertTrue(closed.segments.isEmpty)
        XCTAssertNil(closed.throughId)
    }

    func testParseReadsJSONBulletsAndSkipsEmptyReplies() {
        XCTAssertEqual(ActionItems.parse(modelOutput: "[]"), [])
        XCTAssertEqual(ActionItems.parse(modelOutput: "No action items."), [])
        XCTAssertEqual(ActionItems.parse(modelOutput: "Nothing to do here."), [])
        XCTAssertEqual(
            ActionItems.parse(modelOutput: "```json\n[\"Send the deck\", \"Send the deck\", \"\"]\n```"),
            ["Send the deck"]
        )
        XCTAssertEqual(
            ActionItems.parse(modelOutput: "- Email Sam\n* Call Priya\n1. Email Sam"),
            ["Email Sam", "Call Priya"]
        )
        XCTAssertEqual(
            ActionItems.parse(modelOutput: #"[{"task": "Book the room"}]"#),
            ["Book the room"]
        )
    }

    func testUserPromptNamesSpeakers() {
        let prompt = ActionItems.userPrompt(transcriptions: [
            line(1, "2026-09-23T15:00:00Z", "I will send it", speaker: Speaker.you.rawValue),
        ])
        XCTAssertTrue(prompt.contains("] You: I will send it"))
        XCTAssertTrue(prompt.contains("JSON array of action items:"))
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
