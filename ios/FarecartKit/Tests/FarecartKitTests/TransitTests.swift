import Foundation
import Testing
@testable import FarecartKit

private let en = Locale(identifier: "en_US")

// MARK: - Polyline

/// Reference encoder (Google's algorithm) so tests can round-trip at any precision.
private func encodePolyline(_ points: [Coordinate], precision: Int) -> String {
    let factor = pow(10.0, Double(precision))
    var out = ""
    var lastLat = 0
    var lastLng = 0
    func append(_ value: Int) {
        var v = value < 0 ? ~(value << 1) : (value << 1)
        while v >= 0x20 {
            out.append(Character(UnicodeScalar((0x20 | (v & 0x1F)) + 63)!))
            v >>= 5
        }
        out.append(Character(UnicodeScalar(v + 63)!))
    }
    for point in points {
        let lat = Int((point.latitude * factor).rounded())
        let lng = Int((point.longitude * factor).rounded())
        append(lat - lastLat)
        append(lng - lastLng)
        lastLat = lat
        lastLng = lng
    }
    return out
}

@Suite("Polyline decoding")
struct PolylineTests {
    @Test("Google's documented vector decodes at precision 5")
    func knownVector() {
        let points = Polyline.decode("_p~iF~ps|U_ulLnnqC_mqNvxq`@", precision: 5)
        #expect(points.count == 3)
        #expect(abs(points[0].latitude - 38.5) < 1e-9)
        #expect(abs(points[0].longitude - -120.2) < 1e-9)
        #expect(abs(points[1].latitude - 40.7) < 1e-9)
        #expect(abs(points[1].longitude - -120.95) < 1e-9)
        #expect(abs(points[2].latitude - 43.252) < 1e-9)
        #expect(abs(points[2].longitude - -126.453) < 1e-9)
    }

    @Test("Round-trips Chicago coordinates at precision 7")
    func roundTripSeven() {
        let original = [
            Coordinate(latitude: 41.8807, longitude: -87.7262),
            Coordinate(latitude: 41.88062, longitude: -87.72583),
            Coordinate(latitude: 41.8819, longitude: -87.6868),
        ]
        let decoded = Polyline.decode(encodePolyline(original, precision: 7), precision: 7)
        #expect(decoded.count == 3)
        for (a, b) in zip(original, decoded) {
            #expect(abs(a.latitude - b.latitude) < 1e-6)
            #expect(abs(a.longitude - b.longitude) < 1e-6)
        }
    }

    @Test("Detects precision 7 (MOTIS default) when the line lands in Chicago")
    func detectsSeven() {
        let encoded = encodePolyline([Coordinate(latitude: 41.8807, longitude: -87.7262)], precision: 7)
        let decoded = Polyline.decodeDetectingPrecision(encoded)
        #expect(decoded.count == 1)
        #expect(abs(decoded[0].latitude - 41.8807) < 1e-6)
        #expect(Polyline.BoundingBox.chicago.contains(decoded[0]))
    }

    @Test("Falls back to precision 5 when precision 7 lands outside Chicago")
    func fallsBackToFive() {
        let encoded = encodePolyline([Coordinate(latitude: 41.8807, longitude: -87.7262)], precision: 5)
        // Decoded as 7 this would be lat 0.418807, clearly not Chicago.
        #expect(!Polyline.BoundingBox.chicago.contains(Polyline.decode(encoded, precision: 7)[0]))
        let decoded = Polyline.decodeDetectingPrecision(encoded)
        #expect(abs(decoded[0].latitude - 41.8807) < 1e-5)
        #expect(abs(decoded[0].longitude - -87.7262) < 1e-5)
    }

    @Test("An explicit precision that lands outside Chicago is not trusted")
    func wrongExplicitPrecision() {
        let encoded = encodePolyline([Coordinate(latitude: 41.8807, longitude: -87.7262)], precision: 5)
        let decoded = Polyline.decodeDetectingPrecision(encoded, precision: 7)
        #expect(abs(decoded[0].latitude - 41.8807) < 1e-5)
    }

    @Test("Garbage and empty input yield nothing rather than crashing")
    func garbage() {
        #expect(Polyline.decode("", precision: 7).isEmpty)
        #expect(Polyline.decode("_p~iF", precision: 5).isEmpty)  // one value only, no pair
    }
}

// MARK: - Trip cost

private let cta = "Chicago Transit Authority"
private let t0 = Date(timeIntervalSince1970: 1_792_000_000)

private func stop(_ name: String, minutes: Int) -> TransitStop {
    TransitStop(name: name, coordinate: .westSideChicago, time: t0.addingTimeInterval(TimeInterval(minutes * 60)))
}

private func walk(minutes: Int, from: Int) -> TransitLeg {
    TransitLeg(mode: .walk, from: stop("a", minutes: from), to: stop("b", minutes: from + minutes), duration: TimeInterval(minutes * 60))
}

private func ride(_ mode: TransitLegMode, route: String, agency: String = cta, boardAt: Int, minutes: Int) -> TransitLeg {
    TransitLeg(
        mode: mode, routeShortName: route, headsign: "Downtown", agencyName: agency,
        from: stop("board", minutes: boardAt), to: stop("alight", minutes: boardAt + minutes),
        duration: TimeInterval(minutes * 60)
    )
}

private func itinerary(_ legs: [TransitLeg]) -> TransitItinerary {
    TransitItinerary(duration: legs.reduce(0) { $0 + $1.duration }, startTime: t0, endTime: t0.addingTimeInterval(3600), transfers: max(0, legs.filter { $0.mode.isTransit }.count - 1), legs: legs)
}

@Suite("Trip cost rule")
struct TripFareTests {
    let calculator = TripFareCalculator(fares: BundledFallbacks.fares)

    @Test("Bus only: one bus fare")
    func busOnly() {
        let trip = itinerary([walk(minutes: 4, from: 0), ride(.bus, route: "20", boardAt: 4, minutes: 11), walk(minutes: 3, from: 15)])
        let full = calculator.cost(of: trip, rider: .full)
        #expect(full.riderCents == 225)
        #expect(full.fullCents == 225)
        #expect(full.savingsCents == 0)
        #expect(full.boardings == 1)
        #expect(full.notes.isEmpty)
        #expect(!full.hasDiscount)
        #expect(full.priceText(locale: en) == "$2.25")
    }

    @Test("Train first, then bus: train fare plus a free transfer")
    func trainThenBus() {
        let trip = itinerary([ride(.train, route: "Blue", boardAt: 0, minutes: 10), walk(minutes: 2, from: 10), ride(.bus, route: "49", boardAt: 12, minutes: 8)])
        let full = calculator.cost(of: trip, rider: .full)
        #expect(full.riderCents == 250)
        #expect(full.boardings == 2)
        let access = calculator.cost(of: trip, rider: .reducedAccess)
        #expect(access.riderCents == 125)
        #expect(access.fullCents == 250)
        #expect(access.savingsCents == 125)
    }

    @Test("Bus first, then train: bus fare covers the rail transfer")
    func busThenTrain() {
        let trip = itinerary([ride(.bus, route: "20", boardAt: 0, minutes: 10), ride(.train, route: "Blue", boardAt: 12, minutes: 10)])
        #expect(calculator.cost(of: trip, rider: .full).riderCents == 225)
    }

    @Test("Three boardings within two hours are one fare")
    func threeBoardings() {
        let trip = itinerary([ride(.bus, route: "20", boardAt: 0, minutes: 10), ride(.bus, route: "49", boardAt: 15, minutes: 10), ride(.bus, route: "66", boardAt: 30, minutes: 10)])
        let cost = calculator.cost(of: trip, rider: .full)
        #expect(cost.riderCents == 225)
        #expect(cost.boardings == 3)
    }

    @Test("Four boardings: the fourth starts a second fare")
    func fourBoardings() {
        let trip = itinerary([
            ride(.bus, route: "20", boardAt: 0, minutes: 10),
            ride(.bus, route: "49", boardAt: 15, minutes: 10),
            ride(.bus, route: "66", boardAt: 30, minutes: 10),
            ride(.train, route: "Blue", boardAt: 45, minutes: 10),
        ])
        let full = calculator.cost(of: trip, rider: .full)
        #expect(full.riderCents == 225 + 250)
        #expect(full.boardings == 4)
        let access = calculator.cost(of: trip, rider: .reducedAccess)
        #expect(access.riderCents == 110 + 125)
        #expect(access.savingsCents == 475 - 235)
    }

    @Test("A boarding outside the transfer window starts a new fare")
    func windowExpired() {
        let trip = itinerary([ride(.bus, route: "20", boardAt: 0, minutes: 10), ride(.bus, route: "49", boardAt: 125, minutes: 10)])
        #expect(calculator.cost(of: trip, rider: .full).riderCents == 450)
        let inside = itinerary([ride(.bus, route: "20", boardAt: 0, minutes: 10), ride(.bus, route: "49", boardAt: 119, minutes: 10)])
        #expect(calculator.cost(of: inside, rider: .full).riderCents == 225)
    }

    @Test("Walk-only trip is free")
    func walkOnly() {
        let trip = itinerary([walk(minutes: 12, from: 0)])
        let cost = calculator.cost(of: trip, rider: .reducedAccess)
        #expect(cost.riderCents == 0)
        #expect(cost.fullCents == 0)
        #expect(cost.boardings == 0)
        #expect(cost.isFree)
        #expect(!cost.hasDiscount)
        #expect(trip.isWalkOnly)
    }

    @Test("Non-CTA leg is flagged and not priced")
    func nonCTA() {
        let trip = itinerary([ride(.bus, route: "20", boardAt: 0, minutes: 10), ride(.bus, route: "307", agency: "Pace", boardAt: 15, minutes: 20)])
        let cost = calculator.cost(of: trip, rider: .full)
        #expect(cost.riderCents == 225)
        #expect(cost.boardings == 1)
        #expect(cost.includesNonCTALeg)
        #expect(cost.note == "Includes a non-CTA leg; fare not included")
        let metraOnly = itinerary([ride(.train, route: "UP-W", agency: "Metra", boardAt: 0, minutes: 30)])
        let metraCost = calculator.cost(of: metraOnly, rider: .full)
        #expect(metraCost.riderCents == 0)
        #expect(metraCost.includesNonCTALeg)
    }

    @Test("Student rider pays $0.75 on bus and train; Access rider pays the Access price")
    func riders() {
        let trip = itinerary([ride(.train, route: "Green", boardAt: 0, minutes: 10)])
        let student = calculator.cost(of: trip, rider: .student)
        #expect(student.riderCents == 75)
        #expect(student.fullCents == 250)
        #expect(student.savingsCents == 175)
        #expect(student.hasDiscount)
        let access = calculator.cost(of: trip, rider: .reducedAccess)
        #expect(access.riderCents == 125)
        #expect(access.priceText(locale: en) == "$1.25")
        #expect(access.fullPriceText(locale: en) == "$2.50")
    }

    @Test("Discounts answers pick Access before Student; no answers means full fare")
    func fromAnswers() {
        let trip = itinerary([ride(.bus, route: "20", boardAt: 0, minutes: 10)])
        #expect(calculator.cost(of: trip, answers: EligibilityAnswers(householdReceivesSNAP: true, isK12Student: true)).rider == .reducedAccess)
        #expect(calculator.cost(of: trip, answers: EligibilityAnswers(isK12Student: true)).rider == .student)
        #expect(calculator.cost(of: trip, answers: .none).rider == .full)
        #expect(calculator.cost(of: trip, answers: .none).riderCents == 225)
    }

    @Test("Rider without a row for a mode pays full fare for that boarding")
    func seniorFallsBackToFull() {
        let trip = itinerary([ride(.bus, route: "20", boardAt: 0, minutes: 10)])
        #expect(calculator.cost(of: trip, rider: .seniorDisabled).riderCents == 225)
    }

    @Test("Transfer rules come from the fares rows, not constants")
    func rulesFromData() {
        let paid = BundledFallbacks.fares.map { fare in
            var f = fare
            f.transferCents = 25
            f.maxTransfers = 1
            return f
        }
        let calc = TripFareCalculator(fares: paid)
        let trip = itinerary([ride(.bus, route: "20", boardAt: 0, minutes: 10), ride(.bus, route: "49", boardAt: 15, minutes: 10), ride(.bus, route: "66", boardAt: 30, minutes: 10)])
        #expect(calc.cost(of: trip, rider: .full).riderCents == 225 + 25 + 225)
    }

    @Test("Fare rows decode the transfer columns and default them when absent")
    func fareDecoding() throws {
        let json = """
        [{"id":1,"agency":"CTA","mode":"bus","rider":"full","price_cents":225,"label":"Full fare bus",
          "transfer_cents":0,"transfer_window_min":120,"max_transfers":2,"effective_on":"2023-02-20"},
         {"id":2,"agency":"CTA","mode":"train","rider":"full","price_cents":250,"label":"Full fare train"}]
        """
        let fares = try PostgRESTDecoder.decode([Fare].self, from: Data(json.utf8))
        #expect(fares[0].transferWindowMinutes == 120)
        #expect(fares[0].maxTransfers == 2)
        #expect(fares[0].transferCents == 0)
        #expect(fares[1].transferWindowMinutes == 120)
        #expect(fares[1].maxTransfers == 2)
    }
}

// MARK: - Transitous

@Suite("Transitous decoding")
struct TransitousTests {
    private func fixture() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "transitous_plan", withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    @Test("Real /plan response from Madison & Pulaski to Pete's Fresh Market decodes")
    func decodesFixture() throws {
        let itineraries = try TransitRouter.decodeItineraries(from: fixture())
        #expect(itineraries.count == 3)
        let first = try #require(itineraries.first)
        #expect(first.duration == 1080)
        #expect(first.durationMinutes == 18)
        #expect(first.transfers == 0)
        #expect(first.legs.count == 3)
        #expect(first.legs.map(\.mode) == [.walk, .bus, .train].dropLast() + [.walk])
        #expect(first.busCount == 1)
        #expect(first.trainCount == 0)
        #expect(!first.isWalkOnly)
        #expect(first.startTime == ISO8601.parse("2026-10-16T01:23:00Z"))
        #expect(first.endTime == ISO8601.parse("2026-10-16T01:41:00Z"))
        #expect(Set(itineraries.map(\.id)).count == 3)

        let bus = first.legs[1]
        #expect(bus.routeShortName == "20")
        #expect(bus.headsign == "Michigan")
        #expect(bus.agencyName == "Chicago Transit Authority")
        #expect(bus.isCTA)
        #expect(bus.routeColorHex == "414145")
        #expect(bus.from.name == "Madison & Pulaski")
        #expect(bus.to.name == "Madison & Western")
        #expect(bus.duration == 660)
        #expect(bus.intermediateStopCount == 13)
        #expect(bus.from.time == ISO8601.parse("2026-10-16T01:27:00Z"))
        #expect(bus.polyline.count > 10)
        #expect(bus.polyline.allSatisfy { Polyline.BoundingBox.chicago.contains($0) })

        let walkIn = first.legs[0]
        #expect(walkIn.from.name == "START")
        #expect(abs(walkIn.from.coordinate.latitude - 41.8807) < 1e-6)
        #expect(walkIn.polyline.count == 10)
        #expect(walkIn.routeShortName == nil)
        #expect(!walkIn.isCTA)
        #expect(first.legs[2].to.name == "END")
    }

    @Test("Trip cost for the fixture: one bus")
    func fixtureCost() throws {
        let trip = try #require(TransitRouter.decodeItineraries(from: fixture()).first)
        let calc = TripFareCalculator(fares: BundledFallbacks.fares)
        let access = calc.cost(of: trip, rider: .reducedAccess)
        #expect(access.riderCents == 110)
        #expect(access.fullCents == 225)
        #expect(access.savingsCents == 115)
        #expect(access.boardings == 1)
        #expect(access.notes.isEmpty)
    }

    @Test("Unknown modes, missing fields and extra keys are tolerated")
    func tolerant() throws {
        let json = """
        {"itineraries":[{"duration":600,"transfers":0,"surprise":true,
          "legs":[{"mode":"FERRY","from":{"name":"A","lat":41.88,"lon":-87.72},"to":{"name":"B","lat":41.89,"lon":-87.70},
                   "agencyName":"Pace","legGeometry":{"points":"","precision":7}},
                  {"mode":"WALK","from":{"lat":1}}]}],"nextPageCursor":"x"}
        """
        let itineraries = try TransitRouter.decodeItineraries(from: Data(json.utf8))
        #expect(itineraries.count == 1)
        let legs = try #require(itineraries.first?.legs)
        #expect(legs.count == 1)  // the leg without coordinates is dropped
        #expect(legs[0].mode == .other)
        #expect(legs[0].polyline.isEmpty)
        #expect(!legs[0].isCTA)
        #expect(TransitLegMode(motisMode: "SUBWAY") == .train)
        #expect(TransitLegMode(motisMode: "RAIL") == .train)
        #expect(TransitLegMode(motisMode: "TRAM") == .train)
        #expect(TransitLegMode(motisMode: "METRO") == .train)
        #expect(TransitLegMode(motisMode: "bus") == .bus)
        #expect(TransitLegMode(motisMode: nil) == .other)
    }

    @Test("Empty plan decodes to no itineraries; itineraries without legs are dropped")
    func empty() throws {
        #expect(try TransitRouter.decodeItineraries(from: Data("{}".utf8)).isEmpty)
        #expect(try TransitRouter.decodeItineraries(from: Data(#"{"itineraries":[{"duration":5,"legs":[]}]}"#.utf8)).isEmpty)
    }

    @Test("Request goes to /api/v1/plan with the Farecart User-Agent")
    func request() async throws {
        let recorder = RecordingTransport(body: try fixture())
        let router = TransitRouter(transport: recorder)
        let result = try await router.plan(from: GeoPoint(latitude: 41.8807, longitude: -87.7262), to: GeoPoint(latitude: 41.8819, longitude: -87.6868), departAt: nil, maxItineraries: 3)
        #expect(result.count == 3)
        let request = try #require(await recorder.requests.first)
        let url = try #require(request.url?.absoluteString)
        #expect(url.hasPrefix("https://api.transitous.org/api/v1/plan?"))
        #expect(url.contains("fromPlace=41.880700,-87.726200"))
        #expect(url.contains("toPlace=41.881900,-87.686800"))
        #expect(url.contains("numItineraries=3"))
        #expect(!url.contains("arriveBy"))
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Farecart/0.1 (hello@farecart.org)")
    }

    @Test("Server errors surface as APIError.httpStatus")
    func serverError() async throws {
        let recorder = RecordingTransport(body: Data("oops".utf8), status: 503)
        let router = TransitRouter(transport: recorder)
        await #expect(throws: APIError.self) {
            _ = try await router.plan(from: .westSideChicago, to: .westSideChicago, departAt: nil, maxItineraries: 3)
        }
    }
}

/// Captures requests and answers with a fixed body.
private actor RecordingTransport: HTTPTransport {
    private(set) var requests: [URLRequest] = []
    private let body: Data
    private let status: Int

    init(body: Data, status: Int = 200) {
        self.body = body
        self.status = status
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }
}
