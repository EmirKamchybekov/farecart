import Foundation

/// One row from `nearby_locations(...)` (or `locations`). `distanceMeters` is present only
/// when the row came from the RPC.
public struct Place: Sendable, Hashable, Identifiable, Codable {
    public var id: UUID
    public var name: String
    public var type: LocationType
    public var address: String
    public var neighborhood: String?
    public var latitude: Double
    public var longitude: Double
    /// Structured hours like `{"mon": "9:00-17:00", "sun": "closed"}`. Non-string values are dropped.
    public var hours: [String: String]?
    public var hoursText: String?
    public var acceptsEBT: Bool?
    public var requirements: String?
    public var languages: [String]
    public var phone: String?
    public var website: String?
    public var sourceURL: String?
    public var notes: String?
    /// Date-only (`yyyy-MM-dd`) in the database. `nil` until a human verifies the listing.
    public var verifiedOn: Date?
    /// Where the listing came from: `curated` (hand-researched), `usda_snap`, `osm`, `gcfd`, `plentiful`, `other`.
    public var sourceKind: String
    /// Chain or website favicon (`logo_url`), filled by the seed. `nil` when unknown or unparsable.
    public var logoURL: URL?
    public var distanceMeters: Double?

    public init(
        id: UUID = UUID(),
        name: String,
        type: LocationType,
        address: String,
        neighborhood: String? = nil,
        latitude: Double,
        longitude: Double,
        hours: [String: String]? = nil,
        hoursText: String? = nil,
        acceptsEBT: Bool? = nil,
        requirements: String? = nil,
        languages: [String] = [],
        phone: String? = nil,
        website: String? = nil,
        sourceURL: String? = nil,
        notes: String? = nil,
        verifiedOn: Date? = nil,
        sourceKind: String = "curated",
        logoURL: URL? = nil,
        distanceMeters: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.address = address
        self.neighborhood = neighborhood
        self.latitude = latitude
        self.longitude = longitude
        self.hours = hours
        self.hoursText = hoursText
        self.acceptsEBT = acceptsEBT
        self.requirements = requirements
        self.languages = languages
        self.phone = phone
        self.website = website
        self.sourceURL = sourceURL
        self.notes = notes
        self.verifiedOn = verifiedOn
        self.sourceKind = sourceKind
        self.logoURL = logoURL
        self.distanceMeters = distanceMeters
    }

    public var coordinate: GeoPoint { GeoPoint(latitude: latitude, longitude: longitude) }

    /// `tel:` URL for the phone number, or `nil` when there is no dialable number.
    public var phoneURL: URL? { DirectionsLinks.telephoneURL(phone) }

    public var websiteURL: URL? {
        guard let website, let url = URL(string: website), url.scheme != nil else { return nil }
        return url
    }

    public var isVerified: Bool { verifiedOn != nil }

    /// Human-readable origin of the listing, for the detail screen.
    public var sourceDescription: String {
        switch sourceKind {
        case "curated": "Researched by the Farecart team"
        case "usda_snap": "Listed by the USDA as a SNAP (Link) retailer"
        case "osm": "From OpenStreetMap (© OpenStreetMap contributors)"
        case "gcfd": "From the Greater Chicago Food Depository's Find Food map"
        case "plentiful": "From the Plentiful pantry directory"
        default: "From a public listing"
        }
    }

    // MARK: Codable (snake_case keys from PostgREST)

    private enum CodingKeys: String, CodingKey {
        case id, name, type, address, neighborhood, lat, lng, hours
        case hoursText = "hours_text"
        case acceptsEBT = "accepts_ebt"
        case requirements, languages, phone, website
        case sourceURL = "source_url"
        case notes
        case verifiedOn = "verified_on"
        case sourceKind = "source_kind"
        case logoURL = "logo_url"
        case distanceMeters = "distance_m"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decode(LocationType.self, forKey: .type)
        address = try c.decode(String.self, forKey: .address)
        neighborhood = try c.decodeIfPresent(String.self, forKey: .neighborhood)
        latitude = try c.decode(Double.self, forKey: .lat)
        longitude = try c.decode(Double.self, forKey: .lng)
        // `hours` is free-form jsonb; keep only the string values and ignore anything else.
        if let raw = try? c.decodeIfPresent([String: JSONValue].self, forKey: .hours) {
            let strings = raw.compactMapValues { value -> String? in
                if case .string(let s) = value { return s }
                return nil
            }
            hours = strings.isEmpty ? nil : strings
        } else {
            hours = nil
        }
        hoursText = try c.decodeIfPresent(String.self, forKey: .hoursText)
        acceptsEBT = try c.decodeIfPresent(Bool.self, forKey: .acceptsEBT)
        requirements = try c.decodeIfPresent(String.self, forKey: .requirements)
        languages = try c.decodeIfPresent([String].self, forKey: .languages) ?? []
        phone = try c.decodeIfPresent(String.self, forKey: .phone)
        website = try c.decodeIfPresent(String.self, forKey: .website)
        sourceURL = try c.decodeIfPresent(String.self, forKey: .sourceURL)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        if let dateString = try c.decodeIfPresent(String.self, forKey: .verifiedOn) {
            verifiedOn = PostgresDate.parse(dateString)
        } else {
            verifiedOn = nil
        }
        sourceKind = try c.decodeIfPresent(String.self, forKey: .sourceKind) ?? "curated"
        // Tolerant: a missing, null, empty or malformed value is simply "no logo".
        if let raw = try? c.decodeIfPresent(String.self, forKey: .logoURL),
           let url = URL(string: raw.trimmingCharacters(in: .whitespaces)),
           let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()), url.host() != nil {
            logoURL = url
        } else {
            logoURL = nil
        }
        distanceMeters = try c.decodeIfPresent(Double.self, forKey: .distanceMeters)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(type, forKey: .type)
        try c.encode(address, forKey: .address)
        try c.encodeIfPresent(neighborhood, forKey: .neighborhood)
        try c.encode(latitude, forKey: .lat)
        try c.encode(longitude, forKey: .lng)
        try c.encodeIfPresent(hours, forKey: .hours)
        try c.encodeIfPresent(hoursText, forKey: .hoursText)
        try c.encodeIfPresent(acceptsEBT, forKey: .acceptsEBT)
        try c.encodeIfPresent(requirements, forKey: .requirements)
        try c.encode(languages, forKey: .languages)
        try c.encodeIfPresent(phone, forKey: .phone)
        try c.encodeIfPresent(website, forKey: .website)
        try c.encodeIfPresent(sourceURL, forKey: .sourceURL)
        try c.encodeIfPresent(notes, forKey: .notes)
        try c.encodeIfPresent(verifiedOn.map(PostgresDate.string(from:)), forKey: .verifiedOn)
        try c.encode(sourceKind, forKey: .sourceKind)
        try c.encodeIfPresent(logoURL?.absoluteString, forKey: .logoURL)
        try c.encodeIfPresent(distanceMeters, forKey: .distanceMeters)
    }
}

/// Minimal JSON tree used to decode loosely-typed jsonb columns without crashing.
public enum JSONValue: Sendable, Hashable, Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

/// Parses/prints Postgres `date` values (`yyyy-MM-dd`) and tolerates full timestamps.
public enum PostgresDate {
    private static let dayFormat: Date.ISO8601FormatStyle = .init(timeZone: .gmt).year().month().day()

    public static func parse(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        if let date = try? dayFormat.parse(trimmed) { return date }
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(trimmed) { return date }
        if let date = try? Date.ISO8601FormatStyle().parse(trimmed) { return date }
        return nil
    }

    public static func string(from date: Date) -> String {
        date.formatted(dayFormat)
    }
}
