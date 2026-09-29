import Foundation
import Security

enum KeychainError: LocalizedError {
    case saveFailed(OSStatus)
    case loadFailed
    case deleteFailed(OSStatus)
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            return "Keychain save failed: \(status)"
        case .loadFailed:
            return "Keychain item not found"
        case .deleteFailed(let status):
            return "Keychain delete failed: \(status)"
        case .encodingFailed:
            return "Failed to encode data"
        }
    }
}

/// App-owned Keychain items. Every call runs inside `KeychainInteractionGuard.shared`.
/// The default mode is `.background` (no UI); pass `.userInitiated` only from explicit user actions.
final class KeychainService: Sendable {
    static let shared = KeychainService()

    private init() {}

    func save(
        _ data: Data,
        service: String,
        account: String,
        mode: KeychainInteractionMode = .background
    ) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,

        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        try KeychainInteractionGuard.shared.perform(mode) {
            // Prefer SecItemUpdate to minimize the delete+add window; fall back to add if item doesn't exist
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

            if updateStatus == errSecItemNotFound {
                let addQuery = query.merging(attributes) { _, new in new }
                let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
                guard addStatus == errSecSuccess else {
                    throw KeychainError.saveFailed(addStatus)
                }
            } else if updateStatus != errSecSuccess {
                throw KeychainError.saveFailed(updateStatus)
            }
        }
    }

    func save<T: Encodable>(
        _ value: T,
        service: String,
        account: String,
        mode: KeychainInteractionMode = .background
    ) throws {
        let data = try JSONEncoder().encode(value)
        try save(data, service: service, account: account, mode: mode)
    }

    func load(service: String, account: String, mode: KeychainInteractionMode = .background) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,

            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        return try KeychainInteractionGuard.shared.perform(mode) {
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)

            guard status == errSecSuccess, let data = result as? Data else {
                throw KeychainError.loadFailed
            }

            return data
        }
    }

    func load<T: Decodable>(
        _ type: T.Type,
        service: String,
        account: String,
        mode: KeychainInteractionMode = .background
    ) throws -> T {
        let data = try load(service: service, account: account, mode: mode)
        return try JSONDecoder().decode(type, from: data)
    }

    func delete(service: String, account: String, mode: KeychainInteractionMode = .background) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,

        ]

        try KeychainInteractionGuard.shared.perform(mode) {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError.deleteFailed(status)
            }
        }
    }
}
