import AppKit
import AVFoundation

final class VideoThumbnailService {
    enum RequestMode {
        case standard
        case interactivePreview

        var tolerance: CMTime {
            switch self {
            case .standard:
                return CMTime(seconds: 0.12, preferredTimescale: 600)
            case .interactivePreview:
                return CMTime(seconds: 0.35, preferredTimescale: 600)
            }
        }

        var nativeTolerance: CMTime {
            switch self {
            case .standard:
                return CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
            case .interactivePreview:
                return CMTime(seconds: 0.12, preferredTimescale: 600)
            }
        }

        var cacheBucketMilliseconds: Int {
            switch self {
            case .standard:
                return 1
            case .interactivePreview:
                return 90
            }
        }
    }

    private let cache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(label: "quickpreview.video-thumbnail-service", qos: .userInitiated)
    private let stateQueue = DispatchQueue(label: "quickpreview.video-thumbnail-service.state")
    private var inFlightRequests: [NSString: [(NSImage?) -> Void]] = [:]
    private var imageGeneratorsByVideoPath: [String: AVAssetImageGenerator] = [:]
    private var latestInteractiveRequestIDByVideoPath: [String: Int] = [:]
    private var interactiveInFlightCacheKeyByVideoPath: [String: NSString] = [:]

    init() {
        cache.countLimit = 600
    }

    func requestThumbnail(
        for videoURL: URL,
        at timeSeconds: PlaybackSeconds,
        maximumSize: CGSize? = CGSize(width: 128, height: 72),
        mode: RequestMode = .standard,
        completion: @escaping (NSImage?) -> Void
    ) {
        let cacheKey = thumbnailCacheKey(
            for: videoURL,
            timeSeconds: timeSeconds,
            maximumSize: maximumSize,
            mode: mode
        )
        if let cachedImage = cache.object(forKey: cacheKey as NSString) {
            completion(cachedImage)
            return
        }

        if mode == .interactivePreview {
            requestInteractiveThumbnail(
                for: videoURL,
                at: timeSeconds,
                maximumSize: maximumSize,
                cacheKey: cacheKey,
                completion: completion
            )
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
                    maximumSize: maximumSize,
                    mode: mode
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
            self?.latestInteractiveRequestIDByVideoPath.removeAll()
            self?.interactiveInFlightCacheKeyByVideoPath.removeAll()
        }
        queue.async { [weak self] in
            self?.imageGeneratorsByVideoPath.removeAll()
        }
    }

    private func requestInteractiveThumbnail(
        for videoURL: URL,
        at timeSeconds: PlaybackSeconds,
        maximumSize: CGSize?,
        cacheKey: String,
        completion: @escaping (NSImage?) -> Void
    ) {
        let normalizedURL = videoURL.standardizedFileURL
        let normalizedPath = normalizedURL.path
        let nsCacheKey = cacheKey as NSString

        stateQueue.async { [weak self] in
            guard let self else { return }

            if self.interactiveInFlightCacheKeyByVideoPath[normalizedPath] == nsCacheKey,
               self.inFlightRequests[nsCacheKey] != nil {
                self.inFlightRequests[nsCacheKey]?.append(completion)
                return
            }

            if let staleCacheKey = self.interactiveInFlightCacheKeyByVideoPath[normalizedPath] {
                self.inFlightRequests.removeValue(forKey: staleCacheKey)
            }

            let requestID = (self.latestInteractiveRequestIDByVideoPath[normalizedPath] ?? 0) + 1
            self.latestInteractiveRequestIDByVideoPath[normalizedPath] = requestID
            self.interactiveInFlightCacheKeyByVideoPath[normalizedPath] = nsCacheKey
            self.inFlightRequests[nsCacheKey] = [completion]

            self.queue.async { [weak self] in
                guard let self else { return }
                let generator = self.imageGenerator(for: normalizedURL)
                generator.cancelAllCGImageGeneration()
                self.configure(
                    imageGenerator: generator,
                    maximumSize: maximumSize,
                    mode: .interactivePreview
                )

                let requestedTime = CMTime(seconds: max(timeSeconds, 0), preferredTimescale: 600)
                generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: requestedTime)]) { [weak self] _, cgImage, _, _, _ in
                    guard let self else { return }
                    let generatedImage = cgImage.map { NSImage(cgImage: $0, size: .zero) }

                    self.stateQueue.async { [weak self] in
                        guard let self else { return }

                        let isLatestRequest =
                            self.latestInteractiveRequestIDByVideoPath[normalizedPath] == requestID
                            && self.interactiveInFlightCacheKeyByVideoPath[normalizedPath] == nsCacheKey

                        let completions = self.inFlightRequests.removeValue(forKey: nsCacheKey) ?? []
                        if isLatestRequest {
                            self.interactiveInFlightCacheKeyByVideoPath.removeValue(forKey: normalizedPath)
                            if let generatedImage {
                                self.cache.setObject(generatedImage, forKey: nsCacheKey)
                            }
                            DispatchQueue.main.async {
                                completions.forEach { $0(generatedImage) }
                            }
                            return
                        }
                    }
                }
            }
        }
    }

    private func generateThumbnail(
        for videoURL: URL,
        at timeSeconds: PlaybackSeconds,
        maximumSize: CGSize?,
        mode: RequestMode
    ) -> NSImage? {
        let imageGenerator = imageGenerator(for: videoURL)
        configure(imageGenerator: imageGenerator, maximumSize: maximumSize, mode: mode)

        let requestedTime = CMTime(seconds: timeSeconds, preferredTimescale: 600)
        guard let cgImage = try? imageGenerator.copyCGImage(at: requestedTime, actualTime: nil) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: .zero)
    }

    private func configure(
        imageGenerator: AVAssetImageGenerator,
        maximumSize: CGSize?,
        mode: RequestMode
    ) {
        imageGenerator.appliesPreferredTrackTransform = true
        if let maximumSize {
            imageGenerator.maximumSize = maximumSize
        } else {
            imageGenerator.maximumSize = .zero
        }
        let tolerance = maximumSize == nil ? mode.nativeTolerance : mode.tolerance
        imageGenerator.requestedTimeToleranceBefore = tolerance
        imageGenerator.requestedTimeToleranceAfter = tolerance
    }

    private func imageGenerator(for videoURL: URL) -> AVAssetImageGenerator {
        let normalizedPath = videoURL.standardizedFileURL.path
        if let existingGenerator = imageGeneratorsByVideoPath[normalizedPath] {
            return existingGenerator
        }

        let generator = AVAssetImageGenerator(asset: AVAsset(url: videoURL))
        generator.appliesPreferredTrackTransform = true
        imageGeneratorsByVideoPath[normalizedPath] = generator
        return generator
    }

    private func thumbnailCacheKey(
        for videoURL: URL,
        timeSeconds: PlaybackSeconds,
        maximumSize: CGSize?,
        mode: RequestMode
    ) -> String {
        let bucketMilliseconds = max(mode.cacheBucketMilliseconds, 1)
        let rawMilliseconds = Int((max(timeSeconds, 0) * 1000).rounded())
        let roundedMilliseconds = ((rawMilliseconds + (bucketMilliseconds / 2)) / bucketMilliseconds) * bucketMilliseconds
        if let maximumSize {
            let roundedWidth = Int(maximumSize.width.rounded())
            let roundedHeight = Int(maximumSize.height.rounded())
            return "\(videoURL.standardizedFileURL.path)|\(roundedMilliseconds)|\(roundedWidth)x\(roundedHeight)|\(bucketMilliseconds)"
        }
        return "\(videoURL.standardizedFileURL.path)|\(roundedMilliseconds)|native|\(bucketMilliseconds)"
    }
}
