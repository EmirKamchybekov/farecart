import Foundation
import Testing
@testable import FarecartKit

@Suite("Pantry models")
struct PantryModelTests {
    /// A real `pantry_availability` payload (2026-10-16), plus one row with a category we do not know.
    static let availabilityJSON = """
    {"slots":[
      {"id":"27e4b72f-b599-4fbf-a092-4225e4c5d1b9","notes":null,"booked":0,"ends_at":"2099-10-18T18:30:00+00:00","capacity":13,"remaining":13,"starts_at":"2099-10-18T18:00:00+00:00"},
      {"id":"8a998086-2702-4f58-a84b-9c4d58d7ad7b","notes":"Side door","booked":14,"ends_at":"2099-10-18T19:00:00+00:00","capacity":14,"remaining":0,"starts_at":"2099-10-18T18:30:00+00:00"},
      {"id":"7c0583e2-2104-4ccb-9464-0832cef0ed16","notes":null,"booked":0,"ends_at":"2020-01-01T19:30:00+00:00","capacity":8,"remaining":8,"starts_at":"2020-01-01T19:00:00+00:00"},
      {"id":"not-a-uuid","starts_at":"x","ends_at":"y"}
     ],
     "inventory":[
      {"id":"e2fec269-a92d-4367-8b46-2fd37b00e952","note":"no formula this week","level":"low","source":"demo","category":"baby","expires_at":"2099-10-17T03:39:19.563+00:00","reported_at":"2026-10-16T03:39:19.563+00:00"},
      {"id":"727c63bf-557a-42ea-a59b-5009897a72ac","note":"bakery donations","level":"plenty","source":"demo","category":"bread","expires_at":"2099-10-17T03:39:19.563+00:00","reported_at":"2026-10-16T04:39:19.563+00:00"},
      {"id":"a25420e5-1b25-441a-8ebd-c2582d292021","note":null,"level":"out","source":"staff","category":"produce","expires_at":"2020-01-01T00:00:00+00:00","reported_at":"2019-12-31T00:00:00+00:00"},
      {"id":"b25420e5-1b25-441a-8ebd-c2582d292021","note":null,"level":"low","source":"staff","category":"cheese","expires_at":"2099-01-01T00:00:00+00:00","reported_at":"2026-10-16T00:00:00+00:00"}
     ],
     "location_id":"ab79ab95-d3c3-48ab-925b-4b4534e3ef3f",
     "staff_updated_at":"2026-10-16T03:40:09.270111+00:00"}
    """

    @Test("pantry_availability decodes, drops unknown categories and expired rows")
    func availability() throws {
        let availability = try PostgRESTDecoder.decode(PantryAvailability.self, from: Data(Self.availabilityJSON.utf8))
        #expect(availability.locationID?.uuidString.lowercased() == "ab79ab95-d3c3-48ab-925b-4b4534e3ef3f")
        #expect(availability.slots.count == 3)            // the malformed row is skipped
        #expect(availability.inventory.count == 3)        // "cheese" is skipped
        let current = availability.currentInventory()
        #expect(current.map(\.category) == [.produce, .bread, .baby].filter { $0 != .produce })   // produce expired
        #expect(current.first?.category == .bread)        // display order: bread before baby
        #expect(availability.latestReportedAt().map { PostgresTimestamp.string(from: $0) } == "2026-10-16T04:39:19Z")
        #expect(availability.staffUpdatedAt != nil)

        let upcoming = availability.upcomingSlots()
        #expect(upcoming.count == 2)
        #expect(upcoming[0].remaining == 13)
        #expect(upcoming[1].isFull)
        #expect(upcoming[1].notes == "Side door")
        #expect(availability.hasUpcomingSlots())
        #expect(availability.slotsByDay().count == 1)
        #expect(upcoming[0].durationMinutes == 30)
    }

    @Test("Timestamps in every shape PostgREST and Postgres print")
    func timestamps() throws {
        let expected = try #require(PostgresTimestamp.parse("2026-10-16T03:39:19Z"))
        #expect(PostgresTimestamp.parse("2026-10-16T03:39:19+00:00") == expected)
        #expect(PostgresTimestamp.parse("2026-10-16T03:39:19.000+00:00") == expected)
        #expect(PostgresTimestamp.parse("2026-10-16T03:39:19+00") == expected)
        #expect(PostgresTimestamp.parse("2026-10-16 03:39:19+00") == expected)
        #expect(PostgresTimestamp.parse("2026-10-15T22:39:19-05:00") == expected)
        let micro = try #require(PostgresTimestamp.parse("2026-10-16T03:39:19.270111+00:00"))
        #expect(abs(micro.timeIntervalSince(expected) - 0.27) < 0.001)
        #expect(PostgresTimestamp.parse("yesterday") == nil)
        #expect(PostgresTimestamp.string(from: expected) == "2026-10-16T03:39:19Z")
        // Round trip through the encoder.
        let slot = PantrySlot(startsAt: expected, endsAt: expected.addingTimeInterval(1800), capacity: 5, booked: 2)
        let data = try JSONEncoder().encode(slot)
        let back = try PostgRESTDecoder.decode(PantrySlot.self, from: data)
        #expect(back.startsAt == expected)
        #expect(back.remaining == 3)
    }

    @Test("book_visit and my_visits rows decode into PantryVisit")
    func visits() throws {
        let booked = """
        {"visit_id":"0c5d0a1e-9d2f-4b1c-8f4a-1c2d3e4f5a6b","confirmation_code":"K7PX2M","cancel_token":"1c5d0a1e-9d2f-4b1c-8f4a-1c2d3e4f5a6b",
         "starts_at":"2099-10-18T18:00:00+00:00","ends_at":"2099-10-18T18:30:00+00:00","location_id":"ab79ab95-d3c3-48ab-925b-4b4534e3ef3f",
         "location_name":"Legler Regional Library Food Pantry","address":"115 S Pulaski Rd","party_size":2,"status":"booked"}
        """
        let visit = try PostgRESTDecoder.decode(PantryVisit.self, from: Data(booked.utf8))
        #expect(visit.confirmationCode == "K7PX2M")
        #expect(visit.partySize == 2)
        #expect(visit.slotID == nil)
        #expect(visit.coordinate == nil)
        #expect(visit.isUpcoming())
        #expect(visit.canCancel)

        let mine = """
        [{"visit_id":"0c5d0a1e-9d2f-4b1c-8f4a-1c2d3e4f5a6b","slot_id":"27e4b72f-b599-4fbf-a092-4225e4c5d1b9","location_id":"ab79ab95-d3c3-48ab-925b-4b4534e3ef3f",
          "location_name":"Legler","address":"115 S Pulaski Rd","lat":41.88,"lng":-87.72,"starts_at":"2020-10-18T18:00:00+00:00","ends_at":"2020-10-18T18:30:00+00:00",
          "party_size":1,"status":"cancelled","confirmation_code":"K7PX2M","cancel_token":"1c5d0a1e-9d2f-4b1c-8f4a-1c2d3e4f5a6b","created_at":"2020-10-16T03:39:19.5+00:00","is_upcoming":false}]
        """
        let rows = try PostgRESTDecoder.decode([Lossy<PantryVisit>].self, from: Data(mine.utf8)).compactMap(\.value)
        #expect(rows.count == 1)
        #expect(rows[0].status == .cancelled)
        #expect(!rows[0].isUpcoming())
        #expect(!rows[0].canCancel)
        #expect(rows[0].coordinate == GeoPoint(latitude: 41.88, longitude: -87.72))
        #expect(rows[0].slotID != nil)
    }

    @Test("staff_login and staff rows decode")
    func staff() throws {
        let login = #"{"location_id":"ab79ab95-d3c3-48ab-925b-4b4534e3ef3f","name":"Legler","address":"115 S Pulaski Rd","contact_name":"Demo staff","contact_phone":null}"#
        var session = try PostgRESTDecoder.decode(StaffSession.self, from: Data(login.utf8))
        session.code = StaffSession.normalize(code: " a7gb-qz\n")
        #expect(session.code == "A7GBQZ")
        #expect(session.name == "Legler")
        #expect(session.contactPhone == nil)
        let persisted = try JSONDecoder().decode(StaffSession.self, from: try JSONEncoder().encode(session))
        #expect(persisted == session)

        let bookings = #"[{"visit_id":"0c5d0a1e-9d2f-4b1c-8f4a-1c2d3e4f5a6b","slot_id":"27e4b72f-b599-4fbf-a092-4225e4c5d1b9","starts_at":"2099-10-18T18:00:00+00:00","ends_at":"2099-10-18T18:30:00+00:00","party_size":3,"status":"arrived","confirmation_code":"K7PX2M","created_at":"2026-10-16T03:39:19+00:00"}]"#
        let rows = try PostgRESTDecoder.decode([StaffBooking].self, from: Data(bookings.utf8))
        #expect(rows[0].status == .arrived)
        #expect(rows[0].partySize == 3)

        let inventoryRow = #"{"id":"e2fec269-a92d-4367-8b46-2fd37b00e952","location_id":"ab79ab95-d3c3-48ab-925b-4b4534e3ef3f","category":"produce","level":"low","note":null,"reported_at":"2026-10-16T03:39:19.563+00:00","expires_at":"2026-10-17T03:39:19.563+00:00","source":"staff"}"#
        let item = try PostgRESTDecoder.decode(PantryInventoryItem.self, from: Data(inventoryRow.utf8))
        #expect(item.level == .low)
        #expect(item.level.next == .out)
        #expect(PantryLevel.out.next == .plenty)
    }

    @Test("Place decodes the pantry columns tolerantly")
    func placeColumns() throws {
        let json = """
        [{"id":"5f1d0a1e-9d2f-4b1c-8f4a-1c2d3e4f5a6b","name":"P","type":"pantry","address":"1 Main","lat":41.9,"lng":-87.7,
          "pantry_model":"client_choice","requires_snap":true,"requires_id":false,"feedam_id":223910},
         {"id":"6f1d0a1e-9d2f-4b1c-8f4a-1c2d3e4f5a6b","name":"Q","type":"pantry","address":"1 Main","lat":41.9,"lng":-87.7,
          "pantry_model":"drive_thru","requires_snap":null,"requires_id":null,"feedam_id":"42"},
         {"id":"7f1d0a1e-9d2f-4b1c-8f4a-1c2d3e4f5a6b","name":"R","type":"pantry","address":"1 Main","lat":41.9,"lng":-87.7}]
        """
        let places = try PostgRESTDecoder.decode([Place].self, from: Data(json.utf8))
        #expect(places[0].pantryModel == .clientChoice)
        #expect(places[0].requiresSNAP == true)
        #expect(places[0].requiresID == false)
        #expect(places[0].feedamID == 223910)
        #expect(places[1].pantryModel == nil)
        #expect(places[1].requiresSNAP == false)
        #expect(places[1].requiresID == nil)
        #expect(places[1].feedamID == 42)
        #expect(places[2].pantryModel == nil)
        #expect(places[2].feedamID == nil)
        let back = try PostgRESTDecoder.decode(Place.self, from: try JSONEncoder().encode(places[0]))
        #expect(back.pantryModel == .clientChoice && back.feedamID == 223910 && back.requiresSNAP)
    }
}

@Suite("Pantry errors")
struct PantryErrorTests {
    @Test("PostgREST messages map to typed cases")
    func mapping() {
        let body = #"{"code":"P0001","details":null,"hint":null,"message":"slot_full"}"#
        #expect(PantryError.wrap(APIError.httpStatus(400, body: body)) == .slotFull)
        #expect(PantryError(message: "slot_past") == .slotPast)
        #expect(PantryError(message: "already_booked") == .alreadyBooked)
        #expect(PantryError(message: "BAD_CODE") == .badCode)
        #expect(PantryError(message: "bad_device") == .server("bad_device"))
        #expect(PantryError.wrap(APIError.httpStatus(404, body: #"{"message":"Could not find the function public.my_visits"}"#)).code == "Could not find the function public.my_visits")
        #expect(PantryError.wrap(APIError.httpStatus(502, body: "<html>")) == .network("Server error 502."))
        #expect(PantryError.wrap(APIError.decoding("x")).code == "network")
        #expect(PantryError.wrap(URLError(.notConnectedToInternet)) == .network("You seem to be offline."))
        #expect(PantryError.wrap(PantryError.badCode) == .badCode)
        #expect(PantryError.slotFull.errorDescription?.isEmpty == false)
    }
}

@Suite("Feed America")
struct FeedAmericaTests {
    @Test("Parses the live status shape and ignores unknown fields")
    func liveShape() throws {
        let body = #"{"id":223910,"phone_valid":true,"phone_formatted":"(773) 262-2297","hours_status":"unknown","days_since_verified":176,"confidence":"low","extra":{"x":1}}"#
        let status = try #require(FeedAmericaStatus.parse(Data(body.utf8)))
        #expect(status.id == 223910)
        #expect(status.isOpen == nil)
        #expect(status.daysSinceVerified == 176)
        #expect(status.inventory.isEmpty)
        #expect(FeedAmericaStatus.parse(Data("[1,2]".utf8)) == nil)
        #expect(FeedAmericaStatus.parse(Data("{}".utf8))?.hoursStatus == nil)
    }

    @Test("Accepts inventory-like payloads and merges them under staff rows")
    func merge() throws {
        let body = #"{"id":1,"hours_status":"open","updated_at":"2026-10-16T12:00:00Z","inventory":[{"category":"produce","level":"in stock"},{"category":"dairy","status":"low"},{"category":"fish","level":"low"},{"category":"bread","level":"weird"}]}"#
        let status = try #require(FeedAmericaStatus.parse(Data(body.utf8), now: PostgresTimestamp.parse("2026-10-16T13:00:00Z")!))
        #expect(status.isOpen == true)
        #expect(status.inventory.map(\.category) == [.produce, .dairy])
        #expect(status.inventory.allSatisfy { $0.source == "feedam" })
        #expect(status.inventory[0].level == .plenty)

        let now = PostgresTimestamp.parse("2026-10-16T13:00:00Z")!
        let staff = PantryInventoryItem(category: .produce, level: .out, reportedAt: now, source: "staff")
        let merged = PantryAvailability(inventory: [staff]).merging(feedAmerica: status, at: now)
        let current = merged.currentInventory(at: now)
        #expect(current.map(\.category) == [.produce, .dairy])
        #expect(current[0].source == "staff" && current[0].level == .out)   // staff wins
        #expect(current[1].source == "feedam")
        #expect(merged.feedAmerica?.isOpen == true)
        // Merging again replaces the previous feedam rows instead of duplicating them.
        #expect(merged.merging(feedAmerica: status, at: now).currentInventory(at: now).count == 2)
        #expect(merged.merging(feedAmerica: nil, at: now).feedAmerica == nil)

        let flat = #"{"produce":"plenty","water":"none"}"#
        #expect(FeedAmericaStatus.parse(Data(flat.utf8))?.inventory.map(\.level) == [.plenty, .out])
    }

    @Test("Client sends the User-Agent and caches for ten minutes")
    func client() async throws {
        let transport = StubTransport(body: #"{"id":5,"hours_status":"closed"}"#)
        let clock = ClockBox()
        let client = FeedAmericaClient(transport: transport, now: { clock.now })
        let first = await client.status(feedamID: 5)
        #expect(first?.isOpen == false)
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://feedam.org/api/resources/5/status")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Farecart/0.1 (hello@farecart.org)")
        _ = await client.status(feedamID: 5)
        #expect(transport.requests.count == 1)
        clock.advance(by: 11 * 60)
        _ = await client.status(feedamID: 5)
        #expect(transport.requests.count == 2)

        let failing = FeedAmericaClient(transport: StubTransport(status: 500, body: "nope"))
        #expect(await failing.status(feedamID: 9) == nil)
    }
}

final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _now = Date()
    var now: Date { lock.withLock { _now } }
    func advance(by seconds: TimeInterval) { lock.withLock { _now = _now.addingTimeInterval(seconds) } }
}

@Suite("DeviceID")
struct DeviceIDTests {
    @Test("Created once and reused")
    func stable() throws {
        let store = InMemorySecureStore()
        let first = DeviceID.current(store: store)
        #expect(UUID(uuidString: first) != nil)
        #expect(DeviceID.current(store: store) == first)
        #expect(try store.readString(key: DeviceID.storageKey) == first)
        let seeded = InMemorySecureStore([DeviceID.storageKey: "short"])
        #expect(DeviceID.current(store: seeded) != "short")   // too short to be accepted by book_visit
    }
}

@Suite("MockPantryService")
struct MockPantryServiceTests {
    @Test("Booking counts against capacity, repeats are rejected, cancelling frees the spot")
    func bookingFlow() async throws {
        let service = MockPantryService()
        let pantry = MockData.samplePantry
        let availability = try await service.availability(locationID: pantry.id)
        let open = try #require(availability.upcomingSlots().first { $0.remaining > 0 })
        let before = open.remaining

        let visit = try await service.bookVisit(slotID: open.id, deviceID: "device-aaaa", partySize: 2, userID: nil)
        #expect(visit.confirmationCode.count == 6)
        #expect(visit.locationName == pantry.name)
        #expect(visit.coordinate == pantry.coordinate)
        let after = try await service.availability(locationID: pantry.id).slots.first { $0.id == open.id }
        #expect(after?.remaining == before - 1)

        await #expect(throws: PantryError.alreadyBooked) {
            _ = try await service.bookVisit(slotID: open.id, deviceID: "device-aaaa", partySize: 1, userID: nil)
        }
        let full = try #require(availability.upcomingSlots().first { $0.isFull })
        await #expect(throws: PantryError.slotFull) {
            _ = try await service.bookVisit(slotID: full.id, deviceID: "device-bbbb", partySize: 1, userID: nil)
        }
        await #expect(throws: PantryError.slotNotFound) {
            _ = try await service.bookVisit(slotID: UUID(), deviceID: "device-bbbb", partySize: 1, userID: nil)
        }

        let mine = try await service.myVisits(deviceID: "device-aaaa")
        #expect(mine.map(\.id) == [visit.id])
        #expect(try await service.myVisits(deviceID: "device-other").isEmpty)

        try await service.cancelVisit(visitID: visit.id, cancelToken: visit.cancelToken!)
        let restored = try await service.availability(locationID: pantry.id).slots.first { $0.id == open.id }
        #expect(restored?.remaining == before)
        #expect(try await service.myVisits(deviceID: "device-aaaa").first?.status == .cancelled)
        await #expect(throws: PantryError.visitNotFound) {
            try await service.cancelVisit(visitID: visit.id, cancelToken: UUID())
        }
    }

    @Test("Staff mode: login, stock, slots, bookings, arrived")
    func staffFlow() async throws {
        let service = MockPantryService()
        await #expect(throws: PantryError.badCode) { _ = try await service.staffLogin(code: "WRONG1") }
        let session = try await service.staffLogin(code: "demo01")
        #expect(session.locationID == MockData.samplePantry.id)
        #expect(session.code == "DEMO01")

        let item = try await service.staffSetInventory(code: session.code, category: .water, level: .plenty, note: nil)
        #expect(item.source == "staff")
        let stock = try await service.availability(locationID: session.locationID).currentInventory()
        #expect(stock.first { $0.category == .water }?.level == .plenty)
        _ = try await service.staffSetInventory(code: session.code, category: .water, level: .out, note: nil)
        #expect(try await service.availability(locationID: session.locationID).currentInventory().filter { $0.category == .water }.count == 1)

        let start = Date().addingTimeInterval(3600)
        let slot = try await service.staffUpsertSlot(code: session.code, slotID: nil, startsAt: start, endsAt: start.addingTimeInterval(3600), capacity: 4, notes: nil)
        #expect(slot.durationMinutes == 60)
        await #expect(throws: PantryError.badTimes) {
            _ = try await service.staffUpsertSlot(code: session.code, slotID: nil, startsAt: start, endsAt: start, capacity: 4, notes: nil)
        }
        let visit = try await service.bookVisit(slotID: slot.id, deviceID: "device-cccc", partySize: 3, userID: nil)
        await #expect(throws: PantryError.capacityBelowBooked) {
            _ = try await service.staffUpsertSlot(code: session.code, slotID: slot.id, startsAt: start, endsAt: start.addingTimeInterval(3600), capacity: 0, notes: nil)
        }
        let bookings = try await service.staffBookings(code: session.code, day: start)
        #expect(bookings.map(\.confirmationCode) == [visit.confirmationCode])
        try await service.staffMarkArrived(code: session.code, visitID: visit.id)
        #expect(try await service.staffBookings(code: session.code, day: start).first?.status == .arrived)
        await #expect(throws: PantryError.alreadyArrived) {
            try await service.cancelVisit(visitID: visit.id, cancelToken: visit.cancelToken!)
        }
        try await service.staffDeleteSlot(code: session.code, slotID: slot.id)
        #expect(try await service.availability(locationID: session.locationID).slots.contains { $0.id == slot.id } == false)
        await #expect(throws: PantryError.slotNotFound) { try await service.staffDeleteSlot(code: session.code, slotID: slot.id) }
    }
}

@Suite("SupabaseClient pantry RPCs")
struct SupabasePantryTests {
    let baseURL = URL(string: "https://example.supabase.co")!

    private func body(of request: URLRequest?) throws -> [String: Any] {
        let data = try #require(request?.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("book_visit posts the contract arguments and maps a 400 message")
    func book() async throws {
        let ok = StubTransport(body: #"{"visit_id":"0c5d0a1e-9d2f-4b1c-8f4a-1c2d3e4f5a6b","confirmation_code":"K7PX2M","cancel_token":"1c5d0a1e-9d2f-4b1c-8f4a-1c2d3e4f5a6b","starts_at":"2099-10-18T18:00:00+00:00","ends_at":"2099-10-18T18:30:00+00:00","location_name":"L","address":"A"}"#)
        let client = SupabaseClient(baseURL: baseURL, anonKey: "k", transport: ok)
        let slot = UUID()
        let user = UUID()
        let visit = try await client.bookVisit(slotID: slot, deviceID: "dev-12345678", partySize: 3, userID: user)
        #expect(visit.slotID == slot)
        #expect(ok.requests.first?.url?.absoluteString == "https://example.supabase.co/rest/v1/rpc/book_visit")
        let sent = try body(of: ok.requests.first)
        #expect(sent["p_slot_id"] as? String == slot.uuidString.lowercased())
        #expect(sent["p_device_id"] as? String == "dev-12345678")
        #expect(sent["p_party_size"] as? Double == 3)
        #expect(sent["p_user_id"] as? String == user.uuidString.lowercased())

        let full = StubTransport(status: 400, body: #"{"code":"P0001","details":null,"hint":null,"message":"slot_full"}"#)
        await #expect(throws: PantryError.slotFull) {
            _ = try await SupabaseClient(baseURL: baseURL, anonKey: "k", transport: full).bookVisit(slotID: slot, deviceID: "dev-12345678", partySize: 1, userID: nil)
        }
        let anon = try body(of: full.requests.first)
        #expect(anon["p_user_id"] == nil)
    }

    @Test("Staff calls carry the code and ISO timestamps; bad_code maps")
    func staff() async throws {
        let transport = StubTransport(body: #"{"id":"27e4b72f-b599-4fbf-a092-4225e4c5d1b9","location_id":"ab79ab95-d3c3-48ab-925b-4b4534e3ef3f","starts_at":"2099-10-18T18:00:00+00:00","ends_at":"2099-10-18T19:00:00+00:00","capacity":10,"booked":0,"notes":null,"remaining":10}"#)
        let client = SupabaseClient(baseURL: baseURL, anonKey: "k", transport: transport)
        let start = PostgresTimestamp.parse("2099-10-18T18:00:00Z")!
        let slot = try await client.staffUpsertSlot(code: "A7GBQZ", slotID: nil, startsAt: start, endsAt: start.addingTimeInterval(3600), capacity: 10, notes: nil)
        #expect(slot.remaining == 10)
        let sent = try body(of: transport.requests.first)
        #expect(sent["p_code"] as? String == "A7GBQZ")
        #expect(sent["p_starts_at"] as? String == "2099-10-18T18:00:00Z")
        #expect(sent["p_ends_at"] as? String == "2099-10-18T19:00:00Z")
        #expect(sent["p_slot_id"] is NSNull)
        #expect(sent["p_capacity"] as? Double == 10)

        let bookings = StubTransport(body: "[]")
        _ = try await SupabaseClient(baseURL: baseURL, anonKey: "k", transport: bookings).staffBookings(code: "A7GBQZ", day: PostgresTimestamp.parse("2026-10-16T03:00:00Z")!)
        #expect(try body(of: bookings.requests.first)["p_day"] as? String == "2026-10-15")   // Chicago date of that instant

        let bad = StubTransport(status: 400, body: #"{"code":"P0001","message":"bad_code"}"#)
        await #expect(throws: PantryError.badCode) {
            _ = try await SupabaseClient(baseURL: baseURL, anonKey: "k", transport: bad).staffLogin(code: "nope")
        }
        let login = StubTransport(body: #"{"location_id":"ab79ab95-d3c3-48ab-925b-4b4534e3ef3f","name":"Legler","address":"115 S Pulaski Rd"}"#)
        let session = try await SupabaseClient(baseURL: baseURL, anonKey: "k", transport: login).staffLogin(code: " a7gbqz ")
        #expect(session.code == "A7GBQZ")
        #expect(try body(of: login.requests.first)["p_code"] as? String == "A7GBQZ")

        let cancel = StubTransport(body: #"{"visit_id":"0c5d0a1e-9d2f-4b1c-8f4a-1c2d3e4f5a6b","status":"cancelled"}"#)
        try await SupabaseClient(baseURL: baseURL, anonKey: "k", transport: cancel).cancelVisit(visitID: UUID(), cancelToken: UUID())
        #expect(cancel.requests.first?.url?.lastPathComponent == "cancel_visit")
    }
}
