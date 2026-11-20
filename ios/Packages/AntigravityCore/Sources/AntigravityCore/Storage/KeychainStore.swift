import Foundation
#if canImport(Security)
import Security
#endif

public protocol TokenStoreProtocol: Sendable {
    func saveToken(_ token: String, for hostId: UUID) throws
    func loadToken(for hostId: UUID) throws -> String?
    func deleteToken(for hostId: UUID) throws
}

public enum TokenStoreError: Error, LocalizedError, Equatable, Sendable {
    case encodingFailed
    case keychainError(status: Int32)

    public var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Unable to encode or decode authentication token."
        case .keychainError(let status):
            return "Keychain operation failed with OSStatus \(status)."
        }
    }
}

public final class InMemoryTokenStore: TokenStoreProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID: String]

    public init(initialTokens: [UUID: String] = [:]) {
        self.storage = initialTokens
    }

    public func saveToken(_ token: String, for hostId: UUID) throws {
        lock.lock()
        storage[hostId] = token
        lock.unlock()
    }

    public func loadToken(for hostId: UUID) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[hostId]
    }

    public func deleteToken(for hostId: UUID) throws {
        lock.lock()
        storage.removeValue(forKey: hostId)
        lock.unlock()
    }

    public func clearAll() {
        lock.lock()
        storage.removeAll()
        lock.unlock()
    }
}

#if canImport(Security)
public final class KeychainTokenStore: TokenStoreProtocol, Sendable {
    public let service: String
    public let accessGroup: String?

    public init(
        service: String = "com.antigravity.monitor.tokens",
        accessGroup: String? = nil
    ) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func saveToken(_ token: String, for hostId: UUID) throws {
        guard let data = token.data(using: .utf8) else {
            throw TokenStoreError.encodingFailed
        }

        let baseQuery = makeBaseQuery(for: hostId)
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        var status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let attributesToUpdate: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
            status = SecItemUpdate(baseQuery as CFDictionary, attributesToUpdate as CFDictionary)
        }

        guard status == errSecSuccess else {
            throw TokenStoreError.keychainError(status: status)
        }
    }

    public func loadToken(for hostId: UUID) throws -> String? {
        var query = makeBaseQuery(for: hostId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw TokenStoreError.keychainError(status: status)
        }
        guard let data = item as? Data,
              let token = String(data: data, encoding: .utf8) else {
            throw TokenStoreError.encodingFailed
        }
        return token
    }

    public func deleteToken(for hostId: UUID) throws {
        let query = makeBaseQuery(for: hostId)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TokenStoreError.keychainError(status: status)
        }
    }

    private func makeBaseQuery(for hostId: UUID) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hostId.uuidString
        ]
        if let accessGroup, !accessGroup.isEmpty {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}
#endif
