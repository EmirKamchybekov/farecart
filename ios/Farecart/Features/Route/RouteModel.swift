import Foundation
import MapKit
import Observation
import SwiftUI
import FarecartKit

/// Everything RouteView needs to ask for: where the user is searching from and where they want to go.
struct RouteRequest: Hashable, Sendable {
    var origin: GeoPoint
    var originLabel: String
    var place: Place
}

/// Loads up to three Transitous itineraries for one trip and tracks which one is shown.
@MainActor
@Observable
final class RouteModel {
    enum Failure: Equatable {
        case noRoutes
        case unavailable
    }

    let request: RouteRequest
    private(set) var itineraries: [TransitItinerary] = []
    private(set) var isLoading = false
    private(set) var failure: Failure?
    var selectedID: String?

    private let router: any TransitRouting

    init(request: RouteRequest, router: any TransitRouting) {
        self.request = request
        self.router = router
    }

    var selected: TransitItinerary? {
        itineraries.first { $0.id == selectedID } ?? itineraries.first
    }

    /// "Leave now": the router picks the next departures.
    func load() async {
        guard !isLoading else { return }
        isLoading = true
        failure = nil
        defer { isLoading = false }
        do {
            let results = try await router.plan(from: request.origin, to: request.place.coordinate, departAt: nil, maxItineraries: 3)
            itineraries = Array(results.prefix(3))
            selectedID = itineraries.first?.id
            if itineraries.isEmpty { failure = .noRoutes }
        } catch {
            itineraries = []
            failure = .unavailable
        }
    }

    func select(_ itinerary: TransitItinerary) {
        selectedID = itinerary.id
    }

    /// Camera that shows the whole route with a little breathing room.
    static func cameraPosition(for itinerary: TransitItinerary) -> MapCameraPosition {
        let points = itinerary.allCoordinates
        guard let first = points.first else {
            return .region(MKCoordinateRegion(center: GeoPoint.westSideChicago.clCoordinate, latitudinalMeters: 3000, longitudinalMeters: 3000))
        }
        var minLat = first.latitude, maxLat = first.latitude
        var minLng = first.longitude, maxLng = first.longitude
        for point in points {
            minLat = min(minLat, point.latitude); maxLat = max(maxLat, point.latitude)
            minLng = min(minLng, point.longitude); maxLng = max(maxLng, point.longitude)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLng + maxLng) / 2)
        let span = MKCoordinateSpan(
            latitudeDelta: max(0.008, (maxLat - minLat) * 1.6),
            longitudeDelta: max(0.008, (maxLng - minLng) * 1.3)
        )
        return .region(MKCoordinateRegion(center: center, span: span))
    }
}

extension TransitLeg {
    /// Route color from GTFS, else system blue. Walking legs are gray.
    var displayColor: Color {
        switch mode {
        case .walk: Color(.systemGray)
        default: routeColorHex.flatMap(Color.init(hex:)) ?? .blue
        }
    }

    var symbolName: String {
        switch mode {
        case .walk: "figure.walk"
        case .bus: "bus.fill"
        case .train: "tram.fill"
        case .other: "arrow.triangle.swap"
        }
    }
}

extension Color {
    /// `"414145"` or `"#414145"` → Color. Returns `nil` for anything that is not six hex digits.
    init?(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

/// Trips are in Chicago, so times are shown in Chicago time no matter where the phone thinks it is.
enum ChicagoTime {
    static let zone = TimeZone(identifier: "America/Chicago") ?? .current

    static func short(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: zone))
    }
}
