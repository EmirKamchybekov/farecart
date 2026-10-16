import Foundation

/// A resolved address or place name.
public struct GeocodeResult: Sendable, Hashable, Identifiable {
    public var id: String { "\(label)|\(point.latitude)|\(point.longitude)" }
    public var label: String
    public var point: GeoPoint

    public init(label: String, point: GeoPoint) {
        self.label = label
        self.point = point
    }
}

/// Anything that can turn free text into coordinates.
public protocol Geocoding: Sendable {
    func geocode(_ query: String) async throws -> [GeocodeResult]
}

public enum GeocodingError: Error, Sendable, Equatable {
    case emptyQuery
    case noResults
}

/// Tries `primary` first and falls back to `fallback` when the primary is missing, throws,
/// or returns nothing. The app wires Farecart's API as primary and Apple's geocoder as fallback.
public struct FallbackGeocoder: Geocoding {
    public let primary: (any Geocoding)?
    public let fallback: any Geocoding

    public init(primary: (any Geocoding)?, fallback: any Geocoding) {
        self.primary = primary
        self.fallback = fallback
    }

    public func geocode(_ query: String) async throws -> [GeocodeResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GeocodingError.emptyQuery }
        if let primary {
            if let results = try? await primary.geocode(trimmed), !results.isEmpty {
                return results
            }
        }
        let results = try await fallback.geocode(trimmed)
        guard !results.isEmpty else { throw GeocodingError.noResults }
        return results
    }
}
