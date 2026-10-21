import Foundation

/// In-memory `PantryService` for previews and tests: demo slots and stock for the two mock
/// pantries, bookings that count against capacity, and staff codes `DEMO01` / `DEMO02`.
public final class MockPantryService: PantryService, @unchecked Sendable {
    private let lock = NSLock()
    private var inventory: [UUID: [PantryInventoryItem]] = [:]
    private var slots: [UUID: [PantrySlot]] = [:]
    private var visits: [PantryVisit] = []
    private var deviceByVisit: [UUID: String] = [:]
    /// The mock treats the access token itself as the account key.
    private var accountByVisit: [UUID: String] = [:]
    private var staffCodes: [String: Place] = [:]
    public var delayNanoseconds: UInt64
    public var failure: PantryError?

    public static let demoCode = "DEMO01"

    public init(places: [Place] = MockData.places, now: Date = Date(), delayNanoseconds: UInt64 = 0, failure: PantryError? = nil) {
        self.delayNanoseconds = delayNanoseconds
        self.failure = failure
        let pantries = places.filter { $0.type == .pantry }
        for (index, pantry) in pantries.enumerated() {
            staffCodes[index == 0 ? Self.demoCode : "DEMO0\(index + 1)"] = pantry
            slots[pantry.id] = Self.demoSlots(for: pantry, now: now, seed: index)
            inventory[pantry.id] = index == 0 ? Self.demoInventory(now: now) : []
        }
    }

    /// 30-minute slots on the next three days from tomorrow, 10:00–12:00, capacity 8–12.
    public static func demoSlots(for place: Place, now: Date, seed: Int) -> [PantrySlot] {
        let calendar = Calendar.current
        var result: [PantrySlot] = []
        for dayOffset in 1...3 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: now)) else { continue }
            for half in 0..<4 {
                let start = day.addingTimeInterval(TimeInterval(10 * 3600 + half * 1800))
                let capacity = 8 + ((half + seed) % 3) * 2
                let booked = half == 1 ? capacity : (half == 2 ? capacity - 3 : 0)
                result.append(PantrySlot(id: UUID(), locationID: place.id, startsAt: start, endsAt: start.addingTimeInterval(1800), capacity: capacity, booked: booked))
            }
        }
        return result
    }

    public static func demoInventory(now: Date) -> [PantryInventoryItem] {
        let reported = now.addingTimeInterval(-2 * 3600)
        return [
            PantryInventoryItem(category: .produce, level: .plenty, note: "apples, onions, potatoes", reportedAt: reported, source: "demo"),
            PantryInventoryItem(category: .dairy, level: .low, note: "eggs only today", reportedAt: reported, source: "demo"),
            PantryInventoryItem(category: .protein, level: .out, reportedAt: reported, source: "demo"),
            PantryInventoryItem(category: .canned, level: .plenty, reportedAt: reported, source: "demo"),
            PantryInventoryItem(category: .bread, level: .plenty, note: "bakery donations", reportedAt: reported, source: "demo"),
            PantryInventoryItem(category: .baby, level: .low, note: "no formula this week", reportedAt: reported, source: "demo"),
        ]
    }

    private func pause() async throws {
        if let failure { throw failure }
        if delayNanoseconds > 0 { try? await Task.sleep(nanoseconds: delayNanoseconds) }
    }

    private func location(for code: String) throws -> Place {
        guard let place = staffCodes[StaffSession.normalize(code: code)] else { throw PantryError.badCode }
        return place
    }

    // MARK: Public

    public func availability(locationID: UUID) async throws -> PantryAvailability {
        try await pause()
        return lock.withLock {
            PantryAvailability(
                locationID: locationID,
                inventory: inventory[locationID] ?? [],
                slots: (slots[locationID] ?? []).filter { !$0.isPast() },
                staffUpdatedAt: inventory[locationID]?.map(\.reportedAt).max()
            )
        }
    }

    public func bookVisit(slotID: UUID, deviceID: String, partySize: Int, userID: UUID?, accessToken: String?) async throws -> PantryVisit {
        try await pause()
        return try lock.withLock {
            guard let (locationID, index) = find(slotID: slotID) else { throw PantryError.slotNotFound }
            var slot = slots[locationID]![index]
            if slot.isPast() { throw PantryError.slotPast }
            if visits.contains(where: { $0.slotID == slotID && $0.status != .cancelled && deviceByVisit[$0.id] == deviceID }) {
                throw PantryError.alreadyBooked
            }
            if slot.isFull { throw PantryError.slotFull }
            slot.booked += 1
            slots[locationID]![index] = slot
            let place = staffCodes.values.first { $0.id == locationID }
            let visit = PantryVisit(
                slotID: slotID,
                locationID: locationID,
                locationName: place?.name ?? "Pantry",
                address: place?.address ?? "",
                latitude: place?.latitude,
                longitude: place?.longitude,
                startsAt: slot.startsAt,
                endsAt: slot.endsAt,
                partySize: partySize,
                confirmationCode: Self.makeCode()
            )
            visits.append(visit)
            deviceByVisit[visit.id] = deviceID
            if let accessToken { accountByVisit[visit.id] = accessToken }
            return visit
        }
    }

    public func cancelVisit(visitID: UUID, cancelToken: UUID, accessToken: String?) async throws {
        try await pause()
        try lock.withLock {
            guard let index = visits.firstIndex(where: { $0.id == visitID && $0.cancelToken == cancelToken }) else { throw PantryError.visitNotFound }
            let visit = visits[index]
            if visit.status == .arrived { throw PantryError.alreadyArrived }
            guard visit.status == .booked else { return }
            visits[index].status = .cancelled
            if let slotID = visit.slotID, let (locationID, slotIndex) = find(slotID: slotID) {
                slots[locationID]![slotIndex].booked = max(0, slots[locationID]![slotIndex].booked - 1)
            }
        }
    }

    public func myVisits(deviceID: String, accessToken: String?) async throws -> [PantryVisit] {
        try await pause()
        return lock.withLock {
            VisitMerge.merge(device: visits.filter { deviceByVisit[$0.id] == deviceID }, account: [])
        }
    }

    public func accountVisits(accessToken: String) async throws -> [PantryVisit] {
        try await pause()
        return lock.withLock {
            VisitMerge.merge(device: [], account: visits.filter { accountByVisit[$0.id] == accessToken })
        }
    }

    public func claimDeviceVisits(deviceID: String, accessToken: String) async throws -> Int {
        try await pause()
        return lock.withLock {
            var claimed = 0
            for visit in visits where deviceByVisit[visit.id] == deviceID && accountByVisit[visit.id] == nil {
                accountByVisit[visit.id] = accessToken
                claimed += 1
            }
            return claimed
        }
    }

    // MARK: Staff

    public func staffLogin(code: String) async throws -> StaffSession {
        try await pause()
        let place = try lock.withLock { try location(for: code) }
        return StaffSession(code: StaffSession.normalize(code: code), locationID: place.id, name: place.name, address: place.address, contactName: "Demo staff")
    }

    public func staffSetInventory(code: String, category: PantryCategory, level: PantryLevel, note: String?) async throws -> PantryInventoryItem {
        try await pause()
        return try lock.withLock {
            let place = try location(for: code)
            let item = PantryInventoryItem(category: category, level: level, note: note, source: "staff")
            var rows = inventory[place.id] ?? []
            rows.removeAll { $0.category == category }
            rows.append(item)
            inventory[place.id] = rows
            return item
        }
    }

    public func staffUpsertSlot(code: String, slotID: UUID?, startsAt: Date, endsAt: Date, capacity: Int, notes: String?) async throws -> PantrySlot {
        try await pause()
        return try lock.withLock {
            let place = try location(for: code)
            guard endsAt > startsAt else { throw PantryError.badTimes }
            if let slotID, let (locationID, index) = find(slotID: slotID), locationID == place.id {
                var slot = slots[locationID]![index]
                if capacity < slot.booked { throw PantryError.capacityBelowBooked }
                slot.startsAt = startsAt
                slot.endsAt = endsAt
                slot.capacity = capacity
                slot.notes = notes
                slots[locationID]![index] = slot
                return slot
            }
            let slot = PantrySlot(locationID: place.id, startsAt: startsAt, endsAt: endsAt, capacity: capacity, notes: notes)
            slots[place.id, default: []].append(slot)
            return slot
        }
    }

    public func staffDeleteSlot(code: String, slotID: UUID) async throws {
        try await pause()
        try lock.withLock {
            let place = try location(for: code)
            guard let (locationID, index) = find(slotID: slotID), locationID == place.id else { throw PantryError.slotNotFound }
            slots[locationID]!.remove(at: index)
            for i in visits.indices where visits[i].slotID == slotID { visits[i].status = .cancelled }
        }
    }

    public func staffBookings(code: String, day: Date) async throws -> [StaffBooking] {
        try await pause()
        return try lock.withLock {
            let place = try location(for: code)
            let calendar = Calendar.current
            return visits
                .filter { $0.locationID == place.id && calendar.isDate($0.startsAt, inSameDayAs: day) }
                .sorted { $0.startsAt < $1.startsAt }
                .map { StaffBooking(id: $0.id, slotID: $0.slotID, startsAt: $0.startsAt, endsAt: $0.endsAt, partySize: $0.partySize, status: $0.status, confirmationCode: $0.confirmationCode, createdAt: $0.createdAt) }
        }
    }

    public func staffMarkArrived(code: String, visitID: UUID) async throws {
        try await pause()
        try lock.withLock {
            let place = try location(for: code)
            guard let index = visits.firstIndex(where: { $0.id == visitID && $0.locationID == place.id }) else { throw PantryError.visitNotFound }
            if visits[index].status == .cancelled { throw PantryError.visitCancelled }
            visits[index].status = .arrived
        }
    }

    // MARK: Helpers

    private func find(slotID: UUID) -> (UUID, Int)? {
        for (locationID, list) in slots {
            if let index = list.firstIndex(where: { $0.id == slotID }) { return (locationID, index) }
        }
        return nil
    }

    static func makeCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<6).map { _ in alphabet.randomElement()! })
    }
}
