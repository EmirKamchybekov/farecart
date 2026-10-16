import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Direct PostgREST access with the anon (publishable) key. Read-only; RLS allows public SELECT.
public struct SupabaseClient: Sendable {
    public let baseURL: URL
    public let anonKey: String
    public let transport: any HTTPTransport

    public init(baseURL: URL, anonKey: String, transport: any HTTPTransport = URLSessionTransport()) {
        self.baseURL = baseURL
        self.anonKey = anonKey
        self.transport = transport
    }

    public init(config: AppConfig, transport: any HTTPTransport = URLSessionTransport()) {
        self.init(baseURL: config.supabaseURL, anonKey: config.supabaseAnonKey, transport: transport)
    }

    // MARK: Endpoints

    /// `POST rest/v1/rpc/nearby_locations`
    public func nearbyLocations(
        around point: GeoPoint,
        types: [LocationType]? = nil,
        limit: Int = 25,
        radiusMeters: Int = 8000
    ) async throws -> [Place] {
        var body: [String: JSONValue] = [
            "p_lat": .number(point.latitude),
            "p_lng": .number(point.longitude),
            "p_limit": .number(Double(limit)),
            "p_radius_m": .number(Double(radiusMeters)),
        ]
        if let types, !types.isEmpty {
            body["p_types"] = .array(types.map { .string($0.rawValue) })
        }
        let request = try makeRequest(path: "rest/v1/rpc/nearby_locations", method: "POST", body: body)
        return try await perform(request)
    }

    /// `GET rest/v1/fares?select=*&order=mode,price_cents`
    public func fares() async throws -> [Fare] {
        let request = try makeRequest(
            path: "rest/v1/fares",
            query: [URLQueryItem(name: "select", value: "*"), URLQueryItem(name: "order", value: "mode.asc,price_cents.desc")]
        )
        return try await perform(request)
    }

    /// `GET rest/v1/programs?select=*`
    public func programs() async throws -> [Program] {
        let request = try makeRequest(
            path: "rest/v1/programs",
            query: [URLQueryItem(name: "select", value: "*"), URLQueryItem(name: "order", value: "key.asc")]
        )
        return try await perform(request)
    }

    // MARK: Plumbing

    func makeRequest(
        path: String,
        method: String = "GET",
        query: [URLQueryItem] = [],
        body: [String: JSONValue]? = nil
    ) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw APIError.invalidResponse
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw APIError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            request.httpBody = try encoder.encode(body)
        }
        return request
    }

    func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw APIError.httpStatus(response.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        return try PostgRESTDecoder.decode(T.self, from: data)
    }
}

extension SupabaseClient: FoodDataProviding {
    public func nearbyPlaces(around point: GeoPoint, filter: PlaceFilter, radius: SearchRadius, limit: Int) async throws -> [Place] {
        try await nearbyLocations(around: point, types: filter.types, limit: limit, radiusMeters: radius.meters)
    }
}
