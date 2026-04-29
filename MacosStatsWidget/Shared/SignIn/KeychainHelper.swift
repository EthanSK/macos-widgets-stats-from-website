//
//  KeychainHelper.swift
//  MacosStatsWidgetShared
//
//  Small Keychain wrapper used for MCP shared-secret auth.
//

import Foundation
import Security

enum KeychainHelper {
    enum KeychainError: LocalizedError {
        case unexpectedStatus(OSStatus)
        case invalidData

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                return "Keychain returned status \(status)."
            case .invalidData:
                return "Keychain item data was not readable."
            }
        }
    }

    static let mcpService = "mcp-secret"
    static let mcpAccount = "macos-stats-widget"

    static func saveGenericPassword(_ password: String, service: String, account: String) throws {
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    static func readGenericPassword(service: String, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }

        guard let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }

        return password
    }

    @discardableResult
    static func rotateMCPToken() throws -> String {
        let token = "\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        try saveGenericPassword(token, service: mcpService, account: mcpAccount)
        return token
    }

    static func currentMCPToken() throws -> String? {
        try readGenericPassword(service: mcpService, account: mcpAccount)
    }
}
