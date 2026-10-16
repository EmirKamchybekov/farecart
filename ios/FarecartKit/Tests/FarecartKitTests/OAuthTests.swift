import Foundation
import Testing
@testable import FarecartKit

@Suite("Hosted OAuth with PKCE")
struct OAuthTests {
    let baseURL = URL(string: "https://example.supabase.co")!

    // MARK: PKCE

    @Test("Verifier uses the unreserved alphabet and stays within 43…128 characters")
    func verifier() {
        let v = PKCE.makeVerifier()
        #expect(v.count == 64)
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        #expect(v.allSatisfy { allowed.contains($0) })
        #expect(PKCE.makeVerifier(length: 10).count == 43)
        #expect(PKCE.makeVerifier(length: 500).count == 128)
        #expect(PKCE.makeVerifier() != PKCE.makeVerifier())
    }

    @Test("Challenge is base64url(SHA-256(verifier)) without padding (RFC 7636 appendix B)")
    func challenge() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(PKCE.challenge(for: verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(PKCE.base64URL(Data([0xfb, 0xff, 0xbf])) == "-_-_")
    }

    // MARK: Authorize URL + preflight

    @Test("Authorize URL carries provider, redirect, challenge and s256")
    func authorizeURL() throws {
        let auth = SupabaseAuthClient(baseURL: baseURL, anonKey: "anon", transport: StubTransport(body: ""))
        let url = try auth.authorizeURL(provider: "google", redirectTo: "farecart://auth-callback", codeChallenge: "abc-_")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "example.supabase.co")
        #expect(components.path == "/auth/v1/authorize")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
        #expect(items["provider"] == "google")
        #expect(items["redirect_to"] == "farecart://auth-callback")
        #expect(items["code_challenge"] == "abc-_")
        #expect(items["code_challenge_method"] == "s256")
        #expect(url.absoluteString.contains("redirect_to=farecart://auth-callback"))
    }

    @Test("Preflight reports a 400 'missing OAuth client ID' as not configured")
    func preflightNotConfigured() async throws {
        let transport = StubTransport(status: 400, body: #"{"code":400,"error_code":"validation_failed","msg":"Unsupported provider: missing OAuth client ID"}"#)
        let auth = SupabaseAuthClient(baseURL: baseURL, anonKey: "anon", transport: transport)
        let url = try auth.authorizeURL(provider: "google", redirectTo: "farecart://auth-callback", codeChallenge: "x")
        await #expect(throws: SupabaseAuthClient.ProviderNotConfigured(message: "Unsupported provider: missing OAuth client ID")) {
            try await auth.preflightAuthorize(url)
        }
        #expect(transport.requests.first?.value(forHTTPHeaderField: "apikey") == "anon")
    }

    @Test("Preflight passes when the provider page comes back")
    func preflightOK() async throws {
        let auth = SupabaseAuthClient(baseURL: baseURL, anonKey: "anon", transport: StubTransport(status: 200, body: "<html>Google</html>"))
        let url = try auth.authorizeURL(provider: "google", redirectTo: "farecart://auth-callback", codeChallenge: "x")
        try await auth.preflightAuthorize(url)
    }

    // MARK: Code exchange

    @Test("Code exchange posts auth_code + code_verifier to grant_type=pkce and reads the provider")
    func exchange() async throws {
        let json = AuthTests.tokenJSON.replacingOccurrences(
            of: "\"email\":\"a@example.com\"",
            with: "\"email\":\"a@example.com\",\"app_metadata\":{\"provider\":\"google\",\"providers\":[\"google\"]}"
        )
        let transport = StubTransport(body: json)
        let auth = SupabaseAuthClient(baseURL: baseURL, anonKey: "anon", transport: transport)
        let session = try await auth.exchangeCode(code: "code-123", codeVerifier: "verifier-456")
        #expect(session.accessToken == "jwt-1")
        #expect(session.refreshToken == "r-1")
        #expect(session.provider == "google")
        #expect(session.user.fullName == "Ada L")

        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://example.supabase.co/auth/v1/token?grant_type=pkce")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "apikey") == "anon")
        let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: Any]
        #expect(body?["auth_code"] as? String == "code-123")
        #expect(body?["code_verifier"] as? String == "verifier-456")
    }

    @Test("Fragment tokens become a session via GET auth/v1/user")
    func sessionFromTokens() async throws {
        let transport = StubTransport(body: """
        {"id":"3b7f0a2e-1d4c-4c8a-9b1e-2f5d6a7b8c9d","email":"g@example.com","app_metadata":{"provider":"google"},"user_metadata":{"name":"Grace H"}}
        """)
        let auth = SupabaseAuthClient(baseURL: baseURL, anonKey: "anon", transport: transport)
        let session = try await auth.session(accessToken: "jwt-9", refreshToken: "r-9", expiresIn: 3600, expiresAt: 1_800_000_000)
        #expect(session.accessToken == "jwt-9")
        #expect(session.provider == "google")
        #expect(session.user.fullName == "Grace H")
        #expect(session.user.email == "g@example.com")
        #expect(session.expiresAt == Date(timeIntervalSince1970: 1_800_000_000))
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://example.supabase.co/auth/v1/user")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer jwt-9")
    }

    @Test("Stored sessions without a provider still decode")
    func legacySessionDecodes() throws {
        let legacy = Data("""
        {"accessToken":"a","refreshToken":"r","expiresAt":700000000,"user":{"id":"3b7f0a2e-1d4c-4c8a-9b1e-2f5d6a7b8c9d"}}
        """.utf8)
        let session = try JSONDecoder().decode(AuthSession.self, from: legacy)
        #expect(session.provider == nil)
        #expect(session.accessToken == "a")
    }

    // MARK: Callback parsing

    @Test("Callback with ?code=")
    func callbackCode() throws {
        let url = try #require(URL(string: "farecart://auth-callback?code=abc-123"))
        #expect(OAuthCallback.matches(url, scheme: "farecart", host: "auth-callback"))
        #expect(OAuthCallback.matches(url, scheme: "FARECART", host: "Auth-Callback"))
        #expect(!OAuthCallback.matches(url, scheme: "https", host: "auth-callback"))
        #expect(OAuthCallback.parse(url) == .code("abc-123"))
    }

    @Test("Callback with tokens in the fragment")
    func callbackFragment() throws {
        let url = try #require(URL(string: "farecart://auth-callback#access_token=jwt&refresh_token=r1&expires_in=3600&expires_at=1800000000&token_type=bearer&type=signup"))
        #expect(OAuthCallback.parse(url) == .tokens(accessToken: "jwt", refreshToken: "r1", expiresIn: 3600, expiresAt: 1_800_000_000))
        let partial = try #require(URL(string: "farecart://auth-callback#access_token=jwt"))
        #expect(OAuthCallback.parse(partial) == nil)
    }

    @Test("Callback with an error in the query or the fragment, form-encoded description")
    func callbackError() throws {
        let query = try #require(URL(string: "farecart://auth-callback?error=server_error&error_code=unexpected_failure&error_description=Unable+to+exchange+external+code%3A+4%2F0abc"))
        #expect(OAuthCallback.parse(query) == .failure(code: "unexpected_failure", description: "Unable to exchange external code: 4/0abc"))
        let fragment = try #require(URL(string: "farecart://auth-callback#error=access_denied&error_description=The%20user%20denied%20access"))
        #expect(OAuthCallback.parse(fragment) == .failure(code: "access_denied", description: "The user denied access"))
        let onlyDescription = try #require(URL(string: "farecart://auth-callback/?error_description=Unsupported%20provider"))
        #expect(OAuthCallback.parse(onlyDescription) == .failure(code: nil, description: "Unsupported provider"))
        let empty = try #require(URL(string: "farecart://auth-callback"))
        #expect(OAuthCallback.parse(empty) == nil)
    }

    @Test("Query wins over the fragment when both carry a value")
    func callbackPrecedence() throws {
        let url = try #require(URL(string: "farecart://auth-callback?code=fromquery#code=fromfragment"))
        #expect(OAuthCallback.parse(url) == .code("fromquery"))
    }
}
