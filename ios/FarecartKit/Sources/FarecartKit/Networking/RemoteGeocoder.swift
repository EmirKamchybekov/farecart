import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `GET {API_BASE_URL}/geocode?q=<text>` against the Farecart API.
///
/// The API is being built separately, so decoding is deliberately lenient. Accepted shapes:
/// - `{"lat": 41.88, "lng": -87.72, "label": "..."}`
/// - `{"latitude": ..., "longitude": ..., "formatted": "..."}`
/// - `{"results": [ <either of the above> ]}` (also `matches`, `data`, or a bare array)
public struct RemoteGeocoder: Geocoding {
    public let baseURL: URL
    public let transport: any HTTPTransport

    public init(baseURL: URL, transport: any HTTPTransport = URLSessionTransport()) {
        self.baseURL = baseURL
        self.transport = transport
    }

    public func geocode(_ query: String) async throws -> [GeocodeResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GeocodingError.emptyQuery }
        guard var components = URLComponents(url: baseURL.appending(path: "geocode"), resolvingAgainstBaseURL: false) else {
            throw APIError.invalidResponse
        }
        components.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        guard let url = components.url else { throw APIError.invalidResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw APIError.httpStatus(response.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        return try Self.parse(data, fallbackLabel: trimmed)
    }

    public static func parse(_ data: Data, fallbackLabel: String) throws -> [GeocodeResult] {
        let root = try PostgRESTDecoder.decode(JSONValue.self, from: data)
        let candidates: [JSONValue]
        switch root {
        case .array(let items):
            candidates = items
        case .object(let dict):
            if let list = ["results", "matches", "data", "items"].lazy.compactMap({ key -> [JSONValue]? in
                if case .array(let items)? = dict[key] { return items }
                return nil
            }).first {
                candidates = list
            } else {
                candidates = [root]
            }
        default:
            candidates = []
        }
        return candidates.compactMap { Self.result(from: $0, fallbackLabel: fallbackLabel) }
    }

    private static func result(from value: JSONValue, fallbackLabel: String) -> GeocodeResult? {
        guard case .object(let dict) = value else { return nil }
        func number(_ keys: [String]) -> Double? {
            for key in keys {
                switch dict[key] {
                case .number(let n)?: return n
                case .string(let s)?: if let n = Double(s) { return n }
                default: continue
                }
            }
            return nil
        }
        func string(_ keys: [String]) -> String? {
            for key in keys { if case .string(let s)? = dict[key], !s.isEmpty { return s } }
            return nil
        }
        var lat = number(["lat", "latitude", "y"])
        var lng = number(["lng", "lon", "longitude", "x"])
        if lat == nil || lng == nil, case .object(let coords)? = dict["coordinates"] ?? dict["location"] {
            let nested = JSONValue.object(coords)
            if let inner = result(from: nested, fallbackLabel: fallbackLabel) {
                lat = inner.point.latitude
                lng = inner.point.longitude
            }
        }
        guard let lat, let lng, (-90...90).contains(lat), (-180...180).contains(lng) else { return nil }
        let label = string(["label", "formatted", "formatted_address", "address", "name", "matchedAddress"]) ?? fallbackLabel
        return GeocodeResult(label: label, point: GeoPoint(latitude: lat, longitude: lng))
    }
}
