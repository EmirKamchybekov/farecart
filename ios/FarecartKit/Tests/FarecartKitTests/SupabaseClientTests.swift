import Foundation
import Testing
@testable import FarecartKit

/// Records requests and replays canned responses.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { _requests } }
    let status: Int
    let body: Data

    init(status: Int = 200, body: String) {
        self.status = status
        self.body = Data(body.utf8)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { _requests.append(request) }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }
}

@Suite("SupabaseClient")
struct SupabaseClientTests {
    let baseURL = URL(string: "https://example.supabase.co")!

    @Test("nearby_locations posts the RPC body with headers")
    func nearby() async throws {
        let transport = StubTransport(body: DecodingTests.nearbyJSON)
        let client = SupabaseClient(baseURL: baseURL, anonKey: "anon-key", transport: transport)
        let places = try await client.nearbyLocations(around: .westSideChicago, types: [.grocery, .pantry], limit: 10, radiusMeters: 8047)
        #expect(places.count == 4)

        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://example.supabase.co/rest/v1/rpc/nearby_locations")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "apikey") == "anon-key")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer anon-key")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: Any]
        #expect(body?["p_lat"] as? Double == 41.8807)
        #expect(body?["p_lng"] as? Double == -87.7262)
        #expect(body?["p_limit"] as? Double == 10)
        #expect(body?["p_radius_m"] as? Double == 8047)
        #expect(body?["p_types"] as? [String] == ["grocery", "pantry"])
    }

    @Test("Filter 'All' omits p_types so the RPC default applies")
    func allFilter() async throws {
        let transport = StubTransport(body: "[]")
        let client = SupabaseClient(baseURL: baseURL, anonKey: "k", transport: transport)
        _ = try await client.nearbyPlaces(around: .westSideChicago, filter: .all, radius: .fiveMiles, limit: 25)
        let body = try JSONSerialization.jsonObject(with: try #require(transport.requests.first?.httpBody)) as? [String: Any]
        #expect(body?["p_types"] == nil)
        #expect(body?["p_radius_m"] as? Double == 8047)
    }

    @Test("fares and programs use GET with select=*")
    func tables() async throws {
        let transport = StubTransport(body: "[]")
        let client = SupabaseClient(baseURL: baseURL, anonKey: "k", transport: transport)
        _ = try await client.fares()
        _ = try await client.programs()
        let urls = transport.requests.compactMap { $0.url?.absoluteString }
        #expect(urls[0].hasPrefix("https://example.supabase.co/rest/v1/fares?"))
        #expect(urls[0].contains("select=*"))
        #expect(urls[1].hasPrefix("https://example.supabase.co/rest/v1/programs?"))
        #expect(transport.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test("Non-2xx becomes APIError.httpStatus")
    func httpError() async {
        let transport = StubTransport(status: 401, body: #"{"message":"bad key"}"#)
        let client = SupabaseClient(baseURL: baseURL, anonKey: "k", transport: transport)
        await #expect(throws: APIError.self) {
            _ = try await client.fares()
        }
    }
}

@Suite("RemoteGeocoder")
struct RemoteGeocoderTests {
    @Test("Parses several plausible response shapes")
    func shapes() throws {
        let flat = #"{"lat":41.88,"lng":-87.72,"label":"Garfield Park"}"#
        let r1 = try RemoteGeocoder.parse(Data(flat.utf8), fallbackLabel: "q")
        #expect(r1.first?.label == "Garfield Park")
        #expect(r1.first?.point == GeoPoint(latitude: 41.88, longitude: -87.72))

        let wrapped = #"{"results":[{"latitude":"41.9","longitude":"-87.7","formatted_address":"X"},{"foo":1}]}"#
        let r2 = try RemoteGeocoder.parse(Data(wrapped.utf8), fallbackLabel: "q")
        #expect(r2.count == 1)
        #expect(r2.first?.label == "X")

        let bare = #"[{"coordinates":{"x":-87.65,"y":41.85}}]"#
        let r3 = try RemoteGeocoder.parse(Data(bare.utf8), fallbackLabel: "typed text")
        #expect(r3.first?.label == "typed text")
        #expect(r3.first?.point.latitude == 41.85)

        let out = #"{"lat":100,"lng":0}"#
        #expect(try RemoteGeocoder.parse(Data(out.utf8), fallbackLabel: "q").isEmpty)
    }

    @Test("Builds the geocode URL")
    func url() async throws {
        let transport = StubTransport(body: #"{"lat":1,"lng":2}"#)
        let geocoder = RemoteGeocoder(baseURL: URL(string: "https://api.farecart.org")!, transport: transport)
        _ = try await geocoder.geocode("  4343 W Madison St ")
        #expect(transport.requests.first?.url?.absoluteString == "https://api.farecart.org/geocode?q=4343%20W%20Madison%20St")
    }
}

@Suite("FallbackGeocoder")
struct FallbackGeocoderTests {
    struct Fixed: Geocoding {
        let results: [GeocodeResult]
        let error: GeocodingError?
        func geocode(_ query: String) async throws -> [GeocodeResult] {
            if let error { throw error }
            return results
        }
    }

    let apple = Fixed(results: [GeocodeResult(label: "Apple", point: .westSideChicago)], error: nil)

    @Test("Uses primary when it answers")
    func primary() async throws {
        let api = Fixed(results: [GeocodeResult(label: "API", point: .westSideChicago)], error: nil)
        let results = try await FallbackGeocoder(primary: api, fallback: apple).geocode("x")
        #expect(results.first?.label == "API")
    }

    @Test("Falls back when primary is missing, empty, or throws")
    func fallback() async throws {
        #expect(try await FallbackGeocoder(primary: nil, fallback: apple).geocode("x").first?.label == "Apple")
        let empty = Fixed(results: [], error: nil)
        #expect(try await FallbackGeocoder(primary: empty, fallback: apple).geocode("x").first?.label == "Apple")
        let broken = Fixed(results: [], error: .noResults)
        #expect(try await FallbackGeocoder(primary: broken, fallback: apple).geocode("x").first?.label == "Apple")
    }

    @Test("Empty query and no results throw")
    func errors() async {
        await #expect(throws: GeocodingError.emptyQuery) {
            _ = try await FallbackGeocoder(primary: nil, fallback: apple).geocode("   ")
        }
        await #expect(throws: GeocodingError.noResults) {
            _ = try await FallbackGeocoder(primary: nil, fallback: Fixed(results: [], error: nil)).geocode("x")
        }
    }
}
