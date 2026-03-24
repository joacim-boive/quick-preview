import AppKit
import AVFoundation

final class VideoThumbnailService {
    private let cache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(label: "quickpreview.video-thumbnail-service", qos: .userInitiated)

    func requestThumbnail(
        for videoURL: URL,
        at timeSeconds: PlaybackSeconds,
        maximumSize: CGSize? = CGSize(width: 128, height: 72),
        completion: @escaping (NSImage?) -> Void
    ) {
        let cacheKey = thumbnailCacheKey(for: videoURL, timeSeconds: timeSeconds, maximumSize: maximumSize)
        if let cachedImage = cache.object(forKey: cacheKey as NSString) {
            completion(cachedImage)
            return
        }

        let normalizedURL = videoURL.standardizedFileURL
        queue.async { [weak self] in
            guard let self else { return }
            let generatedImage = self.generateThumbnail(
                for: normalizedURL,
                at: max(timeSeconds, 0),
                maximumSize: maximumSize
            )
            if let generatedImage {
                self.cache.setObject(generatedImage, forKey: cacheKey as NSString)
            }
            DispatchQueue.main.async {
                completion(generatedImage)
            }
        }
    }

    func purgeCache() {
        cache.removeAllObjects()
    }

    private func generateThumbnail(
        for videoURL: URL,
        at timeSeconds: PlaybackSeconds,
        maximumSize: CGSize?
    ) -> NSImage? {
        let asset = AVAsset(url: videoURL)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        if let maximumSize {
            imageGenerator.maximumSize = maximumSize
        }
        imageGenerator.requestedTimeToleranceBefore = .zero
        imageGenerator.requestedTimeToleranceAfter = .zero

        let requestedTime = CMTime(seconds: timeSeconds, preferredTimescale: 600)
        guard let cgImage = try? imageGenerator.copyCGImage(at: requestedTime, actualTime: nil) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: .zero)
    }

    private func thumbnailCacheKey(
        for videoURL: URL,
        timeSeconds: PlaybackSeconds,
        maximumSize: CGSize?
    ) -> String {
        let roundedMilliseconds = Int((max(timeSeconds, 0) * 1000).rounded())
        if let maximumSize {
            let roundedWidth = Int(maximumSize.width.rounded())
            let roundedHeight = Int(maximumSize.height.rounded())
            return "\(videoURL.standardizedFileURL.path)|\(roundedMilliseconds)|\(roundedWidth)x\(roundedHeight)"
        }
        return "\(videoURL.standardizedFileURL.path)|\(roundedMilliseconds)|native"
    }
}
