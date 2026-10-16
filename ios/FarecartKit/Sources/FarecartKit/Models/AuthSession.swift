import Foundation

/// The signed-in user as Supabase Auth describes them. `fullName` comes from Apple on the very
/// first sign-in only, so the app stores it alongside the session.
public struct AuthUser: Sendable, Hashable, Codable {
    public var id: UUID
    public var email: String?
    public var fullName: String?

    public init(id: UUID, email: String? = nil, fullName: String? = nil) {
        self.id = id
        self.email = email
        self.fullName = fullName
    }
}

/// Access + refresh tokens from `POST auth/v1/token`. Persisted in the Keychain by the app.
public struct AuthSession: Sendable, Hashable, Codable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var user: AuthUser

    public init(accessToken: String, refreshToken: String, expiresAt: Date, user: AuthUser) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.user = user
    }

    /// `true` when the access token expires within `leeway` (default one minute).
    public func isExpiring(within leeway: TimeInterval = 60, now: Date = Date()) -> Bool {
        expiresAt.timeIntervalSince(now) < leeway
    }

    /// Decodes the GoTrue token response. `expires_at` is unix seconds; falls back to `expires_in`.
    public init(tokenResponse data: Data, now: Date = Date()) throws {
        let raw = try PostgRESTDecoder.decode(TokenResponse.self, from: data)
        let expiresAt: Date
        if let at = raw.expiresAt {
            expiresAt = Date(timeIntervalSince1970: at)
        } else {
            expiresAt = now.addingTimeInterval(raw.expiresIn ?? 3600)
        }
        let metadata = raw.user.userMetadata ?? [:]
        let name = metadata["full_name"]?.stringValue ?? metadata["name"]?.stringValue
        self.init(
            accessToken: raw.accessToken,
            refreshToken: raw.refreshToken,
            expiresAt: expiresAt,
            user: AuthUser(id: raw.user.id, email: raw.user.email, fullName: name)
        )
    }

    struct TokenResponse: Decodable {
        var accessToken: String
        var refreshToken: String
        var expiresIn: TimeInterval?
        var expiresAt: TimeInterval?
        var user: User

        struct User: Decodable {
            var id: UUID
            var email: String?
            var userMetadata: [String: JSONValue]?

            enum CodingKeys: String, CodingKey {
                case id, email
                case userMetadata = "user_metadata"
            }
        }

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case expiresAt = "expires_at"
            case user
        }
    }
}

/// One row of `profiles`: the Discounts answers plus language and theme, synced for signed-in users.
public struct Profile: Sendable, Hashable, Codable {
    public var id: UUID
    public var householdSnap: Bool?
    public var isStudent: Bool?
    public var language: String?
    public var theme: String?
    public var updatedAt: String?

    public init(id: UUID, householdSnap: Bool? = nil, isStudent: Bool? = nil, language: String? = nil, theme: String? = nil, updatedAt: String? = nil) {
        self.id = id
        self.householdSnap = householdSnap
        self.isStudent = isStudent
        self.language = language
        self.theme = theme
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case householdSnap = "household_snap"
        case isStudent = "is_student"
        case language, theme
        case updatedAt = "updated_at"
    }
}
