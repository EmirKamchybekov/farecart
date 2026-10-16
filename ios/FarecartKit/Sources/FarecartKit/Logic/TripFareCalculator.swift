import Foundation

/// Something the cost line should say in addition to the price.
public enum TripCostNote: String, Sendable, Hashable, Codable, CaseIterable {
    /// A Pace, Metra or other non-CTA leg is in the trip; its fare is not in the total.
    case nonCTALegNotIncluded
    /// The `fares` table had no full-fare row for a mode on the trip; that boarding is uncounted.
    case missingFareData

    /// English fallback text; the app localizes by switching on the case.
    public var message: String {
        switch self {
        case .nonCTALegNotIncluded: "Includes a non-CTA leg; fare not included"
        case .missingFareData: "Fare data is missing for part of this trip"
        }
    }
}

/// What one itinerary costs a rider, with the full-fare price alongside for the savings line.
public struct TripCost: Sendable, Hashable {
    public var rider: RiderCategory
    public var riderCents: Int
    public var fullCents: Int
    /// Number of CTA vehicles boarded (walk-only trips are 0).
    public var boardings: Int
    public var notes: [TripCostNote]

    public init(rider: RiderCategory, riderCents: Int, fullCents: Int, boardings: Int, notes: [TripCostNote] = []) {
        self.rider = rider
        self.riderCents = riderCents
        self.fullCents = fullCents
        self.boardings = boardings
        self.notes = notes
    }

    public var savingsCents: Int { max(0, fullCents - riderCents) }
    public var hasDiscount: Bool { rider != .full && savingsCents > 0 }
    public var isFree: Bool { riderCents == 0 && fullCents == 0 }
    public var includesNonCTALeg: Bool { notes.contains(.nonCTALegNotIncluded) }
    /// First note's English text, for logs and tests.
    public var note: String? { notes.first?.message }

    public func priceText(locale: Locale = .current) -> String { Money.format(cents: riderCents, locale: locale) }
    public func fullPriceText(locale: Locale = .current) -> String { Money.format(cents: fullCents, locale: locale) }
}

/// The README trip cost rule, driven entirely by `fares` rows:
///
/// - The first CTA boarding pays its mode's `price_cents` (bus → `bus`, any rail → `train`).
/// - Each further CTA boarding within `transfer_window_min` of that first boarding costs
///   `transfer_cents`, up to `max_transfers` of them.
/// - A boarding past the limit or outside the window starts a new fare at its mode's price.
/// - Walk-only trips are $0. Non-CTA legs add a "fare not included" note and nothing else.
public struct TripFareCalculator: Sendable {
    public let fares: [Fare]
    public let agency: String

    public init(fares: [Fare], agency: String = "CTA") {
        self.fares = fares
        self.agency = agency
    }

    /// Cost for `rider` plus the full-fare reference price.
    public func cost(of itinerary: TransitItinerary, rider: RiderCategory) -> TripCost {
        let riderTotal = total(of: itinerary, rider: rider)
        let fullTotal = rider == .full ? riderTotal : total(of: itinerary, rider: .full)
        var notes = riderTotal.notes
        for note in fullTotal.notes where !notes.contains(note) { notes.append(note) }
        return TripCost(
            rider: rider,
            riderCents: riderTotal.cents,
            fullCents: fullTotal.cents,
            boardings: riderTotal.boardings,
            notes: notes
        )
    }

    /// Picks the rider's best program from the Discounts answers (Access before Student, see `Eligibility`).
    public func cost(of itinerary: TransitItinerary, answers: EligibilityAnswers) -> TripCost {
        let rider = Eligibility.eligibleRiders(for: answers).first { rider in
            TransitMode.allCases.contains { fare(mode: $0, rider: rider) != nil }
        } ?? .full
        return cost(of: itinerary, rider: rider)
    }

    public func fare(mode: TransitMode, rider: RiderCategory) -> Fare? {
        fares.first { $0.agency == agency && $0.mode == mode && $0.rider == rider }
    }

    // MARK: Rule

    private struct Total {
        var cents = 0
        var boardings = 0
        var notes: [TripCostNote] = []
    }

    private func total(of itinerary: TransitItinerary, rider: RiderCategory) -> Total {
        var result = Total()
        // The fare that is currently "open" for transfers.
        var openFare: Fare?
        var openedAt: Date?
        var transfersUsed = 0

        for leg in itinerary.legs where leg.mode.isTransit {
            guard leg.isCTA else {
                if !result.notes.contains(.nonCTALegNotIncluded) { result.notes.append(.nonCTALegNotIncluded) }
                continue
            }
            guard let mode = leg.mode.fareMode else { continue }
            // Prefer the rider's row; a rider without a row for this mode pays full fare for it.
            guard let row = fare(mode: mode, rider: rider) ?? fare(mode: mode, rider: .full) else {
                if !result.notes.contains(.missingFareData) { result.notes.append(.missingFareData) }
                continue
            }
            result.boardings += 1

            if let open = openFare, transfersUsed < open.maxTransfers, Self.isWithinWindow(leg.from.time, since: openedAt, minutes: open.transferWindowMinutes) {
                result.cents += open.transferCents
                transfersUsed += 1
            } else {
                result.cents += row.priceCents
                openFare = row
                openedAt = leg.from.time
                transfersUsed = 0
            }
        }
        return result
    }

    /// Unknown boarding times are assumed to be within the window (the router only returns
    /// consecutive legs, which are always minutes apart in practice).
    private static func isWithinWindow(_ time: Date?, since start: Date?, minutes: Int) -> Bool {
        guard let time, let start else { return true }
        return time.timeIntervalSince(start) <= TimeInterval(minutes * 60)
    }
}
