import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Anything that can plan a transit trip. The app talks to this so previews and the debug
/// launch path can swap in canned itineraries.
public protocol TransitRouting: Sendable {
    func plan(from origin: GeoPoint, to destination: GeoPoint, departAt: Date?, maxItineraries: Int) async throws -> [TransitItinerary]
}

public enum TransitRouterError: Error, Sendable, LocalizedError {
    case noItineraries

    public var errorDescription: String? {
        switch self {
        case .noItineraries: "No transit route found."
        }
    }
}

/// Transitous (community MOTIS instance, no key). `GET /api/v1/plan?fromPlace=LAT,LNG&toPlace=LAT,LNG`.
/// Decoding is tolerant: every field is optional and unknown keys are ignored, because the
/// instance has no SLA and its response shape has drifted before.
public struct TransitRouter: TransitRouting {
    public static let defaultBaseURL = URL(string: "https://api.transitous.org")!
    public static let userAgent = "Farecart/0.1 (hello@farecart.org)"

    public let baseURL: URL
    public let transport: any HTTPTransport

    public init(baseURL: URL = TransitRouter.defaultBaseURL, transport: any HTTPTransport = URLSessionTransport()) {
        self.baseURL = baseURL
        self.transport = transport
    }

    public func plan(
        from origin: GeoPoint,
        to destination: GeoPoint,
        departAt: Date? = nil,
        maxItineraries: Int = 3
    ) async throws -> [TransitItinerary] {
        let request = try makeRequest(from: origin, to: destination, departAt: departAt, maxItineraries: maxItineraries)
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw APIError.httpStatus(response.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        return try Self.decodeItineraries(from: data)
    }

    func makeRequest(from origin: GeoPoint, to destination: GeoPoint, departAt: Date?, maxItineraries: Int) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL.appending(path: "api/v1/plan"), resolvingAgainstBaseURL: false) else {
            throw APIError.invalidResponse
        }
        var query = [
            URLQueryItem(name: "fromPlace", value: Self.placeString(origin)),
            URLQueryItem(name: "toPlace", value: Self.placeString(destination)),
            URLQueryItem(name: "numItineraries", value: String(max(1, maxItineraries))),
        ]
        if let departAt {
            query.append(URLQueryItem(name: "time", value: departAt.formatted(.iso8601)))
            query.append(URLQueryItem(name: "arriveBy", value: "false"))
        }
        components.queryItems = query
        guard let url = components.url else { throw APIError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func placeString(_ point: GeoPoint) -> String {
        String(format: "%.6f,%.6f", locale: Locale(identifier: "en_US_POSIX"), point.latitude, point.longitude)
    }

    // MARK: Decoding

    public static func decodeItineraries(from data: Data) throws -> [TransitItinerary] {
        let plan: PlanResponse
        do {
            plan = try JSONDecoder().decode(PlanResponse.self, from: data)
        } catch let error as DecodingError {
            throw APIError.decoding(PostgRESTDecoder.describe(error))
        }
        return (plan.itineraries ?? []).enumerated().compactMap { index, raw in raw.itinerary(index: index) }
    }

    struct PlanResponse: Decodable {
        var itineraries: [RawItinerary]?
    }

    struct RawItinerary: Decodable {
        var duration: Double?
        var startTime: String?
        var endTime: String?
        var transfers: Int?
        var legs: [RawLeg]?

        func itinerary(index: Int) -> TransitItinerary? {
            let legs = (self.legs ?? []).enumerated().compactMap { legIndex, raw in raw.leg(index: legIndex, itinerary: index) }
            guard !legs.isEmpty else { return nil }
            let start = ISO8601.parse(startTime) ?? legs.first?.from.time ?? Date()
            let end = ISO8601.parse(endTime) ?? legs.last?.to.time ?? start.addingTimeInterval(duration ?? 0)
            let seconds = duration ?? end.timeIntervalSince(start)
            let transferCount = transfers ?? max(0, legs.filter { $0.mode.isTransit }.count - 1)
            return TransitItinerary(
                id: "\(index)-\(ISO8601.string(start))-\(Int(seconds))",
                duration: seconds,
                startTime: start,
                endTime: end,
                transfers: transferCount,
                legs: legs
            )
        }
    }

    struct RawPlace: Decodable {
        var name: String?
        var lat: Double?
        var lon: Double?
        var departure: String?
        var arrival: String?
        var scheduledDeparture: String?
        var scheduledArrival: String?
    }

    struct RawGeometry: Decodable {
        var points: String?
        var precision: Int?
    }

    struct RawLeg: Decodable {
        var mode: String?
        var from: RawPlace?
        var to: RawPlace?
        var duration: Double?
        var startTime: String?
        var endTime: String?
        var headsign: String?
        var routeShortName: String?
        var routeLongName: String?
        var routeColor: String?
        var agencyName: String?
        var legGeometry: RawGeometry?
        var intermediateStops: [RawPlace]?

        func leg(index: Int, itinerary: Int) -> TransitLeg? {
            guard let from, let to, let fromLat = from.lat, let fromLon = from.lon, let toLat = to.lat, let toLon = to.lon else {
                return nil
            }
            let start = ISO8601.parse(from.departure) ?? ISO8601.parse(startTime) ?? ISO8601.parse(from.scheduledDeparture)
            let end = ISO8601.parse(to.arrival) ?? ISO8601.parse(endTime) ?? ISO8601.parse(to.scheduledArrival)
            let seconds: TimeInterval
            if let duration {
                seconds = duration
            } else if let start, let end {
                seconds = end.timeIntervalSince(start)
            } else {
                seconds = 0
            }
            let polyline = legGeometry?.points.map { Polyline.decodeDetectingPrecision($0, precision: legGeometry?.precision) } ?? []
            let color = routeColor?.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).uppercased()
            return TransitLeg(
                id: "\(itinerary)-\(index)",
                mode: TransitLegMode(motisMode: mode),
                routeShortName: routeShortName.nonEmpty,
                routeLongName: routeLongName.nonEmpty,
                headsign: headsign.nonEmpty,
                agencyName: agencyName.nonEmpty,
                from: TransitStop(name: from.name ?? "", coordinate: Coordinate(latitude: fromLat, longitude: fromLon), time: start),
                to: TransitStop(name: to.name ?? "", coordinate: Coordinate(latitude: toLat, longitude: toLon), time: end),
                duration: seconds,
                routeColorHex: (color?.count == 6) ? color : nil,
                polyline: polyline,
                intermediateStopCount: intermediateStops?.count ?? 0
            )
        }
    }
}

/// MOTIS timestamps look like `2026-10-16T01:23:00Z`; be lenient about fractional seconds.
enum ISO8601 {
    static func parse(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: false).parse(string) { return date }
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) { return date }
        return nil
    }

    static func string(_ date: Date) -> String {
        date.formatted(.iso8601)
    }
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let self else { return nil }
        let trimmed = self.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
