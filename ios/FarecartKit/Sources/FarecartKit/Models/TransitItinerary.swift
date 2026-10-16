import Foundation

/// A latitude/longitude on a route geometry. Same type as `GeoPoint`; the alias keeps the
/// transit API vocabulary readable.
public typealias Coordinate = GeoPoint

/// How a leg of a trip is travelled. MOTIS modes collapse into these four buckets.
public enum TransitLegMode: String, Sendable, Hashable, Codable, CaseIterable {
    case walk
    case bus
    case train
    case other

    /// `WALK` → walk, `BUS` → bus, `SUBWAY`/`RAIL`/`TRAM`/`METRO` → train, anything else → other.
    public init(motisMode: String?) {
        switch motisMode?.uppercased() {
        case "WALK": self = .walk
        case "BUS": self = .bus
        case "SUBWAY", "RAIL", "TRAM", "METRO": self = .train
        default: self = .other
        }
    }

    public var isTransit: Bool { self != .walk }

    /// The `fares.mode` this leg is charged as, or `nil` for walking.
    public var fareMode: TransitMode? {
        switch self {
        case .walk: nil
        case .bus: .bus
        case .train: .train
        case .other: .train  // CTA never emits this; treat as rail so the cost is never understated.
        }
    }
}

/// Where a leg starts or ends: a stop, or the trip's origin / destination.
public struct TransitStop: Sendable, Hashable {
    public var name: String
    public var coordinate: Coordinate
    /// Departure time at the start of a leg, arrival time at the end.
    public var time: Date?

    public init(name: String, coordinate: Coordinate, time: Date? = nil) {
        self.name = name
        self.coordinate = coordinate
        self.time = time
    }
}

/// One leg of an itinerary: a walk, or a ride on one vehicle.
public struct TransitLeg: Sendable, Hashable, Identifiable {
    public var id: String
    public var mode: TransitLegMode
    public var routeShortName: String?
    public var routeLongName: String?
    public var headsign: String?
    public var agencyName: String?
    public var from: TransitStop
    public var to: TransitStop
    /// Seconds.
    public var duration: TimeInterval
    /// Six hex digits without `#`, as published in GTFS (`414145` for CTA buses).
    public var routeColorHex: String?
    public var polyline: [Coordinate]
    public var intermediateStopCount: Int

    public init(
        id: String = UUID().uuidString,
        mode: TransitLegMode,
        routeShortName: String? = nil,
        routeLongName: String? = nil,
        headsign: String? = nil,
        agencyName: String? = nil,
        from: TransitStop,
        to: TransitStop,
        duration: TimeInterval,
        routeColorHex: String? = nil,
        polyline: [Coordinate] = [],
        intermediateStopCount: Int = 0
    ) {
        self.id = id
        self.mode = mode
        self.routeShortName = routeShortName
        self.routeLongName = routeLongName
        self.headsign = headsign
        self.agencyName = agencyName
        self.from = from
        self.to = to
        self.duration = duration
        self.routeColorHex = routeColorHex
        self.polyline = polyline
        self.intermediateStopCount = intermediateStopCount
    }

    /// The trip-cost rule only knows CTA fares. Pace, Metra and anything else is "not included".
    public var isCTA: Bool {
        agencyName?.localizedCaseInsensitiveContains("Chicago Transit Authority") == true
    }

    /// "20", "Blue Line", or the long name when the short one is missing.
    public var routeDisplayName: String? {
        let short = routeShortName?.trimmingCharacters(in: .whitespaces) ?? ""
        if !short.isEmpty { return short }
        let long = routeLongName?.trimmingCharacters(in: .whitespaces) ?? ""
        return long.isEmpty ? nil : long
    }

    public var durationMinutes: Int { max(1, Int((duration / 60).rounded())) }
}

/// One way to make the trip, as returned by the router.
public struct TransitItinerary: Sendable, Hashable, Identifiable {
    public var id: String
    /// Seconds door to door.
    public var duration: TimeInterval
    public var startTime: Date
    public var endTime: Date
    public var transfers: Int
    public var legs: [TransitLeg]

    public init(
        id: String = UUID().uuidString,
        duration: TimeInterval,
        startTime: Date,
        endTime: Date,
        transfers: Int,
        legs: [TransitLeg]
    ) {
        self.id = id
        self.duration = duration
        self.startTime = startTime
        self.endTime = endTime
        self.transfers = transfers
        self.legs = legs
    }

    public var durationMinutes: Int { max(1, Int((duration / 60).rounded())) }
    public var transitLegs: [TransitLeg] { legs.filter { $0.mode.isTransit } }
    public var isWalkOnly: Bool { transitLegs.isEmpty }
    public var busCount: Int { legs.filter { $0.mode == .bus }.count }
    public var trainCount: Int { legs.filter { $0.mode == .train }.count }

    /// Every coordinate on the route, for fitting a map camera.
    public var allCoordinates: [Coordinate] {
        legs.flatMap { leg in
            leg.polyline.isEmpty ? [leg.from.coordinate, leg.to.coordinate] : leg.polyline
        }
    }
}
