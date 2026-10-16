import Foundation
import Testing
@testable import FarecartKit

@Suite("Auth and profiles")
struct AuthTests {
    let baseURL = URL(string: "https://example.supabase.co")!

    static let tokenJSON = """
    {"access_token":"jwt-1","token_type":"bearer","expires_in":3600,"expires_at":1800000000,"refresh_token":"r-1",
     "user":{"id":"3b7f0a2e-1d4c-4c8a-9b1e-2f5d6a7b8c9d","email":"a@example.com","user_metadata":{"full_name":"Ada L"}}}
    """

    @Test("Apple id_token exchange posts provider, token and nonce")
    func signIn() async throws {
        let transport = StubTransport(body: Self.tokenJSON)
        let auth = SupabaseAuthClient(baseURL: baseURL, anonKey: "anon", transport: transport)
        let session = try await auth.signInWithApple(idToken: "apple-jwt", nonce: "raw-nonce")
        #expect(session.accessToken == "jwt-1")
        #expect(session.refreshToken == "r-1")
        #expect(session.user.email == "a@example.com")
        #expect(session.user.fullName == "Ada L")
        #expect(session.expiresAt == Date(timeIntervalSince1970: 1_800_000_000))

        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://example.supabase.co/auth/v1/token?grant_type=id_token")
        #expect(request.value(forHTTPHeaderField: "apikey") == "anon")
        let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: Any]
        #expect(body?["provider"] as? String == "apple")
        #expect(body?["id_token"] as? String == "apple-jwt")
        #expect(body?["nonce"] as? String == "raw-nonce")
    }

    @Test("Refresh keeps the locally known name and uses grant_type=refresh_token")
    func refresh() async throws {
        let json = Self.tokenJSON.replacingOccurrences(of: ",\"user_metadata\":{\"full_name\":\"Ada L\"}", with: "")
        let transport = StubTransport(body: json)
        let auth = SupabaseAuthClient(baseURL: baseURL, anonKey: "anon", transport: transport)
        let old = AuthSession(accessToken: "x", refreshToken: "r-0", expiresAt: .distantPast,
                              user: AuthUser(id: UUID(), email: nil, fullName: "Ada L"))
        #expect(old.isExpiring())
        let new = try await auth.refresh(old)
        #expect(new.user.fullName == "Ada L")
        #expect(transport.requests.first?.url?.query() == "grant_type=refresh_token")
        let body = try JSONSerialization.jsonObject(with: try #require(transport.requests.first?.httpBody)) as? [String: Any]
        #expect(body?["refresh_token"] as? String == "r-0")
    }

    @Test("Profile upsert sends the user's JWT and merge-duplicates")
    func upsert() async throws {
        let id = UUID(uuidString: "3b7f0a2e-1d4c-4c8a-9b1e-2f5d6a7b8c9d")!
        let transport = StubTransport(body: """
        [{"id":"3b7f0a2e-1d4c-4c8a-9b1e-2f5d6a7b8c9d","household_snap":true,"is_student":null,"language":"es","theme":"dark","updated_at":"2026-10-15T12:00:00+00:00"}]
        """)
        let client = SupabaseClient(baseURL: baseURL, anonKey: "anon", transport: transport)
        let saved = try await client.upsertProfile(Profile(id: id, householdSnap: true, language: "es", theme: "dark"), accessToken: "jwt-1")
        #expect(saved.householdSnap == true)
        #expect(saved.isStudent == nil)
        #expect(saved.language == "es")

        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://example.supabase.co/rest/v1/profiles")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer jwt-1")
        #expect(request.value(forHTTPHeaderField: "apikey") == "anon")
        #expect(request.value(forHTTPHeaderField: "Prefer") == "resolution=merge-duplicates,return=representation")
        let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: Any]
        #expect(body?["id"] as? String == id.uuidString.lowercased())
        #expect(body?["household_snap"] as? Bool == true)
        #expect(body?["is_student"] is NSNull)
    }

    @Test("Profile fetch filters by id and returns nil when empty")
    func fetch() async throws {
        let transport = StubTransport(body: "[]")
        let client = SupabaseClient(baseURL: baseURL, anonKey: "anon", transport: transport)
        let id = UUID()
        let row = try await client.profile(id: id, accessToken: "jwt")
        #expect(row == nil)
        #expect(transport.requests.first?.url?.query()?.contains("id=eq.\(id.uuidString.lowercased())") == true)
    }
}
