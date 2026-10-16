import CoreLocation
import FarecartKit

enum LocationError: Error, LocalizedError {
    case denied
    case unavailable
    case timedOut

    var errorDescription: String? {
        switch self {
        case .denied: String(localized: "Location access is off. Allow it in Settings, or type an address instead.", bundle: LanguageBundle.current)
        case .unavailable: String(localized: "Could not find your location right now. Try typing an address.", bundle: LanguageBundle.current)
        case .timedOut: String(localized: "Finding your location is taking too long. Try again or type an address.", bundle: LanguageBundle.current)
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

    /// `true` when the user already allowed location, so Find Food can start from where they are.
    var isAuthorized: Bool {
        if previewPoint != nil { return true }
        switch CLLocationManager().authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: return true
        default: return false
        }
    }

    /// Shows the when-in-use prompt (onboarding) and waits for the answer. Returns the final status.
    @MainActor
    func requestWhenInUsePermission() async -> CLAuthorizationStatus {
        if previewPoint != nil { return .authorizedWhenInUse }
        return await PermissionRequester.shared.request()
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
            // `locationUnavailable` is transient (first update before a fix, or a simulator with no
            // simulated location). Keep waiting; the caller's timeout bounds the wait.
        }
        throw LocationError.unavailable
    }
}

/// Owns a CLLocationManager for the one-time permission prompt. CoreLocation calls the delegate on
/// the thread that created the manager, which is the main thread here.
@MainActor
private final class PermissionRequester: NSObject, @preconcurrency CLLocationManagerDelegate {
    static let shared = PermissionRequester()
    private let manager = CLLocationManager()
    private var continuations: [CheckedContinuation<CLAuthorizationStatus, Never>] = []

    private override init() {
        super.init()
        manager.delegate = self
    }

    func request() async -> CLAuthorizationStatus {
        let status = manager.authorizationStatus
        guard status == .notDetermined else { return status }
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
            manager.requestWhenInUseAuthorization()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager.authorizationStatus != .notDetermined else { return }
        let waiting = continuations
        continuations = []
        for continuation in waiting { continuation.resume(returning: manager.authorizationStatus) }
    }
}
