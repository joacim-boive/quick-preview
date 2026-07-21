import CoreLocation
import Foundation

protocol MediaLocationGeocoding: AnyObject {
    func reverseGeocode(latitude: Double, longitude: Double) async throws -> String?
}

final class CLGeocoderMediaLocationGeocoder: MediaLocationGeocoding {
    private let geocoder = CLGeocoder()

    func reverseGeocode(latitude: Double, longitude: Double) async throws -> String? {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        let placemarks = try await geocoder.reverseGeocodeLocation(location)
        guard let placemark = placemarks.first else {
            return nil
        }
        return MediaLocationPlaceName.preferredName(from: placemark)
    }
}

enum MediaLocationPlaceName {
    static func preferredName(
        locality: String?,
        subAdministrativeArea: String?,
        name: String?,
        administrativeArea: String?
    ) -> String? {
        let candidates = [locality, subAdministrativeArea, name, administrativeArea]
        for candidate in candidates {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    static func preferredName(from placemark: CLPlacemark) -> String? {
        preferredName(
            locality: placemark.locality,
            subAdministrativeArea: placemark.subAdministrativeArea,
            name: placemark.name,
            administrativeArea: placemark.administrativeArea
        )
    }
}

final class MediaLocationResolver {
    private let store: MediaLocationStore
    private let mediaAccessStore: SecurityScopedMediaAccessStore
    private let geocoder: MediaLocationGeocoding
    private let throttleInterval: TimeInterval
    private let queue = DispatchQueue(label: "quickpreview.media-location-resolver", qos: .utility)
    private var pendingPaths: [String] = []
    private var pendingPathSet = Set<String>()
    private var isProcessing = false

    init(
        store: MediaLocationStore,
        mediaAccessStore: SecurityScopedMediaAccessStore,
        geocoder: MediaLocationGeocoding = CLGeocoderMediaLocationGeocoder(),
        throttleInterval: TimeInterval = 0.35
    ) {
        self.store = store
        self.mediaAccessStore = mediaAccessStore
        self.geocoder = geocoder
        self.throttleInterval = throttleInterval
    }

    func resolve(url: URL) {
        resolve(urls: [url])
    }

    func resolve(urls: [URL]) {
        let paths = urls
            .filter(\.isFileURL)
            .map(\.quickPreviewNormalizedPath)
        resolve(paths: paths)
    }

    func resolve(paths: [String]) {
        let needingResolution = store.pathsNeedingResolution(from: paths)
        guard !needingResolution.isEmpty else {
            return
        }

        queue.async { [weak self] in
            guard let self else { return }
            for path in needingResolution where !self.pendingPathSet.contains(path) {
                self.pendingPathSet.insert(path)
                self.pendingPaths.append(path)
            }
            self.processNextIfNeeded()
        }
    }

    private func processNextIfNeeded() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isProcessing, let path = pendingPaths.first else {
            return
        }
        pendingPaths.removeFirst()
        pendingPathSet.remove(path)
        isProcessing = true

        Task { [weak self] in
            guard let self else { return }
            await self.resolvePath(path)
            self.queue.async { [weak self] in
                guard let self else { return }
                self.isProcessing = false
                if self.throttleInterval > 0 {
                    self.queue.asyncAfter(deadline: .now() + self.throttleInterval) { [weak self] in
                        self?.processNextIfNeeded()
                    }
                } else {
                    self.processNextIfNeeded()
                }
            }
        }
    }

    private func resolvePath(_ path: String) async {
        let fileURL = URL(fileURLWithPath: path)
        guard let accessibleURL = mediaAccessStore.beginAccess(for: fileURL) else {
            // Still attempt direct read for non-sandboxed / already-accessible paths.
            await extractAndGeocode(fileURL)
            return
        }
        defer {
            mediaAccessStore.endAccess(for: accessibleURL)
        }
        await extractAndGeocode(accessibleURL)
    }

    private func extractAndGeocode(_ videoURL: URL) async {
        let normalizedURL = videoURL.quickPreviewNormalizedFileURL
        if let existing = store.location(for: normalizedURL) {
            switch existing.status {
            case .resolved, .unavailable, .resolving:
                return
            case .pending, .failed:
                break
            }
        }

        guard let coordinates = await MediaLocationExtractor.extractCoordinates(from: normalizedURL) else {
            _ = store.markUnavailable(for: normalizedURL)
            return
        }

        _ = store.upsertCoordinates(
            for: normalizedURL,
            latitude: coordinates.latitude,
            longitude: coordinates.longitude
        )
        _ = store.markResolving(for: normalizedURL)

        do {
            let placeName = try await geocoder.reverseGeocode(
                latitude: coordinates.latitude,
                longitude: coordinates.longitude
            )
            if let placeName, !placeName.isEmpty {
                _ = store.setPlaceName(for: normalizedURL, placeName: placeName)
            } else {
                _ = store.setPlaceName(for: normalizedURL, placeName: "")
            }
        } catch {
            _ = store.markFailed(for: normalizedURL)
        }
    }
}
