import XCTest
@testable import TranscriberCore

final class NoiseWordFilterTests: XCTestCase {
    func testDropsYeahThatRepeatsThePreviousLine() {
        XCTAssertTrue(NoiseWordFilter.shouldDrop(
            text: "Yeah",
            previousText: "Yeah",
            previousTimestamp: "2026-09-23T15:00:00Z",
            timestamp: "2026-09-23T15:00:02Z"
        ))
    }

    func testDropsOkayThatRepeatsThePreviousLine() {
        XCTAssertTrue(NoiseWordFilter.shouldDrop(
            text: "OK.",
            previousText: "Okay",
            previousTimestamp: "2026-09-23T15:00:00Z",
            timestamp: "2026-09-23T15:00:02Z"
        ))
    }

    func testDropsOkayAfterAPauseLongerThanThirtySeconds() {
        XCTAssertTrue(NoiseWordFilter.shouldDrop(
            text: "Okay",
            previousText: "Let's ship it",
            previousTimestamp: "2026-09-23T15:00:00Z",
            timestamp: "2026-09-23T15:00:31Z"
        ))
    }

    func testKeepsOkayWithinThirtySecondsOfOtherSpeech() {
        XCTAssertFalse(NoiseWordFilter.shouldDrop(
            text: "Okay",
            previousText: "Does that work?",
            previousTimestamp: "2026-09-23T15:00:00Z",
            timestamp: "2026-09-23T15:00:30Z"
        ))
    }

    func testKeepsYeahWithinThirtySecondsOfOtherSpeech() {
        XCTAssertFalse(NoiseWordFilter.shouldDrop(
            text: "Yeah",
            previousText: "Does that work?",
            previousTimestamp: "2026-09-23T15:00:00Z",
            timestamp: "2026-09-23T15:00:30Z"
        ))
    }

    func testKeepsYeahThatFollowsOkay() {
        XCTAssertFalse(NoiseWordFilter.shouldDrop(
            text: "Yeah",
            previousText: "Okay",
            previousTimestamp: "2026-09-23T15:00:00Z",
            timestamp: "2026-09-23T15:00:02Z"
        ))
    }

    func testKeepsTheFirstOkayWhenNothingCameBefore() {
        XCTAssertFalse(NoiseWordFilter.shouldDrop(
            text: "Okay",
            previousText: nil,
            previousTimestamp: nil,
            timestamp: "2026-09-23T15:00:00Z"
        ))
    }

    func testKeepsASentenceThatContainsTheWord() {
        XCTAssertFalse(NoiseWordFilter.shouldDrop(
            text: "Okay, that works",
            previousText: "Okay",
            previousTimestamp: "2026-09-23T15:00:00Z",
            timestamp: "2026-09-23T15:02:00Z"
        ))
    }

    func testMatchesNoiseWordsIgnoringCaseAndPunctuation() {
        XCTAssertEqual(NoiseWordFilter.noiseWord(" yeah! "), "yeah")
        XCTAssertEqual(NoiseWordFilter.noiseWord("OKAY."), "okay")
        XCTAssertNil(NoiseWordFilter.noiseWord("Okay okay"))
        XCTAssertNil(NoiseWordFilter.noiseWord("Oh yeah"))
    }
}
