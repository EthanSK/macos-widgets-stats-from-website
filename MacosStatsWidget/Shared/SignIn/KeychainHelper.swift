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
    private static let keychainAccessGroupsEntitlement = "keychain-access-groups"
    private static let sharedAccessGroupSuffix = ".com.ethansk.macos-stats-widget"

    static func saveGenericPassword(_ password: String, service: String, account: String) throws {
        var lastError: Error?
        for accessGroup in accessGroupCandidates() {
            do {
                try saveGenericPassword(password, service: service, account: account, accessGroup: accessGroup)
                return
            } catch {
                lastError = error
            }
        }

        throw lastError ?? KeychainError.unexpectedStatus(errSecInternalError)
    }

    private static func saveGenericPassword(_ password: String, service: String, account: String, accessGroup: String?) throws {
        let data = Data(password.utf8)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

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
        var lastError: Error?
        for accessGroup in accessGroupCandidates() {
            do {
                if let password = try readGenericPassword(service: service, account: account, accessGroup: accessGroup) {
                    return password
                }
            } catch {
                lastError = error
            }
        }

        if let lastError, accessGroupCandidates().count == 1 {
            throw lastError
        }

        return nil
    }

    private static func readGenericPassword(service: String, account: String, accessGroup: String?) throws -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

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

    private static func accessGroupCandidates() -> [String?] {
        var candidates: [String?] = []
        if let accessGroup = sharedKeychainAccessGroup() {
            candidates.append(accessGroup)
        }
        candidates.append(nil)
        return candidates
    }

    private static func sharedKeychainAccessGroup() -> String? {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, keychainAccessGroupsEntitlement as CFString, nil) else {
            return nil
        }

        let groups = value as? [String] ?? []
        return groups.first { $0.hasSuffix(sharedAccessGroupSuffix) }
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
