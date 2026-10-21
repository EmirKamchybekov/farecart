import Foundation

/// What `signUp` returns: signed in straight away (email autoconfirm on), or a confirmation link
/// was emailed and the user signs in after tapping it.
public enum SignUpResult: Sendable, Hashable {
    case signedIn(AuthSession)
    case confirmationRequired(email: String?)
}

/// GoTrue's email + password failures, decoded from
/// `{"code":422,"error_code":"weak_password","msg":"…"}` (or the older
/// `{"error":"invalid_grant","error_description":"Invalid login credentials"}`). The app maps each
/// case to localized copy; `errorDescription` is English for logs.
public enum AuthError: Error, Sendable, Hashable {
    /// `invalid_credentials`: wrong email or password.
    case invalidCredentials
    /// `user_already_exists` / `email_exists`.
    case userAlreadyExists
    /// `weak_password`: GoTrue's reason, e.g. "Password should be at least 8 characters."
    case weakPassword(String?)
    /// `email_not_confirmed`.
    case emailNotConfirmed
    /// `over_email_send_rate_limit`, `over_request_rate_limit` or HTTP 429.
    case rateLimited
    /// `email_address_invalid` / `validation_failed` about the address.
    case invalidEmail
    /// `signup_disabled` / `email_provider_disabled`.
    case signupDisabled
    /// Anything else, with GoTrue's code and message.
    case other(status: Int, code: String?, message: String)

    public init(status: Int, body: Data) {
        let decoded = try? PostgRESTDecoder.decode(SupabaseAuthClient.GoTrueError.self, from: body)
        let code = decoded?.code?.lowercased()
        let message = decoded?.message ?? String(decoding: body.prefix(200), as: UTF8.self)
        let lowered = message.lowercased()
        switch code {
        case "invalid_credentials":
            self = .invalidCredentials
        case "user_already_exists", "email_exists", "identity_already_exists":
            self = .userAlreadyExists
        case "weak_password":
            self = .weakPassword(decoded?.message)
        case "email_not_confirmed":
            self = .emailNotConfirmed
        case "over_email_send_rate_limit", "over_request_rate_limit", "over_sms_send_rate_limit":
            self = .rateLimited
        case "email_address_invalid", "email_address_not_authorized":
            self = .invalidEmail
        case "signup_disabled", "email_provider_disabled":
            self = .signupDisabled
        default:
            // Older GoTrue: `{"error":"invalid_grant","error_description":"Invalid login credentials"}`.
            if lowered.contains("invalid login credentials") {
                self = .invalidCredentials
            } else if lowered.contains("already registered") || lowered.contains("already been registered") {
                self = .userAlreadyExists
            } else if lowered.contains("email not confirmed") {
                self = .emailNotConfirmed
            } else if status == 429 || lowered.contains("rate limit") {
                self = .rateLimited
            } else if lowered.contains("password should") || lowered.contains("password is") {
                self = .weakPassword(message)
            } else if lowered.contains("email") && (lowered.contains("invalid") || lowered.contains("validate")) {
                self = .invalidEmail
            } else {
                self = .other(status: status, code: code, message: message)
            }
        }
    }
}

extension AuthError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidCredentials: "Wrong email or password."
        case .userAlreadyExists: "An account with this email already exists."
        case .weakPassword(let reason): reason ?? "Password is too weak."
        case .emailNotConfirmed: "Email address not confirmed yet."
        case .rateLimited: "Too many attempts. Try again later."
        case .invalidEmail: "That email address is not valid."
        case .signupDisabled: "Sign-ups are turned off."
        case .other(let status, let code, let message): "Auth error \(status) \(code ?? ""): \(message)"
        }
    }
}
