import Foundation
import AVFoundation

final class PreciseSeekController {
    let fineStepSeconds: PlaybackSeconds
    let coarseStepSeconds: PlaybackSeconds

    init(
        fineStepSeconds: PlaybackSeconds = 0.1,
        coarseStepSeconds: PlaybackSeconds = 1.0
    ) {
        self.fineStepSeconds = fineStepSeconds
        self.coarseStepSeconds = coarseStepSeconds
    }

    func stepSeconds(isCoarse: Bool) -> PlaybackSeconds {
        isCoarse ? coarseStepSeconds : fineStepSeconds
    }

    func clampedSeekTarget(
        current: PlaybackSeconds,
        delta: PlaybackSeconds,
        duration: PlaybackSeconds
    ) -> PlaybackSeconds {
        let target = current + delta
        return min(max(target, 0), max(duration, 0))
    }

    func frameStepSeconds(for item: AVPlayerItem?) -> PlaybackSeconds? {
        guard
            let track = item?.asset.tracks(withMediaType: .video).first,
            track.nominalFrameRate > 0
        else {
            return nil
        }
        return 1.0 / PlaybackSeconds(track.nominalFrameRate)
    }
}
