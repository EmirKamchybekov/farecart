import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Supabase Auth (GoTrue) over plain URLSession: native Sign in with Apple token exchange,
/// refresh, sign-out and user metadata. No SDK.
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

    /// `POST auth/v1/token?grant_type=refresh_token`. Keeps the locally stored full name, which
    /// Apple only sends once.
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
