import Foundation

/// One row of the `programs` table (the discount programs behind the eligibility quiz).
public struct Program: Sendable, Hashable, Identifiable, Codable {
    public var key: String
    public var name: String
    public var who: String
    public var what: String
    public var how: String
    public var signupURL: String?
    public var phone: String?
    public var sourceURL: String?

    public var id: String { key }

    public init(
        key: String,
        name: String,
        who: String,
        what: String,
        how: String,
        signupURL: String? = nil,
        phone: String? = nil,
        sourceURL: String? = nil
    ) {
        self.key = key
        self.name = name
        self.who = who
        self.what = what
        self.how = how
        self.signupURL = signupURL
        self.phone = phone
        self.sourceURL = sourceURL
    }

    public var signupLink: URL? { signupURL.flatMap { URL(string: $0) } }
    public var phoneURL: URL? { DirectionsLinks.telephoneURL(phone) }

    private enum CodingKeys: String, CodingKey {
        case key, name, who, what, how
        case signupURL = "signup_url"
        case phone
        case sourceURL = "source_url"
    }
}
