import Foundation

typealias BookmarkID = UUID

enum BookmarkListScope: Int, CaseIterable {
    case currentVideo
    case allVideos
    case imported
    case protected
}

enum BookmarkSort: Equatable {
    case automatic
    case importedAt(ascending: Bool)
    case fileCreatedAt(ascending: Bool)
}

struct Bookmark: Codable, Equatable {
    let id: BookmarkID
    let videoPath: String
    let timeSeconds: PlaybackSeconds
    let createdAt: Date
    let updatedAt: Date
    let tags: [String]
    let isProtected: Bool
    let isImported: Bool
    let importedAt: Date?
    let fileCreatedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id
        case videoPath
        case timeSeconds
        case createdAt
        case updatedAt
        case tags
        case isProtected
        case isImported
        case importedAt
        case fileCreatedAt
    }

    init(
        id: BookmarkID,
        videoPath: String,
        timeSeconds: PlaybackSeconds,
        createdAt: Date,
        updatedAt: Date,
        tags: [String],
        isProtected: Bool = false,
        isImported: Bool = false,
        importedAt: Date? = nil,
        fileCreatedAt: Date? = nil
    ) {
        self.id = id
        self.videoPath = videoPath
        self.timeSeconds = timeSeconds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.tags = tags
        self.isProtected = isProtected
        self.isImported = isImported
        self.importedAt = importedAt
        self.fileCreatedAt = fileCreatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(BookmarkID.self, forKey: .id)
        videoPath = try container.decode(String.self, forKey: .videoPath)
        timeSeconds = try container.decode(PlaybackSeconds.self, forKey: .timeSeconds)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        tags = try container.decode([String].self, forKey: .tags)
        isProtected = try container.decodeIfPresent(Bool.self, forKey: .isProtected) ?? false
        isImported = try container.decodeIfPresent(Bool.self, forKey: .isImported) ?? false
        importedAt = try container.decodeIfPresent(Date.self, forKey: .importedAt)
        fileCreatedAt = try container.decodeIfPresent(Date.self, forKey: .fileCreatedAt)
    }

    var videoURL: URL {
        URL(fileURLWithPath: videoPath)
    }

    var videoDisplayName: String {
        (videoPath as NSString).lastPathComponent
    }

    func withUpdatedTags(_ tags: [String], updatedAt: Date = Date()) -> Bookmark {
        Bookmark(
            id: id,
            videoPath: videoPath,
            timeSeconds: timeSeconds,
            createdAt: createdAt,
            updatedAt: updatedAt,
            tags: tags,
            isProtected: isProtected,
            isImported: isImported,
            importedAt: importedAt,
            fileCreatedAt: fileCreatedAt
        )
    }

    func withUpdatedProtection(_ isProtected: Bool, updatedAt: Date = Date()) -> Bookmark {
        Bookmark(
            id: id,
            videoPath: videoPath,
            timeSeconds: timeSeconds,
            createdAt: createdAt,
            updatedAt: updatedAt,
            tags: tags,
            isProtected: isProtected,
            isImported: isImported,
            importedAt: importedAt,
            fileCreatedAt: fileCreatedAt
        )
    }
}

enum BookmarkVisibility: Equatable {
    case publicOnly
    case all
    case protectedOnly
}

extension Notification.Name {
    static let bookmarkStoreDidChange = Notification.Name("BookmarkStoreDidChange")
}

final class BookmarkStore {
    private static let defaultsKey = "bookmarks"

    private struct PreparedBookmark {
        let searchableTokens: [String]
    }

    private let persistDebounceInterval: TimeInterval
    private let defaults: UserDefaults
    private let persistenceQueue = DispatchQueue(
        label: "quickpreview.bookmark-store.persistence",
        qos: .utility
    )
    private var cache: [Bookmark] = []
    private var preparedBookmarks: [BookmarkID: PreparedBookmark] = [:]
    private var hasLoadedCache = false
    private var persistWorkItem: DispatchWorkItem?

    init(
        defaults: UserDefaults = .standard,
        persistDebounceInterval: TimeInterval = 0.2
    ) {
        self.defaults = defaults
        self.persistDebounceInterval = persistDebounceInterval
    }

    func allBookmarks(visibility: BookmarkVisibility = .all) -> [Bookmark] {
        loadCacheIfNeeded()
        return filteredBookmarks(cache, visibility: visibility).sorted(by: bookmarkSortComparator)
    }

    func bookmarks(
        scope: BookmarkListScope,
        currentVideoURL: URL?,
        searchQuery: String,
        sort: BookmarkSort = .automatic,
        visibility: BookmarkVisibility = .publicOnly
    ) -> [Bookmark] {
        loadCacheIfNeeded()
        let normalizedVideoPath = currentVideoURL?.standardizedFileURL.path
        let queryTokens = normalizedSearchTokens(from: searchQuery)
        var results: [Bookmark] = []
        results.reserveCapacity(cache.count)

        for bookmark in cache {
            guard matchesVisibility(bookmark, visibility: visibility) else {
                continue
            }
            guard matchesScope(bookmark, scope: scope, normalizedVideoPath: normalizedVideoPath) else {
                continue
            }
            guard matchesQuery(bookmark, queryTokens: queryTokens) else {
                continue
            }
            results.append(bookmark)
        }

        return results.sorted(by: sortComparator(for: sort, scope: scope))
    }

    @discardableResult
    func addBookmark(
        videoURL: URL,
        timeSeconds: PlaybackSeconds,
        tags: [String] = []
    ) -> Bookmark {
        loadCacheIfNeeded()
        let normalizedURL = videoURL.standardizedFileURL
        let bookmark = Bookmark(
            id: BookmarkID(),
            videoPath: normalizedURL.path,
            timeSeconds: max(timeSeconds, 0),
            createdAt: Date(),
            updatedAt: Date(),
            tags: Self.sanitizedTags(tags),
            fileCreatedAt: Self.fileCreationDate(for: normalizedURL)
        )
        cache.append(bookmark)
        preparedBookmarks[bookmark.id] = makePreparedBookmark(for: bookmark)
        schedulePersist()
        notifyDidChange()
        return bookmark
    }

    @discardableResult
    func addImportedBookmarks(videoURLs: [URL]) -> [Bookmark] {
        loadCacheIfNeeded()
        let importedAt = Date()
        let bookmarks = videoURLs.map { videoURL in
            let normalizedURL = videoURL.standardizedFileURL
            return Bookmark(
                id: BookmarkID(),
                videoPath: normalizedURL.path,
                timeSeconds: 0,
                createdAt: importedAt,
                updatedAt: importedAt,
                tags: Self.sanitizedTags(["imported"]),
                isImported: true,
                importedAt: importedAt,
                fileCreatedAt: Self.fileCreationDate(for: normalizedURL)
            )
        }
        guard !bookmarks.isEmpty else {
            return []
        }
        cache.append(contentsOf: bookmarks)
        for bookmark in bookmarks {
            preparedBookmarks[bookmark.id] = makePreparedBookmark(for: bookmark)
        }
        schedulePersist()
        notifyDidChange()
        return bookmarks
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
        preparedBookmarks[id] = makePreparedBookmark(for: cache[index])
        schedulePersist()
        notifyDidChange()
    }

    func updateProtection(for id: BookmarkID, isProtected: Bool) {
        loadCacheIfNeeded()
        guard let index = cache.firstIndex(where: { $0.id == id }) else {
            return
        }
        guard cache[index].isProtected != isProtected else {
            return
        }
        cache[index] = cache[index].withUpdatedProtection(isProtected)
        schedulePersist()
        notifyDidChange()
    }

    func removeBookmark(id: BookmarkID) {
        removeBookmarks(ids: Set([id]))
    }

    func removeBookmarks(ids: Set<BookmarkID>) {
        loadCacheIfNeeded()
        guard !ids.isEmpty else {
            return
        }
        let originalCount = cache.count
        cache.removeAll { ids.contains($0.id) }
        guard cache.count != originalCount else {
            return
        }
        for id in ids {
            preparedBookmarks.removeValue(forKey: id)
        }
        schedulePersist()
        notifyDidChange()
    }

    func flushPendingWrites() {
        guard let persistWorkItem else { return }
        persistWorkItem.cancel()
        let snapshot = cache
        persistenceQueue.sync {
            persistSnapshot(snapshot)
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

    func hasProtectedBookmarks() -> Bool {
        loadCacheIfNeeded()
        return cache.contains(where: \.isProtected)
    }

    func hasProtectedBookmarks(for videoURL: URL) -> Bool {
        loadCacheIfNeeded()
        let normalizedVideoPath = videoURL.standardizedFileURL.path
        return cache.contains { bookmark in
            bookmark.isProtected && bookmark.videoPath == normalizedVideoPath
        }
    }

    private func loadCacheIfNeeded() {
        guard !hasLoadedCache else { return }
        hasLoadedCache = true
        guard
            let data = defaults.data(forKey: Self.defaultsKey),
            let decoded = try? JSONDecoder().decode([Bookmark].self, from: data)
        else {
            cache = []
            preparedBookmarks = [:]
            return
        }
        cache = decoded
        rebuildPreparedBookmarks()
    }

    private func filteredBookmarks(_ bookmarks: [Bookmark], visibility: BookmarkVisibility) -> [Bookmark] {
        switch visibility {
        case .publicOnly:
            return bookmarks.filter { !$0.isProtected }
        case .all:
            return bookmarks
        case .protectedOnly:
            return bookmarks.filter(\.isProtected)
        }
    }

    private func schedulePersist() {
        persistWorkItem?.cancel()
        let snapshot = cache
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.persistWorkItem = nil
            self.persistenceQueue.async { [weak self] in
                self?.persistSnapshot(snapshot)
            }
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

    private func rebuildPreparedBookmarks() {
        preparedBookmarks = cache.reduce(into: [:]) { result, bookmark in
            result[bookmark.id] = makePreparedBookmark(for: bookmark)
        }
    }

    private func makePreparedBookmark(for bookmark: Bookmark) -> PreparedBookmark {
        let displayName = (bookmark.videoPath as NSString).lastPathComponent
        let searchableTokens = normalizedSearchTokens(
            from: ([displayName, Self.formattedTimestamp(bookmark.timeSeconds)] + bookmark.tags)
                .joined(separator: " ")
        )
        return PreparedBookmark(searchableTokens: searchableTokens)
    }

    private func matchesVisibility(_ bookmark: Bookmark, visibility: BookmarkVisibility) -> Bool {
        switch visibility {
        case .publicOnly:
            return !bookmark.isProtected
        case .all:
            return true
        case .protectedOnly:
            return bookmark.isProtected
        }
    }

    private func matchesScope(
        _ bookmark: Bookmark,
        scope: BookmarkListScope,
        normalizedVideoPath: String?
    ) -> Bool {
        switch scope {
        case .currentVideo:
            guard let normalizedVideoPath else { return false }
            return bookmark.videoPath == normalizedVideoPath
        case .allVideos:
            return true
        case .imported:
            return bookmark.isImported
        case .protected:
            return bookmark.isProtected
        }
    }

    private func matchesQuery(_ bookmark: Bookmark, queryTokens: [String]) -> Bool {
        guard !queryTokens.isEmpty else {
            return true
        }
        let preparedBookmark: PreparedBookmark
        if let cached = preparedBookmarks[bookmark.id] {
            preparedBookmark = cached
        } else {
            let prepared = makePreparedBookmark(for: bookmark)
            preparedBookmarks[bookmark.id] = prepared
            preparedBookmark = prepared
        }
        return queryTokens.allSatisfy { token in
            preparedBookmark.searchableTokens.contains(where: { $0.contains(token) })
        }
    }

    private func persistSnapshot(_ snapshot: [Bookmark]) {
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    private static func fileCreationDate(for url: URL) -> Date? {
        do {
            let values = try url.resourceValues(forKeys: [.creationDateKey])
            return values.creationDate
        } catch {
            return nil
        }
    }

    private func sortComparator(for sort: BookmarkSort, scope: BookmarkListScope) -> (Bookmark, Bookmark) -> Bool {
        switch sort {
        case .automatic:
            return automaticSortComparator(for: scope)
        case let .importedAt(ascending):
            return dateComparator(\.importedAt, ascending: ascending)
        case let .fileCreatedAt(ascending):
            return dateComparator(\.fileCreatedAt, ascending: ascending)
        }
    }

    private func automaticSortComparator(for scope: BookmarkListScope) -> (Bookmark, Bookmark) -> Bool {
        switch scope {
        case .imported:
            return dateComparator(\.importedAt, ascending: false)
        case .currentVideo, .allVideos, .protected:
            return bookmarkSortComparator
        }
    }

    private func dateComparator(
        _ keyPath: KeyPath<Bookmark, Date?>,
        ascending: Bool
    ) -> (Bookmark, Bookmark) -> Bool {
        { [self] lhs, rhs in
            let lhsDate = lhs[keyPath: keyPath]
            let rhsDate = rhs[keyPath: keyPath]

            switch (lhsDate, rhsDate) {
            case let (lhsDate?, rhsDate?):
                if lhsDate != rhsDate {
                    return ascending ? lhsDate < rhsDate : lhsDate > rhsDate
                }
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            case (nil, nil):
                break
            }

            return self.bookmarkSortComparator(lhs: lhs, rhs: rhs)
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
