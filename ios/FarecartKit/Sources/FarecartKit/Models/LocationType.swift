import Foundation

/// Mirrors the Postgres enum `location_type`.
public enum LocationType: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case grocery
    case pantry
    case giveaway

    public var id: String { rawValue }

    /// SF Symbol name used for map pins and badges.
    public var symbolName: String {
        switch self {
        case .grocery: "cart.fill"
        case .pantry: "shippingbox.fill"
        case .giveaway: "gift.fill"
        }
    }
}

/// The filter chips shown above the map.
public enum PlaceFilter: String, Sendable, Hashable, CaseIterable, Identifiable {
    case all
    case grocery
    case pantry
    case giveaway
    /// Pantries that take visit bookings.
    case bookable

    public var id: String { rawValue }

    /// `nil` means "no type filter" (the RPC's `p_types` default).
    public var types: [LocationType]? {
        switch self {
        case .all: nil
        case .grocery: [.grocery]
        case .pantry: [.pantry]
        case .giveaway: [.giveaway]
        case .bookable: [.pantry]
        }
    }

    /// Extra client-side condition applied after the type filter.
    public func matches(_ place: Place) -> Bool {
        self == .bookable ? place.isBookable : true
    }

    public var symbolName: String {
        switch self {
        case .all: "line.3.horizontal.decrease"
        case .grocery: LocationType.grocery.symbolName
        case .pantry: LocationType.pantry.symbolName
        case .giveaway: LocationType.giveaway.symbolName
        case .bookable: "calendar.badge.plus"
        }
    }
}
