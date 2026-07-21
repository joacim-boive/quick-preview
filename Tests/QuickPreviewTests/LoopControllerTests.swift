import XCTest
@testable import QuickPreview

final class LoopControllerTests: XCTestCase {
    func testFullLoopWrapsAtDuration() {
        let loop = LoopController()
        loop.setFullLoop(enabled: true)

        XCTAssertTrue(loop.isLooping())
        XCTAssertEqual(loop.normalizedPosition(for: 9.5, duration: 10), 9.5)
        XCTAssertEqual(loop.normalizedPosition(for: 10, duration: 10), 0, accuracy: 0.0001)
        XCTAssertEqual(loop.normalizedPosition(for: 12.5, duration: 10), 2.5, accuracy: 0.0001)
        XCTAssertEqual(loop.loopRestartTime(currentSeconds: 10, duration: 10), 0)
        XCTAssertNil(loop.loopRestartTime(currentSeconds: 4, duration: 10))
    }

    func testRangeLoopWrapsInsideRange() {
        let loop = LoopController()
        loop.setRangeLoop(start: 2, end: 5)

        XCTAssertEqual(loop.normalizedPosition(for: 4, duration: 20), 4)
        XCTAssertEqual(loop.normalizedPosition(for: 5.5, duration: 20), 2.5, accuracy: 0.0001)
        XCTAssertEqual(loop.loopRestartTime(currentSeconds: 5, duration: 20), 2)
        XCTAssertNil(loop.loopRestartTime(currentSeconds: 3, duration: 20))
    }

    func testClearLoopDisablesLooping() {
        let loop = LoopController()
        loop.setFullLoop(enabled: true)
        loop.clearLoop()

        XCTAssertFalse(loop.isLooping())
        XCTAssertEqual(loop.normalizedPosition(for: 12, duration: 10), 10)
        XCTAssertNil(loop.loopRestartTime(currentSeconds: 12, duration: 10))
    }
}
