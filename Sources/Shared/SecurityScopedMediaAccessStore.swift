import Foundation

extension URL {
    /// Stable file path for media identity across `/var` ↔ `/private/var` symlink aliases.
    var quickPreviewNormalizedFileURL: URL {
        resolvingSymlinksInPath().standardizedFileURL
    }

    var quickPreviewNormalizedPath: String {
        quickPreviewNormalizedFileURL.path
    }
}

/// Persists and resolves security-scoped bookmarks so sandboxed builds can re-open
/// user-selected / imported media after the open panel or drag session ends.
final class SecurityScopedMediaAccessStore {
    private static let defaultsKey = "securityScopedMediaBookmarks"

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var bookmarkDataByPath: [String: Data] = [:]
    private var activeURLsByPath: [String: URL] = [:]
    private var activeAccessCountsByPath: [String: Int] = [:]
    private var didStartScopedAccessByPath: [String: Bool] = [:]
    private var didLoad = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Creates and stores a security-scoped bookmark for a user-selected or dropped file URL.
    @discardableResult
    func register(_ url: URL) -> Bool {
        guard url.isFileURL else {
            return false
        }
        loadIfNeeded()

        let normalizedPath = url.quickPreviewNormalizedPath
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard let bookmarkData = makeBookmarkData(from: url) else {
            return false
        }

        lock.lock()
        bookmarkDataByPath[normalizedPath] = bookmarkData
        let snapshot = bookmarkDataByPath
        lock.unlock()
        persist(snapshot)
        return true
    }

    func register(urls: [URL]) {
        for url in urls {
            _ = register(url)
        }
    }

    /// Begins access for `url`. Always pair with `endAccess(for:)` using the returned URL.
    func beginAccess(for url: URL) -> URL? {
        guard url.isFileURL else {
            return nil
        }
        loadIfNeeded()

        let normalizedPath = url.quickPreviewNormalizedPath

        lock.lock()
        if let activeURL = activeURLsByPath[normalizedPath] {
            activeAccessCountsByPath[normalizedPath, default: 0] += 1
            lock.unlock()
            return activeURL
        }
        let storedBookmarkData = bookmarkDataByPath[normalizedPath]
        lock.unlock()

        if let storedBookmarkData,
           let resolvedURL = resolveAndStartAccess(bookmarkData: storedBookmarkData, expectedPath: normalizedPath) {
            return retainActiveURL(resolvedURL, path: normalizedPath, didStartScopedAccess: true)
        }

        // Live panel / drop URLs can still mint a bookmark on first use.
        if register(url) {
            lock.lock()
            let refreshedBookmarkData = bookmarkDataByPath[normalizedPath]
            lock.unlock()
            if let refreshedBookmarkData,
               let resolvedURL = resolveAndStartAccess(
                bookmarkData: refreshedBookmarkData,
                expectedPath: normalizedPath
               ) {
                return retainActiveURL(resolvedURL, path: normalizedPath, didStartScopedAccess: true)
            }
        }

        // Non-sandboxed builds (and still-readable paths) fall back to the plain file URL.
        let fallbackURL = url.quickPreviewNormalizedFileURL
        guard FileManager.default.isReadableFile(atPath: fallbackURL.path) else {
            return nil
        }
        return retainActiveURL(fallbackURL, path: normalizedPath, didStartScopedAccess: false)
    }

    func endAccess(for url: URL) {
        let normalizedPath = url.quickPreviewNormalizedPath
        lock.lock()
        defer { lock.unlock() }

        guard let count = activeAccessCountsByPath[normalizedPath] else {
            return
        }
        if count <= 1 {
            activeAccessCountsByPath.removeValue(forKey: normalizedPath)
            let didStartScopedAccess = didStartScopedAccessByPath.removeValue(forKey: normalizedPath) ?? false
            if let activeURL = activeURLsByPath.removeValue(forKey: normalizedPath), didStartScopedAccess {
                activeURL.stopAccessingSecurityScopedResource()
            }
            return
        }
        activeAccessCountsByPath[normalizedPath] = count - 1
    }

    func hasPersistedAccess(for url: URL) -> Bool {
        loadIfNeeded()
        let path = url.quickPreviewNormalizedPath
        lock.lock()
        defer { lock.unlock() }
        return bookmarkDataByPath[path] != nil
    }

    private func retainActiveURL(_ url: URL, path: String, didStartScopedAccess: Bool) -> URL {
        lock.lock()
        if let existingURL = activeURLsByPath[path] {
            activeAccessCountsByPath[path, default: 0] += 1
            lock.unlock()
            if didStartScopedAccess {
                url.stopAccessingSecurityScopedResource()
            }
            return existingURL
        }
        activeURLsByPath[path] = url
        activeAccessCountsByPath[path] = 1
        didStartScopedAccessByPath[path] = didStartScopedAccess
        lock.unlock()
        return url
    }

    private func resolveAndStartAccess(bookmarkData: Data, expectedPath: String) -> URL? {
        var isStale = false
        guard let resolvedURL = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }

        guard resolvedURL.startAccessingSecurityScopedResource() else {
            return nil
        }

        if isStale, let refreshedData = makeBookmarkData(from: resolvedURL) {
            let refreshedPath = resolvedURL.quickPreviewNormalizedPath
            lock.lock()
            bookmarkDataByPath[expectedPath] = refreshedData
            if refreshedPath != expectedPath {
                bookmarkDataByPath[refreshedPath] = refreshedData
            }
            let snapshot = bookmarkDataByPath
            lock.unlock()
            persist(snapshot)
        }

        return resolvedURL
    }

    private func makeBookmarkData(from url: URL) -> Data? {
        let readOnlyOptions: URL.BookmarkCreationOptions = [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
        if let data = try? url.bookmarkData(
            options: readOnlyOptions,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            return data
        }
        return try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private func loadIfNeeded() {
        lock.lock()
        if didLoad {
            lock.unlock()
            return
        }
        didLoad = true
        let stored = defaults.dictionary(forKey: Self.defaultsKey) as? [String: Data] ?? [:]
        bookmarkDataByPath = stored
        lock.unlock()
    }

    private func persist(_ snapshot: [String: Data]) {
        defaults.set(snapshot, forKey: Self.defaultsKey)
    }
}
