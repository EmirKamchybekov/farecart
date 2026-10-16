import Foundation
import Security
import FarecartKit

/// Tiny Keychain wrapper for the auth session. One generic-password item per `account`.
struct Keychain: Sendable {
    var service = "org.farecart.app"

    enum KeychainError: Error {
        case unexpectedStatus(OSStatus)
    }

    func read(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess: return item as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainError.unexpectedStatus(status)
        }
    }

    func write(_ data: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecItemNotFound {
            let add = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
            guard add == errSecSuccess else { throw KeychainError.unexpectedStatus(add) }
        } else if update != errSecSuccess {
            throw KeychainError.unexpectedStatus(update)
        }
    }

    func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.unexpectedStatus(status) }
    }
}

/// Lets FarecartKit (Foundation-only) keep its device id and the staff session in the Keychain.
extension Keychain: SecureStore {
    func readString(key: String) throws -> String? {
        guard let data = try read(account: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func writeString(_ value: String, key: String) throws {
        try write(Data(value.utf8), account: key)
    }

    func removeValue(key: String) throws {
        try delete(account: key)
    }
}
