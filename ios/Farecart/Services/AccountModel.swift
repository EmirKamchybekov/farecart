import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import SwiftUI
import FarecartKit

/// Optional account: Sign in with Apple → Supabase session in the Keychain → `profiles` row kept in
/// step with the Discounts answers, language and theme. Everything works signed out.
@MainActor
@Observable
final class AccountModel {
    private(set) var session: AuthSession?
    private(set) var isBusy = false
    /// Friendly, already localized message for the Account section; `nil` when all is well.
    private(set) var errorMessage: String?

    var isSignedIn: Bool { session != nil }
    var displayName: String? {
        guard let user = session?.user else { return nil }
        if let name = user.fullName, !name.isEmpty { return name }
        return user.email
    }

    private var auth: SupabaseAuthClient?
    private var data: SupabaseClient?
    private let keychain = Keychain()
    private static let keychainAccount = "supabase.session"
    /// Raw nonce for the Apple request in flight; its SHA-256 went to Apple.
    private var pendingNonce: String?

    // MARK: Launch

    /// Loads the stored session, refreshes it when needed and pulls the profile down.
    func restore(environment: AppEnvironment) async {
        guard let config = environment.config else { return }
        auth = SupabaseAuthClient(config: config)
        data = SupabaseClient(config: config)
        guard let stored = try? keychain.read(account: Self.keychainAccount),
              var restored = try? JSONDecoder().decode(AuthSession.self, from: stored) else { return }
        if restored.isExpiring() {
            do {
                restored = try await auth!.refresh(restored)
                persist(restored)
            } catch APIError.httpStatus(let code, _) where (400..<500).contains(code) {
                // Refresh token revoked or expired: forget the session quietly.
                forget()
                return
            } catch {
                // Offline: keep the stale session and try again next launch.
            }
        }
        session = restored
        await pullProfile()
    }

    // MARK: Sign in with Apple

    /// Prepares the `ASAuthorizationAppleIDRequest`: scopes plus a hashed nonce.
    func configure(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = Self.randomNonce()
        pendingNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(nonce)
        errorMessage = nil
    }

    /// Finishes the Apple flow: exchanges the identity token with Supabase and stores the session.
    func complete(_ result: Result<ASAuthorization, any Error>) async {
        switch result {
        case .failure(let error):
            if let authError = error as? ASAuthorizationError, authError.code == .canceled { return }
            errorMessage = String(localized: "Sign in with Apple is not available on this device right now. You can keep using Farecart without an account.", bundle: LanguageBundle.current)
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8),
                  let nonce = pendingNonce else {
                errorMessage = String(localized: "Sign in with Apple did not finish. Please try again.", bundle: LanguageBundle.current)
                return
            }
            guard let auth else {
                errorMessage = String(localized: "Sign in needs the app's Supabase settings, which are missing in this build.", bundle: LanguageBundle.current)
                return
            }
            isBusy = true
            defer { isBusy = false }
            do {
                var newSession = try await auth.signInWithApple(idToken: idToken, nonce: nonce)
                if let name = Self.formatted(credential.fullName), !name.isEmpty {
                    newSession.user.fullName = name
                    try? await auth.updateFullName(name, session: newSession)
                }
                if newSession.user.email == nil, let email = credential.email { newSession.user.email = email }
                persist(newSession)
                session = newSession
                errorMessage = nil
                await pullProfile(preferLocalAnswers: true)
            } catch {
                errorMessage = String(localized: "Could not sign in right now. Check your connection and try again.", bundle: LanguageBundle.current)
            }
        }
        pendingNonce = nil
    }

    func signOut() async {
        if let session, let auth {
            try? await auth.signOut(session)
        }
        forget()
    }

    // MARK: Profile sync

    /// Writes the local answers, language and theme to `profiles`. No-op when signed out.
    func pushProfile() async {
        guard let session = await freshSession(), let data else { return }
        let defaults = UserDefaults.standard
        let profile = Profile(
            id: session.user.id,
            householdSnap: defaults.bool(forKey: DiscountsKeys.hasAnswered) ? defaults.bool(forKey: DiscountsKeys.householdSNAP) : nil,
            isStudent: defaults.bool(forKey: DiscountsKeys.hasAnswered) ? defaults.bool(forKey: DiscountsKeys.isStudent) : nil,
            language: AppLanguage.selected.rawValue,
            theme: (defaults.string(forKey: AppTheme.storageKey) ?? AppTheme.system.rawValue)
        )
        _ = try? await data.upsertProfile(profile, accessToken: session.accessToken)
    }

    /// Reads the row back and applies it locally. Right after sign-in the phone's own answers win
    /// (`preferLocalAnswers`) so a fresh sign-in never wipes what the user just chose.
    private func pullProfile(preferLocalAnswers: Bool = false) async {
        guard let session = await freshSession(), let data else { return }
        guard let remote = try? await data.profile(id: session.user.id, accessToken: session.accessToken) else {
            if preferLocalAnswers { await pushProfile() }
            return
        }
        let defaults = UserDefaults.standard
        let hasLocalAnswers = defaults.bool(forKey: DiscountsKeys.hasAnswered)
        if !(preferLocalAnswers && hasLocalAnswers), let snap = remote.householdSnap, let student = remote.isStudent {
            defaults.set(snap, forKey: DiscountsKeys.householdSNAP)
            defaults.set(student, forKey: DiscountsKeys.isStudent)
            defaults.set(true, forKey: DiscountsKeys.hasAnswered)
        }
        if !preferLocalAnswers {
            if let language = remote.language, AppLanguage(rawValue: language) != nil {
                defaults.set(language, forKey: AppLanguage.storageKey)
            }
            if let theme = remote.theme, AppTheme(rawValue: theme) != nil {
                defaults.set(theme, forKey: AppTheme.storageKey)
            }
        }
        await pushProfile()
    }

    // MARK: Helpers

    private func freshSession() async -> AuthSession? {
        guard var current = session, let auth else { return nil }
        guard current.isExpiring() else { return current }
        do {
            current = try await auth.refresh(current)
            persist(current)
            session = current
            return current
        } catch APIError.httpStatus(let code, _) where (400..<500).contains(code) {
            forget()
            return nil
        } catch {
            return nil
        }
    }

    private func persist(_ session: AuthSession) {
        if let data = try? JSONEncoder().encode(session) {
            try? keychain.write(data, account: Self.keychainAccount)
        }
    }

    private func forget() {
        try? keychain.delete(account: Self.keychainAccount)
        session = nil
    }

    private static func formatted(_ components: PersonNameComponents?) -> String? {
        guard let components else { return nil }
        return PersonNameComponentsFormatter.localizedString(from: components, style: .default)
    }

    private static func randomNonce(length: Int = 32) -> String {
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] })
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// The Apple button plus the friendly error line, shared by Settings and onboarding.
struct SignInWithAppleRow: View {
    @Environment(AccountModel.self) private var account
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            SignInWithAppleButton(.signIn) { request in
                account.configure(request)
            } onCompletion: { result in
                Task { await account.complete(result) }
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(height: 50)
            .clipShape(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
            .disabled(account.isBusy)
            .overlay {
                if account.isBusy { ProgressView().tint(colorScheme == .dark ? .black : .white) }
            }
            if let message = account.errorMessage {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
