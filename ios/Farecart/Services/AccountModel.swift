import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import SwiftUI
import UIKit
import FarecartKit

/// Which provider the stored session came from.
enum AuthProvider: String, Sendable {
    case apple, google, email
}

/// What an email sheet should show after its button was tapped.
enum EmailAuthOutcome: Equatable {
    /// Signed in; the sheet closes.
    case signedIn
    /// Sign-up needs the emailed link (only when email autoconfirm is off on the server).
    case confirmationSent(String)
    /// The reset link went out (GoTrue says so whether or not the address has an account).
    case resetSent(String)
    /// Localized message to show in the sheet.
    case failed(String)
}

/// Optional account: email + password, Sign in with Apple (native) or Google (Supabase's hosted
/// OAuth flow with PKCE in `ASWebAuthenticationSession`) → Supabase session in the Keychain →
/// `profiles` row kept in step with the Discounts answers, language and theme, and pantry visits
/// claimed onto the account. Everything works signed out.
@MainActor
@Observable
final class AccountModel {
    /// False until the stored session has been loaded at launch, so the first screen doesn't flash.
    private(set) var didRestore = false
    private(set) var session: AuthSession? {
        didSet { if session != nil { UserDefaults.standard.set(true, forKey: OnboardingKeys.hasSignedIn) } }
    }
    private(set) var isBusy = false
    /// Friendly, already localized message for the Account section; `nil` when all is well.
    private(set) var errorMessage: String?
    /// Set after a password-reset link brought the user back signed in: the app asks for a new
    /// password (`NewPasswordSheet`).
    var needsNewPassword = false

    var isSignedIn: Bool { session != nil }
    /// `nil` for sessions stored before the provider was recorded (those were all Apple).
    var provider: AuthProvider? { session?.provider.flatMap(AuthProvider.init(rawValue:)) }
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
    /// PKCE verifier for the Google flow in flight; its SHA-256 went to `/authorize`.
    private var pendingCodeVerifier: String?
    private var webSession: ASWebAuthenticationSession?
    /// Visits move to the account on sign-in and the list refreshes on every account change.
    private weak var pantry: PantryStore?
    /// `"signup:<verifier>"` / `"recovery:<verifier>"` for an emailed link in flight. In the Keychain
    /// because the link is usually opened after the app was suspended or relaunched.
    private static let emailFlowAccount = "supabase.pkce.email"
    private let presentationContext = WebAuthPresentationContext()

    static let callbackScheme = "farecart"
    static let callbackHost = "auth-callback"
    static var redirectURI: String { "\(callbackScheme)://\(callbackHost)" }

    // MARK: Launch

    /// Loads the stored session, refreshes it when needed and pulls the profile down.
    func restore(environment: AppEnvironment) async {
        defer { didRestore = true }
        pantry = environment.pantry
        environment.pantry.accessTokenProvider = { [weak self] in await self?.validAccessToken() }
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
        didRestore = true   // show the app now; profile and visits sync in the background
        await pullProfile()
        #if DEBUG
        if DebugLaunch.signOutAtLaunch { await signOut(); return }
        #endif
        // Visits booked as a guest before an update that added claiming join the account too.
        await claimVisits()
    }

    // MARK: Email + password

    func signUpWithEmail(name: String, email: String, password: String) async -> EmailAuthOutcome {
        guard let auth else { return .failed(Self.missingConfigMessage) }
        if let problem = Self.validate(email: email, password: password) { return .failed(problem) }
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        let verifier = PKCE.makeVerifier()
        do {
            let result = try await auth.signUp(email: email, password: password, name: name,
                                               redirectTo: Self.redirectURI, codeChallenge: PKCE.challenge(for: verifier))
            switch result {
            case .signedIn(var newSession):
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if newSession.user.fullName == nil, !trimmed.isEmpty { newSession.user.fullName = trimmed }
                await adopt(newSession, provider: .email)
                return .signedIn
            case .confirmationRequired(let address):
                try? keychain.write(Data("signup:\(verifier)".utf8), account: Self.emailFlowAccount)
                let shown = address ?? SupabaseAuthClient.normalize(email: email)
                return .confirmationSent(String(localized: "Check your email. We sent a link to \(shown). Open it on this phone to finish.", bundle: LanguageBundle.current))
            }
        } catch {
            return .failed(Self.message(for: error))
        }
    }

    func signInWithEmail(email: String, password: String) async -> EmailAuthOutcome {
        guard let auth else { return .failed(Self.missingConfigMessage) }
        guard Self.looksLikeEmail(email) else { return .failed(Self.invalidEmailMessage) }
        guard !password.isEmpty else { return .failed(String(localized: "Enter your password.", bundle: LanguageBundle.current)) }
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        do {
            let newSession = try await auth.signIn(email: email, password: password)
            await adopt(newSession, provider: .email)
            return .signedIn
        } catch {
            return .failed(Self.message(for: error))
        }
    }

    /// Emails a reset link that comes back to `farecart://auth-callback?code=…` (PKCE).
    func sendPasswordReset(email: String) async -> EmailAuthOutcome {
        guard let auth else { return .failed(Self.missingConfigMessage) }
        guard Self.looksLikeEmail(email) else { return .failed(Self.invalidEmailMessage) }
        isBusy = true
        defer { isBusy = false }
        let verifier = PKCE.makeVerifier()
        do {
            try await auth.sendPasswordReset(email: email, redirectTo: Self.redirectURI, codeChallenge: PKCE.challenge(for: verifier))
            try? keychain.write(Data("recovery:\(verifier)".utf8), account: Self.emailFlowAccount)
            let shown = SupabaseAuthClient.normalize(email: email)
            return .resetSent(String(localized: "If there is an account for \(shown), we sent it a link to reset the password. Open the link on this phone.", bundle: LanguageBundle.current))
        } catch {
            return .failed(Self.message(for: error))
        }
    }

    /// Sets the password after a recovery sign-in. Returns a localized error, `nil` on success.
    func setNewPassword(_ password: String) async -> String? {
        guard password.count >= Self.minimumPasswordLength else { return Self.weakPasswordMessage }
        guard let auth, let current = await freshSession() else { return Self.couldNotSignInMessage }
        isBusy = true
        defer { isBusy = false }
        do {
            try await auth.updatePassword(password, session: current)
            needsNewPassword = false
            return nil
        } catch {
            return Self.message(for: error)
        }
    }

    static let minimumPasswordLength = 8

    static func looksLikeEmail(_ email: String) -> Bool {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = trimmed.firstIndex(of: "@"), trimmed.count >= 5, !trimmed.contains(" ") else { return false }
        let domain = trimmed[trimmed.index(after: at)...]
        return at != trimmed.startIndex && domain.contains(".") && !domain.hasSuffix(".") && !domain.contains("@")
    }

    private static func validate(email: String, password: String) -> String? {
        guard looksLikeEmail(email) else { return invalidEmailMessage }
        guard password.count >= minimumPasswordLength else { return weakPasswordMessage }
        return nil
    }

    /// Friendly, localized copy for GoTrue's errors; anything unexpected reads as a connection problem.
    private static func message(for error: any Error) -> String {
        let bundle = LanguageBundle.current
        guard let authError = error as? AuthError else { return couldNotSignInMessage }
        switch authError {
        case .invalidCredentials:
            return String(localized: "That email and password don't match. Check them and try again.", bundle: bundle)
        case .userAlreadyExists:
            return String(localized: "There is already an account with this email. Sign in instead.", bundle: bundle)
        case .weakPassword:
            return weakPasswordMessage
        case .emailNotConfirmed:
            return String(localized: "Confirm your email first: open the link we sent you, then sign in.", bundle: bundle)
        case .rateLimited:
            return String(localized: "Too many tries for now. Wait a few minutes and try again.", bundle: bundle)
        case .invalidEmail:
            return invalidEmailMessage
        case .signupDisabled:
            return String(localized: "New accounts are turned off right now. You can keep using Farecart as a guest.", bundle: bundle)
        case .other:
            return couldNotSignInMessage
        }
    }

    private static var invalidEmailMessage: String {
        String(localized: "Enter a valid email address.", bundle: LanguageBundle.current)
    }
    private static var weakPasswordMessage: String {
        String(localized: "Use at least 8 characters for your password.", bundle: LanguageBundle.current)
    }
    private static var missingConfigMessage: String {
        String(localized: "Sign in needs the app's Supabase settings, which are missing in this build.", bundle: LanguageBundle.current)
    }

    // MARK: Account deletion

    /// `delete_my_account()`, then the same local cleanup as signing out (Keychain session gone,
    /// visit list back to this phone's). Returns a localized error, `nil` on success.
    func deleteAccount() async -> String? {
        let failure = String(localized: "Could not delete your account right now. Check your connection and try again.", bundle: LanguageBundle.current)
        guard let data, let current = await freshSession() else { return failure }
        isBusy = true
        defer { isBusy = false }
        do {
            try await data.deleteMyAccount(accessToken: current.accessToken)
        } catch {
            return failure
        }
        forget()
        try? keychain.delete(account: Self.emailFlowAccount)
        await pantry?.accountDidChange()
        return nil
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
            errorMessage = String(localized: "Sign in with Apple is not available on this device right now. Use Google or email instead.", bundle: LanguageBundle.current)
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
                await adopt(newSession, provider: .apple)
            } catch {
                errorMessage = Self.couldNotSignInMessage
            }
        }
        pendingNonce = nil
    }

    // MARK: Sign in with Google (hosted OAuth + PKCE, no SDK)

    /// Opens Supabase's `/authorize?provider=google` in a web authentication session and finishes
    /// through `farecart://auth-callback`. Cancelling is silent; a provider that is not set up yet
    /// shows a friendly line instead of the browser.
    func signInWithGoogle() async {
        guard !isBusy else { return }
        guard let auth else {
            errorMessage = String(localized: "Sign in needs the app's Supabase settings, which are missing in this build.", bundle: LanguageBundle.current)
            return
        }
        errorMessage = nil
        isBusy = true
        let verifier = PKCE.makeVerifier()
        guard let url = try? auth.authorizeURL(provider: "google", redirectTo: Self.redirectURI, codeChallenge: PKCE.challenge(for: verifier)) else {
            isBusy = false
            errorMessage = Self.googleDidNotFinishMessage
            return
        }
        // GoTrue answers 400 JSON (not a redirect) while the provider has no client id; don't show that page.
        do {
            try await auth.preflightAuthorize(url)
        } catch is SupabaseAuthClient.ProviderNotConfigured {
            isBusy = false
            errorMessage = Self.googleNotSetUpMessage
            return
        } catch {
            // Offline or similar: let the browser show its own error page.
        }
        pendingCodeVerifier = verifier
        do {
            let callbackURL = try await presentWebSession(url: url)
            await finishGoogle(callbackURL: callbackURL)
        } catch {
            // Either the user dismissed the sheet, or `handleOpenURL` took over and cancelled it.
            guard pendingCodeVerifier != nil else { return }
            pendingCodeVerifier = nil
            webSession = nil
            isBusy = false
            if (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
                errorMessage = Self.googleDidNotFinishMessage
            }
        }
    }

    /// Fallback for `farecart://auth-callback` arriving through the app (`onOpenURL`) rather than
    /// the web authentication session, e.g. from Safari. Ignored when no sign-in is in flight.
    func handleOpenURL(_ url: URL) async {
        guard OAuthCallback.matches(url, scheme: Self.callbackScheme, host: Self.callbackHost) else { return }
        if pendingCodeVerifier != nil {
            webSession?.cancel()
            await finishGoogle(callbackURL: url)
        } else {
            await finishEmailLink(callbackURL: url)
        }
    }

    /// A confirmation or password-reset link from the email, carrying `?code=…` for the verifier
    /// stored when it was requested. Ignored when no emailed link is pending.
    private func finishEmailLink(callbackURL: URL) async {
        guard let auth,
              let raw = (try? keychain.read(account: Self.emailFlowAccount)) ?? nil else { return }
        let stored = String(decoding: raw, as: UTF8.self)
        guard let colon = stored.firstIndex(of: ":") else { return }
        let purpose = stored[..<colon]
        let verifier = String(stored[stored.index(after: colon)...])
        let expired = String(localized: "That link has expired or was already used. Request a new one.", bundle: LanguageBundle.current)
        guard case .code(let code) = OAuthCallback.parse(callbackURL) else {
            errorMessage = expired
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let newSession = try await auth.exchangeCode(code: code, codeVerifier: verifier)
            try? keychain.delete(account: Self.emailFlowAccount)
            await adopt(newSession, provider: .email)
            if purpose == "recovery" { needsNewPassword = true }
        } catch {
            errorMessage = expired
        }
    }

    private func finishGoogle(callbackURL: URL) async {
        guard let verifier = pendingCodeVerifier, let auth else {
            isBusy = false
            return
        }
        pendingCodeVerifier = nil
        webSession = nil
        isBusy = true
        defer { isBusy = false }
        switch OAuthCallback.parse(callbackURL) {
        case .code(let code):
            do {
                let newSession = try await auth.exchangeCode(code: code, codeVerifier: verifier)
                await adopt(newSession, provider: .google)
            } catch {
                errorMessage = Self.couldNotSignInMessage
            }
        case .tokens(let accessToken, let refreshToken, let expiresIn, let expiresAt):
            do {
                let newSession = try await auth.session(accessToken: accessToken, refreshToken: refreshToken, expiresIn: expiresIn, expiresAt: expiresAt)
                await adopt(newSession, provider: .google)
            } catch {
                errorMessage = Self.couldNotSignInMessage
            }
        case .failure(let code, let description):
            if code == "access_denied" { return }   // declined on Google's consent screen: same as cancel
            let text = (description ?? code ?? "").lowercased()
            if text.contains("unsupported provider") || text.contains("not enabled") || text.contains("client id") {
                errorMessage = Self.googleNotSetUpMessage
            } else {
                errorMessage = Self.googleDidNotFinishMessage
            }
        case nil:
            errorMessage = Self.googleDidNotFinishMessage
        }
    }

    private func presentWebSession(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme(Self.callbackScheme)) { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: error ?? ASWebAuthenticationSessionError(.canceledLogin))
                }
            }
            // Not ephemeral: the user's existing Google session in Safari makes this a one-tap flow.
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = presentationContext
            webSession = session
            if !session.start() {
                continuation.resume(throwing: ASWebAuthenticationSessionError(.presentationContextInvalid))
            }
        }
    }

    /// Stores a freshly obtained session exactly like the Apple path and syncs the profile.
    private func adopt(_ newSession: AuthSession, provider: AuthProvider) async {
        var stored = newSession
        if stored.provider == nil { stored.provider = provider.rawValue }
        persist(stored)
        session = stored
        errorMessage = nil
        await pullProfile(preferLocalAnswers: true)
        await claimVisits()
    }

    /// `claim_device_visits` for this phone's guest bookings, then reload the merged list.
    private func claimVisits() async {
        await pantry?.accountDidChange()
    }

    /// A non-expired JWT for pantry calls, or `nil` when signed out.
    func validAccessToken() async -> String? {
        await freshSession()?.accessToken
    }

    private static var couldNotSignInMessage: String {
        String(localized: "Could not sign in right now. Check your connection and try again.", bundle: LanguageBundle.current)
    }
    private static var googleNotSetUpMessage: String {
        String(localized: "Google sign-in isn't available right now. Use email instead.", bundle: LanguageBundle.current)
    }
    private static var googleDidNotFinishMessage: String {
        String(localized: "Google sign-in did not finish. Please try again.", bundle: LanguageBundle.current)
    }

    func signOut() async {
        if let session, let auth {
            try? await auth.signOut(session)
        }
        forget()
        await pantry?.accountDidChange()
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
        UserDefaults.standard.set(true, forKey: OnboardingKeys.needsSignIn)
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

/// Hands `ASWebAuthenticationSession` the key window to present from.
@MainActor
private final class WebAuthPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let windows = scenes.flatMap(\.windows)
            return windows.first(where: \.isKeyWindow) ?? scenes.first?.keyWindow ?? windows.first ?? ASPresentationAnchor()
        }
    }
}

/// "Continue with Google" in Google's standard look (white, hairline border, the colored "G") drawn
/// with SwiftUI shapes only; no asset.
struct SignInWithGoogleButton: View {
    @Environment(AccountModel.self) private var account
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    private var fill: Color { colorScheme == .dark ? Color(red: 0.075, green: 0.075, blue: 0.078) : .white }
    private var text: Color { colorScheme == .dark ? Color(red: 0.89, green: 0.89, blue: 0.89) : Color(red: 0.12, green: 0.12, blue: 0.12) }
    private var border: Color { colorScheme == .dark ? Color(red: 0.56, green: 0.56, blue: 0.56) : Color(red: 0.45, green: 0.46, blue: 0.46) }

    var body: some View {
        Button {
            Task { await account.signInWithGoogle() }
        } label: {
            HStack(spacing: 10) {
                GoogleGMark()
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
                Text("Continue with Google")
                    .font(.body.weight(.semibold))
            }
            .foregroundStyle(text)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(fill, in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                    .strokeBorder(border, lineWidth: 1 / displayScale)
            }
            .contentShape(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(account.isBusy)
    }
}

/// The four-color Google "G": a ring in four arcs with a gap at the top right, plus the blue bar.
struct GoogleGMark: View {
    private static let blue = Color(red: 0.259, green: 0.522, blue: 0.957)
    private static let red = Color(red: 0.918, green: 0.263, blue: 0.208)
    private static let yellow = Color(red: 0.984, green: 0.737, blue: 0.020)
    private static let green = Color(red: 0.204, green: 0.659, blue: 0.325)

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let origin = CGPoint(x: (size.width - side) / 2, y: (size.height - side) / 2)
            let center = CGPoint(x: origin.x + side / 2, y: origin.y + side / 2)
            let width = side * 0.2
            let radius = side / 2 - width / 2
            func arc(_ from: Double, _ to: Double, _ color: Color) {
                var path = Path()
                path.addArc(center: center, radius: radius, startAngle: .degrees(from), endAngle: .degrees(to), clockwise: false)
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .butt))
            }
            // Angles run clockwise on screen: 0° is the right edge, 90° the bottom.
            arc(0, 50, Self.blue)
            arc(48, 138, Self.green)
            arc(136, 212, Self.yellow)
            arc(210, 320, Self.red)
            let bar = CGRect(x: center.x, y: center.y - width / 2, width: side / 2, height: width)
            context.fill(Path(bar), with: .color(Self.blue))
        }
    }
}
