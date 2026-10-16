import Foundation

/// Where small secrets live. The app passes its Keychain; tests and previews use memory. Kept as
/// a protocol so FarecartKit stays Foundation-only (no `Security` import).
public protocol SecureStore: Sendable {
    func readString(key: String) throws -> String?
    func writeString(_ value: String, key: String) throws
    func removeValue(key: String) throws
}

/// A `SecureStore` for previews and tests.
public final class InMemorySecureStore: SecureStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]

    public init(_ values: [String: String] = [:]) {
        self.values = values
    }

    public func readString(key: String) throws -> String? {
        lock.withLock { values[key] }
    }

    public func writeString(_ value: String, key: String) throws {
        lock.withLock { values[key] = value }
    }

    public func removeValue(key: String) throws {
        lock.withLock { _ = values.removeValue(forKey: key) }
    }
}

/// The anonymous device id sent as `p_device_id`: a UUID generated once and kept in the secure
/// store, so bookings survive reinstalls but are never tied to a person.
public enum DeviceID {
    public static let storageKey = "farecart.device_id"

    /// Returns the stored id, creating and saving one the first time. If the store cannot be
    /// written the id lives for this process only (bookings still work, they just do not persist).
    public static func current(store: any SecureStore) -> String {
        if let existing = try? store.readString(key: storageKey), isValid(existing) {
            return existing
        }
        let fresh = UUID().uuidString.lowercased()
        try? store.writeString(fresh, key: storageKey)
        return fresh
    }

    /// `book_visit` rejects ids shorter than 8 characters.
    public static func isValid(_ id: String) -> Bool {
        id.trimmingCharacters(in: .whitespacesAndNewlines).count >= 8
    }
}
