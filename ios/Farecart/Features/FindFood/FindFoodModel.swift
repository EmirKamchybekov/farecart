import Foundation
import MapKit
import Observation
import SwiftUI
import FarecartKit

/// State for the Find Food tab and the search tab (they share the origin and results).
@MainActor
@Observable
final class FindFoodModel {
    // Inputs
    var searchText = ""
    private(set) var filter: PlaceFilter = .all
    var radius: SearchRadius = .fiveMiles

    // Where we are searching from
    private(set) var origin: GeoPoint?
    private(set) var originLabel: String = ""
    private(set) var originIsCurrentLocation = false

    // Outputs
    private(set) var places: [Place] = []
    private(set) var isLoading = false
    private(set) var isLocating = false
    private(set) var errorMessage: String?
    /// True when the user has refused location access; the UI offers Settings instead of Retry.
    private(set) var locationDenied = false
    private(set) var geocodeResults: [GeocodeResult] = []
    private(set) var isGeocoding = false
    private(set) var hasSearchedOnce = false

    var selectedPlace: Place?
    /// Whether the results panel is on screen at all (false until the first search).
    var isListPresented = false
    /// How much of the results panel is showing.
    var panelState: ResultsPanelState = .half
    var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(center: GeoPoint.westSideChicago.clCoordinate, latitudinalMeters: 6000, longitudinalMeters: 6000)
    )

    private let environment: AppEnvironment
    private var reloadGeneration = 0

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    var showsEmptyState: Bool { hasSearchedOnce && !isLoading && places.isEmpty && errorMessage == nil }

    // MARK: Actions

    /// First launch: show the West Side so the map is never blank, then let the user refine.
    func loadInitialIfNeeded() async {
        guard origin == nil else { return }
        setOrigin(.westSideChicago, label: String(localized: "West Side, Chicago"), isCurrent: false)
        await reload()
    }

    func useMyLocation() async {
        isLocating = true
        errorMessage = nil
        locationDenied = false
        defer { isLocating = false }
        do {
            let point = try await environment.location.currentLocation()
            setOrigin(point, label: String(localized: "My location"), isCurrent: true)
            await reload()
        } catch LocationError.denied {
            locationDenied = true
            errorMessage = LocationError.denied.localizedDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Look up what the user typed; show the matches in the search tab.
    func geocode() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { geocodeResults = []; return }
        isGeocoding = true
        errorMessage = nil
        defer { isGeocoding = false }
        do {
            geocodeResults = try await environment.geocoder.geocode(query)
        } catch GeocodingError.noResults {
            geocodeResults = []
            errorMessage = String(localized: "No match for that address. Try adding the street number or ZIP code.")
        } catch {
            geocodeResults = []
            errorMessage = String(localized: "Could not look up that address. Check your connection and try again.")
        }
    }

    /// Search from the first match straight away (Return key).
    func searchAndUseFirstMatch() async {
        await geocode()
        if let first = geocodeResults.first {
            await choose(first)
        }
    }

    func choose(_ result: GeocodeResult) async {
        setOrigin(result.point, label: result.label, isCurrent: false)
        searchText = result.label
        await reload()
    }

    func setFilter(_ newFilter: PlaceFilter) async {
        guard newFilter != filter else { return }
        filter = newFilter
        await reload()
    }

    func widenSearch() async {
        guard let wider = radius.wider else { return }
        radius = wider
        await reload()
    }

    func reload() async {
        guard let origin else { return }
        reloadGeneration += 1
        let generation = reloadGeneration
        let filter = self.filter
        let radius = self.radius
        isLoading = true
        defer { if generation == reloadGeneration { isLoading = false } }
        do {
            let results = try await environment.data.nearbyPlaces(around: origin, filter: filter, radius: radius, limit: 40)
            guard generation == reloadGeneration else { return }   // superseded by a newer search
            places = results
            errorMessage = nil
            hasSearchedOnce = true
            isListPresented = true
            if panelState == .peek { panelState = .half }
            fitCamera(to: results, around: origin)
        } catch {
            guard generation == reloadGeneration else { return }
            places = []
            hasSearchedOnce = true
            errorMessage = String(localized: "Could not load places. Check your connection and try again.")
        }
    }

    func select(_ place: Place) {
        selectedPlace = place
        withAnimation(.snappy) {
            cameraPosition = .region(
                MKCoordinateRegion(center: place.clCoordinate, latitudinalMeters: 1500, longitudinalMeters: 1500)
            )
        }
    }

    // MARK: Helpers

    private func setOrigin(_ point: GeoPoint, label: String, isCurrent: Bool) {
        origin = point
        originLabel = label
        originIsCurrentLocation = isCurrent
        radius = .fiveMiles
    }

    private func fitCamera(to places: [Place], around origin: GeoPoint) {
        var coordinates = places.prefix(12).map(\.clCoordinate)
        coordinates.append(origin.clCoordinate)
        guard coordinates.count > 1 else {
            cameraPosition = .region(MKCoordinateRegion(center: origin.clCoordinate, latitudinalMeters: 4000, longitudinalMeters: 4000))
            return
        }
        let lats = coordinates.map(\.latitude)
        let lngs = coordinates.map(\.longitude)
        let center = CLLocationCoordinate2D(latitude: (lats.min()! + lats.max()!) / 2, longitude: (lngs.min()! + lngs.max()!) / 2)
        let span = MKCoordinateSpan(
            latitudeDelta: max(0.02, (lats.max()! - lats.min()!) * 1.5),
            longitudeDelta: max(0.02, (lngs.max()! - lngs.min()!) * 1.5)
        )
        withAnimation(.smooth) {
            cameraPosition = .region(MKCoordinateRegion(center: center, span: span))
        }
    }
}

/// Detents of the in-tab results panel.
enum ResultsPanelState: Hashable {
    case peek
    case half
    case full
}

extension GeoPoint {
    var clCoordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

extension Place {
    var clCoordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}
