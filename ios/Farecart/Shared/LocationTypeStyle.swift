import SwiftUI
import FarecartKit

extension LocationType {
    var color: Color {
        switch self {
        case .grocery: .green
        case .pantry: .orange
        case .giveaway: .purple
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .grocery: "Grocery"
        case .pantry: "Pantry"
        case .giveaway: "Giveaway"
        }
    }
}

extension PlaceFilter {
    var title: LocalizedStringResource {
        switch self {
        case .all: "All"
        case .grocery: "Grocery"
        case .pantry: "Pantry"
        case .giveaway: "Giveaway"
        }
    }

    var color: Color {
        switch self {
        case .all: .accentColor
        case .grocery: LocationType.grocery.color
        case .pantry: LocationType.pantry.color
        case .giveaway: LocationType.giveaway.color
        }
    }
}

extension TransitMode {
    var title: LocalizedStringResource {
        switch self {
        case .bus: "Bus"
        case .train: "Train"
        }
    }
}

/// Short program names for sentences like "with your Access discount".
func programShortName(forKey key: String?) -> LocalizedStringResource {
    switch key {
    case "access": "Access"
    case "student": "Student"
    default: "reduced fare"
    }
}
