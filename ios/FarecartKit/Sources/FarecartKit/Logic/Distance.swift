import Foundation

public enum Distance {
    public static let metersPerMile = 1609.344

    public static func miles(fromMeters meters: Double) -> Double { meters / metersPerMile }

    /// Short human string in miles: "0.3 mi", "1.2 mi", "12 mi". Under 0.1 mi reads "0.1 mi".
    public static func milesText(meters: Double, locale: Locale = .current) -> String {
        let miles = max(0.1, miles(fromMeters: meters))
        let measurement = Measurement(value: miles, unit: UnitLength.miles)
        let precision: FloatingPointFormatStyle<Double>.Configuration.Precision = miles < 10
            ? .fractionLength(1)
            : .fractionLength(0)
        return measurement.formatted(
            .measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(precision))
            .locale(locale)
        )
    }

    /// Rough walking time at ~3 mph, rounded up to whole minutes.
    public static func walkingMinutes(meters: Double) -> Int {
        let metersPerMinute = 3.0 * metersPerMile / 60.0
        return Int((meters / metersPerMinute).rounded(.up))
    }
}
