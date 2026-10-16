import Foundation
import Testing
@testable import FarecartKit

private var chicago: Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/Chicago")!
    return cal
}

/// 2026-10-14 is a Wednesday.
private func date(_ weekdayOffset: Int = 0, hour: Int, minute: Int = 0) -> Date {
    let cal = chicago
    let base = cal.date(from: DateComponents(year: 2026, month: 10, day: 14 + weekdayOffset, hour: hour, minute: minute))!
    return base
}

@Suite("Opening hours")
struct HoursTests {
    @Test("Time parsing")
    func times() {
        #expect(HoursParser.parseTime("9") == MinuteOfDay(hour: 9, minute: 0))
        #expect(HoursParser.parseTime("9am") == MinuteOfDay(hour: 9, minute: 0))
        #expect(HoursParser.parseTime("9:30 PM") == MinuteOfDay(hour: 21, minute: 30))
        #expect(HoursParser.parseTime("12pm") == MinuteOfDay(hour: 12, minute: 0))
        #expect(HoursParser.parseTime("12am") == MinuteOfDay(hour: 0, minute: 0))
        #expect(HoursParser.parseTime("17:00") == MinuteOfDay(hour: 17, minute: 0))
        #expect(HoursParser.parseTime("noon") == MinuteOfDay(hour: 12, minute: 0))
        #expect(HoursParser.parseTime("25:00") == nil)
        #expect(HoursParser.parseTime("abc") == nil)
    }

    @Test("Range parsing")
    func ranges() {
        #expect(HoursParser.parseRanges("9:00-17:00") == [TimeRange(start: .init(hour: 9, minute: 0), end: .init(hour: 17, minute: 0))])
        #expect(HoursParser.parseRanges("9am – 5pm").first?.end == MinuteOfDay(hour: 17, minute: 0))
        #expect(HoursParser.parseRanges("Closed").isEmpty)
        #expect(HoursParser.parseRanges("8-12, 1pm-5pm").count == 2)
        #expect(HoursParser.parseRanges("call ahead").isEmpty)
    }

    @Test("Structured jsonb hours give open/closed status")
    func structured() throws {
        let weekly = try #require(WeeklyHours(json: ["mon": "9:00-17:00", "wed": "9:00-17:00", "Fri": "closed", "bogus": "1-2"]))
        #expect(weekly.days.keys.sorted() == [2, 4, 6])
        // Wednesday 10:00 → open until 17:00
        if case .open(let closesAt) = weekly.status(at: date(hour: 10), calendar: chicago) {
            #expect(chicago.component(.hour, from: try #require(closesAt)) == 17)
        } else {
            Issue.record("expected open")
        }
        // Wednesday 18:00 → closed, next open Monday 9:00
        if case .closed(let opensAt) = weekly.status(at: date(hour: 18), calendar: chicago) {
            let next = try #require(opensAt)
            #expect(chicago.component(.weekday, from: next) == 2)
            #expect(chicago.component(.hour, from: next) == 9)
        } else {
            Issue.record("expected closed")
        }
        // Wednesday 07:00 → closed, opens later today
        if case .closed(let opensAt) = weekly.status(at: date(hour: 7), calendar: chicago) {
            #expect(chicago.component(.weekday, from: try #require(opensAt)) == 4)
        } else {
            Issue.record("expected closed")
        }
    }

    @Test("Free-text hours parse")
    func freeText() throws {
        let weekly = try #require(WeeklyHours(text: "Mon–Fri 9am–5pm; Sat 10am-2pm"))
        #expect(Set(weekly.days.keys) == [2, 3, 4, 5, 6, 7])
        #expect(weekly.days[7]?.first?.start == MinuteOfDay(hour: 10, minute: 0))

        let daily = try #require(WeeklyHours(text: "Daily 7am–10pm"))
        #expect(daily.days.count == 7)

        let list = try #require(WeeklyHours(text: "Tue & Thu 10am–2pm"))
        // "&" is not a day separator in the day list; we accept "Tue, Thu". Make sure we at least don't crash
        // and get Tuesday.
        #expect(list.days[3] != nil)

        #expect(WeeklyHours(text: "2nd Saturday of the month, 10am until supplies run out") == nil)
        #expect(WeeklyHours(text: "") == nil)
    }

    @Test("Place.openStatus prefers structured hours and degrades to unknown")
    func placeStatus() {
        let grocery = MockData.places[0] // open daily-ish
        if case .open = grocery.openStatus(at: date(hour: 12), calendar: chicago) {} else { Issue.record("expected open") }
        let giveaway = MockData.places[2] // unparseable text
        #expect(giveaway.openStatus(at: date(hour: 12), calendar: chicago) == .unknown)
        let petes = MockData.places[3] // text only: Daily 7am–10pm
        if case .open = petes.openStatus(at: date(hour: 8), calendar: chicago) {} else { Issue.record("expected open") }
        if case .closed = petes.openStatus(at: date(hour: 23), calendar: chicago) {} else { Issue.record("expected closed") }
    }
}

@Suite("Distance")
struct DistanceTests {
    @Test func formatting() {
        let en = Locale(identifier: "en_US")
        #expect(Distance.milesText(meters: 1609.344, locale: en) == "1.0 mi")
        #expect(Distance.milesText(meters: 500, locale: en) == "0.3 mi")
        #expect(Distance.milesText(meters: 10, locale: en) == "0.1 mi")
        #expect(Distance.milesText(meters: 20_000, locale: en) == "12 mi")
    }

    @Test func haversine() {
        let a = GeoPoint(latitude: 41.8807, longitude: -87.7262)
        let b = GeoPoint(latitude: 41.8807, longitude: -87.7355)
        let d = a.distanceMeters(to: b)
        #expect(d > 700 && d < 800)
        #expect(a.distanceMeters(to: a) == 0)
    }

    @Test func radius() {
        #expect(SearchRadius.fiveMiles.meters == 8047)
        #expect(SearchRadius.fiveMiles.wider == .tenMiles)
        #expect(SearchRadius.twentyMiles.wider == nil)
        #expect(Distance.walkingMinutes(meters: 1609.344) == 20)
    }
}

@Suite("Deep links")
struct LinkTests {
    let point = GeoPoint(latitude: 41.8807, longitude: -87.7262)

    @Test func appleMaps() {
        let url = DirectionsLinks.appleMapsTransit(to: point)
        #expect(url.absoluteString == "maps://?daddr=41.880700,-87.726200&dirflg=r")
        let named = DirectionsLinks.appleMapsTransit(to: point, name: "Pete's")
        #expect(named.absoluteString.contains("daddr=Pete's@41.880700,-87.726200") || named.absoluteString.contains("daddr=Pete%27s@41.880700,-87.726200"))
    }

    @Test func googleMaps() {
        #expect(DirectionsLinks.googleMapsApp(to: point).absoluteString == "comgooglemaps://?daddr=41.880700,-87.726200&directionsmode=transit")
        #expect(DirectionsLinks.googleMapsWeb(to: point).absoluteString == "https://www.google.com/maps/dir/?api=1&destination=41.880700,-87.726200&travelmode=transit")
    }

    @Test func telephone() {
        #expect(DirectionsLinks.telephoneURL("(773) 555-0142")?.absoluteString == "tel:7735550142")
        #expect(DirectionsLinks.telephoneURL("+1 312-913-3110")?.absoluteString == "tel:+13129133110")
        #expect(DirectionsLinks.telephoneURL("call us") == nil)
        #expect(DirectionsLinks.telephoneURL(nil) == nil)
    }

    @Test func reportEmail() throws {
        let url = try #require(DirectionsLinks.reportProblemEmail(to: "hello@farecart.org", placeName: "Pete's", placeID: MockData.places[3].id))
        #expect(url.scheme == "mailto")
        #expect(url.absoluteString.hasPrefix("mailto:hello@farecart.org?subject="))
        #expect(url.absoluteString.contains("44444444-4444-4444-4444-444444444444"))
    }
}

@Suite("Config and mock provider")
struct ConfigTests {
    @Test func config() throws {
        let dict = ["SUPABASE_URL": "https:/mwirkxfqbomaaoygyfgm.supabase.co", "SUPABASE_ANON_KEY": "abc", "API_BASE_URL": ""]
        let config = try AppConfig(lookup: { dict[$0] })
        #expect(config.supabaseURL.absoluteString == "https://mwirkxfqbomaaoygyfgm.supabase.co")
        #expect(config.apiBaseURL == nil)
        #expect(config.reportProblemEmail == "hello@farecart.org")

        let withAPI = try AppConfig(lookup: { ["SUPABASE_URL": "https://x.supabase.co", "SUPABASE_ANON_KEY": "k", "API_BASE_URL": "https://api.example.org"][$0] })
        #expect(withAPI.apiBaseURL?.host() == "api.example.org")

        #expect(throws: AppConfig.ConfigError.missing("SUPABASE_ANON_KEY")) {
            try AppConfig(lookup: { ["SUPABASE_URL": "https://x.supabase.co"][$0] })
        }
        #expect(throws: AppConfig.ConfigError.missing("SUPABASE_URL")) {
            try AppConfig(lookup: { _ in nil })
        }
    }

    @Test func mockProvider() async throws {
        let provider = MockDataProvider()
        let all = try await provider.nearbyPlaces(around: .westSideChicago)
        #expect(all.count == MockData.places.count)
        let distances = all.compactMap(\.distanceMeters)
        #expect(distances == distances.sorted())
        let pantries = try await provider.nearbyPlaces(around: .westSideChicago, filter: .pantry)
        #expect(pantries.allSatisfy { $0.type == .pantry })
        let farAway = try await provider.nearbyPlaces(around: GeoPoint(latitude: 42.5, longitude: -88.5))
        #expect(farAway.isEmpty)
        #expect(try await provider.fares().count == 6)
        #expect(try await provider.programs().map(\.key) == ["access", "student"])
    }

    @Test func bundledFallbacksMatchSeed() {
        let calc = FareCalculator(fares: BundledFallbacks.fares)
        #expect(calc.fare(mode: .bus, rider: .full)?.priceCents == 225)
        #expect(calc.fare(mode: .train, rider: .full)?.priceCents == 250)
        #expect(calc.fare(mode: .bus, rider: .reducedAccess)?.priceCents == 110)
        #expect(calc.fare(mode: .train, rider: .reducedAccess)?.priceCents == 125)
        #expect(calc.fare(mode: .bus, rider: .student)?.priceCents == 75)
        #expect(BundledFallbacks.programs.first { $0.key == "access" }?.signupLink?.absoluteString == "https://getaccess.org")
    }
}
