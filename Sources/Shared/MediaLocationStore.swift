import Foundation

enum MediaLocationStatus: String, Codable, Equatable {
    case pending
    case resolving
    case resolved
    case unavailable
    case failed
}

struct MediaLocationRecord: Codable, Equatable {
    let videoPath: String
    var latitude: Double?
    var longitude: Double?
    var placeName: String?
    var status: MediaLocationStatus
    var updatedAt: Date

    var hasCoordinates: Bool {
        latitude != nil && longitude != nil
    }

    var normalizedVideoPath: String {
        URL(fileURLWithPath: videoPath).quickPreviewNormalizedPath
    }
}

extension Notification.Name {
    static let mediaLocationStoreDidChange = Notification.Name("MediaLocationStoreDidChange")
}

final class MediaLocationStore {
    private static let defaultsKey = "mediaLocations"

    private let persistDebounceInterval: TimeInterval
    private let defaults: UserDefaults
    private let persistenceQueue = DispatchQueue(
        label: "quickpreview.media-location-store.persistence",
        qos: .utility
    )
    private var cacheByPath: [String: MediaLocationRecord] = [:]
    private var hasLoadedCache = false
    private var persistWorkItem: DispatchWorkItem?

    init(
        defaults: UserDefaults = .standard,
        persistDebounceInterval: TimeInterval = 0.2
    ) {
        self.defaults = defaults
        self.persistDebounceInterval = persistDebounceInterval
    }

    func location(for videoURL: URL) -> MediaLocationRecord? {
        location(forPath: videoURL.quickPreviewNormalizedPath)
    }

    func location(forPath path: String) -> MediaLocationRecord? {
        loadCacheIfNeeded()
        let normalizedPath = URL(fileURLWithPath: path).quickPreviewNormalizedPath
        return cacheByPath[normalizedPath]
    }

    func allLocations() -> [MediaLocationRecord] {
        loadCacheIfNeeded()
        return Array(cacheByPath.values)
    }

    /// Place name for table display: empty while pending/resolving, em dash when unavailable/failed/missing.
    func displayPlaceName(forPath path: String) -> String {
        guard let record = location(forPath: path) else {
            return "—"
        }
        if let placeName = record.placeName, !placeName.isEmpty {
            return placeName
        }
        switch record.status {
        case .pending, .resolving:
            return ""
        case .resolved, .unavailable, .failed:
            return "—"
        }
    }

    /// Sort key for location column: real place names only; blank/pending/unavailable sort last.
    func locationSortKey(forPath path: String) -> String {
        let display = displayPlaceName(forPath: path)
        if display.isEmpty || display == "—" {
            return ""
        }
        return display
    }

    func sortedByPlaceName(_ bookmarks: [Bookmark], ascending: Bool) -> [Bookmark] {
        bookmarks.sorted { lhs, rhs in
            let lhsKey = locationSortKey(forPath: lhs.normalizedVideoPath)
            let rhsKey = locationSortKey(forPath: rhs.normalizedVideoPath)

            switch (lhsKey.isEmpty, rhsKey.isEmpty) {
            case (true, false):
                return false
            case (false, true):
                return true
            case (true, true):
                break
            case (false, false):
                let comparison = lhsKey.localizedStandardCompare(rhsKey)
                if comparison != .orderedSame {
                    return ascending
                        ? comparison == .orderedAscending
                        : comparison == .orderedDescending
                }
            }

            if lhs.normalizedVideoPath != rhs.normalizedVideoPath {
                return lhs.normalizedVideoPath.localizedCaseInsensitiveCompare(rhs.normalizedVideoPath)
                    == .orderedAscending
            }
            if abs(lhs.timeSeconds - rhs.timeSeconds) > 0.0001 {
                return lhs.timeSeconds < rhs.timeSeconds
            }
            return lhs.createdAt < rhs.createdAt
        }
    }

    func pathsNeedingResolution(from paths: [String]) -> [String] {
        loadCacheIfNeeded()
        var result: [String] = []
        result.reserveCapacity(paths.count)
        var seen = Set<String>()
        for path in paths {
            let normalizedPath = URL(fileURLWithPath: path).quickPreviewNormalizedPath
            guard seen.insert(normalizedPath).inserted else {
                continue
            }
            guard let record = cacheByPath[normalizedPath] else {
                result.append(normalizedPath)
                continue
            }
            switch record.status {
            case .pending, .failed:
                result.append(normalizedPath)
            case .resolving, .resolved, .unavailable:
                continue
            }
        }
        return result
    }

    @discardableResult
    func upsertCoordinates(
        for videoURL: URL,
        latitude: Double,
        longitude: Double
    ) -> MediaLocationRecord {
        loadCacheIfNeeded()
        let normalizedPath = videoURL.quickPreviewNormalizedPath
        let now = Date()
        var record = cacheByPath[normalizedPath] ?? MediaLocationRecord(
            videoPath: normalizedPath,
            latitude: nil,
            longitude: nil,
            placeName: nil,
            status: .pending,
            updatedAt: now
        )
        record.latitude = latitude
        record.longitude = longitude
        record.status = .pending
        record.updatedAt = now
        cacheByPath[normalizedPath] = record
        schedulePersist()
        notifyDidChange()
        return record
    }

    @discardableResult
    func markResolving(for videoURL: URL) -> MediaLocationRecord? {
        loadCacheIfNeeded()
        let normalizedPath = videoURL.quickPreviewNormalizedPath
        guard var record = cacheByPath[normalizedPath] else {
            return nil
        }
        record.status = .resolving
        record.updatedAt = Date()
        cacheByPath[normalizedPath] = record
        schedulePersist()
        notifyDidChange()
        return record
    }

    @discardableResult
    func setPlaceName(for videoURL: URL, placeName: String) -> MediaLocationRecord? {
        loadCacheIfNeeded()
        let normalizedPath = videoURL.quickPreviewNormalizedPath
        guard var record = cacheByPath[normalizedPath] else {
            return nil
        }
        let trimmed = placeName.trimmingCharacters(in: .whitespacesAndNewlines)
        record.placeName = trimmed.isEmpty ? nil : trimmed
        record.status = .resolved
        record.updatedAt = Date()
        cacheByPath[normalizedPath] = record
        schedulePersist()
        notifyDidChange()
        return record
    }

    @discardableResult
    func markUnavailable(for videoURL: URL) -> MediaLocationRecord {
        loadCacheIfNeeded()
        let normalizedPath = videoURL.quickPreviewNormalizedPath
        let now = Date()
        let record = MediaLocationRecord(
            videoPath: normalizedPath,
            latitude: nil,
            longitude: nil,
            placeName: nil,
            status: .unavailable,
            updatedAt: now
        )
        cacheByPath[normalizedPath] = record
        schedulePersist()
        notifyDidChange()
        return record
    }

    @discardableResult
    func markFailed(for videoURL: URL) -> MediaLocationRecord? {
        loadCacheIfNeeded()
        let normalizedPath = videoURL.quickPreviewNormalizedPath
        guard var record = cacheByPath[normalizedPath] else {
            return nil
        }
        record.status = .failed
        record.updatedAt = Date()
        cacheByPath[normalizedPath] = record
        schedulePersist()
        notifyDidChange()
        return record
    }

    func flushPendingWrites() {
        guard let persistWorkItem else { return }
        persistWorkItem.cancel()
        let snapshot = Array(cacheByPath.values)
        persistenceQueue.sync {
            persistSnapshot(snapshot)
        }
        self.persistWorkItem = nil
    }

    private func loadCacheIfNeeded() {
        guard !hasLoadedCache else { return }
        hasLoadedCache = true
        guard let data = defaults.data(forKey: Self.defaultsKey) else {
            return
        }
        guard let records = try? JSONDecoder().decode([MediaLocationRecord].self, from: data) else {
            return
        }
        cacheByPath = Dictionary(uniqueKeysWithValues: records.map { record in
            (record.normalizedVideoPath, record)
        })
    }

    private func schedulePersist() {
        persistWorkItem?.cancel()
        let snapshot = Array(cacheByPath.values)
        let workItem = DispatchWorkItem { [weak self] in
            self?.persistSnapshot(snapshot)
        }
        persistWorkItem = workItem
        if persistDebounceInterval <= 0 {
            persistenceQueue.sync(execute: workItem)
            persistWorkItem = nil
        } else {
            persistenceQueue.asyncAfter(deadline: .now() + persistDebounceInterval, execute: workItem)
        }
    }

    private func persistSnapshot(_ snapshot: [MediaLocationRecord]) {
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    private func notifyDidChange() {
        NotificationCenter.default.post(name: .mediaLocationStoreDidChange, object: self)
    }
}
