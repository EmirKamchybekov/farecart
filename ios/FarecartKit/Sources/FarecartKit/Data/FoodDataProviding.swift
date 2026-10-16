import Foundation

/// Everything the UI needs to read. Implemented by `SupabaseClient` (live) and `MockDataProvider` (previews).
public protocol FoodDataProviding: Sendable {
    func nearbyPlaces(around point: GeoPoint, filter: PlaceFilter, radius: SearchRadius, limit: Int) async throws -> [Place]
    func fares() async throws -> [Fare]
    func programs() async throws -> [Program]
}

extension FoodDataProviding {
    public func nearbyPlaces(around point: GeoPoint, filter: PlaceFilter = .all, radius: SearchRadius = .fiveMiles) async throws -> [Place] {
        try await nearbyPlaces(around: point, filter: filter, radius: radius, limit: 25)
    }
}
