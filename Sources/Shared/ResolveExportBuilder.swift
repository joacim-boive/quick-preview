import Foundation

struct ResolveExportMarker: Equatable {
    let timeSeconds: PlaybackSeconds
    let name: String
    let note: String?
}

struct ResolveExportItem: Equatable {
    let videoPath: String
    let clipStart: PlaybackSeconds
    let clipEnd: PlaybackSeconds
    let durationSeconds: PlaybackSeconds
    let frameRate: Double
    let width: Int
    let height: Int
    let usedFallbackFrameRate: Bool
    let tags: [String]
    let markers: [ResolveExportMarker]

    var videoURL: URL {
        URL(fileURLWithPath: videoPath).quickPreviewNormalizedFileURL
    }

    var clipName: String {
        let stem = (videoPath as NSString).deletingPathExtension
        let baseName = (stem as NSString).lastPathComponent
        guard !tags.isEmpty else {
            return baseName
        }
        return "\(baseName) [\(tags.joined(separator: ", "))]"
    }

    var clipDuration: PlaybackSeconds {
        max(clipEnd - clipStart, 0)
    }
}

struct ResolveExportBuildResult: Equatable {
    let items: [ResolveExportItem]
    let skippedPaths: [String]
    let usedFallbackFrameRate: Bool
}

enum ResolveExportError: Error, Equatable {
    case emptySelection
    case noExportableClips
    case writeFailed(String)
}

enum ResolveExportBuilder {
    static let fallbackFrameRate = AVAssetMediaTimingProvider.fallbackFrameRate

    static func build(
        selectedBookmarks: [Bookmark],
        defaults: UserDefaults = .standard,
        mediaAccessStore: SecurityScopedMediaAccessStore? = nil,
        timingProvider: MediaTimingProviding = AVAssetMediaTimingProvider()
    ) async -> ResolveExportBuildResult {
        var orderedPaths: [String] = []
        var bookmarksByPath: [String: [Bookmark]] = [:]

        for bookmark in selectedBookmarks {
            let path = bookmark.normalizedVideoPath
            if bookmarksByPath[path] == nil {
                orderedPaths.append(path)
                bookmarksByPath[path] = []
            }
            bookmarksByPath[path, default: []].append(bookmark)
        }

        return await build(
            orderedPaths: orderedPaths,
            bookmarksByPath: bookmarksByPath,
            clipOverrides: [:],
            defaults: defaults,
            mediaAccessStore: mediaAccessStore,
            timingProvider: timingProvider
        )
    }

    /// Player one-shot: current file with explicit in/out (or nil to use stored/full duration).
    static func build(
        videoPath: String,
        clipStart: PlaybackSeconds?,
        clipEnd: PlaybackSeconds?,
        bookmarks: [Bookmark],
        defaults: UserDefaults = .standard,
        mediaAccessStore: SecurityScopedMediaAccessStore? = nil,
        timingProvider: MediaTimingProviding = AVAssetMediaTimingProvider()
    ) async -> ResolveExportBuildResult {
        let path = URL(fileURLWithPath: videoPath).quickPreviewNormalizedPath
        var overrides: [String: (PlaybackSeconds, PlaybackSeconds)] = [:]
        if let clipStart, let clipEnd {
            overrides[path] = (clipStart, clipEnd)
        }
        return await build(
            orderedPaths: [path],
            bookmarksByPath: [path: bookmarks],
            clipOverrides: overrides,
            defaults: defaults,
            mediaAccessStore: mediaAccessStore,
            timingProvider: timingProvider
        )
    }

    private static func build(
        orderedPaths: [String],
        bookmarksByPath: [String: [Bookmark]],
        clipOverrides: [String: (PlaybackSeconds, PlaybackSeconds)],
        defaults: UserDefaults,
        mediaAccessStore: SecurityScopedMediaAccessStore?,
        timingProvider: MediaTimingProviding
    ) async -> ResolveExportBuildResult {
        var items: [ResolveExportItem] = []
        var skipped: [String] = []
        var usedFallback = false

        for path in orderedPaths {
            let fileURL = URL(fileURLWithPath: path)
            let accessibleURL = mediaAccessStore?.beginAccess(for: fileURL) ?? fileURL
            defer {
                if mediaAccessStore != nil {
                    mediaAccessStore?.endAccess(for: accessibleURL)
                }
            }

            guard let timing = await timingProvider.timing(for: accessibleURL) else {
                skipped.append(path)
                continue
            }

            if timing.usedFallbackFrameRate {
                usedFallback = true
            }

            let duration = timing.durationSeconds
            let range: (start: PlaybackSeconds, end: PlaybackSeconds)
            if let override = clipOverrides[path] {
                range = clampedRange(start: override.0, end: override.1, duration: duration)
            } else if let stored = ClipSelectionStore.selection(forPath: path, defaults: defaults) {
                range = clampedRange(start: stored.start, end: stored.end, duration: duration)
            } else {
                range = (0, duration)
            }

            let sourceBookmarks = bookmarksByPath[path] ?? []
            let tags = orderedUniqueTags(from: sourceBookmarks)
            let markers = markers(
                from: sourceBookmarks,
                clipStart: range.start,
                clipEnd: range.end,
                frameRate: timing.frameRate
            )

            items.append(
                ResolveExportItem(
                    videoPath: accessibleURL.path,
                    clipStart: range.start,
                    clipEnd: range.end,
                    durationSeconds: duration,
                    frameRate: timing.frameRate,
                    width: timing.width,
                    height: timing.height,
                    usedFallbackFrameRate: timing.usedFallbackFrameRate,
                    tags: tags,
                    markers: markers
                )
            )
        }

        return ResolveExportBuildResult(
            items: items,
            skippedPaths: skipped,
            usedFallbackFrameRate: usedFallback
        )
    }

    static func markers(
        from bookmarks: [Bookmark],
        clipStart: PlaybackSeconds,
        clipEnd: PlaybackSeconds,
        frameRate: Double
    ) -> [ResolveExportMarker] {
        bookmarks
            .filter { $0.timeSeconds >= clipStart && $0.timeSeconds <= clipEnd }
            .sorted { $0.timeSeconds < $1.timeSeconds }
            .map { bookmark in
                let tags = bookmark.tags
                let name: String
                if let first = tags.first, !first.isEmpty {
                    name = first
                } else {
                    name = formatTimecode(bookmark.timeSeconds, frameRate: frameRate)
                }
                let remaining = Array(tags.dropFirst())
                let note = remaining.isEmpty ? nil : remaining.joined(separator: ", ")
                return ResolveExportMarker(timeSeconds: bookmark.timeSeconds, name: name, note: note)
            }
    }

    static func orderedUniqueTags(from bookmarks: [Bookmark]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for bookmark in bookmarks {
            for tag in bookmark.tags {
                let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
                seen.insert(trimmed)
                result.append(trimmed)
            }
        }
        return result
    }

    static func clampedRange(
        start: PlaybackSeconds,
        end: PlaybackSeconds,
        duration: PlaybackSeconds
    ) -> (start: PlaybackSeconds, end: PlaybackSeconds) {
        let lower = min(max(start, 0), duration)
        let upper = min(max(end, lower), duration)
        if upper <= lower {
            return (0, duration)
        }
        return (lower, upper)
    }

    static func formatTimecode(_ seconds: PlaybackSeconds, frameRate: Double) -> String {
        let fps = frameRate > 0 ? frameRate : fallbackFrameRate
        let total = max(Int(seconds.rounded(.down)), 0)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        let fraction = seconds - PlaybackSeconds(total)
        let frames = Int((fraction * fps).rounded(.down))
        if h > 0 {
            return String(format: "%02d:%02d:%02d:%02d", h, m, s, frames)
        }
        return String(format: "%02d:%02d:%02d", m, s, frames)
    }
}
