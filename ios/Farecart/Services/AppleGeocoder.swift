import MapKit
import FarecartKit

/// Address → coordinates using MapKit, biased to Chicago. Used when API_BASE_URL is empty or the
/// Farecart API is unreachable, so the app works standalone.
struct AppleGeocoder: Geocoding {
    static let chicagoRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 41.8781, longitude: -87.6298),
        latitudinalMeters: 60_000,
        longitudinalMeters: 60_000
    )

    func geocode(_ query: String) async throws -> [GeocodeResult] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = Self.chicagoRegion
        request.resultTypes = [.address, .pointOfInterest]
        let response = try await MKLocalSearch(request: request).start()
        return response.mapItems.prefix(8).map { item in
            let coordinate = item.location.coordinate
            let label = [item.name, item.address?.shortAddress]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            return GeocodeResult(
                label: label.isEmpty ? query : label,
                point: GeoPoint(latitude: coordinate.latitude, longitude: coordinate.longitude)
            )
        }
    }
}
