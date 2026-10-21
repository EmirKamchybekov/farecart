import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Supabase Auth (GoTrue) over plain URLSession: email + password accounts, native Sign in with
/// Apple token exchange, the hosted OAuth flow with PKCE (Google), refresh, sign-out and user
/// metadata. No SDK.
public struct SupabaseAuthClient: Sendable {
    public let baseURL: URL
    public let anonKey: String
    public let transport: any HTTPTransport

    public init(baseURL: URL, anonKey: String, transport: any HTTPTransport = URLSessionTransport()) {
        self.baseURL = baseURL
        self.anonKey = anonKey
        self.transport = transport
    }

    public init(config: AppConfig, transport: any HTTPTransport = URLSessionTransport()) {
        self.init(baseURL: config.supabaseURL, anonKey: config.supabaseAnonKey, transport: transport)
    }

    /// `POST auth/v1/token?grant_type=id_token` with the identity token Apple handed the app and
    /// the raw nonce whose SHA-256 was sent to Apple.
    public func signInWithApple(idToken: String, nonce: String) async throws -> AuthSession {
        let request = try makeRequest(
            path: "auth/v1/token",
            method: "POST",
            query: [URLQueryItem(name: "grant_type", value: "id_token")],
            body: ["provider": .string("apple"), "id_token": .string(idToken), "nonce": .string(nonce)]
        )
        let data = try await perform(request)
        return try AuthSession(tokenResponse: data)
    }

    // MARK: Email + password

    /// `POST auth/v1/signup` with `data.full_name`. With `mailer_autoconfirm` on (today) GoTrue
    /// answers with a full token response and the user is signed in; with confirmations on it
    /// answers with the bare user and a link is emailed (`.confirmationRequired`). `redirectTo` and
    /// `codeChallenge` make that link come back to the app with a PKCE `code`.
    /// Throws `AuthError` for GoTrue's error codes.
    public func signUp(email: String, password: String, name: String?, redirectTo: String? = nil, codeChallenge: String? = nil) async throws -> SignUpResult {
        var body: [String: JSONValue] = ["email": .string(Self.normalize(email: email)), "password": .string(password)]
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            body["data"] = .object(["full_name": .string(name)])
        }
        if let codeChallenge {
            body["code_challenge"] = .string(codeChallenge)
            body["code_challenge_method"] = .string("s256")
        }
        let request = try makeRequest(
            path: "auth/v1/signup",
            method: "POST",
            query: redirectTo.map { [URLQueryItem(name: "redirect_to", value: $0)] } ?? [],
            body: body
        )
        let data = try await performAuth(request)
        if let session = try? AuthSession(tokenResponse: data) {
            return .signedIn(session)
        }
        // No tokens: confirmation required. The body is the user itself.
        let user = try? PostgRESTDecoder.decode(AuthSession.TokenResponse.User.self, from: data)
        return .confirmationRequired(email: user?.email ?? Self.normalize(email: email))
    }

    /// `POST auth/v1/token?grant_type=password`. Throws `AuthError.invalidCredentials` for a wrong
    /// email or password, `.emailNotConfirmed` while the address is unconfirmed.
    public func signIn(email: String, password: String) async throws -> AuthSession {
        let request = try makeRequest(
            path: "auth/v1/token",
            method: "POST",
            query: [URLQueryItem(name: "grant_type", value: "password")],
            body: ["email": .string(Self.normalize(email: email)), "password": .string(password)]
        )
        let data = try await performAuth(request)
        return try AuthSession(tokenResponse: data)
    }

    /// `POST auth/v1/recover`: emails a reset link. GoTrue answers 200 whether or not the address
    /// has an account. With `codeChallenge` the link returns to `redirectTo?code=…`, which
    /// `exchangeCode` turns into a session that may set a new password (`updatePassword`).
    public func sendPasswordReset(email: String, redirectTo: String? = nil, codeChallenge: String? = nil) async throws {
        var body: [String: JSONValue] = ["email": .string(Self.normalize(email: email))]
        if let codeChallenge {
            body["code_challenge"] = .string(codeChallenge)
            body["code_challenge_method"] = .string("s256")
        }
        let request = try makeRequest(
            path: "auth/v1/recover",
            method: "POST",
            query: redirectTo.map { [URLQueryItem(name: "redirect_to", value: $0)] } ?? [],
            body: body
        )
        _ = try await performAuth(request)
    }

    /// `PUT auth/v1/user` with the new password (after a recovery sign-in).
    public func updatePassword(_ password: String, session: AuthSession) async throws {
        let request = try makeRequest(
            path: "auth/v1/user",
            method: "PUT",
            body: ["password": .string(password)],
            accessToken: session.accessToken
        )
        _ = try await performAuth(request)
    }

    /// Trimmed and lowercased, the way GoTrue stores addresses.
    public static func normalize(email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// `perform`, but non-2xx answers become `AuthError`.
    func performAuth(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw AuthError(status: response.statusCode, body: data)
        }
        return data
    }

    // MARK: Hosted OAuth (PKCE)

    /// Thrown by `preflightAuthorize` when the provider is disabled or has no client id, in which
    /// case GoTrue answers `/authorize` with a 400 JSON body instead of redirecting to the provider.
    public struct ProviderNotConfigured: Error, Sendable, Equatable {
        public let message: String
    }

    /// `{base}/auth/v1/authorize?provider=…&redirect_to=…&code_challenge=…&code_challenge_method=s256`
    /// to open in a web authentication session.
    public func authorizeURL(provider: String, redirectTo: String, codeChallenge: String) throws -> URL {
        guard var components = URLComponents(url: baseURL.appending(path: "auth/v1/authorize"), resolvingAgainstBaseURL: false) else {
            throw APIError.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "provider", value: provider),
            URLQueryItem(name: "redirect_to", value: redirectTo),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "s256"),
        ]
        guard let url = components.url else { throw APIError.invalidResponse }
        return url
    }

    /// Fetches the authorize URL once before showing it. A 4xx answer means the provider is not set
    /// up (`ProviderNotConfigured`); anything else (the provider's sign-in page, or a network
    /// error, which is swallowed so an offline phone still gets the browser's own error) proceeds.
    public func preflightAuthorize(_ url: URL) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await transport.send(request) else { return }
        guard (400..<500).contains(response.statusCode) else { return }
        let message = (try? PostgRESTDecoder.decode(GoTrueError.self, from: data))?.message
            ?? String(decoding: data.prefix(200), as: UTF8.self)
        throw ProviderNotConfigured(message: message)
    }

    /// `POST auth/v1/token?grant_type=pkce` with the `code` from the callback URL and the verifier
    /// whose challenge went to `/authorize`. Returns the same session shape as the Apple exchange.
    public func exchangeCode(code: String, codeVerifier: String) async throws -> AuthSession {
        let request = try makeRequest(
            path: "auth/v1/token",
            method: "POST",
            query: [URLQueryItem(name: "grant_type", value: "pkce")],
            body: ["auth_code": .string(code), "code_verifier": .string(codeVerifier)]
        )
        let data = try await perform(request)
        return try AuthSession(tokenResponse: data)
    }

    /// Builds a session from tokens that came back in the callback's fragment (implicit flow):
    /// `GET auth/v1/user` with the access token supplies the user.
    public func session(accessToken: String, refreshToken: String, expiresIn: TimeInterval?, expiresAt: TimeInterval?) async throws -> AuthSession {
        let request = try makeRequest(path: "auth/v1/user", method: "GET", accessToken: accessToken)
        let data = try await perform(request)
        let user = try PostgRESTDecoder.decode(AuthSession.TokenResponse.User.self, from: data)
        return AuthSession(accessToken: accessToken, refreshToken: refreshToken, expiresIn: expiresIn, expiresAt: expiresAt, user: user)
    }

    /// `{"code":400,"error_code":"validation_failed","msg":"Unsupported provider: …"}`, or the older
    /// `{"error":"…","error_description":"…"}` shape.
    struct GoTrueError: Decodable {
        var message: String
        /// `error_code` (newer GoTrue) or the older `error` field.
        var code: String?

        enum CodingKeys: String, CodingKey {
            case msg, error, message
            case errorCode = "error_code"
            case errorDescription = "error_description"
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard let text = try c.decodeIfPresent(String.self, forKey: .msg)
                ?? c.decodeIfPresent(String.self, forKey: .message)
                ?? c.decodeIfPresent(String.self, forKey: .errorDescription)
                ?? c.decodeIfPresent(String.self, forKey: .error) else {
                throw DecodingError.keyNotFound(CodingKeys.msg, .init(codingPath: c.codingPath, debugDescription: "No message"))
            }
            message = text
            code = try c.decodeIfPresent(String.self, forKey: .errorCode) ?? c.decodeIfPresent(String.self, forKey: .error)
        }
    }

    // MARK: Refresh / sign-out / profile

    /// `POST auth/v1/token?grant_type=refresh_token`. Keeps the locally stored full name, which
    /// Apple only sends once, and the provider when the response lacks it.
    public func refresh(_ session: AuthSession) async throws -> AuthSession {
        let request = try makeRequest(
            path: "auth/v1/token",
            method: "POST",
            query: [URLQueryItem(name: "grant_type", value: "refresh_token")],
            body: ["refresh_token": .string(session.refreshToken)]
        )
        let data = try await perform(request)
        var refreshed = try AuthSession(tokenResponse: data)
        if refreshed.user.fullName == nil { refreshed.user.fullName = session.user.fullName }
        if refreshed.provider == nil { refreshed.provider = session.provider }
        return refreshed
    }

    /// `POST auth/v1/logout`. Errors are not fatal: the app forgets the session either way.
    public func signOut(_ session: AuthSession) async throws {
        let request = try makeRequest(path: "auth/v1/logout", method: "POST", accessToken: session.accessToken)
        _ = try await perform(request)
    }

    /// `PUT auth/v1/user` storing the name Apple returned so it survives reinstalls.
    public func updateFullName(_ fullName: String, session: AuthSession) async throws {
        let request = try makeRequest(
            path: "auth/v1/user",
            method: "PUT",
            body: ["data": .object(["full_name": .string(fullName)])],
            accessToken: session.accessToken
        )
        _ = try await perform(request)
    }

    // MARK: Plumbing

    func makeRequest(
        path: String,
        method: String,
        query: [URLQueryItem] = [],
        body: [String: JSONValue]? = nil,
        accessToken: String? = nil
    ) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw APIError.invalidResponse
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw APIError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken ?? anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            request.httpBody = try encoder.encode(body)
        }
        return request
    }

    func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw APIError.httpStatus(response.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        return data
    }
}
