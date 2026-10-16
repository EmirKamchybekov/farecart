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
    /// Which provider signed the user in (`"apple"`, `"google"`), from `app_metadata.provider`.
    /// Optional so sessions stored before it existed still decode.
    public var provider: String?

    public init(accessToken: String, refreshToken: String, expiresAt: Date, user: AuthUser, provider: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.user = user
        self.provider = provider
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
        self.init(
            accessToken: raw.accessToken,
            refreshToken: raw.refreshToken,
            expiresAt: expiresAt,
            user: raw.user.authUser,
            provider: raw.user.provider
        )
    }

    /// Builds a session from tokens that arrived without a token response (the implicit-flow
    /// fragment), once the user has been fetched from `GET auth/v1/user`.
    public init(accessToken: String, refreshToken: String, expiresIn: TimeInterval?, expiresAt: TimeInterval?, user: TokenResponse.User, now: Date = Date()) {
        let expiry: Date
        if let expiresAt {
            expiry = Date(timeIntervalSince1970: expiresAt)
        } else {
            expiry = now.addingTimeInterval(expiresIn ?? 3600)
        }
        self.init(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiry, user: user.authUser, provider: user.provider)
    }

    public struct TokenResponse: Decodable, Sendable {
        var accessToken: String
        var refreshToken: String
        var expiresIn: TimeInterval?
        var expiresAt: TimeInterval?
        var user: User

        /// The `user` object GoTrue returns in token responses and from `GET auth/v1/user`.
        public struct User: Decodable, Sendable {
            var id: UUID
            var email: String?
            var userMetadata: [String: JSONValue]?
            var appMetadata: [String: JSONValue]?

            enum CodingKeys: String, CodingKey {
                case id, email
                case userMetadata = "user_metadata"
                case appMetadata = "app_metadata"
            }

            var authUser: AuthUser {
                let metadata = userMetadata ?? [:]
                let name = metadata["full_name"]?.stringValue ?? metadata["name"]?.stringValue
                return AuthUser(id: id, email: email, fullName: name)
            }

            var provider: String? { appMetadata?["provider"]?.stringValue }
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
