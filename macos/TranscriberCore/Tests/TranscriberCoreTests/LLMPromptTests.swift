import XCTest
@testable import TranscriberCore

final class LLMPromptTests: XCTestCase {
    func testRangePromptIncludesNotes() {
        let content = LLMPrompt.userContent(
            transcriptions: [
                TranscriptionRow(id: 1, timestamp: "2026-09-23T15:04:05Z", text: "Hello"),
            ],
            annotations: [
                AnnotationRow(id: 2, afterTranscriptionId: 1, timestamp: "2026-09-23T15:04:06Z", text: "Remember this"),
            ],
            prompt: " Summarize ",
            date: "2026-09-23",
            hasRange: true
        )
        let time = Timestamp.formatTime("2026-09-23T15:04:05Z")
        XCTAssertTrue(content.contains("a selected range of 1 message"))
        XCTAssertTrue(content.contains("[\(time)] Others: Hello"))
        XCTAssertTrue(content.contains("--- User Notes ---"))
        XCTAssertTrue(content.contains("[note] Remember this"))
        XCTAssertTrue(content.hasSuffix("Summarize"))
    }

    func testPromptLabelsLLMNotes() {
        let content = LLMPrompt.userContent(
            transcriptions: [],
            annotations: [
                AnnotationRow(
                    id: 2,
                    afterTranscriptionId: nil,
                    timestamp: "2026-09-23T15:04:06Z",
                    text: "A summary",
                    kind: .llm
                ),
            ],
            prompt: "Continue",
            date: "2026-09-23",
            hasRange: false
        )
        XCTAssertTrue(content.contains("[LLM note] A summary"))
    }

    func testPromptLabelsYou() {
        let content = LLMPrompt.userContent(
            transcriptions: [
                TranscriptionRow(id: 1, timestamp: "2026-09-23T15:04:05Z", text: "Hello", speaker: Speaker.you.rawValue),
            ],
            annotations: [],
            prompt: "Who spoke?",
            date: nil,
            hasRange: false
        )
        XCTAssertTrue(content.contains("] You: Hello"))
    }

    func testDayPromptUsesTheDateString() {
        let content = LLMPrompt.userContent(
            transcriptions: [],
            annotations: [],
            prompt: "What happened?",
            date: "2026-09-23",
            hasRange: false
        )
        XCTAssertTrue(content.contains("transcript for 2026-09-23"))
    }
}
