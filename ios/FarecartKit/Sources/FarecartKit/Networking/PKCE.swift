import Foundation
import CryptoKit

/// Proof Key for Code Exchange (RFC 7636) helpers for the hosted OAuth flow: a random verifier
/// stays in the app, its SHA-256 (base64url, no padding) goes to the authorize URL.
public enum PKCE {
    /// A fresh 43–128 character verifier from the unreserved alphabet.
    public static func makeVerifier(length: Int = 64) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var generator = SystemRandomNumberGenerator()
        let clamped = min(max(length, 43), 128)
        return String((0..<clamped).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] })
    }

    /// `base64url(SHA256(verifier))` as the `code_challenge` with `code_challenge_method=s256`.
    public static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// Base64 with the URL-safe alphabet and no `=` padding.
    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
