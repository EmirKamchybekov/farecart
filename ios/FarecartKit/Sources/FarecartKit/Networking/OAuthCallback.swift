import Foundation

/// What the browser handed back on `farecart://auth-callback`. Supabase's PKCE flow sends
/// `?code=…`; the implicit flow would put `#access_token=…&refresh_token=…` in the fragment;
/// a failed or denied sign-in arrives as `?error=…&error_description=…` (sometimes in the fragment).
public enum OAuthCallback: Sendable, Hashable {
    case code(String)
    case tokens(accessToken: String, refreshToken: String, expiresIn: TimeInterval?, expiresAt: TimeInterval?)
    case failure(code: String?, description: String?)

    /// Parses the callback URL, reading the query first and the fragment second. `nil` when the
    /// URL carries neither a code, tokens nor an error.
    public static func parse(_ url: URL) -> OAuthCallback? {
        var params: [String: String] = [:]
        if let fragment = url.fragment(percentEncoded: true) {
            params.merge(Self.decode(fragment)) { current, _ in current }
        }
        if let query = url.query(percentEncoded: true) {
            params.merge(Self.decode(query)) { _, fromQuery in fromQuery }
        }
        if let error = params["error"], !error.isEmpty {
            return .failure(code: params["error_code"] ?? error, description: params["error_description"])
        }
        if let description = params["error_description"], !description.isEmpty {
            return .failure(code: params["error_code"], description: description)
        }
        if let code = params["code"], !code.isEmpty {
            return .code(code)
        }
        if let access = params["access_token"], !access.isEmpty, let refresh = params["refresh_token"], !refresh.isEmpty {
            return .tokens(
                accessToken: access,
                refreshToken: refresh,
                expiresIn: params["expires_in"].flatMap(TimeInterval.init),
                expiresAt: params["expires_at"].flatMap(TimeInterval.init)
            )
        }
        return nil
    }

    /// `true` for `scheme://host…` regardless of case, trailing slashes or query.
    public static func matches(_ url: URL, scheme: String, host: String) -> Bool {
        url.scheme?.lowercased() == scheme.lowercased() && url.host()?.lowercased() == host.lowercased()
    }

    /// Splits `a=1&b=2`, percent-decoding and treating `+` as a space (the error_description Supabase
    /// sends is form-encoded).
    private static func decode(_ string: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in string.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawKey = parts.first, !rawKey.isEmpty else { continue }
            let rawValue = parts.count > 1 ? String(parts[1]) : ""
            let key = String(rawKey).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(rawKey)
            let value = rawValue.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? rawValue
            result[key] = value
        }
        return result
    }
}
