import Foundation

typealias BookmarkID = UUID

enum BookmarkListScope: Int, CaseIterable {
    case currentVideo
    case allVideos
}

struct Bookmark: Codable, Equatable {
    let id: BookmarkID
    let videoPath: String
    let timeSeconds: PlaybackSeconds
    let createdAt: Date
    let updatedAt: Date
    let tags: [String]

    var videoURL: URL {
        URL(fileURLWithPath: videoPath)
    }

    var videoDisplayName: String {
        videoURL.lastPathComponent
    }

    func withUpdatedTags(_ tags: [String], updatedAt: Date = Date()) -> Bookmark {
        Bookmark(
            id: id,
            videoPath: videoPath,
            timeSeconds: timeSeconds,
            createdAt: createdAt,
            updatedAt: updatedAt,
            tags: tags
        )
    }
}

extension Notification.Name {
    static let bookmarkStoreDidChange = Notification.Name("BookmarkStoreDidChange")
}

final class BookmarkStore {
    private static let defaultsKey = "bookmarks"

    private let persistDebounceInterval: TimeInterval
    private let defaults: UserDefaults
    private var cache: [Bookmark] = []
    private var hasLoadedCache = false
    private var persistWorkItem: DispatchWorkItem?

    init(
        defaults: UserDefaults = .standard,
        persistDebounceInterval: TimeInterval = 0.2
    ) {
        self.defaults = defaults
        self.persistDebounceInterval = persistDebounceInterval
    }

    func allBookmarks() -> [Bookmark] {
        loadCacheIfNeeded()
        return cache.sorted(by: bookmarkSortComparator)
    }

    func bookmarks(
        scope: BookmarkListScope,
        currentVideoURL: URL?,
        searchQuery: String
    ) -> [Bookmark] {
        loadCacheIfNeeded()
        let normalizedVideoPath = currentVideoURL?.standardizedFileURL.path
        let queryTokens = normalizedSearchTokens(from: searchQuery)

        return cache
            .filter { bookmark in
                switch scope {
                case .currentVideo:
                    guard let normalizedVideoPath else { return false }
                    return bookmark.videoPath == normalizedVideoPath
                case .allVideos:
                    return true
                }
            }
            .filter { bookmark in
                guard !queryTokens.isEmpty else { return true }
                let haystack = normalizedSearchTokens(
                    from: ([bookmark.videoDisplayName, BookmarkStore.formattedTimestamp(bookmark.timeSeconds)] + bookmark.tags)
                        .joined(separator: " ")
                )
                return queryTokens.allSatisfy { token in
                    haystack.contains(where: { $0.contains(token) })
                }
            }
            .sorted(by: bookmarkSortComparator)
    }

    @discardableResult
    func addBookmark(
        videoURL: URL,
        timeSeconds: PlaybackSeconds,
        tags: [String] = []
    ) -> Bookmark {
        loadCacheIfNeeded()
        let bookmark = Bookmark(
            id: BookmarkID(),
            videoPath: videoURL.standardizedFileURL.path,
            timeSeconds: max(timeSeconds, 0),
            createdAt: Date(),
            updatedAt: Date(),
            tags: Self.sanitizedTags(tags)
        )
        cache.append(bookmark)
        schedulePersist()
        notifyDidChange()
        return bookmark
    }

    func bookmark(for id: BookmarkID) -> Bookmark? {
        loadCacheIfNeeded()
        return cache.first(where: { $0.id == id })
    }

    func updateTags(for id: BookmarkID, tags: [String]) {
        loadCacheIfNeeded()
        guard let index = cache.firstIndex(where: { $0.id == id }) else {
            return
        }
        let sanitizedTags = Self.sanitizedTags(tags)
        guard cache[index].tags != sanitizedTags else {
            return
        }
        cache[index] = cache[index].withUpdatedTags(sanitizedTags)
        schedulePersist()
        notifyDidChange()
    }

    func removeBookmark(id: BookmarkID) {
        loadCacheIfNeeded()
        let originalCount = cache.count
        cache.removeAll { $0.id == id }
        guard cache.count != originalCount else {
            return
        }
        schedulePersist()
        notifyDidChange()
    }

    func flushPendingWrites() {
        guard let persistWorkItem else { return }
        persistWorkItem.cancel()
        if let data = try? JSONEncoder().encode(cache) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
        self.persistWorkItem = nil
    }

    static func formattedTimestamp(_ seconds: PlaybackSeconds) -> String {
        guard seconds.isFinite, seconds >= 0 else {
            return "00:00"
        }
        let wholeSeconds = Int(seconds.rounded(.down))
        let hours = wholeSeconds / 3600
        let minutes = (wholeSeconds % 3600) / 60
        let remainingSeconds = wholeSeconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }

    static func tagString(from tags: [String]) -> String {
        sanitizedTags(tags).joined(separator: ", ")
    }

    static func tags(from rawValue: String) -> [String] {
        sanitizedTags(
            rawValue
                .split(separator: ",", omittingEmptySubsequences: false)
                .map(String.init)
        )
    }

    private func loadCacheIfNeeded() {
        guard !hasLoadedCache else { return }
        hasLoadedCache = true
        guard
            let data = defaults.data(forKey: Self.defaultsKey),
            let decoded = try? JSONDecoder().decode([Bookmark].self, from: data)
        else {
            cache = []
            return
        }
        cache = decoded
    }

    private func schedulePersist() {
        persistWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if let data = try? JSONEncoder().encode(self.cache) {
                self.defaults.set(data, forKey: Self.defaultsKey)
            }
            self.persistWorkItem = nil
        }
        persistWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + persistDebounceInterval, execute: workItem)
    }

    private func notifyDidChange() {
        NotificationCenter.default.post(name: .bookmarkStoreDidChange, object: self)
    }

    private func normalizedSearchTokens(from rawValue: String) -> [String] {
        rawValue
            .localizedLowercase
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func sanitizedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.reduce(into: [String]()) { result, rawTag in
            let tag = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty else { return }
            let normalizedTag = tag.localizedLowercase
            guard !seen.contains(normalizedTag) else { return }
            seen.insert(normalizedTag)
            result.append(tag)
        }
    }

    private func bookmarkSortComparator(lhs: Bookmark, rhs: Bookmark) -> Bool {
        if lhs.videoPath != rhs.videoPath {
            return lhs.videoPath.localizedCaseInsensitiveCompare(rhs.videoPath) == .orderedAscending
        }
        if abs(lhs.timeSeconds - rhs.timeSeconds) > 0.0001 {
            return lhs.timeSeconds < rhs.timeSeconds
        }
        return lhs.createdAt < rhs.createdAt
    }
}
