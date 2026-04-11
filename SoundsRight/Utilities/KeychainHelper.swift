import Foundation
import Security

enum KeychainError: LocalizedError {
    case saveFailed(OSStatus)
    case readFailed(OSStatus)
    case deleteFailed(OSStatus)
    case dataConversionFailed

    var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            return "Failed to save API key to keychain (status: \(status))"
        case .readFailed(let status):
            return "Failed to read API key from keychain (status: \(status))"
        case .deleteFailed(let status):
            return "Failed to delete API key from keychain (status: \(status))"
        case .dataConversionFailed:
            return "Failed to convert keychain data to string"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .saveFailed:
            return "Check that the keychain is accessible and you have permission to save items."
        case .readFailed:
            return "The API key may not be stored in the keychain. Try saving it again."
        case .deleteFailed:
            return "The item may not exist in the keychain."
        case .dataConversionFailed:
            return "The stored data is not a valid UTF-8 string."
        }
    }
}

struct KeychainHelper {
    private static let accountKey = "claudeAPIKey"

    static func save(apiKey: String, service: String = AppConstants.keychainService) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountKey,
            kSecValueData as String: apiKey.data(using: .utf8) ?? Data(),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    static func read(service: String = AppConstants.keychainService) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountKey,
            kSecReturnData as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status != errSecItemNotFound else {
            return nil
        }

        guard status == errSecSuccess else {
            throw KeychainError.readFailed(status)
        }

        guard let data = result as? Data else {
            throw KeychainError.dataConversionFailed
        }

        guard let apiKey = String(data: data, encoding: .utf8) else {
            throw KeychainError.dataConversionFailed
        }

        return apiKey
    }

    static func delete(service: String = AppConstants.keychainService) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountKey,
        ]

        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }
}
