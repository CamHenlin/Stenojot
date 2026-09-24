import XCTest
@testable import TranscriberCore

final class GitHubUpdateTests: XCTestCase {
    func testOnePointZeroMatchesOnePointZeroPointZero() {
        let installed = AppVersion("1.0")
        let tagged = AppVersion("v1.0.0")
        XCTAssertEqual(installed, tagged)
    }

    func testNewerTagIsGreater() {
        let installed = AppVersion("1.0")
        let tagged = AppVersion("v1.0.1")
        XCTAssertLessThan(installed!, tagged!)
    }

    func testOfferUsesTheReleasePageWhenTheTagIsNewer() throws {
        let data = Data(#"{"tag_name":"v1.2.0","html_url":"https://github.com/CamHenlin/Stenojot/releases/tag/v1.2.0"}"#.utf8)
        let offer = GitHubUpdate.offer(parsing: data, newerThan: AppVersion("1.0")!)
        XCTAssertEqual(offer?.version, AppVersion("1.2.0"))
        XCTAssertEqual(offer?.pageURL.absoluteString, "https://github.com/CamHenlin/Stenojot/releases/tag/v1.2.0")
    }

    func testSameVersionIsNotAnUpdate() {
        let data = Data(#"{"tag_name":"v1.0.0","html_url":"https://github.com/CamHenlin/Stenojot/releases/tag/v1.0.0"}"#.utf8)
        XCTAssertNil(GitHubUpdate.offer(parsing: data, newerThan: AppVersion("1.0")!))
    }

    func testFirstCheckIsOneDayAfterStart() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let due = UpdateCheckSchedule.nextCheck(startedAt: start, lastCheck: nil)
        XCTAssertEqual(due.timeIntervalSince(start), UpdateCheckSchedule.interval)
    }

    func testLaterChecksStayOneDayApart() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let checked = start.addingTimeInterval(UpdateCheckSchedule.interval)
        let due = UpdateCheckSchedule.nextCheck(startedAt: start, lastCheck: checked)
        XCTAssertEqual(due.timeIntervalSince(checked), UpdateCheckSchedule.interval)
    }
}
