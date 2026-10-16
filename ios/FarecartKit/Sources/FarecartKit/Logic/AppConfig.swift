import Foundation

/// Runtime configuration read from Info.plist (which is filled from the xcconfig files).
public struct AppConfig: Sendable, Hashable {
    public var supabaseURL: URL
    public var supabaseAnonKey: String
    /// Optional Farecart API (geocoding). `nil` means "use Apple's geocoder only".
    public var apiBaseURL: URL?
    public var reportProblemEmail: String

    public enum Key {
        public static let supabaseURL = "SUPABASE_URL"
        public static let supabaseAnonKey = "SUPABASE_ANON_KEY"
        public static let apiBaseURL = "API_BASE_URL"
        public static let reportProblemEmail = "REPORT_PROBLEM_EMAIL"
    }

    public enum ConfigError: Error, Equatable, Sendable {
        case missing(String)
        case invalidURL(String)
    }

    public init(supabaseURL: URL, supabaseAnonKey: String, apiBaseURL: URL? = nil, reportProblemEmail: String = "hello@farecart.org") {
        self.supabaseURL = supabaseURL
        self.supabaseAnonKey = supabaseAnonKey
        self.apiBaseURL = apiBaseURL
        self.reportProblemEmail = reportProblemEmail
    }

    /// Build from a lookup such as `{ Bundle.main.object(forInfoDictionaryKey: $0) as? String }`.
    public init(lookup: (String) -> String?) throws {
        func clean(_ key: String) -> String? {
            guard let value = lookup(key)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            // xcconfig cannot express "//" literally; the files use `https:/$()/host`, but tolerate a
            // value that lost its slashes anyway.
            if value.hasPrefix("https:/") && !value.hasPrefix("https://") {
                return value.replacingOccurrences(of: "https:/", with: "https://")
            }
            return value
        }
        guard let urlString = clean(Key.supabaseURL) else { throw ConfigError.missing(Key.supabaseURL) }
        guard let url = URL(string: urlString), url.host() != nil else { throw ConfigError.invalidURL(urlString) }
        guard let key = clean(Key.supabaseAnonKey) else { throw ConfigError.missing(Key.supabaseAnonKey) }
        supabaseURL = url
        supabaseAnonKey = key
        if let api = clean(Key.apiBaseURL) {
            guard let apiURL = URL(string: api), apiURL.host() != nil else { throw ConfigError.invalidURL(api) }
            apiBaseURL = apiURL
        } else {
            apiBaseURL = nil
        }
        reportProblemEmail = clean(Key.reportProblemEmail) ?? "hello@farecart.org"
    }
}
