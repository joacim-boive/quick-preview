import Foundation
import CoreMedia

typealias PlaybackSeconds = Double

enum LoopMode: Equatable {
    case off
    case full
    case range(start: PlaybackSeconds, end: PlaybackSeconds)
}

struct PlaybackPosition: Equatable {
    let seconds: PlaybackSeconds
    let duration: PlaybackSeconds

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(seconds / duration, 0), 1)
    }
}

enum PlaybackCommand: Equatable {
    case togglePlayPause
    case seekBy(seconds: PlaybackSeconds)
    case seekTo(seconds: PlaybackSeconds)
    case seekFrame(delta: Int)
    case toggleLoop
}

extension CMTime {
    static func seconds(_ value: PlaybackSeconds) -> CMTime {
        CMTimeMakeWithSeconds(value, preferredTimescale: 600)
    }
}
