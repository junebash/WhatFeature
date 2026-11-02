import Foundation
#if canImport(Security)
import Security
#endif

/// Where `login` keeps the admin token on macOS: a generic password in the user's Keychain. Elsewhere the token
/// goes in the settings file. Calls block on the Keychain service, so run them on `CLIContext.threadPool`.
struct Keychain: Sendable {
    var service = "whatfeature"
    /// The settings file's path, so a token belongs to one settings file (and tests don't share one).
    var account: String

    struct Failure: Error, CustomStringConvertible {
        var status: Int32
        var description: String { "Keychain error \(status)" }
    }

    #if canImport(Security)
    func read() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure(status: status) }
        return (item as? Data).map { String(decoding: $0, as: UTF8.self) }
    }

    func save(_ secret: String) throws {
        let data = [kSecValueData as String: Data(secret.utf8)]
        var status = SecItemUpdate(baseQuery as CFDictionary, data as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(baseQuery.merging(data) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    /// Returns `false` if there was nothing to delete.
    func delete() throws -> Bool {
        let status = SecItemDelete(baseQuery as CFDictionary)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw Failure(status: status) }
        return true
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    #else
    // Never created off macOS (`CLIContext.live` leaves it out), so these never run.
    func read() throws -> String? { nil }
    func save(_ secret: String) throws { throw Failure(status: -1) }
    func delete() throws -> Bool { false }
    #endif
}
