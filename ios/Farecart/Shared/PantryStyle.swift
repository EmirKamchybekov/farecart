import SwiftUI
import FarecartKit

// Names, symbols and colours for the pantry models. Kept out of FarecartKit (Foundation only).

extension PantryCategory {
    var title: LocalizedStringResource {
        switch self {
        case .produce: "Produce"
        case .dairy: "Dairy"
        case .protein: "Meat"
        case .canned: "Canned"
        case .bread: "Bread"
        case .baby: "Baby"
        case .water: "Water"
        case .other: "Other"
        }
    }

    var symbolName: String {
        switch self {
        case .produce: "carrot.fill"
        case .dairy: "cup.and.saucer.fill"
        case .protein: "fish.fill"
        case .canned: "shippingbox.fill"
        case .bread: "birthday.cake.fill"
        case .baby: "figure.and.child.holdinghands"
        case .water: "drop.fill"
        case .other: "bag.fill"
        }
    }
}

extension PantryLevel {
    var title: LocalizedStringResource {
        switch self {
        case .plenty: "Plenty"
        case .low: "Low"
        case .out: "Out"
        }
    }

    /// plenty green, low amber, out grey (root README client rules).
    var color: Color {
        switch self {
        case .plenty: .green
        case .low: .orange
        case .out: .gray
        }
    }

    var symbolName: String {
        switch self {
        case .plenty: "checkmark.circle.fill"
        case .low: "exclamationmark.circle.fill"
        case .out: "xmark.circle.fill"
        }
    }
}

extension PantryModel {
    var description: LocalizedStringResource {
        switch self {
        case .clientChoice: "Client choice: you pick your own items"
        case .prePacked: "Pre-packed boxes"
        case .both: "Pre-packed boxes or client choice"
        }
    }

    var symbolName: String {
        switch self {
        case .clientChoice: "cart.fill"
        case .prePacked: "shippingbox.fill"
        case .both: "cart.badge.plus"
        }
    }
}

extension Place {
    /// "Most pantries don't require SNAP or ID." unless the listing says otherwise.
    var pantryRequirementsLine: LocalizedStringResource {
        switch (requiresSNAP, requiresID) {
        case (true, true?): "SNAP and a photo ID are required here."
        case (true, _): "SNAP is required here. Most pantries don't ask for ID."
        case (false, true?): "A photo ID is required here. SNAP is not."
        case (false, false?): "No SNAP or ID needed here."
        case (false, nil): "Most pantries don't require SNAP or ID."
        }
    }
}

/// A `Place` stand-in for a visit, so the route screen can price the trip to it.
extension PantryVisit {
    func asPlace() -> Place? {
        guard let coordinate else { return nil }
        return Place(id: locationID ?? id, name: locationName, type: .pantry, address: address, latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}

/// Date and time pieces for slots and visits, in the language picked in Settings (SwiftUI's
/// `Text` re-resolves against the environment locale, but `Date.formatted` does not).
enum VisitFormat {
    static var locale: Locale { AppLanguage.selected.locale ?? .current }

    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().locale(locale))
    }

    static func weekday(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).locale(locale))
    }

    static func dayNumber(_ date: Date) -> String {
        date.formatted(.dateTime.day().locale(locale))
    }

    static func time(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
    }

    static func timeRange(_ start: Date, _ end: Date) -> String {
        "\(time(start)) – \(time(end))"
    }

    static func dayAndTime(_ date: Date) -> String {
        "\(day(date)) · \(time(date))"
    }

    static func relative(_ date: Date, locale: Locale) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
