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

    static func loadFrameStepSeconds(for asset: AVAsset) async -> PlaybackSeconds? {
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                return nil
            }

            let nominalFrameRate = try await track.load(.nominalFrameRate)
            guard nominalFrameRate > 0 else {
                return nil
            }

            return 1.0 / PlaybackSeconds(nominalFrameRate)
        } catch {
            return nil
        }
    }
}
