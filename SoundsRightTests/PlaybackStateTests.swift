import XCTest
@testable import SoundsRight

/// Each surface renders only its own subject's playback: the panel and HUD
/// show the lookup, a Collection row its own item.
final class PlaybackStateTests: XCTestCase {

    func testIdleHasNoSubject() {
        XCTAssertNil(TTSPlaybackState.idle.subject)
    }

    func testEveryOtherStateKeepsItsSubject() {
        let item = PlaybackSubject.oneShot("serendipity")
        let states: [TTSPlaybackState] = [
            .loading(item),
            .playing(.audio(looping: false), item),
            .paused(.fallback(generation: 3), item),
            .finished(item),
            .error("offline", item)
        ]
        for state in states {
            XCTAssertEqual(state.subject, item)
        }
    }

    /// The panel shows the lookup, so a Collection row playing must read as
    /// idle there rather than as the panel's own audio.
    func testFilteringHidesAnotherSubjectsPlayback() {
        let state = TTSPlaybackState.playing(.audio(looping: false), .oneShot("serendipity"))

        XCTAssertNil(state.filtered(to: PlaybackSubject.lookup).subject)
        XCTAssertFalse(state.filtered(to: PlaybackSubject.lookup).isPlayingOrLoading)
        // A different row's text is a different subject too.
        XCTAssertNil(state.filtered(to: PlaybackSubject.oneShot("ephemeral")).subject)
    }

    func testFilteringKeepsTheSubjectsOwnPlayback() {
        let state = TTSPlaybackState.paused(.audio(looping: true), .lookup)
        let filtered = state.filtered(to: PlaybackSubject.lookup)

        XCTAssertEqual(filtered.subject, PlaybackSubject.lookup)
        XCTAssertEqual(filtered.source, PlaybackSource.audio(looping: true))
    }
}
