import Foundation

/// A latitude/longitude pair. Kept framework-free so the Kit never needs CoreLocation.
public struct GeoPoint: Sendable, Hashable, Codable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Garfield Park Conservatory area, a sensible default for West Side Chicago.
    public static let westSideChicago = GeoPoint(latitude: 41.8807, longitude: -87.7262)

    /// Great-circle distance in meters (haversine).
    public func distanceMeters(to other: GeoPoint) -> Double {
        let earthRadius = 6_371_000.0
        let dLat = (other.latitude - latitude).degreesToRadians
        let dLon = (other.longitude - longitude).degreesToRadians
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(latitude.degreesToRadians) * cos(other.latitude.degreesToRadians)
            * sin(dLon / 2) * sin(dLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return earthRadius * c
    }
}

extension Double {
    var degreesToRadians: Double { self * .pi / 180 }
}

/// Search radius choices. The default matches the product spec (5 miles); the wider one is
/// offered when nothing is found nearby.
public enum SearchRadius: Int, Sendable, Hashable, CaseIterable {
    case fiveMiles = 5
    case tenMiles = 10
    case twentyMiles = 20

    public var miles: Int { rawValue }
    public var meters: Int { Int((Double(rawValue) * 1609.344).rounded()) }

    /// The next wider radius, or `nil` when already at the widest.
    public var wider: SearchRadius? {
        let all = SearchRadius.allCases
        guard let index = all.firstIndex(of: self), index + 1 < all.count else { return nil }
        return all[index + 1]
    }
}
