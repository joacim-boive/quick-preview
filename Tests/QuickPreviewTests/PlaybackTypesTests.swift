import XCTest
@testable import QuickPreview

final class PlaybackTypesTests: XCTestCase {
    func testPlaybackProgressClampsBetweenZeroAndOne() {
        XCTAssertEqual(PlaybackPosition(seconds: 5, duration: 10).progress, 0.5)
        XCTAssertEqual(PlaybackPosition(seconds: -1, duration: 10).progress, 0)
        XCTAssertEqual(PlaybackPosition(seconds: 20, duration: 10).progress, 1)
        XCTAssertEqual(PlaybackPosition(seconds: 5, duration: 0).progress, 0)
    }
}
