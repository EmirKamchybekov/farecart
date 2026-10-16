import Foundation

/// Deep links for transit directions and contact actions. Pure URL building, fully testable.
public enum DirectionsLinks {
    private static func coordinateString(_ point: GeoPoint) -> String {
        // 6 decimals ≈ 0.1 m; avoids locale-specific decimal separators.
        String(format: "%.6f,%.6f", locale: Locale(identifier: "en_US_POSIX"), point.latitude, point.longitude)
    }

    /// Apple Maps transit directions, as documented in the README (`maps://?daddr=lat,lng&dirflg=r`).
    public static func appleMapsTransit(to point: GeoPoint, name: String? = nil) -> URL {
        var components = URLComponents()
        components.scheme = "maps"
        components.host = ""
        var daddr = coordinateString(point)
        if let name, !name.isEmpty { daddr = "\(name)@\(daddr)" }
        components.queryItems = [
            URLQueryItem(name: "daddr", value: daddr),
            URLQueryItem(name: "dirflg", value: "r"),
        ]
        return components.url!
    }

    /// Google Maps app (requires `comgooglemaps` in `LSApplicationQueriesSchemes`).
    public static func googleMapsApp(to point: GeoPoint) -> URL {
        var components = URLComponents()
        components.scheme = "comgooglemaps"
        components.host = ""
        components.queryItems = [
            URLQueryItem(name: "daddr", value: coordinateString(point)),
            URLQueryItem(name: "directionsmode", value: "transit"),
        ]
        return components.url!
    }

    /// Google Maps on the web; works without the app installed.
    public static func googleMapsWeb(to point: GeoPoint) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.google.com"
        components.path = "/maps/dir/"
        components.queryItems = [
            URLQueryItem(name: "api", value: "1"),
            URLQueryItem(name: "destination", value: coordinateString(point)),
            URLQueryItem(name: "travelmode", value: "transit"),
        ]
        return components.url!
    }

    /// `tel:` URL keeping only digits and a leading `+`. Returns `nil` for empty/garbage input.
    public static func telephoneURL(_ raw: String?) -> URL? {
        guard let raw else { return nil }
        var digits = raw.filter { $0.isNumber }
        if raw.trimmingCharacters(in: .whitespaces).hasPrefix("+") { digits = "+" + digits }
        guard digits.filter(\.isNumber).count >= 7 else { return nil }
        return URL(string: "tel:\(digits)")
    }

    /// Pre-filled email for "Report a problem with a listing".
    public static func reportProblemEmail(to address: String, placeName: String?, placeID: UUID?) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = address
        var subject = "Farecart listing problem"
        if let placeName, !placeName.isEmpty { subject += ": \(placeName)" }
        var body = "What is wrong with this listing?\n\n"
        if let placeID { body += "\nListing ID: \(placeID.uuidString)\n" }
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body),
        ]
        return components.url
    }
}
