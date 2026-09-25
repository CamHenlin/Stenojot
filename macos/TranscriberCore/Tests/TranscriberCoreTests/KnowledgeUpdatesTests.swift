import XCTest
@testable import TranscriberCore

final class KnowledgeUpdatesTests: XCTestCase {
    private let document = KnowledgeRevision(
        title: "Runbook",
        description: "Deploy steps",
        text: "Ship the build."
    )

    func testStoredSystemPromptFallsBackToTheBuiltInText() {
        XCTAssertTrue(KnowledgeUpdates.systemPrompt.contains("NO UPDATE"))
        XCTAssertTrue(KnowledgeUpdates.systemPrompt.contains("when that information was heard"))
        XCTAssertTrue(KnowledgeUpdates.systemPrompt.contains("[Sep 23, 2026, 3:04 PM]"))
        XCTAssertEqual(KnowledgeUpdates.systemPrompt(stored: "  "), KnowledgeUpdates.systemPrompt)
        XCTAssertEqual(KnowledgeUpdates.systemPrompt(stored: "Only project facts."), "Only project facts.")
    }

    func testUserPromptIncludesTheEntryAndTheSourceMaterial() {
        let summary = "Talked about the signed build."
        let heardAt = "2026-09-23T15:04:05Z"
        let prompt = KnowledgeUpdates.userPrompt(
            document: document,
            material: summary,
            source: .dailySummary,
            heardAt: heardAt
        )
        XCTAssertTrue(prompt.contains("Heard around: \(Timestamp.formatDateTime(heardAt))"))
        XCTAssertTrue(prompt.contains("Title: Runbook"))
        XCTAssertTrue(prompt.contains("Description: Deploy steps"))
        XCTAssertTrue(prompt.contains("Ship the build."))
        XCTAssertTrue(prompt.contains(summary))
        XCTAssertTrue(prompt.contains("Daily summary"))

        let transcript = ActionItems.userPrompt(transcriptions: [
            TranscriptionRow(id: 1, timestamp: "2026-09-23T15:00:00Z", text: "I'll send the deck.", speaker: "you")
        ])
        let actionPrompt = KnowledgeUpdates.userPrompt(
            document: document,
            material: transcript,
            source: .actionItemTranscript,
            heardAt: heardAt
        )
        XCTAssertTrue(actionPrompt.contains(transcript))
    }

    func testParseReadsNoUpdateAndAFullDocument() {
        XCTAssertEqual(KnowledgeUpdates.parse(modelOutput: "NO UPDATE"), .none)
        XCTAssertEqual(KnowledgeUpdates.parse(modelOutput: "  no update. \n"), .none)
        XCTAssertEqual(KnowledgeUpdates.parse(modelOutput: "Nothing to add."), .none)

        let json = """
        {"title":"Runbook","description":"Deploy steps","text":"Ship the signed build."}
        """
        XCTAssertEqual(
            KnowledgeUpdates.parse(modelOutput: "```json\n\(json)\n```"),
            .update(KnowledgeRevision(title: "Runbook", description: "Deploy steps", text: "Ship the signed build."))
        )
        XCTAssertEqual(
            KnowledgeUpdates.parse(modelOutput: "Here is the update:\n\(json)"),
            .update(KnowledgeRevision(title: "Runbook", description: "Deploy steps", text: "Ship the signed build."))
        )
        XCTAssertEqual(KnowledgeUpdates.parse(modelOutput: #"{"title":"Only a title"}"#), .none)
    }

    func testMaxTokensTracksTheDocumentAndStaysBounded() {
        XCTAssertEqual(KnowledgeUpdates.maxTokens(for: document), 2_048)
        let long = KnowledgeRevision(title: "", description: "", text: String(repeating: "a", count: 90_000))
        XCTAssertEqual(KnowledgeUpdates.maxTokens(for: long), 16_384)
    }
}