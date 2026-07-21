import Foundation

/// Persisted in/out range written by the main player (`clipSelectionByPath`).
struct PersistedClipSelection: Codable, Equatable {
    let start: PlaybackSeconds
    let end: PlaybackSeconds
}

enum ClipSelectionStore {
    static let defaultsKey = "clipSelectionByPath"

    static func loadAll(from defaults: UserDefaults = .standard) -> [String: PersistedClipSelection] {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: PersistedClipSelection].self, from: data) else {
            return [:]
        }
        return decoded
    }

    static func selection(forPath path: String, defaults: UserDefaults = .standard) -> PersistedClipSelection? {
        let all = loadAll(from: defaults)
        if let exact = all[path] {
            return exact
        }
        let normalized = URL(fileURLWithPath: path).quickPreviewNormalizedPath
        if let match = all[normalized] {
            return match
        }
        // Player historically keys by `url.path` (not always normalized).
        for (storedPath, selection) in all {
            if URL(fileURLWithPath: storedPath).quickPreviewNormalizedPath == normalized {
                return selection
            }
        }
        return nil
    }
}
