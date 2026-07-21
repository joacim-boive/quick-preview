import AVFoundation
import CoreMedia
import Foundation

struct MediaTiming: Equatable {
    let durationSeconds: PlaybackSeconds
    let frameRate: Double
    let width: Int
    let height: Int
    let usedFallbackFrameRate: Bool
}

protocol MediaTimingProviding {
    func timing(for url: URL) async -> MediaTiming?
}

struct AVAssetMediaTimingProvider: MediaTimingProviding {
    static let fallbackFrameRate: Double = 25
    static let fallbackWidth = 1920
    static let fallbackHeight = 1080

    func timing(for url: URL) async -> MediaTiming? {
        await Self.loadTiming(for: url)
    }

    private static func loadTiming(for url: URL) async -> MediaTiming? {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            guard duration.isNumeric, duration.isValid, duration.seconds.isFinite, duration.seconds > 0 else {
                return nil
            }

            var frameRate = fallbackFrameRate
            var usedFallback = true
            var width = fallbackWidth
            var height = fallbackHeight

            if let track = try await asset.loadTracks(withMediaType: .video).first {
                let nominal = Double(try await track.load(.nominalFrameRate))
                if nominal > 0 {
                    frameRate = nominal
                    usedFallback = false
                }
                let naturalSize = try await track.load(.naturalSize)
                let transform = try await track.load(.preferredTransform)
                let size = naturalSize.applying(transform)
                let resolvedWidth = Int(abs(size.width).rounded())
                let resolvedHeight = Int(abs(size.height).rounded())
                if resolvedWidth > 0, resolvedHeight > 0 {
                    width = resolvedWidth
                    height = resolvedHeight
                }
            }

            return MediaTiming(
                durationSeconds: duration.seconds,
                frameRate: frameRate,
                width: width,
                height: height,
                usedFallbackFrameRate: usedFallback
            )
        } catch {
            return nil
        }
    }
}
