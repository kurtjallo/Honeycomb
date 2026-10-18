import Foundation
import Security

/// Where provider API keys are kept. Tests use an in-memory fake, so they never touch the login keychain.
public protocol SecretStore: Sendable {
    func set(_ secret: String, account: String) throws
    func get(account: String) -> String?
    func delete(account: String)
}

/// API keys for AI providers, in the login keychain. Keys never go in SQLite, settings, or logs.
public struct Keychain: SecretStore {
    public let service: String

    public init(service: String = "io.github.kurtjallo.Honeycomb.providers") {
        self.service = service
    }

    public enum KeychainError: Error, Equatable {
        case status(OSStatus)
    }

    public func set(_ secret: String, account: String) throws {
        let query = baseQuery(account)
        let attributes = [kSecValueData as String: Data(secret.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(secret.utf8)
            item[kSecAttrLabel as String] = "Honeycomb AI provider key"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    public func get(account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return Self.secret(status: status, result: result)
    }

    static func secret(status: OSStatus, result: AnyObject?) -> String? {
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func delete(account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }

    /// "Delete all data" also removes every stored key.
    public func deleteAll() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}
