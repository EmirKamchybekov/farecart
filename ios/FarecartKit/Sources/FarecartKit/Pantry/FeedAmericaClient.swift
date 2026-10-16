import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `GET https://feedam.org/api/resources/{id}/status` (Feed America, CC BY 4.0). Today the
/// endpoint answers `{"id","phone_valid","phone_formatted","hours_status","days_since_verified",
/// "confidence"}`; the decoder also accepts any inventory-like array it may add later and
/// ignores everything it does not understand.
public struct FeedAmericaStatus: Sendable, Hashable, Codable {
    public var id: Int?
    /// `open`, `closed`, `unknown`, … as the API spells it.
    public var hoursStatus: String?
    public var confidence: String?
    public var daysSinceVerified: Int?
    public var phoneValid: Bool?
    public var phoneFormatted: String?
    /// Stock rows reported through Feed America, already tagged `source == "feedam"`.
    public var inventory: [PantryInventoryItem]
    public var fetchedAt: Date

    public init(id: Int? = nil, hoursStatus: String? = nil, confidence: String? = nil, daysSinceVerified: Int? = nil, phoneValid: Bool? = nil, phoneFormatted: String? = nil, inventory: [PantryInventoryItem] = [], fetchedAt: Date = Date()) {
        self.id = id
        self.hoursStatus = hoursStatus
        self.confidence = confidence
        self.daysSinceVerified = daysSinceVerified
        self.phoneValid = phoneValid
        self.phoneFormatted = phoneFormatted
        self.inventory = inventory
        self.fetchedAt = fetchedAt
    }

    /// `true` / `false` when Feed America says open / closed; `nil` for unknown.
    public var isOpen: Bool? {
        switch hoursStatus?.lowercased() {
        case "open", "open_now", "opened": true
        case "closed", "closed_now": false
        default: nil
        }
    }

    public static let attribution = "Directory published by Feed America (feedam.org)"

    /// Tolerant parse of the status payload. Returns `nil` only when the body is not a JSON object.
    public static func parse(_ data: Data, now: Date = Date()) -> FeedAmericaStatus? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var status = FeedAmericaStatus(fetchedAt: now)
        status.id = object["id"] as? Int ?? (object["id"] as? String).flatMap(Int.init)
        status.hoursStatus = (object["hours_status"] ?? object["status"]) as? String
        status.confidence = object["confidence"] as? String
        status.daysSinceVerified = object["days_since_verified"] as? Int
        status.phoneValid = object["phone_valid"] as? Bool
        status.phoneFormatted = object["phone_formatted"] as? String
        let updated = ((object["updated_at"] ?? object["reported_at"] ?? object["last_updated"]) as? String).flatMap(PostgresTimestamp.parse) ?? now
        for key in ["inventory", "stock", "items", "categories", "availability"] {
            guard let rows = object[key] as? [[String: Any]] else { continue }
            for row in rows {
                guard let item = inventoryItem(from: row, reportedAt: updated) else { continue }
                status.inventory.append(item)
            }
            break
        }
        // Flat form: {"produce": "low", "bread": "plenty"}.
        if status.inventory.isEmpty {
            for category in PantryCategory.allCases {
                guard let raw = object[category.rawValue] as? String, let level = level(from: raw) else { continue }
                status.inventory.append(PantryInventoryItem(category: category, level: level, reportedAt: updated, source: "feedam"))
            }
        }
        return status
    }

    static func inventoryItem(from row: [String: Any], reportedAt: Date) -> PantryInventoryItem? {
        let rawCategory = (row["category"] ?? row["name"] ?? row["type"]) as? String
        let rawLevel = (row["level"] ?? row["status"] ?? row["availability"]) as? String
        guard let rawCategory, let category = PantryCategory(rawValue: rawCategory.lowercased()),
              let rawLevel, let level = level(from: rawLevel) else { return nil }
        let reported = (row["reported_at"] as? String).flatMap(PostgresTimestamp.parse) ?? reportedAt
        return PantryInventoryItem(category: category, level: level, note: row["note"] as? String, reportedAt: reported, source: "feedam")
    }

    static func level(from raw: String) -> PantryLevel? {
        switch raw.lowercased().replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_") {
        case "plenty", "high", "good", "full", "in_stock", "available", "yes": .plenty
        case "low", "limited", "some", "running_low": .low
        case "out", "none", "empty", "out_of_stock", "no": .out
        default: nil
        }
    }
}

/// Fetches and caches Feed America statuses for 10 minutes per id. Never throws: a failure
/// just means "no Feed America status", and the status is a bonus on top of the pantry's own rows.
public actor FeedAmericaClient {
    public static let userAgent = "Farecart/0.1 (hello@farecart.org)"
    public static let cacheLifetime: TimeInterval = 10 * 60

    private let baseURL: URL
    private let transport: any HTTPTransport
    private var cache: [Int: (status: FeedAmericaStatus?, at: Date)] = [:]
    private var inFlight: [Int: Task<FeedAmericaStatus?, Never>] = [:]
    private let now: @Sendable () -> Date

    public init(baseURL: URL = URL(string: "https://feedam.org")!, transport: any HTTPTransport = URLSessionTransport(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.baseURL = baseURL
        self.transport = transport
        self.now = now
    }

    public func status(feedamID: Int) async -> FeedAmericaStatus? {
        if let cached = cache[feedamID], now().timeIntervalSince(cached.at) < Self.cacheLifetime {
            return cached.status
        }
        if let task = inFlight[feedamID] { return await task.value }
        let task = Task<FeedAmericaStatus?, Never> { [transport, baseURL] in
            var request = URLRequest(url: baseURL.appending(path: "api/resources/\(feedamID)/status"))
            request.timeoutInterval = 10
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            guard let (data, response) = try? await transport.send(request), (200..<300).contains(response.statusCode) else { return nil }
            return FeedAmericaStatus.parse(data)
        }
        inFlight[feedamID] = task
        let status = await task.value
        inFlight[feedamID] = nil
        cache[feedamID] = (status, now())
        return status
    }

    public func clearCache() {
        cache.removeAll()
    }
}
