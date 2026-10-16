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
    /// Set when Info.plist is missing SUPABASE_* values; the UI shows a friendly message.
    let configurationError: String?

    init(
        config: AppConfig?,
        data: any FoodDataProviding,
        geocoder: any Geocoding,
        location: LocationService = LocationService(),
        configurationError: String? = nil
    ) {
        self.config = config
        self.data = data
        self.geocoder = geocoder
        self.location = location
        self.fareStore = FareStore(data: data)
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
            location: LocationService(previewPoint: .westSideChicago)
        )
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
