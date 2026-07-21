import AVFoundation
import CoreLocation
import Foundation

enum MediaLocationExtractor {
    struct Coordinates: Equatable {
        let latitude: Double
        let longitude: Double
    }

    static func extractCoordinates(from videoURL: URL) async -> Coordinates? {
        let asset = AVURLAsset(url: videoURL)
        do {
            let metadata = try await asset.load(.metadata)
            for item in metadata {
                if let coordinates = await coordinates(from: item) {
                    return coordinates
                }
            }

            let commonMetadata = try await asset.load(.commonMetadata)
            for item in commonMetadata {
                if let coordinates = await coordinates(from: item) {
                    return coordinates
                }
            }
        } catch {
            return nil
        }
        return nil
    }

    /// Parses ISO 6709 location strings such as `+59.3293+018.0686/` or `+39.9410-075.2040+007.371/`.
    static func parseISO6709(_ rawValue: String) -> Coordinates? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let pattern = #"^([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)(?:[+-]\d+(?:\.\d+)?)?/?$"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
            match.numberOfRanges >= 3,
            let latitudeRange = Range(match.range(at: 1), in: trimmed),
            let longitudeRange = Range(match.range(at: 2), in: trimmed),
            let latitude = Double(trimmed[latitudeRange]),
            let longitude = Double(trimmed[longitudeRange]),
            (-90...90).contains(latitude),
            (-180...180).contains(longitude)
        else {
            return nil
        }

        return Coordinates(latitude: latitude, longitude: longitude)
    }

    private static func coordinates(from item: AVMetadataItem) async -> Coordinates? {
        if let identifier = item.identifier {
            let isLocationIdentifier =
                identifier == .quickTimeMetadataLocationISO6709
                || identifier == .commonIdentifierLocation
            guard isLocationIdentifier else {
                return nil
            }
        }

        if let stringValue = try? await item.load(.stringValue),
           let coordinates = parseISO6709(stringValue) {
            return coordinates
        }
        return nil
    }
}
