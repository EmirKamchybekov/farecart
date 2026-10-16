import Foundation
import MapKit
import FarecartKit

/// Finds Apple's own record for one of our places so the Info tab can show the system place card
/// (photos, hours, reviews). Looks the name up with `MKLocalSearch` in a 300 m region around our
/// coordinate and keeps the closest point of interest within 150 m. Results (including "nothing
/// matched") are cached per place id for the life of the app, so switching tabs never re-queries.
@MainActor
final class ApplePlaceLookup {
    /// Half-width of the search region around our coordinate.
    static let searchRadiusMeters: CLLocationDistance = 300
    /// A result further than this from our coordinate is a different business.
    static let maxMatchDistanceMeters: CLLocationDistance = 150

    private var cache: [UUID: MKMapItem?] = [:]

    /// Apple's map item for the place, or `nil` when nothing nearby matches (or the lookup failed).
    func mapItem(for place: Place) async -> MKMapItem? {
        if let cached = cache[place.id] { return cached }
        let item = await Self.search(for: place)
        cache[place.id] = .some(item)
        return item
    }

    private static func search(for place: Place) async -> MKMapItem? {
        let center = CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = place.name
        request.region = MKCoordinateRegion(
            center: center,
            latitudinalMeters: searchRadiusMeters * 2,
            longitudinalMeters: searchRadiusMeters * 2
        )
        request.resultTypes = .pointOfInterest
        guard let response = try? await MKLocalSearch(request: request).start() else { return nil }
        let origin = CLLocation(latitude: place.latitude, longitude: place.longitude)
        let candidates = response.mapItems.map { item in
            (item: item, distance: item.location.distance(from: origin))
        }
        guard let best = candidates.min(by: { $0.distance < $1.distance }),
              best.distance <= maxMatchDistanceMeters else { return nil }
        return best.item
    }
}
