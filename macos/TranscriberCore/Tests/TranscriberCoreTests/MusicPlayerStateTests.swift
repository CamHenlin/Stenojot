import XCTest
@testable import TranscriberCore

final class MusicPlayerStateTests: XCTestCase {
    func testParsesMusicNotificationValues() {
        XCTAssertEqual(MusicPlayerState(playbackDescription: "Playing"), .playing)
        XCTAssertEqual(MusicPlayerState(playbackDescription: "Paused"), .paused)
        XCTAssertEqual(MusicPlayerState(playbackDescription: "Stopped"), .stopped)
    }

    func testParsesAppleScriptValues() {
        XCTAssertEqual(MusicPlayerState(playbackDescription: "playing"), .playing)
        XCTAssertEqual(MusicPlayerState(playbackDescription: " paused "), .paused)
    }

    func testRejectsUnknownValues() {
        XCTAssertNil(MusicPlayerState(playbackDescription: ""))
        XCTAssertNil(MusicPlayerState(playbackDescription: "fast forwarding"))
    }

    func testPlayingIsTheOnlyStateThatHoldsTranscription() {
        XCTAssertTrue(MusicPlayerState.playing.isPlaying)
        XCTAssertFalse(MusicPlayerState.paused.isPlaying)
        XCTAssertFalse(MusicPlayerState.stopped.isPlaying)
    }
}
