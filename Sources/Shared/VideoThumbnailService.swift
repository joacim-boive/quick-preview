import AppKit
import AVFoundation

final class VideoThumbnailService {
    private let cache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(label: "quickpreview.video-thumbnail-service", qos: .userInitiated)
    private let stateQueue = DispatchQueue(label: "quickpreview.video-thumbnail-service.state")
    private var inFlightRequests: [NSString: [(NSImage?) -> Void]] = [:]

    init() {
        cache.countLimit = 600
    }

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
        let nsCacheKey = cacheKey as NSString
        stateQueue.async { [weak self] in
            guard let self else { return }
            if self.inFlightRequests[nsCacheKey] != nil {
                self.inFlightRequests[nsCacheKey]?.append(completion)
                return
            }
            self.inFlightRequests[nsCacheKey] = [completion]

            self.queue.async { [weak self] in
                guard let self else { return }
                let generatedImage = self.generateThumbnail(
                    for: normalizedURL,
                    at: max(timeSeconds, 0),
                    maximumSize: maximumSize
                )
                if let generatedImage {
                    self.cache.setObject(generatedImage, forKey: nsCacheKey)
                }
                self.stateQueue.async { [weak self] in
                    guard let self else { return }
                    let completions = self.inFlightRequests.removeValue(forKey: nsCacheKey) ?? []
                    DispatchQueue.main.async {
                        completions.forEach { $0(generatedImage) }
                    }
                }
            }
        }
    }

    func purgeCache() {
        cache.removeAllObjects()
        stateQueue.async { [weak self] in
            self?.inFlightRequests.removeAll()
        }
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
        let tolerance = maximumSize == nil
            ? CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
            : CMTime(seconds: 0.12, preferredTimescale: 600)
        imageGenerator.requestedTimeToleranceBefore = tolerance
        imageGenerator.requestedTimeToleranceAfter = tolerance

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
