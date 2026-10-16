import Foundation

/// In-memory data for SwiftUI previews and tests. Distances are computed with the haversine
/// formula and sorted like the real RPC.
public struct MockDataProvider: FoodDataProviding {
    public var places: [Place]
    public var fareRows: [Fare]
    public var programRows: [Program]
    public var delayNanoseconds: UInt64
    public var failure: (any Error & Sendable)?

    public init(
        places: [Place] = MockData.places,
        fares: [Fare] = BundledFallbacks.fares,
        programs: [Program] = BundledFallbacks.programs,
        delayNanoseconds: UInt64 = 0,
        failure: (any Error & Sendable)? = nil
    ) {
        self.places = places
        self.fareRows = fares
        self.programRows = programs
        self.delayNanoseconds = delayNanoseconds
        self.failure = failure
    }

    public func nearbyPlaces(around point: GeoPoint, filter: PlaceFilter, radius: SearchRadius, limit: Int) async throws -> [Place] {
        try await pause()
        let allowed = filter.types.map(Set.init)
        return places
            .filter { allowed == nil || allowed!.contains($0.type) }
            .map { place in
                var copy = place
                copy.distanceMeters = point.distanceMeters(to: place.coordinate)
                return copy
            }
            .filter { ($0.distanceMeters ?? .infinity) <= Double(radius.meters) }
            .sorted { ($0.distanceMeters ?? 0) < ($1.distanceMeters ?? 0) }
            .prefix(limit)
            .map { $0 }
    }

    public func fares() async throws -> [Fare] {
        try await pause()
        return fareRows
    }

    public func programs() async throws -> [Program] {
        try await pause()
        return programRows
    }

    private func pause() async throws {
        if let failure { throw failure }
        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
    }
}

/// A handful of plausible West Side Chicago listings for previews. Not real data: the live
/// `locations` table (seeded from `data/`) is the source of truth.
public enum MockData {
    public static let places: [Place] = [
        Place(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: "Garfield Park Fresh Market",
            type: .grocery,
            address: "300 N Central Park Ave, Chicago, IL 60624",
            neighborhood: "East Garfield Park",
            latitude: 41.8865, longitude: -87.7167,
            hours: ["mon": "8:00-21:00", "tue": "8:00-21:00", "wed": "8:00-21:00", "thu": "8:00-21:00",
                    "fri": "8:00-21:00", "sat": "8:00-21:00", "sun": "9:00-19:00"],
            hoursText: "Mon–Sat 8am–9pm; Sun 9am–7pm",
            acceptsEBT: true,
            languages: ["en", "es"],
            phone: "(773) 555-0142",
            website: "https://example.org/fresh-market",
            sourceURL: "https://example.org/fresh-market",
            verifiedOn: PostgresDate.parse("2026-10-01")
        ),
        Place(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            name: "Breakthrough FamilyPlex Food Pantry",
            type: .pantry,
            address: "3219 W Carroll Ave, Chicago, IL 60624",
            neighborhood: "East Garfield Park",
            latitude: 41.8872, longitude: -87.7065,
            hours: ["tue": "10:00-14:00", "thu": "10:00-14:00", "sat": "9:00-12:00"],
            hoursText: "Tue & Thu 10am–2pm; Sat 9am–12pm",
            requirements: "Photo ID. Serves ZIP codes 60612, 60624 and 60644.",
            languages: ["en", "es"],
            phone: "(773) 555-0199",
            sourceURL: "https://example.org/pantry",
            notes: "Bring your own bags."
        ),
        Place(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            name: "Austin Produce Giveaway",
            type: .giveaway,
            address: "5700 W Madison St, Chicago, IL 60644",
            neighborhood: "Austin",
            latitude: 41.8805, longitude: -87.7680,
            hoursText: "2nd Saturday of the month, 10am until supplies run out",
            requirements: "No ID needed. First come, first served.",
            languages: ["en"],
            sourceURL: "https://example.org/giveaway"
        ),
        Place(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            name: "Pete's Fresh Market",
            type: .grocery,
            address: "4343 W Madison St, Chicago, IL 60624",
            neighborhood: "West Garfield Park",
            latitude: 41.8807, longitude: -87.7355,
            hoursText: "Daily 7am–10pm",
            acceptsEBT: true,
            languages: ["en", "es"],
            phone: "(773) 555-0177",
            website: "https://example.org/petes",
            sourceURL: "https://example.org/petes",
            verifiedOn: PostgresDate.parse("2026-09-28")
        ),
        Place(
            id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            name: "Greater West Town Pantry",
            type: .pantry,
            address: "500 N Sacramento Blvd, Chicago, IL 60612",
            neighborhood: "Humboldt Park",
            latitude: 41.8908, longitude: -87.7025,
            hours: ["wed": "closed", "fri": "9:00-13:00"],
            hoursText: "Fri 9am–1pm",
            requirements: "Proof of address required.",
            languages: ["en", "es", "pl"],
            phone: "(773) 555-0111",
            sourceURL: "https://example.org/gwt"
        ),
    ]

    public static var samplePlace: Place { places[0] }
    public static var samplePantry: Place { places[1] }
}
