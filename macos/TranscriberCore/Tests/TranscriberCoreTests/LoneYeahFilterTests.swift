import XCTest
@testable import TranscriberCore

final class LoneYeahFilterTests: XCTestCase {
    func testDropsYeahThatRepeatsThePreviousLine() {
        XCTAssertTrue(LoneYeahFilter.shouldDrop(
            text: "Yeah",
            previousText: "Yeah",
            previousTimestamp: "2026-09-23T15:00:00Z",
            timestamp: "2026-09-23T15:00:02Z"
        ))
    }

    func testDropsYeahAfterAPauseLongerThanThirtySeconds() {
        XCTAssertTrue(LoneYeahFilter.shouldDrop(
            text: "Yeah.",
            previousText: "Let's ship it",
            previousTimestamp: "2026-09-23T15:00:00Z",
            timestamp: "2026-09-23T15:00:31Z"
        ))
    }

    func testKeepsYeahWithinThirtySecondsOfOtherSpeech() {
        XCTAssertFalse(LoneYeahFilter.shouldDrop(
            text: "Yeah",
            previousText: "Does that work?",
            previousTimestamp: "2026-09-23T15:00:00Z",
            timestamp: "2026-09-23T15:00:30Z"
        ))
    }

    func testKeepsTheFirstYeahWhenNothingCameBefore() {
        XCTAssertFalse(LoneYeahFilter.shouldDrop(
            text: "Yeah",
            previousText: nil,
            previousTimestamp: nil,
            timestamp: "2026-09-23T15:00:00Z"
        ))
    }

    func testKeepsASentenceThatContainsYeah() {
        XCTAssertFalse(LoneYeahFilter.shouldDrop(
            text: "Yeah, that works",
            previousText: "Yeah",
            previousTimestamp: "2026-09-23T15:00:00Z",
            timestamp: "2026-09-23T15:02:00Z"
        ))
    }

    func testMatchesYeahIgnoringCaseAndPunctuation() {
        XCTAssertTrue(LoneYeahFilter.isLoneYeah(" yeah! "))
        XCTAssertTrue(LoneYeahFilter.isLoneYeah("YEAH."))
        XCTAssertFalse(LoneYeahFilter.isLoneYeah("Yeah yeah"))
        XCTAssertFalse(LoneYeahFilter.isLoneYeah("Oh yeah"))
    }
}
