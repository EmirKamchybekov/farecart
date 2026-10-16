import Foundation
import SwiftUI
import FarecartKit

/// Everything the views need, built once at launch. Previews use `.preview`.
@MainActor
@Observable
final class AppEnvironment {
    let config: AppConfig?
    let data: any FoodDataProviding
    let geocoder: any Geocoding
    let location: LocationService
    let fareStore: FareStore
    /// Transit trip planner (Transitous). Previews use canned itineraries.
    let router: any TransitRouting
    /// Set when Info.plist is missing SUPABASE_* values; the UI shows a friendly message.
    let configurationError: String?

    init(
        config: AppConfig?,
        data: any FoodDataProviding,
        geocoder: any Geocoding,
        location: LocationService = LocationService(),
        router: any TransitRouting = TransitRouter(),
        configurationError: String? = nil
    ) {
        self.config = config
        self.data = data
        self.geocoder = geocoder
        self.location = location
        self.fareStore = FareStore(data: data)
        self.router = router
        self.configurationError = configurationError
    }

    var reportProblemEmail: String { config?.reportProblemEmail ?? "hello@farecart.org" }

    /// Reads Info.plist (filled from Config/*.xcconfig) and wires Supabase + geocoding.
    static func live() -> AppEnvironment {
        do {
            let config = try AppConfig(lookup: { Bundle.main.object(forInfoDictionaryKey: $0) as? String })
            let client = SupabaseClient(config: config)
            let remote = config.apiBaseURL.map { RemoteGeocoder(baseURL: $0) }
            let geocoder = FallbackGeocoder(primary: remote, fallback: AppleGeocoder())
            return AppEnvironment(config: config, data: client, geocoder: geocoder)
        } catch {
            // Keep the app usable with bundled data so a misconfigured build is obvious but not a crash.
            return AppEnvironment(
                config: nil,
                data: MockDataProvider(),
                geocoder: FallbackGeocoder(primary: nil, fallback: AppleGeocoder()),
                configurationError: "\(error)"
            )
        }
    }

    /// Offline, deterministic data for SwiftUI previews.
    static func preview(places: [Place] = MockData.places, failure: (any Error & Sendable)? = nil) -> AppEnvironment {
        AppEnvironment(
            config: nil,
            data: MockDataProvider(places: places, failure: failure),
            geocoder: PreviewGeocoder(),
            location: LocationService(previewPoint: .westSideChicago),
            router: PreviewTransitRouter()
        )
    }
}

/// One canned bus trip (Madison & Pulaski → Madison & Western) so previews never touch Transitous.
struct PreviewTransitRouter: TransitRouting {
    func plan(from origin: GeoPoint, to destination: GeoPoint, departAt: Date?, maxItineraries: Int) async throws -> [TransitItinerary] {
        let start = Date()
        func at(_ minutes: Int) -> Date { start.addingTimeInterval(TimeInterval(minutes * 60)) }
        let board = GeoPoint(latitude: 41.88062, longitude: -87.72583)
        let alight = GeoPoint(latitude: 41.88093, longitude: -87.68650)
        let legs = [
            TransitLeg(id: "p-0", mode: .walk, from: TransitStop(name: "START", coordinate: origin, time: at(0)),
                       to: TransitStop(name: "Madison & Pulaski", coordinate: board, time: at(4)), duration: 240,
                       polyline: [origin, board]),
            TransitLeg(id: "p-1", mode: .bus, routeShortName: "20", routeLongName: "Madison", headsign: "Michigan",
                       agencyName: "Chicago Transit Authority",
                       from: TransitStop(name: "Madison & Pulaski", coordinate: board, time: at(4)),
                       to: TransitStop(name: "Madison & Western", coordinate: alight, time: at(15)), duration: 660,
                       routeColorHex: "414145", polyline: [board, alight], intermediateStopCount: 13),
            TransitLeg(id: "p-2", mode: .walk, from: TransitStop(name: "Madison & Western", coordinate: alight, time: at(15)),
                       to: TransitStop(name: "END", coordinate: destination, time: at(18)), duration: 180,
                       polyline: [alight, destination]),
        ]
        return [
            TransitItinerary(id: "preview-0", duration: 1080, startTime: at(0), endTime: at(18), transfers: 0, legs: legs),
            TransitItinerary(id: "preview-1", duration: 1080, startTime: at(9), endTime: at(27), transfers: 0, legs: legs),
        ]
    }
}

/// Returns a fixed match for anything typed, so previews never touch the network.
struct PreviewGeocoder: Geocoding {
    func geocode(_ query: String) async throws -> [GeocodeResult] {
        [
            GeocodeResult(label: "\(query), Chicago, IL", point: .westSideChicago),
            GeocodeResult(label: "Austin, Chicago, IL", point: GeoPoint(latitude: 41.8880, longitude: -87.7650)),
        ]
    }
}
