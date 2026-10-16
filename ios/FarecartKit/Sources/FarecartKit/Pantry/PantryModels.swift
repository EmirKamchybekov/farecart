import Foundation

// Pantry inventory + visit scheduling (root README, "Pantry inventory and visit scheduling").
// Everything here decodes the jsonb shapes returned by the SECURITY DEFINER functions in
// migration 0007 and tolerates missing or unexpected values: a pantry that posts a category
// the app does not know simply does not show that chip.

/// Stock categories a pantry can report. Order is the display order.
public enum PantryCategory: String, CaseIterable, Sendable, Codable, Hashable, Identifiable {
    case produce, dairy, protein, canned, bread, baby, water, other

    public var id: String { rawValue }
}

/// How much of a category the pantry has right now.
public enum PantryLevel: String, CaseIterable, Sendable, Codable, Hashable {
    case plenty, low, out

    /// Tap to cycle: plenty → low → out → plenty.
    public var next: PantryLevel {
        switch self {
        case .plenty: .low
        case .low: .out
        case .out: .plenty
        }
    }
}

/// `client_choice`: people pick their own items; `pre_packed`: boxes are made up in advance.
public enum PantryModel: String, Sendable, Codable, Hashable {
    case clientChoice = "client_choice"
    case prePacked = "pre_packed"
    case both
}

/// One current row of `pantry_inventory`, or a Feed America status merged in as `source == "feedam"`.
public struct PantryInventoryItem: Sendable, Hashable, Identifiable, Codable {
    public var id: UUID
    public var category: PantryCategory
    public var level: PantryLevel
    public var note: String?
    public var reportedAt: Date
    public var expiresAt: Date?
    /// `staff`, `feedam` or `demo`.
    public var source: String

    public init(
        id: UUID = UUID(),
        category: PantryCategory,
        level: PantryLevel,
        note: String? = nil,
        reportedAt: Date = Date(),
        expiresAt: Date? = nil,
        source: String = "staff"
    ) {
        self.id = id
        self.category = category
        self.level = level
        self.note = note
        self.reportedAt = reportedAt
        self.expiresAt = expiresAt ?? reportedAt.addingTimeInterval(24 * 3600)
        self.source = source
    }

    public func isExpired(at now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }

    private enum CodingKeys: String, CodingKey {
        case id, category, level, note, source
        case reportedAt = "reported_at"
        case expiresAt = "expires_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        category = try c.decode(PantryCategory.self, forKey: .category)
        level = try c.decode(PantryLevel.self, forKey: .level)
        note = try? c.decodeIfPresent(String.self, forKey: .note)
        let reported = (try? c.decodeIfPresent(String.self, forKey: .reportedAt)).flatMap(PostgresTimestamp.parse)
        reportedAt = reported ?? Date()
        expiresAt = (try? c.decodeIfPresent(String.self, forKey: .expiresAt)).flatMap(PostgresTimestamp.parse)
            ?? reportedAt.addingTimeInterval(24 * 3600)
        source = (try? c.decodeIfPresent(String.self, forKey: .source)) ?? "staff"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(category, forKey: .category)
        try c.encode(level, forKey: .level)
        try c.encodeIfPresent(note, forKey: .note)
        try c.encode(PostgresTimestamp.string(from: reportedAt), forKey: .reportedAt)
        try c.encodeIfPresent(expiresAt.map(PostgresTimestamp.string(from:)), forKey: .expiresAt)
        try c.encode(source, forKey: .source)
    }
}

/// One `pantry_slots` row with `remaining = capacity - booked`.
public struct PantrySlot: Sendable, Hashable, Identifiable, Codable {
    public var id: UUID
    public var locationID: UUID?
    public var startsAt: Date
    public var endsAt: Date
    public var capacity: Int
    public var booked: Int
    public var notes: String?

    public init(id: UUID = UUID(), locationID: UUID? = nil, startsAt: Date, endsAt: Date, capacity: Int, booked: Int = 0, notes: String? = nil) {
        self.id = id
        self.locationID = locationID
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.capacity = capacity
        self.booked = booked
        self.notes = notes
    }

    public var remaining: Int { max(0, capacity - booked) }
    public var isFull: Bool { remaining == 0 }
    public func isPast(at now: Date = Date()) -> Bool { endsAt <= now }
    public func isBookable(at now: Date = Date()) -> Bool { !isFull && !isPast(at: now) }
    public var durationMinutes: Int { Int(endsAt.timeIntervalSince(startsAt) / 60) }

    private enum CodingKeys: String, CodingKey {
        case id, capacity, booked, notes, remaining
        case locationID = "location_id"
        case startsAt = "starts_at"
        case endsAt = "ends_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        locationID = try? c.decodeIfPresent(UUID.self, forKey: .locationID)
        guard let start = PostgresTimestamp.parse(try c.decode(String.self, forKey: .startsAt)) else {
            throw DecodingError.dataCorruptedError(forKey: .startsAt, in: c, debugDescription: "bad timestamp")
        }
        guard let end = PostgresTimestamp.parse(try c.decode(String.self, forKey: .endsAt)) else {
            throw DecodingError.dataCorruptedError(forKey: .endsAt, in: c, debugDescription: "bad timestamp")
        }
        startsAt = start
        endsAt = end
        capacity = (try? c.decodeIfPresent(Int.self, forKey: .capacity)) ?? 0
        if let booked = try? c.decodeIfPresent(Int.self, forKey: .booked) {
            self.booked = booked
        } else if let remaining = try? c.decodeIfPresent(Int.self, forKey: .remaining) {
            self.booked = max(0, capacity - remaining)
        } else {
            self.booked = 0
        }
        notes = try? c.decodeIfPresent(String.self, forKey: .notes)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(locationID, forKey: .locationID)
        try c.encode(PostgresTimestamp.string(from: startsAt), forKey: .startsAt)
        try c.encode(PostgresTimestamp.string(from: endsAt), forKey: .endsAt)
        try c.encode(capacity, forKey: .capacity)
        try c.encode(booked, forKey: .booked)
        try c.encode(remaining, forKey: .remaining)
        try c.encodeIfPresent(notes, forKey: .notes)
    }
}

/// `pantry_availability(p_location_id)`: current stock + the next 14 days of slots.
public struct PantryAvailability: Sendable, Hashable, Codable {
    public var locationID: UUID?
    public var inventory: [PantryInventoryItem]
    public var slots: [PantrySlot]
    public var staffUpdatedAt: Date?
    /// Feed America's view of the listing, when the pantry has a `feedam_id` and the call succeeded.
    public var feedAmerica: FeedAmericaStatus?

    public init(locationID: UUID? = nil, inventory: [PantryInventoryItem] = [], slots: [PantrySlot] = [], staffUpdatedAt: Date? = nil, feedAmerica: FeedAmericaStatus? = nil) {
        self.locationID = locationID
        self.inventory = inventory
        self.slots = slots
        self.staffUpdatedAt = staffUpdatedAt
        self.feedAmerica = feedAmerica
    }

    public static let empty = PantryAvailability()

    /// Stock rows that have not expired, in category display order.
    public func currentInventory(at now: Date = Date()) -> [PantryInventoryItem] {
        inventory
            .filter { !$0.isExpired(at: now) }
            .sorted { PantryCategory.allCases.firstIndex(of: $0.category)! < PantryCategory.allCases.firstIndex(of: $1.category)! }
    }

    /// The newest `reported_at` among current rows ("Reported 2h ago").
    public func latestReportedAt(at now: Date = Date()) -> Date? {
        currentInventory(at: now).map(\.reportedAt).max()
    }

    /// Slots that can still be booked, soonest first.
    public func upcomingSlots(at now: Date = Date()) -> [PantrySlot] {
        slots.filter { !$0.isPast(at: now) }.sorted { $0.startsAt < $1.startsAt }
    }

    public func hasUpcomingSlots(at now: Date = Date()) -> Bool {
        slots.contains { $0.isBookable(at: now) }
    }

    /// Upcoming slots grouped by calendar day in `calendar`, days in order.
    public func slotsByDay(at now: Date = Date(), calendar: Calendar = .current) -> [(day: Date, slots: [PantrySlot])] {
        let grouped = Dictionary(grouping: upcomingSlots(at: now)) { calendar.startOfDay(for: $0.startsAt) }
        return grouped.keys.sorted().map { (day: $0, slots: grouped[$0]!) }
    }

    /// Adds Feed America's rows for categories the staff have not reported (a staff or demo row
    /// is newer and more specific, so it wins) and records the status itself.
    public func merging(feedAmerica status: FeedAmericaStatus?, at now: Date = Date()) -> PantryAvailability {
        var copy = self
        copy.feedAmerica = status
        guard let status else { return copy }
        let reported = Set(currentInventory(at: now).filter { $0.source != "feedam" }.map(\.category))
        let extra = status.inventory.filter { !reported.contains($0.category) && !$0.isExpired(at: now) }
        copy.inventory = inventory.filter { $0.source != "feedam" } + extra
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case inventory, slots
        case locationID = "location_id"
        case staffUpdatedAt = "staff_updated_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        locationID = try? c.decodeIfPresent(UUID.self, forKey: .locationID)
        inventory = ((try? c.decodeIfPresent([Lossy<PantryInventoryItem>].self, forKey: .inventory)) ?? []).compactMap(\.value)
        slots = ((try? c.decodeIfPresent([Lossy<PantrySlot>].self, forKey: .slots)) ?? []).compactMap(\.value)
        staffUpdatedAt = (try? c.decodeIfPresent(String.self, forKey: .staffUpdatedAt)).flatMap(PostgresTimestamp.parse)
        feedAmerica = nil
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(locationID, forKey: .locationID)
        try c.encode(inventory, forKey: .inventory)
        try c.encode(slots, forKey: .slots)
        try c.encodeIfPresent(staffUpdatedAt.map(PostgresTimestamp.string(from:)), forKey: .staffUpdatedAt)
    }
}

public enum PantryVisitStatus: String, Sendable, Codable, Hashable {
    case booked, cancelled, arrived
}

/// A booking, as returned by `book_visit` (no slot id / coordinates) and `my_visits` (everything).
public struct PantryVisit: Sendable, Hashable, Identifiable, Codable {
    public var id: UUID
    public var slotID: UUID?
    public var locationID: UUID?
    public var locationName: String
    public var address: String
    public var latitude: Double?
    public var longitude: Double?
    public var startsAt: Date
    public var endsAt: Date
    public var partySize: Int
    public var status: PantryVisitStatus
    public var confirmationCode: String
    public var cancelToken: UUID?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        slotID: UUID? = nil,
        locationID: UUID? = nil,
        locationName: String,
        address: String,
        latitude: Double? = nil,
        longitude: Double? = nil,
        startsAt: Date,
        endsAt: Date,
        partySize: Int = 1,
        status: PantryVisitStatus = .booked,
        confirmationCode: String,
        cancelToken: UUID? = UUID(),
        createdAt: Date = Date()
    ) {
        self.id = id
        self.slotID = slotID
        self.locationID = locationID
        self.locationName = locationName
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.partySize = partySize
        self.status = status
        self.confirmationCode = confirmationCode
        self.cancelToken = cancelToken
        self.createdAt = createdAt
    }

    public var coordinate: GeoPoint? {
        guard let latitude, let longitude else { return nil }
        return GeoPoint(latitude: latitude, longitude: longitude)
    }

    /// Booked (or arrived) and the slot has not ended yet.
    public func isUpcoming(at now: Date = Date()) -> Bool {
        status != .cancelled && endsAt > now
    }

    public var canCancel: Bool { status == .booked && cancelToken != nil }

    private enum CodingKeys: String, CodingKey {
        case address, status
        case id = "visit_id"
        case slotID = "slot_id"
        case locationID = "location_id"
        case locationName = "location_name"
        case lat, lng
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case partySize = "party_size"
        case confirmationCode = "confirmation_code"
        case cancelToken = "cancel_token"
        case createdAt = "created_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        slotID = try? c.decodeIfPresent(UUID.self, forKey: .slotID)
        locationID = try? c.decodeIfPresent(UUID.self, forKey: .locationID)
        locationName = (try? c.decodeIfPresent(String.self, forKey: .locationName)) ?? ""
        address = (try? c.decodeIfPresent(String.self, forKey: .address)) ?? ""
        latitude = try? c.decodeIfPresent(Double.self, forKey: .lat)
        longitude = try? c.decodeIfPresent(Double.self, forKey: .lng)
        guard let start = PostgresTimestamp.parse(try c.decode(String.self, forKey: .startsAt)),
              let end = PostgresTimestamp.parse(try c.decode(String.self, forKey: .endsAt)) else {
            throw DecodingError.dataCorruptedError(forKey: .startsAt, in: c, debugDescription: "bad timestamp")
        }
        startsAt = start
        endsAt = end
        partySize = (try? c.decodeIfPresent(Int.self, forKey: .partySize)) ?? 1
        status = (try? c.decodeIfPresent(PantryVisitStatus.self, forKey: .status)) ?? .booked
        confirmationCode = try c.decode(String.self, forKey: .confirmationCode)
        cancelToken = try? c.decodeIfPresent(UUID.self, forKey: .cancelToken)
        createdAt = (try? c.decodeIfPresent(String.self, forKey: .createdAt)).flatMap(PostgresTimestamp.parse) ?? Date()
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(slotID, forKey: .slotID)
        try c.encodeIfPresent(locationID, forKey: .locationID)
        try c.encode(locationName, forKey: .locationName)
        try c.encode(address, forKey: .address)
        try c.encodeIfPresent(latitude, forKey: .lat)
        try c.encodeIfPresent(longitude, forKey: .lng)
        try c.encode(PostgresTimestamp.string(from: startsAt), forKey: .startsAt)
        try c.encode(PostgresTimestamp.string(from: endsAt), forKey: .endsAt)
        try c.encode(partySize, forKey: .partySize)
        try c.encode(status, forKey: .status)
        try c.encode(confirmationCode, forKey: .confirmationCode)
        try c.encodeIfPresent(cancelToken, forKey: .cancelToken)
        try c.encode(PostgresTimestamp.string(from: createdAt), forKey: .createdAt)
    }
}

/// A validated staff code and the pantry it opens. The code itself is kept (the functions
/// re-validate it on every call); stored in the Keychain by the app.
public struct StaffSession: Sendable, Hashable, Codable {
    public var code: String
    public var locationID: UUID
    public var name: String
    public var address: String
    public var contactName: String?
    public var contactPhone: String?

    public init(code: String, locationID: UUID, name: String, address: String, contactName: String? = nil, contactPhone: String? = nil) {
        self.code = code
        self.locationID = locationID
        self.name = name
        self.address = address
        self.contactName = contactName
        self.contactPhone = contactPhone
    }

    private enum CodingKeys: String, CodingKey {
        case code, name, address
        case locationID = "location_id"
        case contactName = "contact_name"
        case contactPhone = "contact_phone"
    }

    /// Decodes the `staff_login` payload (which does not echo the code).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = (try? c.decodeIfPresent(String.self, forKey: .code)) ?? ""
        locationID = try c.decode(UUID.self, forKey: .locationID)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        address = (try? c.decodeIfPresent(String.self, forKey: .address)) ?? ""
        contactName = try? c.decodeIfPresent(String.self, forKey: .contactName)
        contactPhone = try? c.decodeIfPresent(String.self, forKey: .contactPhone)
    }

    /// Codes are 6 characters, upper case, no 0/O/1/I; normalises what the user typed.
    public static func normalize(code: String) -> String {
        code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().filter { $0.isLetter || $0.isNumber }
    }
}

/// One row of `staff_bookings(p_code, p_day)`.
public struct StaffBooking: Sendable, Hashable, Identifiable, Codable {
    public var id: UUID
    public var slotID: UUID?
    public var startsAt: Date
    public var endsAt: Date
    public var partySize: Int
    public var status: PantryVisitStatus
    public var confirmationCode: String
    public var createdAt: Date

    public init(id: UUID = UUID(), slotID: UUID? = nil, startsAt: Date, endsAt: Date, partySize: Int = 1, status: PantryVisitStatus = .booked, confirmationCode: String, createdAt: Date = Date()) {
        self.id = id
        self.slotID = slotID
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.partySize = partySize
        self.status = status
        self.confirmationCode = confirmationCode
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case id = "visit_id"
        case slotID = "slot_id"
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case partySize = "party_size"
        case confirmationCode = "confirmation_code"
        case createdAt = "created_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        slotID = try? c.decodeIfPresent(UUID.self, forKey: .slotID)
        guard let start = PostgresTimestamp.parse(try c.decode(String.self, forKey: .startsAt)),
              let end = PostgresTimestamp.parse(try c.decode(String.self, forKey: .endsAt)) else {
            throw DecodingError.dataCorruptedError(forKey: .startsAt, in: c, debugDescription: "bad timestamp")
        }
        startsAt = start
        endsAt = end
        partySize = (try? c.decodeIfPresent(Int.self, forKey: .partySize)) ?? 1
        status = (try? c.decodeIfPresent(PantryVisitStatus.self, forKey: .status)) ?? .booked
        confirmationCode = try c.decode(String.self, forKey: .confirmationCode)
        createdAt = (try? c.decodeIfPresent(String.self, forKey: .createdAt)).flatMap(PostgresTimestamp.parse) ?? Date()
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(slotID, forKey: .slotID)
        try c.encode(PostgresTimestamp.string(from: startsAt), forKey: .startsAt)
        try c.encode(PostgresTimestamp.string(from: endsAt), forKey: .endsAt)
        try c.encode(partySize, forKey: .partySize)
        try c.encode(status, forKey: .status)
        try c.encode(confirmationCode, forKey: .confirmationCode)
        try c.encode(PostgresTimestamp.string(from: createdAt), forKey: .createdAt)
    }
}

// MARK: - Helpers

/// Decodes to `nil` instead of failing, so one bad row in a jsonb array does not sink the rest.
public struct Lossy<T: Decodable>: Decodable {
    public let value: T?
    public init(from decoder: any Decoder) throws {
        value = try? T(from: decoder)
    }
}

/// Postgres `timestamptz` as PostgREST prints it: `2026-10-16T03:39:19.563+00:00`,
/// `2026-10-16T18:00:00+00:00`, `…Z`, six fractional digits, `+00` without minutes, or a space
/// instead of `T`. Output is always UTC `yyyy-MM-ddTHH:mm:ssZ`, which Postgres accepts back.
public enum PostgresTimestamp {
    public static func parse(_ raw: String) -> Date? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        guard s.count >= 19 else { return nil }
        if s.count > 10, s[s.index(s.startIndex, offsetBy: 10)] == " " {
            s.replaceSubrange(s.index(s.startIndex, offsetBy: 10)...s.index(s.startIndex, offsetBy: 10), with: "T")
        }
        // Split off the zone designator.
        var zone = "Z"
        var body = s
        if s.hasSuffix("Z") || s.hasSuffix("z") {
            body = String(s.dropLast())
        } else if let signIndex = s.lastIndex(where: { $0 == "+" || $0 == "-" }), s.distance(from: s.startIndex, to: signIndex) >= 19 {
            body = String(s[..<signIndex])
            var z = String(s[signIndex...])
            if z.count == 3 { z += ":00" }                       // +00 → +00:00
            if z.count == 5 { z.insert(":", at: z.index(z.startIndex, offsetBy: 3)) }  // +0000 → +00:00
            zone = z
        }
        // Normalise fractional seconds to exactly three digits (ISO8601DateFormatter's expectation).
        var fraction = ""
        if let dot = body.firstIndex(of: ".") {
            let digits = String(body[body.index(after: dot)...]).prefix(3)
            fraction = "." + digits.padding(toLength: 3, withPad: "0", startingAt: 0)
            body = String(body[..<dot])
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fraction.isEmpty ? [.withInternetDateTime] : [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: body + fraction + zone)
    }

    public static func string(from date: Date) -> String {
        date.ISO8601Format(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeZone(separator: .omitted))
    }
}
