import Foundation

final class LoopController {
    private(set) var mode: LoopMode = .off

    func setFullLoop(enabled: Bool) {
        mode = enabled ? .full : .off
    }

    func setRangeLoop(start: PlaybackSeconds, end: PlaybackSeconds) {
        let clampedStart = max(0, min(start, end))
        let clampedEnd = max(clampedStart, end)
        mode = .range(start: clampedStart, end: clampedEnd)
    }

    func clearLoop() {
        mode = .off
    }

    func isLooping() -> Bool {
        mode != .off
    }

    func normalizedPosition(for seconds: PlaybackSeconds, duration: PlaybackSeconds) -> PlaybackSeconds {
        guard duration > 0 else { return 0 }

        switch mode {
        case .off:
            return min(max(seconds, 0), duration)
        case .full:
            let safe = max(seconds, 0)
            if safe < duration { return safe }
            return safe.truncatingRemainder(dividingBy: duration)
        case let .range(start, end):
            let span = max(end - start, 0.001)
            let safe = max(seconds, start)
            if safe <= end { return safe }
            return start + (safe - start).truncatingRemainder(dividingBy: span)
        }
    }

    func loopRestartTime(currentSeconds: PlaybackSeconds, duration: PlaybackSeconds) -> PlaybackSeconds? {
        switch mode {
        case .off:
            return nil
        case .full:
            guard currentSeconds >= duration, duration > 0 else { return nil }
            return 0
        case let .range(start, end):
            guard currentSeconds >= end else { return nil }
            return start
        }
    }
}
