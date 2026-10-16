import Foundation

/// Currency formatting for cents, locale-aware (USD).
public enum Money {
    public static func format(cents: Int, locale: Locale = .current) -> String {
        let amount = Decimal(cents) / 100
        return amount.formatted(.currency(code: "USD").locale(locale))
    }
}

/// What one ride costs the user on a given mode, with and without their discount.
public struct FareQuote: Sendable, Hashable {
    public let mode: TransitMode
    public let full: Fare
    /// The best discount the user qualifies for, or `nil` when they pay full fare.
    public let discounted: Fare?
    /// Cheaper-but-conditional alternatives (for example the student fare for a SNAP household).
    public let alternatives: [Fare]

    public init(mode: TransitMode, full: Fare, discounted: Fare?, alternatives: [Fare] = []) {
        self.mode = mode
        self.full = full
        self.discounted = discounted
        self.alternatives = alternatives
    }

    /// The price the user actually pays.
    public var priceCents: Int { discounted?.priceCents ?? full.priceCents }
    public var savingsCents: Int { full.priceCents - priceCents }
    public var hasDiscount: Bool { discounted != nil && savingsCents > 0 }

    public func priceText(locale: Locale = .current) -> String { Money.format(cents: priceCents, locale: locale) }
    public func fullPriceText(locale: Locale = .current) -> String { Money.format(cents: full.priceCents, locale: locale) }
}

/// Pure fare math over rows from the `fares` table. Never hardcodes prices.
public struct FareCalculator: Sendable {
    public let fares: [Fare]
    public let agency: String

    public init(fares: [Fare], agency: String = "CTA") {
        self.fares = fares
        self.agency = agency
    }

    public func fare(mode: TransitMode, rider: RiderCategory) -> Fare? {
        fares.first { $0.agency == agency && $0.mode == mode && $0.rider == rider }
    }

    /// Quote for one mode. Returns `nil` when the full fare row is missing (no data yet).
    public func quote(mode: TransitMode, answers: EligibilityAnswers) -> FareQuote? {
        guard let full = fare(mode: mode, rider: .full) else { return nil }
        let eligible = Eligibility.eligibleRiders(for: answers).compactMap { fare(mode: mode, rider: $0) }
        guard let primary = eligible.first else {
            return FareQuote(mode: mode, full: full, discounted: nil)
        }
        let others = eligible.dropFirst().filter { $0.priceCents < primary.priceCents }
        return FareQuote(mode: mode, full: full, discounted: primary, alternatives: Array(others))
    }

    /// Bus then train, skipping any mode without data.
    public func quotes(answers: EligibilityAnswers) -> [FareQuote] {
        TransitMode.allCases.compactMap { quote(mode: $0, answers: answers) }
    }
}
