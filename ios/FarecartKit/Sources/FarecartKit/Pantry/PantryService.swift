import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The ten pantry functions (root README, "Pantry inventory and visit scheduling"). Implemented
/// by `SupabaseClient` (live) and `MockPantryService` (previews, tests). Every method throws
/// `PantryError` only.
public protocol PantryService: Sendable {
    func availability(locationID: UUID) async throws -> PantryAvailability
    func bookVisit(slotID: UUID, deviceID: String, partySize: Int, userID: UUID?) async throws -> PantryVisit
    func cancelVisit(visitID: UUID, cancelToken: UUID) async throws
    func myVisits(deviceID: String) async throws -> [PantryVisit]

    func staffLogin(code: String) async throws -> StaffSession
    func staffSetInventory(code: String, category: PantryCategory, level: PantryLevel, note: String?) async throws -> PantryInventoryItem
    func staffUpsertSlot(code: String, slotID: UUID?, startsAt: Date, endsAt: Date, capacity: Int, notes: String?) async throws -> PantrySlot
    func staffDeleteSlot(code: String, slotID: UUID) async throws
    func staffBookings(code: String, day: Date) async throws -> [StaffBooking]
    func staffMarkArrived(code: String, visitID: UUID) async throws
}

extension SupabaseClient: PantryService {
    public func availability(locationID: UUID) async throws -> PantryAvailability {
        try await rpc("pantry_availability", body: ["p_location_id": .string(locationID.uuidString.lowercased())])
    }

    public func bookVisit(slotID: UUID, deviceID: String, partySize: Int, userID: UUID?) async throws -> PantryVisit {
        var body: [String: JSONValue] = [
            "p_slot_id": .string(slotID.uuidString.lowercased()),
            "p_device_id": .string(deviceID),
            "p_party_size": .number(Double(partySize)),
        ]
        if let userID { body["p_user_id"] = .string(userID.uuidString.lowercased()) }
        var visit: PantryVisit = try await rpc("book_visit", body: body)
        if visit.slotID == nil { visit.slotID = slotID }
        return visit
    }

    public func cancelVisit(visitID: UUID, cancelToken: UUID) async throws {
        let _: JSONValue = try await rpc("cancel_visit", body: [
            "p_visit_id": .string(visitID.uuidString.lowercased()),
            "p_cancel_token": .string(cancelToken.uuidString.lowercased()),
        ])
    }

    public func myVisits(deviceID: String) async throws -> [PantryVisit] {
        let rows: [Lossy<PantryVisit>] = try await rpc("my_visits", body: ["p_device_id": .string(deviceID)])
        return rows.compactMap(\.value)
    }

    public func staffLogin(code: String) async throws -> StaffSession {
        let normalized = StaffSession.normalize(code: code)
        var session: StaffSession = try await rpc("staff_login", body: ["p_code": .string(normalized)])
        session.code = normalized
        return session
    }

    public func staffSetInventory(code: String, category: PantryCategory, level: PantryLevel, note: String?) async throws -> PantryInventoryItem {
        var body: [String: JSONValue] = [
            "p_code": .string(code),
            "p_category": .string(category.rawValue),
            "p_level": .string(level.rawValue),
        ]
        body["p_note"] = note.map { .string($0) } ?? .null
        return try await rpc("staff_set_inventory", body: body)
    }

    public func staffUpsertSlot(code: String, slotID: UUID?, startsAt: Date, endsAt: Date, capacity: Int, notes: String?) async throws -> PantrySlot {
        var body: [String: JSONValue] = [
            "p_code": .string(code),
            "p_starts_at": .string(PostgresTimestamp.string(from: startsAt)),
            "p_ends_at": .string(PostgresTimestamp.string(from: endsAt)),
            "p_capacity": .number(Double(capacity)),
        ]
        body["p_slot_id"] = slotID.map { .string($0.uuidString.lowercased()) } ?? .null
        body["p_notes"] = notes.map { .string($0) } ?? .null
        return try await rpc("staff_upsert_slot", body: body)
    }

    public func staffDeleteSlot(code: String, slotID: UUID) async throws {
        let _: JSONValue = try await rpc("staff_delete_slot", body: [
            "p_code": .string(code),
            "p_slot_id": .string(slotID.uuidString.lowercased()),
        ])
    }

    public func staffBookings(code: String, day: Date) async throws -> [StaffBooking] {
        // `p_day` is a Postgres date in Chicago terms; send the local calendar day.
        var chicago = Calendar(identifier: .gregorian)
        chicago.timeZone = TimeZone(identifier: "America/Chicago") ?? .current
        let parts = chicago.dateComponents([.year, .month, .day], from: day)
        let dayString = String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
        let rows: [Lossy<StaffBooking>] = try await rpc("staff_bookings", body: ["p_code": .string(code), "p_day": .string(dayString)])
        return rows.compactMap(\.value)
    }

    public func staffMarkArrived(code: String, visitID: UUID) async throws {
        let _: JSONValue = try await rpc("staff_mark_arrived", body: [
            "p_code": .string(code),
            "p_visit_id": .string(visitID.uuidString.lowercased()),
        ])
    }

    /// `POST rest/v1/rpc/<name>` with every failure mapped to `PantryError`.
    func rpc<T: Decodable>(_ name: String, body: [String: JSONValue]) async throws -> T {
        do {
            let request = try makeRequest(path: "rest/v1/rpc/\(name)", method: "POST", body: body)
            return try await perform(request)
        } catch {
            throw PantryError.wrap(error)
        }
    }
}
