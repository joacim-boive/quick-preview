import AVFoundation
import XCTest
@testable import QuickPreview

final class PlaybackEngineTests: XCTestCase {
    func testToggleLoopCommandCyclesFullLoop() {
        let engine = PlaybackEngine()
        var modes: [LoopMode] = []
        engine.onLoopModeUpdate = { modes.append($0) }

        XCTAssertEqual(engine.loopMode(), .off)

        engine.handle(command: .toggleLoop)
        XCTAssertEqual(engine.loopMode(), .full)

        engine.handle(command: .toggleLoop)
        XCTAssertEqual(engine.loopMode(), .off)

        XCTAssertEqual(modes, [.full, .off])
    }

    func testSetAndClearLoopRangeNotifiesObservers() {
        let engine = PlaybackEngine()
        var modes: [LoopMode] = []
        engine.onLoopModeUpdate = { modes.append($0) }

        engine.setLoopRange(start: 2, end: 8)
        XCTAssertEqual(engine.loopMode(), .range(start: 2, end: 8))

        engine.clearLoop()
        XCTAssertEqual(engine.loopMode(), .off)
        XCTAssertEqual(modes, [.range(start: 2, end: 8), .off])
    }

    func testAttachClearsExistingLoop() {
        let engine = PlaybackEngine()
        engine.setLoopFull(enabled: true)

        var clearedToOff = false
        engine.onLoopModeUpdate = { mode in
            if mode == .off {
                clearedToOff = true
            }
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("quickpreview-empty-\(UUID().uuidString).mp4")
        FileManager.default.createFile(atPath: tempURL.path, contents: Data(), attributes: nil)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        engine.attach(to: tempURL, autoplay: false)
        XCTAssertEqual(engine.loopMode(), .off)
        XCTAssertTrue(clearedToOff)
    }

    func testSeekCommandsClampWhenDurationIsUnknown() {
        let engine = PlaybackEngine()
        engine.handle(command: .seekBy(seconds: 5))
        engine.handle(command: .seekTo(seconds: 12))

        XCTAssertEqual(engine.currentDurationSeconds(), 0)
        XCTAssertEqual(engine.currentTimeSeconds(), 0, accuracy: 0.05)
    }

    func testFineAndCoarseStepAmounts() {
        let engine = PlaybackEngine(
            seekController: PreciseSeekController(fineStepSeconds: 0.2, coarseStepSeconds: 2.5)
        )
        XCTAssertEqual(engine.fineStepAmount(), 0.2)
        XCTAssertEqual(engine.coarseStepAmount(), 2.5)
    }

    func testTogglePlayPauseWithEmptyPlayerDoesNotCrash() {
        let engine = PlaybackEngine()
        engine.handle(command: .togglePlayPause)
        engine.pause()
        engine.play()
        engine.pause()
        XCTAssertNotNil(engine.currentPlayer())
    }

    func testScrubLifecycleEndsWithSeek() {
        let engine = PlaybackEngine()
        engine.beginScrubbing()
        engine.scrub(to: 4)
        engine.endScrubbing(at: 4)
        XCTAssertEqual(engine.currentTimeSeconds(), 0, accuracy: 0.05)
    }
}
