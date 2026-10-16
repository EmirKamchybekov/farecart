import Foundation

/// Google encoded polyline decoding (the format MOTIS / Transitous uses for `legGeometry.points`).
public enum Polyline {
    /// Chicago and its near suburbs. Used to sanity-check which precision a polyline was encoded with.
    public struct BoundingBox: Sendable, Hashable {
        public var minLatitude: Double
        public var maxLatitude: Double
        public var minLongitude: Double
        public var maxLongitude: Double

        public init(minLatitude: Double, maxLatitude: Double, minLongitude: Double, maxLongitude: Double) {
            self.minLatitude = minLatitude
            self.maxLatitude = maxLatitude
            self.minLongitude = minLongitude
            self.maxLongitude = maxLongitude
        }

        public static let chicago = BoundingBox(minLatitude: 41.4, maxLatitude: 42.3, minLongitude: -88.3, maxLongitude: -87.3)

        public func contains(_ point: Coordinate) -> Bool {
            (minLatitude...maxLatitude).contains(point.latitude) && (minLongitude...maxLongitude).contains(point.longitude)
        }
    }

    /// Decodes `encoded` with the given number of decimal places (5 is Google's classic, 7 is MOTIS's default).
    /// Malformed trailing data is dropped rather than thrown: a partial line is still useful on a map.
    public static func decode(_ encoded: String, precision: Int = 5) -> [Coordinate] {
        let factor = pow(10.0, Double(precision))
        var result: [Coordinate] = []
        var latitude = 0
        var longitude = 0
        var index = encoded.utf8.startIndex
        let end = encoded.utf8.endIndex

        func readValue() -> Int? {
            var shift = 0
            var value = 0
            while index < end {
                let byte = Int(encoded.utf8[index]) - 63
                index = encoded.utf8.index(after: index)
                guard byte >= 0 else { return nil }
                value |= (byte & 0x1F) << shift
                shift += 5
                if byte < 0x20 {
                    return (value & 1) != 0 ? ~(value >> 1) : (value >> 1)
                }
            }
            return nil
        }

        while index < end {
            guard let dLat = readValue(), let dLng = readValue() else { break }
            latitude += dLat
            longitude += dLng
            result.append(Coordinate(latitude: Double(latitude) / factor, longitude: Double(longitude) / factor))
        }
        return result
    }

    /// Decodes with precision 7 (MOTIS default) and, if the first point does not land inside `bounds`,
    /// retries with precision 5. An explicit `precision` from the API skips the guesswork.
    public static func decodeDetectingPrecision(
        _ encoded: String,
        precision: Int? = nil,
        bounds: BoundingBox = .chicago
    ) -> [Coordinate] {
        if let precision {
            let explicit = decode(encoded, precision: precision)
            if let first = explicit.first, bounds.contains(first) { return explicit }
        }
        let seven = decode(encoded, precision: 7)
        if let first = seven.first, bounds.contains(first) { return seven }
        let five = decode(encoded, precision: 5)
        if let first = five.first, bounds.contains(first) { return five }
        return seven
    }
}
