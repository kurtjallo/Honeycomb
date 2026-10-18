import Foundation
import Security

/// Where provider API keys are kept. Tests use an in-memory fake, so they never touch the login keychain.
public protocol SecretStore: Sendable {
    func set(_ secret: String, account: String) throws
    /// Nil only when no key is stored. A keychain that can't be read throws, so a request never
    /// goes out without its key and comes back as "key rejected".
    func read(account: String) throws -> String?
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

    public func read(account: String) throws -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return try Self.secret(status: status, result: result)
    }

    /// Only `KeychainTests` still reads keys this way. Use `read(account:)`, which reports failures.
    public func get(account: String) -> String? {
        (try? read(account: account)) ?? nil
    }

    static func secret(status: OSStatus, result: AnyObject?) throws -> String? {
        switch status {
        case errSecSuccess: (result as? Data).flatMap { String(data: $0, encoding: .utf8) }
        case errSecItemNotFound: nil
        default: throw KeychainError.status(status)
        }
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
