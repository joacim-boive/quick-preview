import XCTest
@testable import QuickPreview

final class PreciseSeekControllerTests: XCTestCase {
    func testStepSecondsUsesFineAndCoarseDefaults() {
        let seek = PreciseSeekController()
        XCTAssertEqual(seek.stepSeconds(isCoarse: false), 0.1)
        XCTAssertEqual(seek.stepSeconds(isCoarse: true), 1.0)
    }

    func testClampedSeekTargetStaysWithinDuration() {
        let seek = PreciseSeekController()
        XCTAssertEqual(seek.clampedSeekTarget(current: 5, delta: 2, duration: 10), 7)
        XCTAssertEqual(seek.clampedSeekTarget(current: 0.05, delta: -1, duration: 10), 0)
        XCTAssertEqual(seek.clampedSeekTarget(current: 9.5, delta: 2, duration: 10), 10)
        XCTAssertEqual(seek.clampedSeekTarget(current: 3, delta: 1, duration: 0), 0)
    }
}
