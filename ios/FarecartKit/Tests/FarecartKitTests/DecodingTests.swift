import Foundation
import Testing
@testable import FarecartKit

@Suite("PostgREST decoding")
struct DecodingTests {
    static let nearbyJSON = """
    [{"id":"5f1d0a1e-9d2f-4b1c-8f4a-1c2d3e4f5a6b","name":"Pete's Fresh Market","type":"grocery",
      "address":"4343 W Madison St","neighborhood":"West Garfield Park","lat":41.8807,"lng":-87.7355,
      "hours":{"mon":"7:00-22:00","notes":{"holiday":"varies"},"count":3},"hours_text":"Daily 7am-10pm",
      "accepts_ebt":true,"requirements":null,"languages":["en","es"],"phone":"773-555-0177",
      "website":"https://example.org","source_url":"https://example.org/src","notes":null,
      "verified_on":"2026-09-28","distance_m":812.5},
     {"id":"6f1d0a1e-9d2f-4b1c-8f4a-1c2d3e4f5a6c","name":"Pantry","type":"pantry",
      "address":"1 Main","neighborhood":null,"lat":41.9,"lng":-87.7,"hours":null,"hours_text":null,
      "accepts_ebt":null,"requirements":"ID","languages":null,"phone":null,"website":null,
      "source_url":null,"notes":null,"verified_on":null,"distance_m":1500}]
    """

    @Test("nearby_locations rows decode, tolerating jsonb hours and nulls")
    func decodePlaces() throws {
        let places = try PostgRESTDecoder.decode([Place].self, from: Data(Self.nearbyJSON.utf8))
        #expect(places.count == 2)
        let first = places[0]
        #expect(first.name == "Pete's Fresh Market")
        #expect(first.type == .grocery)
        #expect(first.hours == ["mon": "7:00-22:00"])   // non-string values dropped
        #expect(first.acceptsEBT == true)
        #expect(first.languages == ["en", "es"])
        #expect(first.distanceMeters == 812.5)
        #expect(first.isVerified)
        #expect(first.verifiedOn.map(PostgresDate.string(from:)) == "2026-09-28")
        #expect(first.phoneURL?.absoluteString == "tel:7735550177")
        #expect(first.websiteURL?.host() == "example.org")

        let second = places[1]
        #expect(second.hours == nil)
        #expect(second.languages.isEmpty)
        #expect(second.verifiedOn == nil)
        #expect(!second.isVerified)
        #expect(second.phoneURL == nil)
    }

    @Test("Place round-trips through Codable")
    func roundTrip() throws {
        let original = MockData.places[0]
        let data = try JSONEncoder().encode(original)
        let decoded = try PostgRESTDecoder.decode(Place.self, from: data)
        #expect(decoded == original)
    }

    @Test("fares and programs decode from seed-shaped JSON")
    func decodeFaresAndPrograms() throws {
        let faresJSON = """
        [{"id":3,"agency":"CTA","mode":"bus","rider":"reduced_access","price_cents":110,
          "label":"Access reduced fare bus","how_to_get":"Apply","signup_url":"https://getaccess.org",
          "effective_on":"2026-10-01","source_url":"https://nita.illinois.gov/riders/access"}]
        """
        let fares = try PostgRESTDecoder.decode([Fare].self, from: Data(faresJSON.utf8))
        #expect(fares.first?.rider == .reducedAccess)
        #expect(fares.first?.priceCents == 110)
        #expect(fares.first?.effectiveOn == PostgresDate.parse("2026-10-01"))

        let programsJSON = """
        [{"key":"access","name":"Access reduced fare","who":"SNAP households","what":"Half price",
          "how":"Apply online","signup_url":"https://getaccess.org","phone":"312-913-3110",
          "source_url":"https://nita.illinois.gov/riders/access","updated_at":"2026-10-01T00:00:00+00:00"}]
        """
        let programs = try PostgRESTDecoder.decode([Program].self, from: Data(programsJSON.utf8))
        #expect(programs.first?.key == "access")
        #expect(programs.first?.signupLink?.absoluteString == "https://getaccess.org")
        #expect(programs.first?.phoneURL?.absoluteString == "tel:3129133110")
    }

    @Test("Decoding errors are wrapped with a readable path")
    func decodingErrorMessage() {
        let bad = Data(#"[{"id":"not-a-uuid","name":"x"}]"#.utf8)
        #expect(throws: APIError.self) {
            try PostgRESTDecoder.decode([Place].self, from: bad)
        }
    }

    @Test("Postgres date parsing accepts date-only and timestamps")
    func dates() {
        #expect(PostgresDate.parse("2026-10-01") != nil)
        #expect(PostgresDate.parse("2026-10-01T12:34:56Z") != nil)
        #expect(PostgresDate.parse("2026-10-01T12:34:56.123Z") != nil)
        #expect(PostgresDate.parse("yesterday") == nil)
    }
}
