import Foundation

public enum TransitMode: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case bus
    case train

    public var id: String { rawValue }

    public var symbolName: String {
        switch self {
        case .bus: "bus.fill"
        case .train: "tram.fill"
        }
    }
}

/// Mirrors `fares.rider`.
public enum RiderCategory: String, Codable, Sendable, Hashable, CaseIterable {
    case full
    case reducedAccess = "reduced_access"
    case student
    case seniorDisabled = "senior_disabled"

    /// Key in the `programs` table that explains this discount (nil for full fare).
    public var programKey: String? {
        switch self {
        case .full: nil
        case .reducedAccess: "access"
        case .student: "student"
        case .seniorDisabled: "senior_disabled"
        }
    }
}

/// One row of the `fares` table.
public struct Fare: Sendable, Hashable, Identifiable, Codable {
    public var id: Int
    public var agency: String
    public var mode: TransitMode
    public var rider: RiderCategory
    public var priceCents: Int
    public var label: String
    public var howToGet: String?
    public var signupURL: String?
    public var effectiveOn: Date?
    public var sourceURL: String?
    /// Price of each further boarding within `transferWindowMinutes` of the first (CTA: $0).
    public var transferCents: Int
    /// How long after the first boarding transfers stay valid (CTA: 120 minutes).
    public var transferWindowMinutes: Int
    /// How many transfers one fare covers (CTA: 2).
    public var maxTransfers: Int

    public init(
        id: Int,
        agency: String = "CTA",
        mode: TransitMode,
        rider: RiderCategory,
        priceCents: Int,
        label: String,
        howToGet: String? = nil,
        signupURL: String? = nil,
        effectiveOn: Date? = nil,
        sourceURL: String? = nil,
        transferCents: Int = 0,
        transferWindowMinutes: Int = 120,
        maxTransfers: Int = 2
    ) {
        self.id = id
        self.agency = agency
        self.mode = mode
        self.rider = rider
        self.priceCents = priceCents
        self.label = label
        self.howToGet = howToGet
        self.signupURL = signupURL
        self.effectiveOn = effectiveOn
        self.sourceURL = sourceURL
        self.transferCents = transferCents
        self.transferWindowMinutes = transferWindowMinutes
        self.maxTransfers = maxTransfers
    }

    private enum CodingKeys: String, CodingKey {
        case id, agency, mode, rider
        case priceCents = "price_cents"
        case label
        case howToGet = "how_to_get"
        case signupURL = "signup_url"
        case effectiveOn = "effective_on"
        case sourceURL = "source_url"
        case transferCents = "transfer_cents"
        case transferWindowMinutes = "transfer_window_min"
        case maxTransfers = "max_transfers"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        agency = try c.decodeIfPresent(String.self, forKey: .agency) ?? "CTA"
        mode = try c.decode(TransitMode.self, forKey: .mode)
        rider = try c.decode(RiderCategory.self, forKey: .rider)
        priceCents = try c.decode(Int.self, forKey: .priceCents)
        label = try c.decode(String.self, forKey: .label)
        howToGet = try c.decodeIfPresent(String.self, forKey: .howToGet)
        signupURL = try c.decodeIfPresent(String.self, forKey: .signupURL)
        effectiveOn = try c.decodeIfPresent(String.self, forKey: .effectiveOn).flatMap(PostgresDate.parse)
        sourceURL = try c.decodeIfPresent(String.self, forKey: .sourceURL)
        // Older rows (before migration 0003) lack the transfer columns; CTA's defaults apply.
        transferCents = try c.decodeIfPresent(Int.self, forKey: .transferCents) ?? 0
        transferWindowMinutes = try c.decodeIfPresent(Int.self, forKey: .transferWindowMinutes) ?? 120
        maxTransfers = try c.decodeIfPresent(Int.self, forKey: .maxTransfers) ?? 2
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(agency, forKey: .agency)
        try c.encode(mode, forKey: .mode)
        try c.encode(rider, forKey: .rider)
        try c.encode(priceCents, forKey: .priceCents)
        try c.encode(label, forKey: .label)
        try c.encodeIfPresent(howToGet, forKey: .howToGet)
        try c.encodeIfPresent(signupURL, forKey: .signupURL)
        try c.encodeIfPresent(effectiveOn.map(PostgresDate.string(from:)), forKey: .effectiveOn)
        try c.encodeIfPresent(sourceURL, forKey: .sourceURL)
        try c.encode(transferCents, forKey: .transferCents)
        try c.encode(transferWindowMinutes, forKey: .transferWindowMinutes)
        try c.encode(maxTransfers, forKey: .maxTransfers)
    }
}
