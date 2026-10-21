import Foundation
import Testing
@testable import FarecartKit

@Suite("Email accounts and account visits")
struct AccountTests {
    let baseURL = URL(string: "https://example.supabase.co")!

    private func body(of request: URLRequest?) throws -> [String: Any] {
        let data = try #require(request?.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("signUp posts email, password and full_name and returns the session when autoconfirmed")
    func signUpSignedIn() async throws {
        let json = AuthTests.tokenJSON.replacingOccurrences(of: "\"user_metadata\"", with: "\"app_metadata\":{\"provider\":\"email\"},\"user_metadata\"")
        let transport = StubTransport(body: json)
        let auth = SupabaseAuthClient(baseURL: baseURL, anonKey: "anon", transport: transport)
        let result = try await auth.signUp(email: "  Ada@Example.com ", password: "correct-horse", name: " Ada L ")
        guard case .signedIn(let session) = result else { Issue.record("expected a session"); return }
        #expect(session.accessToken == "jwt-1")
        #expect(session.provider == "email")
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://example.supabase.co/auth/v1/signup")
        #expect(request.httpMethod == "POST")
        let sent = try body(of: request)
        #expect(sent["email"] as? String == "ada@example.com")
        #expect(sent["password"] as? String == "correct-horse")
        #expect((sent["data"] as? [String: Any])?["full_name"] as? String == "Ada L")
    }

    @Test("signUp without tokens means a confirmation email went out; PKCE + redirect are sent")
    func signUpConfirmation() async throws {
        let transport = StubTransport(body: #"{"id":"3b7f0a2e-1d4c-4c8a-9b1e-2f5d6a7b8c9d","email":"ada@example.com","confirmation_sent_at":"2026-10-20T10:00:00Z"}"#)
        let auth = SupabaseAuthClient(baseURL: baseURL, anonKey: "anon", transport: transport)
        let result = try await auth.signUp(email: "ada@example.com", password: "correct-horse", name: nil, redirectTo: "farecart://auth-callback", codeChallenge: "abc")
        #expect(result == .confirmationRequired(email: "ada@example.com"))
        let request = try #require(transport.requests.first)
        #expect(request.url?.query() == "redirect_to=farecart://auth-callback")
        let sent = try body(of: request)
        #expect(sent["data"] == nil)
        #expect(sent["code_challenge"] as? String == "abc")
        #expect(sent["code_challenge_method"] as? String == "s256")
    }

    @Test("signIn uses grant_type=password")
    func signIn() async throws {
        let transport = StubTransport(body: AuthTests.tokenJSON)
        let auth = SupabaseAuthClient(baseURL: baseURL, anonKey: "anon", transport: transport)
        let session = try await auth.signIn(email: "a@example.com", password: "pw-123456")
        #expect(session.refreshToken == "r-1")
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://example.supabase.co/auth/v1/token?grant_type=password")
        #expect(try body(of: request)["password"] as? String == "pw-123456")
    }

    @Test("sendPasswordReset posts to /recover")
    func recover() async throws {
        let transport = StubTransport(body: "{}")
        let auth = SupabaseAuthClient(baseURL: baseURL, anonKey: "anon", transport: transport)
        try await auth.sendPasswordReset(email: "A@example.com", redirectTo: "farecart://auth-callback", codeChallenge: "c")
        let request = try #require(transport.requests.first)
        #expect(request.url?.path() == "/auth/v1/recover")
        #expect(try body(of: request)["email"] as? String == "a@example.com")
    }

    @Test("updatePassword sends the user's JWT")
    func updatePassword() async throws {
        let transport = StubTransport(body: "{}")
        let auth = SupabaseAuthClient(baseURL: baseURL, anonKey: "anon", transport: transport)
        let session = AuthSession(accessToken: "jwt-9", refreshToken: "r", expiresAt: .distantFuture, user: AuthUser(id: UUID()))
        try await auth.updatePassword("new-password-1", session: session)
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "PUT")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer jwt-9")
    }

    @Test("GoTrue error codes map to AuthError", arguments: [
        (400, #"{"code":400,"error_code":"invalid_credentials","msg":"Invalid login credentials"}"#, AuthError.invalidCredentials),
        (422, #"{"code":422,"error_code":"user_already_exists","msg":"User already registered"}"#, .userAlreadyExists),
        (422, #"{"code":422,"error_code":"email_exists","msg":"Email address already exists"}"#, .userAlreadyExists),
        (422, #"{"code":422,"error_code":"weak_password","msg":"Password should be at least 8 characters.","weak_password":{"reasons":["length"]}}"#, .weakPassword("Password should be at least 8 characters.")),
        (400, #"{"code":400,"error_code":"email_not_confirmed","msg":"Email not confirmed"}"#, .emailNotConfirmed),
        (429, #"{"code":429,"error_code":"over_email_send_rate_limit","msg":"email rate limit exceeded"}"#, .rateLimited),
        (400, #"{"code":400,"error_code":"email_address_invalid","msg":"Email address \"x\" is invalid"}"#, .invalidEmail),
        (400, #"{"error":"invalid_grant","error_description":"Invalid login credentials"}"#, .invalidCredentials),
        (429, "Too Many Requests", .rateLimited),
    ])
    func errors(status: Int, json: String, expected: AuthError) async throws {
        let auth = SupabaseAuthClient(baseURL: baseURL, anonKey: "anon", transport: StubTransport(status: status, body: json))
        await #expect(throws: expected) {
            _ = try await auth.signIn(email: "a@example.com", password: "whatever-1")
        }
    }

    @Test("Unknown GoTrue errors keep status, code and message")
    func otherError() {
        let error = AuthError(status: 500, body: Data(#"{"code":500,"error_code":"unexpected_failure","msg":"boom"}"#.utf8))
        #expect(error == .other(status: 500, code: "unexpected_failure", message: "boom"))
    }

    @Test("Account RPCs send the JWT; guest calls send the anon key")
    func accountRPCs() async throws {
        let transport = StubTransport(body: "[]")
        let client = SupabaseClient(baseURL: baseURL, anonKey: "anon", transport: transport)
        _ = try await client.accountVisits(accessToken: "jwt-1")
        _ = try await client.myVisits(deviceID: "device-12345678", accessToken: "jwt-1")
        _ = try await client.myVisits(deviceID: "device-12345678")
        let requests = transport.requests
        #expect(requests[0].url?.path() == "/rest/v1/rpc/my_account_visits")
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer jwt-1")
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer jwt-1")
        #expect(requests[2].value(forHTTPHeaderField: "Authorization") == "Bearer anon")

        let claim = StubTransport(body: "2")
        let count = try await SupabaseClient(baseURL: baseURL, anonKey: "anon", transport: claim).claimDeviceVisits(deviceID: "device-12345678", accessToken: "jwt-2")
        #expect(count == 2)
        #expect(claim.requests.first?.url?.path() == "/rest/v1/rpc/claim_device_visits")
        #expect(try body(of: claim.requests.first)["p_device_id"] as? String == "device-12345678")

        let delete = StubTransport(body: "true")
        try await SupabaseClient(baseURL: baseURL, anonKey: "anon", transport: delete).deleteMyAccount(accessToken: "jwt-3")
        #expect(delete.requests.first?.url?.path() == "/rest/v1/rpc/delete_my_account")
        #expect(delete.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer jwt-3")
    }

    @Test("Device and account visits merge by id, upcoming first")
    func merge() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let shared = UUID()
        let device = [
            PantryVisit(id: shared, slotID: UUID(), locationName: "A", address: "", latitude: 41.8, longitude: -87.7,
                        startsAt: now.addingTimeInterval(7200), endsAt: now.addingTimeInterval(9000), confirmationCode: "AAAAAA"),
            PantryVisit(locationName: "Past", address: "", startsAt: now.addingTimeInterval(-90000), endsAt: now.addingTimeInterval(-88000), confirmationCode: "PPPPPP"),
        ]
        let account = [
            PantryVisit(id: shared, locationName: "A", address: "", startsAt: now.addingTimeInterval(7200), endsAt: now.addingTimeInterval(9000), confirmationCode: "AAAAAA"),
            PantryVisit(locationName: "Other phone", address: "", startsAt: now.addingTimeInterval(3600), endsAt: now.addingTimeInterval(5400), confirmationCode: "OOOOOO"),
        ]
        let merged = VisitMerge.merge(device: device, account: account, now: now)
        #expect(merged.map(\.confirmationCode) == ["OOOOOO", "AAAAAA", "PPPPPP"])
        #expect(merged[1].latitude == 41.8)
        #expect(merged[1].slotID != nil)
    }

    @Test("Mock claims a device's guest visits once")
    func mockClaim() async throws {
        let service = MockPantryService()
        let place = try #require(MockData.places.first { $0.type == .pantry })
        let slot = try #require(try await service.availability(locationID: place.id).slots.first)
        _ = try await service.bookVisit(slotID: slot.id, deviceID: "device-aaaa", partySize: 1, userID: nil)
        #expect(try await service.claimDeviceVisits(deviceID: "device-aaaa", accessToken: "jwt") == 1)
        #expect(try await service.claimDeviceVisits(deviceID: "device-aaaa", accessToken: "jwt") == 0)
        #expect(try await service.accountVisits(accessToken: "jwt").count == 1)
        #expect(try await service.accountVisits(accessToken: "other").isEmpty)
    }
}
