import CoreLocation
import FarecartKit

enum LocationError: Error, LocalizedError {
    case denied
    case unavailable
    case timedOut

    var errorDescription: String? {
        switch self {
        case .denied: String(localized: "Location access is off. Allow it in Settings, or type an address instead.")
        case .unavailable: String(localized: "Could not find your location right now. Try typing an address.")
        case .timedOut: String(localized: "Finding your location is taking too long. Try again or type an address.")
        }
    }
}

/// One-shot "where am I?" using the modern async CoreLocation API (iOS 17+ `CLLocationUpdate`,
/// iOS 18+ `CLServiceSession` for the when-in-use prompt). No delegate boilerplate.
struct LocationService: Sendable {
    /// Fixed answer for SwiftUI previews and tests.
    var previewPoint: GeoPoint?

    init(previewPoint: GeoPoint? = nil) {
        self.previewPoint = previewPoint
    }

    func currentLocation(timeout: Duration = .seconds(15)) async throws -> GeoPoint {
        if let previewPoint { return previewPoint }
        return try await withThrowingTaskGroup(of: GeoPoint.self) { group in
            group.addTask { try await Self.firstFix() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw LocationError.timedOut
            }
            guard let first = try await group.next() else { throw LocationError.unavailable }
            group.cancelAll()
            return first
        }
    }

    private static func firstFix() async throws -> GeoPoint {
        // Holding the session triggers the when-in-use prompt and keeps authorization alive.
        let session = CLServiceSession(authorization: .whenInUse)
        defer { session.invalidate() }
        for try await update in CLLocationUpdate.liveUpdates() {
            if update.authorizationDenied || update.authorizationDeniedGlobally || update.authorizationRestricted {
                throw LocationError.denied
            }
            if let location = update.location {
                return GeoPoint(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
            }
            if update.locationUnavailable {
                throw LocationError.unavailable
            }
        }
        throw LocationError.unavailable
    }
}
